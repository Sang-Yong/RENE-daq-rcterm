#!/usr/bin/env bash
# monitor-bgtrend.test.sh -- bg-trend.sh 가 합성 TSV 에서 6 쪽 PNG 를 만들고,
# 입력이 없거나 schema 1 이면 [SKIP] 으로 조용히 exit 0 하는지. 실데이터 무접촉.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh 2>/dev/null
command -v root >/dev/null 2>&1 || { echo "SKIP: ROOT 없음"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/a" "$T/b" "$T/c"

# ---- [a] 정상 : 런 3개 x 두 태그. 선원 런 하나는 빠져야 한다 ----
printf '# run_summary\n# schema 2\n' > "$T/a/run_summary.tsv"
for r in 4300 4301 4302; do
   printf '%s\t10\t0\t%d\t%d\t3600\t3600\t3500\t100\t1\t2\t3\tnone\n' "$r" $((1700000000 + (r-4300)*86400)) $((1700000000 + (r-4300)*86400 + 3600)) >> "$T/a/run_summary.tsv"
done
H='#run\ttag\tsrc\tlive_s\tn_paired\tn_paired_acci\tn_ibd\tn_ibd_acci\tn_single\tr_ll\tn_subrun\tn_mu\tn_mu_shower\tn_lihe\te_lihe\tlihe_stat\tn_fn_side\tn_fn_side_scaled\tn_fn_side_lin\tfn_sat_frac\tn_lihe_rev\te_lihe_rev\tr_mu_shower\tn_acci_rp\tn_mult_rej\tpsd_mean\tpsd_rms\tn_ibd_psd_nlike\tdt_min\tdt_max\tdt_acci\ts2_lo\ts2_hi\tiso_pre\tiso_post\tmu_shower_npe\tfn_e_lo\tfn_e_hi\tlihe_fit_lo\tlihe_fit_hi\tlihe_li_frac\tpsd_nsig'
{ printf '# metrics\n# schema 2\n'; printf "$H\n"
  for r in 4300 4301 4302; do
     src=none; [ "$r" = 4301 ] && src=AmBe
     printf '%s\t_nGd\t%s\t3500\t650\t28\t82\t17\t7601557\t88.0\t60\t68654229\t54030\t3.2\t2.1\tok\t6\t1.7\t2.0\t0.95\t0.1\t0.3\t0.625\t25.3\t4.0\t0.401\t0.078\t2\t1\t100\t1000\t6\t10\t200\t400\t20000\t12\t50\t0.002\t10\t1\t3\n' "$r" "$src"
     printf '%s\t_nH\t%s\t3500\t80073\t69961\t62601\t58894\t7601557\t88.0\t60\t68654229\t54030\t-1\t-1\tlowstat\t5\t1.4\t1.0\t0.95\t-1\t-1\t0.625\t69000.5\t120.0\t0.401\t0.078\t50\t2\t400\t1000\t1.87\t2.59\t600\t1000\t20000\t12\t50\t0.002\t10\t1\t3\n' "$r" "$src"
  done; } > "$T/a/metrics_summary.tsv"
OUT=$(RUNSUM_OUT="$T/a" "$DIR/tools/monitor/bg-trend.sh" 2>&1); RC=$?
N=$(ls "$T/a"/bg_trend_*.png 2>/dev/null | wc -l)
CHK_A=$([ "$RC" -eq 0 ] && [ "$N" -eq 6 ] && [ -s "$T/a/bg_trend.pdf" ] && echo 1 || echo 0)
[ "$CHK_A" = 1 ] || { echo "[a] rc=$RC png=$N"; echo "$OUT" | tail -8; }
#  선원 런이 빠졌는가 -- '선원 없는 런 행 4' (3 런 x 2 태그 - AmBe 2 행)
echo "$OUT" | grep -q '선원 없는 런 행 4' && CHK_SRC=1 || { CHK_SRC=0; echo "$OUT" | grep '행'; }

# ---- [b] metrics 가 없다 -> SKIP, exit 0, 아무것도 안 만든다 ----
cp "$T/a/run_summary.tsv" "$T/b/"
OUTB=$(RUNSUM_OUT="$T/b" "$DIR/tools/monitor/bg-trend.sh" 2>&1); RCB=$?
CHK_B=$([ "$RCB" -eq 0 ] && echo "$OUTB" | grep -q SKIP && [ ! -e "$T/b/bg_trend.pdf" ] && echo 1 || echo 0)

# ---- [c] schema 1 -> SKIP, exit 0 ----
cp "$T/a/run_summary.tsv" "$T/c/"; sed 's/^# schema 2/# schema 1/' "$T/a/metrics_summary.tsv" > "$T/c/metrics_summary.tsv"
OUTC=$(RUNSUM_OUT="$T/c" "$DIR/tools/monitor/bg-trend.sh" 2>&1); RCC=$?
CHK_C=$([ "$RCC" -eq 0 ] && echo "$OUTC" | grep -q 'SKIP' && [ ! -e "$T/c/bg_trend.pdf" ] && echo 1 || echo 0)
[ "$CHK_C" = 1 ] || { echo "[c] rc=$RCC"; echo "$OUTC" | tail -3; }

echo "CHK pages=$CHK_A"; echo "CHK source_excluded=$CHK_SRC"; echo "CHK no_metrics_skip=$CHK_B"; echo "CHK schema1_skip=$CHK_C"
[ "$CHK_A$CHK_SRC$CHK_B$CHK_C" = 1111 ] || exit 1
echo "PASS monitor-bgtrend (4/4)"
