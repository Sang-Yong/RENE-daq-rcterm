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

# =====================================================================
#  2) 퇴화 경로 (리뷰 지적, Critical) -- run_summary.tsv 에 live_s<=0 인
#     행만 있어도(=typeRate 가 완전히 빈다) rate_trend.pdf 가 유효하게
#     닫혀서 나오는가.
#
#  고치기 전 버그 : 8~11번(타입별 rate) 넷 다 typeRate 에서 자기 계열을
#  채우므로, typeRate 가 비면 넷 다 DrawPage 의 "any 없으면 그리지 않고
#  반환한다"(early return, c->Print 호출 전) 로 조용히 빠진다. 마감(")")을
#  그 중 마지막(k==3) 하나에 맡겨 두었더니, 그 경로에서는 그 Print 자체가
#  안 불려서 1번(candidates)이 이미 열어 둔 PDF 스트림이 영영 안 닫혔다.
#  실측 재현(고치기 전 커밋 b29ac3f 로) : pdfinfo 가 이 픽스처의 산출물을
#  "Couldn't find trailer dictionary / Couldn't read xref table" 로 거부했다.
#
#  ★ 이 조건을 고른 이유 -- run_summary.tsv 를 통째로 없애는 대안은 이
#  버그를 재현하지 못한다. r.epoch 의 유일한 출처가 run_summary.tsv 의
#  epoch 맵이라(BuildRateTrend.C:263), 파일이 없으면 epoch 맵도 비어 모든
#  행이 `r.epoch<=0` 로 걸러져 `use` 자체가 비고, 1번(candidates)에
#  닿기도 전에 "[FATAL] 그릴 점이 없다" 로 함수가 반환한다 -- PDF 를 아예
#  안 만드는, 이번 변경과 무관한 별개 경로다. epoch_start 는 있지만
#  live_s 만 없는 행이라야 `use` 는 안 비면서(pair_summary 가 자기
#  live_s>0 를 따로 갖는다) typeRate 만 비어, 실제로 고친 코드 경로를 지난다.
mkdir -p "$T/out2"
RUNSUM2="$T/out2/run_summary.tsv"
{
   echo "# RENE DAQ run summary (fixture, degenerate: live_s<=0 rows only)"
   echo "# schema 2"
   printf '#run\tn_subrun\tn_bad\tepoch_start\tepoch_end\twall_s\tspan_s\tlive_s\tdead_s\tn_type1\tn_type2\tn_type3\tsource\n'
} > "$RUNSUM2"
awk -v base="$BASE" 'BEGIN {
   for (i = 0; i < 3; i++) {
      run = 5000 + i
      es  = base + i * 86400
      ee  = es + 3600
      #  epoch_start/end 는 채우고 live_s(8열) 만 0 으로 둔다.
      printf "%d\t10\t0\t%d\t%d\t3600.000\t3600.000\t0.000\t0.000\t0\t0\t0\tprd\n", run, es, ee
   }
}' >> "$RUNSUM2"
cp "$PAIRSUM" "$T/out2/pair_summary.tsv"      # 유효한 pair_summary 를 그대로 재사용

RUNSUM_OUT="$T/out2" RENE_COND="$COND" "$DIR/tools/monitor/rate-trend.sh" \
   > "$T/log2" 2>&1
RC2=$?
[ "$RC2" -eq 0 ] || { echo "FAIL: 퇴화 경로 rate-trend.sh exit=$RC2"; tail -60 "$T/log2"; exit 1; }

FAIL2=0
PDF2="$T/out2/rate_trend.pdf"
if [ ! -s "$PDF2" ]; then
   echo "FAIL: 퇴화 경로에 rate_trend.pdf 가 없다"; FAIL2=1
else
   #  1순위 pdfinfo(이 호스트에 이미 있다 -- 새 의존 아님). 없는 호스트를
   #  대비해 %%EOF 꼬리 검사도 항상 같이 한다(의존 없음).
   if command -v pdfinfo >/dev/null 2>&1; then
      if ! pdfinfo "$PDF2" >"$T/pdfinfo2.log" 2>&1; then
         echo "FAIL: pdfinfo 가 퇴화 경로 PDF 를 거부함 (닫히지 않은 것으로 보임)"
         cat "$T/pdfinfo2.log"; FAIL2=1
      fi
   else
      echo "[NOTE] pdfinfo 없음 -- %%EOF 꼬리 검사만으로 판정한다"
   fi
   case "$(tail -c 16 "$PDF2" | tr -d '\0')" in
      *%%EOF*) : ;;
      *) echo "FAIL: 퇴화 경로 PDF 끝에 %%EOF 가 없다 (마감이 안 됐다)"; FAIL2=1 ;;
   esac
fi

#  typeRate 가 정말 비었는지도 확인한다 -- 새 4종 PNG 는 이 경로에서 안
#  나오는 게 정상이다(기존 페이지들의 "자료 없으면 안 그린다" 관례와 같다).
#  나왔다면 픽스처가 의도한 조건(typeRate 빈 상태)을 못 만든 것이라 이
#  시험이 뭘 확인했는지가 불확실해진다.
for nm in evt_total evt_target evt_veto evt_coinc; do
   [ ! -e "$T/out2/rate_trend_${nm}.png" ] || {
      echo "FAIL: 퇴화 경로인데 ${nm}.png 가 나왔다 (픽스처가 typeRate 를 못 비웠다)"
      FAIL2=1
   }
done

if [ "$FAIL2" -ne 0 ]; then
   echo "----- log2 -----"
   tail -60 "$T/log2"
   exit 1
fi

echo "PASS monitor-typetrend (7 기존 + 4 신규 PNG, PDF 11쪽; 퇴화 경로 마감 확인)"
