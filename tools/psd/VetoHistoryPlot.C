//  VetoHistoryPlot.C — VETO 패널 반응·계수율 추이 그림 (veto_history.tsv / veto_summary.tsv 를 읽는다)
//
//    2026-09-14 : tools/monitor/ReneTrendPlot.h 의 공통 그리기로 옮겼다 — 선형축, 범례는 빈 구석에,
//    파일 이름은 웹 순서대로 29~31 (rate 01~17 · bg 18~28 뒤).
//      29_veto_rate.png          VETO-tagged 사건율 [Hz]
//      30_veto_panels.png        살아 있는 패널의 AND 반응 비율 [%]
//      31_veto_panel1_pmts.png   패널 1 의 두 PMT (ch2·ch3) 와 AND
#include <TStyle.h>
#include "../monitor/ReneTrendPlot.h"
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

void VetoHistoryPlot(const char *tsv = "/scratch/RunSummary/psd/veto_history.tsv", const char *out = "/scratch/RunSummary/psd/") {
   gStyle->SetOptStat(0); gStyle->SetTimeOffset(0);
   std::ifstream in(tsv); std::string l; std::vector<std::vector<double>> R;
   while (std::getline(in, l)) {
      if (l.empty() || l[0] == '#') continue;
      std::stringstream ss(l); std::vector<double> v; std::string f; int k = 0;
      while (std::getline(ss, f, '\t')) { if (k == 2) { k++; continue; } v.push_back(atof(f.c_str())); k++; }
      R.push_back(v);
   }
   // columns after dropping date: 0 run 1 epoch 2 n_sub 3 fadc 4 veto 5 thr2 6 thr3 7 thr9 8 ch2 9 ch3 10.. panel0..14
   // 살아 있는 패널(어느 런에서든 1 % 이상)만 그린다 -- 2026-09-09 문턱 변경으로 5·12 가 살아나고 11 이 죽었다.
   std::vector<int> pan;
   for (int q = 0; q < 15; q++) {
      double mx = 0;
      for (auto &v : R) if (v.size() > (size_t)(10 + q) && v[0] >= 4280 && v[10 + q] > mx) mx = v[10 + q];
      if (mx >= 1.0) pan.push_back(q);
   }
   if (pan.empty()) pan = {0, 1, 2, 3, 8, 11};
   const int col[8] = {kRed + 1, kBlue + 1, kGreen + 2, kMagenta + 1, kOrange + 7, kCyan + 2, kViolet + 1, kGray + 2};
   const int mst[3] = {20, 21, 22};
   auto mk = [&](int c, double lo, const char *label, int k) {
      TrendSeries s; s.label = label; s.color = col[k % 8]; s.marker = mst[(k / 8) % 3];
      std::vector<std::pair<double, double>> pts;
      for (auto &v : R) if (v.size() > (size_t)c && v[0] >= lo) pts.push_back({v[1], v[c]});
      std::sort(pts.begin(), pts.end());
      for (auto &p : pts) s.add(p.first, p.second, 0);
      return s;
   };
   TString od(out); if (!od.EndsWith("/")) od += "/";
   TrendPageOpt o; o.timeFmt = "%m/%d"; o.width = 1300; o.height = 600;
   {  //  문턱 변경 표식 : 이 표의 run -> epoch 로 (thr_by_run.tsv 는 od 의 부모 psd/ 에 있을 수도, od 자체에 있을 수도 있다)
      std::map<int, double> ep; for (auto &v : R) if (v.size() > 1) ep[(int)v[0]] = v[1];
      TString parent = od; parent.Remove(parent.Length() - 1); parent = parent(0, parent.Last('/') + 1);   // <out>/psd/ -> <out>/
      o.markers = ReneLoadThrMarkers(parent, ep, 4280);
      if (o.markers.empty()) { TString pp = parent; pp.Remove(pp.Length() - 1); pp = pp(0, pp.Last('/') + 1); o.markers = ReneLoadThrMarkers(pp, ep, 4280); }
   }

   std::vector<TrendSeries> P;
   for (size_t i = 0; i < pan.size(); i++) P.push_back(mk(10 + pan[i], 4280, Form("panel %d", pan[i]), (int)i));
   std::vector<TrendSeries> V{mk(4, 4280, "veto (any panel AND)", 0)};
   std::vector<TrendSeries> Q{mk(8, 4280, "ch2", 0), mk(9, 4280, "ch3", 1), mk(11, 4280, "panel 1 AND", 2)};
   DrawTrendPage("", od, "29_veto_rate", "VETO-tagged event rate per run", "rate [Hz]", V, "", o);
   DrawTrendPage("", od, "30_veto_panels", "VETO panel AND fraction per run (subrun-averaged, runs >= 4280)", "fraction of events [%]", P, "", o);
   DrawTrendPage("", od, "31_veto_panel1_pmts", "Panel 1 PMTs (ch2, ch3) trigger fraction per run", "fraction [%]", Q, "", o);
   printf("[SAVED] %s29..31_veto_*.png\n", od.Data());
}
