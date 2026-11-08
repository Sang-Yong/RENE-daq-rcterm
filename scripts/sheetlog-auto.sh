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
#  ★ 로컬 우선 등재 (2026-11-09 사용자 지시) : 등재 = 로컬 원장(/Data_ssd/LOG/sheetledger/Y2026B.tsv)에 적는 것.
#    append_runs.py 가 원장에 적은 뒤 시트로 민다. 망이 없으면 원장에만 적고 '[SHEET] 보류' -- 실패가 아니다.
#    회차마다 새 런을 보기 전에 원장의 pending 부터 시트로 민다 (sheet_ledger.py --flush --tab Y2026B).
#  ★ netsync.sh 가 망 단절(net=down)이라고 적어 두었으면 구글에 붙어 보지도 않고(--offline) 원장에만 등재한다.
#    망이 돌아오면 netsync 가 sheet_ledger.py --flush 와 이것을 (보통 게이트로) 부른다.
#  ★ 자율 복구 드릴 중(drill_flag, 기본 /Data_ssd/LOG/drill.active)이면 --force 여도 쓰지 않는다 ([SKIP] drill).
#    11-06 09:35 망 복귀 때 드릴 시험 런 4435·4436 이 GoodRuns 에 실렸다. 드릴은 끝날 때 그 런들을 onlbit=0 으로 뺀다.
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
LEDGER_TOOL=${SHEETLOG_LEDGER_TOOL:-$DIR/tools/sheetlog/sheet_ledger.py}
PARAMS=$DIR/config/notify.params

STATE=${SHEETLOG_STATE:-/Data_ssd/LOG/sheetlog-auto.state}
LOG=${SHEETLOG_LOG:-/Data_ssd/LOG/sheetlog-auto.log}
LOCK=${SHEETLOG_LOCK:-/Data_ssd/LOG/.sheetlog-auto.lock}
FAILSTATE=${SHEETLOG_FAILSTATE:-/Data_ssd/LOG/sheetlog-auto.failstate}
ROOTS=${SHEETLOG_ROOTS:-"/Data_ssd/RAW /data/RAW /scratch/RAW"}
# shellcheck source=/dev/null
. "$DIR/scripts/netsync-lib.sh" 2>/dev/null || netsync_is_down() { return 1; }
type drill_active >/dev/null 2>&1 || { drill_active() { return 1; }; drill_flag_param() { :; }; }

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

[ -r "$PARAMS" ] && drill_flag_param "$(sed -n 's/^[[:space:]]*drill_flag[[:space:]]*=[[:space:]]*//p' "$PARAMS" 2>/dev/null | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//' | head -1)"
#  드릴 중이면 쓰지 않는다 (--force · --dry-run 도). --status 는 그래도 보여 준다
if [ $STATUS -eq 0 ] && drill_active; then
   log "[SKIP] drill -- 자율 복구 드릴 중 (pid $(drill_flag_get pid), $DRILL_FLAG). 드릴 시험 런을 싣지 않는다"
   exit 0
fi

#  망이 끊긴 것을 이미 안다 -- 구글에 붙어 보지도 않고 원장에만 등재한다 (--status 는 그래도 보여 준다)
OFFLINE=0; TOOLARGS=()
if [ $STATUS -eq 0 ] && netsync_is_down; then
   OFFLINE=1; TOOLARGS=(--offline)
   log "망 단절 (netsync net=down) -- 시트에 붙지 않고 로컬 원장에만 등재한다. 망이 돌아오면 netsync 가 원장을 시트로 민다"
fi

#  ---- 시트 쪽 실패 알림 : 같은 사유는 한 번만 ------------------------------
sheet_fail_once() {   # $1 = 사유 서명 원문  -> 0 이면 알린다
   local sig; sig=$(printf '%s\n' "$1" | tr -d '0-9' | md5sum | cut -c1-12)
   if [ "$(cat "$FAILSTATE" 2>/dev/null)" = "$sig" ]; then
      log "같은 사유의 실패라 메일은 생략 (첫 실패 때 이미 알렸다, $FAILSTATE)"; return 1
   fi
   printf '%s\n' "$sig" > "$FAILSTATE" 2>/dev/null; return 0
}

#  ---- 원장 pending 을 먼저 시트로 (새 런을 보기 전에) -----------------------
if [ $STATUS -eq 0 ] && [ $DRY -eq 0 ] && [ $OFFLINE -eq 0 ] && [ -r "$LEDGER_TOOL" ]; then
   FO=$(mktemp /tmp/sheetlog-flushout.XXXXXX)
   (cd "$DIR" && timeout 600 python3 "$LEDGER_TOOL" --flush --tab Y2026B) > "$FO" 2>&1; frc=$?
   fout=$(grep -v FutureWarning "$FO" | grep -v 'warnings.warn'); rm -f "$FO"
   printf '%s\n' "$fout" | grep -E '^(\[|기록함)' | grep -v '^\[OK\] Y2026B : pending 0' | while read -r l; do log "원장 flush : $l"; done
   case "$frc" in
      0|5) : ;;                                    # 정상 · 망 없음(보류)
      *)  log "[FAIL] 원장 flush rc=$frc"
          if [ $NONOTIFY -eq 0 ] && [ -x "$NOTIFY" ] && sheet_fail_once "flush $(printf '%s\n' "$fout" | grep -v '^[[:space:]]*$' | tail -1)"; then
             FD=$(mktemp /tmp/sheetlog-flush.XXXXXX); printf '%s\n' "$fout" > "$FD"
             "$NOTIFY" --params "$PARAMS" sheetlog --msg "시트 원장 flush 실패 (rc=$frc) -- 원장의 pending 이 시트로 못 갔다. 로그 : $LOG" --detail-file "$FD" >/dev/null 2>&1
             rm -f "$FD"
          fi ;;
   esac
fi

# ---- 상태 ------------------------------------------------------------
last_ts=0
[ -r "$STATE" ] && last_ts=$(awk -F= '$1=="last_commit"{print $2}' "$STATE" 2>/dev/null)
case "$last_ts" in ''|*[!0-9]*) last_ts=0 ;; esac
now=$(date +%s)
elapsed_h=$(( (now - last_ts) / 3600 ))

# ---- 밀린 런을 센다 (읽기 전용) --------------------------------------
#  ★ 종료코드는 python 의 것을 본다. 예전에는 '$(… | grep -v …); rc=$?' 라 grep 의 0 을 받아, 원장이 없고 망도 없을 때
#    append_runs 의 '[FAIL] 원장이 비어 있고…' (rc 5) 가 '밀린 런 없음' 으로 기록됐다 (2026-11-09 리뷰 필수 2c)
PO=$(mktemp /tmp/sheetlog-preview.XXXXXX)
(cd "$DIR" && timeout 600 python3 "$TOOL" "${TOOLARGS[@]}") > "$PO" 2>&1; rc=$?
preview=$(grep -v FutureWarning "$PO" | grep -v 'warnings.warn'); rm -f "$PO"
if { [ $rc -ne 0 ] && ! printf '%s' "$preview" | grep -q '추가 대상'; } || printf '%s\n' "$preview" | grep -qE '^\[(FAIL|FATAL)\]'; then
   why=$(printf '%s\n' "$preview" | grep -E '^\[(FAIL|FATAL)\]' | head -1)
   [ -n "$why" ] || why=$(printf '%s\n' "$preview" | grep -v '^[[:space:]]*$' | tail -1)
   if [ $STATUS -eq 1 ]; then
      echo "★ 미리보기 실패 (rc=$rc) : $why"
      [ -r "$LEDGER_TOOL" ] && echo "원장            : $(cd "$DIR" && python3 "$LEDGER_TOOL" --status --tab Y2026B 2>/dev/null | sed -n '2p' | sed 's/^ *//')"
      exit 1
   fi
   log "[FAIL] 미리보기 실패 (rc=$rc) : $why"
   printf '%s\n' "$preview" | tail -5 >> "$LOG"
   #  같은 사유는 한 번만 알린다 (원장이 없는 채 망이 끊기면 매시 같은 실패다)
   #  --dry-run 은 바깥(메일)에 닿지 않고 실패 표식도 심지 않는다 (2 라운드 리뷰 필수)
   if [ $DRY -eq 0 ] && [ $NONOTIFY -eq 0 ] && [ -x "$NOTIFY" ] && sheet_fail_once "preview $why"; then
      FD=$(mktemp /tmp/sheetlog-preview.XXXXXX); printf '%s\n' "$preview" > "$FD"
      "$NOTIFY" --params "$PARAMS" sheetlog --msg "시트 런 로그 미리보기 실패 (rc=$rc) -- 등재하지 못했다 : $why. 원장이 없으면 망이 있을 때 sheet_ledger.py --pull --tab Y2026B 로 씨앗을 만든다. 로그 : $LOG" --detail-file "$FD" >/dev/null 2>&1
      rm -f "$FD"
   fi
   exit 1
fi

#  이벤트 0 인 런은 append_runs.py 가 후보에서 뺀다 (2026-11-08 run 4441~4445). 무엇을 뺐는지 남긴다
zskip=$(printf '%s' "$preview" | grep '^건너뜀(0 사건)' | head -1)
[ -n "$zskip" ] && [ $STATUS -eq 0 ] && log "$zskip -- 시트에 싣지 않는다"
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
   [ -n "$zskip" ] && echo "$zskip  (onlbit=1 이나 nfadc=0 -- 싣지 않는다)"
   [ -n "$blocked" ] && echo "대기            : run $blocked 부터 (후처리 미완)"
   echo "마지막 등재     : $( [ "$last_ts" -gt 0 ] && date -d "@$last_ts" '+%F %T' || echo '기록 없음' )  (${elapsed_h}시간 전)"
   echo "문턱 / 주기     : $THRESHOLD 개 / ${INTERVAL_H}시간"
   drill_active && echo "★ 드릴 중       : pid $(drill_flag_get pid) plan $(drill_flag_get plan) ($DRILL_FLAG) -- 등재하지 않는다"
   [ -r "$LEDGER_TOOL" ] && echo "원장            : $(cd "$DIR" && python3 "$LEDGER_TOOL" --status --tab Y2026B 2>/dev/null | sed -n '2p' | sed 's/^ *//')"
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

CO=$(mktemp /tmp/sheetlog-commitout.XXXXXX)
(cd "$DIR" && timeout 900 python3 "$TOOL" "${TOOLARGS[@]}" --limit "$ok" --commit) > "$CO" 2>&1; trc=$?
out=$(grep -v FutureWarning "$CO" | grep -v 'warnings.warn'); rm -f "$CO"
wrote=$(printf '%s' "$out" | sed -n 's/.*기록함 : \(.*\)/\1/p' | head -1)
#  ★ 로컬 등재가 성공의 기준이다. 시트 쪽은 따로 본다 (보류 = 망 없음, 실패 = 그 밖)
localok=$(printf '%s\n' "$out" | grep -m1 '^\[LOCAL\]')

DETAIL=$(mktemp /tmp/sheetlog-detail.XXXXXX)
{
   echo "사유    : $reason"
   echo "등재 런 : $(printf '%s' "$cands" | head -n "$ok" | tr '\n' ' ')"
   [ -n "$blocked" ] && echo "미룬 것 : run $blocked 이후 (후처리 미완)"
   echo
   printf '%s\n' "$out"
} > "$DETAIL"

send_mail=1
if [ -n "$localok" ] || [ -n "$wrote" ]; then
   printf 'last_commit=%s\n' "$now" > "$STATE"
   if [ -n "$wrote" ]; then
      log "[OK] 등재 $ok 런 -> $wrote  ($reason)"
      msg="시트에 $ok 런 등재 -- $wrote"
      rm -f "$FAILSTATE" 2>/dev/null       # 다음 실패는 다시 알린다
   elif [ "${trc:-0}" -eq 0 ]; then          # 망 없음(보류)이면 도구는 0 을 낸다
      log "[OK] 등재 $ok 런 -> 로컬 원장 (시트 보류 : 망이 돌아오면 원장에서 민다)  ($reason)"
      msg="로컬 원장에 $ok 런 등재 -- 시트 전송은 보류 (망 없음). 망이 돌아오면 원장 값으로 자동 동기화"
   else
      log "[OK] 등재 $ok 런 -> 로컬 원장. ★ 시트 쓰기 실패 rc=$trc ($reason)"
      printf '%s\n' "$out" | tail -5 >> "$LOG"
      msg="로컬 원장에 $ok 런 등재 -- ★ 시트 쓰기 실패 (rc=$trc). 원장에 남아 다음 회차에 다시 민다. 로그 : $LOG"
      sheet_fail_once "commit $(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)" || send_mail=0
   fi
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
[ -n "$localok" ] || [ -n "$wrote" ]
