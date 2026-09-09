#!/usr/bin/env bash
# veto-summary.sh 의 증분 논리. ROOT·실데이터 무접촉 -- VETO_SCAN_CMD/VETO_PLOT_CMD 를 가짜로.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd); SUT=$DIR/tools/monitor/veto-summary.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
cat > "$T/scan.sh" <<'S'
#!/usr/bin/env bash
# $1=run $2=subs $3=out : 서브런 하나당 한 줄 (80 열). 패널 % 는 런 번호에 따라 다르게
r=$1; out=$3; echo "$r" >> "${SCANLOG}"
for s in $(echo "$2" | tr ',' ' '); do
  printf '%s\t%s\t60.0\t50000\t185.0\t%s\t80\t80' "$r" "$s" "$(( r == 4340 ? 500 : 750 ))"
  for j in $(seq 0 29); do printf '\t150'; done
  for j in $(seq 0 29); do printf '\t1.00'; done
  for q in $(seq 0 14); do
    if [ "$r" = 4340 ]; then v=$( [ $q = 0 -o $q = 1 -o $q = 2 -o $q = 3 -o $q = 5 -o $q = 12 ] && echo 10.0 || echo 0.1 )
    else v=$( [ $q = 0 -o $q = 1 -o $q = 2 -o $q = 3 -o $q = 8 -o $q = 11 ] && echo 10.0 || echo 0.1 ); fi
    printf '\t%s' "$v"; done; printf '\n'
done >> "$out"
S
cat > "$T/plot.sh" <<'S'
#!/usr/bin/env bash
: > "$2/veto_panel_trend.png"; echo "[SAVED] fake"
S
chmod +x "$T/scan.sh" "$T/plot.sh"
export SCANLOG=$T/scanlog; : > "$SCANLOG"
mkdir -p "$T/out"
printf '#run\tn_subrun\tn_bad\tepoch_start\tepoch_end\n4333\t1440\t0\t1757300000\t1757386400\n4340\t100\t0\t1757400000\t1757406000\n' > "$T/out/run_summary.tsv"
run(){ RUNSUM_OUT=$T/out VETO_SCAN_CMD=$T/scan.sh VETO_PLOT_CMD=$T/plot.sh "$SUT" "$@"; }

echo "[1] --missing : run_summary 의 두 런을 잰다"
run --missing >/dev/null 2>&1; rc=$?
check "rc=0"                 '[ $rc = 0 ]'
check "두 런 스캔"            '[ "$(sort -u "$SCANLOG" | wc -l)" = 2 ]'
check "thr_history 8 줄"     '[ "$(grep -vc "^#" "$T/out/veto/thr_history.tsv")" = 8 ]'
check "veto_summary 2 행"    '[ "$(grep -vc "^#" "$T/out/veto_summary.tsv")" = 2 ]'
check "veto Hz 4340=500"     'grep -P "^4340\t" "$T/out/veto_summary.tsv" | cut -f6 | grep -q "^500.0"'
check "epoch 는 run_summary"  'grep -P "^4340\t" "$T/out/veto_summary.tsv" | cut -f2 | grep -q 1757400000'
check "그림 호출"             '[ -e "$T/out/veto_panel_trend.png" ]'

echo "[2] 다시 돌리면 아무것도 안 잰다 (증분)"
: > "$SCANLOG"; run --missing >/dev/null 2>&1
check "스캔 0"                '[ ! -s "$SCANLOG" ]'
check "thr_history 그대로"    '[ "$(grep -vc "^#" "$T/out/veto/thr_history.tsv")" = 8 ]'

echo "[3] --force 는 그 런 줄을 지우고 다시 잰다 (중복 없음)"
run --list 4340 --force >/dev/null 2>&1
check "4340 스캔 1회"         '[ "$(grep -c 4340 "$SCANLOG")" = 1 ]'
check "thr_history 여전히 8"  '[ "$(grep -vc "^#" "$T/out/veto/thr_history.tsv")" = 8 ]'

echo "[4] --dry-run 은 아무것도 안 바꾼다"
: > "$SCANLOG"; run --list 4350 --dry-run >/dev/null 2>&1
check "스캔 0"                '[ ! -s "$SCANLOG" ]'
check "표 그대로 2 행"        '[ "$(grep -vc "^#" "$T/out/veto_summary.tsv")" = 2 ]'

echo "[5] 스캐너가 실패해도 죽지 않는다"
run --list 4351 >/dev/null 2>&1; rc=$?
printf '#!/bin/sh\nexit 1\n' > "$T/scan.sh"
RUNSUM_OUT=$T/out VETO_SCAN_CMD=$T/scan.sh VETO_PLOT_CMD=$T/plot.sh "$SUT" --list 4352 >/dev/null 2>&1; rc2=$?
check "rc=0 (실패 런 건너뜀)"  '[ $rc2 = 0 ]'
echo; echo "PASS $PASS  FAIL $FAIL"; [ $FAIL = 0 ]
