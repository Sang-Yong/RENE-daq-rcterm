// ---------------------------------------------------------------------------
//  PsdSummary.C - psdana_<run>.root 들에서 위치(선원 높이)별 검출기 응답을 모은다.
//     capture_mev   n-H 포획 γ(2.2 MeV) 봉우리의 재구성 에너지 (on−off 뺀 스펙트럼을 가우스 적합)
//                   현재 에너지 보정 기준 값이라 1 에서 벗어난 만큼이 위치 의존이다
//     ambe_mev      AmBe 4.44 MeV γ 봉우리 (prompt on−off, [3.5,6] 적합) -- AmBe 런만
//     mt_gam        포획 γ 의 평균시각 [샘플]   (펄스 모양의 위치 의존)
//  입력 : runpos.tsv (run\tpos\tsource), psdana_*.root    출력 : psd_summary.tsv + PNG 3장
// ---------------------------------------------------------------------------
#include <TFile.h>
#include <TH1D.h>
#include <TF1.h>
#include <TGraph.h>
#include <TGraphErrors.h>
#include <TMultiGraph.h>
#include <TCanvas.h>
#include <TLegend.h>
#include <TStyle.h>
#include <TSystem.h>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>
#include <cstdio>

static bool FitPeak(TH1D *h, double lo, double hi, double &mu, double &sig, double &emu) {
   if (!h || h->Integral() < 50) return false;
   h->GetXaxis()->SetRangeUser(lo, hi);
   double x0 = h->GetBinCenter(h->GetMaximumBin());
   double hw = (hi - lo > 2.0) ? 0.9 : 0.35;      // n-Gd 봉우리는 넓다
   TF1 f("fp", "gaus", x0 - hw, x0 + hw);
   f.SetParameters(h->GetMaximum(), x0, hw / 2.5);
   if (h->Fit(&f, "QRN0") != 0) return false;
   mu = f.GetParameter(1); sig = f.GetParameter(2); emu = f.GetParError(1);
   h->GetXaxis()->SetRange(0, 0);
   return sig > 0.02 && sig < 1.5;
}

//  mode "nH" : runpos.tsv + psdana_<run>.root, 포획 봉우리 2.2 MeV 를 [1.5,3.2] 에서 적합
//  mode "nGd": runpos_gd.tsv + psdana_<run>_nGd.root, 포획 봉우리(n-Gd ~8 MeV) 를 [6,10] 에서 적합
void PsdSummary(const char *dir = "/scratch/RunSummary/psd/", const char *mode = "nH") {
   const bool gd = (TString(mode) == "nGd");
   gStyle->SetOptStat(0);
   TString d = dir; if (!d.EndsWith("/")) d += "/";
   std::ifstream in((d + (gd ? "runpos_gd.tsv" : "runpos.tsv")).Data());
   std::string line;
   std::ofstream out((d + (gd ? "psd_summary_gd.tsv" : "psd_summary.tsv")).Data());
   out << "#run\tpos_mm\tsource\tcapture_mev\tcapture_sig\tcapture_err\tambe_mev\tambe_sig\tmt_gam\tmt_gam_rms\n";
   TGraphErrors gCapA, gCapC, gAmbe; TGraph gMtA, gMtC;
   while (std::getline(in, line)) {
      if (line.empty() || line[0] == '#') continue;
      std::stringstream ss(line); int run, pos; std::string src;
      if (!(ss >> run >> pos >> src)) continue;
      TFile f(d + TString::Format("psdana_%06d%s.root", run, gd ? "_nGd" : ""));
      if (f.IsZombie()) continue;
      TH1D *cap = (TH1D *)f.Get("e_cap"), *capOff = (TH1D *)f.Get("e_capoff");
      TH1D *eOn = (TH1D *)f.Get("e_on"), *eOff = (TH1D *)f.Get("e_off");
      TH1D *gm = (TH1D *)f.Get("gon_mt"), *gmo = (TH1D *)f.Get("goff_mt");
      if (!cap || !capOff || !eOn || !eOff || !gm || !gmo) continue;
      TH1D *c = (TH1D *)cap->Clone("csub"); c->Add(capOff, -1);
      TH1D *e = (TH1D *)eOn->Clone("esub");  e->Add(eOff, -1);
      TH1D *m = (TH1D *)gm->Clone("msub");   m->Add(gmo, -1);
      double cmu = -1, csig = -1, cerr = -1, amu = -1, asig = -1, aerr = -1;
      bool okC = FitPeak(c, 1.5, 3.2, cmu, csig, cerr);
      bool okA = (src == "AmBe") && FitPeak(e, 3.5, 6.0, amu, asig, aerr);
      double mtm = m->GetMean(), mtr = m->GetRMS();
      out << run << '\t' << pos << '\t' << src << '\t' << (okC ? cmu : -1) << '\t' << (okC ? csig : -1) << '\t' << (okC ? cerr : -1)
          << '\t' << (okA ? amu : -1) << '\t' << (okA ? asig : -1) << '\t' << mtm << '\t' << mtr << '\n';
      printf("run %d pos %4d %-5s  capture %.3f±%.3f (σ %.3f)  ambe %.3f  mt_γ %.2f±%.2f\n", run, pos, src.c_str(), cmu, cerr, csig, amu, mtm, mtr);
      if (pos < 0) continue;
      if (okC) { TGraphErrors &g = (src == "AmBe") ? gCapA : gCapC; int k = g.GetN(); g.SetPoint(k, pos, cmu); g.SetPointError(k, 0, cerr); }
      if (okA) { int k = gAmbe.GetN(); gAmbe.SetPoint(k, pos, amu); gAmbe.SetPointError(k, 0, aerr); }
      TGraph &gmt = (src == "AmBe") ? gMtA : gMtC; gmt.SetPoint(gmt.GetN(), pos, mtm);
   }
   auto draw = [&](const char *name, const char *title, const char *yt, std::vector<std::pair<TGraph*, const char*>> gs, int col0) {
      TCanvas c(name, title, 1100, 600); c.SetGridx(); c.SetGridy();
      TMultiGraph *mg = new TMultiGraph(); TLegend *leg = new TLegend(0.7, 0.75, 0.93, 0.9); leg->SetBorderSize(0);
      int col[] = {kBlue+1, kRed+1, kGreen+2}; int k = 0;
      for (auto &pg : gs) { if (pg.first->GetN() == 0) { k++; continue; } pg.first->Sort(); pg.first->SetMarkerStyle(20 + k); pg.first->SetMarkerColor(col[k]); pg.first->SetLineColor(col[k]); mg->Add(pg.first, "LP"); leg->AddEntry(pg.first, pg.second, "lp"); k++; }
      mg->SetTitle(Form("%s;source height from chimney top [mm];%s", title, yt)); mg->Draw("A"); leg->Draw();
      c.Print(d + name + (gd ? "_gd" : "") + ".png");
   };
   draw("psd_capture_vs_pos", "n-H capture peak (2.2 MeV) reconstructed energy vs source height", "E_{rec} [MeV]", {{&gCapA, "AmBe"}, {&gCapC, "Cf252"}}, 0);
   draw("psd_ambe_vs_pos", "AmBe 4.44 MeV prompt peak vs source height", "E_{rec} [MeV]", {{&gAmbe, "AmBe"}}, 0);
   draw("psd_mt_vs_pos", "capture-#gamma mean time vs source height", "mean time [samples of 2 ns]", {{&gMtA, "AmBe"}, {&gMtC, "Cf252"}}, 0);
   printf("[SAVED] %spsd_summary.tsv + 3 png\n", d.Data());
}
