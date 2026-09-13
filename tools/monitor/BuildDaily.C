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
//          <OutDir>/32..52_*.png         (32~36 날짜 추이 · 37~40 스펙트럼 전/후 · 41~44 배경 성분별 · 45~48 신호창 분해
//                                         · 49~50 prompt PSD · 51~52 샤워링 뮤온 뒤 dt 와 Li/He 적합
//                                         · 53~54 다중도 분포 + 포아송 외삽 · 55~56 남는 신호 대 다중중성자 가족의 prompt 모양)
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
//   ---- 추가 컷 · 대안 규격화 (2026-09-14, 사용자 : "배경 컷이 더 있어야 한다. 신호 스펙트럼이 이상하다") ----
//   * psdCutNsig > 0 : prompt 의 p_psd = (꼬리비율 − m_γ(E)) / σ_γ(E) 가 이 값을 넘는 쌍을 버린다 (NEOS §4.3.2.2 의 기각.
//     m_γ·σ_γ 는 그 런의 clean single 을 에너지 밴드 6 개로 나눠 잰다 — BuildMetrics 와 같은 밴드). on/off 쌍에 똑같이 걸어
//     우발 추정이 어긋나지 않게 한다. γ 수용은 3σ 에서 99.9 % 라 효율 보정은 하지 않는다. 버린 쌍의 스펙트럼을 41~44 에 그린다.
//   * muVetoUs > 0 : prompt 가 **어느 veto 뮤온이든** 그 뒤 muVetoUs 안이면 쌍을 버린다 (DST 의 150 µs after-muon 컷을 늘리는 것).
//     라이브타임은 그 런의 뮤온율로 exp(−R_μ·(muVetoUs−150 µs)) 만큼 줄여 센다. showerVetoMs > 0 은 샤워링 뮤온 뒤 ms 단위 veto
//     (Li/He 를 직접 자른다. 적합 창 아래끝은 그 값 이상으로 올린다). 버린 쌍의 스펙트럼을 41~44 에 그린다 —
//     그 모양이 '신호' 와 같으면 신호가 뮤온 유발 배경이라는 뜻이다.
//   * dstSub : DST 폴더 이름. "dst" = 분석 코드의 패널 AND veto, "dst_m2" = 강한 veto(PMT 하나라도 트리거 또는 S_ADC > 50)로
//     dst-build.sh --muon-mode 2 가 만든 것. 런별 파이프라인은 언제나 dst/ 를 쓴다.
//   * 라이브타임 : DST 의 live_s 는 서브런 벽시계 합이라 after-muon 데드타임이 안 빠져 있다. 여기서 exp(−R_μ·veto_us) 를 곱한다
//     (패널 AND 864 Hz × 150 µs → 12 % 감소. 이 보정은 4d 에만 있다 — 런별 표는 그대로다).
//   * fnNormMode = 1 : fast-n 평평한 높이를 사이드밴드(12~50 MeV, 실측 93 % 포화 = 에너지가 잘린 사건) 가 아니라
//     **신호창 안의 고에너지 꼬리** [fnNormLoMev, S1 상한] 의 우발 뺀 on-window 쌍 수로 정한다. IBD prompt 는 ~8 MeV 에서
//     끝나므로 그 위는 fast-n (+ Li/He 조금) 뿐이다. 사이드밴드 값은 대조용으로 범례에 남긴다.
//   ★예비 표기는 metrics 와 같다 — fast-n · Li/He 는 분석팀 검증 전까지 물리로 읽지 말 것.
#include <TCanvas.h>
#include <TFile.h>
#include <TH1D.h>
#include <TF1.h>
#include <TLegend.h>
#include <TLine.h>
#include <TPad.h>
#include <THStack.h>
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
   long long nShower = 0, nPsdRej = 0, nMuRej = 0;   // 샤워링 뮤온 수 · PSD 로 버린 on 쌍 · 뮤온 veto 로 버린 on 쌍
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

struct BgComp { TH1D *h; std::string label; int color; };

//  배경 성분별 스펙트럼 : 성분마다 다른 색, 범례에 적분. 선형축 + 로그 inset. side(0~50 MeV) 가 있으면 x 축을 50 까지 늘려 같이 그린다
static void DrawBgComponents(const TString &dir, const char *file, const char *title, std::vector<BgComp> comps,
                             TH1D *side, const char *sideLabel) {
   TCanvas *c = new TCanvas(Form("c_%s", file), title, 1400, 700);
   c->SetLeftMargin(0.11); c->SetBottomMargin(0.13); c->SetRightMargin(0.04); c->SetGridx(); c->SetGridy();
   double xhi = side ? side->GetXaxis()->GetXmax() : comps[0].h->GetXaxis()->GetXmax();
   //  축 범위는 '빼는' 성분(앞 셋)으로 잡는다 — multiplicity 기각분은 스무 배 커서 같이 재면 나머지가 납작해진다. 넘치는 것은 inset(로그) 에서 본다
   double ymax = 0; for (size_t i = 0; i < comps.size() && i < 3; ++i) ymax = std::max(ymax, comps[i].h->GetMaximum());
   for (size_t i = 3; i < comps.size(); ++i) if (comps[i].label.find("not subtracted") == std::string::npos) ymax = std::max(ymax, comps[i].h->GetMaximum());
   //  사이드밴드(회색 점선)는 포화 사건이 30 MeV 한 빈에 몰려 축을 잡아먹는다 — 축 범위에 넣지 않는다 (inset 에서 본다)
   TH1D *frame = new TH1D(Form("frame_%s", file), Form("%s;Energy [MeV];Events / bin", title), 10, 0, xhi);
   frame->SetStats(0); frame->SetMinimum(0); frame->SetMaximum(ymax * 1.25 + 1); frame->GetXaxis()->SetTitleSize(0.045); frame->GetYaxis()->SetTitleSize(0.045);
   frame->Draw();
   TLegend *leg = new TLegend(0.30, 0.56, 0.95, 0.88); leg->SetBorderSize(0); leg->SetFillStyle(1001); leg->SetFillColor(kWhite); leg->SetTextSize(0.021);
   for (auto &cp : comps) { cp.h->SetStats(0); cp.h->SetLineColor(cp.color); cp.h->SetLineWidth(2); cp.h->Draw("HIST SAME"); leg->AddEntry(cp.h, Form("%s : N = %.1f", cp.label.c_str(), cp.h->Integral()), "l"); }
   if (side) { side->SetStats(0); side->SetLineColor(kGray + 2); side->SetLineWidth(2); side->SetLineStyle(2); side->Draw("HIST SAME"); leg->AddEntry(side, Form("%s : N = %.0f", sideLabel, side->Integral()), "l"); }
   leg->Draw();
   TPad *pd = new TPad(Form("ins_%s", file), "", 0.57, 0.15, 0.95, 0.55);
   pd->SetFillStyle(4000); pd->SetFillColor(0); pd->SetLeftMargin(0.2); pd->SetBottomMargin(0.2); pd->SetLogy(); pd->SetGridy(); pd->Draw(); pd->cd();
   double ymaxAll = ymax; for (auto &cp : comps) ymaxAll = std::max(ymaxAll, cp.h->GetMaximum());
   TH1D *f2 = (TH1D *)frame->Clone(Form("%s_ins", frame->GetName())); f2->SetTitle(";;log scale"); f2->SetMinimum(0.5); f2->SetMaximum(ymaxAll * 3 + 2);
   f2->GetXaxis()->SetLabelSize(0.07); f2->GetYaxis()->SetLabelSize(0.07); f2->GetYaxis()->SetTitleSize(0.07); f2->GetYaxis()->SetTitleOffset(1.0); f2->Draw();
   for (auto &cp : comps) { TH1D *h2 = (TH1D *)cp.h->Clone(Form("%s_ins", cp.h->GetName())); h2->Draw("HIST SAME"); }
   if (side) { TH1D *s2 = (TH1D *)side->Clone(Form("%s_ins", side->GetName())); s2->Draw("HIST SAME"); }
   c->cd(); c->Print(dir + file + ".png");
}

//  신호창 분해 : 전체 쌍(검정 점) = 신호(빨강, 맨 아래) + 배경들(쌓음). 선형축
static void DrawDecomposition(const TString &dir, const char *file, const char *title, TH1D *hAll, TH1D *hSig, std::vector<BgComp> comps) {
   TCanvas *c = new TCanvas(Form("c_%s", file), title, 1400, 700);
   c->SetLeftMargin(0.11); c->SetBottomMargin(0.13); c->SetRightMargin(0.04); c->SetGridx(); c->SetGridy();
   THStack *st = new THStack(Form("st_%s", file), Form("%s;Energy [MeV];Events / %.2f MeV", title, hAll->GetBinWidth(1)));
   TH1D *sig = (TH1D *)hSig->Clone(Form("%s_stack", hSig->GetName()));
   for (int b = 1; b <= sig->GetNbinsX(); ++b) if (sig->GetBinContent(b) < 0) sig->SetBinContent(b, 0);
   sig->SetFillColorAlpha(kRed + 1, 0.35); sig->SetLineColor(kRed + 1); st->Add(sig);
   for (auto &cp : comps) { TH1D *h2 = (TH1D *)cp.h->Clone(Form("%s_stack", cp.h->GetName())); h2->SetFillColorAlpha(cp.color, 0.35); h2->SetLineColor(cp.color); st->Add(h2); }
   st->Draw("HIST"); st->SetMaximum(hAll->GetMaximum() * 1.25);
   st->GetXaxis()->SetTitleSize(0.045); st->GetYaxis()->SetTitleSize(0.045); st->GetYaxis()->SetTitleOffset(1.1);
   TH1D *all = (TH1D *)hAll->Clone(Form("%s_pts", hAll->GetName())); all->SetStats(0); all->SetMarkerStyle(20); all->SetMarkerSize(0.9); all->SetLineColor(kBlack); all->Draw("E SAME");
   TLegend *leg = new TLegend(0.58, 0.55, 0.95, 0.88); leg->SetBorderSize(0); leg->SetFillStyle(1001); leg->SetFillColor(kWhite); leg->SetTextSize(0.030);
   leg->AddEntry(all, Form("all pairs (on-window)  N = %.0f", hAll->Integral()), "lp");
   leg->AddEntry(sig, Form("signal (after subtraction)  N = %.0f", hSig->Integral()), "f");
   for (size_t i = 0; i < comps.size(); ++i) leg->AddEntry(st->GetHists()->At((int)i + 1), Form("%s  N = %.1f", comps[i].label.c_str(), comps[i].h->Integral()), "f");
   leg->Draw();
   c->Print(dir + file + ".png");
}

// ---------------------------------------------------------------------------
void BuildDaily(const char *outDir = "/scratch/RunSummary/", double muShowerNpe = 20000, double liheFitLoS = 0.002,
                double liheFitHiS = 10.0, int liheMinCand = 50, double fnELoMev = 12.0, double fnEHiMev = 50.0,
                double liheLiFrac = 1.0, double psdCutNsig = -1, int fnNormMode = 0, double fnNormLoMev = 8.5,
                double muVetoUs = 0, double showerVetoMs = 0, const char *dstSub = "dst") {
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
   TH1D *hPside[2], *hPrej[2][2], *hDrej[2][2];          // 사이드밴드 prompt(0~50 MeV) · multiplicity 기각 쌍 (on/off)
   for (int k = 0; k < 2; ++k) {
      hPside[k] = new TH1D(Form("prompt_%s_sideband", fileTag[k]), "", 100, 0, 50); hPside[k]->SetDirectory(nullptr);
      for (int o = 0; o < 2; ++o) {
         hPrej[k][o] = new TH1D(Form("prompt_%s_multrej_%s", fileTag[k], o ? "off" : "on"), "", nbE, eLo, eHi); hPrej[k][o]->SetDirectory(nullptr);
         hDrej[k][o] = new TH1D(Form("delayed_%s_multrej_%s", fileTag[k], o ? "off" : "on"), "", nbE, eLo, eHi); hDrej[k][o]->SetDirectory(nullptr);
      }
   }
   TH1D *hPsd[2][2], *hPpsdRej[2][2], *hDpsdRej[2][2], *hDtPrev[2], *hDtNext[2];   // p_psd(on/off) · PSD 로 버린 쌍 · 샤워 뒤 dt
   TH1D *hPmuRej[2][2], *hDmuRej[2][2];                                          // 뮤온 veto 로 버린 쌍 (on/off)
   TH1D *hNx[2][2], *hPnx1[2][2], *hPnx2[2][2];                                   // 다중도(창 안 다른 single 수) 분포 · nExtra=1 / >=2 의 prompt (on/off)
   for (int k = 0; k < 2; ++k) {
      for (int o = 0; o < 2; ++o) {
         hPsd[k][o] = new TH1D(Form("psd_%s_%s", fileTag[k], o ? "off" : "on"), "", 90, -6, 12); hPsd[k][o]->SetDirectory(nullptr);
         hPpsdRej[k][o] = new TH1D(Form("prompt_%s_psdrej_%s", fileTag[k], o ? "off" : "on"), "", nbE, eLo, eHi); hPpsdRej[k][o]->SetDirectory(nullptr);
         hDpsdRej[k][o] = new TH1D(Form("delayed_%s_psdrej_%s", fileTag[k], o ? "off" : "on"), "", nbE, eLo, eHi); hDpsdRej[k][o]->SetDirectory(nullptr);
         hPmuRej[k][o] = new TH1D(Form("prompt_%s_muveto_%s", fileTag[k], o ? "off" : "on"), "", nbE, eLo, eHi); hPmuRej[k][o]->SetDirectory(nullptr);
         hDmuRej[k][o] = new TH1D(Form("delayed_%s_muveto_%s", fileTag[k], o ? "off" : "on"), "", nbE, eLo, eHi); hDmuRej[k][o]->SetDirectory(nullptr);
         hNx[k][o] = new TH1D(Form("nextra_%s_%s", fileTag[k], o ? "off" : "on"), "", 12, -0.5, 11.5); hNx[k][o]->SetDirectory(nullptr);
         hPnx1[k][o] = new TH1D(Form("prompt_%s_nextra1_%s", fileTag[k], o ? "off" : "on"), "", nbE, eLo, eHi); hPnx1[k][o]->SetDirectory(nullptr);
         hPnx2[k][o] = new TH1D(Form("prompt_%s_nextra2p_%s", fileTag[k], o ? "off" : "on"), "", nbE, eLo, eHi); hPnx2[k][o]->SetDirectory(nullptr);
      }
      hDtPrev[k] = new TH1D(Form("dt_prev_shower_%s", fileTag[k]), "", 200, 0, liheFitHiS); hDtPrev[k]->SetDirectory(nullptr);
      hDtNext[k] = new TH1D(Form("dt_next_shower_%s", fileTag[k]), "", 200, 0, liheFitHiS); hDtNext[k]->SetDirectory(nullptr);
   }
   double acciScale[2] = {1, 1}, fnScale[2] = {0, 0};    // fnScale = 신호창 폭 / 사이드밴드 폭
   long long nPsdRejTot[2] = {0, 0}, nMuRejTot[2] = {0, 0}; double liveTot[2] = {0, 0}, showerTot[2] = {0, 0};
   const double liheFitLoUse = std::max(liheFitLoS, showerVetoMs * 1e-3);   // 샤워 veto 를 걸면 그 아래는 비어 있다

   int nRunUsed = 0, nRunNoDst = 0, nRunSrc = 0;
   for (const auto &kv : meta) {
      const RunMeta &m = kv.second;
      if (m.es <= 0 || m.live <= 0 || m.nsub <= 0) continue;
      auto ir = rtype.find(m.run);
      if (ir != rtype.end() && !(ir->second == "none" || ir->second == "?")) { nRunSrc++; continue; }
      TString dst = out + TString::Format("%s/DST_%06d.root", dstSub, m.run);
      if (gSystem->AccessPathName(dst)) { nRunNoDst++; continue; }
      std::vector<S1S2_Candidate> sing; std::vector<Float_t> psd; std::vector<ReneSat> sats; std::vector<ReneMuon> mu;
      double liveS = 0, dstVetoUs = 150; int nSubrun = 0, schema = 1, dstMuMode = 0;
      if (!DailyLoadDst(dst, sing, psd, sats, mu, liveS, nSubrun, schema, &dstVetoUs, &dstMuMode)) { nRunNoDst++; continue; }
      nRunUsed++;
      std::vector<double> showers = DailyShowerTimes(mu, muShowerNpe);
      std::vector<double> muT;                                    // 모든 veto 뮤온 시각 (muVetoUs > 0 일 때만)
      if (muVetoUs > 0) { muT.reserve(mu.size()); for (const auto &x : mu) muT.push_back(x.t_us); std::sort(muT.begin(), muT.end()); }
      const double rMuAll = liveS > 0 ? mu.size() / liveS : 0, rShower = liveS > 0 ? showers.size() / liveS : 0;
      double liveFac = std::exp(-rMuAll * dstVetoUs * 1e-6);    // DST 의 after-muon 데드타임 (live_s 는 벽시계 합이다)
      if (muVetoUs > dstVetoUs) liveFac *= std::exp(-rMuAll * (muVetoUs - dstVetoUs) * 1e-6);   // 늘린 veto 의 추가분
      if (showerVetoMs > 0) liveFac *= std::exp(-rShower * showerVetoMs * 1e-3);
      //  single ∪ 포화 (fast-n 사이드밴드용, BuildMetrics 와 같다)
      std::vector<S1S2_Candidate> all = sing;
      for (const auto &x : sats) if (x.pe > LOWER_LIMIT) all.push_back({-1, x.sub, x.t_us, (double)x.pe});
      std::sort(all.begin(), all.end());
      const double subLen = (m.span > 0 ? m.span : m.live) / m.nsub;
      const double liveSub = liveS * liveFac / std::max(1, nSubrun);
      //  PSD γ-band : 에너지 밴드별 clean single 꼬리비율의 평균·RMS (BuildMetrics 와 같은 밴드). 밴드에 100 개 미만이면 못 쓴다
      static const double kBand[] = {0.6, 1.2, 2.0, 3.0, 4.5, 6.0, 12.0}; const int nB = 6;
      double bm[6] = {0}, bs[6] = {0}; bool bok[6] = {false};
      {
         double S1[6] = {0}, S2[6] = {0}; long long N[6] = {0};
         for (size_t i = 0; i < sing.size(); ++i) {
            if (i >= psd.size() || psd[i] < 0) continue;
            double mev = NpeToMeV(sing[i]._pe_sum);
            for (int b = 0; b < nB; ++b) if (mev >= kBand[b] && mev < kBand[b + 1]) { S1[b] += psd[i]; S2[b] += (double)psd[i] * psd[i]; N[b]++; break; }
         }
         for (int b = 0; b < nB; ++b) if (N[b] >= 100) { bm[b] = S1[b] / N[b]; double v = S2[b] / N[b] - bm[b] * bm[b]; if (v > 0) { bs[b] = std::sqrt(v); bok[b] = true; } }
      }
      auto pPsd = [&](long long i1) -> double {          // p_psd. 없으면 -99
         if (i1 < 0 || i1 >= (long long)psd.size() || psd[i1] < 0) return -99;
         double mev = NpeToMeV(sing[i1]._pe_sum);
         for (int b = 0; b < nB; ++b) if (mev >= kBand[b] && mev < kBand[b + 1]) return bok[b] ? (psd[i1] - bm[b]) / bs[b] : -99;
         return -99;
      };

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
            double e1 = NpeToMeV(p.e1), e2 = NpeToMeV(p.e2); const int o = p.off ? 1 : 0;
            hNx[k][o]->Fill(std::min(p.nExtra, 11));
            if (p.nExtra == 1) hPnx1[k][o]->Fill(e1); else if (p.nExtra >= 2) hPnx2[k][o]->Fill(e1);
            if (!p.mult) { hPrej[k][o]->Fill(e1); hDrej[k][o]->Fill(e2); continue; }
            std::string d = DayOf(m.es + p.t1_us * 1e-6); DayAcc &a = acc[k][d]; a.day = d;
            if (muVetoUs > 0 || showerVetoMs > 0) {
               bool rej = false;
               if (muVetoUs > 0) { auto it = std::lower_bound(muT.begin(), muT.end(), p.t1_us); if (it != muT.begin() && p.t1_us - *(it - 1) < muVetoUs) rej = true; }
               if (!rej && showerVetoMs > 0) { double dps = DailyDtShower(p.t1_us, showers, false); if (dps >= 0 && dps < showerVetoMs * 1e-3) rej = true; }
               if (rej) { hPmuRej[k][o]->Fill(e1); hDmuRej[k][o]->Fill(e2); if (!p.off) a.nMuRej++; continue; }
            }
            double pp = pPsd(p.i1);
            if (pp > -50) hPsd[k][o]->Fill(std::max(-5.99, std::min(11.99, pp)));
            if (psdCutNsig > 0 && pp > psdCutNsig) { hPpsdRej[k][o]->Fill(e1); hDpsdRej[k][o]->Fill(e2); if (!p.off) a.nPsdRej++; continue; }
            if (p.off) { a.nOff++; hP[k][1]->Fill(e1); hD[k][1]->Fill(e2); continue; }
            a.nOn++; hP[k][0]->Fill(e1); hD[k][0]->Fill(e2);
            double dp = DailyDtShower(p.t1_us, showers, false), dn = DailyDtShower(p.t1_us, showers, true);
            if (dp >= 0) { a.dtPrev.push_back(dp); hDtPrev[k]->Fill(dp); if (dp < 3 * kDailyTauLiS) { hPli[k][0]->Fill(e1); hDli[k][0]->Fill(e2); } }
            if (dn >= 0) { a.dtNext.push_back(dn); hDtNext[k]->Fill(dn); if (dn < 3 * kDailyTauLiS) { hPli[k][1]->Fill(e1); hDli[k][1]->Fill(e2); } }
         }
         std::vector<PairRec> side = PairListW(all, wf);
         for (const auto &p : side) {
            if (!p.mult || p.off) continue;
            std::string d = DayOf(m.es + p.t1_us * 1e-6); acc[k][d].day = d; acc[k][d].nSide++;
            hDside[k]->Fill(NpeToMeV(p.e2)); hPside[k]->Fill(NpeToMeV(p.e1));
         }
      }
      printf("  [RUN ] %06d : singles %zu  muons %zu (%.0f Hz, mode %d)  showers %zu  live %.0f s x %.3f  (%s)\n", m.run, sing.size(), mu.size(), rMuAll, dstMuMode, showers.size(), liveS, liveFac, DayOf(m.es).c_str());
   }
   printf("[INFO] 런 %d 개 사용 · DST 없음 %d · 선원 런 제외 %d\n", nRunUsed, nRunNoDst, nRunSrc);
   if (nRunUsed == 0) { printf("[FATAL] 쓸 런이 없다\n"); return; }

   //  ---- fast-n 규격화 (채널 전체) : 사이드밴드 0차 외삽, 또는 신호창 고에너지 꼬리 ----
   double nFnSide[2] = {0, 0}, nFnUse[2] = {0, 0}; std::string fnHow[2];
   for (int k = 0; k < 2; ++k) {
      SetChannel(chans[k]); PairWindows w = CurrentPairWindows();
      double s1lo = NpeToMeV(w.s1lo), s1hi = NpeToMeV(w.s1hi);
      long long nSideAll = 0; for (auto &kv : acc[k]) { nSideAll += kv.second.nSide; liveTot[k] += kv.second.live; showerTot[k] += kv.second.nShower; nPsdRejTot[k] += kv.second.nPsdRej; nMuRejTot[k] += kv.second.nMuRej; }
      nFnSide[k] = nSideAll * fnScale[k];
      int bS1 = hP[k][0]->FindBin(s1lo), bS2 = hP[k][0]->FindBin(std::min(s1hi, eHi - 1e-6)); int nbS = std::max(1, bS2 - bS1 + 1);
      if (fnNormMode == 1) {
         int bT1 = hP[k][0]->FindBin(std::max(fnNormLoMev, s1lo)), bT2 = bS2; int nbT = std::max(1, bT2 - bT1 + 1);
         double tail = hP[k][0]->Integral(bT1, bT2) - acciScale[k] * hP[k][1]->Integral(bT1, bT2);
         nFnUse[k] = std::max(0.0, tail) / nbT * nbS;
         fnHow[k] = TString::Format("flat, normalized to the %.1f-%.0f MeV tail of the on-window prompt (acc. subtracted)", std::max(fnNormLoMev, s1lo), s1hi).Data();
      } else { nFnUse[k] = nFnSide[k]; fnHow[k] = "flat, sideband 0th-order extrapolation"; }
      printf("[FN  ] %s : sideband %.1f  used %.1f  (%s)  psd-rejected on-pairs %lld  muon-veto-rejected on-pairs %lld\n", chanName[k], nFnSide[k], nFnUse[k], fnHow[k].c_str(), nPsdRejTot[k], nMuRejTot[k]);
   }

   //  ---- 날짜별 Li/He 적합 + 표 ----
   double nLiheTot[2] = {0, 0};
   {
      std::ofstream o((out + "daily_summary.tsv").Data());
      o << "# RENE daily summary (machine readable). BuildDaily.C 가 만든다. 런별 표(metrics_summary)와 별개다.\n"
           "# 날짜는 이 PC 의 지역시 자정 기준. live_s 는 서브런을 등분해 날짜에 나눠 붙인 값. rate 는 [/day] = 후보/live.\n"
           "# ★예비 : fast-n(0차 외삽) · Li/He(Daya Bay Eq.2, 표본 " << liheMinCand << " 미만이면 lowstat) 는 분석팀 검증 전.\n"
           "#date\ttag\tlive_s\tn_run\tn_subrun\tn_ibd\tn_ibd_acci\tacci_scaled\tn_cand\tcand_err\trate_per_day\trate_err"
           "\tn_fn_side\tfn_flat\tn_shower\tn_lihe\te_lihe\tlihe_stat\truns\tn_psd_rej\tfn_mode\tn_mu_rej\n";
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
               if (DailyFitLiHe(&h, Form("flihe_%s_%s", fileTag[k], a.day.c_str()), liheFitLoUse, liheFitHiS, rMu, liheLiFrac, nL, eL)) {
                  a.nLihe = nL; a.eLihe = eL; a.liheStat = "ok"; nLiheTot[k] += nL;
               } else a.liheStat = "nofit";
            }
            std::string runs; for (int r : a.runs) runs += (runs.empty() ? "" : ",") + std::to_string(r);
            o << a.day << '\t' << tag << '\t' << TString::Format("%.1f", a.live) << '\t' << a.runs.size() << '\t' << a.nsub << '\t'
              << a.nOn << '\t' << a.nOff << '\t' << TString::Format("%.2f", nAcci) << '\t' << TString::Format("%.2f", nCand) << '\t'
              << TString::Format("%.2f", err) << '\t' << TString::Format("%.2f", day > 0 ? nCand / day : 0) << '\t'
              << TString::Format("%.2f", day > 0 ? err / day : 0) << '\t' << a.nSide << '\t'
              << TString::Format("%.2f", fnNormMode == 1 ? (liveTot[k] > 0 ? nFnUse[k] * a.live / liveTot[k] : 0) : a.nSide * fnScale[k]) << '\t'
              << a.nShower << '\t' << TString::Format("%.2f", a.nLihe) << '\t' << TString::Format("%.2f", a.eLihe) << '\t' << a.liheStat << '\t' << runs
              << '\t' << a.nPsdRej << '\t' << fnNormMode << '\t' << a.nMuRej << '\n';
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
      double nFn = nFnUse[k];
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
         {fnNormMode == 1 ? "fast-n (flat, tail-normalized)  [prelim]" : "fast-n (sideband, flat)  [prelim]", nFn},
         {"^{9}Li/^{8}He (daily fits)  [prelim]", nLi}};
      DrawSpectrum(out, Form("%02d_spectrum_prompt_%s", 37 + 2 * k, fileTag[k]),
                   Form("Prompt energy spectrum of all IBD pairs, %s (all days)", chanName[k]), pAll, pSub, parts);
      DrawSpectrum(out, Form("%02d_spectrum_delayed_%s", 38 + 2 * k, fileTag[k]),
                   Form("Delayed energy spectrum of all IBD pairs, %s (all days)", chanName[k]), dAll, dSub, parts);
      //  ---- 배경 성분별 스펙트럼 (41~44) 와 신호창 분해 (45~48) ----
      TH1D *pAcc = (TH1D *)hP[k][1]->Clone(Form("prompt_%s_accidental_scaled", fileTag[k])); pAcc->Scale(acciScale[k]);
      TH1D *dAcc = (TH1D *)hD[k][1]->Clone(Form("delayed_%s_accidental_scaled", fileTag[k])); dAcc->Scale(acciScale[k]);
      TH1D *pRej = (TH1D *)hPrej[k][0]->Clone(Form("prompt_%s_multrej_excess", fileTag[k])); pRej->Add(hPrej[k][1], -acciScale[k]);
      TH1D *dRej = (TH1D *)hDrej[k][0]->Clone(Form("delayed_%s_multrej_excess", fileTag[k])); dRej->Add(hDrej[k][1], -acciScale[k]);
      for (TH1D *h : {pRej, dRej}) for (int b = 1; b <= h->GetNbinsX(); ++b) if (h->GetBinContent(b) < 0) h->SetBinContent(b, 0);
      TH1D *pSideFull = (TH1D *)hPside[k]->Clone(Form("prompt_%s_sideband_raw", fileTag[k]));
      TH1D *pPsdRej = (TH1D *)hPpsdRej[k][0]->Clone(Form("prompt_%s_psdrej_excess", fileTag[k])); pPsdRej->Add(hPpsdRej[k][1], -acciScale[k]);
      TH1D *dPsdRej = (TH1D *)hDpsdRej[k][0]->Clone(Form("delayed_%s_psdrej_excess", fileTag[k])); dPsdRej->Add(hDpsdRej[k][1], -acciScale[k]);
      for (TH1D *h : {pPsdRej, dPsdRej}) for (int b = 1; b <= h->GetNbinsX(); ++b) if (h->GetBinContent(b) < 0) h->SetBinContent(b, 0);
      std::vector<BgComp> pc = {{pAcc, "accidental (off-window #times ratio)", (int)kBlue + 1},
                                {pFn,  TString::Format("fast-n (%s)  [prelim]", fnHow[k].c_str()).Data(), (int)kGreen + 2},
                                {pLi,  "^{9}Li/^{8}He template (after-shower excess), scaled to fits  [prelim]", (int)kMagenta + 1},
                                {pRej, "multiplicity-rejected excess (multi-n indicator; not subtracted, may clip)", (int)kOrange + 7}};
      std::vector<BgComp> dc = {{dAcc, "accidental (off-window #times ratio)", (int)kBlue + 1},
                                {dFn,  "fast-n (sideband pairs' delayed shape, scaled)  [prelim]", (int)kGreen + 2},
                                {dLi,  "^{9}Li/^{8}He template, scaled to fits  [prelim]", (int)kMagenta + 1},
                                {dRej, "multiplicity-rejected excess (not subtracted, may clip)", (int)kOrange + 7}};
      if (psdCutNsig > 0) {
         pc.push_back({pPsdRej, TString::Format("PSD n-like prompt rejected (p_{psd} > %.1f), on #minus acc", psdCutNsig).Data(), (int)kCyan + 2});
         dc.push_back({dPsdRej, TString::Format("PSD n-like prompt rejected (p_{psd} > %.1f), on #minus acc", psdCutNsig).Data(), (int)kCyan + 2});
      }
      TH1D *pMuRej = (TH1D *)hPmuRej[k][0]->Clone(Form("prompt_%s_muveto_excess", fileTag[k])); pMuRej->Add(hPmuRej[k][1], -acciScale[k]);
      TH1D *dMuRej = (TH1D *)hDmuRej[k][0]->Clone(Form("delayed_%s_muveto_excess", fileTag[k])); dMuRej->Add(hDmuRej[k][1], -acciScale[k]);
      for (TH1D *h : {pMuRej, dMuRej}) for (int b = 1; b <= h->GetNbinsX(); ++b) if (h->GetBinContent(b) < 0) h->SetBinContent(b, 0);
      if (muVetoUs > 0 || showerVetoMs > 0) {
         std::string lab = TString::Format("muon-veto rejected (%s%s), on #minus acc", muVetoUs > 0 ? TString::Format("< %.0f #mus after any veto muon", muVetoUs).Data() : "",
                                           showerVetoMs > 0 ? TString::Format("%s< %.0f ms after shower", muVetoUs > 0 ? ", " : "", showerVetoMs).Data() : "").Data();
         pc.push_back({pMuRej, lab, (int)kRed + 2}); dc.push_back({dMuRej, lab, (int)kRed + 2});
      }
      DrawBgComponents(out, Form("%02d_bgspec_prompt_%s", 41 + 2 * k, fileTag[k]),
                       Form("Background components, prompt energy, %s (all days)", chanName[k]), pc,
                       pSideFull, TString::Format("sideband pairs' raw prompt %.0f-%.0f MeV (saturated = pinned at 30; flat extrap. %.1f)", fnELoMev, fnEHiMev, nFnSide[k]).Data());
      DrawBgComponents(out, Form("%02d_bgspec_delayed_%s", 42 + 2 * k, fileTag[k]),
                       Form("Background components, delayed energy, %s (all days)", chanName[k]), dc, nullptr, "");
      //  49~50 prompt PSD : on(검정) 대 off(파랑, 우발 비율로 규격화 = γ 참조). 컷 선
      {
         TCanvas *c = new TCanvas(Form("c_psd_%s", fileTag[k]), "", 1400, 700);
         c->SetLeftMargin(0.11); c->SetBottomMargin(0.13); c->SetRightMargin(0.04); c->SetGridx(); c->SetGridy();
         TH1D *on = (TH1D *)hPsd[k][0]->Clone(Form("psd_%s_on_draw", fileTag[k])); TH1D *of = (TH1D *)hPsd[k][1]->Clone(Form("psd_%s_off_draw", fileTag[k]));
         of->Scale(acciScale[k]);
         on->SetTitle(Form("Prompt PSD of IBD pairs, %s : p_{psd} = (tail ratio #minus m_{#gamma}(E)) / #sigma_{#gamma}(E);p_{psd} [#sigma];Pairs / 0.2", chanName[k]));
         on->SetLineColor(kBlack); on->SetLineWidth(2); of->SetLineColor(kBlue + 1); of->SetLineWidth(2); of->SetLineStyle(2);
         on->SetStats(0); on->SetMinimum(0); on->SetMaximum(std::max(on->GetMaximum(), of->GetMaximum()) * 1.25 + 1);
         on->GetXaxis()->SetTitleSize(0.045); on->GetYaxis()->SetTitleSize(0.045);
         on->Draw("HIST"); of->Draw("HIST SAME");
         TLegend *lg = new TLegend(0.55, 0.62, 0.95, 0.88); lg->SetBorderSize(0); lg->SetFillStyle(1001); lg->SetFillColor(kWhite); lg->SetTextSize(0.030);
         lg->AddEntry(on, Form("on-window pairs  N = %.0f", on->Integral()), "l");
         lg->AddEntry(of, Form("off-window (accidental, scaled)  N = %.1f  = #gamma reference", of->Integral()), "l");
         double fracOn = on->Integral() > 0 ? on->Integral(on->FindBin(3.0), on->GetNbinsX()) / on->Integral() : 0;
         double fracOf = of->Integral() > 0 ? of->Integral(of->FindBin(3.0), of->GetNbinsX()) / of->Integral() : 0;
         lg->AddEntry((TObject *)nullptr, Form("p_{psd} > 3 : on %.1f %%, off %.1f %%   (recoil-like excess = fast-n indicator)", 100 * fracOn, 100 * fracOf), "");
         if (psdCutNsig > 0) { TLine *ln = new TLine(psdCutNsig, 0, psdCutNsig, on->GetMaximum() / 1.25); ln->SetLineColor(kRed + 1); ln->SetLineWidth(2); ln->Draw(); lg->AddEntry(ln, Form("cut : reject p_{psd} > %.1f  (rejected on-pairs %lld)", psdCutNsig, nPsdRejTot[k]), "l"); }
         else lg->AddEntry((TObject *)nullptr, "cut : off (daily_psd_nsig <= 0)", "");
         lg->Draw();
         TPad *pd = new TPad(Form("ins_psd_%s", fileTag[k]), "", 0.57, 0.16, 0.95, 0.58);
         pd->SetFillStyle(4000); pd->SetFillColor(0); pd->SetLeftMargin(0.2); pd->SetBottomMargin(0.2); pd->SetLogy(); pd->SetGridy(); pd->Draw(); pd->cd();
         TH1D *on2 = (TH1D *)on->Clone(Form("%s_ins", on->GetName())); TH1D *of2 = (TH1D *)of->Clone(Form("%s_ins", of->GetName()));
         on2->SetTitle(";;log scale"); on2->SetMinimum(0.5); on2->SetMaximum(on->GetMaximum() * 3);
         on2->GetXaxis()->SetLabelSize(0.07); on2->GetYaxis()->SetLabelSize(0.07); on2->GetYaxis()->SetTitleSize(0.07); on2->GetYaxis()->SetTitleOffset(1.0);
         on2->Draw("HIST"); of2->Draw("HIST SAME"); c->cd();
         c->Print(out + Form("%02d_bgspec_psd_%s.png", 49 + k, fileTag[k]));
      }
      //  51~52 샤워링 뮤온 뒤 dt (Li/He 의 근거) : 직전(검정) · 직후(회색, 역방향 대조) · 전체 합 적합(빨강)
      {
         TCanvas *c = new TCanvas(Form("c_dt_%s", fileTag[k]), "", 1400, 700);
         c->SetLeftMargin(0.11); c->SetBottomMargin(0.13); c->SetRightMargin(0.04); c->SetGridx(); c->SetGridy();
         TH1D *hp = (TH1D *)hDtPrev[k]->Clone(Form("dt_prev_%s_draw", fileTag[k])); TH1D *hn = (TH1D *)hDtNext[k]->Clone(Form("dt_next_%s_draw", fileTag[k]));
         hp->SetTitle(Form("Time since previous showering muon (> %.0f NPE), on-window pairs, %s;#Deltat_{#mu} [s];Pairs / %.3f s", muShowerNpe, chanName[k], hp->GetBinWidth(1)));
         hp->SetLineColor(kBlack); hp->SetLineWidth(2); hn->SetLineColor(kGray + 2); hn->SetLineWidth(2); hn->SetLineStyle(2);
         hp->SetStats(0); hp->SetMinimum(0); hp->SetMaximum(std::max(hp->GetMaximum(), hn->GetMaximum()) * 1.25 + 1);
         hp->GetXaxis()->SetTitleSize(0.045); hp->GetYaxis()->SetTitleSize(0.045);
         hp->Draw("HIST"); hn->Draw("HIST SAME");
         double rMu = liveTot[k] > 0 ? showerTot[k] / liveTot[k] : 0; double nL = 0, eL = 0; bool fitOk = false;
         if (rMu > 0 && hp->GetEntries() >= liheMinCand) fitOk = DailyFitLiHe(hp, Form("flihe_all_%s", fileTag[k]), liheFitLoUse, liheFitHiS, rMu, liheLiFrac, nL, eL);
         TLegend *lg = new TLegend(0.45, 0.60, 0.95, 0.88); lg->SetBorderSize(0); lg->SetFillStyle(1001); lg->SetFillColor(kWhite); lg->SetTextSize(0.030);
         lg->AddEntry(hp, Form("#Deltat to previous shower  N = %.0f", hp->Integral()), "l");
         lg->AddEntry(hn, Form("#Deltat to next shower (reverse control)  N = %.0f", hn->Integral()), "l");
         if (fitOk) {
            TF1 *f = (TF1 *)hp->GetListOfFunctions()->FindObject(Form("flihe_all_%s", fileTag[k]));
            TF1 *fd = new TF1(Form("flihe_draw_%s", fileTag[k]), "[3]*([0]*([4]*[5]*exp(-[5]*x)+(1-[4])*[6]*exp(-[6]*x)) + [1]*[2]*exp(-[2]*x))", liheFitLoUse, liheFitHiS);
            fd->SetParameters(nL, 0, rMu, hp->GetBinWidth(1), liheLiFrac, 1.0 / kDailyTauLiS, 1.0 / kDailyTauHeS);
            //  우발항 크기 : 적합에서 되읽는다 (DailyFitLiHe 는 N_LiHe 만 돌려주므로 총량에서 뺀다)
            double nUnc = std::max(0.0, hp->Integral() - nL); fd->SetParameter(1, nUnc);
            fd->SetLineColor(kRed + 1); fd->SetLineWidth(2); fd->Draw("SAME");
            lg->AddEntry(fd, Form("Daya Bay Eq.2 fit on the sum : N_{LiHe} = %.1f #pm %.1f  (R_{#mu} = %.3f Hz, 1/R_{#mu} = %.2f s, #tau_{Li} = %.3f s)", nL, eL, rMu, rMu > 0 ? 1 / rMu : 0, kDailyTauLiS), "l");
            (void)f;
         } else lg->AddEntry((TObject *)nullptr, "fit : not done (no showers or too few pairs)", "");
         lg->AddEntry((TObject *)nullptr, Form("sum of daily fits used for subtraction : %.1f  [prelim]", nLiheTot[k]), "");
         lg->Draw();
         TPad *pd = new TPad(Form("ins_dt_%s", fileTag[k]), "", 0.57, 0.16, 0.95, 0.56);
         pd->SetFillStyle(4000); pd->SetFillColor(0); pd->SetLeftMargin(0.2); pd->SetBottomMargin(0.2); pd->SetLogy(); pd->SetGridy(); pd->Draw(); pd->cd();
         TH1D *hp2 = (TH1D *)hp->Clone(Form("%s_ins", hp->GetName())); TH1D *hn2 = (TH1D *)hn->Clone(Form("%s_ins", hn->GetName()));
         hp2->SetTitle(";;log scale"); hp2->SetMinimum(0.5); hp2->SetMaximum(hp->GetMaximum() * 3);
         hp2->GetXaxis()->SetLabelSize(0.07); hp2->GetYaxis()->SetLabelSize(0.07); hp2->GetYaxis()->SetTitleSize(0.07); hp2->GetYaxis()->SetTitleOffset(1.0);
         hp2->Draw("HIST"); hn2->Draw("HIST SAME"); c->cd();
         c->Print(out + Form("%02d_bgspec_lihe_dt_%s.png", 51 + k, fileTag[k]));
      }
      DrawDecomposition(out, Form("%02d_decomp_prompt_%s", 45 + 2 * k, fileTag[k]),
                        Form("Prompt spectrum decomposition, %s : all pairs = signal + backgrounds", chanName[k]),
                        pAll, pSub, {{pAcc, "accidental", (int)kBlue + 1}, {pFn, "fast-n [prelim]", (int)kGreen + 2}, {pLi, "Li/He [prelim]", (int)kMagenta + 1}});
      DrawDecomposition(out, Form("%02d_decomp_delayed_%s", 46 + 2 * k, fileTag[k]),
                        Form("Delayed spectrum decomposition, %s : all pairs = signal + backgrounds", chanName[k]),
                        dAll, dSub, {{dAcc, "accidental", (int)kBlue + 1}, {dFn, "fast-n [prelim]", (int)kGreen + 2}, {dLi, "Li/He [prelim]", (int)kMagenta + 1}});
      //  53~54 다중도 분포와 포아송 외삽 : 창 안 다른 single 수 n 의 on−acc 초과분 N(n). 뮤온 파쇄 중성자 다발이 포아송이면
      //  N(0) 의 다중중성자 몫 ≈ N(1)²/(2·N(2)). 이것이 남는 '신호' 와 비슷하면 신호가 2-중성자 배경이라는 뜻이다
      double nxN[3] = {0, 0, 0}, n0est = -1, n0estErr = -1;
      {
         TH1D *ex = (TH1D *)hNx[k][0]->Clone(Form("nextra_%s_excess", fileTag[k])); ex->Add(hNx[k][1], -acciScale[k]);
         for (int n = 0; n < 3; ++n) nxN[n] = ex->GetBinContent(ex->FindBin(n));
         if (nxN[2] > 0) { n0est = nxN[1] * nxN[1] / (2 * nxN[2]);
            double r1 = std::sqrt(hNx[k][0]->GetBinContent(2) + acciScale[k] * acciScale[k] * hNx[k][1]->GetBinContent(2)) / std::max(1.0, nxN[1]);
            double r2 = std::sqrt(hNx[k][0]->GetBinContent(3) + acciScale[k] * acciScale[k] * hNx[k][1]->GetBinContent(3)) / std::max(1.0, nxN[2]);
            n0estErr = n0est * std::sqrt(4 * r1 * r1 + r2 * r2); }
         TCanvas *c = new TCanvas(Form("c_nx_%s", fileTag[k]), "", 1400, 700);
         c->SetLeftMargin(0.11); c->SetBottomMargin(0.13); c->SetRightMargin(0.04); c->SetGridx(); c->SetGridy();
         TH1D *on = (TH1D *)hNx[k][0]->Clone(Form("nextra_%s_on_draw", fileTag[k])); TH1D *of = (TH1D *)hNx[k][1]->Clone(Form("nextra_%s_off_draw", fileTag[k])); of->Scale(acciScale[k]);
         on->SetTitle(Form("Multiplicity of IBD pairs, %s : other singles (> 1.2 MeV) in [prompt#minus%.0f #mus, delayed+%.0f #mus];n_{extra};Pairs", chanName[k], w.isoPre, w.isoPost));
         on->SetLineColor(kBlack); on->SetLineWidth(2); of->SetLineColor(kBlue + 1); of->SetLineWidth(2); of->SetLineStyle(2); ex->SetLineColor(kOrange + 7); ex->SetLineWidth(3);
         for (int b = 1; b <= ex->GetNbinsX(); ++b) if (ex->GetBinContent(b) < 0) ex->SetBinContent(b, 0);
         on->SetStats(0); on->SetMinimum(0); on->SetMaximum(on->GetMaximum() * 1.3 + 1); on->GetXaxis()->SetTitleSize(0.045); on->GetYaxis()->SetTitleSize(0.045);
         on->Draw("HIST"); of->Draw("HIST SAME"); ex->Draw("HIST SAME");
         TLegend *lg = new TLegend(0.40, 0.55, 0.95, 0.88); lg->SetBorderSize(0); lg->SetFillStyle(1001); lg->SetFillColor(kWhite); lg->SetTextSize(0.028);
         lg->AddEntry(on, Form("on-window pairs (all, before multiplicity cut)  N = %.0f", on->Integral()), "l");
         lg->AddEntry(of, Form("off-window (accidental, scaled)  N = %.1f", of->Integral()), "l");
         lg->AddEntry(ex, Form("excess on #minus acc : N(0) = %.1f (passes cut)  N(1) = %.1f  N(2) = %.1f  N(#geq3) = %.1f", nxN[0], nxN[1], nxN[2], ex->Integral(ex->FindBin(3), ex->GetNbinsX())), "l");
         if (n0est >= 0) lg->AddEntry((TObject *)nullptr, Form("Poisson extrapolation of the multi-n family to n_{extra}=0 : N(1)^{2}/(2N(2)) = %.0f #pm %.0f  [prelim]", n0est, n0estErr), "");
         lg->AddEntry((TObject *)nullptr, Form("compare : after all subtractions the 'signal' is %.0f", pSub->Integral()), "");
         lg->Draw();
         TPad *pd = new TPad(Form("ins_nx_%s", fileTag[k]), "", 0.57, 0.16, 0.95, 0.52);
         pd->SetFillStyle(4000); pd->SetFillColor(0); pd->SetLeftMargin(0.2); pd->SetBottomMargin(0.2); pd->SetLogy(); pd->SetGridy(); pd->Draw(); pd->cd();
         TH1D *on2 = (TH1D *)on->Clone(Form("%s_ins", on->GetName())); on2->SetTitle(";;log scale"); on2->SetMinimum(0.5); on2->SetMaximum(on->GetMaximum() * 3);
         on2->GetXaxis()->SetLabelSize(0.07); on2->GetYaxis()->SetLabelSize(0.07); on2->GetYaxis()->SetTitleSize(0.07); on2->GetYaxis()->SetTitleOffset(1.0);
         on2->Draw("HIST"); ((TH1D *)of->Clone(Form("%s_ins", of->GetName())))->Draw("HIST SAME"); ((TH1D *)ex->Clone(Form("%s_ins", ex->GetName())))->Draw("HIST SAME"); c->cd();
         c->Print(out + Form("%02d_bgspec_multiplicity_%s.png", 53 + k, fileTag[k]));
         printf("  [MULT] %s : N(0)=%.1f N(1)=%.1f N(2)=%.1f  Poisson N0_est=%.1f +- %.1f  signal=%.1f\n", chanName[k], nxN[0], nxN[1], nxN[2], n0est, n0estErr, pSub->Integral());
         ex->SetDirectory(fs);
      }
      //  55~56 prompt 모양 대조 : 남는 '신호'(빨강) 대 n_extra=1 초과분(초록) · n_extra>=2 초과분(주황), 각각 신호 적분으로 규격화
      {
         TH1D *x1 = (TH1D *)hPnx1[k][0]->Clone(Form("prompt_%s_nextra1_excess", fileTag[k])); x1->Add(hPnx1[k][1], -acciScale[k]);
         TH1D *x2 = (TH1D *)hPnx2[k][0]->Clone(Form("prompt_%s_nextra2p_excess", fileTag[k])); x2->Add(hPnx2[k][1], -acciScale[k]);
         for (TH1D *h : {x1, x2}) for (int b = 1; b <= h->GetNbinsX(); ++b) if (h->GetBinContent(b) < 0) h->SetBinContent(b, 0);
         double nS = std::max(1.0, pSub->Integral()); double n1 = x1->Integral(), n2 = x2->Integral();
         TH1D *s1n = (TH1D *)pSub->Clone(Form("prompt_%s_signal_shape", fileTag[k])); TH1D *x1n = (TH1D *)x1->Clone(Form("%s_norm", x1->GetName())); TH1D *x2n = (TH1D *)x2->Clone(Form("%s_norm", x2->GetName()));
         if (n1 > 0) x1n->Scale(nS / n1); if (n2 > 0) x2n->Scale(nS / n2);
         TCanvas *c = new TCanvas(Form("c_shape_%s", fileTag[k]), "", 1400, 700);
         c->SetLeftMargin(0.11); c->SetBottomMargin(0.13); c->SetRightMargin(0.04); c->SetGridx(); c->SetGridy();
         s1n->SetTitle(Form("Prompt shape comparison, %s : remaining 'signal' vs multi-n families (normalized to the same area);Energy [MeV];Events / %.2f MeV (normalized)", chanName[k], s1n->GetBinWidth(1)));
         s1n->SetStats(0); s1n->SetLineColor(kRed + 1); s1n->SetLineWidth(3); s1n->SetFillStyle(0); x1n->SetLineColor(kGreen + 2); x1n->SetLineWidth(2); x2n->SetLineColor(kOrange + 7); x2n->SetLineWidth(2);
         double ym = std::max({s1n->GetMaximum(), x1n->GetMaximum(), x2n->GetMaximum()}); s1n->SetMinimum(0); s1n->SetMaximum(ym * 1.3 + 1);
         s1n->GetXaxis()->SetTitleSize(0.045); s1n->GetYaxis()->SetTitleSize(0.045);
         s1n->Draw("HIST"); x1n->Draw("HIST SAME"); x2n->Draw("HIST SAME");
         TLegend *lg = new TLegend(0.42, 0.62, 0.95, 0.88); lg->SetBorderSize(0); lg->SetFillStyle(1001); lg->SetFillColor(kWhite); lg->SetTextSize(0.028);
         lg->AddEntry(s1n, Form("remaining 'signal' after all subtractions  N = %.0f", nS), "l");
         lg->AddEntry(x1n, Form("pairs with exactly 1 extra single (on #minus acc), N = %.0f, scaled to %.0f", n1, nS), "l");
         lg->AddEntry(x2n, Form("pairs with #geq 2 extra singles (on #minus acc), N = %.0f, scaled to %.0f", n2, nS), "l");
         lg->AddEntry((TObject *)nullptr, "same shape = the 'signal' is the n_{extra}=0 tail of the same multi-neutron family", "");
         lg->Draw();
         c->Print(out + Form("%02d_bgspec_shape_%s.png", 55 + k, fileTag[k]));
         x1->SetDirectory(fs); x2->SetDirectory(fs); s1n->SetDirectory(fs);
      }
      fs->cd();
      for (TH1D *h : {pAll, pSub, pFn, pLi, dAll, dSub, dFn, dLi, hP[k][0], hP[k][1], hD[k][0], hD[k][1], hDside[k],
                      pAcc, dAcc, pRej, dRej, pSideFull, hPrej[k][0], hPrej[k][1], hDrej[k][0], hDrej[k][1],
                      hPsd[k][0], hPsd[k][1], pPsdRej, dPsdRej, hDtPrev[k], hDtNext[k], pMuRej, dMuRej,
                      hNx[k][0], hNx[k][1], hPnx1[k][0], hPnx1[k][1], hPnx2[k][0], hPnx2[k][1]}) h->Write();
      printf("  [SPEC] %s : on %.0f  off·scale %.1f  fast-n %.1f  Li/He %.1f  -> prompt after %.1f, delayed after %.1f\n",
             chanName[k], pAll->Integral(), acciScale[k] * hP[k][1]->Integral(), nFn, nLi, pSub->Integral(), dSub->Integral());
   }
   fs->Close();
   printf("[SAVED] %sdaily_spectra.root + %s32..56_*.png\n", out.Data(), out.Data());
}
