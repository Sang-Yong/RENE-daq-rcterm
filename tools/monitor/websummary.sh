#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  websummary.sh - 런 서머리 웹 발행 오케스트레이터. cron 매시 27분.
#
#    완결(FADC==PRD)된 새 런이 있을 때만 일한다. /scratch 가 없으면 조용히
#    물러난다 -- 감시·발행이 스스로 죽어 사고가 되지 않게 (chainwatch 원칙,
#    CLAUDE.md §11.138).
#
#  사용 :
#      websummary.sh [--params <파일>] [--dry-run] [--status] [--force]
#
#      --params   기본 <저장소>/config/websummary.params
#      --dry-run  무엇을 할지 목록만 찍고 아무것도 바꾸지 않는다
#      --status   지금 상태를 읽기만 한다 (잠금을 잡지 않는다)
#      --force    last_run 을 무시하고 start_run 부터 다시 훑는다.
#                 이미 처리된 런은 각 단계 스크립트가 알아서 건너뛰므로
#                 (already 관용구) 다시 돌려도 안전하다
#
#  순서 : 게이트(완결 런 목록, start_run 부터 연속으로 완결된 것까지만)
#      -> run-summary.sh -> dst-build.sh -> metrics.sh(빌드)
#      -> metrics.sh --verify (legacy 인 동안은 불일치해도 경고만)
#      -> ibd-summary.sh -> rate-trend.sh
#      -> veto-summary.sh (VETO 패널 반응·veto 계수율. 실패해도 WARN 뿐, 2026-09-09)
#      -> bg-trend.sh   (실패해도 WARN 뿐)
#      -> gen-runclass.sh (type 열 분류, 컨트롤러 판정 R9. 실패해도 WARN 뿐 --
#         type='-' 로 계속) -> gen-summary-html.sh
#      -> rate_trend_*.png 11개 + bg_trend_*.png 6개 + veto_*.png 3개 + summary.html 을 webroot 로 rsync 복사
#
#  ★ 부팅 실패 런 (2026-09-09, §11.173 개선 4) -- FADC 파일이 min_subruns(기본 2)개
#      미만인 완결 런은 표에 싣지 않고 건너뛴다(게이트도 막지 않는다). run 4335 처럼
#      서브런 하나 남기고 죽은 런이 'test' 행으로 들어가던 것을 막는다. 3분 확인 런
#      (서브런 3)은 그대로 실린다(§11.5 의 4300 처럼 사용자가 싣기로 한 것).
#         (publish_google.py 는 webroot 만 읽는다 -- 컨트롤러 판정 R2)
#      -> publish_google.py (publish=1 일 때만)
#
#  상태 : <WEBSUMMARY_STATE> 에 'last_run=N' 한 줄. 모든 단계(발행 포함)가
#      성공한 뒤에만 전진한다. publish=0 이면 로컬 생성까지만 마치고
#      전진한다. 어느 단계든 실패하면 로그만 남기고 exit 1 -- 상태는
#      그대로라 다음 회차가 같은 런부터 다시 시도한다.
#
#  cron (매시 27분, 배포는 Task 10 몫) :
#      27 * * * * <저장소>/tools/monitor/websummary.sh >/dev/null 2>&1
#
#  환경 (전부 선택. 기본은 운영값 그대로) --------------------------------
#      WEBSUMMARY_ROOTS    완결 게이트가 훑을 RAW 루트들 (공백 구분).
#                          기본 "/Data_ssd/RAW /data/RAW /scratch/RAW".
#                          시험이 픽스처 트리로 갈아끼우는 자리다.
#      WEBSUMMARY_LOCK     잠금 파일. 기본 /tmp/websummary.lock.
#                          ★ 운영 중인 것과 시험이 같은 잠금을 잡으면
#                          시험이 조용히 exit 0 으로 끝난다 (dataflow.sh
#                          DATAFLOW_LOCK 의 교훈, CLAUDE.md §11.150).
#                          시험은 반드시 갈아끼울 것.
#      WEBSUMMARY_STATE    상태 파일. 기본 /Data_ssd/LOG/websummary.state
#      WEBSUMMARY_LOG      로그 파일. 기본 /Data_ssd/LOG/websummary.log
#      WEBSUMMARY_MON_DIR  다섯 단계 스크립트 + gen-summary-html.sh +
#                          publish_google.py 를 부를 디렉터리. 기본은 이
#                          스크립트 자신이 있는 tools/monitor.
#                          ★ 시험 전용. 가짜 스테이지로 publish=1 성공/실패
#                          경로를 시험할 때만 갈아끼운다. 기본과 다르면
#                          실행마다 [TEST] 로 크게 알린다(운영에서 켜져
#                          있으면 바로 눈에 띄어야 한다). 운영에서는
#                          절대 쓰지 말 것.
#      WEBSUMMARY_STAGES_DISABLED=1
#                          ★ 시험 전용. 다섯 단계 스크립트 + html 생성 +
#                          webroot 복사 + 발행을 전부 건너뛰고 게이트/
#                          상태/잠금/마운트/dry-run 로직만 시험한다.
#                          운영에서는 절대 쓰지 말 것.
# ---------------------------------------------------------------------
set -u

#  ★ 자기발견 결함(리뷰 범위 밖, Finding 1·2 를 고치다 발견) -- websummary.sh
#  는 이 저장소의 다른 tools/monitor/*.sh 와 같은 깊이(tools/monitor/)에
#  있다. 그 형제들의 관용구(metrics.sh 의 DIR/REPO)와 다르게 애초
#  '..' 를 한 번만 올려 저장소 루트가 아니라 'tools' 를 가리켰다 --
#  MON_DEFAULT 가 tools/tools/monitor 로, PARAMS 가 tools/config/... 로
#  잘못 잡혀 있었다(실측: WEBSUMMARY_MON_DIR 을 넣어 보는 시험을 만들며
#  로그의 [TEST] 줄에서 드러났다). --params 도 WEBSUMMARY_MON_DIR 도
#  안 주는 것이 실제 cron 호출 그대로라, 고치지 않았으면 첫 배포마다
#  모든 단계가 '파일이 없다'로 즉시 실패했을 것이다.
DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$DIR/../.." && pwd)
MON_DEFAULT=$DIR
MON=${WEBSUMMARY_MON_DIR:-$MON_DEFAULT}
PARAMS=$REPO/config/websummary.params
DRY=0; FORCE=0; STATUS=0

while [ $# -gt 0 ]; do
   case "${1:-}" in
      --params)  [ $# -ge 2 ] || { echo "--params 뒤에 파일 경로가 필요하다" >&2; exit 2; }
                 PARAMS=$2; shift 2 ;;
      --dry-run) DRY=1; shift ;;
      --status)  STATUS=1; shift ;;
      --force)   FORCE=1; shift ;;
      -h|--help) sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) echo "모르는 옵션 : $1" >&2; exit 2 ;;
   esac
done

LOG=${WEBSUMMARY_LOG:-/Data_ssd/LOG/websummary.log}
STATE=${WEBSUMMARY_STATE:-/Data_ssd/LOG/websummary.state}
LOCK=${WEBSUMMARY_LOCK:-/tmp/websummary.lock}
STAGES_DISABLED=${WEBSUMMARY_STAGES_DISABLED:-0}
mkdir -p "$(dirname "$LOG")" "$(dirname "$STATE")" 2>/dev/null

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

#  ★ 리뷰 지적 (Finding 2) -- WEBSUMMARY_MON_DIR 은 시험 전용이다. 운영에서
#  실수로 켜진 채 남으면 실제 단계 대신 아무것도 안 하는 스크립트를 부르게
#  되므로, 기본값과 다르면 회차마다 크게 알린다.
[ "$MON" = "$MON_DEFAULT" ] || \
   log "[TEST] WEBSUMMARY_MON_DIR=$MON (기본값 $MON_DEFAULT 아님) -- 시험 전용, 운영에서는 절대 쓰지 말 것"

#  'key = value' 한 줄을 읽는다 (metrics.sh 의 getp 와 같은 관용구 --
#  '#' 뒤는 주석, 앞뒤 공백은 버리고, 같은 키가 여러 번이면 나중 것이 이긴다).
#  ★ 앞 공백을 먼저 떼야 한다 (metrics.sh 가 실측으로 고친 순서).
getp() {          # getp <키> <기본값>
   local k=$1
   local d=$2
   [ -r "$PARAMS" ] || { printf '%s\n' "$d"; return; }
   awk -F= -v k="$k" '
      $1 ~ "^[ \t]*"k"[ \t]*$" {
         sub(/^[ \t]+/, "", $2); sub(/[ \t#].*$/, "", $2)
         if ($2 != "") { v = $2; f = 1 }
      }
      END { if (f) print v; else exit 1 }' "$PARAMS" 2>/dev/null || printf '%s\n' "$d"
}

TSVDIR=$(getp tsv_dir /scratch/RunSummary)
WEBROOT=$(getp webroot /scratch/RunSummary/web)
METRICS_SOURCE=$(getp metrics_source legacy)
REFRESH_S=$(getp refresh_s 600)
PUBLISH=$(getp publish 1)
START_RUN=$(getp start_run 4280)
case "$START_RUN" in ''|*[!0-9]*) START_RUN=4280 ;; esac
MIN_SUBRUNS=$(getp min_subruns 2)
case "$MIN_SUBRUNS" in ""|*[!0-9]*) MIN_SUBRUNS=2 ;; esac

# ---- 완결 게이트 : sheetlog-auto.sh 의 run_complete 와 같은 판정 -------
#      시험이 픽스처 트리를 끼울 수 있게 환경으로 뺀다
ROOTS=${WEBSUMMARY_ROOTS:-"/Data_ssd/RAW /data/RAW /scratch/RAW"}
RC_NF=0                       # run_complete 가 마지막으로 본 FADC 파일 수 (부팅 실패 런 판정용)
run_complete() {
   local rr d f p
   rr=$1; RC_NF=0
   for d in $ROOTS; do
      [ -d "$d/$rr" ] || continue
      f=$(ls -U "$d/$rr"     2>/dev/null | grep -c "^FADC_$rr\.root\.")
      p=$(ls -U "$d/$rr/PRD" 2>/dev/null | grep -c '\.root$')
      RC_NF=$f
      [ "$f" -gt 0 ] && [ "$p" -eq "$f" ] && return 0
      #  ★ 원시 파일이 **전부** badrun/ 으로 격리된 런(CLAUDE.md §5.9)은 FADC 가
      #    0 이라 위 판정으로는 영원히 '미완결' 이고, 연속 규칙이라 그 뒤 런까지
      #    통째로 막는다 (실측 : run 4324 가 4325~ 를 막았다). 더 기다릴 것이
      #    없는 런이므로 완결로 친다 -- 뒤 단계는 PRD 가 0~몇 개여도 죽지 않는다.
      [ "$f" -eq 0 ] && [ -d "$d/$rr/badrun" ] && return 0
   done
   return 1
}

#  ROOTS 아래 6자리 런 디렉터리 이름을 훑는다 (파일이 아니라 디렉터리 하나당
#  한 번의 readdir 이라 /scratch 에서도 가볍다 -- run-summary.sh 의
#  have_runs() 와 같은 값싼 관용구, CLAUDE.md §11.5).
discover_runs() {
   local d
   for d in $ROOTS; do
      d=${d%/}
      [ -d "$d" ] || continue
      ls -1U "$d" 2>/dev/null
   done | grep -E '^[0-9]{6}$' | sort -n -u
}

state_last_run() {
   [ -r "$STATE" ] || return 1
   awk -F= '$1=="last_run"{print $2; f=1} END{exit !f}' "$STATE" 2>/dev/null
}

#  start_run 부터 last(하한, 배타) 보다 큰 런을 훑어 -- 연속으로 완결된
#  접두만 NEWLIST_ARR 에 담는다. 처음 만나는 미완결 런에서 멈춘다
#  (sheetlog-auto.sh 와 같은 규칙 -- CONSECUTIVE, 건너뛰지 않는다).
NEWLIST_ARR=(); BLOCKED=""; SKIPPED_ARR=()
compute_gate() {
   local last=$1 rr n
   NEWLIST_ARR=(); BLOCKED=""; SKIPPED_ARR=()
   for rr in $(discover_runs); do
      n=$((10#$rr))
      [ "$n" -ge "$START_RUN" ] || continue
      [ "$n" -gt "$last" ] || continue
      if run_complete "$rr"; then
         #  완결이지만 서브런이 너무 적은 런 = 부팅 실패의 잔재. 표에 싣지 않고
         #  지나간다 (연속 규칙은 유지 -- 게이트를 막지 않는다).
         if [ "$RC_NF" -gt 0 ] && [ "$RC_NF" -lt "$MIN_SUBRUNS" ]; then
            SKIPPED_ARR+=("$n")
            continue
         fi
         NEWLIST_ARR+=("$n")
      else
         BLOCKED=$n
         break
      fi
   done
}

run_stage() {          # run_stage <이름표> <명령...>
   local label=$1; shift
   log "[RUN ] $label"
   nice -n 15 ionice -c2 -n7 "$@" >>"$LOG" 2>&1
   local rc=$?
   if [ $rc -ne 0 ]; then log "[FAIL] $label (exit=$rc). 로그 : $LOG"
   else                   log "[OK  ] $label"
   fi
   return $rc
}

# ---- --status : 읽기 전용, 잠금을 잡지 않는다 (chainwatch.sh 와 같은 규칙) --
if [ "$STATUS" -eq 1 ]; then
   echo "websummary 상태  $(date '+%F %T')"
   echo "  params    : $PARAMS $( [ -r "$PARAMS" ] || echo '(없음 -- 기본값 사용)' )"
   echo "  tsv_dir   : $TSVDIR $( [ -d "$TSVDIR" ] || echo '★ 없음' )"
   echo "  webroot   : $WEBROOT"
   echo "  publish   : $PUBLISH   metrics_source : $METRICS_SOURCE   refresh_s : ${REFRESH_S}s"
   echo "  start_run : $START_RUN"
   mountpoint -q /scratch 2>/dev/null && echo "  /scratch  : 마운트됨" || echo "  /scratch  : ★ 마운트 안 됨"
   SLR=$(state_last_run 2>/dev/null); case "$SLR" in ''|*[!0-9]*) SLR=0 ;; esac
   echo "  last_run  : $( [ "$SLR" -gt 0 ] && echo "$SLR" || echo '없음(0)' )  ($STATE)"
   #  ★ 잠금 파일은 열어 보지 않는다 -- exec N>"$LOCK" 은 없으면 만든다.
   #  --status 는 순수 읽기 전용이라야 한다(운영 요구사항). 잠금 상태가
   #  궁금하면 실행 자체를 한 번 걸어 보는 것으로 충분하다(즉시 물러난다).
   compute_gate "$SLR"
   if [ ${#NEWLIST_ARR[@]} -eq 0 ]; then
      echo "  새 완결 런 : 없음$( [ -n "$BLOCKED" ] && echo " (run $BLOCKED 에서 막힘 -- 후처리 미완)" )"
   else
      echo "  새 완결 런 : ${#NEWLIST_ARR[@]}개 (${NEWLIST_ARR[*]})$( [ -n "$BLOCKED" ] && echo "  다음은 run $BLOCKED 에서 막힘" )"
   fi
   [ ${#SKIPPED_ARR[@]} -gt 0 ] && echo "  건너뜀    : ${SKIPPED_ARR[*]} (FADC 파일 ${MIN_SUBRUNS}개 미만 -- 부팅 실패 런)"
   exit 0
fi

# ---- 두 번 겹쳐 돌지 않는다 --------------------------------------------
exec 9>"$LOCK" || exit 0
flock -n 9 || { log "이미 돌고 있다. 물러난다"; exit 0; }

mountpoint -q /scratch || { log "/scratch 가 없다. 이번 회차는 쉰다"; exit 0; }
[ -d "$TSVDIR" ] || { log "$TSVDIR 이 없다. 쉰다"; exit 0; }

export RUNSUM_OUT=$TSVDIR

LAST=0
if [ "$FORCE" -ne 1 ]; then
   t=$(state_last_run 2>/dev/null)
   case "$t" in ''|*[!0-9]*) : ;; *) LAST=$t ;; esac
fi
compute_gate "$LAST"
NEWLIST=$(IFS=,; echo "${NEWLIST_ARR[*]}")

# ---- --dry-run : 무엇을 할지만 찍고 아무것도 바꾸지 않는다 -------------
if [ "$DRY" -eq 1 ]; then
   [ ${#SKIPPED_ARR[@]} -gt 0 ] && log "[DRY] 건너뜀 : ${SKIPPED_ARR[*]} (FADC 파일 ${MIN_SUBRUNS}개 미만 -- 부팅 실패 런)"
   if [ ${#NEWLIST_ARR[@]} -eq 0 ]; then
      log "[DRY] 새로 처리할 완결 런이 없다 (start_run=$START_RUN, last_run=$LAST)"
      [ -n "$BLOCKED" ] && log "[DRY]   run $BLOCKED 에서 막혀 있다 (후처리 미완)"
   else
      log "[DRY] 처리했을 런 : $NEWLIST (${#NEWLIST_ARR[@]}개)"
      [ -n "$BLOCKED" ] && log "[DRY]   그 다음은 run $BLOCKED 에서 막혀 있다 (후처리 미완)"
      log "[DRY]   run-summary.sh --list $NEWLIST"
      log "[DRY]   dst-build.sh   --list $NEWLIST"
      log "[DRY]   metrics.sh     --list $NEWLIST  (+ --verify, legacy 면 불일치해도 경고만)"
      log "[DRY]   ibd-summary.sh --list $NEWLIST"
      log "[DRY]   rate-trend.sh"
      log "[DRY]   veto-summary.sh --list $NEWLIST  (실패해도 WARN 뿐)"
      log "[DRY]   bg-trend.sh   (실패해도 WARN 뿐)"
      log "[DRY]   gen-runclass.sh $TSVDIR $TSVDIR/runclass.tsv  (실패해도 WARN 뿐, type='-' 로 계속)"
      log "[DRY]   gen-summary-html.sh $TSVDIR $TSVDIR/summary.html $METRICS_SOURCE $REFRESH_S"
      log "[DRY]   rsync rate_trend_*.png + bg_trend_*.png + veto_*.png + summary.html -> $WEBROOT"
      if [ "$PUBLISH" = 1 ]; then log "[DRY]   publish_google.py --params $PARAMS"
      else                        log "[DRY]   (publish=0 이므로 로컬 생성까지만)"
      fi
   fi
   exit 0
fi

# ---- 새로 할 것이 없다 -- cron 이 시끄러우면 안 되므로 조용히 나간다 ---
if [ ${#NEWLIST_ARR[@]} -eq 0 ]; then
   [ "$FORCE" -eq 1 ] && log "[FORCE] 새로 처리할 완결 런이 없다 (start_run=$START_RUN)"
   if [ ${#SKIPPED_ARR[@]} -gt 0 ]; then
      #  건너뛴 런만 있다 -- 그 번호까지 상태를 전진시킨다 (매 회차 다시 훑지 않게)
      LAST_SKIP=${SKIPPED_ARR[$((${#SKIPPED_ARR[@]}-1))]}
      if [ "$LAST_SKIP" -gt "$LAST" ] && printf 'last_run=%s\n' "$LAST_SKIP" > "$STATE.tmp.$$" && mv -f "$STATE.tmp.$$" "$STATE"; then
         log "[SKIP] run ${SKIPPED_ARR[*]} : FADC 파일 ${MIN_SUBRUNS}개 미만(부팅 실패 런). 표에 싣지 않고 last_run=$LAST_SKIP"
      fi
   fi
   exit 0
fi
[ ${#SKIPPED_ARR[@]} -gt 0 ] && log "[SKIP] run ${SKIPPED_ARR[*]} : FADC 파일 ${MIN_SUBRUNS}개 미만(부팅 실패 런). 표에 싣지 않는다"

# ---- 실행 ---------------------------------------------------------------
if [ "$STAGES_DISABLED" = 1 ]; then
   log "[TEST] WEBSUMMARY_STAGES_DISABLED=1 -- 단계 호출을 건너뛴다 (run $NEWLIST)"
else
   run_stage "run-summary"   "$MON/run-summary.sh"   --list "$NEWLIST" || exit 1
   run_stage "dst-build"     "$MON/dst-build.sh"     --list "$NEWLIST" || exit 1
   run_stage "metrics-build" "$MON/metrics.sh"       --list "$NEWLIST" || exit 1

   log "[RUN ] metrics-verify"
   nice -n 15 ionice -c2 -n7 "$MON/metrics.sh" --verify >>"$LOG" 2>&1
   vrc=$?
   if [ $vrc -ne 0 ]; then
      if [ "$METRICS_SOURCE" = legacy ]; then
         log "[WARN] metrics --verify 불일치 -- metrics_source=legacy 라 발행은 막지 않는다"
      else
         log "[FAIL] metrics --verify 불일치 -- metrics_source=$METRICS_SOURCE 라 발행을 막는다"
         exit 1
      fi
   else
      log "[OK  ] metrics-verify"
   fi

   run_stage "ibd-summary" "$MON/ibd-summary.sh" --list "$NEWLIST" || exit 1
   run_stage "rate-trend"  "$MON/rate-trend.sh"                    || exit 1

   #  VETO 패널 반응·veto 계수율 (veto_summary.tsv + veto_*.png). 발행을 막지 않는다.
   log "[RUN ] veto-summary"
   nice -n 15 ionice -c2 -n7 "$MON/veto-summary.sh" --list "$NEWLIST" >>"$LOG" 2>&1
   vsrc=$?
   if [ $vsrc -ne 0 ]; then log "[WARN] veto-summary 실패 (exit=$vsrc) -- Panels 열과 veto 추이만 빠진다"
   else                     log "[OK  ] veto-summary"
   fi

   #  배경 지표 추이(bg_trend_*.png, 배경 레시피 v2). 발행을 막지 않는다 --
   #  metrics_summary 가 schema 2 가 아니면 [SKIP] 을 찍고 0 으로 나온다.
   log "[RUN ] bg-trend"
   nice -n 15 ionice -c2 -n7 "$MON/bg-trend.sh" >>"$LOG" 2>&1
   bgrc=$?
   if [ $bgrc -ne 0 ]; then log "[WARN] bg-trend 실패 (exit=$bgrc) -- 배경 추이 그림만 빠진다"
   else                     log "[OK  ] bg-trend"
   fi

   #  type(physics/calibration/test) 열의 유일한 생산자(컨트롤러 판정 R9).
   #  실패해도 발행을 막지 않는다 -- WARN 만 남기고 지나가면 gen-summary-html.sh
   #  가 runclass.tsv 를 못 찾아 type 열을 전부 '-' 로 낸다(그 스크립트의
   #  키 조회 fallback). metrics-verify 와 같은 이유로 run_stage 를 안 쓴다 --
   #  실패를 곧장 exit 1 로 넘기지 않아야 해서다.
   log "[RUN ] gen-runclass"
   nice -n 15 ionice -c2 -n7 "$MON/gen-runclass.sh" "$TSVDIR" "$TSVDIR/runclass.tsv" >>"$LOG" 2>&1
   rcrc=$?
   if [ $rcrc -ne 0 ]; then
      log "[WARN] gen-runclass 실패 (exit=$rcrc) -- type 열은 이번 회차에 '-' 로 뜬다"
   else
      log "[OK  ] gen-runclass"
   fi

   run_stage "gen-summary-html" "$MON/gen-summary-html.sh" \
      "$TSVDIR" "$TSVDIR/summary.html" "$METRICS_SOURCE" "$REFRESH_S" || exit 1

   #  컨트롤러 판정 R2 -- publish_google.py 는 webroot 만 읽는다. 복사 없이는
   #  발행이 빈다. rsync -a, 로컬(같은 기계 안 두 경로).
   log "[RUN ] webroot 복사"
   mkdir -p "$WEBROOT" || { log "[FAIL] webroot 를 만들 수 없다 : $WEBROOT"; exit 1; }
   if [ ! -r "$TSVDIR/summary.html" ]; then
      log "[FAIL] $TSVDIR/summary.html 이 없다"; exit 1
   fi
   pngs=("$TSVDIR"/rate_trend_*.png "$TSVDIR"/bg_trend_*.png "$TSVDIR"/veto_*.png)
   pngs=($(for f in "${pngs[@]}"; do [ -e "$f" ] && echo "$f"; done))
   nice -n 15 ionice -c2 -n7 rsync -a "${pngs[@]}" "$TSVDIR/summary.html" "$WEBROOT/" >>"$LOG" 2>&1
   rc=$?
   if [ $rc -ne 0 ]; then log "[FAIL] webroot 복사 (exit=$rc)"; exit 1; fi
   log "[OK  ] webroot 복사 (${#pngs[@]}개 png + summary.html)"

   if [ "$PUBLISH" = 1 ]; then
      run_stage "publish" "$MON/publish_google.py" --params "$PARAMS" || exit 1
   else
      log "[SKIP] publish=0 -- 로컬 생성까지만"
   fi
fi

# ---- 성공 -- 상태 전진 (임시파일 + rename 로 원자적으로) ----------------
#  ★ 리뷰 지적 (Finding 1) -- 이 대입 자체가 이 스크립트가 존재하는 이유다.
#  쓰기가 실패했는데도 [DONE]/exit 0 을 내면 다음 회차가 '이미 했다'고
#  믿고 건너뛴다. && 체인의 성공 여부로 반드시 분기할 것.
LAST_NEW=${NEWLIST_ARR[$((${#NEWLIST_ARR[@]}-1))]}
for sk in "${SKIPPED_ARR[@]}"; do [ "$sk" -gt "$LAST_NEW" ] && LAST_NEW=$sk; done
if printf 'last_run=%s\n' "$LAST_NEW" > "$STATE.tmp.$$" && mv -f "$STATE.tmp.$$" "$STATE"; then
   log "[DONE] run $NEWLIST 처리 완료. last_run=$LAST_NEW (publish=$PUBLISH)$( [ -n "$BLOCKED" ] && echo "  다음은 run $BLOCKED 에서 막힘")"
   exit 0
else
   log "[FAIL] 상태 파일을 쓰지 못했다 : $STATE -- run $NEWLIST 처리는 실제로 끝났으나 기록되지 않았다. 다음 회차가 같은 런부터 다시 시도한다"
   rm -f "$STATE.tmp.$$" 2>/dev/null
   exit 1
fi
