#!/usr/bin/env bash
# monitor-bg.test.sh -- Li/He 적합과 fast-n 두 추정치(★예비 레시피), IBD 컷
# 오버라이드, 그리고 --verify 의 거부/판별을 **합성 DST** 로 확인한다.
#
# 실데이터도 /scratch 도 건드리지 않는다 -- DST 를 임시 디렉터리에 직접 만들고
# 그 안에서만 돌린다. 그래서 런이 하나도 없는 새 PC 에서도 그대로 돌아간다.
#
# 픽스처가 심는 것 (참값)
#   뮤온 1,000개, 전부 샤워링(pe=5000), 10 s 간격
#   뮤온 상관 후보 500쌍 : 뮤온 뒤 dt ~ Exp(τ=0.257 s)  <- 적합이 되찾아야 하는 수
#   우발 후보 1,000쌍    : 런 전체에 고르게 (dt 분포가 평평한 성분)
#   짝 없는 배경 싱글 2,000개
# S1/S2 에너지와 dt 는 CurrentPairWindows() 의 **중앙값**으로 만든다 --
# 사이트 상수(AnalysisCondition.h)가 바뀌어도 이 시험이 따라간다.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh 2>/dev/null
command -v root >/dev/null 2>&1 || { echo "SKIP: ROOT 없음"; exit 0; }

RUN=999999
NSIG=500                    # 픽스처가 심은 Li/He 참값
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/out/dst" "$T/out2/dst"

# ---------------------------------------------------------------- 픽스처 ----
cat > "$T/mkdst.C" <<'EOF2'
#include "TOOLDIR/RenePrdSingles.h"
#include "TOOLDIR/RenePairing.h"
#include <TRandom3.h>
void mkdst() {
   const double kTau      = 0.257;      // 참값 [s] (⁹Li)
   const int    kNMu      = 1000;
   const double kMuStepUs = 1.0e7;      // 10 s
   const double kRunUs    = kNMu * kMuStepUs;
   const int    kNSig = 500, kNFlat = 1000, kNBg = 2000;

   SetChannel(CH_NGD);
   PairWindows w = CurrentPairWindows();
   double e1  = 0.5 * (w.s1lo + w.s1hi);      // S1 창 중앙
   double e2  = 0.5 * (w.s2lo + w.s2hi);      // S2 창 중앙
   double eBg = 0.5 * (w.lower + w.s2lo);     // S1 창 안, S2 창 **밖**
   double dtP = 0.5 * (w.dtMin + w.dtMax);
   TRandom3 rnd(20260908);                    // 고정 씨앗. 값이 흔들리면 안 된다

   std::vector<ReneMuon> mu;
   for (int i = 0; i < kNMu; ++i) {
      ReneMuon m; m.sub = 0; m.t_us = (i + 0.05) * kMuStepUs; m.pe = 5000; m.sat = 0;
      mu.push_back(m);
   }

   std::vector<S1S2_Candidate> ev;
   //  index 0 자리를 채우는 낮은 에너지 이력. 진짜 i1==0 인 S1 은
   //  multiplicity 가 언제나 떨어진다 (monitor-pairing.test.sh 와 같은 이유).
   ev.push_back({-1, 0, 0.0, w.lower * 0.1});
   int id = 0;
   for (int k = 0; k < kNSig; ++k) {          // 뮤온 상관 (Li/He 참값)
      double t = mu[2 * k].t_us + rnd.Exp(kTau) * 1e6;
      ev.push_back({id++, 0, t,        e1});
      ev.push_back({id++, 0, t + dtP,  e2});
   }
   for (int k = 0; k < kNFlat; ++k) {         // 우발 (dt 평평한 성분)
      double t = rnd.Uniform(0.0, kRunUs);
      ev.push_back({id++, 0, t,        e1});
      ev.push_back({id++, 0, t + dtP,  e2});
   }
   for (int k = 0; k < kNBg; ++k)             // 짝 없는 배경 싱글
      ev.push_back({id++, 0, rnd.Uniform(0.0, kRunUs), eBg});
   std::sort(ev.begin(), ev.end());           // T_Singles 는 시간 순이어야 한다

   TFile *f = TFile::Open("OUTDST", "RECREATE");
   TTree *tS = new TTree("T_Singles", "clean singles, whole run, time order");
   Int_t s_evt = 0, s_sub = 0; Double_t s_t = 0; Float_t s_pe = 0;
   tS->Branch("evt_id", &s_evt); tS->Branch("sub_id", &s_sub);
   tS->Branch("t_us",   &s_t);   tS->Branch("pe",     &s_pe);
   for (const auto &c : ev) {
      s_evt = c._evt_id; s_sub = c._sub_id; s_t = c._t_us; s_pe = (Float_t)c._pe_sum;
      tS->Fill();
   }
   TTree *tM = new TTree("T_Muons", "muon veto events, whole run, time order");
   Int_t m_sub = 0; Double_t m_t = 0; Float_t m_pe = -1; Char_t m_sat = 0;
   tM->Branch("sub_id", &m_sub); tM->Branch("t_us", &m_t);
   tM->Branch("pe",     &m_pe);  tM->Branch("sat",  &m_sat);
   for (const auto &m : mu) {
      m_sub = m.sub; m_t = m.t_us; m_pe = m.pe; m_sat = m.sat;
      tM->Fill();
   }
   TTree *tI = new TTree("T_Info", "DST build metadata (one entry)");
   Int_t i_run = 999999, i_nsub = 1, i_nbad = 0, i_schema = 1;
   Double_t i_thr = w.lower, i_veto = 150.0, i_live = kRunUs * 1e-6;
   Long64_t i_built = 0;
   tI->Branch("run", &i_run);           tI->Branch("thr_npe", &i_thr);
   tI->Branch("veto_us", &i_veto);      tI->Branch("n_subrun", &i_nsub);
   tI->Branch("n_bad", &i_nbad);        tI->Branch("live_s", &i_live);
   tI->Branch("built", &i_built);       tI->Branch("schema", &i_schema);
   tI->Fill();
   f->cd(); tS->Write(); tM->Write(); tI->Write(); f->Close();
   printf("FIXTURE singles=%zu muons=%zu\n", ev.size(), mu.size());
}
EOF2
sed -i "s|TOOLDIR|$DIR/tools/monitor|g; s|OUTDST|$T/out/dst/DST_$RUN.root|g" "$T/mkdst.C"
root -l -b -q "$T/mkdst.C+" > "$T/log0" 2>&1 || { echo "FAIL fixture"; tail -20 "$T/log0"; exit 1; }
grep -q '^FIXTURE ' "$T/log0" || { echo "FAIL fixture(출력 없음)"; tail -20 "$T/log0"; exit 1; }
ln -s "$T/out/dst/DST_$RUN.root" "$T/out2/dst/DST_$RUN.root"

# ------------------------------------------------------------------ 컷 파일 ----
#  A : 오버라이드 없음. fn_tag_s 만 1.0 (τ=0.257 s 픽스처의 대부분을 담게)
cat > "$T/cuts_a.params" <<'EOF3'
mu_shower_npe = 3000
lihe_fit_lo_s = 0.002
lihe_fit_hi_s = 10.0
lihe_min_cand = 100
fn_e_lo_mev   = 12.0
fn_e_hi_mev   = 50.0
fn_tag_s      = 1.0
EOF3
#  B : 같은 값 + S2 창을 픽스처가 심은 에너지에서 **비켜 세운다**
cp "$T/cuts_a.params" "$T/cuts_b.params"
printf 's2_lo_mev = 20\ns2_hi_mev = 30\n' >> "$T/cuts_b.params"

M="$T/out/metrics_summary.tsv"
M2="$T/out2/metrics_summary.tsv"
col() {   # col <열번호> <파일>
   local c=$1
   local f=$2
   awk -F'\t' -v r="$RUN" -v c="$c" '!/^#/ && $1==r && $2=="_nGd" {print $c}' "$f"
}

# ------------------------------------------------------------ 1) 기본 실행 ----
MONITORCUTS="$T/cuts_a.params" RUNSUM_OUT="$T/out" \
   "$DIR/tools/monitor/metrics.sh" --list "$RUN" > "$T/log1" 2>&1 \
   || { echo "FAIL build"; tail -30 "$T/log1"; exit 1; }
[ -s "$M" ] || { echo "FAIL: metrics_summary.tsv 없음"; tail -30 "$T/log1"; exit 1; }

LIHE_STAT=$(col 16 "$M"); N_LIHE=$(col 14 "$M"); E_LIHE=$(col 15 "$M")
N_FN_SIDE=$(col 17 "$M"); N_FN_MUTAG=$(col 19 "$M"); N_IBD=$(col 7 "$M")
echo "  측정 : lihe=$N_LIHE±$E_LIHE ($LIHE_STAT)  fn_side=$N_FN_SIDE" \
     " fn_mutag=$N_FN_MUTAG  ibd=$N_IBD   (참값 lihe=$NSIG)"

echo "CHK lihe_stat=$LIHE_STAT" > "$T/chk"
#  참값 500 이 적합값의 ±3σ 안에 있는가. σ 가 0 이면 '맞았다' 가 아니라
#  '적합이 오차를 못 냈다' 는 뜻이므로 떨어뜨린다.
#
#  ★ ±3σ 만으로는 부족해서 절대 밴드 ±20% 를 **함께** 요구한다. 두 지수(τ=257/
#    172 ms)가 거의 축퇴라 MINUIT 이 합을 둘로 나누는 방식에 따라 개별 오차가
#    크게 흔들린다 -- 씨앗 6개 실측 e_lihe = 41 / 77 / 111 / 119 / 202 / 706.
#    σ 만 보면 '오차가 커서 통과' 하는 일이 생긴다. 반면 **중심값**은 매우
#    안정적이다 (같은 6개에서 481~515, 참값 500 대비 최대 편차 19 = 3.8%).
#    그래서 밴드를 그 다섯 배쯤인 20% 로 잡았다 -- 느슨하게 푼 것이 아니라
#    σ 가 터졌을 때를 대비해 **더 조인** 것이다.
awk -v n="$N_LIHE" -v e="$E_LIHE" -v t="$NSIG" \
   'BEGIN{d=n-t; if(d<0)d=-d; print "CHK lihe_range=" ((e>0 && d<=3*e && d<=0.2*t)?1:0)}' \
   >> "$T/chk"
awk -v v="$N_FN_SIDE"  'BEGIN{print "CHK fn_side_zero=" ((v==0)?1:0)}'  >> "$T/chk"
awk -v v="$N_FN_MUTAG" 'BEGIN{print "CHK mutag_pos="   ((v>0)?1:0)}'    >> "$T/chk"

# ------------------------------------------------- 2) IBD 컷 오버라이드 ----
MONITORCUTS="$T/cuts_b.params" RUNSUM_OUT="$T/out2" \
   "$DIR/tools/monitor/metrics.sh" --list "$RUN" > "$T/log2" 2>&1 \
   || { echo "FAIL build(override)"; tail -30 "$T/log2"; exit 1; }
N_IBD_OVR=$(col 7 "$M2"); S2LO_OVR=$(col 23 "$M2")
awk -v a="$N_IBD" -v b="$N_IBD_OVR" -v s="$S2LO_OVR" \
   'BEGIN{print "CHK override_moves=" ((a>0 && b<a && s==20)?1:0)}' >> "$T/chk"

# ------------------------------------- 3) 오버라이드가 있으면 --verify 거부 ----
cp "$M2" "$T/out2/pair_summary.tsv"      # 대조할 짝이 있어도 거부해야 한다
VOUT=$(MONITORCUTS="$T/cuts_b.params" RUNSUM_OUT="$T/out2" \
       "$DIR/tools/monitor/metrics.sh" --verify 2>&1); VRC=$?
if [ "$VRC" -eq 1 ] && printf '%s' "$VOUT" | grep -q '거부'; then
   echo "CHK verify_refused=1" >> "$T/chk"
else
   echo "CHK verify_refused=0 (rc=$VRC : $VOUT)" >> "$T/chk"
fi

# --------------------------- 4) --verify 가 실제로 차이를 잡는가 (음성 대조) ----
#  게이트가 '언제나 통과' 라면 게이트가 아니다. 같은 값이면 통과하고, 한 칸만
#  틀어 놓으면 떨어지는지 **둘 다** 본다.
P="$T/out/pair_summary.tsv"
{ printf '# fixture pair_summary (verify 판별용)\n# schema 2\n'
  awk -F'\t' '!/^#/ {printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                     $1,$2,$3,$4,$5,$6,$7,$8}' "$M"; } > "$P"
V1=$(MONITORCUTS="$T/cuts_a.params" RUNSUM_OUT="$T/out" \
     "$DIR/tools/monitor/metrics.sh" --verify 2>&1); R1=$?
#  n_ibd(7열)를 한 행만 손으로 어긋나게 한다
awk -F'\t' -v OFS='\t' '/^#/{print;next} {if(!done && $1!~/^#/){$7=$7+1; done=1} print}' \
   "$P" > "$P.bad" && mv "$P.bad" "$P"
V2=$(MONITORCUTS="$T/cuts_a.params" RUNSUM_OUT="$T/out" \
     "$DIR/tools/monitor/metrics.sh" --verify 2>&1); R2=$?
if [ "$R1" -eq 0 ] && printf '%s' "$V1" | grep -q '불일치 0' \
   && [ "$R2" -eq 1 ] && printf '%s' "$V2" | grep -q '\[DIFF\]'; then
   echo "CHK verify_discriminates=1" >> "$T/chk"
else
   echo "CHK verify_discriminates=0 (같음 rc=$R1 / 틀림 rc=$R2)" >> "$T/chk"
   echo "$V1"; echo "$V2"
fi

# ------------------------------------------------------------------ 판정 ----
cat "$T/chk"
FAIL=0
for k in lihe_stat=ok lihe_range=1 fn_side_zero=1 mutag_pos=1 \
         override_moves=1 verify_refused=1 verify_discriminates=1; do
   grep -qx "CHK $k" "$T/chk" || { echo "FAIL $k"; FAIL=1; }
done
[ "$FAIL" -eq 0 ] || exit 1
echo "PASS monitor-bg (7/7)"
