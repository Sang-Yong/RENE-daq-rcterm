#!/usr/bin/env bash
# monitor-trend-xmin.test.sh -- 추이 그림 x 축 시작 (trend_xmin_date / daily_xmin_date, 2026-10-18).
#   [1] 키가 없으면 산출이 키 도입 전과 같다 (환경변수도 비운다)
#   [2] 키가 자료보다 늦으면 그 쪽은 그리지 않고 죽지도 않는다
#   [3] 키가 자료 사이면 쪽은 그대로 나오되 그림이 바뀐다
#   [4] 래퍼 도우미 : daily_xmin_date 가 없으면 trend_xmin_date 를 같이 쓴다, 따로 주면 따로
#   [5] ReneParseXminDate 는 지역 자정, 못 읽는 값은 -1
#  합성 TSV 만 쓴다. 실데이터·운영 params 무접촉.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh 2>/dev/null
command -v root >/dev/null 2>&1 || { echo "SKIP: ROOT 없음"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
unset RENE_TREND_XMIN RENE_DAILY_XMIN

mkfix() {   # mkfix <dir> : 런 3 개 (2023-11-14 · 15 · 16 KST 근처) x 두 태그
   local d=$1; mkdir -p "$d"
   printf '# run_summary\n# schema 2\n' > "$d/run_summary.tsv"
   for r in 4300 4301 4302; do
      printf '%s\t10\t0\t%d\t%d\t3600\t3600\t3500\t100\t1\t2\t3\tnone\n' "$r" $((1700000000 + (r-4300)*86400)) $((1700000000 + (r-4300)*86400 + 3600)) >> "$d/run_summary.tsv"
   done
   local H='#run\ttag\tsrc\tlive_s\tn_paired\tn_paired_acci\tn_ibd\tn_ibd_acci\tn_single\tr_ll\tn_subrun\tn_mu\tn_mu_shower\tn_lihe\te_lihe\tlihe_stat\tn_fn_side\tn_fn_side_scaled\tn_fn_side_lin\tfn_sat_frac\tn_lihe_rev\te_lihe_rev\tr_mu_shower\tn_acci_rp\tn_mult_rej\tpsd_mean\tpsd_rms\tn_ibd_psd_nlike\tdt_min\tdt_max\tdt_acci\ts2_lo\ts2_hi\tiso_pre\tiso_post\tmu_shower_npe\tfn_e_lo\tfn_e_hi\tlihe_fit_lo\tlihe_fit_hi\tlihe_li_frac\tpsd_nsig'
   { printf '# metrics\n# schema 2\n'; printf "$H\n"
     for r in 4300 4301 4302; do
        printf '%s\t_nGd\tnone\t3500\t650\t28\t%d\t17\t7601557\t88.0\t60\t68654229\t54030\t3.2\t2.1\tok\t6\t1.7\t2.0\t0.95\t0.1\t0.3\t0.625\t25.3\t4.0\t0.401\t0.078\t2\t1\t100\t1000\t6\t10\t200\t400\t20000\t12\t50\t0.002\t10\t1\t3\n' "$r" $((60 + r - 4300))
        printf '%s\t_nH\tnone\t3500\t80073\t69961\t62601\t58894\t7601557\t88.0\t60\t68654229\t54030\t-1\t-1\tlowstat\t5\t1.4\t1.0\t0.95\t-1\t-1\t0.625\t69000.5\t120.0\t0.401\t0.078\t50\t2\t400\t1000\t1.87\t2.59\t600\t1000\t20000\t12\t50\t0.002\t10\t1\t3\n' "$r"
     done; } > "$d/metrics_summary.tsv"
}
cuts() { printf '# 시험\n%s\n' "$2" > "$1"; }

run_bg() {   # run_bg <dir> <params> -> png 수
   RUNSUM_OUT="$1" MONITORCUTS="$2" "$DIR/tools/monitor/bg-trend.sh" > "$1.log" 2>&1 || echo "rc=$? $(tail -3 "$1.log")" >&2
   ls "$1"/[0-9][0-9]_bg_*.png 2>/dev/null | wc -l
}

echo "[1] 키 없음 -> 자동 범위"
mkfix "$T/a"; cuts "$T/a.params" "fn_norm_mode = 2"
NA=$(run_bg "$T/a" "$T/a.params")
[ "$NA" -eq 10 ] && ok "png $NA 장" || bad "png $NA (기대 10)"
mkfix "$T/a2"; NA2=$(run_bg "$T/a2" "$T/a.params")
same=1; for f in "$T/a"/[0-9][0-9]_bg_*.png; do cmp -s "$f" "$T/a2/$(basename "$f")" || same=0; done
[ "$same" = 1 ] && ok "같은 입력 두 번 -> 바이트 동일 (비교 기준이 결정적)" || bad "PNG 가 결정적이 아니다"
grep -q 'x 축' "$T/a.log" && bad "키가 없는데 x 축 줄을 찍었다" || ok "키가 없으면 x 축 줄 없음"

echo "[2] 키가 자료보다 늦다 -> 쪽을 그리지 않고 rc 0"
mkfix "$T/b"; cuts "$T/b.params" "trend_xmin_date = 2030-01-01"
NB=$(run_bg "$T/b" "$T/b.params"); RCB=$(grep -c 'rc=' "$T/b.log" || true)
[ "$NB" -eq 0 ] && ok "png 0 장" || bad "png $NB (기대 0)"
grep -q 'x 축 : 2030-01-01 부터' "$T/b.log" && ok "x 축 줄" || bad "x 축 줄이 없다"
echo "[2b] 키가 없고 환경변수가 있으면 환경을 쓴다 (별도 OUT 용)"
mkfix "$T/b2"; NB2=$(RENE_TREND_XMIN=2030-01-01 run_bg "$T/b2" "$T/a.params")
[ "$NB2" -eq 0 ] && ok "환경 RENE_TREND_XMIN 반영" || bad "png $NB2 (기대 0)"

echo "[3] 키가 자료 사이 (첫 런 뒤) -> 쪽은 그대로, 그림은 바뀐다"
mkfix "$T/c"; cuts "$T/c.params" "trend_xmin_date = $(date -d @1700050000 '+%Y-%m-%d %H:%M')"
NC=$(run_bg "$T/c" "$T/c.params")
[ "$NC" -eq 10 ] && ok "png $NC 장" || bad "png $NC (기대 10)"
cmp -s "$T/a/18_bg_accidental_nGd.png" "$T/c/18_bg_accidental_nGd.png" && bad "그림이 그대로다" || ok "그림이 바뀌었다"

echo "[4] 래퍼 도우미"
. "$DIR/tools/monitor/trend-xmin.sh"
h() { ( unset RENE_TREND_XMIN RENE_DAILY_XMIN; MONITORCUTS=$1; rene_trend_xmin_export "$DIR"; echo "${RENE_TREND_XMIN-UNSET}|${RENE_DAILY_XMIN-UNSET}" ); }
cuts "$T/h1" "fn_norm_mode = 2";                                           r=$(h "$T/h1"); [ "$r" = "UNSET|UNSET" ] && ok "키 없음 -> $r" || bad "키 없음 -> $r"
cuts "$T/h2" "trend_xmin_date = 2026-08-15   # 주석";                       r=$(h "$T/h2"); [ "$r" = "2026-08-15|2026-08-15" ] && ok "daily 는 trend 를 같이 -> $r" || bad "-> $r"
printf 'trend_xmin_date = 2026-08-15\ndaily_xmin_date = 2026-09-01\n' > "$T/h3"; r=$(h "$T/h3"); [ "$r" = "2026-08-15|2026-09-01" ] && ok "따로 -> $r" || bad "-> $r"
printf 'daily_xmin_date = 2026-09-01\n' > "$T/h4";                          r=$(h "$T/h4"); [ "$r" = "UNSET|2026-09-01" ] && ok "daily 만 -> $r" || bad "-> $r"
cuts "$T/h5" "trend_xmin_date = 2026-08-15 10:30";                          r=$(h "$T/h5"); [ "$r" = "2026-08-15 10:30|2026-08-15 10:30" ] && ok "시각 포함 -> $r" || bad "-> $r"

echo "[5] ReneParseXminDate"
cat > "$T/p.C" <<CEOF
#include "$DIR/tools/monitor/ReneTrendPlot.h"
void p() { printf("P %.0f %.0f %.0f %.0f\n", ReneParseXminDate("2026-08-15"), ReneParseXminDate("2026-08-15 10:30"), ReneParseXminDate("garbage"), ReneParseXminDate("")); }
CEOF
got=$(cd "$T" && root -l -b -q "p.C" 2>/dev/null | grep '^P ')
want="P $(date -d '2026-08-15 00:00' +%s) $(date -d '2026-08-15 10:30' +%s) -1 -1"
[ "$got" = "$want" ] && ok "$got" || bad "got '$got' want '$want'"

echo; echo "PASS $PASS  FAIL $FAIL"
[ "$FAIL" -eq 0 ]
