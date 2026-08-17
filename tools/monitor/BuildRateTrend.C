// ---------------------------------------------------------------------------
//  BuildRateTrend.C - 시간에 따른 IBD candidate 추이와 효율 보정 rate 를
//                     그림으로 만든다. 3단계(마지막)다.
//
//     1) run-summary.sh   livetime, 종류별 이벤트 수
//     2) ibd-summary.sh   IBD 후보 수 (채널별)
//     3) rate-trend.sh    효율 보정 + 추이 그림   <- 이 파일
//
//  읽는 것 : <OutDir>/pair_summary.tsv   후보 수·컷 창
//            <OutDir>/run_summary.tsv    livetime·DAQ 시작 시각(x축)
//            <SampleDir>/Step2/parts/... R_LL 측정용 (서브런 표본만)
//  쓰는 것 : <OutDir>/rate_trend.tsv     한 줄 = 런 × 채널
//            <OutDir>/rll.tsv            R_LL 측정값 캐시 (다시 재지 않는다)
//            <OutDir>/rate_trend.pdf     여러 쪽
//            <OutDir>/rate_trend_<이름>.png  쪽마다 하나 (화면에 띄우기 좋다)
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
//  ---- R_LL 은 추정하지 않고 잰다 ----
//  run_summary 의 n_clean 을 livetime 으로 나누고 싶어지지만 **틀린다.**
//  Step2 의 T_Event 에는 에너지 문턱이 없어서(muon/afterMu/saturation 컷만)
//  1.2 MeV 미만이 절반쯤 섞여 있다. 실측 : run 4237 서브런 100 에서
//  T_Event 11,356 개 중 1.2 MeV 이상은 5,740 개뿐이었다. 그대로 쓰면 R_LL 이
//  두 배가 되고 eps_iso 가 낮아져 보정 rate 가 부풀려진다.
//  그래서 Step2 part 를 몇 개 표본으로 열어 직접 센다. rate 라서 전수 조사가
//  필요 없다. 결과는 rll.tsv 에 캐시하므로 런당 한 번만 잰다.
//
//  사용 :
//     root -l -b -q 'BuildRateTrend.C+()'            전부 다시 그린다
//     root -l -b -q 'BuildRateTrend.C+(true)'        R_LL 캐시를 무시하고 재측정
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
#include <cmath>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include RENE_COND_HEADER

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

//  R_LL 을 서브런 표본으로 잰다. 전수 조사가 아니라 표본인 이유는 rate 이기
//  때문이다. 표본 수는 nWant 개를 런 전체에 고르게 흩는다.
static bool MeasureRLL(int run, const TString &sampleDir, double vetoCutUs,
                       int nWant, double &rllOut, int &nUsed) {
   //  서브런 번호와 그 livetime 은 monitor 요약에 있다.
   TString mon = TString::Format("%sMonitor/monitor_Run%s.root",
                                 sampleDir.Data(), RunStr(run).Data());
   if (gSystem->AccessPathName(mon)) return false;
   TFile *fM = TFile::Open(mon, "READ");
   if (!fM || fM->IsZombie()) { if (fM) fM->Close(); return false; }
   TTree *tM = (TTree *)fM->Get("T_Monitor");
   if (!tM) { fM->Close(); return false; }
   Int_t sid; Double_t dur;
   tM->SetBranchAddress("subrun_id", &sid);
   tM->SetBranchAddress("duration_sec", &dur);
   std::vector<std::pair<int, double>> subs;
   for (Long64_t i = 0; i < tM->GetEntries(); ++i) {
      tM->GetEntry(i);
      if (dur > 0) subs.push_back({sid, dur});
   }
   fM->Close();
   if (subs.empty()) return false;

   TString vtag = (vetoCutUs == 150.0) ? "_veto150"
                                       : TString::Format("_veto%.0f", vetoCutUs);
   //  q0+q1 >= LOWER_LIMIT [pe]. (q0<5 && q1<5) 는 Step2Reader 가 버리는 잡음이다.
   TString cut = TString::Format("!(q0<5.0&&q1<5.0)&&(q0+q1)>=%.4f", LOWER_LIMIT);

   int stride = (int)subs.size() / std::max(1, nWant);
   if (stride < 1) stride = 1;
   long long nSel = 0;
   double liveSel = 0;
   nUsed = 0;
   for (size_t i = 0; i < subs.size(); i += stride) {
      TString p = TString::Format("%sStep2/parts/step2_Run%s_sub%05d%s.root",
                                  sampleDir.Data(), RunStr(run).Data(),
                                  subs[i].first, vtag.Data());
      if (gSystem->AccessPathName(p)) continue;
      TFile *f = TFile::Open(p, "READ");
      if (!f || f->IsZombie()) { if (f) f->Close(); continue; }
      TTree *t = (TTree *)f->Get("T_Event");
      if (t && t->GetBranch("q0")) {
         nSel += t->GetEntries(cut);
         liveSel += subs[i].second;
         nUsed++;
      }
      f->Close();
   }
   if (nUsed == 0 || liveSel <= 0) return false;
   rllOut = (double)nSel / liveSel;
   return true;
}

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
static void SaveRllCache(const TString &p, const std::map<int, std::pair<double, int>> &c) {
   std::ofstream o(p.Data());
   o << "# run\tR_LL[Hz]\tn_subrun_sampled   -- BuildRateTrend.C 가 잰 값\n";
   for (const auto &kv : c) o << kv.first << '\t' << kv.second.first << '\t' << kv.second.second << '\n';
}

// ---------------------------------------------------------------------------
//  그림 한 장. x 는 언제나 시각이라 축 설정을 한 곳에 모은다.
static void StyleTimeAxis(TMultiGraph *mg) {
   TAxis *ax = mg->GetXaxis();
   ax->SetTimeDisplay(1);
   ax->SetTimeOffset(0, "gmt");
   ax->SetTimeFormat("%y/%m/%d");
   ax->SetNdivisions(507);
   ax->SetTitleSize(0.045); ax->SetLabelSize(0.038);
   ax->SetTitleOffset(1.5); ax->CenterTitle();
   mg->GetYaxis()->SetTitleSize(0.045);
   mg->GetYaxis()->SetLabelSize(0.040);
   mg->GetYaxis()->SetTitleOffset(1.15);
   mg->GetYaxis()->CenterTitle();
}

struct Series {
   std::vector<double> x, y, ey;
   std::string label;
   int color = kBlack, marker = 20;
};

static void DrawPage(const TString &pdf, const TString &pngBase, const char *pngName,
                     const char *title, const char *ytitle,
                     std::vector<Series> &ss, const char *pdfMode,
                     bool logy = false, int &pageNo = *(new int(0))) {
   TCanvas *c = new TCanvas(Form("cTrend_%s", pngName), title, 1400, 700);
   c->SetLeftMargin(0.11); c->SetBottomMargin(0.15); c->SetRightMargin(0.04);
   c->SetGridx(); c->SetGridy();
   if (logy) c->SetLogy();

   TMultiGraph *mg = new TMultiGraph();
   TLegend *leg = new TLegend(0.72, 0.74, 0.95, 0.90);
   leg->SetBorderSize(0); leg->SetFillStyle(0); leg->SetTextSize(0.035);

   bool any = false;
   for (auto &s : ss) {
      if (s.x.empty()) continue;
      TGraphErrors *g = new TGraphErrors((int)s.x.size(), s.x.data(), s.y.data(),
                                         nullptr, s.ey.empty() ? nullptr : s.ey.data());
      g->SetMarkerStyle(s.marker); g->SetMarkerSize(1.1);
      g->SetMarkerColor(s.color);  g->SetLineColor(s.color); g->SetLineWidth(2);
      mg->Add(g, "LP");
      leg->AddEntry(g, s.label.c_str(), "lp");
      any = true;
   }
   if (!any) { delete c; return; }

   mg->SetTitle(Form("%s;DAQ start [YY/MM/DD];%s", title, ytitle));
   mg->Draw("A");
   StyleTimeAxis(mg);
   if (ss.size() > 1) leg->Draw();
   c->Print(pdf + pdfMode);
   c->Print(pngBase + pngName + ".png");
   pageNo++;
}

// ---------------------------------------------------------------------------
void BuildRateTrend(bool remeasure = false,
                    const char *outDir    = "/scratch/RunSummary/",
                    const char *sampleDir = "/scratch/junkyo/SampleFiles/",
                    double epsE = 1.0, int nSample = 20, double vetoCutUs = 150.0) {
   gStyle->SetOptStat(0);
   gStyle->SetFrameLineWidth(2);
   gStyle->SetGridColor(kGray + 1);
   gStyle->SetGridStyle(3);

   TString out(outDir), sample(sampleDir);
   if (!out.EndsWith("/"))    out    += "/";
   if (!sample.EndsWith("/")) sample += "/";

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
         long long nP, nPA;
         double dtAcci, s2lo, s2hi;
         if (!(ss >> r.run >> r.tag >> r.src >> r.liveSec >> nP >> nPA
                  >> r.nIbd >> r.nIbdAcci >> r.dtMin >> r.dtMax >> dtAcci
                  >> s2lo >> s2hi >> r.isoPre >> r.isoPost)) continue;
         rows.push_back(r);
      }
   }
   if (rows.empty()) { printf("[FATAL] pair_summary 에 읽을 행이 없다\n"); return; }

   // ---- run_summary 에서 x축(시각)과 livetime ----
   std::map<int, double> epoch, live;
   {
      std::ifstream in((out + "run_summary.tsv").Data());
      std::string line;
      while (std::getline(in, line)) {
         if (line.empty() || line[0] == '#') continue;
         std::stringstream ss(line);
         //  run_summary.tsv 열 순서 (schema 2). BuildRunSummary.C 의 WriteTsv
         //  와 짝이다 -- 한쪽만 고치면 live 자리에 span 이 들어온다.
         int run, nsub, nbad; double es, ee, wall, span, lv;
         if (!(ss >> run >> nsub >> nbad >> es >> ee >> wall >> span >> lv)) continue;
         if (es > 0) epoch[run] = es;
         if (lv > 0) live[run]  = lv;
      }
   }
   for (auto &r : rows) {
      auto ie = epoch.find(r.run); if (ie != epoch.end()) r.epoch = ie->second;
      if (r.liveSec <= 0) { auto il = live.find(r.run); if (il != live.end()) r.liveSec = il->second; }
   }

   // ---- R_LL (캐시) ----
   TString rllPath = out + "rll.tsv";
   auto cache = LoadRllCache(rllPath);
   //  한 런에 채널이 둘이라 그냥 두면 같은 런을 두 번 재려 든다. R_LL 은
   //  채널과 무관하므로 런 단위로 한 번만 시도한다.
   std::map<int, bool> tried;
   int nMeasured = 0;
   for (auto &r : rows) {
      if (r.src != "none") continue;           // 선원 런은 추이에 넣지 않는다
      auto it = cache.find(r.run);
      if (!remeasure && it != cache.end()) { r.rll = it->second.first; r.rllN = it->second.second; continue; }
      if (tried.count(r.run)) continue;
      tried[r.run] = true;
      double v; int n;
      if (MeasureRLL(r.run, sample, vetoCutUs, nSample, v, n)) {
         cache[r.run] = {v, n};
         r.rll = v; r.rllN = n; nMeasured++;
         printf("  [R_LL] run %d : %.2f Hz  (서브런 %d 개 표본)\n", r.run, v, n);
      } else {
         printf("  [WARN] run %d : R_LL 을 재지 못했다 (Step2 part 없음). "
                "eps_iso 를 비운다\n", r.run);
      }
   }
   //  같은 런의 다른 채널에도 채워 준다 (R_LL 은 채널과 무관하다)
   for (auto &r : rows) {
      if (r.rll >= 0) continue;
      auto it = cache.find(r.run);
      if (it != cache.end()) { r.rll = it->second.first; r.rllN = it->second.second; }
   }
   if (nMeasured > 0) SaveRllCache(rllPath, cache);
   printf("[INFO] R_LL : 새로 잰 런 %d, 캐시 %zu (%s)\n",
          nMeasured, cache.size(), rllPath.Data());

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
   TString png = out + "rate_trend_";
   int page = 0;

   {  // 1) 후보 수 (이벤트 수)
      std::vector<Series> s{series("_nGd", kRed + 1, 20, fCand, fCandE),
                            series("_nH",  kBlue + 1, 21, fCand, fCandE)};
      //  두 채널의 크기가 100배쯤 달라서 선형축이면 n-Gd 이 바닥에 깔려 안 보인다
      DrawPage(pdf, png, "candidates", "IBD candidates per run (accidental subtracted)",
               "Candidates", s, "(", true, page);
   }
   {  // 2) 보정 전 rate
      std::vector<Series> s{series("_nGd", kRed + 1, 20, fRaw, fRawE),
                            series("_nH",  kBlue + 1, 21, fRaw, fRawE)};
      DrawPage(pdf, png, "rate_raw", "Candidate rate (no efficiency correction)",
               "Rate [/day]", s, "", true, page);
   }
   {  // 3) 효율 보정 rate  ★핵심
      std::vector<Series> s{series("_nGd", kRed + 1, 20, fCorr, fCorrE),
                            series("_nH",  kBlue + 1, 21, fCorr, fCorrE)};
      DrawPage(pdf, png, "rate_corrected",
               "Candidate rate corrected for #varepsilon_{T} #times #varepsilon_{iso}",
               "Rate [/day]", s, "", true, page);
   }
   {  // 4) 효율
      std::vector<Series> s{series("_nGd", kRed + 1, 20, fEpsIso, fZero),
                            series("_nH",  kBlue + 1, 21, fEpsIso, fZero),
                            series("_nGd", kRed + 1, 24, fEpsTot, fZero),
                            series("_nH",  kBlue + 1, 25, fEpsTot, fZero)};
      s[0].label = "#varepsilon_{iso} nGd"; s[1].label = "#varepsilon_{iso} nH";
      s[2].label = "#varepsilon_{tot} nGd"; s[3].label = "#varepsilon_{tot} nH";
      DrawPage(pdf, png, "efficiency", "Efficiencies used for the correction",
               "Efficiency", s, "", false, page);
   }
   {  // 5) 우발
      std::vector<Series> s{series("_nGd", kRed + 1, 20, fAcci, fZero),
                            series("_nH",  kBlue + 1, 21, fAcci, fZero)};
      DrawPage(pdf, png, "accidental", "Accidental (window-scaled) per day",
               "Accidental [/day]", s, "", true, page);
   }
   {  // 6) R_LL -- eps_iso 가 흔들리면 여기가 원인이다
      std::vector<Series> s{series("_nGd", kBlack, 20, fRll, fZero)};
      s[0].label = "R_{LL} (>1.2 MeV singles)";
      DrawPage(pdf, png, "rll", "Singles rate above 1.2 MeV (drives #varepsilon_{iso})",
               "R_{LL} [Hz]", s, "", false, page);
   }
   {  // 7) 누적 후보 수
      std::vector<Series> s;
      for (const char *tg : {"_nGd", "_nH"}) {
         Series q; q.label = tg;
         q.color = (std::string(tg) == "_nH") ? kBlue + 1 : kRed + 1;
         q.marker = (std::string(tg) == "_nH") ? 21 : 20;
         double acc = 0;
         for (const auto &r : use) {
            if (r.tag != tg) continue;
            acc += r.nCand();
            q.x.push_back(r.epoch); q.y.push_back(acc); q.ey.push_back(0);
         }
         s.push_back(q);
      }
      DrawPage(pdf, png, "cumulative", "Cumulative IBD candidates",
               "#Sigma candidates", s, ")", false, page);
   }

   printf("[SAVED] %s  (%d 쪽)\n", pdf.Data(), page);
   printf("[SAVED] %srate_trend_*.png\n", out.Data());
   printf("[SAVED] %srate_trend.tsv\n", out.Data());
   printf("[NOTE ] eps_E 는 %.3f 로 고정했다. 봉우리 fit 이 필요해 자동으로 못 구한다.\n", epsE);
}
