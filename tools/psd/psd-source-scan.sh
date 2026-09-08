#!/usr/bin/env bash
# psd-source-scan.sh - source-runs.tsv 의 런 전부를 PsdScan 으로 훑고(짧은 런은 서브런 0-5,
#   긴 런은 0-11, 물리 런 4332 는 100-105) PsdAnalyze · PsdSummary 까지 돌린다.
#   읽기 전용 입력. 출력 $PSD_OUT (기본 /scratch/RunSummary/psd). 2 병렬, nice.
#   사용 : psd-source-scan.sh [--analyze-only]
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=${PSD_OUT:-/scratch/RunSummary/psd}
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh
mkdir -p "$OUT"; cp "$DIR/source-runs.tsv" "$OUT/runpos.tsv"
if [ "${1:-}" != "--analyze-only" ]; then
   grep -v '^#' "$DIR/source-runs.tsv" | while read -r r p s; do
      s0=0; s1=5
      case "$r" in 2791|2809|2858|2875) s1=11 ;; 4332) s0=100; s1=105 ;; esac
      echo "$r $s0 $s1 $p"
   done | xargs -P 2 -L 1 bash -c 'nice -n 15 ionice -c2 -n7 '"$DIR"'/psd-scan.sh "$0" "$1" "$2" "$3" > /dev/null 2>&1; echo "run $0 done"'
fi
: > "$OUT/psdana_all.tsv"
for f in $(ls "$OUT"/psdscan_*.root | sort); do
   root -l -b -q "$DIR/PsdAnalyze.C+(\"$f\", \"$OUT/\")" 2>&1 | grep -v '^$\|Processing\|Warning\|Info in' >> "$OUT/psdana_all.tsv"
done
root -l -b -q "$DIR/PsdSummary.C+(\"$OUT/\")" 2>&1 | grep 'SAVED\|^run'
