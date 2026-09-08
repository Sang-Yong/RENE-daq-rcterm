// ---------------------------------------------------------------------------
//  PsdAnalyze.C - PsdScan 트리에서 '상관 prompt'(선원 중성자 사건) 와 'γ 참조' 의
//                 펄스 모양 변수 분포를 만들어 분리력(FoM)과 위치 의존을 낸다.
//
//  ★ 2025-11 선원 런은 Gd 없는 LS 였다 (실측 : n-Gd 창 상관 없음, n-H 창 상관 수천).
//    그래서 포획 = n-H 2.2 MeV, τ≈200 µs. on-window [5,400] µs, off [1000,1395] µs.
//
//  표본
//     corr(E)   prompt 에너지 밴드 E 의 사건 중 뒤 on-window 안에 n-H 포획이 따르는 것
//               에서 off-window 짝을 뺀 것 = 선원 중성자와 상관된 prompt (γ+recoil 혼합)
//     gam       n-H 창 사건 중 앞 on-window 안에 prompt 가 있는 것 − off 짝 = 포획 γ (2.2 MeV)
//     unc(E)    같은 밴드의 off 짝 = 우발(무상관) 사건. 대부분 γ + 뮤온 조각
//  변수 : mt(양채널 전하가중) tail30 tail40 tail50 pkfrac fwhm rise  (+ 채널별 mt)
//  FoM  = |m_corr − m_ref| / sqrt(s_corr² + s_ref²)
//
//  사용 : root -l -b -q 'PsdAnalyze.C+("/scratch/RunSummary/psd/psdscan_002821.root", "/scratch/RunSummary/psd/")'
//         -> 표(stdout, TSV 한 줄/밴드·변수) + psdana_<run>.root (히스토그램)
// ---------------------------------------------------------------------------
#include "/home/ojk/analysis3/essential/AnalysisCondition.h"
#include <TFile.h>
#include <TTree.h>
#include <TH1D.h>
#include <TString.h>
#include <TSystem.h>
#include <cmath>
#include <cstdio>
#include <vector>
#include <map>

struct Var { const char *name; double lo, hi; };
static const Var kVars[] = {
   {"mt",     0, 60}, {"mt0", 0, 60}, {"mt1", 0, 60},
   {"tail20", 0, 0.7}, {"tail30", 0, 0.6}, {"tail40", 0, 0.5}, {"tail50", 0, 0.4},
   {"pkfrac", 0, 0.08}, {"fwhm", 0, 80}, {"rise", 0, 30}};
static const int kNVar = sizeof(kVars) / sizeof(kVars[0]);
static const double kBands[][2] = {{0.6,1.2},{1.2,2.0},{2.0,3.0},{3.0,4.5},{4.5,6.0}};
static const int kNBand = 5;

#include <TMatrixD.h>
#include <TVectorD.h>
#include <array>
//  5 변수(mt, tail30, pkfrac, fwhm, rise)의 가중 평균·공분산 -- Fisher 판별용
struct WCov { double n=0; double sx[5]={0,0,0,0,0}; double sxx[5][5]={{0}};
   void add(const std::array<float,10>&v, double w){ int idx[5]={0,4,7,8,9}; n+=w; for(int a=0;a<5;a++){ double xa=v[idx[a]]; sx[a]+=w*xa; for(int b=0;b<5;b++) sxx[a][b]+=w*xa*v[idx[b]]; } }
   void sub(const WCov&o){ n-=o.n; for(int a=0;a<5;a++){ sx[a]-=o.sx[a]; for(int b=0;b<5;b++) sxx[a][b]-=o.sxx[a][b]; } }
   TVectorD mean() const { TVectorD m(5); for(int a=0;a<5;a++) m[a]=n>0?sx[a]/n:0; return m; }
   TMatrixD cov() const { TMatrixD c(5,5); TVectorD m=mean(); for(int a=0;a<5;a++) for(int b=0;b<5;b++) c[a][b]=n>0? sxx[a][b]/n-m[a]*m[b]:0; return c; } };
struct WStat { double n=0, sx=0, sxx=0; void add(double x, double w){ n+=w; sx+=w*x; sxx+=w*x*x; }
   double mean() const { return n>0 ? sx/n : 0; } double rms() const { double m=mean(); double v=n>0? sxx/n-m*m:0; return v>0?std::sqrt(v):0; } };

void PsdAnalyze(const char *scanFile, const char *outDir = "/scratch/RunSummary/psd/",
                const char *capMode = "nH",
                double onLo = -1, double onHi = -1, double offLo = -1, double offHi = -1) {
   //  capMode : "nH"  포획창 1.87-2.59 MeV, on [5,400] µs, off [1000,1395]  (Gd 없는 2025-11 선원 런)
   //            "nGd" 포획창 6-10 MeV,     on [1,100] µs,  off [1000,1099]  (Gd-LS, 2026-04~08 선원 런)
   //  창을 직접 주면(>=0) 그것이 이긴다.
   const bool gd = (TString(capMode) == "nGd");
   if (onLo  < 0) onLo  = gd ? 1.0    : 5.0;
   if (onHi  < 0) onHi  = gd ? 100.0  : 400.0;
   if (offLo < 0) offLo = 1000.0;
   if (offHi < 0) offHi = gd ? 1099.0 : 1395.0;
   TFile fin(scanFile);
   TTree *t = (TTree *)fin.Get("psd");
   if (!t) { printf("[SKIP] %s : psd 트리 없음\n", scanFile); return; }
   Int_t run, sub, pos; Double_t tu; Float_t pe, asym; Char_t sat;
   struct C { float q, pk, cfd, rise, fwhm, pkfrac, tail20, tail30, tail40, tail50, late, mt; char sat, has; } c0, c1;
   t->SetBranchAddress("run",&run); t->SetBranchAddress("sub",&sub); t->SetBranchAddress("pos",&pos);
   t->SetBranchAddress("t_us",&tu); t->SetBranchAddress("pe",&pe); t->SetBranchAddress("asym",&asym); t->SetBranchAddress("sat",&sat);
   t->SetBranchAddress("c0",&c0); t->SetBranchAddress("c1",&c1);
   Long64_t n = t->GetEntries();
   std::vector<double> T(n); std::vector<float> E(n); std::vector<int> S(n); std::vector<char> ok(n);
   std::vector<std::array<float,10>> V(n);
   int theRun = 0, thePos = -1;
   for (Long64_t i = 0; i < n; ++i) {
      t->GetEntry(i); theRun = run; thePos = pos;
      T[i] = tu; E[i] = pe; S[i] = sub;
      ok[i] = (!sat && c0.has && c1.has && c0.q > 0 && c1.q > 0) ? 1 : 0;
      double q = c0.q + c1.q;
      V[i] = {(float)((c0.mt*c0.q + c1.mt*c1.q)/q), c0.mt, c1.mt,
              (float)((c0.tail20*c0.q + c1.tail20*c1.q)/q),
              (float)((c0.tail30*c0.q + c1.tail30*c1.q)/q), (float)((c0.tail40*c0.q + c1.tail40*c1.q)/q),
              (float)((c0.tail50*c0.q + c1.tail50*c1.q)/q), (float)((c0.pkfrac*c0.q + c1.pkfrac*c1.q)/q),
              (float)(0.5*(c0.fwhm + c1.fwhm)), (float)(0.5*(c0.rise + c1.rise))};
   }
   //  prompt 태그(뒤에 포획이 따르나)는 모드의 창으로, γ 참조(포획 γ 자신)는 **언제나 n-H 2.2 MeV**
   //  로 잡는다 -- prompt 밴드(0.6-4.5 MeV)와 에너지가 맞는 순수 γ 표본이기 때문이다.
   //  Gd-LS 에서도 포획의 10-15 % 는 H 에서 일어나 n-H 봉우리가 있다.
   const double hLo = gd ? MeVToNpe(6.0) : MeVToNpe(1.87), hHi = gd ? MeVToNpe(10.0) : MeVToNpe(2.59);
   auto inCap = [&](Long64_t j) { return E[j] >= hLo && E[j] <= hHi; };
   const double gLo = MeVToNpe(1.87), gHi = MeVToNpe(2.59);
   const double gOnLo = 5.0, gOnHi = 400.0, gOffLo = 1000.0, gOffHi = 1395.0;
   auto inGamCap = [&](Long64_t j) { return E[j] >= gLo && E[j] <= gHi; };

   //  히스토그램 : [band][var][on/off], 그리고 γ 참조 [var][on/off], 에너지 스펙트럼
   TString out = outDir; if (!out.EndsWith("/")) out += "/";
   TFile fo(out + TString::Format("psdana_%06d%s.root", theRun, gd ? "_nGd" : ""), "RECREATE");
   std::vector<std::vector<TH1D*>> hOn(kNBand, std::vector<TH1D*>(kNVar)), hOff = hOn;
   std::vector<TH1D*> gOn(kNVar), gOff(kNVar);
   for (int b = 0; b < kNBand; ++b) for (int v = 0; v < kNVar; ++v) {
      hOn[b][v]  = new TH1D(Form("on_b%d_%s", b, kVars[v].name),  "", 60, kVars[v].lo, kVars[v].hi);
      hOff[b][v] = new TH1D(Form("off_b%d_%s", b, kVars[v].name), "", 60, kVars[v].lo, kVars[v].hi);
   }
   for (int v = 0; v < kNVar; ++v) {
      gOn[v]  = new TH1D(Form("gon_%s", kVars[v].name),  "", 60, kVars[v].lo, kVars[v].hi);
      gOff[v] = new TH1D(Form("goff_%s", kVars[v].name), "", 60, kVars[v].lo, kVars[v].hi);
   }
   TH1D *eOn = new TH1D("e_on", "prompt E (on)", 120, 0, 12), *eOff = new TH1D("e_off", "prompt E (off)", 120, 0, 12);
   TH1D *eCap = new TH1D("e_cap", "delayed E (on)", 100, 1, 4), *eCapOff = new TH1D("e_capoff", "delayed E (off)", 100, 1, 4);
   std::vector<std::vector<WStat>> sOn(kNBand, std::vector<WStat>(kNVar)), sOff = sOn;
   std::vector<WStat> sG(kNVar), sGoff(kNVar);
   std::vector<WCov> cOn(kNBand), cOff(kNBand); WCov cG, cGoff;
   long nPairOn = 0, nPairOff = 0;
   std::vector<char> tagOn(n,0), tagOff(n,0), capOn(n,0), capOff(n,0);

   for (Long64_t i = 0; i < n; ++i) {
      double mev = NpeToMeV(E[i]);
      //  ---- prompt 로서 : 뒤에 포획이 따르나 ----
      bool fon = false, foff = false;
      for (Long64_t j = i + 1; j < n; ++j) { if (S[j] != S[i]) break; double dt = T[j] - T[i]; if (dt > offHi) break;
         if (!inCap(j)) continue;
         if (!fon  && dt >= onLo  && dt < onHi)  fon  = true;
         if (!foff && dt >= offLo && dt < offHi) foff = true; }
      if (fon)  { nPairOn++;  eOn->Fill(mev); tagOn[i] = 1; }
      if (foff) { nPairOff++; eOff->Fill(mev); tagOff[i] = 1; }
      if (ok[i]) for (int b = 0; b < kNBand; ++b) if (mev >= kBands[b][0] && mev < kBands[b][1]) {
         for (int v = 0; v < kNVar; ++v) {
            if (fon)  { hOn[b][v]->Fill(V[i][v]);  sOn[b][v].add(V[i][v], 1); }
            if (foff) { hOff[b][v]->Fill(V[i][v]); sOff[b][v].add(V[i][v], 1); }
         }
         if (fon)  cOn[b].add(V[i], 1);
         if (foff) cOff[b].add(V[i], 1);
      }
      //  ---- 포획 γ 로서 (n-H 2.2 MeV) : 앞에 prompt 가 있나 ----
      if (inGamCap(i)) {
         bool pon = false, poff = false;
         for (Long64_t j = i - 1; j >= 0; --j) { if (S[j] != S[i]) break; double dt = T[i] - T[j]; if (dt > gOffHi) break;
            if (NpeToMeV(E[j]) < 0.6) continue;
            if (!pon  && dt >= gOnLo  && dt < gOnHi)  pon  = true;
            if (!poff && dt >= gOffLo && dt < gOffHi) poff = true; }
         if (pon)  { eCap->Fill(mev);    capOn[i] = 1; }
         if (poff) { eCapOff->Fill(mev); capOff[i] = 1; }
         if (ok[i]) for (int v = 0; v < kNVar; ++v) {
            if (pon)  { gOn[v]->Fill(V[i][v]);  sG[v].add(V[i][v], 1); }
            if (poff) { gOff[v]->Fill(V[i][v]); sGoff[v].add(V[i][v], 1); }
         }
         if (ok[i] && pon)  cG.add(V[i], 1);
         if (ok[i] && poff) cGoff.add(V[i], 1);
      }
   }
   //  ---- 표 : 상관(on−off) 대 γ 참조(on−off) ----
   printf("# run %d pos %d mm [%s] : pairs on %ld off %ld (excess %ld)\n", theRun, thePos, gd ? "nGd" : "nH", nPairOn, nPairOff, nPairOn - nPairOff);
   printf("#run\tpos\tband\tvar\tn_corr\tm_corr\ts_corr\tn_gam\tm_gam\ts_gam\tn_unc\tm_unc\ts_unc\tfom_gam\tfom_unc\n");
   for (int b = 0; b < kNBand; ++b) for (int v = 0; v < kNVar; ++v) {
      WStat corr; corr.n = sOn[b][v].n - sOff[b][v].n; corr.sx = sOn[b][v].sx - sOff[b][v].sx; corr.sxx = sOn[b][v].sxx - sOff[b][v].sxx;
      WStat gam;  gam.n  = sG[v].n - sGoff[v].n;       gam.sx  = sG[v].sx - sGoff[v].sx;       gam.sxx  = sG[v].sxx - sGoff[v].sxx;
      const WStat &unc = sOff[b][v];
      double fomG = (corr.n > 0 && gam.n > 0) ? std::fabs(corr.mean() - gam.mean()) / std::sqrt(corr.rms()*corr.rms() + gam.rms()*gam.rms()) : -1;
      double fomU = (corr.n > 0 && unc.n > 0) ? std::fabs(corr.mean() - unc.mean()) / std::sqrt(corr.rms()*corr.rms() + unc.rms()*unc.rms()) : -1;
      printf("%d\t%d\t[%.1f,%.1f)\t%s\t%.0f\t%.4f\t%.4f\t%.0f\t%.4f\t%.4f\t%.0f\t%.4f\t%.4f\t%.2f\t%.2f\n",
             theRun, thePos, kBands[b][0], kBands[b][1], kVars[v].name, corr.n, corr.mean(), corr.rms(),
             gam.n, gam.mean(), gam.rms(), unc.n, unc.mean(), unc.rms(), fomG, fomU);
   }
   //  ---- Fisher 판별 (mt, tail30, pkfrac, fwhm, rise) : corr(on-off) 대 γ(on-off) ----
   //  w = (S_c + S_g)^-1 (μ_c - μ_g). 투영값의 히스토그램(on/off/gon/goff)을 같이 남겨
   //  decomp 가 순수 recoil 성분을 뽑고 컷 효율을 잴 수 있게 한다.
   WCov gam = cG; gam.sub(cGoff);
   const int idx[5] = {0, 4, 7, 8, 9};
   for (int b = 0; b < kNBand; ++b) {
      WCov corr = cOn[b]; corr.sub(cOff[b]);
      if (corr.n < 50 || gam.n < 50) continue;
      TMatrixD S = corr.cov(); S += gam.cov();
      TVectorD d = corr.mean(); d -= gam.mean();
      TMatrixD Si(TMatrixD::kInverted, S);
      TVectorD w = Si * d;
      double mc = w * corr.mean(), mg = w * gam.mean();
      double vc = (w * (corr.cov() * w)), vg = (w * (gam.cov() * w));
      double fom = (vc > 0 && vg > 0) ? std::fabs(mc - mg) / std::sqrt(vc + vg) : -1;
      //  부호를 'γ 가 낮고 recoil 이 높게' 로 맞추고 γ 평균 0, γ 폭 1 로 규격화해 저장한다
      double sgn = (mc > mg) ? 1.0 : -1.0, sg = std::sqrt(vg > 0 ? vg : 1);
      auto proj = [&](const std::array<float,10> &v) { double x = 0; for (int a = 0; a < 5; ++a) x += w[a] * v[idx[a]]; return sgn * (x - mg) / sg; };
      TH1D *pOn  = new TH1D(Form("on_b%d_fisher", b),  "", 60, -6, 12), *pOff = new TH1D(Form("off_b%d_fisher", b), "", 60, -6, 12);
      TH1D *pGon = new TH1D(Form("gon_b%d_fisher", b), "", 60, -6, 12), *pGoff = new TH1D(Form("goff_b%d_fisher", b), "", 60, -6, 12);
      for (Long64_t i = 0; i < n; ++i) {
         if (!ok[i]) continue;
         double mev = NpeToMeV(E[i]);
         bool inB = (mev >= kBands[b][0] && mev < kBands[b][1]);
         if (inB && tagOn[i])  pOn->Fill(proj(V[i]));
         if (inB && tagOff[i]) pOff->Fill(proj(V[i]));
         if (capOn[i])  pGon->Fill(proj(V[i]));
         if (capOff[i]) pGoff->Fill(proj(V[i]));
      }
      printf("%d\t%d\t[%.1f,%.1f)\tfisher\t%.0f\t%.4f\t%.4f\t%.0f\t%.4f\t%.4f\t0\t0\t0\t%.2f\t-1\t# w(mt,tail30,pkfrac,fwhm,rise)= %.4g %.4g %.4g %.4g %.4g\n",
             theRun, thePos, kBands[b][0], kBands[b][1], corr.n, sgn*(mc-mg)/sg, std::sqrt(vc)/sg, gam.n, 0.0, 1.0, fom,
             w[0], w[1], w[2], w[3], w[4]);

      //  ---- fisherU : 참조를 같은 밴드의 off-window(에너지 일치, γ 우세) 로 ----
      //  8 MeV 포획 γ 를 참조로 쓰면 fwhm·pkfrac 의 에너지 의존이 분리력으로 둔갑한다.
      {
         const WCov &unc = cOff[b];
         if (unc.n < 50) continue;
         TMatrixD S2 = corr.cov(); S2 += unc.cov();
         TVectorD d2 = corr.mean(); d2 -= unc.mean();
         TMatrixD Si2(TMatrixD::kInverted, S2);
         TVectorD w2 = Si2 * d2;
         double mc2 = w2 * corr.mean(), mu2 = w2 * unc.mean();
         double vc2 = (w2 * (corr.cov() * w2)), vu2 = (w2 * (unc.cov() * w2));
         double fom2 = (vc2 > 0 && vu2 > 0) ? std::fabs(mc2 - mu2) / std::sqrt(vc2 + vu2) : -1;
         double sgn2 = (mc2 > mu2) ? 1.0 : -1.0, su2 = std::sqrt(vu2 > 0 ? vu2 : 1);
         auto proj2 = [&](const std::array<float,10> &v) { double x = 0; for (int a = 0; a < 5; ++a) x += w2[a] * v[idx[a]]; return sgn2 * (x - mu2) / su2; };
         TH1D *uOn = new TH1D(Form("on_b%d_fisherU", b), "", 60, -6, 12), *uOff = new TH1D(Form("off_b%d_fisherU", b), "", 60, -6, 12);
         for (Long64_t i = 0; i < n; ++i) {
            if (!ok[i]) continue;
            double mev = NpeToMeV(E[i]);
            if (!(mev >= kBands[b][0] && mev < kBands[b][1])) continue;
            if (tagOn[i])  uOn->Fill(proj2(V[i]));
            if (tagOff[i]) uOff->Fill(proj2(V[i]));
         }
         printf("%d\t%d\t[%.1f,%.1f)\tfisherU\t%.0f\t%.4f\t%.4f\t%.0f\t%.4f\t%.4f\t0\t0\t0\t%.2f\t-1\t# w(mt,tail30,pkfrac,fwhm,rise)= %.4g %.4g %.4g %.4g %.4g\n",
                theRun, thePos, kBands[b][0], kBands[b][1], corr.n, sgn2*(mc2-mu2)/su2, std::sqrt(vc2)/su2, unc.n, 0.0, 1.0, fom2,
                w2[0], w2[1], w2[2], w2[3], w2[4]);
      }
   }
   fo.Write(); fo.Close();
}
