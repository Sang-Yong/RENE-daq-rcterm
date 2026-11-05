#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  daq-notify.sh - DAQ 사건 하나를 알람과 메일로 내보내는 단일 진입점.
#
#  사용 :
#     daq-notify.sh [--params <파일>] <이벤트> [--run N] [--msg '...']
#                   [--detail-file <파일>] [--dry-run]
#
#  이벤트 (config/notify.params 의 on_<이벤트> 가 무엇을 할지 정한다)
#     restart          런 하나가 실패해 감시자가 재시작했다
#     stale            런이 쓰기 도중 멈춰 감시자가 개입했다
#     recovered        연속 실패 뒤 usbreset 자동 복구에 성공했다
#     recovery_failed  자동 복구가 끝내 안 됐다. ★ 사람이 현장에 가야 한다
#     fatal            감시자가 포기하고 종료한다
#     backup_audit     로컬과 경희대를 대조한 결과 (scripts/backup-audit.sh)
#     sheetlog         구글시트 런 로그에 등재했다 (scripts/sheetlog-auto.sh)
#     chain_down       후처리 사슬이 끊겼다 -- /scratch·postrun·dataflow 중 하나가 없다
#     rate_low         수집은 도는데 ADC 별 계수율이 문턱 아래다 (HV 를 먼저 의심)
#     rate_high        ★ ADC 별 계수율이 30,000 Hz 이상 (잡음 트리거). 알람 + 책임자 메일 (2026-09-14 사용자 지시)
#     rotate           정상 런 교체 (이전 런 정상 마감, 간격 짧음). ★ 책임자에게만
#     resumed          문제(실패·정지) 뒤 새 런이 warmup 을 넘겨 정상 가동에 들어갔다
#                      위 넷은 scripts/chainwatch.sh 가 보낸다
#     backup_session   저장소 서버의 외장하드 백업 세션이 시작/종료됐다 (새 판인지 포함). scripts/backup-sheetlog.sh
#     websummary       런 서머리 웹 발행이 막혔다 (단계 실패·대조 불일치). tools/monitor/websummary.sh. 같은 사유로는 한 번만
#     supervisor_down  ★ 감시자가 FATAL 로 끝나 수집이 멎었다 (chainwatch). 알람 + 메일. 자동 재기동 결과를 함께 싣는다
#     disk_low         /Data_ssd 여유가 문턱 아래다 (chainwatch). 알람 문턱 아래면 --force-alarm 으로 온다
#     mid_disk_low     /data 여유가 문턱 아래다 (같은 규칙). 사건명을 나눈 것은 도배 방지(300 초)에 서로 먹히지 않게
#     standby_retry    감시자가 대기(standby) 중 재시도했다 (시간당 1 회, 하루 24 통 가능). ★ 기본은 로그만(none) --
#                      대기에 들어간 사건(fatal)은 이미 한 번 나간다. 메일로 받으려면 on_standby_retry = mail
#     net_down         바깥 망(메일·시트)이 끊겼다 (scripts/netsync.sh). 큐에 들어가 망이 돌아올 때 나간다
#     net_restored     바깥 망이 돌아왔다 -- 밀린 메일·시트를 내보낸 결과
#
#  ★ 메일이 안 나가면 버리지 않는다 (2026-11-05). /Data_ssd/LOG/MAILQ 에 mailq-send.sh 와 같은 형식으로
#    적재하고, mailq-send(cron 5분) · netsync(망 복귀 때) 가 내보낸다. netsync 가 망 단절(net=down)이라고
#    적어 두었으면 30 초 타임아웃을 기다리지 않고 곧바로 적재한다. 알람(소리)은 메일과 무관하게 먼저 울린다.
#
#  옵션 --force-alarm : 그 사건의 on_<이벤트> 가 mail 이어도 이번에는 알람까지 (disk_low 알람 문턱)
#
#  누구에게 가나 (config/notify.params 의 mail_expert_events, 2026-09-09 사용자 지시)
#     목록에 있는 사건  -> 전문가 목록 + 책임자   (문제가 생겼거나, 해결돼 다시 정상 가동)
#     그 밖의 사건      -> 책임자만               (정상 런 교체 rotate 가 대표)
#     비어 있으면 예전 규칙 : recovery_failed · fatal 만 전문가
#
#  rcsupervisor 가 이것을 부른다 :
#     rcsupervisor --notify-cmd <이 스크립트>
#
#  ★ 이 스크립트는 절대 실패로 죽지 않는다. 알림이 감시자를 끌고 내려가면
#    안 되기 때문이다. 문제가 있으면 로그에 적고 종료코드 0 으로 돌아간다.
#
#  ★ 메일 본문에 진단을 담는다. 새벽에 전화를 받은 사람이 메일만 보고
#    "가야 하는가"를 판단할 수 있어야 한다.
# ---------------------------------------------------------------------
set -u

DIR=$(cd "$(dirname "$0")/.." && pwd)
PARAMS=$DIR/config/notify.params
ALARM=$DIR/scripts/daq-alarm.sh
MAILER=$DIR/tools/notify/send_mail.py

HB=/Data/LOG/rcterm.hb
SUPLOG=/Data/LOG/rcsupervisor.log
RCLOG=/Data/LOG/rcterm.log
DAQLOG=/Data_ssd/LOG
ALARM_STATE=/Data/LOG/daq-alarm.state
MAIL_MIN_INTERVAL=300
NOTIFY_LOG=${NOTIFY_LOG:-/Data/LOG/daq-notify.log}   # 시험은 갈아끼운다 -- 운영 로그를 더럽히지 않게
NOTIFY_MAILQ=${NOTIFY_MAILQ:-/Data_ssd/LOG/MAILQ}      # 못 보낸 메일을 쌓는 곳. mailq-send.sh 가 비운다
[ -n "${NOTIFY_MAILER:-}" ] && MAILER=$NOTIFY_MAILER   # 시험용 가짜 발송기
[ -n "${NOTIFY_ALARM:-}" ] && ALARM=$NOTIFY_ALARM      # 시험용 가짜 알람
# shellcheck source=/dev/null
. "$DIR/scripts/netsync-lib.sh" 2>/dev/null || netsync_is_down() { return 1; }

declare -A ON=( [restart]=mail [stale]=mail [recovered]=mail \
                [recovery_failed]=both [fatal]=both [backup_audit]=mail \
                [sheetlog]=mail [chain_down]=mail [rate_low]=mail [rate_high]=both \
                [rotate]=mail [resumed]=mail [backup_session]=mail [websummary]=mail \
                [supervisor_down]=both [disk_low]=mail [mid_disk_low]=mail [standby_retry]=none [net_down]=mail [net_restored]=mail )
EXPERT_EVENTS="recovery_failed fatal"     # params 의 mail_expert_events 가 덮어쓴다

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$NOTIFY_LOG" 2>/dev/null; }

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
         alarm_state)        ALARM_STATE=$v ;;
         mail_min_interval)  MAIL_MIN_INTERVAL=$v ;;
         on_restart)         ON[restart]=$v ;;
         on_stale)           ON[stale]=$v ;;
         on_recovered)       ON[recovered]=$v ;;
         on_recovery_failed) ON[recovery_failed]=$v ;;
         on_fatal)           ON[fatal]=$v ;;
         on_backup_audit)    ON[backup_audit]=$v ;;
         on_sheetlog)        ON[sheetlog]=$v ;;
         on_chain_down)      ON[chain_down]=$v ;;
         on_rate_low)        ON[rate_low]=$v ;;
         on_rate_high)       ON[rate_high]=$v ;;
         on_rotate)          ON[rotate]=$v ;;
         on_resumed)         ON[resumed]=$v ;;
         on_backup_session)  ON[backup_session]=$v ;;
         on_websummary)      ON[websummary]=$v ;;
         on_supervisor_down) ON[supervisor_down]=$v ;;
         on_disk_low)        ON[disk_low]=$v ;;
         on_mid_disk_low)    ON[mid_disk_low]=$v ;;
         on_standby_retry)   ON[standby_retry]=$v ;;
         on_net_down)        ON[net_down]=$v ;;
         on_net_restored)    ON[net_restored]=$v ;;
         mail_queue)         NOTIFY_MAILQ=$v ;;
         mail_expert_events) EXPERT_EVENTS=$v ;;
         *) : ;;
      esac
   done < "$f"
}

# ---- 인자 ------------------------------------------------------------
EVENT=""; RUN=""; MSG=""; DETAIL=""; DRY=0; FORCE_ALARM=0
while [ $# -gt 0 ]; do
   case "$1" in
      --params)      PARAMS=$2; shift 2 ;;
      --run)         RUN=$2; shift 2 ;;
      --msg)         MSG=$2; shift 2 ;;
      --detail-file) DETAIL=$2; shift 2 ;;
      --dry-run)     DRY=1; shift ;;
      --force-alarm) FORCE_ALARM=1; shift ;;
      -h|--help)     sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      -*)            echo "모르는 인자 : $1" >&2; exit 0 ;;
      *)             EVENT=$1; shift ;;
   esac
done
if [ -z "$EVENT" ]; then sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0; fi
load_params "$PARAMS"
#  시험용 : 도배 방지 표식(.notify-<사건>.last)이 운영 /Data/LOG 에 남지 않게. params 보다 이긴다
[ -n "${NOTIFY_ALARM_STATE:-}" ] && ALARM_STATE=$NOTIFY_ALARM_STATE

ACT=${ON[$EVENT]:-mail}
if [ "$FORCE_ALARM" -eq 1 ]; then
   case "$ACT" in mail) ACT=both ;; none) ACT=alarm ;; esac
fi
log "event=$EVENT run=${RUN:-?} act=$ACT msg=${MSG:-}"

# ---- 도배 방지 -------------------------------------------------------
#  놓치면 안 되는 둘은 제한하지 않는다.
#  ★ 표식은 메일을 보냈거나 큐에 쌓은 뒤에만 남긴다 (throttle_mark). 예전에는 보내기 전에 남겨
#    발송이 실패해도 MAIL_MIN_INTERVAL 동안 같은 사건을 다시 시도하지 않았다.
throttle_markfile() { echo "$(dirname "$ALARM_STATE")/.notify-$EVENT.last"; }
throttled() {
   case "$EVENT" in recovery_failed|fatal) return 1 ;; esac
   local mark now last
   mark=$(throttle_markfile)
   now=$(date +%s)
   if [ -r "$mark" ]; then
      last=$(cat "$mark" 2>/dev/null || echo 0)
      if [ $(( now - ${last:-0} )) -lt "$MAIL_MIN_INTERVAL" ] 2>/dev/null; then return 0; fi
   fi
   return 1
}
throttle_mark() { date +%s > "$(throttle_markfile)" 2>/dev/null; return 0; }

#  못 보낸 메일을 mailq-send.sh 가 읽는 형식으로 쌓는다 (subject: / to: / body: / 본문).
#  .tmp 로 쓴 뒤 rename -- mailq-send 가 반쪽짜리를 집지 않게.
queue_mail() {           # $1=수신자 $2=제목 $3=본문 파일  -> 쌓은 경로를 찍는다
   local who=$1 subj=$2 body=$3 base tmp
   mkdir -p "$NOTIFY_MAILQ" 2>/dev/null || return 1
   base="$NOTIFY_MAILQ/$(date +%Y%m%d%H%M%S)-$$-$RANDOM"
   tmp="$base.tmp"
   { printf 'subject: %s\n' "$(printf '%s' "$subj" | tr '\n' ' ')"; printf 'to: %s\n' "$who"; echo "body:"
     cat "$body" 2>/dev/null; } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
   mv -f "$tmp" "$base.mail" 2>/dev/null || { rm -f "$tmp"; return 1; }
   echo "$base.mail"
}

# ---- 메일 본문 : 받는 사람이 바로 판단할 수 있게 -----------------------
build_body() {
   local f=$1
   {
      echo "사건      : $EVENT"
      [ -n "$MSG" ] && echo "내용      : $MSG"
      [ -n "$RUN" ] && echo "런        : $RUN"
      echo "시각      : $(date '+%F %T %Z')"
      echo "호스트    : $(hostname)"
      echo

      echo "== 지금 수집이 돌고 있는가 =="
      if pgrep -x rcterm >/dev/null 2>&1; then echo "rcterm    : 살아 있음"; else echo "rcterm    : 없음"; fi
      if pgrep -x rcsupervisor >/dev/null 2>&1; then echo "감시자    : 살아 있음"; else echo "감시자    : 없음"; fi
      if [ -r "$HB" ]; then
         echo "heartbeat : $(( $(date +%s) - $(stat -c %Y "$HB" 2>/dev/null || echo 0) )) 초 전"
         sed -n 's/^\(phase\|run\|subrun\|state\|daqtime\|totev\|daq[01]\)=/  &/p' "$HB" 2>/dev/null | sed 's/^  /  /'
      else
         echo "heartbeat : 파일 없음 ($HB)"
      fi
      echo

      echo "== NOTICE 보드가 USB 에 보이는가 =="
      #  셋 다 보여야 정상이다. 빠진 것이 있으면 그 보드가 문제다.
      for id in 0547:1502@FADC 0547:1501@TCB 0547:1503@SADC; do
         v=${id%@*}; n=${id#*@}
         if lsusb -d "$v" >/dev/null 2>&1; then echo "  $n ($v) : 보임"; else echo "  $n ($v) : ★ 안 보임"; fi
      done
      echo

      echo "== 최근 DAQ 로그의 USB 오류 =="
      #  LIBUSB_ERROR_IO 가 보이면 보드가 걸린 것이다 (2026-08-20 장애와 같은 모양).
      local anyerr=0
      for f2 in $(ls -1t "$DAQLOG"/FADCDAQ_*.log "$DAQLOG"/SADCDAQ_*.log 2>/dev/null | head -6); do
         local n2
         #  grep -c 는 0건일 때도 '0' 을 찍고 종료코드 1 을 낸다. '|| echo 0' 을
         #  붙이면 '0' 이 두 줄 나와 뒤의 비교가 깨진다.
         n2=$(grep -c 'LIBUSB_ERROR\|USB3Read\|ReadBCount' "$f2" 2>/dev/null)
         if [ "${n2:-0}" -gt 0 ]; then
            anyerr=1
            echo "  $(basename "$f2") : $n2 건"
            grep -m2 'LIBUSB_ERROR' "$f2" 2>/dev/null | sed 's/^/      /'
         fi
      done
      [ "$anyerr" -eq 0 ] && echo "  (없음)"
      echo

      echo "== 감시자 로그 마지막 15줄 =="
      tail -15 "$SUPLOG" 2>/dev/null | sed 's/^/  /' || echo "  (읽을 수 없음)"
      echo

      echo "== 디스크 =="
      df -h /Data_ssd /data /scratch 2>/dev/null | sed 's/^/  /'

      if [ -n "$DETAIL" ] && [ -r "$DETAIL" ]; then
         echo
         case "$EVENT" in
            rotate|resumed) echo "== 런 교체 상세 ==" ;;
            *)              echo "== 복구 시도 기록 ==" ;;
         esac
         sed 's/^/  /' "$DETAIL"
      fi

      echo
      echo "-- 무엇을 하면 되나 --"
      case "$EVENT" in
         recovery_failed)
            echo "  자동 복구(usbreset)가 실패했다. 사람이 현장에 가야 한다."
            echo "  1) tmux attach -t daq   로 화면을 본다"
            echo "  2) 수집이 멎어 있는지 확인 :  pgrep -x rcterm ; ss -ltn | grep 7809"
            echo "  3) 보드 전원을 껐다 켜거나 USB 케이블을 다시 꽂는다"
            echo "  4) 복구 절차는 저장소 CLAUDE.md 11.50 에 순서대로 있다"
            echo "  5) 알람을 끄려면 :  scripts/daq-alarm.sh --silence" ;;
         recovered)
            echo "  자동 복구에 성공해 수집이 이어지고 있다. 가지 않아도 된다."
            echo "  다만 보드가 걸리는 일이 잦아지면 보드/케이블/USB 허브를 의심할 것." ;;
         fatal)
            echo "  감시자가 종료했다. 수집이 멎어 있다."
            echo "  scripts/daq-tmux.sh --start 로 다시 세우기 전에 원인을 먼저 볼 것." ;;
         stale)
            echo "  런이 쓰기 도중 멈춰 감시자가 개입했다. 이어서 재시작할 것이다."
            echo "  반복되면 디스크와 NFS 링크를 볼 것." ;;
         restart)
            echo "  런 하나가 실패해 새 번호로 재시작했다. 한 번이면 대개 그냥 넘어간다."
            echo "  연속으로 쌓이면 자동 USB 복구가 돌고, 그것도 실패하면 다시 알린다." ;;
         backup_audit)
            echo "  로컬과 경희대 서버를 대조한 결과다. 아래 목록을 볼 것."
            echo "  '로컬에만 있다' 가 많으면 백업이 밀린 것이다 :"
            echo "     scripts/backup-trickle.sh --from <시작> --to <끝>"
            echo "  급한 상황은 아니다. 데이터는 로컬에 그대로 있다." ;;
         chain_down)
            echo "  수집은 돌고 있으나 뒤쪽 사슬이 끊겼다. 원시 데이터는 /Data_ssd 에"
            echo "  계속 쌓이므로 급히 뛰어갈 일은 아니다. 다만 며칠 두면 SSD 가 찬다."
            echo "  1) scripts/chainwatch.sh --status     무엇이 빠졌는지 한 줄로 나온다"
            echo "  2) /scratch 가 빠졌으면 저장소 서버부터 :  mountpoint /scratch"
            echo "     ping 10.0.0.10 · ssh store · ethtool -S <10G> 의 rx_unicast"
            echo "  3) 마운트한 뒤 pane 에서 다시 띄운다 :"
            echo "     postrun  : scripts/postrun.sh --follow --jobs 3 --lag 3 --rawroot /Data_ssd/RAW"
            echo "     dataflow : scripts/dataflow.sh --params config/dataflow.params --follow" ;;
         supervisor_down)
            echo "  ★ 감시자(rcsupervisor)가 FATAL 로 끝나 수집이 멎었다. chainwatch 가 pane 에서 다시 띄웠는지는 위 '내용' 의 자동 재기동 줄."
            echo "  1) 감시자 로그 마지막 줄(위)을 본다 -- 'too many consecutive failures' 면 보드를 의심 (CLAUDE.md 11.119 · 11.224)"
            echo "  2) 고아 daq/tcb 가 있으면 :  scripts/killdaq.sh -b /home/frontend/DAQ/DAQ_cup/install/bin"
            echo "  3) 손으로 띄우려면 tmux daq 의 supervisor pane 에서 scripts/daq-tmux.sh --print-cmd supervisor 가 찍는 줄"
            echo "  4) 알람을 끄려면 :  scripts/daq-alarm.sh --silence" ;;
         disk_low|mid_disk_low)
            echo "  디스크 여유가 문턱 아래다. /Data_ssd 가 차면 DAQ 가 쓰기를 못 해 멎는다."
            echo "  1) dataflow 가 도는지 :  scripts/chainwatch.sh --status  (dataflow 줄)"
            echo "  2) 무엇이 차지하나 :  du -sh /Data_ssd/RAW/* | sort -h | tail ;  scripts/dataflow.sh --params config/dataflow.params --once --dry-run"
            echo "  3) 경희대 서버의 데이터는 절대 임의로 지우지 않는다 (CLAUDE.md 8)" ;;
         net_down)
            echo "  바깥 망(smtp.gmail.com · sheets.googleapis.com)이 끊겼다. 수집·후처리는 영향이 없다."
            echo "  메일은 /Data_ssd/LOG/MAILQ 에 쌓였다가 망이 돌아오면 나간다. 이 메일도 그렇게 나온 것이다."
            echo "  상태 :  scripts/netsync.sh --status" ;;
         net_restored)
            echo "  바깥 망이 돌아왔다. 밀린 메일과 시트 등재를 내보냈다 (위 '내용')."
            echo "  상태 :  scripts/netsync.sh --status ;  scripts/mailq-send.sh --status" ;;
         rotate)
            echo "  정상적인 런 교체다. 할 일은 없다."
            echo "  계수율이 이전 런과 크게 다르면 그때만 볼 것 (위 '런 교체 상세')." ;;
         websummary)
            echo "  런 서머리 웹 발행(tools/monitor/websummary.sh, cron 매시 27분)이 막혔다. 같은 사유로는 한 번만 알린다."
            echo "  로그 : /Data_ssd/LOG/websummary.log   상태 : tools/monitor/websummary.sh --status"
            echo "  metrics --verify 불일치면 DIFF 줄의 livetime 을 볼 것 -- DST 쪽이 짧으면 dst-build --force, legacy 쪽이 짧으면 ibd-summary --force" ;;
         backup_session)
            echo "  저장소 서버의 외장하드 백업 세션이 바뀌었다. build=NEW 면 이탈 감지·시리얼·시트 링크가 든 판이다."
            echo "  build=OLD 면 옛 파일로 띄운 것 -- 세션을 끝내고 같은 명령으로 다시 띄우면 새 판이 된다." ;;
         resumed)
            echo "  문제(실패·정지) 뒤 새 런이 warmup 을 넘겨 정상 가동에 들어갔다."
            echo "  이전 런이 왜 끝났는지는 위 '런 교체 상세' 와 감시자 로그를 볼 것."
            echo "  이전 런의 산출물 개수 대조 :  scripts/runcheck.sh --run <이전 런>" ;;
         rate_high)
            echo "  ★ 계수율이 알람 기준(30,000 Hz)을 넘었다. 물리 사건이 아니라 잡음 트리거일 가능성이 높다."
            echo "  1) 보드 전원을 내렸다 올린 뒤라면 트리거 설정이 날아간 것이다 (실측 23,527 Hz, CLAUDE.md 11.119)"
            echo "     -> 수집을 세우고 src/NOTICE_CODE_RUN.sh 로 설정을 복원한 뒤 다시 띄운다"
            echo "  2) 아니면 SADC/FADC 문턱값이 바뀌었는지 :  설정 파일의 THR 줄과 TCB 로그의 'THR :' 를 대조"
            echo "     (설정 파일 /home/frontend/ConfigFiles/DataTaking_IBD_sykim_2026.config, 이력 docs/THRESHOLD-HISTORY.md)"
            echo "  3) HV·잡음원(조명·장비) 도 본다. 지금 값은 위 heartbeat 의 daq0/daq1 줄 (ar= 가 평균 계수율)"
            echo "  4) 알람을 끄려면 :  scripts/daq-alarm.sh --silence" ;;
         rate_low)
            echo "  ★ 보드보다 검출기를 먼저 의심할 것. 2026-09-01 에 계수가 0 이었던"
            echo "     원인은 PMT HV 였고, 보드 진단에 30분을 헛되이 썼다."
            echo "  1) HV 를 본다 (rundesc 기준 PMT_A 1680V · PMT_B 1642V)"
            echo "  2) 그 다음 보드 :  DAQ 로그의 LIBUSB 오류, TCB 로그의 DRAM 정렬"
            echo "     'Fail to align DRAM' 이 보이면 usbreset 을 두 번 걸어 볼 것"
            echo "  3) 지금 값은 위 heartbeat 의 daq0/daq1 줄에 있다 (ar= 가 평균 계수율)" ;;
      esac
   } > "$f" 2>/dev/null
}

# ---- 알람 ------------------------------------------------------------
case "$ACT" in
   alarm|both)
      if [ "$DRY" -eq 1 ]; then
         echo "[DRY] 알람 : $EVENT ${MSG:-}"
      else
         "$ALARM" --params "$PARAMS" --raise "$EVENT : ${MSG:-DAQ 이상}" >/dev/null 2>&1 \
            || log "WARN 알람을 켜지 못했다"
      fi ;;
esac

# ---- 메일 ------------------------------------------------------------
case "$ACT" in
   mail|both)
      if throttled; then
         log "메일 생략 (도배 방지, ${MAIL_MIN_INTERVAL}초 이내 같은 사건)"
         exit 0
      fi
      #  전문가 목록에는 책임자가 없으므로 'both' 로 보낸다 (send_mail.py 가 합친다).
      #  params 에 목록이 없으면 예전 규칙(recovery_failed·fatal 만 expert) 그대로.
      WHO=routine
      if [ "$EXPERT_EVENTS" = "recovery_failed fatal" ]; then
         case "$EVENT" in recovery_failed|fatal) WHO=expert ;; esac
      else
         case " $EXPERT_EVENTS " in *" $EVENT "*) WHO=both ;; esac
      fi
      BODY=$(mktemp /tmp/daq-notify-XXXXXX.txt) || exit 0
      build_body "$BODY"
      SUBJ="$EVENT"
      [ -n "$RUN" ] && SUBJ="$SUBJ run $RUN"
      [ -n "$MSG" ] && SUBJ="$SUBJ - $MSG"
      if [ "$DRY" -eq 1 ]; then
         echo "[DRY] 메일 -> $WHO : $SUBJ"; echo "--- 본문 ---"; cat "$BODY"
      elif netsync_is_down; then
         #  망이 끊긴 것을 이미 안다. 30 초 타임아웃을 기다리지 않고 곧바로 쌓는다.
         if q=$(queue_mail "$WHO" "$SUBJ" "$BODY"); then
            log "mail queued (net=down) -> $q"; throttle_mark
         else
            log "WARN 망 단절인데 큐에도 못 쌓았다 ($NOTIFY_MAILQ)"
         fi
      else
         out=$(python3 "$MAILER" --params "$PARAMS" --to "$WHO" \
                  --subject "$SUBJ" --body-file "$BODY" 2>&1)
         rc=$?
         log "mail rc=$rc $out"
         if [ $rc -eq 0 ]; then
            throttle_mark
         else
            echo "daq-notify: 메일 실패 -> $out" >&2
            #  설정을 못 읽거나(2) 필수값이 없으면(3) 몇 번을 다시 해도 안 나간다 -- 쌓지 않는다.
            #  망(5) · 인증(4) · 그 밖은 쌓는다. mailq-send 가 망 복귀 뒤 다시 보낸다.
            case "$rc" in
               2|3) : ;;
               *) if q=$(queue_mail "$WHO" "$SUBJ" "$BODY"); then
                     log "mail queued (rc=$rc) -> $q"; throttle_mark
                  else
                     log "WARN 큐에도 못 쌓았다 ($NOTIFY_MAILQ)"
                  fi ;;
            esac
         fi
      fi
      rm -f "$BODY" ;;
esac

exit 0
