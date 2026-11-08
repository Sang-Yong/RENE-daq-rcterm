#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  chainwatch.sh - 수집 뒤쪽 사슬이 조용히 멈춘 것을 사람에게 알린다.
#
#  사용 :
#     chainwatch.sh [--params <파일>] [--min-rate HZ] [--consecutive N]
#                   [--warmup SEC] [--realert-min M] [--rotate-gap SEC]
#                   [--status] [--dry-run] [--no-notify]
#
#  왜 필요한가 (2026-09-01 에 두 번 다 아팠다)
#     1) /scratch 가 빠지자 postrun 이 죽었는데 아무 알림이 없었다.
#        사람이 pane 을 들여다보기 전까지 몇 시간을 몰랐다.
#     2) PMT HV 가 내려가 계수가 0 이 됐는데 알림이 없었다. 감시자의
#        stall 검사는 재시작만 되풀이해 런 번호만 태운다 (4319 · 4320).
#
#  무엇을 보는가
#     chain_down   /scratch 마운트 · postrun · dataflow 중 하나가 없다
#     rate_low     수집은 도는데 ADC 별 계수율 최솟값이 문턱 아래다
#     rate_high    ★ 비정상 기준 (2026-09-14 사용자 지시) : ADC 별 계수율 최댓값이 chain_alarm_rate(30,000 Hz) 이상이면
#                  그 자리에서 알람 + 책임자 메일. chain_warn_rate(20,000 Hz) 이상이면 경고 문구만 (로그·--status). 잡음 트리거
#                  (전원 재투입 뒤 설정 소실 = 23,527 Hz, §11.119) 이 그 모양이다
#     rotate       런 번호가 바뀌었고 이전 런이 정상 마감(onlbit=1) + 간격이 짧다
#                  -> 책임자에게만 (정상 로테이션)
#     resumed      런 번호가 바뀌었는데 이전 런이 실패했거나 간격이 길다
#                  -> 문제 뒤 다시 정상 가동. 전문가 목록 + 책임자
#                  (2026-09-09 사용자 지시. 감시자는 실패만 알리고 정상 교체는
#                   알리지 않으므로 여기서 본다. 새 런이 warmup 을 넘겨 계수율이
#                   잡힌 뒤에만 판정하고, 그 전에는 다음 주기로 미룬다)
#
#  ★ 합이나 평균이 아니라 '최솟값' 을 본다. 한 보드만 죽으면 합·평균은
#    멀쩡해 보인다 (usb-recover.sh 와 같은 이유. §11.56)
#
#  ★ 운용 중일 때만 본다. tmux 세션 'daq' 도 없고 감시자도 없으면
#    사람이 일부러 세운 것이므로 아무 말도 하지 않는다.
#
#  ★ 이 스크립트는 실패로 죽지 않는다 (daq-notify.sh 와 같은 원칙).
#    감시가 스스로 넘어지면 없느니만 못하다. 종료코드는 언제나 0 이다.
#
#  ★ CLI 옵션이 params 파일보다 우선한다 (친 대로 동작한다).
#
#  cron 예 (5분마다 점검. 조건이 이어지면 realert-min 간격으로만 알린다) :
#     */5 * * * * <저장소>/scripts/chainwatch.sh >/dev/null 2>&1
# ---------------------------------------------------------------------
set -u

DIR=$(cd "$(dirname "$0")/.." && pwd)
NOTIFY=$DIR/scripts/daq-notify.sh
PARAMS=$DIR/config/notify.params

STATE=${CHAINWATCH_STATE:-/Data_ssd/LOG/chainwatch.state}
LOG=${CHAINWATCH_LOG:-/Data_ssd/LOG/chainwatch.log}
#  ★ 시험은 갈아끼운다. 고정 경로면 운영 cron 과 잠금이 겹쳐 시험의 한 회차가
#    '이미 실행 중' 으로 조용히 빠지고 시험이 들쭉날쭉 깨진다 (2026-11-05 실측 4/41)
LOCK=${CHAINWATCH_LOCK:-/Data_ssd/LOG/.chainwatch.lock}

#  바깥 명령. 시험은 전부 가짜로 갈아끼운다 (tmux send-keys · kill 이 진짜로 나가지 않게)
TMUX_BIN=${CHAINWATCH_TMUX:-tmux}
PGREP_BIN=${CHAINWATCH_PGREP:-pgrep}
KILL_BIN=${CHAINWATCH_KILL:-kill}
MOUNTPOINT_BIN=${CHAINWATCH_MOUNTPOINT:-mountpoint}
PROC_ROOT=${CHAINWATCH_PROC:-/proc}
PS_FILE=${CHAINWATCH_PS:-}            # 'pid args' 줄. 비면 진짜 ps
DF_FILE=${CHAINWATCH_DF_FILE:-}       # '경로 여유GB' 줄. 비면 진짜 df
IDLE_PIDS=${CHAINWATCH_IDLE_PIDS-unset}   # pane 셸이 놀고 있다고 볼 pid 목록 (시험용)
SUPLOG=${CHAINWATCH_SUPLOG:-/Data/LOG/rcsupervisor.log}
DAQTMUX=${CHAINWATCH_DAQTMUX:-$DIR/scripts/daq-tmux.sh}
RCTERM_PARAMS=${CHAINWATCH_RCTERM_PARAMS:-$DIR/config/rcterm.params}
SESSION=${CHAINWATCH_SESSION:-daq}
#  ★ 멈춤 파일. 사람이 손으로 작업하는 동안 이것을 만들어 두면 pane 자동 재기동(D-3 · D-4)을 하지 않는다.
#    알림은 그대로 나간다.   touch /Data_ssd/LOG/chainwatch.hold   ...   rm /Data_ssd/LOG/chainwatch.hold
HOLD=${CHAINWATCH_HOLD:-/Data_ssd/LOG/chainwatch.hold}
#  이번 부팅 시각. 감시자가 이보다 먼저 끝났으면 정전·재부팅으로 끝난 것이다 -> 다시 띄우지 않는다 (CLAUDE.md 10, 11.225)
BOOT_EPOCH=${CHAINWATCH_BTIME:-$(awk '$1 == "btime" { print $2 }' /proc/stat 2>/dev/null)}
SUP_HB=${CHAINWATCH_SUP_HB:-}         # 감시자 대기 상태 파일. 비면 <heartbeat>.sup
#  pane 의 마지막 줄이 '맨 프롬프트' 인가 (끝이 $ # > 이고 그 뒤에 친 글자가 없다)
PROMPT_RE=${CHAINWATCH_PROMPT_RE:-'[$#>]$'}

HB=/Data/LOG/rcterm.hb
NFS_ROOT=/scratch
MINRATE=400          # ADC 별 계수율 최솟값의 문턱 [Hz]. (2026-09-14 veto 문턱 조정 뒤 정상은 ~300 Hz — params 에서 100)
WARNRATE=20000       # ADC 별 계수율 최댓값이 이 이상이면 경고 문구 (알림 없음)
ALARMRATE=30000      # 이 이상이면 rate_high 알림 = 알람 + 책임자 메일 (연속 조건 없이 즉시)
CONSEC=2             # 이만큼 연속으로 이상이어야 알린다 (일시적 흔들림 무시)
WARMUP=180           # 런 시작 후 이 시간[초] 안에는 계수율을 판정하지 않는다
REALERT_MIN=60       # 이상이 이어질 때 다시 알리는 간격 [분]
HB_MAX_AGE=120       # heartbeat 가 이보다 오래되면 '수집 중이 아니다'
DBFILE=/Data_ssd/runcatalog.db   # 런 교체 판정에 이전 런의 onlbit·etime 을 읽는다
ROTATE_GAP=600       # 이전 런 종료 -> 새 런 시작 간격이 이보다 길면 '사람이 세웠다 올린 것'
RATE_STOP=1          # rate_high 때 감시자에 SIGUSR1 (현재 런 정상 마감 뒤 cooldown 재기동). 런당 한 번
SSD_ROOT=/Data_ssd; MID_ROOT=/data
SSD_MIN_GB=700       # /Data_ssd 여유가 이보다 적으면 disk_low 메일 (dataflow 의 min_free_gb 와 같은 뜻)
SSD_ALARM_GB=200     # 이보다 적으면 알람 + 메일
MID_MIN_GB=3000      # /data 여유 문턱 (메일)
MID_ALARM_GB=500     # /data 알람 문턱
SUP_AUTORESTART=1    # 감시자가 FATAL 로 끝났으면 pane 에서 다시 띄운다 (시간당 1 회, 하루 상한)
SUP_RESTART_DAILY=3  # 하루 상한 -- 보드가 정말 죽었으면 매시 런 번호 5 개씩 태운다
AUTORESTART=1        # postrun · dataflow 가 죽었으면 pane 에서 다시 띄운다 (시간당 1 회)
SUP_RESTART_AFTER_MIN=30   # 감시자가 끝난 뒤(마지막 [SUP] 줄) 이만큼 지나야 다시 띄운다 -- 사람이 손대는 중일 수 있다
SUP_MAX_AGE=900      # 감시자 대기 상태 파일(time=)이 이보다 오래되면 믿지 않는다
TAIL_FINISH=0        # 1 이면 비정상으로 끝난 런의 꼬리를 scripts/tailfinish.sh 로 자동 마감한다 (params chain_tailfinish)
TAILFINISH=${CHAINWATCH_TAILFINISH:-$DIR/scripts/tailfinish.sh}
SUP_RESTART_MANUAL=0 # 1 이면 사람이 'rcsupervisor stop' 으로 세운 감시자도 SUP_RESTART_AFTER_MIN 뒤 다시 띄운다 (세워 두려면 멈춤 파일)
STATUS=0; DRY=0; NONOTIFY=0
GATE=auto            # auto | on | off   (off/on 은 시험용 강제)

load_params() {
   local f=$1 line k v
   [ -r "$f" ] || return 0
   while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      case "$line" in *=*) ;; *) continue ;; esac
      k=${line%%=*}; v=${line#*=}
      k=$(printf '%s' "$k" | tr -d ' \t' | tr 'A-Z-' 'a-z_')
      v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      case "$k" in
         heartbeat)          HB=$v ;;
         chain_nfs_root)     NFS_ROOT=$v ;;
         chain_min_rate)     MINRATE=$v ;;
         chain_warn_rate)    WARNRATE=$v ;;
         chain_alarm_rate)   ALARMRATE=$v ;;
         chain_consecutive)  CONSEC=$v ;;
         chain_warmup_sec)   WARMUP=$v ;;
         chain_realert_min)  REALERT_MIN=$v ;;
         chain_hb_max_age)   HB_MAX_AGE=$v ;;
         chain_dbfile)       DBFILE=$v ;;
         chain_rotate_gap_sec) ROTATE_GAP=$v ;;
         chain_rate_stop)    RATE_STOP=$v ;;
         chain_ssd_root)     SSD_ROOT=$v ;;
         chain_mid_root)     MID_ROOT=$v ;;
         chain_min_free_gb)  SSD_MIN_GB=$v ;;
         chain_disk_alarm_gb) SSD_ALARM_GB=$v ;;
         chain_mid_min_free_gb) MID_MIN_GB=$v ;;
         chain_mid_alarm_gb) MID_ALARM_GB=$v ;;
         chain_sup_autorestart) SUP_AUTORESTART=$v ;;
         chain_sup_autorestart_daily) SUP_RESTART_DAILY=$v ;;
         chain_autorestart)  AUTORESTART=$v ;;
         chain_sup_restart_after_min) SUP_RESTART_AFTER_MIN=$v ;;
         chain_sup_standby_max_age) SUP_MAX_AGE=$v ;;
         chain_sup_restart_manual) SUP_RESTART_MANUAL=$v ;;
         chain_hold_file)    HOLD=$v ;;
         chain_tailfinish)   TAIL_FINISH=$v ;;
      esac
   done < "$f"
}

#  ★ params 파일을 먼저 읽고, 그 다음 CLI 가 덮어쓴다 -- 친 대로 동작한다.
#    (usb-recover.sh 는 반대 순서다. 여기서는 --min-rate 를 손으로 주고
#     시험하는 일이 잦아 CLI 가 이기게 했다.)
for i in $(seq 1 $#); do
   eval "a=\${$i}"
   if [ "$a" = "--params" ]; then j=$(( i + 1 )); eval "PARAMS=\${$j:-$PARAMS}"; fi
done
load_params "$PARAMS"

while [ $# -gt 0 ]; do
   case "$1" in
      --params)       shift 2 ;;
      --min-rate)     MINRATE=$2; shift 2 ;;
      --warn-rate)    WARNRATE=$2; shift 2 ;;
      --alarm-rate)   ALARMRATE=$2; shift 2 ;;
      --consecutive)  CONSEC=$2; shift 2 ;;
      --warmup)       WARMUP=$2; shift 2 ;;
      --realert-min)  REALERT_MIN=$2; shift 2 ;;
      --heartbeat)    HB=$2; shift 2 ;;
      --state)        STATE=$2; shift 2 ;;
      --log)          LOG=$2; shift 2 ;;
      --gate)         GATE=$2; shift 2 ;;      # auto|on|off  (시험용)
      --dbfile)       DBFILE=$2; shift 2 ;;
      --rotate-gap)   ROTATE_GAP=$2; shift 2 ;;
      --notify)       NOTIFY=$2; shift 2 ;;    # 시험용 : 가짜 알림기
      --status)       STATUS=1; shift ;;
      --dry-run)      DRY=1; shift ;;
      --no-notify)    NONOTIFY=1; shift ;;
      -h|--help)      sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) echo "모르는 옵션 : $1" >&2; exit 2 ;;
   esac
done

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }
say() { [ "$STATUS" -eq 1 ] || [ "$DRY" -eq 1 ] && printf '%s\n' "$*"; return 0; }

# ---- 프로세스 확인 ---------------------------------------------------
#  ★ pgrep -f 를 그대로 쓰지 말 것. 저장소 경로에 'rcterm' 이 들어 있어
#    자기 셸과 조상까지 잡힌다 (§11.67 · §11.119). 조상을 빼고 센다.
proc_alive() {           # $1 = 확장정규식
   local pat=$1 mine=" $$ $PPID " p=$PPID i
   for i in 1 2 3 4 5 6; do
      p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
      { [ -n "$p" ] && [ "$p" != 0 ]; } || break
      mine="$mine$p "
   done
   ps_lines | while read -r pid args; do
      case "$mine" in *" $pid "*) continue ;; esac
      printf '%s\n' "$args"
   done | grep -Eq "$pat"
}

ps_lines() { if [ -n "$PS_FILE" ]; then cat "$PS_FILE" 2>/dev/null; else ps -eo pid=,args= 2>/dev/null; fi; }
is_mounted() { "$MOUNTPOINT_BIN" -q "$1" 2>/dev/null; }

hb_field() { sed -n "s/^$1=//p" "$HB" 2>/dev/null | head -1; }
#  ADC 별 계수율. ★ 순간값 sr= 을 먼저 본다 (2026-11-03 사고 : 누적 평균 ar= 은 17 시간을 7 kHz 로
#  돈 런에서 순간 41.7 kHz 에도 7.6 k 에 머물러 30 kHz 가드가 침묵했다, CLAUDE.md 11.227).
#  sr= 이 없는 옛 heartbeat 만 ar= 로 물러난다.
hb_rates() {
   sed -n 's/^daq[0-9]*=//p' "$HB" 2>/dev/null | awk '{
      v = ""; a = ""
      for (i = 1; i <= NF; i++) { if ($i ~ /^sr=/) v = substr($i, 4); if ($i ~ /^ar=/) a = substr($i, 4) }
      if (v == "") v = a
      if (v != "") print v
   }'
}
hb_rate_kind() { grep -q '^daq[0-9]*=.* sr=' "$HB" 2>/dev/null && echo "순간 sr" || echo "평균 ar"; }
hb_age()   { local t; t=$(stat -c %Y "$HB" 2>/dev/null) || return 1
             echo $(( $(date +%s) - ${t:-0} )); }

# ---- 상태 파일 -------------------------------------------------------
st_get() { [ -r "$STATE" ] && sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -1; }
st_set() {                                  # 키=값 을 갈아끼운다
   local k=$1 v=$2 tmp
   tmp=$(mktemp "${STATE}.XXXXXX" 2>/dev/null) || return 0
   { [ -r "$STATE" ] && grep -v "^$k=" "$STATE" 2>/dev/null; echo "$k=$v"; } > "$tmp" 2>/dev/null
   mv -f "$tmp" "$STATE" 2>/dev/null || rm -f "$tmp"
}

# ---- warmup (벽시계 + daqtime) ---------------------------------------
#  ★ warmup 은 daqtime 만으로 재지 않는다 (2026-11-08 run 4441~4445 : 사건이 0 인 런은 DAQ 의
#    경과시간(QUERYTRGINFO m2)도 0 에 머물러 daqtime=0 -> 5 시간 동안 영원히 warmup 으로 읽혀
#    rate_low 도 런 교체 판정도 돌지 않았다). 런 번호를 처음 본 시각을 상태 파일에 남기고
#    (run_first_seen=<run> <epoch>), daqtime 과 벽시계 중 하나라도 WARMUP 을 넘으면 판정한다.
RUN_SEEN=""
note_run_seen() {
   local cur pr pt now
   cur=$(hb_field run); case "$cur" in ''|*[!0-9]*) RUN_SEEN=""; return 0 ;; esac
   now=$(date +%s)
   read -r pr pt <<< "$(st_get run_first_seen)"
   if [ "${pr:-}" = "$cur" ] && [ -n "${pt:-}" ]; then RUN_SEEN=$pt; return 0; fi
   RUN_SEEN=$now
   [ "$DRY" -eq 1 ] || st_set run_first_seen "$cur $now"
   return 0
}
warm_enough() {
   local d; d=$(hb_field daqtime)
   awk -v d="${d:-0}" -v w="$WARMUP" 'BEGIN{ exit !(d+0 >= w+0) }' && return 0
   [ -n "$RUN_SEEN" ] || return 1
   [ $(( $(date +%s) - RUN_SEEN )) -ge "$WARMUP" ]
}

# ---- 운용 중인가 -----------------------------------------------------
#  tmux 세션도 없고 감시자도 없으면 사람이 일부러 세운 것이다. 조용히 있는다.
gate_on() {
   case "$GATE" in on) return 0 ;; off) return 1 ;; esac
   "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null && return 0
   "$PGREP_BIN" -x rcsupervisor >/dev/null 2>&1 && return 0
   return 1
}

# =====================================================================
#  점검
# =====================================================================
DOWN=""       # chain_down 사유
RATE_MSG=""   # rate_low 사유
HIGH_MSG=""   # rate_high 사유
WARN_MSG=""   # 20,000 이상 경고 문구 (알림 없음)

check_chain() {
   local miss=""
   is_mounted "$NFS_ROOT" || miss="$miss $NFS_ROOT(마운트 안 됨)"
   proc_alive 'scripts/postrun\.sh'  || miss="$miss postrun(없음)"
   proc_alive 'scripts/dataflow\.sh' || miss="$miss dataflow(없음)"
   DOWN=$(printf '%s' "$miss" | sed 's/^ //')
   [ -z "$DOWN" ]
}

check_rate() {
   local age phase minrate
   in_standby && { RATE_MSG=""; return 0; }          # 감시자 대기 중 -- 수집 중이 아니다
   age=$(hb_age) || { RATE_MSG=""; return 0; }          # heartbeat 없음 -> 판정 안 함
   [ "$age" -le "$HB_MAX_AGE" ] || { RATE_MSG=""; return 0; }   # 수집 중이 아니다
   phase=$(hb_field phase)
   [ "$phase" = "running" ] || { RATE_MSG=""; return 0; }
   #  런이 막 떴을 때는 계수율이 0 으로 나온다. warmup 동안은 보지 않는다 (daqtime 또는 벽시계).
   warm_enough || { RATE_MSG=""; return 0; }
   #  ★ 합·평균이 아니라 ADC 별 최솟값. 한 보드만 죽으면 합은 멀쩡해 보인다.
   minrate=$(hb_rates | awk 'NR==1||$1<m{m=$1} END{ if (NR) printf "%.1f", m; }')
   [ -n "${minrate:-}" ] || { RATE_MSG=""; return 0; }
   if awk -v r="$minrate" -v m="$MINRATE" 'BEGIN{ exit !(r+0 < m+0) }'; then
      RATE_MSG="ADC 별 계수율($(hb_rate_kind)) 최솟값 ${minrate} Hz (문턱 ${MINRATE} Hz), run $(hb_field run) sub $(hb_field subrun)"
      #  모든 ADC 가 0 이면 신호가 없는 것이다 -- 보드보다 HV 를 먼저 (CLAUDE.md 11.131 · 11.225)
      if hb_rates | awk '$1+0 != 0 { nz=1 } END{ exit (NR > 0 && !nz) ? 0 : 1 }'; then
         RATE_MSG="$RATE_MSG ; ★ FADC·SADC 모두 0 Hz (daqtime=$(hb_field daqtime) totev=$(hb_field totev)) -- 신호 없음, PMT HV(GECO) 부터 볼 것 (CLAUDE.md 11.131)"
      fi
      return 1
   fi
   RATE_MSG=""; return 0
}

#  ★ 계수율 높음 (2026-09-14 사용자 지시). 합이 아니라 ADC 별 최댓값. 30,000 이상 = 이상(알람+메일), 20,000 이상 = 경고 문구
check_rate_high() {
   local age phase maxrate run sub
   HIGH_MSG=""; WARN_MSG=""
   in_standby && return 0
   age=$(hb_age) || return 0
   [ "$age" -le "$HB_MAX_AGE" ] || return 0
   phase=$(hb_field phase); [ "$phase" = "running" ] || return 0
   warm_enough || return 0
   maxrate=$(hb_rates | awk 'NR==1||$1>m{m=$1} END{ if (NR) printf "%.0f", m; }')
   [ -n "${maxrate:-}" ] || return 0
   run=$(hb_field run); sub=$(hb_field subrun)
   if awk -v r="$maxrate" -v m="$ALARMRATE" 'BEGIN{ exit !(r+0 >= m+0) }'; then
      HIGH_MSG="★ 계수율 비정상 : ADC 별 계수율($(hb_rate_kind)) 최댓값 ${maxrate} Hz 가 알람 기준 ${ALARMRATE} Hz 이상입니다 (run $run sub $sub). 잡음 트리거를 의심할 것"
      return 1
   fi
   if awk -v r="$maxrate" -v m="$WARNRATE" 'BEGIN{ exit !(r+0 >= m+0) }'; then
      WARN_MSG="경고 : 계수율이 높습니다 — ADC 별($(hb_rate_kind)) 최댓값 ${maxrate} Hz (경고 기준 ${WARNRATE} Hz, 알람 기준 ${ALARMRATE} Hz), run $run sub $sub"
   fi
   return 0
}

# ---- 런 교체 -----------------------------------------------------------
db_q() { [ -r "$DBFILE" ] || return 1; sqlite3 -batch "$DBFILE" "$1" 2>/dev/null; }
#  runcatalog 의 stime/etime 은 epoch 가 아니라 'YYYY-MM-DD HH:MM:SS' 텍스트다 (실측 2026-09-10 --
#  이것을 몰라 첫 실전에서 정상 교체를 resumed 로 오판해 전문가 11명에게 오보를 냈다).
#  둘 다 받아 epoch 로 돌려준다. 못 읽으면 빈 문자열.
to_epoch() {
   local v=$1
   case "$v" in
      '') echo "" ;;
      *[!0-9]*) date -d "$v" +%s 2>/dev/null || echo "" ;;
      *) echo "$v" ;;
   esac
}

check_runchange() {
   local age phase daqtime cur prev ev gap detail msg p_onl p_st p_et p_n p_t c_st c_desc p_desc rate between
   in_standby && return 0
   age=$(hb_age) || return 0
   [ "$age" -le "$HB_MAX_AGE" ] || return 0
   phase=$(hb_field phase); [ "$phase" = "running" ] || return 0
   cur=$(hb_field run)
   case "$cur" in ''|*[!0-9]*) return 0 ;; esac         # 숫자가 아니면 보지 않는다
   daqtime=$(hb_field daqtime)
   #  새 런이 warmup 을 넘겨 계수율이 잡힌 뒤에 판정한다 (daqtime 또는 벽시계). 그 전에는 다음 주기로.
   warm_enough || return 0
   prev=$(st_get last_run)
   if [ -z "$prev" ]; then
      [ "$DRY" -eq 1 ] || st_set last_run "$cur"
      log "런 추적 시작 : run $cur"; say "  런 추적 시작 : run $cur"
      return 0
   fi
   [ "$cur" != "$prev" ] || return 0
   case "$prev" in *[!0-9]*) prev=0 ;; esac

   rate=$(sed -n 's/^daq[0-9]*=//p' "$HB" 2>/dev/null | tr '\n' ' ')
   ev=resumed; gap=""
   if [ -r "$DBFILE" ]; then
      p_onl=$(db_q "select onlbit from runcatalog where runnum=$prev")
      p_st=$(db_q "select stime from runcatalog where runnum=$prev")
      p_et=$(to_epoch "$(db_q "select etime from runcatalog where runnum=$prev")")
      p_st=$(to_epoch "$p_st")
      p_n=$(db_q "select nfadc from runcatalog where runnum=$prev")
      p_t=$(db_q "select tfadc from runcatalog where runnum=$prev")
      p_desc=$(db_q "select rundesc from runcatalog where runnum=$prev")
      #  ★ 수집 중인 런의 stime 은 DB 에 아직 없다 (rcterm 이 마감 때 채운다). heartbeat 의
      #    time - daqtime 이 시작 시각이다. DB 에 있으면 그것을 쓴다.
      c_st=$(to_epoch "$(db_q "select stime from runcatalog where runnum=$cur")")
      if [ -z "$c_st" ]; then
         local hbt; hbt=$(hb_field time)
         c_st=$(awk -v t="${hbt:-0}" -v d="${daqtime:-0}" 'BEGIN{ if (t>0 && d+0 > 0) printf "%d", t-d; }')
         #  daqtime 이 0 이면 (사건 0 인 런) 시작 시각을 알 수 없다 -- 처음 본 시각으로 갈음한다
         [ -z "$c_st" ] && c_st=$RUN_SEEN
      fi
      c_desc=$(db_q "select rundesc from runcatalog where runnum=$cur")
      #  ★ 사이에 다른 런 번호가 있으면(부팅 실패로 warmup 도 못 넘긴 런) 문제가 있었던 것이다.
      #    그런 런은 heartbeat 에 잠깐만 보여 last_run 에 안 잡히므로 DB 로 센다.
      between=$(db_q "select count(*) from runcatalog where runnum>$prev and runnum<$cur")
      if [ "${between:-0}" = 0 ] && [ "$p_onl" = 1 ] && [ -n "$p_et" ] && [ -n "$c_st" ]; then
         gap=$(( c_st - p_et ))
         [ "$gap" -ge 0 ] && [ "$gap" -le "$ROTATE_GAP" ] && ev=rotate
      fi
   else
      #  DB 를 못 읽으면 판정할 수 없다. 전문가 11명에게 오보를 내느니 책임자에게만.
      ev=rotate
   fi

   detail=$(mktemp "${STATE}.detail.XXXXXX" 2>/dev/null) || detail=/dev/null
   {
      if [ -r "$DBFILE" ]; then
         echo "이전 런 $prev : onlbit=${p_onl:-NULL}  시작 $( [ -n "$p_st" ] && date -d @"$p_st" '+%F %T' )  종료 $( [ -n "$p_et" ] && date -d @"$p_et" '+%F %T' || echo '(없음)')"
         [ -n "$p_st" ] && [ -n "$p_et" ] && echo "            길이 $(awk -v a="$p_st" -v b="$p_et" 'BEGIN{printf "%.2f", (b-a)/3600}') h  이벤트 ${p_n:-?}  평균 $( [ -n "$p_n" ] && [ -n "$p_t" ] && awk -v n="$p_n" -v t="$p_t" 'BEGIN{ if (t>0) printf "%.1f Hz", n/t }' )"
         echo "새 런   $cur : 시작 $( [ -n "$c_st" ] && date -d @"$c_st" '+%F %T' || echo '(DB 에 없음)')  지금 daqtime ${daqtime}s  sub $(hb_field subrun)"
         [ -n "$gap" ] && echo "간격        : ${gap} 초 (문턱 ${ROTATE_GAP} 초)"
         [ "${between:-0}" != 0 ] && echo "★ 사이에 런 ${between} 개가 더 있었다 (부팅 실패 등) : $(db_q "select group_concat(runnum||'(onlbit='||ifnull(onlbit,'NULL')||')',' ') from runcatalog where runnum>$prev and runnum<$cur")"
         if [ -n "$p_desc" ] && [ -n "$c_desc" ]; then
            [ "$p_desc" = "$c_desc" ] && echo "rundesc     : 이전 런과 같다" || echo "rundesc     : ★ 이전 런과 다르다 -> '$c_desc'"
         fi
      else
         echo "★ runcatalog DB 를 읽지 못했다 ($DBFILE). 이전 런 $prev 의 마감 상태를 알 수 없어"
         echo "  정상 교체로 간주하고 책임자에게만 보낸다. 실제로는 문제 뒤 재개일 수 있다."
         echo "새 런   $cur : 지금 daqtime ${daqtime}s  sub $(hb_field subrun)"
      fi
      echo "계수율      : $rate"
      echo "판정        : $ev"
   } > "$detail" 2>/dev/null

   case "$ev" in
      rotate)  msg="정상 런 교체 $prev -> $cur (간격 ${gap:-?}초) · $rate" ;;
      resumed) msg="문제 뒤 수집 재개 run $cur (이전 run $prev onlbit=${p_onl:-?}${gap:+, 간격 ${gap}초}) · $rate" ;;
   esac
   log "런 교체 $prev -> $cur : $ev : $msg"
   say "  런 교체 $prev -> $cur : $ev"
   if [ "$NONOTIFY" -eq 1 ] || [ "$STATUS" -eq 1 ]; then
      say "  -> 알림 생략 (--no-notify/--status)"
   elif [ "$DRY" -eq 1 ]; then
      say "  -> [DRY] $NOTIFY $ev --run $cur --msg '$msg'"
   else
      "$NOTIFY" --params "$PARAMS" "$ev" --run "$cur" --msg "$msg" --detail-file "$detail" >/dev/null 2>&1 \
         || log "WARN 알림을 보내지 못했다 ($ev)"
   fi
   [ "$DRY" -eq 1 ] || st_set last_run "$cur"
   [ "$detail" != /dev/null ] && rm -f "$detail"
   return 0
}

# ---- 알림 한 번 (handle 을 거치지 않는 새 사건들이 쓴다) ------------------
notify_ev() {            # $1=이벤트 $2=사유 [그 밖의 daq-notify 인자...]
   local ev=$1 msg=$2; shift 2
   if [ "$NONOTIFY" -eq 1 ] || [ "$STATUS" -eq 1 ]; then say "  -> 알림 생략 (--no-notify/--status)"; return 0; fi
   if [ "$DRY" -eq 1 ]; then say "  -> [DRY] $NOTIFY $ev --msg '$msg' $*"; return 0; fi
   "$NOTIFY" --params "$PARAMS" "$ev" --msg "$msg" "$@" >/dev/null 2>&1 \
      || log "WARN 알림을 보내지 못했다 ($ev)"
   return 0
}

# ---- tmux pane 되살리기 (D-3 · D-4) -------------------------------------
#  pane 은 제목의 열쇠말로 찾는다 (daq-layout.sh 와 같은 방식). 번호는 레이아웃마다 바뀐다.
pane_of() {              # $1 = 열쇠말  ->  'pane_id pane_pid'
   "$TMUX_BIN" list-panes -s -t "$SESSION" -F '#{pane_id} #{pane_pid} #{pane_title}' 2>/dev/null \
      | awk -v k="$1" 'index(substr($0, length($1) + length($2) + 3), k) { print $1, $2; exit }'
}
#  pane 의 셸이 놀고 있는가 = 앞에 도는 명령이 없다 (셸 자신이 터미널의 전경 그룹이다)
pane_idle() {
   local pid=$1 t
   if [ "$IDLE_PIDS" != unset ]; then
      case " $IDLE_PIDS " in *" $pid "*) return 0 ;; esac; return 1
   fi
   t=$(ps -o tpgid= -p "$pid" 2>/dev/null | tr -d ' ')
   [ -n "$t" ] && [ "$t" = "$pid" ]
}
#  pane 에 명령 한 줄을 친다. ★ send-keys "<명령>" Enter 는 'not in a mode' 만 내고
#    아무것도 안 칠 때가 있어 -l 로 글자를 넣고 Enter 를 따로 보낸다 (CLAUDE.md 10)
#  ★ 먼저 C-a C-k 로 줄을 비운다. 사람이 쳐 두고 Enter 를 안 친 글자가 있으면 그 뒤에 명령이
#    이어 붙는다 (리뷰 재현 : 'ran.txtecho RUN-supervisor'). 그래서 그런 글자가 보이면 아예 손대지 않는다
#    (pane_bare_prompt), 보이지 않아도 한 번 더 비운다.
PANE_LAST=""
pane_bare_prompt() {     # $1 = pane_id.  마지막 내용 줄이 맨 프롬프트면 0
   PANE_LAST=$("$TMUX_BIN" capture-pane -p -t "$1" 2>/dev/null | sed 's/[[:space:]]*$//' | grep -v '^$' | tail -1)
   [ -n "$PANE_LAST" ] && printf '%s\n' "$PANE_LAST" | grep -Eq "$PROMPT_RE"
}
pane_type() {            # $1 = pane_id  $2 = 명령
   "$TMUX_BIN" send-keys -t "$1" C-a C-k 2>/dev/null || return 1
   "$TMUX_BIN" send-keys -t "$1" -l "$2" 2>/dev/null && "$TMUX_BIN" send-keys -t "$1" Enter 2>/dev/null
}
#  pane 하나를 다시 띄운다. 결과 문구를 RESTART_MSG 에 남긴다.  $1=열쇠말(postrun|dataflow|supervisor)
revive_pane() {
   local key=$1 pp id pid cmd
   RESTART_MSG=""
   pp=$(pane_of "$key")
   [ -n "$pp" ] || { RESTART_MSG="$key pane 을 tmux 세션 $SESSION 에서 못 찾았다 -- 다시 띄우지 않았다"; return 1; }
   id=${pp% *}; pid=${pp#* }
   pane_idle "$pid" || { RESTART_MSG="$key pane($id) 에 무언가 돌고 있다 -- 손대지 않았다"; return 1; }
   pane_bare_prompt "$id" || { RESTART_MSG="$key pane($id) 의 마지막 줄이 맨 프롬프트가 아니다 (사람이 친 글자? '$(printf '%s' "$PANE_LAST" | tail -c 60)') -- 손대지 않았다"; return 1; }
   cmd=$(bash "$DAQTMUX" --print-cmd "$key" 2>/dev/null)
   [ -n "$cmd" ] || { RESTART_MSG="$key 명령 줄을 daq-tmux.sh --print-cmd 로 못 얻었다 -- 다시 띄우지 않았다"; return 1; }
   if [ "$DRY" -eq 1 ]; then RESTART_MSG="[DRY] $key pane($id) 에 쳤을 것 : $cmd"; return 0; fi
   if pane_type "$id" "$cmd"; then
      RESTART_MSG="$key 를 pane($id) 에서 다시 띄웠다 : $cmd"; log "자동 재기동 : $RESTART_MSG"; return 0
   fi
   RESTART_MSG="$key pane($id) 에 send-keys 실패"; return 1
}
#  시간당 1 회 상한.  $1 = 상태 키
restart_allowed() {
   local last now; now=$(date +%s); last=$(st_get "$1"); last=${last:-0}
   [ $(( now - last )) -ge 3600 ]
}

# ---- D-1 : 계수율 비정상 -> 감시자에 현재 런 정상 마감 요청 (SIGUSR1) ------
#  감시자는 SIGUSR1 을 받으면 지금 런을 정상 마감하고 cooldown 뒤 다시 띄운다(새 판).
#  ★ 옛 판은 SIGUSR1 을 처리하지 않아 받는 즉시 죽는다(기본 동작 = 종료). 그래서
#    /proc/<pid>/status 의 SigCgt 에 SIGUSR1(10번 = 0x200) 비트가 있을 때만 보낸다.
STOP_MSG=""
rate_stop() {
   local run pid cgt
   STOP_MSG=""
   [ "$RATE_STOP" = 1 ] || return 0
   run=$(hb_field run)
   if [ "$(st_get rate_stop_run)" = "$run" ]; then STOP_MSG="(run $run 은 이미 마감 요청을 보냈다)"; return 0; fi
   pid=$("$PGREP_BIN" -x rcsupervisor 2>/dev/null | head -1)
   [ -n "$pid" ] || { STOP_MSG="(감시자가 없어 마감 요청은 못 보냈다)"; return 0; }
   cgt=$(sed -n 's/^SigCgt:[[:space:]]*//p' "$PROC_ROOT/$pid/status" 2>/dev/null | head -1)
   case "$cgt" in ''|*[!0-9a-fA-F]*) cgt=0 ;; esac
   if [ $(( 0x$cgt & 0x200 )) -eq 0 ]; then
      STOP_MSG="(★ 감시자 pid $pid 가 SIGUSR1 을 처리하지 않는 판이라 마감 요청을 보내지 않았다 -- 보내면 감시자가 죽는다. 사람이 세울 것)"
      log "rate_stop : $STOP_MSG"; return 0
   fi
   if [ "$DRY" -eq 1 ]; then STOP_MSG="([DRY] 감시자 pid $pid 에 SIGUSR1 을 보냈을 것)"; return 0; fi
   if "$KILL_BIN" -USR1 "$pid" 2>/dev/null; then
      st_set rate_stop_run "$run"
      STOP_MSG="(감시자 pid $pid 에 SIGUSR1 = run $run 정상 마감 뒤 cooldown 재기동을 요청했다)"
   else
      STOP_MSG="(감시자 pid $pid 에 SIGUSR1 을 보내지 못했다)"
   fi
   log "rate_stop : $STOP_MSG"
   return 0
}

# ---- D-2 : 디스크 여유 ---------------------------------------------------
df_avail_gb() {
   if [ -n "$DF_FILE" ]; then awk -v p="$1" '$1 == p { print $2; exit }' "$DF_FILE" 2>/dev/null; return 0; fi
   df -BG --output=avail "$1" 2>/dev/null | awk 'NR == 2 { gsub(/G/, ""); print $1 + 0 }'
}
#  수준 0 정상 · 1 메일 문턱 아래 · 2 알람 문턱 아래.  수준이 오르면 즉시, 같으면 재알림 간격으로.
#  ★ 사건명을 경로마다 나눈다 (/Data_ssd = disk_low, /data = mid_disk_low). 같은 이름이면 둘째가
#    daq-notify 의 300 초 도배 방지에 먹힌다.
check_disk_one() {       # $1=키 $2=경로 $3=메일 문턱 GB $4=알람 문턱 GB $5=사건명
   local key=$1 root=$2 min=$3 alarm=$4 ev=$5 av lvl prev last now msg
   [ -d "$root" ] || return 0
   av=$(df_avail_gb "$root"); case "$av" in ''|*[!0-9]*) return 0 ;; esac
   lvl=0; [ "$av" -lt "$min" ] && lvl=1; [ "$av" -lt "$alarm" ] && lvl=2
   prev=$(st_get "disk_level_$key"); prev=${prev:-0}
   if [ "$lvl" -eq 0 ]; then
      [ "$prev" -gt 0 ] && { log "disk_low $root 해소됨 (여유 ${av} GB)"; say "  disk_low $root : 해소됨"; }
      [ "$DRY" -eq 1 ] || st_set "disk_level_$key" 0
      return 0
   fi
   msg="$root 여유 ${av} GB (메일 문턱 ${min} GB · 알람 문턱 ${alarm} GB)"
   [ "$lvl" -eq 2 ] && msg="★ $msg -- 곧 가득 찬다"
   say "  disk_low : $msg"
   now=$(date +%s); last=$(st_get "disk_alert_$key"); last=${last:-0}
   if [ "$lvl" -le "$prev" ] && [ $(( now - last )) -lt $(( REALERT_MIN * 60 )) ]; then
      log "disk_low 이어짐 (알림 생략, ${REALERT_MIN}분 이내) : $msg"
      return 0
   fi
   log "disk_low 알림 (수준 $lvl) : $msg"
   if [ "$lvl" -eq 2 ]; then notify_ev "$ev" "$msg" --force-alarm; else notify_ev "$ev" "$msg"; fi
   [ "$DRY" -eq 1 ] || { st_set "disk_level_$key" "$lvl"; st_set "disk_alert_$key" "$now"; }
   return 0
}
check_disk() {
   check_disk_one ssd "$SSD_ROOT" "$SSD_MIN_GB" "$SSD_ALARM_GB" disk_low
   check_disk_one mid "$MID_ROOT" "$MID_MIN_GB" "$MID_ALARM_GB" mid_disk_low
}

# ---- 감시자 대기(standby) 상태 ------------------------------------------
#  새 감시자는 대기 상태를 rcterm.hb 가 아니라 <heartbeat>.sup 에 쓴다 (time= pid= phase=standby
#  standby=<config|hardware|rate> run=…). rcterm.hb 는 직전 런 그대로라 소비자들이 붙잡지 않는다.
#  그 파일이 없으면(옛 판·과도기) rcterm.hb 의 phase=standby 도 받아들인다.
STANDBY_REASON=""; STANDBY_RUN=""; STANDBY_FROM=""
in_standby() {
   local f t ph now
   STANDBY_REASON=""; STANDBY_RUN=""; STANDBY_FROM=""
   f=${SUP_HB:-$HB.sup}; now=$(date +%s)
   if [ -e "$f" ]; then
      ph=$(sed -n 's/^phase=//p' "$f" 2>/dev/null | head -1)
      [ "$ph" = standby ] || return 1
      t=$(sed -n 's/^time=//p' "$f" 2>/dev/null | head -1)
      case "$t" in ''|*[!0-9]*) t=$(stat -c %Y "$f" 2>/dev/null || echo 0) ;; esac
      [ $(( now - t )) -le "$SUP_MAX_AGE" ] || return 1
      STANDBY_REASON=$(sed -n 's/^standby=//p' "$f" 2>/dev/null | head -1)
      STANDBY_RUN=$(sed -n 's/^run=//p' "$f" 2>/dev/null | head -1); STANDBY_FROM=$f
      return 0
   fi
   [ "$(hb_field phase)" = standby ] || return 1
   t=$(hb_age) || return 1
   [ "$t" -le "$SUP_MAX_AGE" ] || return 1
   STANDBY_REASON=$(hb_field standby); STANDBY_RUN=$(hb_field run); STANDBY_FROM=$HB
   return 0
}

# ---- D-3 : 감시자가 끝나 수집이 멎었다 ------------------------------------
#  tmux 세션은 있는데 감시자가 없고, 감시자 로그의 마지막 [SUP] 줄이
#     FATAL                      -> 감시자가 포기했다          (SUPKIND=fatal)
#     'rcsupervisor stop' 이 아님 -> stop 줄 없이 사라졌다      (SUPKIND=gone : kill -9 · OOM, §11.208)
#  ★ 사람이 세운 것('rcsupervisor stop' 으로 끝남)은 알리지 않는다. 대기(standby) 중이면 멎은 것이 아니다.
#  ★ chain_sup_restart_manual=1 이면 사람이 세운 것도 SUPKIND=manual 로 돌려 sup_autorestart 가 (멈춤 파일이 없을 때)
#    SUP_RESTART_AFTER_MIN 뒤 다시 띄운다 -- "수집은 언제나 돌아야 한다" (2026-11-05 사용자 지시). 알림은 내지 않는다 :
#    다시 뜨면 런 교체 추적이 resumed 를 낸다. 일부러 세워 두려면 touch $HOLD.
SUPDOWN=""; SUPKIND=""; SUPGONE=""
check_supervisor() {
   local last
   SUPDOWN=""; SUPKIND=""; SUPGONE=""
   "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null || return 0
   "$PGREP_BIN" -x rcsupervisor >/dev/null 2>&1 && return 0
   in_standby && return 0
   local recent
   #  마지막 감시자 세션('rcsupervisor start' 뒤)의 끝 5 줄만 본다 -- 앞 세션의 'stop requested' 가 이번 세션의 FATAL 을 가리면 안 된다 (리뷰 P2)
   recent=$(tail -n 400 "$SUPLOG" 2>/dev/null | grep -a '\[SUP\]' | awk '/rcsupervisor start/{n=0} {a[n++]=$0} END{for(i=(n>5?n-5:0);i<n;i++) print a[i]}')
   last=$(printf '%s\n' "$recent" | tail -1)
   [ -n "$last" ] || return 0
   #  사람이 TERM 을 보내면 'stop requested' -> … -> 'rcsupervisor stop' 이다. 그 사이에 죽었어도 사람이 세운 것
   if printf '%s\n' "$recent" | grep -q 'stop requested' || printf '%s\n' "$last" | grep -q 'rcsupervisor stop'; then
      [ "$SUP_RESTART_MANUAL" = 1 ] || return 0
      #  --max-cycles · --dry-run 으로 스스로 끝난 감시자는 일부러 유한하게 띄운 것(시험 런, 11.213·11.217) -- 되살리지 않는다
      printf '%s\n' "$recent" | grep -qE 'max cycles reached|dry-run: stopping' && return 0
      SUPDOWN=$last; SUPKIND=manual; return 1
   fi
   case "$last" in
      *FATAL*) SUPDOWN=$last; SUPKIND=fatal; return 1 ;;
      *)       SUPDOWN=$last; SUPKIND=gone; SUPGONE=$last; return 1 ;;
   esac
}
#  마지막 [SUP] 줄의 시각 (줄 머리 'YYYY-MM-DD HH:MM:SS') -> epoch. 못 읽으면 빈 문자열
supline_epoch() { date -d "$(printf '%s' "$1" | cut -c1-19)" +%s 2>/dev/null; }
sup_autorestart() {
   local day cnt n t age
   RESTART_MSG=""
   [ "$SUP_AUTORESTART" = 1 ] || { RESTART_MSG="자동 재기동 꺼짐 (chain_sup_autorestart=0)"; return 0; }
   [ -e "$HOLD" ] && { RESTART_MSG="멈춤 파일이 있다 ($HOLD) -- 사람이 작업 중. 다시 띄우지 않았다"; return 0; }
   t=$(supline_epoch "$SUPDOWN")
   #  ★ 감시자가 이번 부팅 전에 끝났다 = 정전·재부팅. PC 만 켜졌다고 수집을 띄우지 않는다 -- 저장소 IPv4 ·
   #    HV 망 · 보드 전원(TCB TIMEOUT) · HV 채널이 따로 복구 대상이다 (§10, §11.225). FATAL 이든 사라짐이든 알림만
   case "$BOOT_EPOCH" in ''|*[!0-9]*) ;; *)
      if [ -n "$t" ] && [ "$t" -lt "$BOOT_EPOCH" ]; then
         RESTART_MSG="감시자가 이번 부팅($(date -d @"$BOOT_EPOCH" '+%F %T')) 전에 끝났다 -- 정전·재부팅 뒤라 다시 띄우지 않는다. 저장소·HV 망·보드 전원·HV 를 확인한 뒤 사람이 띄울 것 (CLAUDE.md 10)"
         return 0
      fi ;;
   esac
   if [ -n "$t" ]; then
      age=$(( $(date +%s) - t ))
      [ "$age" -ge $(( SUP_RESTART_AFTER_MIN * 60 )) ] || { RESTART_MSG="감시자가 끝난 지 $(( age / 60 ))분 -- ${SUP_RESTART_AFTER_MIN}분이 지나야 다시 띄운다 (사람이 손대는 중일 수 있다)"; return 0; }
   fi
   restart_allowed autorestart_supervisor || { RESTART_MSG="자동 재기동은 시간당 1 회 -- 이번에는 하지 않았다"; return 0; }
   day=$(date +%Y%m%d); cnt=$(st_get autorestart_supervisor_day)
   case "$cnt" in "$day":*) n=${cnt#*:} ;; *) n=0 ;; esac
   [ "$n" -lt "$SUP_RESTART_DAILY" ] || { RESTART_MSG="★ 오늘 자동 재기동을 이미 ${n} 회 했다 (상한 ${SUP_RESTART_DAILY}) -- 사람이 볼 것"; return 0; }
   [ -r "$RCTERM_PARAMS" ] || { RESTART_MSG="rcterm.params 가 없다 ($RCTERM_PARAMS) -- 다시 띄우지 않았다"; return 0; }
   local p
   for p in rcterm daq tcb merger; do
      "$PGREP_BIN" -x "$p" >/dev/null 2>&1 && { RESTART_MSG="$p 가 아직 살아 있다 (고아) -- scripts/killdaq.sh -b <bindir> 로 치운 뒤 사람이 띄울 것"; return 0; }
   done
   if revive_pane supervisor && [ "$DRY" -eq 0 ]; then
      st_set autorestart_supervisor "$(date +%s)"; st_set autorestart_supervisor_day "$day:$(( n + 1 ))"
   fi
   return 0
}

# ---- D-4 : 죽은 postrun · dataflow 를 다시 띄운다 ---------------------------
#  ★ postrun 은 /scratch 가 빠져 있으면 띄우지 않는다 (그 로그가 /scratch 밑이다).
#    dataflow 는 /scratch 와 무관하게 띄운다 -- 자체 마운트 가드(1·3 단계)가 있고 SSD 를 비우는 유일한 길이다.
NFS_HINT="★ /scratch 가 안 붙으면 저장소 서버에서 10.0.0.11 로 잘못 설정된 이더넷(카드) 프로파일을 지워 달라고 요청할 것 (CLAUDE.md 10, 11.225)"
CHAIN_RESTART=""
chain_autorestart() {
   local comp out=""
   CHAIN_RESTART=""
   [ "$AUTORESTART" = 1 ] || return 0
   for comp in postrun dataflow; do
      case " $DOWN " in *" $comp(없음)"*) ;; *) continue ;; esac
      [ -e "$HOLD" ] && { out="$out; $comp 는 멈춤 파일($HOLD)이 있어 다시 띄우지 않았다"; continue; }
      if [ "$comp" = postrun ] && ! is_mounted "$NFS_ROOT"; then out="$out; $comp 는 $NFS_ROOT 가 빠져 있어 다시 띄우지 않았다"; continue; fi
      restart_allowed "autorestart_$comp" || { out="$out; $comp 자동 재기동은 시간당 1 회"; continue; }
      if revive_pane "$comp"; then
         [ "$DRY" -eq 1 ] || st_set "autorestart_$comp" "$(date +%s)"
      fi
      out="$out; $RESTART_MSG"
   done
   CHAIN_RESTART=${out#; }
   return 0
}

# ---- 비정상 런 꼬리 자동 마감 -------------------------------------------
#  판정(읽기 전용)과 처리는 tailfinish.sh 가 한다. 대상이 있으면 그것이 스스로 뒤에서
#  일꾼을 띄우고 곧 돌아오므로 chainwatch 회차가 늘어지지 않는다. 멈춤 파일도 그쪽이 본다.
tail_kick() {
   [ "$TAIL_FINISH" = 1 ] || return 0
   [ -x "$TAILFINISH" ] || { log "WARN tailfinish 를 실행할 수 없다 ($TAILFINISH)"; return 0; }
   if [ "$DRY" -eq 1 ]; then
      say "  꼬리 마감 (tailfinish --dry-run) :"
      "$TAILFINISH" --params "$PARAMS" --dry-run 2>&1 | sed 's/^/    /'
      return 0
   fi
   #  ★ 9>&- : 우리 잠금(fd 9)을 물려주지 않는다. 뒤에 뜨는 일꾼이 그것을 쥐면 다음 회차들이
   #    '이미 실행 중' 으로 빠진다 -- 옛 dataflow 의 고아 rsync 가 그랬다 (CLAUDE.md 11.228)
   "$TAILFINISH" --params "$PARAMS" >/dev/null 2>&1 9>&- || log "WARN tailfinish rc=$?"
   return 0
}

# ---- 한 조건을 처리한다 ----------------------------------------------
#  연속 CONSEC 회여야 알리고, 이어지는 동안은 REALERT_MIN 간격으로만 알린다.
handle() {               # $1=이벤트  $2=이상이면 1  $3=사유  [$4=연속 문턱 (기본 CONSEC)]
   local ev=$1 bad=$2 msg=$3 n now last consec=${4:-$CONSEC}
   now=$(date +%s)
   n=$(st_get "fail_$ev"); n=${n:-0}
   if [ "$bad" -eq 0 ]; then
      if [ "$n" -gt 0 ]; then
         log "$ev 해소됨 (연속 $n 회 뒤)"
         say "  $ev : 해소됨"
      fi
      st_set "fail_$ev" 0
      return 0
   fi
   n=$(( n + 1 )); st_set "fail_$ev" "$n"
   say "  $ev : 이상 (연속 $n/$consec) - $msg"
   [ "$n" -ge "$consec" ] || { log "$ev 이상 $n/$consec : $msg"; return 0; }
   last=$(st_get "alert_$ev"); last=${last:-0}
   if [ $(( now - last )) -lt $(( REALERT_MIN * 60 )) ]; then
      log "$ev 이상 (알림 생략, ${REALERT_MIN}분 이내) : $msg"
      return 0
   fi
   log "$ev 알림 : $msg"
   if [ "$NONOTIFY" -eq 1 ] || [ "$STATUS" -eq 1 ]; then
      say "  -> 알림 생략 (--no-notify/--status)"
   elif [ "$DRY" -eq 1 ]; then
      say "  -> [DRY] $NOTIFY $ev --msg '$msg'"
   else
      "$NOTIFY" --params "$PARAMS" "$ev" --msg "$msg" >/dev/null 2>&1 \
         || log "WARN 알림을 보내지 못했다 ($ev)"
      st_set "alert_$ev" "$now"
   fi
   [ "$DRY" -eq 1 ] && st_set "alert_$ev" "$now"
   return 0
}

# =====================================================================
main() {
   if ! gate_on; then
      say "운용 중이 아니다 (tmux 세션 daq 도 없고 감시자도 없다). 점검하지 않는다."
      #  세워 둔 동안 카운터가 남아 있으면 다음 기동 때 곧바로 알림이 나간다.
      st_set fail_chain_down 0; st_set fail_rate_low 0; st_set fail_rate_high 0; st_set fail_supervisor_down 0
      return 0
   fi
   say "운용 중 (gate on).  heartbeat=$HB"

   check_chain; local c=$? cmsg n
   cmsg="후처리 사슬이 끊겼다 :${DOWN:+ }$DOWN"
   if [ "$c" -ne 0 ]; then
      n=$(st_get fail_chain_down); n=${n:-0}
      #  연속 문턱에 닿았을 때만 다시 띄운다 (handle 이 알리는 그 회차)
      if [ $(( n + 1 )) -ge "$CONSEC" ]; then
         chain_autorestart
         [ -n "$CHAIN_RESTART" ] && cmsg="$cmsg ; 자동 재기동 : $CHAIN_RESTART"
      fi
      is_mounted "$NFS_ROOT" || cmsg="$cmsg ; $NFS_HINT"
   fi
   handle chain_down "$c" "$cmsg"

   check_supervisor; local sd=$?
   if [ "$sd" -ne 0 ] && [ "$SUPKIND" = manual ]; then
      #  사람이 세운 감시자 : 사건이 아니다. 재기동만 하고(상한·멈춤 파일·30 분 유예는 sup_autorestart 그대로) 로그는 사유가 바뀔 때만
      sup_autorestart
      local mm="감시자 없음 (사람이 세웠다, chain_sup_restart_manual=1) -- 자동 재기동 : ${RESTART_MSG:-다시 띄웠다 (supervisor pane)}"
      if [ "$(st_get manual_restart_msg)" != "$mm" ]; then log "$mm"; [ "$DRY" -eq 1 ] || st_set manual_restart_msg "$mm"; fi
      say "  supervisor : $mm"
      #  하루 상한에 닿아 못 띄우면 조용히 멎은 채 남는다 -- 그때는 한 번 알린다 (리뷰 지적 2)
      case "$RESTART_MSG" in *'오늘 자동 재기동을 이미'*) handle supervisor_down 1 "감시자가 서 있고 자동 재기동 상한에 닿았다 -- 사람이 볼 것 : $RESTART_MSG" 1 ;;
                             *) handle supervisor_down 0 "" ;; esac
   elif [ "$sd" -ne 0 ]; then
      sup_autorestart
      if [ "$SUPKIND" = fatal ]; then
         handle supervisor_down 1 "감시자가 FATAL 로 끝나 수집이 멎었다 : ${SUPDOWN#* \[SUP\] } ; 자동 재기동 : ${RESTART_MSG:-없음}" 1
      else
         handle supervisor_down 1 "★ 감시자가 'stop' 줄 없이 사라졌다 (kill -9 · OOM?) -- 마지막 줄 : ${SUPDOWN} ; 자동 재기동 : ${RESTART_MSG:-없음}" 1
      fi
   else
      handle supervisor_down 0 ""
   fi

   check_disk

   note_run_seen
   check_rate;  local r=$?
   handle rate_low "$r" "$RATE_MSG"

   #  ★ 비정상 기준 = 30,000 Hz 이상 (연속 조건 없이 즉시). 20,000 이상은 경고 문구만
   check_rate_high; local h=$?
   if [ -n "$WARN_MSG" ]; then log "$WARN_MSG"; say "  $WARN_MSG"; st_set warn_rate_high "$(date '+%F %T') $WARN_MSG"; else st_set warn_rate_high ""; fi
   if [ "$h" -ne 0 ]; then rate_stop; [ -n "$STOP_MSG" ] && HIGH_MSG="$HIGH_MSG $STOP_MSG"; fi
   handle rate_high "$h" "$HIGH_MSG" 1

   check_runchange
   tail_kick
   return 0
}

if [ "$STATUS" -eq 1 ]; then
   echo "chainwatch 상태  $(date '+%F %T')"
   echo "  문턱      : 계수율 하한 ${MINRATE} Hz (연속 ${CONSEC} 회) · ★ 경고 ${WARNRATE} Hz 이상 · 알람+메일 ${ALARMRATE} Hz 이상 (즉시) · warmup ${WARMUP}s · 재알림 ${REALERT_MIN}분"
   if gate_on; then echo "  운용      : 중 (gate on)"; else echo "  운용      : 아님 (gate off)"; fi
   is_mounted "$NFS_ROOT" && echo "  $NFS_ROOT  : 마운트됨" || echo "  $NFS_ROOT  : ★ 마운트 안 됨"
   proc_alive 'scripts/postrun\.sh'  && echo "  postrun   : 살아 있음" || echo "  postrun   : ★ 없음"
   proc_alive 'scripts/dataflow\.sh' && echo "  dataflow  : 살아 있음" || echo "  dataflow  : ★ 없음"
   if a=$(hb_age); then
      echo "  heartbeat : ${a}초 전 · phase=$(hb_field phase) run=$(hb_field run) sub=$(hb_field subrun)"
      echo "  계수율    : $(sed -n 's/^daq[0-9]*=//p' "$HB" 2>/dev/null | tr '\n' ' ')"
   else
      echo "  heartbeat : 파일 없음 ($HB)"
   fi
   cd=$(st_get fail_chain_down); rl=$(st_get fail_rate_low); rh=$(st_get fail_rate_high)
   echo "  연속 카운터 : chain_down=${cd:-0} rate_low=${rl:-0} rate_high=${rh:-0} supervisor_down=$(st_get fail_supervisor_down | grep . || echo 0)  (문턱 $CONSEC, rate_high·supervisor_down 은 1)"
   echo "  계수율 기준 : $(hb_rate_kind)"
   w=$(st_get warn_rate_high); [ -n "$w" ] && echo "  ★ 경고     : $w"
   echo "  런 추적     : last_run=$(st_get last_run)  처음 본 런/시각=$(st_get run_first_seen | awk '{ if ($2 != "") printf "%s %s", $1, strftime("%m-%d %H:%M:%S", $2); else print "-" }')  (교체 간격 문턱 ${ROTATE_GAP}s · DB $DBFILE · warmup 은 daqtime 또는 벽시계)"
   for d in "$SSD_ROOT:$SSD_MIN_GB:$SSD_ALARM_GB" "$MID_ROOT:$MID_MIN_GB:$MID_ALARM_GB"; do
      IFS=: read -r dr dm da <<< "$d"
      [ -d "$dr" ] && echo "  디스크      : $dr 여유 $(df_avail_gb "$dr") GB  (메일 < $dm · 알람 < $da)"
   done
   if in_standby; then echo "  감시자      : 대기 (standby=${STANDBY_REASON:-?} run=${STANDBY_RUN:-?}, $STANDBY_FROM) -- 계수율·런 교체 판정 안 함"
   elif "$PGREP_BIN" -x rcsupervisor >/dev/null 2>&1; then echo "  감시자      : 살아 있음  (rate_high 마감 요청 chain_rate_stop=$RATE_STOP)"
   else
      check_supervisor
      if [ "$SUPKIND" = fatal ]; then echo "  감시자      : ★ FATAL 로 끝났다 -- $SUPDOWN"
      elif [ "$SUPKIND" = gone ]; then echo "  감시자      : ★ 'stop' 줄 없이 사라졌다 (kill -9 · OOM?) -- 마지막 줄 : $SUPGONE"
      elif [ "$SUPKIND" = manual ]; then echo "  감시자      : 없음 (사람이 세웠다) -- chain_sup_restart_manual=1 : 멈춤 파일이 없으면 ${SUP_RESTART_AFTER_MIN}분 뒤 다시 띄운다 ($(st_get manual_restart_msg | sed 's/.*자동 재기동 : //' | grep . || echo "아직 회차 전"))"
      else echo "  감시자      : 없음 (사람이 세웠다 -- chain_sup_restart_manual=0 이라 다시 띄우지 않는다)"; fi
   fi
   [ -e "$HOLD" ] && echo "  ★ 멈춤 파일 : $HOLD -- pane 자동 재기동을 하지 않는다 (알림은 나간다)"
   echo "  꼬리 마감   : chain_tailfinish=$TAIL_FINISH  (상세 : scripts/tailfinish.sh --status)"
   echo "  자동 재기동 : postrun/dataflow chain_autorestart=$AUTORESTART · 감시자 chain_sup_autorestart=$SUP_AUTORESTART (하루 ${SUP_RESTART_DAILY} 회, 끝난 뒤 ${SUP_RESTART_AFTER_MIN}분) · 마지막 $(for k in postrun dataflow supervisor; do t=$(st_get autorestart_$k); printf '%s=%s ' $k "$( [ -n "$t" ] && date -d @"$t" '+%m-%d %H:%M' || echo -)"; done)"
   exit 0
fi

#  두 번 겹쳐 돌지 않는다 (cron 이 5분마다 부른다)
exec 9>"$LOCK" 2>/dev/null || exec 9>/dev/null
flock -n 9 2>/dev/null || { log "이미 실행 중. 건너뛴다"; exit 0; }

main
exit 0
