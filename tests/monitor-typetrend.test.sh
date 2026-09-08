#!/usr/bin/env bash
# monitor-typetrend.test.sh -- BuildRateTrend.C 가 run_summary.tsv 의 타입별
# 수(n_type1~3, 9~12열)로 rate_trend_evt_{total,target,veto,coinc}.png 4장을
# 추가로 만드는지, 그러면서 기존 7장이 그대로 나오는지 픽스처로 본다
# (task-6-brief.md Step 2).
#
# 실데이터도 /scratch 도 건드리지 않는다 -- run_summary.tsv 와 pair_summary.tsv
# 를 임시 RUNSUM_OUT 에 직접 두고 그 안에서만 rate-trend.sh 를 돌린다. 분석
# 컷 헤더(RENE_COND)는 rate-trend.sh 의 필수 전제라 없으면 SKIP 한다.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)

command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh 2>/dev/null
command -v root >/dev/null 2>&1 || { echo "SKIP: ROOT 없음"; exit 0; }

COND=${RENE_COND:-/home/ojk/analysis3/essential/AnalysisCondition.h}
[ -r "$COND" ] || { echo "SKIP: 분석 컷 헤더를 읽을 수 없다 ($COND)"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/out"

# ------------------------------------------------------------------ 픽스처 ----
#  run_summary.tsv (schema 2, 3행). 열 순서는 BuildRunSummary.C::WriteTsv 와
#  같다 (CLAUDE.md 작업 지침의 실제 스키마) :
#    run n_subrun n_bad epoch_start epoch_end wall_s span_s live_s dead_s
#    n_type1 n_type2 n_type3 source
#  n_type1=target only(FADC) n_type2=veto only(SADC) n_type3=both(coinc).
#  epoch 는 실제 유닉스 시각대 (base + i*하루) 로 둬 시간축이 그럴듯하게 잡히게 한다.
BASE=1787433297
RUNSUM="$T/out/run_summary.tsv"
{
   echo "# RENE DAQ run summary (fixture, monitor-typetrend.test.sh)"
   echo "# schema 2"
   printf '#run\tn_subrun\tn_bad\tepoch_start\tepoch_end\twall_s\tspan_s\tlive_s\tdead_s\tn_type1\tn_type2\tn_type3\tsource\n'
} > "$RUNSUM"
awk -v base="$BASE" 'BEGIN {
   for (i = 0; i < 3; i++) {
      run = 5000 + i
      es  = base + i * 86400
      ee  = es + 3600
      t1  = 1000 + 100 * i     # target only (FADC)
      t2  = 5000 + 200 * i     # veto only (SADC)
      t3  = 40   + 2   * i     # coincidence (both)
      printf "%d\t10\t0\t%d\t%d\t3600.000\t3600.000\t3595.000\t5.000\t%d\t%d\t%d\tprd\n", \
             run, es, ee, t1, t2, t3
   }
}' >> "$RUNSUM"

#  pair_summary.tsv (schema 2, 3행) -- 같은 세 런, src=none (선원 아님, 즉
#  추이에 쓰인다), r_ll>0 이라 eps_iso 도 계산된다.
PAIRSUM="$T/out/pair_summary.tsv"
{
   echo "# RENE IBD pair summary (fixture, monitor-typetrend.test.sh)"
   echo "# schema 2"
   printf '#run\ttag\tsrc\tlive_s\tn_paired\tn_paired_acci\tn_ibd\tn_ibd_acci\tdt_min\tdt_max\tdt_acci\ts2_lo\ts2_hi\tiso_pre\tiso_post\tn_single\tr_ll\tn_subrun\n'
} > "$PAIRSUM"
awk 'BEGIN {
   for (i = 0; i < 3; i++) {
      run = 5000 + i
      printf "%d\t_nGd\tnone\t3595.000\t100\t10\t50\t5\t1\t100\t1000\t6\t10\t200\t400\t500000\t80.5\t10\n", run
   }
}' >> "$PAIRSUM"

# -------------------------------------------------------------------- 실행 ----
RUNSUM_OUT="$T/out" RENE_COND="$COND" "$DIR/tools/monitor/rate-trend.sh" \
   > "$T/log" 2>&1
RC=$?
[ "$RC" -eq 0 ] || { echo "FAIL: rate-trend.sh exit=$RC"; tail -60 "$T/log"; exit 1; }

# ------------------------------------------------------------------ 판정 ----
#  기존 7종 + 새 4종. 하나라도 없거나 5KB 이하이면(빈 그림) 실패다.
FAIL=0
OLD7="candidates rate_raw rate_corrected efficiency accidental rll cumulative"
NEW4="evt_total evt_target evt_veto evt_coinc"
for nm in $OLD7 $NEW4; do
   f="$T/out/rate_trend_${nm}.png"
   if [ ! -e "$f" ]; then
      echo "FAIL: 없음 $f"; FAIL=1; continue
   fi
   sz=$(wc -c < "$f")
   if [ "$sz" -le 5120 ]; then
      echo "FAIL: 너무 작음 $f ($sz bytes)"; FAIL=1
   fi
done

#  rate_trend.pdf 도 있어야 하고, 11쪽(기존 7 + 새 4) 전부 담겼는지 본다 --
#  이번 변경의 핵심 위험은 PDF 스트림을 늦게 닫아서 앞 7쪽을 덮어쓰는 것이었다
#  (cumulative 페이지의 pdfMode 를 ")" 에서 "" 로 바꾸고 마지막 새 페이지에서
#  닫도록 옮겼다). 페이지 수를 세어 그 회귀를 잡는다.
PDF="$T/out/rate_trend.pdf"
if [ ! -s "$PDF" ]; then
   echo "FAIL: 없음 $PDF"; FAIL=1
else
   NPAGES=$(python3 -c "
import re
data = open('$PDF', 'rb').read()
print(len(re.findall(rb'/Type\s*/Page[^s]', data)))
" 2>/dev/null)
   if [ -z "$NPAGES" ]; then
      echo "[NOTE] python3 로 PDF 쪽 수를 셀 수 없다 -- 건너뛴다"
   elif [ "$NPAGES" -ne 11 ]; then
      echo "FAIL: rate_trend.pdf 쪽 수 = $NPAGES (기대 11 = 기존 7 + 새 4)"; FAIL=1
   fi
fi

#  rate_trend.tsv (기존 산출물) 도 그대로 나와야 한다 -- 이번 변경이 건드리지
#  않은 산출물이라는 것을 확인한다.
[ -s "$T/out/rate_trend.tsv" ] || { echo "FAIL: 없음 $T/out/rate_trend.tsv"; FAIL=1; }

if [ "$FAIL" -ne 0 ]; then
   echo "----- log -----"
   tail -60 "$T/log"
   exit 1
fi

echo "PASS monitor-typetrend (7 기존 + 4 신규 PNG, PDF 11쪽)"
