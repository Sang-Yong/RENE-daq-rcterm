#!/usr/bin/env bash
# BuildMetrics : 표에 행이 있어도 DST 가 그 뒤에 다시 만들어졌으면(live_s 가 다르다) 다시 계산한다 (2026-09-13, run 4341 사고).
# ROOT 와 실 DST(run 4305) 가 필요하다 -- 표만 임시 사본으로 손댄다. /scratch 의 원본은 읽기만 한다.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
OUT=${RUNSUM_OUT:-/scratch/RunSummary}
f=$(ls "$OUT/dst/" 2>/dev/null | grep -E 'DST_0*4305\.root' | head -1)
[ -n "$f" ] && [ -r "$OUT/metrics_summary.tsv" ] || { echo "SKIP metrics-stale : $OUT/dst 의 run 4305 DST 또는 metrics_summary.tsv 가 없다"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/dst"; ln -s "$OUT/dst/$f" "$T/dst/$f"; cp "$OUT/runtype.tsv" "$T/" 2>/dev/null
#  4305 행의 live 를 3000 s 줄여 '낡은 행' 을 만든다
awk -F'\t' 'BEGIN{OFS="\t"} /^#/ || $1!="4305" {print; next} {$4=$4-3000; print}' "$OUT/metrics_summary.tsv" > "$T/metrics_summary.tsv"
OLD=$(awk -F'\t' '$1=="4305"{print $4; exit}' "$T/metrics_summary.tsv")
o1=$(RUNSUM_OUT="$T" timeout 900 "$DIR/tools/monitor/metrics.sh" --list 4305 2>&1)
NEW=$(awk -F'\t' '$1=="4305"{print $4; exit}' "$T/metrics_summary.tsv")
o2=$(RUNSUM_OUT="$T" timeout 900 "$DIR/tools/monitor/metrics.sh" --list 4305 2>&1)
PASS=0; FAIL=0
chk(){ if eval "$2"; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }
chk "낡은 행을 알아본다 ([REDO] … DST 가 표의 행보다 새롭다)" 'printf "%s" "$o1" | grep -q "DST 가 표의 행보다 새롭다"'
chk "두 채널을 다시 썼다"                               'printf "%s" "$o1" | grep -q "다시 쓴 행 2"'
chk "live 가 DST 값으로 돌아왔다 ($OLD -> $NEW)"        '[ "$NEW" != "$OLD" ] && awk -v n="$NEW" "BEGIN{exit !(n > 86000)}"'
chk "다시 돌리면 건너뛴다 (멱등)"                       'printf "%s" "$o2" | grep -q "건너뜀 2"'
echo; echo "PASS $PASS  FAIL $FAIL"; [ "$FAIL" -eq 0 ]
