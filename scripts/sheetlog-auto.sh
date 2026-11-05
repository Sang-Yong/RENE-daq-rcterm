#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  sheetlog-auto.sh - 구글시트 런 로그를 자동으로 등재한다.
#
#  사용 :
#     sheetlog-auto.sh [--threshold N] [--interval-hours H]
#                      [--dry-run] [--force] [--status] [--no-notify]
#
#  언제 쓰는가 (둘 중 하나라도 참이면)
#     1) 밀린 런이 --threshold(기본 5) 개 이상이다        -> 즉시
#     2) 마지막 등재로부터 --interval-hours(기본 24) 시간  -> 하루 한 번
#  쓸 때마다 daq-notify.sh 로 알린다.
#
#  ★ 완결 게이트 -- 이 스크립트의 핵심이다.
#    후처리가 덜 끝난 런을 쓰면 PRD 용량이 모자란 채로 박히고,
#    시트의 기존 행은 고칠 수 없으므로 영영 틀린 값이 남는다.
#    그래서 FADC 개수 == PRD 개수 인 런까지만 쓰고, 그 뒤는 다음으로 미룬다.
#    (badrun 격리분은 하위 폴더라 최상위 개수에서 빠진다 -- §5.9)
#
#  ★ 실패 메일은 같은 사유로 한 번만 (2026-11-05). 예전에는 매시 실패할 때마다 메일이 나갔다
#    (2026-10-16 시트 그리드가 차서 20 시간 동안 매시, §11.220). 사유가 바뀌거나 한 번 성공하면 다시 알린다.
#  ★ netsync.sh 가 망 단절(net=down)이라고 적어 두었으면 시도 자체를 건너뛴다 (로그만).
#    망이 돌아오면 netsync 가 이것을 --force 로 부른다.
#
#  ★ 기존 행은 절대 건드리지 않는다. append_runs.py 가 마지막 Run 행
#    아래에 무엇이든 있으면 스스로 멈춘다.
#
#  cron 예 (매시 07분에 점검, 조건이 맞을 때만 쓴다) :
#     7 * * * * <저장소>/scripts/sheetlog-auto.sh >/dev/null 2>&1
# ---------------------------------------------------------------------
set -u

DIR=$(cd "$(dirname "$0")/.." && pwd)
#  시험은 아래를 전부 갈아끼운다 (진짜 시트·메일·운영 로그 무접촉)
TOOL=${SHEETLOG_TOOL:-$DIR/tools/sheetlog/append_runs.py}
NOTIFY=${SHEETLOG_NOTIFY:-$DIR/scripts/daq-notify.sh}
PARAMS=$DIR/config/notify.params

STATE=${SHEETLOG_STATE:-/Data_ssd/LOG/sheetlog-auto.state}
LOG=${SHEETLOG_LOG:-/Data_ssd/LOG/sheetlog-auto.log}
LOCK=${SHEETLOG_LOCK:-/Data_ssd/LOG/.sheetlog-auto.lock}
FAILSTATE=${SHEETLOG_FAILSTATE:-/Data_ssd/LOG/sheetlog-auto.failstate}
ROOTS=${SHEETLOG_ROOTS:-"/Data_ssd/RAW /data/RAW /scratch/RAW"}
# shellcheck source=/dev/null
. "$DIR/scripts/netsync-lib.sh" 2>/dev/null || netsync_is_down() { return 1; }

THRESHOLD=5
INTERVAL_H=24
DRY=0; FORCE=0; STATUS=0; NONOTIFY=0

while [ $# -gt 0 ]; do
   case "$1" in
      --threshold)      THRESHOLD=$2; shift 2 ;;
      --interval-hours) INTERVAL_H=$2; shift 2 ;;
      --params)         PARAMS=$2; shift 2 ;;
      --dry-run)        DRY=1; shift ;;
      --force)          FORCE=1; shift ;;
      --status)         STATUS=1; shift ;;
      --no-notify)      NONOTIFY=1; shift ;;
      -h|--help)        sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) echo "모르는 옵션 : $1" >&2; exit 2 ;;
   esac
done

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" ; }

# ---- 한 런이 완결됐는가 : FADC 개수 == PRD 개수 (둘 다 0 이 아님) -------
run_complete() {
   local rr=$1 d f p
   for d in $ROOTS; do
      [ -d "$d/$rr" ] || continue
      f=$(ls -U "$d/$rr"       2>/dev/null | grep -c "^FADC_$rr\.root\.")
      p=$(ls -U "$d/$rr/PRD"   2>/dev/null | grep -c '\.root$')
      [ "$f" -gt 0 ] && [ "$p" -eq "$f" ] && return 0
   done
   return 1
}

#  망이 끊긴 것을 이미 안다 -- 구글에 붙어 보지도 않는다 (--status 는 그래도 보여 준다)
if [ $STATUS -eq 0 ] && netsync_is_down; then
   log "망 단절 (netsync net=down) -- 건너뛴다. 망이 돌아오면 netsync 가 부른다"
   exit 0
fi

# ---- 상태 ------------------------------------------------------------
last_ts=0
[ -r "$STATE" ] && last_ts=$(awk -F= '$1=="last_commit"{print $2}' "$STATE" 2>/dev/null)
case "$last_ts" in ''|*[!0-9]*) last_ts=0 ;; esac
now=$(date +%s)
elapsed_h=$(( (now - last_ts) / 3600 ))

# ---- 밀린 런을 센다 (읽기 전용) --------------------------------------
preview=$(cd "$DIR" && timeout 600 python3 "$TOOL" 2>&1 | grep -v FutureWarning | grep -v 'warnings.warn')
rc=$?
if [ $rc -ne 0 ] && ! printf '%s' "$preview" | grep -q '추가 대상'; then
   log "[FAIL] 미리보기 실패 (rc=$rc)"
   printf '%s\n' "$preview" | tail -5 >> "$LOG"
   exit 1
fi

pending=$(printf '%s' "$preview" | sed -n 's/.*추가 대상 : \([0-9]\+\) 런.*/\1/p' | head -1)
case "$pending" in ''|*[!0-9]*) pending=0 ;; esac
cands=$(printf '%s' "$preview" | sed -n "s/^\['\([0-9]\+\)'.*/\1/p")

# ---- 완결 게이트 : 앞에서부터 연속으로 완결된 것까지만 ----------------
ok=0; blocked=""
for r in $cands; do
   rr=$(printf '%06d' "$r")
   if run_complete "$rr"; then ok=$((ok+1))
   else blocked="$r"; break; fi
done

if [ $STATUS -eq 1 ]; then
   echo "밀린 런        : $pending 개  [$(echo $cands | tr '\n' ' ')]"
   echo "완결돼 쓸 수 있는 것 : $ok 개"
   [ -n "$blocked" ] && echo "대기            : run $blocked 부터 (후처리 미완)"
   echo "마지막 등재     : $( [ "$last_ts" -gt 0 ] && date -d "@$last_ts" '+%F %T' || echo '기록 없음' )  (${elapsed_h}시간 전)"
   echo "문턱 / 주기     : $THRESHOLD 개 / ${INTERVAL_H}시간"
   exit 0
fi

if [ "$pending" -eq 0 ]; then log "밀린 런 없음"; exit 0; fi
if [ "$ok" -eq 0 ]; then
   log "밀린 런 $pending 개이나 후처리 미완 (run $blocked 부터). 미룬다"
   exit 0
fi

# ---- 쓸 것인가 --------------------------------------------------------
reason=""
if [ $FORCE -eq 1 ];                       then reason="--force"
elif [ "$ok" -ge "$THRESHOLD" ];           then reason="밀린 런 $ok 개 (문턱 $THRESHOLD)"
elif [ "$elapsed_h" -ge "$INTERVAL_H" ];   then reason="일일 등재 (${elapsed_h}시간 경과)"
else
   log "대기 : 완결 $ok 개 < 문턱 $THRESHOLD, 경과 ${elapsed_h}h < ${INTERVAL_H}h"
   exit 0
fi

if [ $DRY -eq 1 ]; then
   log "[DRY] 등재했을 것 : $ok 런 ($reason)"
   printf '%s\n' "$preview" | grep '^\[' | head -20
   exit 0
fi

# ---- 쓴다 (겹치지 않게) ----------------------------------------------
exec 9>"$LOCK" 2>/dev/null
if ! flock -n 9; then log "다른 인스턴스가 돌고 있다. 건너뛴다"; exit 0; fi

out=$(cd "$DIR" && timeout 900 python3 "$TOOL" --limit "$ok" --commit 2>&1 \
      | grep -v FutureWarning | grep -v 'warnings.warn')
wrote=$(printf '%s' "$out" | sed -n 's/.*기록함 : \(.*\)/\1/p' | head -1)

DETAIL=$(mktemp /tmp/sheetlog-detail.XXXXXX)
{
   echo "사유    : $reason"
   echo "등재 런 : $(printf '%s' "$cands" | head -n "$ok" | tr '\n' ' ')"
   [ -n "$blocked" ] && echo "미룬 것 : run $blocked 이후 (후처리 미완)"
   echo
   printf '%s\n' "$out"
} > "$DETAIL"

send_mail=1
if [ -n "$wrote" ]; then
   printf 'last_commit=%s\n' "$now" > "$STATE"
   log "[OK] 등재 $ok 런 -> $wrote  ($reason)"
   msg="시트에 $ok 런 등재 -- $wrote"
   rm -f "$FAILSTATE" 2>/dev/null          # 다음 실패는 다시 알린다
else
   log "[FAIL] 등재 실패 ($reason)"
   printf '%s\n' "$out" | tail -5 >> "$LOG"
   msg="시트 등재 실패 -- 로그를 볼 것 : $LOG"
   #  사유 서명 = 출력 마지막 줄에서 숫자를 지운 것 (행 번호·시각이 바뀌어도 같은 사유로 본다)
   sig=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1 | tr -d '0-9' | md5sum | cut -c1-12)
   if [ "$(cat "$FAILSTATE" 2>/dev/null)" = "$sig" ]; then
      send_mail=0
      log "같은 사유의 실패라 메일은 생략 (첫 실패 때 이미 알렸다, $FAILSTATE)"
   else
      printf '%s\n' "$sig" > "$FAILSTATE" 2>/dev/null
   fi
fi

if [ $NONOTIFY -eq 0 ] && [ $send_mail -eq 1 ] && [ -x "$NOTIFY" ]; then
   "$NOTIFY" --params "$PARAMS" sheetlog --msg "$msg" --detail-file "$DETAIL" >/dev/null 2>&1
fi
rm -f "$DETAIL"
[ -n "$wrote" ]
