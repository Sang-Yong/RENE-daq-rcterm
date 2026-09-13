// ---------------------------------------------------------------------------
//  BuildRateTrend.C - 시간에 따른 IBD candidate 추이와 효율 보정 rate 를
//                     그림으로 만든다. 3단계(마지막)다.
//
//     1) run-summary.sh   livetime, 종류별 이벤트 수
//     2) ibd-summary.sh   IBD 후보 수 (채널별)
//     3) rate-trend.sh    효율 보정 + 추이 그림   <- 이 파일
//
//  읽는 것 : <OutDir>/pair_summary.tsv   후보 수·컷 창·R_LL
//            <OutDir>/run_summary.tsv    livetime·DAQ 시작 시각(x축)
//  쓰는 것 : <OutDir>/rate_trend.tsv     한 줄 = 런 × 채널
//            <OutDir>/rate_trend.pdf     여러 쪽
//            <OutDir>/NN_rate_<이름>_<채널>.png · NN_evt_<종류>.png  쪽마다 하나, 번호순 (01~17)
//
//  x축은 언제나 '그 런의 DAQ 시작 시각'이다. 런이 하나 끝날 때마다 오른쪽
//  끝에 점이 하나 붙는다. 지우고 다시 그리는 게 아니라 표가 누적되므로,
//  주기적으로 돌리기만 하면 추이가 계속 자란다.
//
//  ---- 효율 ----
//  분석 쪽 diagnostics 의 정의를 그대로 쓴다. 새로 만들지 않았다.
//
//    eps_T   = exp(-DT_MIN/tau) - exp(-DT_MAX/tau)        EffCutFlow.C:86
//              포획시간 tau : n-Gd 25 us, n-H 171 us       EffCutFlow.C:85
//    eps_iso = exp(-R_LL * (ISO_PRE + ISO_POST))          IsolationEfficiency.C:62
//              R_LL = 1.2 MeV 이상 clean single 의 rate
//    eps_E   = 자동으로 구할 수 없다. 기본 1.0 이고 보정에서 빠져 있다.
//              (봉우리 fit 이 필요해 사람이 봐야 한다 -- EffCutFlow.C 주석 참조)
//
//    rate_corr = rate_raw / (eps_T * eps_iso * eps_E)
//
//  ---- R_LL 은 2단계가 준다. 여기서 재지 않는다 ----
//  R_LL 은 1.2 MeV 이상 clean single 의 rate 다. **에너지 문턱이 있다는 것이
//  핵심**이다 -- Step2 의 T_Event 에는 문턱이 없어서(muon/afterMu/saturation
//  컷만) 1.2 MeV 미만이 절반쯤 섞여 있다. 실측 : run 4237 서브런 100 에서
//  clean 11,356 개 중 1.2 MeV 이상은 5,739 개뿐이다. n_clean/live 를 그대로
//  쓰면 R_LL 이 두 배가 되고 eps_iso 가 낮아져 보정 rate 가 부풀려진다.
//
//  예전에는 여기서 Step2 part 를 서브런 몇 개 표본으로 열어 쟀다. 이제
//  2단계(BuildPairSummary.C)가 PRD 에서 런 전체의 single 을 이미 세므로
//  pair_summary.tsv 의 r_ll 열을 그대로 쓴다 -- **표본이 아니라 전수**이고,
//  /scratch/junkyo 에 기대지 않는다. 옛 rll.tsv 가 있으면 r_ll 이 비어 있는
//  런에 한해 예비로 쓴다.
//
//  사용 :
//     root -l -b -q 'BuildRateTrend.C+()'            전부 다시 그린다
// ---------------------------------------------------------------------------
#ifndef RENE_COND_HEADER
#define RENE_COND_HEADER "/home/ojk/analysis3/essential/AnalysisCondition.h"
#endif

#include <TAxis.h>
#include <TCanvas.h>
#include <TFile.h>
#include <TGraphErrors.h>
#include <TLegend.h>
#include <TMultiGraph.h>
#include <TStyle.h>
#include <TSystem.h>
#include <TString.h>
#include <TTree.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include RENE_COND_HEADER
#include "ReneTrendPlot.h"      // 채널별 쪽 · 선형축 + 로그 inset · 번호 붙은 파일 이름 (2026-09-14)

// ---------------------------------------------------------------------------
struct TrendRow {
   int         run = 0;
   std::string tag, src;
   double epoch   = -1;      // x축. DAQ 시작 시각 [Unix s]
   double liveSec = -1;
   long long nIbd = -1, nIbdAcci = -1;
   double dtMin = -1, dtMax = -1, isoPre = -1, isoPost = -1;
   double rll   = -1;        // [Hz]  1.2 MeV 이상 clean single
   int    rllN  = 0;         // R_LL 을 잰 서브런 수

   double acciScale() const { return dtMax > 0 ? (dtMax - dtMin) / dtMax : -1; }
   double nAcci()  const { return nIbdAcci >= 0 ? acciScale() * nIbdAcci : -1; }
   double nCand()  const { return nIbd >= 0 ? nIbd - nAcci() : 0; }
   double nCandErr() const {
      double s = acciScale();
      return (nIbd >= 0 && nIbdAcci >= 0) ? std::sqrt((double)nIbd + s * s * nIbdAcci) : 0;
   }
   double liveDay() const { return liveSec > 0 ? liveSec / 86400.0 : -1; }

   double tau() const { return tag == "_nH" ? 171.0 : 25.0; }
   double epsT() const {
      return (dtMax > 0) ? std::exp(-dtMin / tau()) - std::exp(-dtMax / tau()) : -1;
   }
   double epsIso() const {
      if (rll < 0 || isoPre < 0) return -1;
      return std::exp(-rll * (isoPre + isoPost) * 1e-6);
   }
   double epsTot(double epsE) const {
      double a = epsT(), b = epsIso();
      return (a > 0 && b > 0) ? a * b * epsE : -1;
   }
   double rateRaw() const {   // [/day]
      double d = liveDay();
      return d > 0 ? nCand() / d : -1e30;
   }
   double rateRawErr() const {
      double d = liveDay();
      return d > 0 ? nCandErr() / d : 0;
   }
   double rateCorr(double epsE) const {
      double e = epsTot(epsE);
      return (e > 0 && liveDay() > 0) ? rateRaw() / e : -1e30;
   }
   double rateCorrErr(double epsE) const {
      double e = epsTot(epsE);
      return (e > 0 && liveDay() > 0) ? rateRawErr() / e : 0;
   }
   double acciPerDay() const {
      double d = liveDay();
      return (d > 0 && nAcci() >= 0) ? nAcci() / d : -1e30;
   }
};

// ---------------------------------------------------------------------------
static TString RunStr(int run) { return TString::Format("%06d", run); }

// ---------------------------------------------------------------------------
static std::map<int, std::pair<double, int>> LoadRllCache(const TString &p) {
   std::map<int, std::pair<double, int>> out;
   std::ifstream in(p.Data());
   if (!in) return out;
   std::string line;
   while (std::getline(in, line)) {
      if (line.empty() || line[0] == '#') continue;
      std::stringstream ss(line);
      int run, n; double r;
      if (ss >> run >> r >> n) out[run] = {r, n};
   }
   return out;
}

// ---------------------------------------------------------------------------
//  그림은 ReneTrendPlot.h 의 DrawTrendPage 가 그린다. 여기서는 계열만 만든다.
using Series = TrendSeries;
static const char *ChanName(const char *tag) { return std::string(tag) == "_nH" ? "n-H" : "n-Gd"; }
static int         ChanColor(const char *tag) { return std::string(tag) == "_nH" ? kBlue + 1 : kRed + 1; }
static int         ChanMarker(const char *tag) { return std::string(tag) == "_nH" ? 21 : 20; }

// ---------------------------------------------------------------------------
void BuildRateTrend(const char *outDir = "/scratch/RunSummary/", double epsE = 1.0) {
   gStyle->SetOptStat(0);
   gStyle->SetFrameLineWidth(2);
   gStyle->SetGridColor(kGray + 1);
   gStyle->SetGridStyle(3);

   TString out(outDir);
   if (!out.EndsWith("/")) out += "/";

   // ---- pair_summary ----
   std::vector<TrendRow> rows;
   {
      std::ifstream in((out + "pair_summary.tsv").Data());
      if (!in) { printf("[FATAL] pair_summary.tsv 가 없다. ibd-summary.sh 를 먼저 돌릴 것\n"); return; }
      std::string line;
      while (std::getline(in, line)) {
         if (line.empty() || line[0] == '#') continue;
         std::stringstream ss(line);
         TrendRow r;
         long long nP, nPA, nSingle;
         double dtAcci, s2lo, s2hi;
         int nSub;
         //  pair_summary.tsv 열 순서 (schema 2). BuildPairSummary.C 의 WriteTsv
         //  와 짝이다 -- 한쪽만 고치면 엉뚱한 열을 R_LL 로 읽는다.
         if (!(ss >> r.run >> r.tag >> r.src >> r.liveSec >> nP >> nPA
                  >> r.nIbd >> r.nIbdAcci >> r.dtMin >> r.dtMax >> dtAcci
                  >> s2lo >> s2hi >> r.isoPre >> r.isoPost
                  >> nSingle >> r.rll >> nSub)) continue;
         if (r.rll > 0) r.rllN = nSub;
         rows.push_back(r);
      }
   }
   if (rows.empty()) { printf("[FATAL] pair_summary 에 읽을 행이 없다\n"); return; }

   // ---- run_summary 에서 x축(시각)과 livetime ----
   std::map<int, double> epoch, live;
   //  run -> {total, target(FADC only), veto(SADC only), coinc(both)} [Hz]
   std::map<int, std::array<double, 4>> typeRate;
   {
      std::ifstream in((out + "run_summary.tsv").Data());
      std::string line;
      while (std::getline(in, line)) {
         if (line.empty() || line[0] == '#') continue;
         std::stringstream ss(line);
         //  run_summary.tsv 열 순서 (schema 2). BuildRunSummary.C 의 WriteTsv
         //  와 짝이다 -- 한쪽만 고치면 live 자리에 span 이 들어온다.
         //  추가로 dead 와 타입별 수까지 읽는다 (schema 2 의 9~12열).
         int run, nsub, nbad; double es, ee, wall, span, lv;
         double dead; long long t1, t2, t3;
         if (!(ss >> run >> nsub >> nbad >> es >> ee >> wall >> span >> lv
                  >> dead >> t1 >> t2 >> t3)) continue;
         if (es > 0) epoch[run] = es;
         if (lv > 0) live[run]  = lv;
         if (lv > 0) typeRate[run] = {(double)(t1 + t2 + t3) / lv, (double)t1 / lv,
                                      (double)t2 / lv, (double)t3 / lv};
      }
   }
   for (auto &r : rows) {
      auto ie = epoch.find(r.run); if (ie != epoch.end()) r.epoch = ie->second;
      if (r.liveSec <= 0) { auto il = live.find(r.run); if (il != live.end()) r.liveSec = il->second; }
   }

   // ---- R_LL : 2단계가 pair_summary 에 넣어 준 전수 값 ----
   //  옛 rll.tsv (표본으로 잰 값) 는 r_ll 이 없는 행에만 예비로 쓴다.
   auto legacy = LoadRllCache(out + "rll.tsv");
   int nFromPair = 0, nFromLegacy = 0, nNoRll = 0;
   for (auto &r : rows) {
      if (r.rll > 0) { nFromPair++; continue; }
      auto it = legacy.find(r.run);
      if (it != legacy.end() && it->second.first > 0) {
         r.rll = it->second.first; r.rllN = it->second.second; nFromLegacy++;
      } else if (r.src == "none") {
         nNoRll++;
      }
   }
   printf("[INFO] R_LL : pair_summary %d 행, 옛 rll.tsv %d 행, 없음 %d 행\n",
          nFromPair, nFromLegacy, nNoRll);
   if (nNoRll > 0)
      printf("[WARN] R_LL 이 없는 행이 있다. eps_iso 를 비운다 -- "
             "ibd-summary.sh 를 다시 돌리면 채워진다\n");

   // ---- 추이에 쓸 행만 남긴다 ----
   std::vector<TrendRow> use;
   int nDropSrc = 0, nDropTime = 0;
   for (const auto &r : rows) {
      if (r.src != "none") { nDropSrc++; continue; }
      if (r.epoch <= 0 || r.liveSec <= 0) { nDropTime++; continue; }
      use.push_back(r);
   }
   std::sort(use.begin(), use.end(),
             [](const TrendRow &a, const TrendRow &b) { return a.epoch < b.epoch; });
   printf("[INFO] 추이에 쓰는 점 %zu 개 (선원 런 %d 제외, 시각/livetime 없음 %d 제외)\n",
          use.size(), nDropSrc, nDropTime);
   if (use.empty()) { printf("[FATAL] 그릴 점이 없다\n"); return; }

   // ---- tsv ----
   {
      std::ofstream o((out + "rate_trend.tsv").Data());
      o << "# RENE IBD rate trend. BuildRateTrend.C 가 만든다.\n"
           "# eps_E 는 자동으로 못 구해 " << epsE << " 로 고정했다 (보정에서 빠져 있음).\n"
           "# rate 단위는 [/day]. cand 는 우발을 뺀 값.\n"
           "#run\ttag\tepoch\tlive_s\tcand\tcand_err\tR_LL\teps_T\teps_iso\teps_tot"
           "\trate_raw\trate_raw_err\trate_corr\trate_corr_err\tacci_per_day\n";
      for (const auto &r : use)
         o << r.run << '\t' << r.tag << '\t' << (long long)r.epoch << '\t'
           << r.liveSec << '\t' << r.nCand() << '\t' << r.nCandErr() << '\t'
           << r.rll << '\t' << r.epsT() << '\t' << r.epsIso() << '\t' << r.epsTot(epsE) << '\t'
           << r.rateRaw() << '\t' << r.rateRawErr() << '\t'
           << r.rateCorr(epsE) << '\t' << r.rateCorrErr(epsE) << '\t'
           << r.acciPerDay() << '\n';
   }

   // ---- 채널별 계열 만들기 ----
   auto series = [&](const char *tag, int color, int marker,
                     double (*pick)(const TrendRow &, double),
                     double (*perr)(const TrendRow &, double)) {
      Series s; s.label = tag; s.color = color; s.marker = marker;
      for (const auto &r : use) {
         if (r.tag != tag) continue;
         double v = pick(r, epsE);
         if (v <= -1e29) continue;
         s.x.push_back(r.epoch); s.y.push_back(v);
         s.ey.push_back(perr ? perr(r, epsE) : 0.0);
      }
      return s;
   };
   auto fCand    = [](const TrendRow &r, double) { return r.nCand(); };
   auto fCandE   = [](const TrendRow &r, double) { return r.nCandErr(); };
   auto fRaw     = [](const TrendRow &r, double) { return r.rateRaw(); };
   auto fRawE    = [](const TrendRow &r, double) { return r.rateRawErr(); };
   auto fCorr    = [](const TrendRow &r, double e) { return r.rateCorr(e); };
   auto fCorrE   = [](const TrendRow &r, double e) { return r.rateCorrErr(e); };
   auto fAcci    = [](const TrendRow &r, double) { return r.acciPerDay(); };
   auto fZero    = [](const TrendRow &, double) { return 0.0; };
   auto fEpsIso  = [](const TrendRow &r, double) { return r.epsIso(); };
   auto fEpsTot  = [](const TrendRow &r, double e) { return r.epsTot(e); };
   auto fRll     = [](const TrendRow &r, double) { return r.rll; };

   TString pdf = out + "rate_trend.pdf";
   int page = 0; bool opened = false;
   //  쪽 하나. 첫 쪽이 PDF 를 열고("("), 마지막은 아래에서 "]" 로 닫는다.
   auto draw = [&](const char *file, const char *title, const char *yt, std::vector<Series> ss, bool logInset) {
      TrendPageOpt o; o.logInset = logInset;
      if (DrawTrendPage(pdf, out, file, title, yt, ss, opened ? "" : "(", o)) { opened = true; page++; }
   };
   const char *tags[2] = {"_nGd", "_nH"};
   const char *fileTag[2] = {"nGd", "nH"};

   //  ★ 채널은 쪽을 나눈다 (사용자 지시 2026-09-14). 두 채널의 크기가 100배쯤 달라 한 캔버스에 두면 한쪽이 바닥에 깔린다.
   //    축은 선형이고, 값이 열 배 넘게 벌어지는 쪽에는 로그축 inset 이 붙는다 (빈 구석에).
   for (int k = 0; k < 2; ++k) {                       // 01~02 후보 수
      std::vector<Series> s{series(tags[k], ChanColor(tags[k]), ChanMarker(tags[k]), fCand, fCandE)};
      s[0].label = ChanName(tags[k]);
      draw(Form("%02d_rate_candidates_%s", 1 + k, fileTag[k]),
           Form("IBD candidates per run, %s (accidental subtracted)", ChanName(tags[k])), "Candidates", s, true);
   }
   for (int k = 0; k < 2; ++k) {                       // 03~04 보정 전 rate
      std::vector<Series> s{series(tags[k], ChanColor(tags[k]), ChanMarker(tags[k]), fRaw, fRawE)};
      s[0].label = ChanName(tags[k]);
      draw(Form("%02d_rate_raw_%s", 3 + k, fileTag[k]),
           Form("Candidate rate, %s (no efficiency correction)", ChanName(tags[k])), "Rate [/day]", s, true);
   }
   for (int k = 0; k < 2; ++k) {                       // 05~06 효율 보정 rate  ★핵심
      std::vector<Series> s{series(tags[k], ChanColor(tags[k]), ChanMarker(tags[k]), fCorr, fCorrE)};
      s[0].label = ChanName(tags[k]);
      draw(Form("%02d_rate_corrected_%s", 5 + k, fileTag[k]),
           Form("Candidate rate corrected for #varepsilon_{T} #times #varepsilon_{iso}, %s", ChanName(tags[k])),
           "Rate [/day]", s, true);
   }
   for (int k = 0; k < 2; ++k) {                       // 07~08 효율 (iso · tot)
      std::vector<Series> s{series(tags[k], ChanColor(tags[k]), 20, fEpsIso, fZero),
                            series(tags[k], ChanColor(tags[k]), 24, fEpsTot, fZero)};
      s[0].label = "#varepsilon_{iso}"; s[1].label = "#varepsilon_{tot}";
      draw(Form("%02d_rate_efficiency_%s", 7 + k, fileTag[k]),
           Form("Efficiencies used for the correction, %s", ChanName(tags[k])), "Efficiency", s, false);
   }
   for (int k = 0; k < 2; ++k) {                       // 09~10 우발
      std::vector<Series> s{series(tags[k], ChanColor(tags[k]), ChanMarker(tags[k]), fAcci, fZero)};
      s[0].label = ChanName(tags[k]);
      draw(Form("%02d_rate_accidental_%s", 9 + k, fileTag[k]),
           Form("Accidental (window-scaled) per day, %s", ChanName(tags[k])), "Accidental [/day]", s, true);
   }
   {                                                   // 11 R_LL -- eps_iso 가 흔들리면 여기가 원인이다
      std::vector<Series> s{series("_nGd", kBlack, 20, fRll, fZero)};
      s[0].label = "R_{LL} (>1.2 MeV singles)";
      draw("11_rate_rll", "Singles rate above 1.2 MeV (drives #varepsilon_{iso})", "R_{LL} [Hz]", s, false);
   }
   for (int k = 0; k < 2; ++k) {                       // 12~13 누적 후보 수
      Series q; q.label = ChanName(tags[k]); q.color = ChanColor(tags[k]); q.marker = ChanMarker(tags[k]);
      double acc = 0;
      for (const auto &r : use) {
         if (r.tag != tags[k]) continue;
         acc += r.nCand();
         q.add(r.epoch, acc, 0);
      }
      std::vector<Series> s{q};
      draw(Form("%02d_rate_cumulative_%s", 12 + k, fileTag[k]),
           Form("Cumulative IBD candidates, %s", ChanName(tags[k])), "#Sigma candidates", s, false);
   }
   {                                                   // 14~17 DAQ 이벤트 rate (런당 점 하나. 표의 타입별 수와 같은 자료)
      const char *nm[4] = {"14_evt_total", "15_evt_target", "16_evt_veto", "17_evt_coinc"};
      const char *tt[4] = {"Total trigger rate", "Target only (FADC) rate",
                           "VETO only (SADC) rate", "VETO+Target coincidence rate"};
      const int   cl[4] = {kBlack, kRed + 1, kBlue + 1, kGreen + 2};
      for (int k = 0; k < 4; ++k) {
         Series s; s.label = tt[k]; s.color = cl[k]; s.marker = 20;
         for (auto &kv : typeRate) {
            auto ie = epoch.find(kv.first);
            if (ie == epoch.end()) continue;
            s.x.push_back(ie->second); s.y.push_back(kv.second[k]); s.ey.push_back(0);
         }
         std::vector<Series> v{s};
         draw(nm[k], tt[k], "Rate [Hz]", v, false);
      }
   }
   {  // ★ PDF 마감 -- 첫 쪽이 열어 둔 파일을 여기서 무조건 닫는다. "]" 는 그리지 않고 스트림만 닫는 모드다.
      //  (쪽이 하나도 안 찍혔으면 열린 적이 없으니 닫지 않는다)
      if (opened) { TCanvas *cClose = new TCanvas("cTrendClose", "close rate_trend.pdf", 1400, 700); cClose->Print(pdf + "]"); delete cClose; }
   }

   printf("[SAVED] %s  (%d 쪽)\n", pdf.Data(), page);
   printf("[SAVED] %s01..17_*.png  (채널별 쪽, 선형축 + 로그 inset)\n", out.Data());
   printf("[SAVED] %srate_trend.tsv\n", out.Data());
   printf("[NOTE ] eps_E 는 %.3f 로 고정했다. 봉우리 fit 이 필요해 자동으로 못 구한다.\n", epsE);
}
