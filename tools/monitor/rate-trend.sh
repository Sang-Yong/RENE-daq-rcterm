#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  rate-trend.sh - 효율을 보정한 rate 와 시간축 추이 그림을 만든다. 3단계다.
#
#      1) run-summary.sh   livetime, 종류별 이벤트 수
#      2) ibd-summary.sh   IBD 후보 수
#      3) rate-trend.sh    효율 보정 + 그림      <- 이것
#
#  x축은 그 런의 DAQ 시작 시각이다. 런이 하나 끝날 때마다 오른쪽 끝에 점이
#  하나 붙는다. 표(pair_summary)가 누적되므로 다시 돌리기만 하면 추이가 자란다.
#
#  ★ 2026-08-18 : R_LL 을 여기서 재지 않는다. 2단계가 PRD 에서 런 전체의
#    single 을 세어 pair_summary.tsv 의 r_ll 열에 넣어 주므로 그것을 읽는다.
#    표본이 아니라 전수이고, /scratch/junkyo 에 기대지 않는다.
#
#  사용 :
#      tools/monitor/rate-trend.sh              그린다
#      tools/monitor/rate-trend.sh --eps-e 0.85 에너지창 효율을 넣어 보정한다
#      tools/monitor/rate-trend.sh --show       무엇이 만들어졌는지 본다
#
#  경로 (환경변수)
#      RUNSUM_OUT     기본 /scratch/RunSummary
#      RENE_COND      기본 /home/ojk/analysis3/essential/AnalysisCondition.h
# ---------------------------------------------------------------------
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
MACRO=$DIR/BuildRateTrend.C
OUT=${RUNSUM_OUT:-/scratch/RunSummary}
COND=${RENE_COND:-/home/ojk/analysis3/essential/AnalysisCondition.h}
EPSE=1.0

while [ $# -gt 0 ]; do
   case "${1:-}" in
      --eps-e)     EPSE=${2:-1.0}; shift 2 ;;
      --remeasure|--samples)
         echo "[NOTE] $1 는 이제 쓰지 않는다 -- R_LL 은 2단계가 전수로 낸다."
         echo "       다시 재려면 : $DIR/ibd-summary.sh --force <런>"
         case "$1" in --samples) shift 2 ;; *) shift ;; esac ;;
      --show)
         echo "출력 : $OUT"
         ls -la "$OUT"/rate_trend* 2>/dev/null || echo "아직 없다. 인자 없이 한 번 돌릴 것."
         exit 0 ;;
      -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
      *) echo "모르는 옵션 : $1"; sed -n '2,26p' "$0"; exit 1 ;;
   esac
done

[ -r "$MACRO" ] || { echo "매크로가 없다 : $MACRO"; exit 1; }
[ -r "$COND" ]  || { echo "컷 상수 헤더를 읽을 수 없다 : $COND"; exit 1; }
[ -r "$OUT/pair_summary.tsv" ] || {
   echo "pair_summary.tsv 가 없다. 먼저 :"
   echo "   $DIR/run-summary.sh && $DIR/ibd-summary.sh"
   exit 1; }

if ! command -v root >/dev/null 2>&1; then
   # shellcheck disable=SC1091
   [ -r /usr/local/bin/thisroot.sh ] && . /usr/local/bin/thisroot.sh
fi
command -v root >/dev/null 2>&1 || { echo "ROOT 를 찾을 수 없다"; exit 1; }
[ -w "$OUT" ] || { echo "출력 디렉터리에 쓸 수 없다 : $OUT"; exit 1; }

echo "출력  : $OUT/rate_trend.{pdf,tsv} + rate_trend_*.png"
echo "eps_E : $EPSE  (1.0 이면 에너지창 효율은 보정에서 빠진 것이다)"

root -l -b -q "$MACRO+(\"$OUT/\", $EPSE)"
