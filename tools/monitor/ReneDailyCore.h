// ReneDailyCore.h — 날짜 기준 계산(BuildDaily.C)이 쓰는 도구 모음 (2026-09-14, 사용자 지시)
//
//   ★ 런별 파이프라인(BuildMetrics.C · RenePairing.h)은 손대지 않는다. 여기 있는 것은 그쪽 함수의 **쌍 단위 판본**과
//     그 파일의 static 함수 사본이다(LoadDst · ShowerTimes · LiHeWalk · FitLiHe). 컷·판정 논리는 한 글자도 다르지 않아야
//     하며, 그것을 tests/monitor-daily.test.sh 가 같은 합성 DST 로 대조한다.
#ifndef RENE_DAILY_CORE_H
#define RENE_DAILY_CORE_H

#include "RenePrdSingles.h"     // S1S2_Candidate, SetChannel, ChannelTag, ReneMuon, ReneSat, NpeToMeV
#include "RenePairing.h"        // PairWindows, CurrentPairWindows
#include <TF1.h>
#include <TFile.h>
#include <TH1D.h>
#include <TTree.h>
#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

static const double kDailyTauLiS = 0.257;    // ⁹Li 평균수명 [s]  (BuildMetrics.C 의 kTauLiS 와 같다)
static const double kDailyTauHeS = 0.172;    // ⁸He

//  쌍 하나. RenePairing.h::PairAndCountW 가 세는 것을 그대로 남긴다.
struct PairRec {
   double t1_us = 0, e1 = 0, e2 = 0;   // prompt 시각·NPE, delayed NPE
   double dt_us = 0;                   // delayed − prompt [µs]
   bool   off = false;                 // off-window(우발) 쌍인가
   bool   mult = false;                // multiplicity 통과 (= IBD / IBD_Acci 로 세어지는 것)
   long long i1 = -1;                  // prompt single 의 ev 색인 (psd 를 찾아가기 위해. 병합 목록에서는 뜻이 없다)
   int    nExtra = 0;                  // multiplicity 창([s1−isoPre, s1) · (s1, s2) · (s2, s2+isoPost]) 안의 다른 single 수 (lower 이상). 다중도 외삽용
};

//  PairAndCountW 와 같은 루프. 세는 대신 쌍을 모은다. (on-time 은 c.nCoinc/nCoincMult, off 는 nAcci/nAcciMult 와 개수가 같다)
inline std::vector<PairRec> PairListW(const std::vector<S1S2_Candidate> &ev, const PairWindows &w) {
   std::vector<PairRec> out;
   const long long nEv = (long long)ev.size();
   if (nEv == 0) return out;
   auto isS1 = [&](const S1S2_Candidate &e) { return e._pe_sum >= w.s1lo && e._pe_sum <= w.s1hi; };
   auto isS2 = [&](const S1S2_Candidate &e) { return e._pe_sum >= w.s2lo && e._pe_sum <= w.s2hi; };
   auto windowEnd = [&](long long i1) {
      long long ww = i1; double tLimit = ev[i1]._t_us + w.dtMax;
      while (ww + 1 < nEv && ev[ww + 1]._t_us <= tLimit) ++ww;
      return ww;
   };
   //  창 안의 다른 single 수. passMult 는 이웃 하나만 보지만(분석 코드 그대로) 외삽에는 전부 세어야 한다. mult 판정에는 쓰지 않는다
   auto countExtra = [&](long long i1, long long i2, long long wEnd) {
      int n = 0;
      for (long long q = i1 - 1; q >= 0 && ev[i1]._t_us - ev[q]._t_us < w.isoPre; --q) if (ev[q]._pe_sum >= w.lower) n++;
      for (long long q = i2 + 1; q < nEv && ev[q]._t_us - ev[i2]._t_us < w.isoPost; ++q) if (ev[q]._pe_sum >= w.lower) n++;
      n += (int)((double)(wEnd - i1) - ((i2 <= wEnd) ? 1.0 : 0.0));
      return n;
   };
   auto passMult = [&](double prevE, double prevT, double s1t, double nextE, double nextT, double s2t, double vetoExtra) {
      if (prevE >= w.lower && s1t - prevT < w.isoPre)  return false;
      if (nextE >= w.lower && nextT - s2t < w.isoPost) return false;
      if (vetoExtra > 0) return false;
      return true;
   };
   for (long long i2 = 0; i2 < nEv; ++i2) {                      // on-time
      const S1S2_Candidate &s2 = ev[i2];
      if (!isS2(s2)) continue;
      for (long long i1 = i2 - 1; i1 >= 0; --i1) {
         double dt = s2._t_us - ev[i1]._t_us;
         if (dt > w.dtMax) break;
         if (dt < w.dtMin) continue;
         const S1S2_Candidate &s1 = ev[i1];
         if (!isS1(s1)) continue;
         const long long wEnd = windowEnd(i1);
         const S1S2_Candidate &prev = (i1 > 0) ? ev[i1 - 1] : s1;
         const S1S2_Candidate &next = (i2 + 1 < nEv) ? ev[i2 + 1] : s2;
         double vetoExtra = (double)(wEnd - i1) - ((i2 <= wEnd) ? 1.0 : 0.0);
         PairRec p; p.t1_us = s1._t_us; p.e1 = s1._pe_sum; p.e2 = s2._pe_sum; p.off = false; p.i1 = i1; p.dt_us = dt;
         p.mult = passMult(prev._pe_sum, prev._t_us, s1._t_us, next._pe_sum, next._t_us, s2._t_us, vetoExtra);
         p.nExtra = countExtra(i1, i2, wEnd);
         out.push_back(p);
         break;
      }
   }
   const double accLo = w.dtAcci, accHi = w.dtAcci + w.dtMax;
   for (long long j = 0; j < nEv; ++j) {                          // off-time (우발)
      const S1S2_Candidate &s2 = ev[j];
      if (!isS2(s2)) continue;
      for (long long i = j - 1; i >= 1; --i) {
         double dt = s2._t_us - ev[i]._t_us;
         if (dt > accHi) break;
         if (dt < accLo) continue;
         const S1S2_Candidate &s1 = ev[i];
         if (!isS1(s1)) continue;
         const long long wEnd = windowEnd(i);
         const S1S2_Candidate &prev = ev[i - 1];
         const S1S2_Candidate &next = (j + 1 < nEv) ? ev[j + 1] : ev[j];
         double vetoExtra = (double)(wEnd - i) - ((j <= wEnd) ? 1.0 : 0.0);
         PairRec p; p.t1_us = s1._t_us; p.e1 = s1._pe_sum; p.e2 = s2._pe_sum; p.off = true; p.i1 = i; p.dt_us = dt - w.dtAcci;
         p.mult = passMult(prev._pe_sum, prev._t_us, s1._t_us, next._pe_sum, next._t_us, s2._t_us, vetoExtra);
         p.nExtra = countExtra(i, j, wEnd);
         out.push_back(p);
         break;
      }
   }
   return out;
}

//  BuildMetrics.C::LoadDst 의 사본
inline bool DailyLoadDst(const TString &dst, std::vector<S1S2_Candidate> &sing, std::vector<Float_t> &psd,
                         std::vector<ReneSat> &sats, std::vector<ReneMuon> &mu, double &liveS, int &nSubrun, int &schema,
                         double *vetoUs = nullptr, int *muonMode = nullptr) {
   TFile *f = TFile::Open(dst, "READ");
   if (!f || f->IsZombie()) { if (f) f->Close(); return false; }
   TTree *tS = (TTree *)f->Get("T_Singles"); TTree *tM = (TTree *)f->Get("T_Muons");
   TTree *tI = (TTree *)f->Get("T_Info");    TTree *tX = (TTree *)f->Get("T_Sat");
   if (!tS || !tM || !tI || tI->GetEntries() < 1) { f->Close(); return false; }
   const bool hasPsd = tS->GetBranch("psd") != nullptr;
   Int_t s_evt, s_sub; Double_t s_t; Float_t s_pe, s_psd = -1;
   tS->SetBranchAddress("evt_id", &s_evt); tS->SetBranchAddress("sub_id", &s_sub);
   tS->SetBranchAddress("t_us", &s_t);     tS->SetBranchAddress("pe", &s_pe);
   if (hasPsd) tS->SetBranchAddress("psd", &s_psd);
   for (Long64_t i = 0; i < tS->GetEntries(); ++i) { tS->GetEntry(i); sing.push_back({s_evt, s_sub, s_t, (double)s_pe}); psd.push_back(hasPsd ? s_psd : (Float_t)-1); }
   if (tX) {
      Int_t x_sub; Double_t x_t; Float_t x_pe;
      tX->SetBranchAddress("sub_id", &x_sub); tX->SetBranchAddress("t_us", &x_t); tX->SetBranchAddress("pe", &x_pe);
      for (Long64_t i = 0; i < tX->GetEntries(); ++i) { tX->GetEntry(i); sats.push_back({x_sub, x_t, x_pe}); }
   }
   Int_t m_sub; Double_t m_t; Float_t m_pe; Char_t m_sat;
   tM->SetBranchAddress("sub_id", &m_sub); tM->SetBranchAddress("t_us", &m_t);
   tM->SetBranchAddress("pe", &m_pe);      tM->SetBranchAddress("sat", &m_sat);
   for (Long64_t i = 0; i < tM->GetEntries(); ++i) { tM->GetEntry(i); mu.push_back({m_sub, m_t, m_pe, m_sat}); }
   Int_t i_nsub, i_schema = 1, i_mm = 0; Double_t i_live, i_veto = 150;
   tI->SetBranchAddress("n_subrun", &i_nsub); tI->SetBranchAddress("live_s", &i_live);
   if (tI->GetBranch("schema")) tI->SetBranchAddress("schema", &i_schema);
   if (tI->GetBranch("veto_us")) tI->SetBranchAddress("veto_us", &i_veto);
   if (tI->GetBranch("muon_mode")) tI->SetBranchAddress("muon_mode", &i_mm);
   tI->GetEntry(0); nSubrun = i_nsub; liveS = i_live; schema = i_schema;
   if (vetoUs) *vetoUs = i_veto; if (muonMode) *muonMode = i_mm;
   f->Close(); return true;
}

inline std::vector<double> DailyShowerTimes(const std::vector<ReneMuon> &mu, double muShowerNpe) {
   std::vector<double> s;
   for (const auto &m : mu) if (m.pe > muShowerNpe) s.push_back(m.t_us);
   std::sort(s.begin(), s.end());
   return s;
}

//  prompt 시각 t 의 직전(reverse=false)/직후(reverse=true) 샤워링 뮤온까지 |dt| [s]. 없으면 -1
inline double DailyDtShower(double t, const std::vector<double> &showers, bool reverse) {
   if (!reverse) {
      auto it = std::lower_bound(showers.begin(), showers.end(), t);
      if (it == showers.begin()) return -1;
      return (t - *(it - 1)) * 1e-6;
   }
   auto it = std::upper_bound(showers.begin(), showers.end(), t);
   if (it == showers.end()) return -1;
   return (*it - t) * 1e-6;
}

//  BuildMetrics.C::FitLiHe 의 사본 (Daya Bay Eq.2)
inline bool DailyFitLiHe(TH1D *h, const TString &fname, double lo, double hi, double rMu, double liFrac, double &n, double &e) {
   TF1 f(fname, "[3]*([0]*([4]*[5]*exp(-[5]*x)+(1-[4])*[6]*exp(-[6]*x)) + [1]*[2]*exp(-[2]*x))", lo, hi);
   double tot = h->Integral(1, h->GetNbinsX());
   f.SetParameters(0.1 * tot, tot, rMu, h->GetBinWidth(1), liFrac, 1.0 / kDailyTauLiS, 1.0 / kDailyTauHeS);
   f.FixParameter(2, rMu); f.FixParameter(3, h->GetBinWidth(1)); f.FixParameter(4, liFrac);
   f.FixParameter(5, 1.0 / kDailyTauLiS); f.FixParameter(6, 1.0 / kDailyTauHeS);
   f.SetParLimits(0, 0, 1e9); f.SetParLimits(1, 0, 1e9);
   int rc = h->Fit(&f, "QRLN0");
   if (rc != 0) return false;
   n = f.GetParameter(0); e = f.GetParError(0);
   return true;
}

#endif
