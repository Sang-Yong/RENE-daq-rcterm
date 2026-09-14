// ---------------------------------------------------------------------------
//  BuildBgTrend.C - 배경 지표(metrics_summary.tsv, schema 2)의 시간축 추이.
//                   런마다 점 하나, x축은 그 런의 DAQ 시작 시각.
//
//  읽는 것 : <OutDir>/metrics_summary.tsv   (BuildMetrics.C, # schema 2)
//            <OutDir>/run_summary.tsv       epoch_start(x축)
//  쓰는 것 : <OutDir>/bg_trend.pdf          여러 쪽
//            <OutDir>/NN_bg_<이름>_<채널>.png   쪽마다 하나, 번호순 (18~28)
//
//  쪽                       무엇
//   accidental   off-window(창 배율 보정) 대 rate-곱 R_S1·R_S2·T -- 둘이 같은 양이라
//                나란히 놓으면 방법 자체가 검증된다 (RENE PTEP 2025 §2)
//   fastn        사이드밴드 외삽 fast-n [/day]. 오차막대 = |0차−1차| (계통)
//   lihe         Li/He 적합 [/day] (lihe_stat=ok 만) + 시간 역방향 대조(빈 표식)
//   psd          1-3 MeV single 꼬리비율 γ-band 평균 (오차막대 = RMS) -- 파형 안정성
//   psd_nlike    IBD 후보 prompt 중 n-like 비율 [%]
//   multrej      multiplicity 가 걸러낸 쌍의 우발 초과분 [/day] (다중 중성자 지표)
//
//  열은 헤더 줄(#run\ttag...)의 이름으로 찾는다 -- 열이 더 붙어도 깨지지 않고,
//  이름이 없으면 그 쪽만 비운다. 선원 런(src 가 none/? 가 아닌 것)은 뺀다 --
//  AmBe 의 중성자가 배경 추이를 통째로 가린다.
// ---------------------------------------------------------------------------
#include <TAxis.h>
#include <TCanvas.h>
#include <TGraphErrors.h>
#include <TLegend.h>
#include <TMultiGraph.h>
#include <TStyle.h>
#include <TString.h>

#include <cmath>
#include <cstdio>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "ReneTrendPlot.h"      // 채널별 쪽 · 선형축 + 로그 inset · 번호 붙은 파일 이름 (2026-09-14)


static std::map<std::string, int> ReadHeader(const std::string &line) {
   std::map<std::string, int> idx;
   std::string h = line.substr(1);           // '#' 뗀다
   std::stringstream ss(h); std::string col; int i = 0;
   while (std::getline(ss, col, '\t')) idx[col] = i++;
   return idx;
}

using BgSeries = TrendSeries;

void BuildBgTrend(const char *outDir = "/scratch/RunSummary/") {
   gStyle->SetOptStat(0);
   gStyle->SetTimeOffset(0);
   TString out = outDir; if (!out.EndsWith("/")) out += "/";

   //  ---- run_summary : run -> epoch_start ----
   std::map<int, double> epoch;
   {
      std::ifstream in((out + "run_summary.tsv").Data());
      std::string line;
      while (std::getline(in, line)) {
         if (line.empty() || line[0] == '#') continue;
         std::stringstream ss(line); int run; double a, b, c, ep;
         if (ss >> run >> a >> b >> ep) epoch[run] = ep;
      }
   }
   //  ---- metrics_summary : 이름으로 열을 찾는다 ----
   std::map<std::string, int> col; int schema = 0;
   struct Row { std::vector<std::string> f; };
   std::vector<Row> rows;
   {
      std::ifstream in((out + "metrics_summary.tsv").Data());
      if (!in) { printf("[SKIP] metrics_summary.tsv 가 없다 (%s)\n", out.Data()); return; }
      std::string line;
      while (std::getline(in, line)) {
         if (line.rfind("# schema", 0) == 0) { schema = std::atoi(line.c_str() + 8); continue; }
         if (line.rfind("#run", 0) == 0) { col = ReadHeader(line); continue; }
         if (line.empty() || line[0] == '#') continue;
         Row r; std::stringstream ss(line); std::string f;
         while (std::getline(ss, f, '\t')) r.f.push_back(f);
         rows.push_back(r);
      }
   }
   if (schema < 2 || col.empty()) { printf("[SKIP] metrics_summary.tsv 가 schema 2 가 아니다 (schema %d)\n", schema); return; }
   auto has = [&](const char *k) { return col.count(k) > 0; };
   auto get = [&](const Row &r, const char *k) -> double {
      auto it = col.find(k); if (it == col.end() || it->second >= (int)r.f.size()) return -1;
      return std::atof(r.f[it->second].c_str());
   };
   auto gets = [&](const Row &r, const char *k) -> std::string {
      auto it = col.find(k); if (it == col.end() || it->second >= (int)r.f.size()) return "";
      return r.f[it->second];
   };

   auto mk = [](const char *lab, int col, int mk) { BgSeries s; s.label = lab; s.color = col; s.marker = mk; return s; };
   const int cGd = kRed + 1, cH = kBlue + 1;             // rate 그림과 같은 색 : n-Gd 빨강 · n-H 파랑
   BgSeries accOffGd = mk("off-window", cGd, 20), accRpGd = mk("R_{S1}R_{S2}T", cGd, 24);
   BgSeries accOffH  = mk("off-window", cH, 21),  accRpH  = mk("R_{S1}R_{S2}T", cH, 25);
   BgSeries fnGd = mk("n-Gd", cGd, 20), fnH = mk("n-H", cH, 21);
   BgSeries liGd = mk("n-Gd", cGd, 20), liH = mk("n-H", cH, 21);
   BgSeries liGdR = mk("reversed (control)", cGd, 24), liHR = mk("reversed (control)", cH, 25);
   BgSeries psdM = mk("#gamma-band mean #pm RMS", kBlack, 20);
   BgSeries nlGd = mk("n-Gd", cGd, 20), nlH = mk("n-H", cH, 21);
   BgSeries mrGd = mk("n-Gd", cGd, 20), mrH = mk("n-H", cH, 21);

   int nUsed = 0;
   for (const auto &r : rows) {
      int run = (int)get(r, "run"); std::string tag = gets(r, "tag"), src = gets(r, "src");
      if (!epoch.count(run)) continue;
      if (!(src == "none" || src == "?")) continue;       // 선원 런은 뺀다
      double live = get(r, "live_s"); if (live <= 0) continue;
      double day = live / 86400.0, x = epoch[run];
      bool gd = (tag == "_nGd");
      nUsed++;
      double dtMin = get(r, "dt_min"), dtMax = get(r, "dt_max");
      double sc = dtMax > 0 ? (dtMax - dtMin) / dtMax : 1;
      double nPA = get(r, "n_paired_acci"), rp = get(r, "n_acci_rp");
      if (nPA >= 0) (gd ? accOffGd : accOffH).add(x, sc * nPA / day, sc * std::sqrt(nPA) / day);
      if (rp  >= 0) (gd ? accRpGd  : accRpH ).add(x, rp / day, 0);
      double fs = get(r, "n_fn_side_scaled"), fl = get(r, "n_fn_side_lin");
      if (fs >= 0) (gd ? fnGd : fnH).add(x, fs / day, (fl >= 0 ? std::fabs(fs - fl) : 0) / day);
      if (gets(r, "lihe_stat") == "ok") {
         (gd ? liGd : liH).add(x, get(r, "n_lihe") / day, get(r, "e_lihe") / day);
         double nr = get(r, "n_lihe_rev"), er = get(r, "e_lihe_rev");
         if (er >= 0) (gd ? liGdR : liHR).add(x, nr / day, er / day);
      }
      double pm = get(r, "psd_mean"), pr = get(r, "psd_rms");
      if (gd && pm >= 0) psdM.add(x, pm, pr > 0 ? pr : 0);
      double nl = get(r, "n_ibd_psd_nlike"), ni = get(r, "n_ibd");
      if (nl >= 0 && ni > 0) (gd ? nlGd : nlH).add(x, 100.0 * nl / ni, 100.0 * std::sqrt(nl) / ni);
      double mr = get(r, "n_mult_rej");
      if (has("n_mult_rej") && mr > -1e29) (gd ? mrGd : mrH).add(x, mr / day, 0);
   }
   printf("[INFO] metrics 행 %zu, 선원 없는 런 행 %d\n", rows.size(), nUsed);

   TString pdf = out + "bg_trend.pdf";
   int nPage = 0; bool opened = false;
   std::vector<TrendMarker> thrMarkers = ReneLoadThrMarkers(out, epoch, 4280);
   auto page = [&](const char *file, const char *title, const char *yt, std::vector<BgSeries> ss, bool logInset) {
      TrendPageOpt o; o.logInset = logInset; o.markers = thrMarkers;
      if (DrawTrendPage(pdf, out, file, title, yt, ss, opened ? "" : "(", o)) { opened = true; nPage++; }
   };
   //  ★ 채널은 쪽을 나눈다 (사용자 지시 2026-09-14). 번호는 rate 그림(01~17)에 이어 18 부터.
   page("18_bg_accidental_nGd", "Accidental per day, n-Gd : off-window vs rate product (before multiplicity)",
        "Accidental [/day]", {accOffGd, accRpGd}, true);
   page("19_bg_accidental_nH",  "Accidental per day, n-H : off-window vs rate product (before multiplicity)",
        "Accidental [/day]", {accOffH, accRpH}, true);
   page("20_bg_fastn_nGd", "Fast-neutron estimate per day, n-Gd (sideband extrapolation, T_Sat included)  [preliminary]",
        "fast-n [/day]", {fnGd}, false);
   page("21_bg_fastn_nH",  "Fast-neutron estimate per day, n-H (sideband extrapolation, T_Sat included)  [preliminary]",
        "fast-n [/day]", {fnH}, false);
   page("22_bg_lihe_nGd", "^{9}Li/^{8}He fit per day, n-Gd (Daya Bay Eq.2) vs time-reversed control  [preliminary]",
        "Li/He [/day]", {liGd, liGdR}, false);
   page("23_bg_lihe_nH",  "^{9}Li/^{8}He fit per day, n-H (Daya Bay Eq.2) vs time-reversed control  [preliminary]",
        "Li/He [/day]", {liH, liHR}, false);
   page("24_bg_psd", "PSD tail fraction, 1-3 MeV singles (#gamma-band)  -- pulse-shape stability",
        "tail / total", {psdM}, false);
   page("25_bg_psd_nlike_nGd", "IBD prompts beyond #gamma-band + n#sigma, n-Gd  [preliminary]",
        "n-like fraction [%]", {nlGd}, false);
   page("26_bg_psd_nlike_nH",  "IBD prompts beyond #gamma-band + n#sigma, n-H  [preliminary]",
        "n-like fraction [%]", {nlH}, false);
   page("27_bg_multrej_nGd", "Multiplicity-rejected excess per day, n-Gd (multi-neutron indicator)",
        "excess [/day]", {mrGd}, false);
   page("28_bg_multrej_nH",  "Multiplicity-rejected excess per day, n-H (multi-neutron indicator)",
        "excess [/day]", {mrH}, false);
   if (opened) {
      //  마지막 쪽을 닫는다 -- 빈 캔버스로 ')' 만 찍는다
      TCanvas cEnd("cBgEnd", "", 10, 10); cEnd.Print(pdf + ")");
      printf("[SAVED] %s (%d 쪽) + %s18..28_bg_*.png\n", pdf.Data(), nPage, out.Data());
   } else {
      printf("[INFO] 그릴 행이 없다 (metrics_summary 에 선원 없는 완결 런이 없다)\n");
   }
}
