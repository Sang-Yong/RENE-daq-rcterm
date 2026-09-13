//  BuildDaily.C — 날짜 기준 신호 계산 + 스펙트럼 (2026-09-14, 사용자 지시)
//
//   사용자 : "IBD 후보는 런별이 아니라 날짜별이어야 한다. 기존 런별 방식은 그대로 두고, 측정 기준은 전부 날짜로.
//             라이브타임을 먼저 구하고 모든 런의 자료를 시간에 대한 사건 수로 다시 계산. 최종 확인 그림은 누적 개수가
//             아니라 전체 사건의 에너지 스펙트럼 — prompt · delayed 두 캔버스, 각각 배경 빼기 전과 모든 배경을 뺀 뒤를 함께."
//
//   입력   <OutDir>/run_summary.tsv   런 → 시작 시각(epoch) · span · live · 서브런 수
//          <OutDir>/runtype.tsv       선원 런은 뺀다 (metrics 와 같은 규칙)
//          <OutDir>/dst/DST_<run>.root  (dst-build.sh 산출물. 없는 런은 건너뛴다)
//   출력   <OutDir>/daily_summary.tsv    날짜·채널마다 한 줄 : 라이브타임 · 런 수 · IBD · 우발 · 후보 · rate[/day] · fast-n · Li/He
//          <OutDir>/daily_spectra.root   스펙트럼 히스토그램 전부
//          <OutDir>/32..40_*.png         (ReneTrendPlot 규칙 : 채널별 쪽 · 선형축 · 번호 이름)
//
//   ---- 날짜에 어떻게 붙이나 ----
//   * 사건 시각 = 런 시작 epoch + t_us·1e-6  (DST 의 t_us 는 런 안에서 이어지는 시각).  날짜는 이 PC 의 지역시(KST) 자정 기준.
//   * 라이브타임 : 런의 live_s 를 서브런 수로 등분해 서브런 k 의 중간 시각(epoch_start + (k+½)·span/n_subrun)이 속한 날에 더한다.
//     (서브런은 60 s 씩이라 하루 경계에서의 오차는 1 분 이하)
//   * 쌍(prompt·delayed)은 RenePairing.h 와 같은 논리(ReneDailyCore.h::PairListW)로 만들고 prompt 시각의 날짜로 센다.
//   ---- 배경 (run 단위 BuildMetrics 와 같은 정의, 날짜 단위로) ----
//   * 우발 : off-window 쌍 × (dtMax−dtMin)/dtMax                       — 스펙트럼 모양도 off-window 쌍 그대로
//   * fast-n : 사이드밴드(prompt [fn_e_lo, fn_e_hi] MeV, single ∪ 포화) 쌍 수 × 신호창 폭/사이드밴드 폭 (0차 외삽)
//              prompt 스펙트럼 모양은 신호창 안에서 평평, delayed 모양은 사이드밴드 쌍의 delayed 그대로
//   * ⁹Li/⁸He : 날짜마다 직전 샤워링 뮤온까지의 dt 를 Daya Bay Eq.2 로 적합 (표본 lihe_min_cand 미만이면 lowstat=0)
//              스펙트럼 모양은 '직전 샤워링 뮤온 뒤 3τ 안의 쌍' 에서 '직후(역방향) 3τ 안의 쌍' 을 뺀 초과분
//   ★예비 표기는 metrics 와 같다 — fast-n · Li/He 는 분석팀 검증 전까지 물리로 읽지 말 것.
#include <TCanvas.h>
#include <TFile.h>
#include <TH1D.h>
#include <TLegend.h>
#include <TPad.h>
#include <TStyle.h>
#include <TString.h>
#include <TSystem.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "ReneDailyCore.h"
#include "ReneTrendPlot.h"

// ---------------------------------------------------------------------------
struct RunMeta { int run = 0, nsub = 0; double es = -1, ee = -1, span = -1, live = -1; };

static std::map<int, RunMeta> LoadRunSummary(const TString &p) {
   std::map<int, RunMeta> out; std::ifstream in(p.Data()); std::string line;
   while (std::getline(in, line)) {
      if (line.empty() || line[0] == '#') continue;
      std::stringstream ss(line); RunMeta m; int nbad; double wall, dead;
      if (!(ss >> m.run >> m.nsub >> nbad >> m.es >> m.ee >> wall >> m.span >> m.live >> dead)) continue;
      out[m.run] = m;
   }
   return out;
}
static std::map<int, std::string> LoadRunTypes(const TString &p) {
   std::map<int, std::string> out; std::ifstream in(p.Data()); std::string line;
   while (std::getline(in, line)) {
      if (line.empty() || line[0] == '#') continue;
      std::stringstream ss(line); int run; std::string src;
      if (ss >> run >> src) out[run] = src;
   }
   return out;
}
//  epoch [s] → 지역 날짜 "YYYY-MM-DD" 와 그 날 0 시의 epoch
static std::string DayOf(double epoch, double *dayStart = nullptr) {
   time_t t = (time_t)epoch; struct tm lt; localtime_r(&t, &lt);
   char b[16]; strftime(b, sizeof b, "%Y-%m-%d", &lt);
   if (dayStart) { lt.tm_hour = 0; lt.tm_min = 0; lt.tm_sec = 0; *dayStart = (double)mktime(&lt); }
   return b;
}

struct DayAcc {
   std::string day; double dayStart = 0;
   double live = 0; std::set<int> runs; int nsub = 0;
   long long nOn = 0, nOff = 0, nSide = 0;           // multiplicity 통과 쌍 : on · off · 사이드밴드(on)
   long long nShower = 0;
   std::vector<double> dtPrev;                       // on 쌍의 직전 샤워링 뮤온까지 dt [s]  (Li/He 적합 표본)
   std::vector<double> dtNext;                       // 역방향 (대조)
   double nLihe = -1, eLihe = -1; std::string liheStat = "-";
};

// ---------------------------------------------------------------------------
//  스펙트럼 그림 : 배경 빼기 전(검정) 과 전부 뺀 뒤(빨강). 선형축 + 로그 inset (우상단), 범례는 우측 중간.
static void DrawSpectrum(const TString &dir, const char *file, const char *title, TH1D *hAll, TH1D *hSub,
                         const std::vector<std::pair<std::string, double>> &parts) {
   TCanvas *c = new TCanvas(Form("c_%s", file), title, 1400, 700);
   c->SetLeftMargin(0.11); c->SetBottomMargin(0.13); c->SetRightMargin(0.04); c->SetGridx(); c->SetGridy();
   hAll->SetTitle(Form("%s;Energy [MeV];Events / %.2f MeV", title, hAll->GetBinWidth(1)));
   hAll->SetLineColor(kBlack); hAll->SetLineWidth(2); hAll->SetStats(0);
   hSub->SetLineColor(kRed + 1); hSub->SetLineWidth(2); hSub->SetFillColorAlpha(kRed + 1, 0.15); hSub->SetStats(0);
   double ymax = std::max(hAll->GetMaximum(), hSub->GetMaximum());
   hAll->SetMinimum(0); hAll->SetMaximum(ymax * 1.20);
   hAll->GetXaxis()->SetTitleSize(0.045); hAll->GetYaxis()->SetTitleSize(0.045); hAll->GetYaxis()->SetTitleOffset(1.1);
   hAll->Draw("HIST"); hSub->Draw("HIST SAME");
   TLegend *leg = new TLegend(0.58, 0.14 + 0.05, 0.95, 0.14 + 0.05 + 0.045 * (2 + parts.size()));
   leg->SetBorderSize(0); leg->SetFillStyle(1001); leg->SetFillColor(kWhite); leg->SetTextSize(0.030);
   leg->AddEntry(hAll, Form("all pairs (on-window)  N = %.0f", hAll->Integral()), "l");
   leg->AddEntry(hSub, Form("after background subtraction  N = %.0f", hSub->Integral()), "lf");
   for (const auto &p : parts) leg->AddEntry((TObject *)nullptr, Form("  #minus %s : %.1f", p.first.c_str(), p.second), "");
   leg->Draw();
   //  로그 inset (우상단) : 낮은 빈이 보이도록
   if (hAll->GetMaximum() > 0) {
      TPad *pd = new TPad(Form("ins_%s", file), "", 0.57, 0.52, 0.95, 0.88);
      pd->SetFillStyle(4000); pd->SetFillColor(0); pd->SetLeftMargin(0.2); pd->SetBottomMargin(0.2); pd->SetLogy(); pd->SetGridy();
      pd->Draw(); pd->cd();
      TH1D *a2 = (TH1D *)hAll->Clone(Form("%s_ins", hAll->GetName())); TH1D *s2 = (TH1D *)hSub->Clone(Form("%s_ins", hSub->GetName()));
      a2->SetTitle(";;log scale"); a2->SetMinimum(0.5); a2->SetMaximum(ymax * 3);
      a2->GetXaxis()->SetLabelSize(0.07); a2->GetYaxis()->SetLabelSize(0.07); a2->GetYaxis()->SetTitleSize(0.07); a2->GetYaxis()->SetTitleOffset(1.0);
      a2->Draw("HIST"); s2->Draw("HIST SAME");
      c->cd();
   }
   c->Print(dir + file + ".png");
}

// ---------------------------------------------------------------------------
void BuildDaily(const char *outDir = "/scratch/RunSummary/", double muShowerNpe = 20000, double liheFitLoS = 0.002,
                double liheFitHiS = 10.0, int liheMinCand = 50, double fnELoMev = 12.0, double fnEHiMev = 50.0,
                double liheLiFrac = 1.0) {
   gStyle->SetOptStat(0);
   TString out(outDir); if (!out.EndsWith("/")) out += "/";
   auto meta  = LoadRunSummary(out + "run_summary.tsv");
   auto rtype = LoadRunTypes(out + "runtype.tsv");
   if (meta.empty()) { printf("[FATAL] run_summary.tsv 가 없다 (%s)\n", out.Data()); return; }

   const Channel chans[2] = {CH_NGD, CH_NH};
   const char *fileTag[2] = {"nGd", "nH"};
   const char *chanName[2] = {"n-Gd", "n-H"};
   std::map<std::string, DayAcc> acc[2];                 // [채널][날짜]
   //  스펙트럼 [채널] : prompt/delayed × on/off/사이드밴드 delayed/Li-He 템플릿(prev·next)
   const int nbE = 60; const double eLo = 0, eHi = 12;
   TH1D *hP[2][2], *hD[2][2], *hDside[2], *hPli[2][2], *hDli[2][2];
   for (int k = 0; k < 2; ++k) {
      for (int o = 0; o < 2; ++o) {
         hP[k][o] = new TH1D(Form("prompt_%s_%s", fileTag[k], o ? "off" : "on"), "", nbE, eLo, eHi); hP[k][o]->SetDirectory(nullptr);
         hD[k][o] = new TH1D(Form("delayed_%s_%s", fileTag[k], o ? "off" : "on"), "", nbE, eLo, eHi); hD[k][o]->SetDirectory(nullptr);
         hPli[k][o] = new TH1D(Form("prompt_%s_lihe_%s", fileTag[k], o ? "next" : "prev"), "", nbE, eLo, eHi); hPli[k][o]->SetDirectory(nullptr);
         hDli[k][o] = new TH1D(Form("delayed_%s_lihe_%s", fileTag[k], o ? "next" : "prev"), "", nbE, eLo, eHi); hDli[k][o]->SetDirectory(nullptr);
      }
      hDside[k] = new TH1D(Form("delayed_%s_sideband", fileTag[k]), "", nbE, eLo, eHi); hDside[k]->SetDirectory(nullptr);
   }
   double acciScale[2] = {1, 1}, fnScale[2] = {0, 0};    // fnScale = 신호창 폭 / 사이드밴드 폭

   int nRunUsed = 0, nRunNoDst = 0, nRunSrc = 0;
   for (const auto &kv : meta) {
      const RunMeta &m = kv.second;
      if (m.es <= 0 || m.live <= 0 || m.nsub <= 0) continue;
      auto ir = rtype.find(m.run);
      if (ir != rtype.end() && !(ir->second == "none" || ir->second == "?")) { nRunSrc++; continue; }
      TString dst = out + TString::Format("dst/DST_%06d.root", m.run);
      if (gSystem->AccessPathName(dst)) { nRunNoDst++; continue; }
      std::vector<S1S2_Candidate> sing; std::vector<Float_t> psd; std::vector<ReneSat> sats; std::vector<ReneMuon> mu;
      double liveS = 0; int nSubrun = 0, schema = 1;
      if (!DailyLoadDst(dst, sing, psd, sats, mu, liveS, nSubrun, schema)) { nRunNoDst++; continue; }
      nRunUsed++;
      std::vector<double> showers = DailyShowerTimes(mu, muShowerNpe);
      //  single ∪ 포화 (fast-n 사이드밴드용, BuildMetrics 와 같다)
      std::vector<S1S2_Candidate> all = sing;
      for (const auto &x : sats) if (x.pe > LOWER_LIMIT) all.push_back({-1, x.sub, x.t_us, (double)x.pe});
      std::sort(all.begin(), all.end());
      const double subLen = (m.span > 0 ? m.span : m.live) / m.nsub;
      const double liveSub = liveS / std::max(1, nSubrun);

      for (int k = 0; k < 2; ++k) {
         SetChannel(chans[k]);
         PairWindows w = CurrentPairWindows();
         acciScale[k] = (w.dtMax > 0) ? (w.dtMax - w.dtMin) / w.dtMax : 1.0;
         PairWindows wf = w; wf.s1lo = MeVToNpe(fnELoMev); wf.s1hi = MeVToNpe(fnEHiMev);
         double sigW = NpeToMeV(w.s1hi) - NpeToMeV(w.s1lo), sideW = fnEHiMev - fnELoMev;
         fnScale[k] = (sideW > 0 && sigW > 0) ? sigW / sideW : 0;
         //  라이브타임을 날짜에 나눠 붙인다
         for (int s = 0; s < nSubrun; ++s) {
            double mid = m.es + (s + 0.5) * subLen; double d0; std::string d = DayOf(mid, &d0);
            DayAcc &a = acc[k][d]; a.day = d; a.dayStart = d0; a.live += liveSub; a.runs.insert(m.run); a.nsub++;
         }
         for (double st : showers) { std::string d = DayOf(m.es + st * 1e-6); acc[k][d].day = d; acc[k][d].nShower++; }
         //  쌍
         std::vector<PairRec> pairs = PairListW(sing, w);
         for (const auto &p : pairs) {
            if (!p.mult) continue;
            std::string d = DayOf(m.es + p.t1_us * 1e-6); DayAcc &a = acc[k][d]; a.day = d;
            double e1 = NpeToMeV(p.e1), e2 = NpeToMeV(p.e2);
            if (p.off) { a.nOff++; hP[k][1]->Fill(e1); hD[k][1]->Fill(e2); continue; }
            a.nOn++; hP[k][0]->Fill(e1); hD[k][0]->Fill(e2);
            double dp = DailyDtShower(p.t1_us, showers, false), dn = DailyDtShower(p.t1_us, showers, true);
            if (dp >= 0) { a.dtPrev.push_back(dp); if (dp < 3 * kDailyTauLiS) { hPli[k][0]->Fill(e1); hDli[k][0]->Fill(e2); } }
            if (dn >= 0) { a.dtNext.push_back(dn); if (dn < 3 * kDailyTauLiS) { hPli[k][1]->Fill(e1); hDli[k][1]->Fill(e2); } }
         }
         std::vector<PairRec> side = PairListW(all, wf);
         for (const auto &p : side) {
            if (!p.mult || p.off) continue;
            std::string d = DayOf(m.es + p.t1_us * 1e-6); acc[k][d].day = d; acc[k][d].nSide++;
            hDside[k]->Fill(NpeToMeV(p.e2));
         }
      }
      printf("  [RUN ] %06d : singles %zu  showers %zu  live %.0f s  (%s)\n", m.run, sing.size(), showers.size(), liveS, DayOf(m.es).c_str());
   }
   printf("[INFO] 런 %d 개 사용 · DST 없음 %d · 선원 런 제외 %d\n", nRunUsed, nRunNoDst, nRunSrc);
   if (nRunUsed == 0) { printf("[FATAL] 쓸 런이 없다\n"); return; }

   //  ---- 날짜별 Li/He 적합 + 표 ----
   double nLiheTot[2] = {0, 0};
   {
      std::ofstream o((out + "daily_summary.tsv").Data());
      o << "# RENE daily summary (machine readable). BuildDaily.C 가 만든다. 런별 표(metrics_summary)와 별개다.\n"
           "# 날짜는 이 PC 의 지역시 자정 기준. live_s 는 서브런을 등분해 날짜에 나눠 붙인 값. rate 는 [/day] = 후보/live.\n"
           "# ★예비 : fast-n(0차 외삽) · Li/He(Daya Bay Eq.2, 표본 " << liheMinCand << " 미만이면 lowstat) 는 분석팀 검증 전.\n"
           "#date\ttag\tlive_s\tn_run\tn_subrun\tn_ibd\tn_ibd_acci\tacci_scaled\tn_cand\tcand_err\trate_per_day\trate_err"
           "\tn_fn_side\tfn_flat\tn_shower\tn_lihe\te_lihe\tlihe_stat\truns\n";
      for (int k = 0; k < 2; ++k) {
         SetChannel(chans[k]); std::string tag = ChannelTag(chans[k]).Data();
         for (auto &kv : acc[k]) {
            DayAcc &a = kv.second;
            if (a.live <= 0) continue;
            double nAcci = acciScale[k] * a.nOff, nCand = a.nOn - nAcci;
            double err = std::sqrt((double)a.nOn + acciScale[k] * acciScale[k] * a.nOff);
            double day = a.live / 86400.0;
            double rMu = a.nShower / a.live;
            if (a.nShower == 0 || rMu <= 0) a.liheStat = "noshower";
            else if ((long long)a.dtPrev.size() < liheMinCand) a.liheStat = "lowstat";
            else {
               TH1D h(Form("hdt_%s_%s", fileTag[k], a.day.c_str()), "", 200, 0, liheFitHiS); h.SetDirectory(nullptr);
               for (double x : a.dtPrev) h.Fill(x);
               double nL, eL;
               if (DailyFitLiHe(&h, Form("flihe_%s_%s", fileTag[k], a.day.c_str()), liheFitLoS, liheFitHiS, rMu, liheLiFrac, nL, eL)) {
                  a.nLihe = nL; a.eLihe = eL; a.liheStat = "ok"; nLiheTot[k] += nL;
               } else a.liheStat = "nofit";
            }
            std::string runs; for (int r : a.runs) runs += (runs.empty() ? "" : ",") + std::to_string(r);
            o << a.day << '\t' << tag << '\t' << TString::Format("%.1f", a.live) << '\t' << a.runs.size() << '\t' << a.nsub << '\t'
              << a.nOn << '\t' << a.nOff << '\t' << TString::Format("%.2f", nAcci) << '\t' << TString::Format("%.2f", nCand) << '\t'
              << TString::Format("%.2f", err) << '\t' << TString::Format("%.2f", day > 0 ? nCand / day : 0) << '\t'
              << TString::Format("%.2f", day > 0 ? err / day : 0) << '\t' << a.nSide << '\t' << TString::Format("%.2f", a.nSide * fnScale[k]) << '\t'
              << a.nShower << '\t' << TString::Format("%.2f", a.nLihe) << '\t' << TString::Format("%.2f", a.eLihe) << '\t' << a.liheStat << '\t' << runs << '\n';
         }
      }
   }
   printf("[SAVED] %sdaily_summary.tsv\n", out.Data());

   //  ---- 날짜 추이 그림 (32~36) ----
   {
      TString nopdf = "";
      TrendPageOpt o; o.logInset = true;
      {  // 32 라이브타임 (두 채널이 같다)
         TrendSeries s; s.label = "live time"; s.color = kBlack; s.marker = 20;
         for (auto &kv : acc[0]) if (kv.second.live > 0) s.add(kv.second.dayStart + 43200, kv.second.live / 3600.0, 0);
         std::vector<TrendSeries> v{s}; TrendPageOpt o2; o2.logInset = false;
         DrawTrendPage(nopdf, out, "32_daily_livetime", "Live time per calendar day", "live time [h]", v, "", o2);
      }
      for (int k = 0; k < 2; ++k) {  // 33·34 후보 수/일, 35·36 rate
         TrendSeries sc, sr; sc.label = chanName[k]; sr.label = chanName[k];
         sc.color = sr.color = (k ? kBlue + 1 : kRed + 1); sc.marker = sr.marker = (k ? 21 : 20);
         for (auto &kv : acc[k]) {
            const DayAcc &a = kv.second; if (a.live <= 0) continue;
            double nAcci = acciScale[k] * a.nOff, nCand = a.nOn - nAcci;
            double err = std::sqrt((double)a.nOn + acciScale[k] * acciScale[k] * a.nOff), day = a.live / 86400.0;
            sc.add(a.dayStart + 43200, nCand, err);
            sr.add(a.dayStart + 43200, nCand / day, err / day);
         }
         std::vector<TrendSeries> vc{sc}, vr{sr};
         DrawTrendPage(nopdf, out, Form("%02d_daily_candidates_%s", 33 + k, fileTag[k]),
                       Form("IBD candidates per calendar day, %s (accidental subtracted)", chanName[k]), "Candidates / day", vc, "", o);
         DrawTrendPage(nopdf, out, Form("%02d_daily_rate_%s", 35 + k, fileTag[k]),
                       Form("IBD candidate rate per calendar day, %s (= candidates / live time)", chanName[k]), "Rate [/day]", vr, "", o);
      }
   }

   //  ---- 스펙트럼 (37~40) : 배경 빼기 전 / 전부 뺀 뒤 ----
   TFile *fs = TFile::Open(out + "daily_spectra.root", "RECREATE");
   for (int k = 0; k < 2; ++k) {
      SetChannel(chans[k]); PairWindows w = CurrentPairWindows();
      double s1lo = NpeToMeV(w.s1lo), s1hi = NpeToMeV(w.s1hi);
      long long nSideAll = 0; for (auto &kv : acc[k]) nSideAll += kv.second.nSide;
      double nFn = nSideAll * fnScale[k];
      double nLi = nLiheTot[k];
      //  prompt : on − scale·off − fast-n(신호창 안 평평) − Li/He(초과분 템플릿을 n_lihe 로 규격화)
      TH1D *pAll = (TH1D *)hP[k][0]->Clone(Form("prompt_%s_all", fileTag[k]));
      TH1D *pSub = (TH1D *)hP[k][0]->Clone(Form("prompt_%s_subtracted", fileTag[k]));
      pSub->Add(hP[k][1], -acciScale[k]);
      TH1D *pFn = (TH1D *)pAll->Clone(Form("prompt_%s_fastn", fileTag[k])); pFn->Reset();
      { int b1 = pFn->FindBin(s1lo), b2 = pFn->FindBin(std::min(s1hi, eHi - 1e-6)); int nb = std::max(1, b2 - b1 + 1);
        for (int b = b1; b <= b2; ++b) pFn->SetBinContent(b, nFn / nb); }
      pSub->Add(pFn, -1);
      TH1D *pLi = (TH1D *)hPli[k][0]->Clone(Form("prompt_%s_lihe_template", fileTag[k])); pLi->Add(hPli[k][1], -1);
      for (int b = 1; b <= pLi->GetNbinsX(); ++b) if (pLi->GetBinContent(b) < 0) pLi->SetBinContent(b, 0);
      if (nLi > 0 && pLi->Integral() > 0) { pLi->Scale(nLi / pLi->Integral()); pSub->Add(pLi, -1); }
      //  delayed : on − scale·off − fast-n(사이드밴드 쌍의 delayed 모양) − Li/He(초과분 템플릿)
      TH1D *dAll = (TH1D *)hD[k][0]->Clone(Form("delayed_%s_all", fileTag[k]));
      TH1D *dSub = (TH1D *)hD[k][0]->Clone(Form("delayed_%s_subtracted", fileTag[k]));
      dSub->Add(hD[k][1], -acciScale[k]);
      TH1D *dFn = (TH1D *)hDside[k]->Clone(Form("delayed_%s_fastn", fileTag[k]));
      if (nFn > 0 && dFn->Integral() > 0) { dFn->Scale(nFn / dFn->Integral()); dSub->Add(dFn, -1); }
      TH1D *dLi = (TH1D *)hDli[k][0]->Clone(Form("delayed_%s_lihe_template", fileTag[k])); dLi->Add(hDli[k][1], -1);
      for (int b = 1; b <= dLi->GetNbinsX(); ++b) if (dLi->GetBinContent(b) < 0) dLi->SetBinContent(b, 0);
      if (nLi > 0 && dLi->Integral() > 0) { dLi->Scale(nLi / dLi->Integral()); dSub->Add(dLi, -1); }
      std::vector<std::pair<std::string, double>> parts = {
         {"accidental (off-window #times window ratio)", acciScale[k] * hP[k][1]->Integral()},
         {"fast-n (sideband, flat)  [prelim]", nFn},
         {"^{9}Li/^{8}He (daily fits)  [prelim]", nLi}};
      DrawSpectrum(out, Form("%02d_spectrum_prompt_%s", 37 + 2 * k, fileTag[k]),
                   Form("Prompt energy spectrum of all IBD pairs, %s (all days)", chanName[k]), pAll, pSub, parts);
      DrawSpectrum(out, Form("%02d_spectrum_delayed_%s", 38 + 2 * k, fileTag[k]),
                   Form("Delayed energy spectrum of all IBD pairs, %s (all days)", chanName[k]), dAll, dSub, parts);
      fs->cd();
      for (TH1D *h : {pAll, pSub, pFn, pLi, dAll, dSub, dFn, dLi, hP[k][0], hP[k][1], hD[k][0], hD[k][1], hDside[k]}) h->Write();
      printf("  [SPEC] %s : on %.0f  off·scale %.1f  fast-n %.1f  Li/He %.1f  -> prompt after %.1f, delayed after %.1f\n",
             chanName[k], pAll->Integral(), acciScale[k] * hP[k][1]->Integral(), nFn, nLi, pSub->Integral(), dSub->Integral());
   }
   fs->Close();
   printf("[SAVED] %sdaily_spectra.root + %s32..40_*.png\n", out.Data(), out.Data());
}
