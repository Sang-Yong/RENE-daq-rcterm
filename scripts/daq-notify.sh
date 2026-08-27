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
NOTIFY_LOG=/Data/LOG/daq-notify.log

declare -A ON=( [restart]=mail [stale]=mail [recovered]=mail \
                [recovery_failed]=both [fatal]=both [backup_audit]=mail \
                [sheetlog]=mail )

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
         *) : ;;
      esac
   done < "$f"
}

# ---- 인자 ------------------------------------------------------------
EVENT=""; RUN=""; MSG=""; DETAIL=""; DRY=0
while [ $# -gt 0 ]; do
   case "$1" in
      --params)      PARAMS=$2; shift 2 ;;
      --run)         RUN=$2; shift 2 ;;
      --msg)         MSG=$2; shift 2 ;;
      --detail-file) DETAIL=$2; shift 2 ;;
      --dry-run)     DRY=1; shift ;;
      -h|--help)     sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      -*)            echo "모르는 인자 : $1" >&2; exit 0 ;;
      *)             EVENT=$1; shift ;;
   esac
done
if [ -z "$EVENT" ]; then sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0; fi
load_params "$PARAMS"

ACT=${ON[$EVENT]:-mail}
log "event=$EVENT run=${RUN:-?} act=$ACT msg=${MSG:-}"

# ---- 도배 방지 -------------------------------------------------------
#  놓치면 안 되는 둘은 제한하지 않는다.
throttled() {
   case "$EVENT" in recovery_failed|fatal) return 1 ;; esac
   local mark now last
   mark=$(dirname "$ALARM_STATE")/.notify-$EVENT.last
   now=$(date +%s)
   if [ -r "$mark" ]; then
      last=$(cat "$mark" 2>/dev/null || echo 0)
      if [ $(( now - ${last:-0} )) -lt "$MAIL_MIN_INTERVAL" ] 2>/dev/null; then return 0; fi
   fi
   echo "$now" > "$mark" 2>/dev/null
   return 1
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
         echo "== 복구 시도 기록 =="
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
      WHO=routine
      case "$EVENT" in recovery_failed|fatal) WHO=expert ;; esac
      BODY=$(mktemp /tmp/daq-notify-XXXXXX.txt) || exit 0
      build_body "$BODY"
      SUBJ="$EVENT"
      [ -n "$RUN" ] && SUBJ="$SUBJ run $RUN"
      [ -n "$MSG" ] && SUBJ="$SUBJ - $MSG"
      if [ "$DRY" -eq 1 ]; then
         echo "[DRY] 메일 -> $WHO : $SUBJ"; echo "--- 본문 ---"; cat "$BODY"
      else
         out=$(python3 "$MAILER" --params "$PARAMS" --to "$WHO" \
                  --subject "$SUBJ" --body-file "$BODY" 2>&1)
         rc=$?
         log "mail rc=$rc $out"
         [ $rc -ne 0 ] && echo "daq-notify: 메일 실패 -> $out" >&2
      fi
      rm -f "$BODY" ;;
esac

exit 0
