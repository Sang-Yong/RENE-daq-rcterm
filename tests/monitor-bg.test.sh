#!/usr/bin/env bash
# monitor-bg.test.sh -- 배경 레시피 v2 (Li/He 적합 + 시간 역방향 대조, fast-n 사이드밴드가
# 포화 사건을 센다, accidental rate-곱, PSD n-like), IBD 컷 오버라이드, --verify 의
# 거부/판별을 **합성 DST(schema 2)** 로 확인한다.
#
# 실데이터도 /scratch 도 건드리지 않는다 -- DST 를 임시 디렉터리에 직접 만들고
# 그 안에서만 돌린다. 그래서 런이 하나도 없는 새 PC 에서도 그대로 돌아간다.
#
# 픽스처가 심는 것 (참값)
#   샤워링 뮤온 2,000개, 간격 **Poisson(평균 5 s)**, pe=30000  <- 우발항이 R_μ e^{-R_μ t}
#   뮤온 상관 후보 500쌍 : 4번째 뮤온마다 dt ~ Exp(τ=0.257 s)   <- 적합이 되찾아야 하는 수
#   우발 후보 1,000쌍    : 런 전체에 고르게
#   짝 없는 배경 싱글 2,000개
#   포화 사이드밴드 40쌍 : T_Sat 에 30 MeV 상당 prompt + 뒤따르는 S2   <- fast-n 이 세야 한다
#   psd : γ-band N(0.30, 0.03). 우발 후보 prompt 중 앞 60개만 0.45 (n-like)
# S1/S2 에너지와 dt 는 CurrentPairWindows() 의 **중앙값**으로 만든다 --
# 사이트 상수(AnalysisCondition.h)가 바뀌어도 이 시험이 따라간다.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh 2>/dev/null
command -v root >/dev/null 2>&1 || { echo "SKIP: ROOT 없음"; exit 0; }

RUN=999999
NSIG=500                    # 픽스처가 심은 Li/He 참값
NSAT=40                     # 포화 사이드밴드 쌍
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/out/dst" "$T/out2/dst"

# ---------------------------------------------------------------- 픽스처 ----
cat > "$T/mkdst.C" <<'EOF2'
#include "TOOLDIR/RenePrdSingles.h"
#include "TOOLDIR/RenePairing.h"
#include <TRandom3.h>
struct Fx { S1S2_Candidate c; Float_t psd; };
void mkdst() {
   const double kTau   = 0.257;
   const int    kNMu   = 2000;
   const double kMuMeanUs = 5.0e6;            // Poisson 간격 평균 5 s -> R_μ = 0.2 Hz
   const int    kNSig = 500, kNFlat = 1000, kNBg = 2000, kNSat = 40, kNNlike = 60;

   SetChannel(CH_NGD);
   PairWindows w = CurrentPairWindows();
   double e1  = 0.5 * (w.s1lo + w.s1hi);
   double e2  = 0.5 * (w.s2lo + w.s2hi);
   double eBg = MeVToNpe(2.0);                // 1-3 MeV : PSD γ-band 표본이 되면서 S2 창 밖
   double dtP = 0.5 * (w.dtMin + w.dtMax);
   double eSat = MeVToNpe(30.0);              // 사이드밴드 [12,50] MeV 안
   TRandom3 rnd(20260908);

   std::vector<ReneMuon> mu;
   double tm = 0;
   for (int i = 0; i < kNMu; ++i) {
      tm += rnd.Exp(kMuMeanUs);
      ReneMuon m; m.sub = 0; m.t_us = tm; m.pe = 30000; m.sat = 1;
      mu.push_back(m);
   }
   const double kRunUs = tm + 20.0e6;

   std::vector<Fx> ev;
   auto gpsd = [&]() { return (Float_t)rnd.Gaus(0.30, 0.03); };
   ev.push_back({{-1, 0, 0.0, w.lower * 0.1}, gpsd()});
   int id = 0;
   for (int k = 0; k < kNSig; ++k) {          // 뮤온 상관 (Li/He 참값). 4번째 뮤온마다
      double t = mu[4 * k].t_us + rnd.Exp(kTau) * 1e6;
      ev.push_back({{id++, 0, t,        e1}, gpsd()});
      ev.push_back({{id++, 0, t + dtP,  e2}, gpsd()});
   }
   for (int k = 0; k < kNFlat; ++k) {         // 우발. 앞 kNNlike 개의 prompt 만 n-like psd
      double t = rnd.Uniform(0.0, kRunUs);
      ev.push_back({{id++, 0, t,        e1}, (k < kNNlike) ? (Float_t)0.45 : gpsd()});
      ev.push_back({{id++, 0, t + dtP,  e2}, gpsd()});
   }
   for (int k = 0; k < kNBg; ++k)             // 짝 없는 배경 싱글
      ev.push_back({{id++, 0, rnd.Uniform(0.0, kRunUs), eBg}, gpsd()});
   //  포화 사이드밴드 : prompt 는 T_Sat 에만, 뒤따르는 S2 는 single 에
   std::vector<ReneSat> sats;
   for (int k = 0; k < kNSat; ++k) {
      double t = rnd.Uniform(0.0, kRunUs);
      sats.push_back({0, t, (Float_t)eSat});
      ev.push_back({{id++, 0, t + dtP, e2}, gpsd()});
   }
   std::sort(ev.begin(), ev.end(), [](const Fx&a, const Fx&b){ return a.c._t_us < b.c._t_us; });
   std::sort(sats.begin(), sats.end(), [](const ReneSat&a, const ReneSat&b){ return a.t_us < b.t_us; });

   TFile *f = TFile::Open("OUTDST", "RECREATE");
   TTree *tS = new TTree("T_Singles", "clean singles, whole run, time order");
   Int_t s_evt = 0, s_sub = 0; Double_t s_t = 0; Float_t s_pe = 0, s_psd = -1;
   tS->Branch("evt_id", &s_evt); tS->Branch("sub_id", &s_sub);
   tS->Branch("t_us",   &s_t);   tS->Branch("pe",     &s_pe); tS->Branch("psd", &s_psd);
   for (const auto &x : ev) {
      s_evt = x.c._evt_id; s_sub = x.c._sub_id; s_t = x.c._t_us; s_pe = (Float_t)x.c._pe_sum; s_psd = x.psd;
      tS->Fill();
   }
   TTree *tX = new TTree("T_Sat", "saturated events past the muon cuts, time order");
   Int_t x_sub = 0; Double_t x_t = 0; Float_t x_pe = 0;
   tX->Branch("sub_id", &x_sub); tX->Branch("t_us", &x_t); tX->Branch("pe", &x_pe);
   for (const auto &x : sats) { x_sub = x.sub; x_t = x.t_us; x_pe = x.pe; tX->Fill(); }
   TTree *tM = new TTree("T_Muons", "muon veto events, whole run, time order");
   Int_t m_sub = 0; Double_t m_t = 0; Float_t m_pe = -1; Char_t m_sat = 0;
   tM->Branch("sub_id", &m_sub); tM->Branch("t_us", &m_t);
   tM->Branch("pe",     &m_pe);  tM->Branch("sat",  &m_sat);
   for (const auto &m : mu) { m_sub = m.sub; m_t = m.t_us; m_pe = m.pe; m_sat = m.sat; tM->Fill(); }
   TTree *tI = new TTree("T_Info", "DST build metadata (one entry)");
   Int_t i_run = 999999, i_nsub = 1, i_nbad = 0, i_schema = 2, i_psd = 40;
   Double_t i_thr = w.lower, i_veto = 150.0, i_live = kRunUs * 1e-6;
   Long64_t i_built = 0;
   tI->Branch("run", &i_run);           tI->Branch("thr_npe", &i_thr);
   tI->Branch("veto_us", &i_veto);      tI->Branch("n_subrun", &i_nsub);
   tI->Branch("n_bad", &i_nbad);        tI->Branch("live_s", &i_live);
   tI->Branch("built", &i_built);       tI->Branch("schema", &i_schema);
   tI->Branch("psd_tail_ns", &i_psd);
   tI->Fill();
   f->cd(); tS->Write(); tX->Write(); tM->Write(); tI->Write(); f->Close();
   printf("FIXTURE singles=%zu sat=%zu muons=%zu live=%.0fs\n", ev.size(), sats.size(), mu.size(), i_live);
}
EOF2
sed -i "s|TOOLDIR|$DIR/tools/monitor|g; s|OUTDST|$T/out/dst/DST_$RUN.root|g" "$T/mkdst.C"
root -l -b -q "$T/mkdst.C+" > "$T/log0" 2>&1 || { echo "FAIL fixture"; tail -20 "$T/log0"; exit 1; }
grep -q '^FIXTURE ' "$T/log0" || { echo "FAIL fixture(출력 없음)"; tail -20 "$T/log0"; exit 1; }
ln -s "$T/out/dst/DST_$RUN.root" "$T/out2/dst/DST_$RUN.root"

# ------------------------------------------------------------------ 컷 파일 ----
cat > "$T/cuts_a.params" <<'EOF3'
mu_shower_npe = 20000
lihe_fit_lo_s = 0.002
lihe_fit_hi_s = 10.0
lihe_min_cand = 100
lihe_li_frac  = 1.0
fn_e_lo_mev   = 12.0
fn_e_hi_mev   = 50.0
psd_nsig      = 3.0
EOF3
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
grep -q '^# schema 2' "$M" || { echo "FAIL schema"; exit 1; }

N_IBD=$(col 7 "$M");  N_LIHE=$(col 14 "$M"); E_LIHE=$(col 15 "$M"); LIHE_STAT=$(col 16 "$M")
N_FN_SIDE=$(col 17 "$M"); N_FN_SC=$(col 18 "$M"); FN_SAT=$(col 20 "$M")
N_REV=$(col 21 "$M"); E_REV=$(col 22 "$M"); R_MU=$(col 23 "$M")
N_ACCI_RP=$(col 24 "$M"); N_NLIKE=$(col 28 "$M"); PSD_MEAN=$(col 26 "$M")
echo "  측정 : lihe=$N_LIHE±$E_LIHE ($LIHE_STAT)  rev=$N_REV±$E_REV  R_μ=$R_MU" \
     " fn_side=$N_FN_SIDE (scaled $N_FN_SC, sat_frac $FN_SAT)  acci_rp=$N_ACCI_RP" \
     " psd_mean=$PSD_MEAN n-like=$N_NLIKE  ibd=$N_IBD   (참값 lihe=$NSIG, sat쌍=$NSAT)"

echo "CHK lihe_stat=$LIHE_STAT" > "$T/chk"
#  참값 500 이 적합값의 ±3σ 안이면서 절대 밴드 ±20 % 안인가 (둘 다).
awk -v n="$N_LIHE" -v e="$E_LIHE" -v t="$NSIG" \
   'BEGIN{d=n-t; if(d<0)d=-d; print "CHK lihe_range=" ((e>0 && d<=3*e && d<=0.2*t)?1:0)}' >> "$T/chk"
#  시간 역방향 대조는 물리 상관이 없다 -> 0 과 맞아야 한다 (3σ 또는 참값의 10 % 안)
awk -v n="$N_REV" -v e="$E_REV" -v t="$NSIG" \
   'BEGIN{print "CHK lihe_rev_zero=" ((e>=0 && (n<=3*e || n<=0.1*t))?1:0)}' >> "$T/chk"
#  R_μ 가 픽스처의 0.2 Hz 근처인가 (±20 %)
awk -v r="$R_MU" 'BEGIN{print "CHK rmu=" ((r>0.16 && r<0.24)?1:0)}' >> "$T/chk"
#  포화 사이드밴드 : 40쌍 중 multiplicity 통과분(우연히 이웃이 있는 것 몇 개 제외)이 세어져야 한다
awk -v v="$N_FN_SIDE" -v t="$NSAT" 'BEGIN{print "CHK fn_side_sat=" ((v>=0.7*t && v<=t)?1:0)}' >> "$T/chk"
awk -v v="$FN_SAT" 'BEGIN{print "CHK fn_sat_frac=" ((v>=0.99)?1:0)}' >> "$T/chk"
awk -v v="$N_FN_SC" 'BEGIN{print "CHK fn_scaled_pos=" ((v>0)?1:0)}' >> "$T/chk"
awk -v v="$N_ACCI_RP" 'BEGIN{print "CHK acci_rp_pos=" ((v>0)?1:0)}' >> "$T/chk"
#  n-like : 우발 prompt 60개 중 multiplicity 통과분. 30 이상이면 잡은 것
awk -v v="$N_NLIKE" -v m="$PSD_MEAN" 'BEGIN{print "CHK psd_nlike=" ((v>=30 && m>0.25 && m<0.35)?1:0)}' >> "$T/chk"

# ------------------------------------------------- 2) IBD 컷 오버라이드 ----
MONITORCUTS="$T/cuts_b.params" RUNSUM_OUT="$T/out2" \
   "$DIR/tools/monitor/metrics.sh" --list "$RUN" > "$T/log2" 2>&1 \
   || { echo "FAIL build(override)"; tail -30 "$T/log2"; exit 1; }
N_IBD_OVR=$(col 7 "$M2"); S2LO_OVR=$(col 32 "$M2")
awk -v a="$N_IBD" -v b="$N_IBD_OVR" -v s="$S2LO_OVR" \
   'BEGIN{print "CHK override_moves=" ((a>0 && b<a && s==20)?1:0)}' >> "$T/chk"

# ------------------------------------- 3) 오버라이드가 있으면 --verify 거부 ----
cp "$M2" "$T/out2/pair_summary.tsv"
VOUT=$(MONITORCUTS="$T/cuts_b.params" RUNSUM_OUT="$T/out2" \
       "$DIR/tools/monitor/metrics.sh" --verify 2>&1); VRC=$?
if [ "$VRC" -eq 1 ] && printf '%s' "$VOUT" | grep -q '거부'; then
   echo "CHK verify_refused=1" >> "$T/chk"
else
   echo "CHK verify_refused=0 (rc=$VRC : $VOUT)" >> "$T/chk"
fi

# --------------------------- 4) --verify 가 실제로 차이를 잡는가 (음성 대조) ----
P="$T/out/pair_summary.tsv"
{ printf '# fixture pair_summary (verify 판별용)\n# schema 2\n'
  awk -F'\t' '!/^#/ {printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                     $1,$2,$3,$4,$5,$6,$7,$8}' "$M"; } > "$P"
V1=$(MONITORCUTS="$T/cuts_a.params" RUNSUM_OUT="$T/out" \
     "$DIR/tools/monitor/metrics.sh" --verify 2>&1); R1=$?
awk -F'\t' -v OFS='\t' '/^#/{print;next} {if(!done && $1!~/^#/){$7=$7+1; done=1} print}' \
   "$P" > "$P.bad" && mv "$P.bad" "$P"
V2=$(MONITORCUTS="$T/cuts_a.params" RUNSUM_OUT="$T/out" \
     "$DIR/tools/monitor/metrics.sh" --verify 2>&1); R2=$?
if [ "$R1" -eq 0 ] && printf '%s' "$V1" | grep -q '불일치 0' \
   && [ "$R2" -eq 1 ] && printf '%s' "$V2" | grep -q '\[DIFF\]'; then
   echo "CHK verify_discriminates=1" >> "$T/chk"
else
   echo "CHK verify_discriminates=0 (같음 rc=$R1 / 틀림 rc=$R2)" >> "$T/chk"
fi

# ------------------------------------------------------------------ 판정 ----
cat "$T/chk"
FAIL=0
for k in lihe_stat=ok lihe_range=1 lihe_rev_zero=1 rmu=1 fn_side_sat=1 fn_sat_frac=1 \
         fn_scaled_pos=1 acci_rp_pos=1 psd_nlike=1 override_moves=1 verify_refused=1 \
         verify_discriminates=1; do
   grep -qx "CHK $k" "$T/chk" || { echo "FAIL $k"; FAIL=1; }
done
[ "$FAIL" -eq 0 ] || { echo "---- 빌드 로그 끝 ----"; tail -12 "$T/log1"; exit 1; }
echo "PASS monitor-bg (12/12)"
