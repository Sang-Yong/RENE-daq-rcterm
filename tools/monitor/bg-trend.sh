#!/usr/bin/env bash
# bg-trend.sh - 배경 지표(metrics_summary.tsv schema 2)의 시간축 추이 그림.
#   사용 : bg-trend.sh            그린다 (bg_trend.pdf + bg_trend_*.png)
#          bg-trend.sh --show     무엇이 만들어졌는지 본다
#   환경 : RUNSUM_OUT (기본 /scratch/RunSummary)
#   metrics_summary.tsv 가 없거나 schema 2 가 아니면 [SKIP] 을 찍고 exit 0 --
#   websummary.sh 가 이 단계를 비필수로 부르므로 여기서 죽으면 안 된다.
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=${RUNSUM_OUT:-/scratch/RunSummary}
case "${1:-}" in
   --show) ls -la "$OUT"/bg_trend* 2>/dev/null || echo "아직 없다."; exit 0 ;;
   -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
   "") ;;
   *) echo "모르는 옵션 : $1"; exit 1 ;;
esac
[ -r "$OUT/metrics_summary.tsv" ] || { echo "[SKIP] $OUT/metrics_summary.tsv 가 없다"; exit 0; }
[ -r "$OUT/run_summary.tsv" ]     || { echo "[SKIP] $OUT/run_summary.tsv 가 없다"; exit 0; }
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh 2>/dev/null
command -v root >/dev/null 2>&1 || { echo "ROOT 를 찾을 수 없다"; exit 1; }
[ -w "$OUT" ] || { echo "출력 디렉터리에 쓸 수 없다 : $OUT"; exit 1; }
root -l -b -q "$DIR/BuildBgTrend.C+(\"$OUT/\")"
