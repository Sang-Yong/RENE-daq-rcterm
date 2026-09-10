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

STATE=/Data_ssd/LOG/chainwatch.state
LOG=/Data_ssd/LOG/chainwatch.log
LOCK=/Data_ssd/LOG/.chainwatch.lock

HB=/Data/LOG/rcterm.hb
NFS_ROOT=/scratch
MINRATE=400          # ADC 별 계수율 최솟값의 문턱 [Hz]. 정상은 약 1000
CONSEC=2             # 이만큼 연속으로 이상이어야 알린다 (일시적 흔들림 무시)
WARMUP=180           # 런 시작 후 이 시간[초] 안에는 계수율을 판정하지 않는다
REALERT_MIN=60       # 이상이 이어질 때 다시 알리는 간격 [분]
HB_MAX_AGE=120       # heartbeat 가 이보다 오래되면 '수집 중이 아니다'
DBFILE=/Data_ssd/runcatalog.db   # 런 교체 판정에 이전 런의 onlbit·etime 을 읽는다
ROTATE_GAP=600       # 이전 런 종료 -> 새 런 시작 간격이 이보다 길면 '사람이 세웠다 올린 것'
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
         chain_consecutive)  CONSEC=$v ;;
         chain_warmup_sec)   WARMUP=$v ;;
         chain_realert_min)  REALERT_MIN=$v ;;
         chain_hb_max_age)   HB_MAX_AGE=$v ;;
         chain_dbfile)       DBFILE=$v ;;
         chain_rotate_gap_sec) ROTATE_GAP=$v ;;
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
   ps -eo pid=,args= 2>/dev/null | while read -r pid args; do
      case "$mine" in *" $pid "*) continue ;; esac
      printf '%s\n' "$args"
   done | grep -Eq "$pat"
}

hb_field() { sed -n "s/^$1=//p" "$HB" 2>/dev/null | head -1; }
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

# ---- 운용 중인가 -----------------------------------------------------
#  tmux 세션도 없고 감시자도 없으면 사람이 일부러 세운 것이다. 조용히 있는다.
gate_on() {
   case "$GATE" in on) return 0 ;; off) return 1 ;; esac
   tmux has-session -t daq 2>/dev/null && return 0
   pgrep -x rcsupervisor >/dev/null 2>&1 && return 0
   return 1
}

# =====================================================================
#  점검
# =====================================================================
DOWN=""       # chain_down 사유
RATE_MSG=""   # rate_low 사유

check_chain() {
   local miss=""
   mountpoint -q "$NFS_ROOT" 2>/dev/null || miss="$miss $NFS_ROOT(마운트 안 됨)"
   proc_alive 'scripts/postrun\.sh'  || miss="$miss postrun(없음)"
   proc_alive 'scripts/dataflow\.sh' || miss="$miss dataflow(없음)"
   DOWN=$(printf '%s' "$miss" | sed 's/^ //')
   [ -z "$DOWN" ]
}

check_rate() {
   local age phase daqtime minrate
   age=$(hb_age) || { RATE_MSG=""; return 0; }          # heartbeat 없음 -> 판정 안 함
   [ "$age" -le "$HB_MAX_AGE" ] || { RATE_MSG=""; return 0; }   # 수집 중이 아니다
   phase=$(hb_field phase)
   [ "$phase" = "running" ] || { RATE_MSG=""; return 0; }
   daqtime=$(hb_field daqtime)
   #  런이 막 떴을 때는 계수율이 0 으로 나온다. warmup 동안은 보지 않는다.
   awk -v d="${daqtime:-0}" -v w="$WARMUP" 'BEGIN{ exit !(d+0 >= w+0) }' \
      || { RATE_MSG=""; return 0; }
   #  ★ 합·평균이 아니라 ADC 별 최솟값. 한 보드만 죽으면 합은 멀쩡해 보인다.
   minrate=$(sed -n 's/.* ar=\([0-9.]*\).*/\1/p' "$HB" 2>/dev/null \
             | awk 'NR==1||$1<m{m=$1} END{ if (NR) printf "%.1f", m; }')
   [ -n "${minrate:-}" ] || { RATE_MSG=""; return 0; }
   if awk -v r="$minrate" -v m="$MINRATE" 'BEGIN{ exit !(r+0 < m+0) }'; then
      RATE_MSG="ADC 별 계수율 최솟값 ${minrate} Hz (문턱 ${MINRATE} Hz), run $(hb_field run) sub $(hb_field subrun)"
      return 1
   fi
   RATE_MSG=""; return 0
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
   age=$(hb_age) || return 0
   [ "$age" -le "$HB_MAX_AGE" ] || return 0
   phase=$(hb_field phase); [ "$phase" = "running" ] || return 0
   cur=$(hb_field run)
   case "$cur" in ''|*[!0-9]*) return 0 ;; esac         # 숫자가 아니면 보지 않는다
   daqtime=$(hb_field daqtime)
   #  새 런이 warmup 을 넘겨 계수율이 잡힌 뒤에 판정한다. 그 전에는 다음 주기로.
   awk -v d="${daqtime:-0}" -v w="$WARMUP" 'BEGIN{ exit !(d+0 >= w+0) }' || return 0
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
         c_st=$(awk -v t="${hbt:-0}" -v d="${daqtime:-0}" 'BEGIN{ if (t>0) printf "%d", t-d; }')
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

# ---- 한 조건을 처리한다 ----------------------------------------------
#  연속 CONSEC 회여야 알리고, 이어지는 동안은 REALERT_MIN 간격으로만 알린다.
handle() {               # $1=이벤트  $2=이상이면 1  $3=사유
   local ev=$1 bad=$2 msg=$3 n now last
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
   say "  $ev : 이상 (연속 $n/$CONSEC) - $msg"
   [ "$n" -ge "$CONSEC" ] || { log "$ev 이상 $n/$CONSEC : $msg"; return 0; }
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
      st_set fail_chain_down 0; st_set fail_rate_low 0
      return 0
   fi
   say "운용 중 (gate on).  heartbeat=$HB"

   check_chain; local c=$?
   handle chain_down "$c" "후처리 사슬이 끊겼다 :${DOWN:+ }$DOWN"

   check_rate;  local r=$?
   handle rate_low "$r" "$RATE_MSG"

   check_runchange
   return 0
}

if [ "$STATUS" -eq 1 ]; then
   echo "chainwatch 상태  $(date '+%F %T')"
   echo "  문턱      : 계수율 ${MINRATE} Hz · 연속 ${CONSEC} 회 · warmup ${WARMUP}s · 재알림 ${REALERT_MIN}분"
   if gate_on; then echo "  운용      : 중 (gate on)"; else echo "  운용      : 아님 (gate off)"; fi
   mountpoint -q "$NFS_ROOT" 2>/dev/null && echo "  $NFS_ROOT  : 마운트됨" || echo "  $NFS_ROOT  : ★ 마운트 안 됨"
   proc_alive 'scripts/postrun\.sh'  && echo "  postrun   : 살아 있음" || echo "  postrun   : ★ 없음"
   proc_alive 'scripts/dataflow\.sh' && echo "  dataflow  : 살아 있음" || echo "  dataflow  : ★ 없음"
   if a=$(hb_age); then
      echo "  heartbeat : ${a}초 전 · phase=$(hb_field phase) run=$(hb_field run) sub=$(hb_field subrun)"
      echo "  계수율    : $(sed -n 's/^daq[0-9]*=//p' "$HB" 2>/dev/null | tr '\n' ' ')"
   else
      echo "  heartbeat : 파일 없음 ($HB)"
   fi
   cd=$(st_get fail_chain_down); rl=$(st_get fail_rate_low)
   echo "  연속 카운터 : chain_down=${cd:-0} rate_low=${rl:-0}  (문턱 $CONSEC)"
   echo "  런 추적     : last_run=$(st_get last_run)  (교체 간격 문턱 ${ROTATE_GAP}s · DB $DBFILE)"
   exit 0
fi

#  두 번 겹쳐 돌지 않는다 (cron 이 5분마다 부른다)
exec 9>"$LOCK" 2>/dev/null || exec 9>/dev/null
flock -n 9 2>/dev/null || { log "이미 실행 중. 건너뛴다"; exit 0; }

main
exit 0
