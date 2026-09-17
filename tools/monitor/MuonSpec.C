// MuonSpec.C — 타겟에서 보이는 뮤온(고에너지 사건) NPE 스펙트럼을 veto 태그 유무로 갈라 그린다 (2026-09-18, 사용자 지시).
//
//   root -l -b -q 'MuonSpec.C+("/scratch/RunSummary/", "dst", 4237, 4348)'
//   → <outDir>/muspec/<dstSub>/  (기본 = 선형축, 5,000 NPE 아래 γ 는 위로 잘림 · 같은 이름 + _log = log-log 전체)  muspec_all_all.png · muspec_month_<YYYY-MM>.png · muspec_week_<YYYY-Www>.png · muspec_run_<NNNNNN>.png
//                                 ★ muspec_cut_<kind>_<key>[_log].png · muspec_cut_overlay_{months,weeks}[_log].png : 한 캔버스에 veto 컷 전(전체) / 뒤(미태그) 스펙트럼
//                                 muspec_overlay_months.png · muspec_overlay_weeks.png (태그 비율 곡선 겹침) · muspec_trend.png (주별 태그 비율 추이)
//                                 muspec_summary.tsv · muspec.root
//   입력 : DST (BuildMonitorDst.C). dst/ = 분석 코드의 패널 AND veto, dst_m2/ = 강한 veto (PMT 하나라도 or S_ADC > 50).
//     태그됨   T_Muons 의 pe > 0 (veto 가 걸린 사건 중 타겟에도 신호가 있는 것. pe = 타겟 두 PMT NPE 합, 1 µs 적분, 포화면 sat=1)
//     태그 안됨 T_Sat (veto 없이 포화된 사건) ∪ T_Singles (veto 없고 포화 안 된 clean single, pe > 1.2 MeV = 610 NPE)
//     ★ 두 표본이 대칭이 아니다 : 태그 안 된 쪽은 after-muon 150 µs 창 안의 사건이 이미 빠져 있고 610 NPE 아래가 없다. 그래서 축을 610 NPE 부터 그린다.
//   기간 : 사건의 서브런(sub_id)으로 날짜를 정한다 (런 시작 epoch + 서브런 중간 시각, 지역시). 라이브타임도 서브런 등분으로 기간에 나눠 붙인다.
//   에너지 눈금 : 610 NPE = 1.2 MeV · 7,265 = 12 MeV · ~19,000 = 30 MeV (NpeToMeV 의 상한, 그 위는 포화 영역).  20,000 NPE 이상 = '샤워링' 문턱.
#include "ReneTrendPlot.h"
#include <TCanvas.h>
#include <TFile.h>
#include <TGraphAsymmErrors.h>
#include <TH1D.h>
#include <TLatex.h>
#include <TLegend.h>
#include <TLine.h>
#include <TPad.h>
#include <TStyle.h>
#include <TSystem.h>
#include <TTree.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace {
const int    kNb = 50; const double kLo = 620, kHi = 6e4;      // log 축 빈 (single 문턱 610.6 NPE 위부터, 포화 상한 ~3.5e4 까지)
struct Meta { int run = 0, nsub = 0; double es = -1, span = -1, live = -1; };
const int    kNbL = 72; const double kLoL = 620, kHiL = 36620;   // 선형 축 빈 (500 NPE 씩. 포화 상한 ~3.5e4 까지)
struct Per {
   std::string key, kind; TH1D *tag = nullptr, *un = nullptr, *tagL = nullptr, *unL = nullptr; double live = 0; std::set<int> runs; double tmin = 1e18, tmax = 0;
   long long nTag[3] = {0, 0, 0}, nUn[3] = {0, 0, 0};           // > 610 / > 3000 / > 20000 NPE
};
std::map<std::string, Meta> LoadMeta(const TString &p) {
   std::map<std::string, Meta> out; std::ifstream in(p.Data()); std::string line;
   while (std::getline(in, line)) {
      if (line.empty() || line[0] == '#') continue;
      std::stringstream ss(line); Meta m; int nbad; double ee, wall, dead;
      if (!(ss >> m.run >> m.nsub >> nbad >> m.es >> ee >> wall >> m.span >> m.live >> dead)) continue;
      out[std::to_string(m.run)] = m;
   }
   return out;
}
std::string Fmt(double epoch, const char *fmt) { time_t t = (time_t)epoch; struct tm lt; localtime_r(&t, &lt); char b[32]; strftime(b, sizeof b, fmt, &lt); return b; }
void LogBins(double *e) { for (int i = 0; i <= kNb; ++i) e[i] = kLo * std::pow(kHi / kLo, (double)i / kNb); }
Per &Get(std::map<std::string, Per> &m, const std::string &key, const std::string &kind, const double *edges) {
   auto it = m.find(key);
   if (it != m.end()) return it->second;
   Per p; p.key = key; p.kind = kind;
   p.tag = new TH1D(Form("tag_%s", key.c_str()), "", kNb, edges); p.tag->SetDirectory(nullptr);
   p.un  = new TH1D(Form("un_%s", key.c_str()), "", kNb, edges);  p.un->SetDirectory(nullptr);
   p.tagL = new TH1D(Form("tagL_%s", key.c_str()), "", kNbL, kLoL, kHiL); p.tagL->SetDirectory(nullptr);
   p.unL  = new TH1D(Form("unL_%s", key.c_str()), "", kNbL, kLoL, kHiL);  p.unL->SetDirectory(nullptr);
   return m.emplace(key, p).first->second;
}
void Count(long long *n, double pe) { if (pe > kLo) n[0]++; if (pe > 3000) n[1]++; if (pe > 20000) n[2]++; }

void DrawOne(const TString &dir, const Per &p, const char *dstSub, bool logMode) {
   //  logMode=false (기본 그림) : 선형 x·y, 5,000 NPE 아래의 γ 봉우리는 위로 잘라 뮤온 영역이 보이게 (범례에 적는다)
   //  logMode=true  (_log 그림) : log-log, 620 NPE 부터 전부
   double days = p.live / 86400.0; if (days <= 0) return;
   TH1D *t = (TH1D *)(logMode ? p.tag : p.tagL)->Clone(Form("d_tag_%s", p.key.c_str())), *u = (TH1D *)(logMode ? p.un : p.unL)->Clone(Form("d_un_%s", p.key.c_str()));
   TH1D *s = (TH1D *)t->Clone(Form("d_sum_%s", p.key.c_str())); s->Add(u);
   for (TH1D *h : {t, u, s}) { h->Scale(1.0 / days); h->SetDirectory(nullptr); }
   TCanvas *c = new TCanvas(Form("c_%s", p.key.c_str()), "", 1400, 950);
   TPad *pt = new TPad("pt", "", 0, 0.34, 1, 1), *pb = new TPad("pb", "", 0, 0, 1, 0.34);
   pt->SetBottomMargin(0.02); pt->SetLeftMargin(0.09); pt->SetRightMargin(0.03); pt->SetGridx(); pt->SetGridy(); if (logMode) { pt->SetLogx(); pt->SetLogy(); }
   pb->SetTopMargin(0.03); pb->SetBottomMargin(0.28); pb->SetLeftMargin(0.09); pb->SetRightMargin(0.03); pb->SetGridx(); pb->SetGridy(); if (logMode) pb->SetLogx();
   pt->Draw(); pb->Draw(); pt->cd();
   std::string runs; int nr = 0; for (int r : p.runs) { if (nr++ < 6) runs += (runs.empty() ? "" : ",") + std::to_string(r); } if (p.runs.size() > 6) runs += ",...";
   s->SetTitle(Form("Target muon (high-energy event) spectrum, %s %s  [%s : %s ~ %s, %zu run(s), %.2f live days]", p.kind.c_str(), p.key.c_str(), dstSub,
                    Fmt(p.tmin, "%m-%d %H:%M").c_str(), Fmt(p.tmax, "%m-%d %H:%M").c_str(), p.runs.size(), days));
   s->GetYaxis()->SetTitle("Events / day / bin"); s->GetYaxis()->SetTitleSize(0.045); s->GetYaxis()->SetTitleOffset(0.95); s->GetXaxis()->SetLabelSize(0);
   s->SetLineColor(kBlack); s->SetLineWidth(2); t->SetLineColor(kRed + 1); t->SetLineWidth(2); u->SetLineColor(kBlue + 1); u->SetLineWidth(2);
   s->SetStats(0);
   if (logMode) { double ymax = s->GetMaximum() * 3; s->SetMaximum(ymax > 0 ? ymax : 1); s->SetMinimum(std::max(1e-3, s->GetMinimum(0) * 0.3)); }
   else { double ymax = 0; for (int b = s->FindBin(5000); b <= s->GetNbinsX(); ++b) ymax = std::max(ymax, s->GetBinContent(b)); s->SetMaximum(ymax * 1.45 + 1); s->SetMinimum(0); }
   s->Draw("HIST"); t->Draw("HIST SAME"); u->Draw("HIST SAME");
   for (double x : {3000.0, 7265.0, 20000.0}) { TLine *l = new TLine(x, s->GetMinimum(), x, s->GetMaximum()); l->SetLineStyle(3); l->SetLineColor(kGray + 2); l->Draw(); }
   TLegend *lg = new TLegend(0.47, 0.58, 0.97, 0.89); lg->SetBorderSize(0); lg->SetFillStyle(1001); lg->SetFillColor(kWhite); lg->SetTextSize(0.028);
   lg->AddEntry(s, Form("all target events > 620 NPE : %.3g /day", (p.nTag[0] + p.nUn[0]) / days), "l");
   lg->AddEntry(t, Form("veto-tagged (T_Muons pe>0) : %.3g /day, >3k %.0f, >20k %.0f /day", p.nTag[0] / days, p.nTag[1] / days, p.nTag[2] / days), "l");
   lg->AddEntry(u, Form("untagged (T_Sat #cup T_Singles) : %.3g /day, >3k %.0f, >20k %.0f /day", p.nUn[0] / days, p.nUn[1] / days, p.nUn[2] / days), "l");
   double f3 = (p.nTag[1] + p.nUn[1]) > 0 ? 100.0 * p.nTag[1] / (p.nTag[1] + p.nUn[1]) : 0, f20 = (p.nTag[2] + p.nUn[2]) > 0 ? 100.0 * p.nTag[2] / (p.nTag[2] + p.nUn[2]) : 0;
   lg->AddEntry((TObject *)nullptr, Form("tagged fraction : > 3000 NPE %.1f %%,  > 20000 NPE %.1f %%", f3, f20), "");
   lg->AddEntry((TObject *)nullptr, logMode ? "dotted : 3000 / 7265 (= 12 MeV) / 20000 NPE (shower threshold)" : "dotted : 3000 / 7265 (= 12 MeV) / 20000 NPE.  bins below 5000 NPE (#gamma) clipped at the top", "");
   lg->Draw();
   pb->cd();
   TH1D *num = (TH1D *)(logMode ? p.tag : p.tagL)->Clone("num"), *den = (TH1D *)(logMode ? p.tag : p.tagL)->Clone("den"); den->Add(logMode ? p.un : p.unL); num->SetDirectory(nullptr); den->SetDirectory(nullptr);
   TGraphAsymmErrors *fr = new TGraphAsymmErrors(); fr->Divide(num, den, "cl=0.683 b(1,1) mode");
   TH1D *fa = logMode ? new TH1D(Form("fa_%s", p.key.c_str()), ";Target NPE (two-PMT sum, 1 #mus window);tagged fraction", kNb, s->GetXaxis()->GetXbins()->GetArray())
                      : new TH1D(Form("fa_%s", p.key.c_str()), ";Target NPE (two-PMT sum, 1 #mus window);tagged fraction", kNbL, kLoL, kHiL); fa->SetDirectory(nullptr);
   fa->SetStats(0); fa->SetMinimum(0); fa->SetMaximum(1.05); fa->GetXaxis()->SetTitleSize(0.10); fa->GetXaxis()->SetLabelSize(0.08); fa->GetXaxis()->SetTitleOffset(1.1);
   fa->GetYaxis()->SetTitleSize(0.09); fa->GetYaxis()->SetLabelSize(0.08); fa->GetYaxis()->SetTitleOffset(0.45); fa->GetYaxis()->SetNdivisions(505);
   fa->Draw(); fr->SetMarkerStyle(20); fr->SetMarkerSize(0.8); fr->SetLineColor(kRed + 1); fr->SetMarkerColor(kRed + 1); fr->Draw("P SAME");
   for (double x : {3000.0, 7265.0, 20000.0}) { TLine *l = new TLine(x, 0, x, 1.05); l->SetLineStyle(3); l->SetLineColor(kGray + 2); l->Draw(); }
   c->Print(dir + Form("muspec_%s_%s%s.png", p.kind.c_str(), p.key.c_str(), logMode ? "_log" : ""));
   delete c;
}

void DrawOverlay(const TString &dir, std::vector<const Per *> ps, const char *kind, const char *dstSub, bool logMode) {
   if (ps.empty()) return;
   std::sort(ps.begin(), ps.end(), [](const Per *a, const Per *b) { return a->key < b->key; });
   const int cols[] = {kRed + 1, kBlue + 1, kGreen + 2, kMagenta + 1, kOrange + 7, kCyan + 2, kGray + 2, kViolet, kSpring - 6, kAzure + 7, kPink + 2, kTeal - 6};
   TCanvas *c = new TCanvas(Form("c_ov_%s", kind), "", 1400, 950);
   TPad *pt = new TPad("pt", "", 0, 0.5, 1, 1), *pb = new TPad("pb", "", 0, 0, 1, 0.5);
   for (TPad *p : {pt, pb}) { p->SetLeftMargin(0.09); p->SetRightMargin(0.03); p->SetGridx(); p->SetGridy(); if (logMode) p->SetLogx(); }
   pt->SetBottomMargin(0.02); pb->SetTopMargin(0.03); pb->SetBottomMargin(0.22); if (logMode) pt->SetLogy(); pt->Draw(); pb->Draw();
   TLegend *lg = logMode ? new TLegend(0.10, 0.04, 0.62, 0.04 + 0.055 * std::min<size_t>(ps.size(), 12)) : new TLegend(0.40, 0.89 - 0.055 * std::min<size_t>(ps.size(), 12), 0.97, 0.89); lg->SetBorderSize(0); lg->SetFillStyle(1001); lg->SetFillColor(kWhite); lg->SetTextSize(0.028);
   int i = 0; double ymax = 0;
   std::vector<TH1D *> tots; std::vector<TGraphAsymmErrors *> frs;
   for (const Per *p : ps) {
      double days = p->live / 86400.0; if (days <= 0) continue;
      TH1D *s = (TH1D *)(logMode ? p->tag : p->tagL)->Clone(Form("ov_s_%s", p->key.c_str())); s->Add(logMode ? p->un : p->unL); s->Scale(1.0 / days); s->SetDirectory(nullptr);
      s->SetLineColor(cols[i % 12]); s->SetLineWidth(2); tots.push_back(s);
      if (logMode) ymax = std::max(ymax, s->GetMaximum()); else for (int b = s->FindBin(5000); b <= s->GetNbinsX(); ++b) ymax = std::max(ymax, s->GetBinContent(b));
      TH1D *num = (TH1D *)(logMode ? p->tag : p->tagL)->Clone("n"), *den = (TH1D *)(logMode ? p->tag : p->tagL)->Clone("d"); den->Add(logMode ? p->un : p->unL);
      TGraphAsymmErrors *fr = new TGraphAsymmErrors(); fr->Divide(num, den, "cl=0.683 b(1,1) mode"); fr->SetLineColor(cols[i % 12]); fr->SetMarkerColor(cols[i % 12]); fr->SetMarkerStyle(20); fr->SetMarkerSize(0.7); frs.push_back(fr);
      double f3 = (p->nTag[1] + p->nUn[1]) > 0 ? 100.0 * p->nTag[1] / (p->nTag[1] + p->nUn[1]) : 0, f20 = (p->nTag[2] + p->nUn[2]) > 0 ? 100.0 * p->nTag[2] / (p->nTag[2] + p->nUn[2]) : 0;
      lg->AddEntry(s, Form("%s : %.1f d, >3k %.0f/day, tagged %.0f %% (>3k) / %.0f %% (>20k)", p->key.c_str(), days, (p->nTag[1] + p->nUn[1]) / days, f3, f20), "l");
      i++;
   }
   pt->cd();
   for (size_t k = 0; k < tots.size(); ++k) {
      if (k == 0) { tots[k]->SetTitle(Form("Target muon spectrum per %s (tagged + untagged, per live day) and tagged fraction  [%s]", kind, dstSub)); tots[k]->SetStats(0); tots[k]->GetYaxis()->SetTitle("Events / day / bin"); tots[k]->GetXaxis()->SetLabelSize(0); if (logMode) { tots[k]->SetMaximum(ymax * 3); tots[k]->SetMinimum(1.0); } else { tots[k]->SetMaximum(ymax * 1.45 + 1); tots[k]->SetMinimum(0); } tots[k]->Draw("HIST"); }
      else tots[k]->Draw("HIST SAME");
   }
   lg->Draw();
   pb->cd();
   TH1D *fa = logMode ? new TH1D(Form("fa_ov_%s", kind), ";Target NPE (two-PMT sum, 1 #mus window);tagged fraction", kNb, ps[0]->tag->GetXaxis()->GetXbins()->GetArray())
                      : new TH1D(Form("fa_ov_%s", kind), ";Target NPE (two-PMT sum, 1 #mus window);tagged fraction", kNbL, kLoL, kHiL); fa->SetDirectory(nullptr);
   fa->SetStats(0); fa->SetMinimum(0); fa->SetMaximum(1.05); fa->GetXaxis()->SetTitleSize(0.07); fa->GetXaxis()->SetLabelSize(0.06); fa->GetYaxis()->SetTitleSize(0.07); fa->GetYaxis()->SetLabelSize(0.06); fa->GetYaxis()->SetTitleOffset(0.6);
   fa->Draw(); for (auto *fr : frs) fr->Draw("PL SAME");
   for (double x : {3000.0, 7265.0, 20000.0}) { TLine *l = new TLine(x, 0, x, 1.05); l->SetLineStyle(3); l->SetLineColor(kGray + 2); l->Draw(); }
   c->Print(dir + Form("muspec_overlay_%ss%s.png", kind, logMode ? "_log" : ""));
   delete c;
}

//  ---- 사용자가 보려는 그림 (2026-09-18 두 번째 지시) : 한 캔버스에 'veto 컷 전(태그 무관 전체)' 과 'veto 컷 뒤(태그 안 된 것만)' 스펙트럼을 같이.
//       기간 하나(all/month/week/run)씩 : muspec_cut_<kind>_<key>[_log].png.  월·주 겹침 : muspec_cut_overlay_{months,weeks}[_log].png (실선 = 컷 전, 점선 = 컷 뒤, 색 = 기간)
void DrawCut(const TString &dir, std::vector<const Per *> ps, const char *kind, const char *tagfile, const char *dstSub, bool logMode) {
   if (ps.empty()) return;
   std::sort(ps.begin(), ps.end(), [](const Per *a, const Per *b) { return a->key < b->key; });
   const int cols[] = {kRed + 1, kBlue + 1, kGreen + 2, kMagenta + 1, kOrange + 7, kCyan + 2, kGray + 2, kViolet, kSpring - 6, kAzure + 7, kPink + 2, kTeal - 6};
   TCanvas *c = new TCanvas(Form("c_cut_%s_%s_%d", kind, tagfile, (int)logMode), "", 1400, 850);
   c->SetLeftMargin(0.08); c->SetRightMargin(0.03); c->SetBottomMargin(0.11); c->SetGridx(); c->SetGridy(); if (logMode) { c->SetLogx(); c->SetLogy(); }
   const size_t n = ps.size();
   const double lh = 0.042 * std::min<size_t>(n, 12) + 0.045;
   TLegend *lg = logMode ? new TLegend(0.10, 0.12, 0.66, 0.12 + lh) : new TLegend(0.36, 0.89 - lh, 0.97, 0.89);
   lg->SetBorderSize(0); lg->SetFillStyle(1001); lg->SetFillColor(kWhite); lg->SetTextSize(n > 6 ? 0.020 : 0.024);
   std::vector<TH1D *> hs; double ymax = 0;
   for (size_t i = 0; i < n; ++i) {
      const Per *p = ps[i]; double days = p->live / 86400.0; if (days <= 0) continue;
      TH1D *all = (TH1D *)(logMode ? p->tag : p->tagL)->Clone(Form("cut_all_%s_%d", p->key.c_str(), (int)logMode)); all->Add(logMode ? p->un : p->unL); all->Scale(1.0 / days); all->SetDirectory(nullptr);
      TH1D *cut = (TH1D *)(logMode ? p->un : p->unL)->Clone(Form("cut_un_%s_%d", p->key.c_str(), (int)logMode)); cut->Scale(1.0 / days); cut->SetDirectory(nullptr);
      int col = n == 1 ? kBlack : cols[i % 12];
      all->SetLineColor(col); all->SetLineWidth(2); all->SetLineStyle(1);
      cut->SetLineColor(n == 1 ? kBlue + 1 : col); cut->SetLineWidth(2); cut->SetLineStyle(n == 1 ? 1 : 2);
      if (n == 1) { cut->SetFillColorAlpha(kBlue + 1, 0.15); cut->SetFillStyle(1001); }
      if (logMode) ymax = std::max(ymax, all->GetMaximum()); else for (int b = all->FindBin(5000); b <= all->GetNbinsX(); ++b) ymax = std::max(ymax, all->GetBinContent(b));
      hs.push_back(all); hs.push_back(cut);
      double s3 = (p->nTag[1] + p->nUn[1]) > 0 ? 100.0 * p->nUn[1] / (p->nTag[1] + p->nUn[1]) : 0, s20 = (p->nTag[2] + p->nUn[2]) > 0 ? 100.0 * p->nUn[2] / (p->nTag[2] + p->nUn[2]) : 0;
      lg->AddEntry(all, Form("%s  no cut : >3k %.3g/d, >20k %.3g/d  (%.1f live d)", p->key.c_str(), (p->nTag[1] + p->nUn[1]) / days, (p->nTag[2] + p->nUn[2]) / days, days), "l");
      lg->AddEntry(cut, Form("%s  after veto cut : >3k %.3g/d (%.0f %% left), >20k %.3g/d (%.0f %% left)", p->key.c_str(), p->nUn[1] / days, s3, p->nUn[2] / days, s20), n == 1 ? "f" : "l");
   }
   if (hs.empty()) { delete c; return; }
   TH1D *fr = hs[0];
   fr->SetTitle(Form("Target muon spectrum before / after the veto cut, per %s  [%s%s]%s;Target NPE (two-PMT sum, 1 #mus window);Events / day / bin", kind, dstSub,
                     std::string(dstSub) == "dst" ? " = panel AND veto" : " = strong veto (any PMT or S_ADC>50)", logMode ? "" : "   (bins below 5000 NPE clipped)"));
   fr->SetStats(0); fr->GetXaxis()->SetTitleSize(0.04); fr->GetYaxis()->SetTitleSize(0.04); fr->GetYaxis()->SetTitleOffset(1.0);
   if (logMode) { fr->SetMaximum(ymax * 3); fr->SetMinimum(1.0); } else { fr->SetMaximum(ymax * 1.5 + 1); fr->SetMinimum(0); }
   fr->Draw("HIST"); for (size_t k = 1; k < hs.size(); ++k) hs[k]->Draw("HIST SAME");
   for (double x : {3000.0, 7265.0, 20000.0}) { TLine *l = new TLine(x, logMode ? 1.0 : 0, x, logMode ? ymax * 3 : ymax * 1.5 + 1); l->SetLineStyle(3); l->SetLineColor(kGray + 2); l->Draw(); }
   lg->AddEntry((TObject *)nullptr, n == 1 ? "black = no veto cut, blue filled = left after the cut.  dotted lines : 3000 / 7265 (12 MeV) / 20000 NPE" : "solid = no veto cut, dashed = after the cut (same colour = same period).  dotted : 3k / 7265 / 20k NPE", "");
   lg->Draw();
   c->Print(dir + Form("muspec_cut_%s%s.png", tagfile, logMode ? "_log" : ""));
   delete c;
}
}  // namespace

void MuonSpec(const char *outDir = "/scratch/RunSummary/", const char *dstSub = "dst", int minRun = 4237, int maxRun = 4348) {
   gStyle->SetOptStat(0);
   TString out(outDir); if (!out.EndsWith("/")) out += "/";
   TString dir = out + Form("muspec/%s/", dstSub); gSystem->mkdir(dir, kTRUE);
   auto meta = LoadMeta(out + "run_summary.tsv");
   double edges[kNb + 1]; LogBins(edges);
   std::map<std::string, Per> per;
   int nRun = 0;
   for (auto &kv : meta) {
      const Meta &m = kv.second;
      if (m.run < minRun || m.run > maxRun || m.es <= 0 || m.nsub <= 0) continue;
      TString dst = out + Form("%s/DST_%06d.root", dstSub, m.run);
      if (gSystem->AccessPathName(dst)) continue;
      TFile *f = TFile::Open(dst, "READ"); if (!f || f->IsZombie()) { if (f) f->Close(); continue; }
      TTree *tI = (TTree *)f->Get("T_Info"); int nsub = 0; double live = 0; tI->SetBranchAddress("n_subrun", &nsub); tI->SetBranchAddress("live_s", &live); tI->GetEntry(0);
      if (nsub <= 0 || live <= 0) { f->Close(); continue; }
      const double subLen = (m.span > 0 ? m.span : m.live) / m.nsub, liveSub = live / nsub;
      //  서브런 → 기간 키 넷 (all · month · week · run) 과 라이브타임
      std::vector<std::array<Per *, 4>> subPer(nsub);
      for (int s = 0; s < nsub; ++s) {
         double mid = m.es + (s + 0.5) * subLen;
         std::array<std::string, 4> keys = {"all", Fmt(mid, "%Y-%m"), Fmt(mid, "%G-W%V"), Form("%06d", m.run)};
         const char *kinds[4] = {"all", "month", "week", "run"};
         for (int k = 0; k < 4; ++k) { Per &p = Get(per, keys[k], kinds[k], edges); p.live += liveSub; p.runs.insert(m.run); p.tmin = std::min(p.tmin, mid - subLen / 2); p.tmax = std::max(p.tmax, mid + subLen / 2); subPer[s][k] = &p; }
      }
      auto fill = [&](TTree *t, bool tagged, bool needPos) {
         if (!t) return 0LL;
         t->SetBranchStatus("*", 0); t->SetBranchStatus("sub_id", 1); t->SetBranchStatus("pe", 1);
         Int_t sub = 0; Float_t pe = 0; t->SetBranchAddress("sub_id", &sub); t->SetBranchAddress("pe", &pe);
         Long64_t n = t->GetEntries(), used = 0;
         for (Long64_t i = 0; i < n; ++i) {
            t->GetEntry(i);
            if (needPos && pe <= 0) continue;
            if (pe <= kLo) continue;                      // 두 표본을 같은 문턱(single 문턱 610.6 NPE 바로 위)에서 비교한다
            if (sub < 0 || sub >= nsub) continue;
            for (Per *p : subPer[sub]) { (tagged ? p->tag : p->un)->Fill(pe); (tagged ? p->tagL : p->unL)->Fill(std::min<double>(pe, kHiL - 1)); Count(tagged ? p->nTag : p->nUn, pe); }
            used++;
         }
         return used;
      };
      long long a = fill((TTree *)f->Get("T_Muons"), true, true), b = fill((TTree *)f->Get("T_Sat"), false, false), c = fill((TTree *)f->Get("T_Singles"), false, false);
      printf("  [RUN ] %06d : tagged %lld  untagged sat %lld + singles %lld  live %.0f s  (%s)\n", m.run, a, b, c, live, Fmt(m.es, "%Y-%m-%d").c_str());
      f->Close(); nRun++;
   }
   if (nRun == 0) { printf("[FATAL] DST 가 없다 (%s%s/, run %d-%d)\n", out.Data(), dstSub, minRun, maxRun); return; }
   //  ---- 그림 ----
   std::vector<const Per *> months, weeks, runs;
   for (auto &kv : per) { DrawOne(dir, kv.second, dstSub, false); DrawOne(dir, kv.second, dstSub, true); if (kv.second.kind == "month") months.push_back(&kv.second); else if (kv.second.kind == "week") weeks.push_back(&kv.second); else if (kv.second.kind == "run") runs.push_back(&kv.second); }
   for (bool lg : {false, true}) {
      DrawOverlay(dir, months, "month", dstSub, lg); DrawOverlay(dir, weeks, "week", dstSub, lg);
      DrawCut(dir, months, "month", "overlay_months", dstSub, lg); DrawCut(dir, weeks, "week", "overlay_weeks", dstSub, lg);
      for (auto &kv : per) DrawCut(dir, {&kv.second}, kv.second.kind.c_str(), Form("%s_%s", kv.second.kind.c_str(), kv.second.key.c_str()), dstSub, lg);
   }
   //  주별 · 런별 태그 비율 추이
   {
      TrendSeries w3, w20, r3, r20;
      w3.label = "weekly, > 3000 NPE"; w20.label = "weekly, > 20000 NPE"; r3.label = "per run, > 3000 NPE"; r20.label = "per run, > 20000 NPE";
      w3.color = kRed + 1; w20.color = kBlue + 1; r3.color = kRed - 7; r20.color = kBlue - 7; w3.marker = 21; w20.marker = 21; r3.marker = 24; r20.marker = 24;
      auto add = [](TrendSeries &s, const Per *p, int k) { double n = p->nTag[k] + p->nUn[k]; if (n > 0) { double f = p->nTag[k] / n; s.add((p->tmin + p->tmax) / 2, 100 * f, 100 * std::sqrt(f * (1 - f) / n)); } };
      for (const Per *p : weeks) { add(w3, p, 1); add(w20, p, 2); }
      for (const Per *p : runs) { add(r3, p, 1); add(r20, p, 2); }
      std::vector<TrendSeries> v{r3, r20, w3, w20}; TrendPageOpt o; o.logInset = false; std::map<int, double> ep; for (auto &kv : meta) ep[kv.second.run] = kv.second.es; o.markers = ReneLoadThrMarkers(out, ep, minRun);
      TString nopdf = "";
      DrawTrendPage(nopdf, dir, "muspec_trend", Form("Veto-tagged fraction of target muons vs time  [%s]  (dotted : SADC threshold changes)", dstSub), "tagged fraction [%]", v, "", o);
   }
   //  ---- 표 · ROOT ----
   std::ofstream o((dir + "muspec_summary.tsv").Data());
   o << "# MuonSpec.C  " << dstSub << "  run " << minRun << "-" << maxRun << ".  tagged = T_Muons pe>0, untagged = T_Sat + T_Singles, both pe > 610 NPE\n"
        "#kind\tkey\tlive_days\tn_runs\ttag_610\tun_610\ttag_3k\tun_3k\ttag_20k\tun_20k\tfrac_3k\tfrac_20k\ttag_per_day_3k\tun_per_day_3k\n";
   TFile *fo = TFile::Open(dir + "muspec.root", "RECREATE");
   for (auto &kv : per) {
      const Per &p = kv.second; double d = p.live / 86400.0;
      double f3 = (p.nTag[1] + p.nUn[1]) > 0 ? (double)p.nTag[1] / (p.nTag[1] + p.nUn[1]) : 0, f20 = (p.nTag[2] + p.nUn[2]) > 0 ? (double)p.nTag[2] / (p.nTag[2] + p.nUn[2]) : 0;
      o << p.kind << '\t' << p.key << '\t' << Form("%.3f", d) << '\t' << p.runs.size() << '\t' << p.nTag[0] << '\t' << p.nUn[0] << '\t' << p.nTag[1] << '\t' << p.nUn[1] << '\t'
        << p.nTag[2] << '\t' << p.nUn[2] << '\t' << Form("%.4f", f3) << '\t' << Form("%.4f", f20) << '\t' << Form("%.1f", d > 0 ? p.nTag[1] / d : 0) << '\t' << Form("%.1f", d > 0 ? p.nUn[1] / d : 0) << '\n';
      for (TH1D *h : {p.tag, p.un, p.tagL, p.unL}) { h->SetDirectory(fo); h->Write(); }
      if (p.kind == "all" || p.kind == "month")
         printf("[MUSP] %-5s %-8s : %.2f d  >3k tagged %lld / untagged %lld (%.1f %%)   >20k %lld / %lld (%.1f %%)\n", p.kind.c_str(), p.key.c_str(), d, p.nTag[1], p.nUn[1], 100 * f3, p.nTag[2], p.nUn[2], 100 * f20);
   }
   fo->Close();
   printf("[SAVED] %s  (%zu periods : all 1, months %zu, weeks %zu, runs %zu)\n", dir.Data(), per.size(), months.size(), weeks.size(), runs.size());
}
