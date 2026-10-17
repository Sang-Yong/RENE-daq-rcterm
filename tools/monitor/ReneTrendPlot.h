// ReneTrendPlot.h — 런 서머리 추이 그림의 공통 그리기 (2026-09-14, 사용자 지시)
//
//   * 채널(n-Gd / n-H)은 한 캔버스에 같이 그리지 않는다. 쪽마다 한 채널.
//   * 축은 언제나 선형. 로그 축에서만 보이는 것(값이 한 자릿수 넘게 벌어짐)은 같은 쪽 안에
//     작은 로그축 inset 으로 넣는다 — 범례·점과 겹치지 않는 빈 구석을 골라서.
//   * 파일 이름은 NN_<묶음>_<양>[_<채널>].png 로 번호가 앞에 온다 — 웹에 순서대로 올리기 위해.
//
//   BuildRateTrend.C · BuildBgTrend.C · tools/psd/VetoHistoryPlot.C 가 include 한다.
#ifndef RENE_TREND_PLOT_H
#define RENE_TREND_PLOT_H

#include <TAxis.h>
#include <TCanvas.h>
#include <TLatex.h>
#include <TLine.h>
#include <TVirtualPad.h>
#include <fstream>
#include <map>
#include <sstream>
#include <TGraphErrors.h>
#include <TLegend.h>
#include <TMultiGraph.h>
#include <TPad.h>
#include <TString.h>
#include <TStyle.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <ctime>
#include <string>
#include <vector>

struct TrendSeries {
   std::vector<double> x, y, ey;
   std::string label;
   int color = kBlack, marker = 20;
   void add(double xx, double yy, double e = 0) { x.push_back(xx); y.push_back(yy); ey.push_back(e); }
};

//  x 축에 세울 표식 (예 : veto 문턱값이 바뀐 런). epoch 와 짧은 라벨
struct TrendMarker { double x; std::string label; };

struct TrendPageOpt {
   bool logInset   = false;   // 값이 한 자릿수 넘게 벌어지면 로그축 inset 을 넣는다
   std::vector<TrendMarker> markers;   // 세로 점선 + 라벨 (2026-09-15 : 문턱 변경 런)
   bool legend     = true;    // 계열이 둘 이상이면 범례
   const char *timeFmt = "%y/%m/%d";
   //  x 축 시작 [epoch] (2026-10-18, 사용자 지시 "날짜가 8월 15일부터 시작되게").
   //    -2 = 환경변수 RENE_TREND_XMIN 을 따른다 (기본) · -1 = 끔 (자동 범위) · 그 밖 = 이 epoch 부터.
   //  자료는 버리지 않는다 — 표·누적값은 그대로이고, 축 범위 밖의 점만 그리지 않는다. 축 끝(xmax)은 자동 그대로.
   double xmin = -2;
   int  width = 1400, height = 700;
};

//  "YYYY-MM-DD" 또는 "YYYY-MM-DD HH:MM" -> 지역 시각(사이트 = KST) 의 epoch. 비었거나 못 읽으면 -1.
//  지역 시각으로 읽는 이유 : 날짜별 단계(BuildDaily)의 '하루' 가 지역 자정 기준이고, 운영자가 말하는 날짜도 KST 다.
static double ReneParseXminDate(const char *v) {
   if (!v || !*v) return -1;
   struct tm t = {}; int Y = 0, M = 0, D = 0, h = 0, m = 0;
   int n = sscanf(v, "%d-%d-%d %d:%d", &Y, &M, &D, &h, &m);
   if (n < 3 || Y < 1970 || M < 1 || M > 12 || D < 1 || D > 31) return -1;
   t.tm_year = Y - 1900; t.tm_mon = M - 1; t.tm_mday = D; t.tm_hour = (n >= 4 ? h : 0); t.tm_min = (n >= 5 ? m : 0); t.tm_isdst = -1;
   return (double)mktime(&t);
}
//  opt.xmin 을 실제 값으로 : -2 면 RENE_TREND_XMIN (trend_xmin_date 를 래퍼가 넘긴다), 없으면 -1
static double ReneResolveXmin(double optXmin) {
   if (optXmin != -2) return optXmin;
   return ReneParseXminDate(std::getenv("RENE_TREND_XMIN"));
}

//  네 구석의 '비어 있는 정도'. 점이 적게 든 구석부터 돌려준다 (0 좌하 1 우하 2 좌상 3 우상).
//  선형축 범위 : 값이 전부 0 이상이면 0 부터, 위로 15 % 여유 (DrawTrendPage 가 같은 규칙으로 축을 잡는다)
static void ReneLinearRange(const std::vector<TrendSeries> &ss, double &ylo, double &yhi) {
   ylo = 1e300; yhi = -1e300;
   for (const auto &s : ss) for (size_t i = 0; i < s.y.size(); ++i) {
      double e = s.ey.empty() ? 0 : s.ey[i];
      ylo = std::min(ylo, s.y[i] - e); yhi = std::max(yhi, s.y[i] + e);
   }
   if (ylo >= 0 && yhi > 0) { ylo = 0; yhi *= 1.15; }
}

static std::vector<int> ReneEmptyCorners(const std::vector<TrendSeries> &ss, bool logy = false, double xAxisLo = -1,
                                         double yHiAxis = -1, int *cntOut = nullptr, double yLoAxis = 0, bool yFix = false) {
   double xlo = 1e300, xhi = -1e300, ylo = 1e300, yhi = -1e300;
   for (const auto &s : ss) for (size_t i = 0; i < s.x.size(); ++i) {
      xlo = std::min(xlo, s.x[i]); xhi = std::max(xhi, s.x[i]);
   }
   if (xAxisLo > 0) xlo = xAxisLo;       // 축 시작을 정했으면 그 값이 그려질 왼쪽 끝이다
   ReneLinearRange(ss, ylo, yhi);        // ★ 자료 범위가 아니라 그려질 축 범위로 잰다 (효율 그림에서 범례가 선 위에 앉았다)
   if (yFix) { ylo = yLoAxis; yhi = yHiAxis; }   // 축 범위를 따로 정했으면 그것으로
   int cnt[4] = {0, 0, 0, 0};
   double dx = xhi - xlo, dy = yhi - ylo;
   if (dx <= 0) dx = 1; if (dy <= 0) dy = 1;
   for (const auto &s : ss) for (size_t i = 0; i < s.x.size(); ++i) {
      double y = s.y[i];
      double fx = (s.x[i] - xlo) / dx, fy = (y - ylo) / dy;
      //  inset 은 폭 38 % · 높이 42 % 를 차지한다. 그 상자에 드는 점을 센다
      if (fx < 0.40 && fy < 0.45) cnt[0]++;
      if (fx > 0.60 && fy < 0.45) cnt[1]++;
      if (fx < 0.40 && fy > 0.55) cnt[2]++;
      if (fx > 0.60 && fy > 0.55) cnt[3]++;
   }
   std::vector<int> order = {3, 2, 1, 0};        // 비면 우상 · 좌상 · 우하 · 좌하 순으로 선호
   std::stable_sort(order.begin(), order.end(), [&](int a, int b) { return cnt[a] < cnt[b]; });
   if (cntOut) for (int i = 0; i < 4; ++i) cntOut[i] = cnt[i];
   return order;
}

//  값이 로그축이라야 보이는가 : 양수 값의 최대/최소가 10 배를 넘고 점이 넷 이상
static bool ReneNeedsLog(const std::vector<TrendSeries> &ss) {
   double lo = 1e300, hi = 0; int n = 0;
   for (const auto &s : ss) for (double y : s.y) if (y > 0) { lo = std::min(lo, y); hi = std::max(hi, y); n++; }
   return n >= 4 && lo > 0 && hi / lo > 10.0;
}

static void ReneStyleAxes(TMultiGraph *mg, const char *timeFmt, double tsize, double lsize) {
   TAxis *ax = mg->GetXaxis();
   ax->SetTimeDisplay(1); ax->SetTimeOffset(0, "gmt"); ax->SetTimeFormat(timeFmt);
   ax->SetNdivisions(507);
   ax->SetTitleSize(tsize); ax->SetLabelSize(lsize); ax->SetTitleOffset(1.5); ax->CenterTitle();
   mg->GetYaxis()->SetTitleSize(tsize); mg->GetYaxis()->SetLabelSize(lsize);
   mg->GetYaxis()->SetTitleOffset(1.15); mg->GetYaxis()->CenterTitle();
}

static TMultiGraph *ReneMakeGraphs(const std::vector<TrendSeries> &ss, TLegend *leg, bool &any) {
   TMultiGraph *mg = new TMultiGraph();
   any = false;
   for (const auto &s : ss) {
      if (s.x.empty()) continue;
      TGraphErrors *g = new TGraphErrors((int)s.x.size(), s.x.data(), s.y.data(),
                                         nullptr, s.ey.empty() ? nullptr : s.ey.data());
      g->SetMarkerStyle(s.marker); g->SetMarkerSize(1.1);
      g->SetMarkerColor(s.color);  g->SetLineColor(s.color); g->SetLineWidth(2);
      mg->Add(g, "LP");
      if (leg) leg->AddEntry(g, s.label.c_str(), "lp");
      any = true;
   }
   return mg;
}

//  구석 번호 -> NDC 상자 (x1 y1 x2 y2). 그림 영역은 여백을 뺀 (0.11..0.96, 0.15..0.90)
static void ReneCornerBox(int corner, double w, double h, double &x1, double &y1, double &x2, double &y2) {
   const double L = 0.13, R = 0.95, B = 0.17, T = 0.89;
   x1 = (corner == 1 || corner == 3) ? R - w : L;  x2 = x1 + w;
   y1 = (corner == 2 || corner == 3) ? T - h : B;  y2 = y1 + h;
}

//  veto 문턱값이 바뀐 런의 표식 (2026-09-15, 사용자 지시 "문턱을 바꾼 데이터의 그림을 보자").
//  <OutDir>/psd/thr_by_run.tsv (tools/psd/thr-history.sh) 에서 S_THR 30 개가 직전 행과 다른 런을 찾아, 그 런의 DAQ 시작 시각에
//  'THR 4347' 같은 표식을 세운다. 표가 없으면 빈 목록 (그림은 그대로). epoch 는 run_summary 에서 온 run -> 시작 epoch.
static std::vector<TrendMarker> ReneLoadThrMarkers(const TString &outDir, const std::map<int, double> &epoch, int minRun = 0) {
   std::vector<TrendMarker> mk;
   TString p = outDir; if (!p.EndsWith("/")) p += "/"; p += "psd/thr_by_run.tsv";
   std::ifstream in(p.Data()); if (!in) return mk;
   std::string line, prev; int prevRun = -1;
   std::vector<std::pair<int, std::string>> rows;
   while (std::getline(in, line)) {
      if (line.empty() || line[0] == '#') continue;
      std::vector<std::string> f; std::stringstream ss(line); std::string c;
      while (std::getline(ss, c, '\t')) f.push_back(c);
      if (f.size() < 36 || f[0].empty() || !isdigit(f[0][0])) continue;
      std::string key; for (int i = 6; i < 36; ++i) key += f[i] + " ";
      if (key.find("ERR") != std::string::npos) continue;
      rows.push_back({atoi(f[0].c_str()), key});
   }
   std::sort(rows.begin(), rows.end());
   for (auto &r : rows) {
      if (prevRun >= 0 && r.second != prev && r.first >= minRun) {
         auto ie = epoch.find(r.first);
         if (ie != epoch.end()) mk.push_back({ie->second, "THR " + std::to_string(r.first)});
      }
      prev = r.second; prevRun = r.first;
   }
   return mk;
}

//  표식 그리기 : 축 범위 안의 것만, 세로 점선 + 위쪽 작은 라벨
static void ReneDrawMarkers(TMultiGraph *mg, const std::vector<TrendMarker> &mk) {
   if (mk.empty() || !mg->GetXaxis() || !gPad) return;
   //  TMultiGraph 의 축 객체는 그려진 틀의 범위를 돌려주지 않는다 (SetMinimum/Maximum 뒤에도) -- 패드의 사용자 좌표를 쓴다
   gPad->Update();
   double x1 = gPad->GetUxmin(), x2 = gPad->GetUxmax();
   double y1 = gPad->GetUymin(), y2 = gPad->GetUymax();
   for (const auto &m : mk) {
      if (m.x < x1 || m.x > x2) continue;
      TLine *l = new TLine(m.x, y1, m.x, y2); l->SetLineColor(kGray + 2); l->SetLineStyle(2); l->SetLineWidth(1); l->Draw();
      //  라벨은 축 아래쪽에 세워 쓴다 (위쪽은 inset·범례가 앉는 자리다)
      TLatex *t = new TLatex(m.x, y1 + 0.02 * (y2 - y1), m.label.c_str()); t->SetTextSize(0.022); t->SetTextColor(kGray + 2); t->SetTextAngle(90); t->SetTextAlign(11); t->Draw();
   }
}

//  쪽 하나. 돌려주는 값 : 그렸는가 (계열이 전부 비면 false, 파일도 안 만든다).
//  fileName 은 확장자 없는 이름 (예 "01_rate_candidates_nGd").
static bool DrawTrendPage(const TString &pdf, const TString &pngDir, const char *fileName,
                          const char *title, const char *ytitle,
                          std::vector<TrendSeries> &ssIn, const char *pdfMode,
                          const TrendPageOpt &opt = TrendPageOpt()) {
   //  x 축 시작이 정해졌으면 그 앞의 점은 그리지 않는다 (축 범위·y 범위·inset 판단·구석 계산이 전부 그려질 점으로 잰다).
   //  정해지지 않았으면 ssIn 을 그대로 쓴다 — 산출이 예전과 바이트 단위로 같다.
   const double xmin = ReneResolveXmin(opt.xmin);
   std::vector<TrendSeries> ssCut;
   if (xmin > 0) {
      for (const auto &s0 : ssIn) {
         TrendSeries s = s0; s.x.clear(); s.y.clear(); s.ey.clear();
         for (size_t i = 0; i < s0.x.size(); ++i) if (s0.x[i] >= xmin)
            s.add(s0.x[i], s0.y[i], s0.ey.empty() ? 0 : s0.ey[i]);
         if (s0.ey.empty()) s.ey.clear();
         ssCut.push_back(s);
      }
   }
   std::vector<TrendSeries> &ss = (xmin > 0) ? ssCut : ssIn;
   TCanvas *c = new TCanvas(Form("c_%s", fileName), title, opt.width, opt.height);
   c->SetLeftMargin(0.11); c->SetBottomMargin(0.15); c->SetRightMargin(0.04);
   c->SetGridx(); c->SetGridy();

   int cnt[4] = {0, 0, 0, 0};
   std::vector<int> corners = ReneEmptyCorners(ss, false, xmin, -1, cnt);
   bool wantInset = opt.logInset && ReneNeedsLog(ss);
   //  축 시작을 정한 경우만 (2026-10-18) : 잘라 낸 뒤에는 점이 그림 가운데 띠를 채워 빈 구석이 없을 수 있다
   //  (실측 01_rate_candidates_nGd : inset 이 점 위에 앉았다). 그러면 위 여백을 늘려 위쪽 두 구석을 비운다 —
   //  자료 최댓값이 축 높이의 52 % 에 오게. 축 시작을 안 정하면 이 블록은 돌지 않는다 (산출 불변).
   bool yFix = false; double yLoFix = 0, yHiFix = 0;
   {
      bool needLeg = opt.legend && ss.size() > 1;
      int nBox = (wantInset ? 1 : 0) + (needLeg ? 1 : 0);
      bool crowded = (nBox >= 1 && cnt[corners[0]] > 0) || (nBox >= 2 && cnt[corners[1]] > 0);
      double ylo0, yhi0; ReneLinearRange(ss, ylo0, yhi0);
      if (xmin > 0 && crowded && yhi0 > ylo0) {
         double ymaxData = (ylo0 == 0) ? yhi0 / 1.15 : yhi0;     // ReneLinearRange 가 붙인 15 % 를 걷어 낸 자료 최댓값(오차 포함)
         yLoFix = (ylo0 == 0) ? 0 : ylo0 - 0.05 * (yhi0 - ylo0);
         yHiFix = yLoFix + (ymaxData - yLoFix) / 0.52;
         yFix = true;
         corners = ReneEmptyCorners(ss, false, xmin, yHiFix, cnt, yLoFix, true);
      }
   }
   //  inset 이 있으면 가장 빈 구석, 범례는 그 다음 구석
   double ix1, iy1, ix2, iy2, lx1, ly1, lx2, ly2;
   ReneCornerBox(corners[0], 0.36, 0.40, ix1, iy1, ix2, iy2);
   size_t maxLab = 4; for (const auto &s : ss) maxLab = std::max(maxLab, s.label.size());
   double legW = std::min(0.40, 0.10 + 0.011 * (double)maxLab);
   ReneCornerBox(corners[wantInset ? 1 : 0], legW, 0.05 + 0.04 * std::max<size_t>(ss.size(), 1), lx1, ly1, lx2, ly2);

   TLegend *leg = new TLegend(lx1, ly1, lx2, ly2);
   leg->SetBorderSize(0); leg->SetFillStyle(1001); leg->SetFillColor(kWhite); leg->SetTextSize(0.035);   // 불투명 : 선 위에 앉아도 읽힌다
   bool any = false;
   TMultiGraph *mg = ReneMakeGraphs(ss, leg, any);
   if (!any) { delete c; return false; }

   mg->SetTitle(Form("%s;DAQ start [YY/MM/DD];%s", title, ytitle));
   mg->Draw("A");
   ReneStyleAxes(mg, opt.timeFmt, 0.045, 0.038);
   if (xmin > 0) { double xhiAuto = mg->GetXaxis()->GetXmax(); if (xhiAuto > xmin) mg->GetXaxis()->SetLimits(xmin, xhiAuto); gPad->Modified(); }
   //  선형축 : 0 을 포함하도록 아래를 내린다 (음수 값이 없을 때)
   {
      double ylo, yhi; ReneLinearRange(ss, ylo, yhi);
      if (yFix) { mg->SetMinimum(yLoFix); mg->SetMaximum(yHiFix); }
      else if (ylo == 0 && yhi > 0) { mg->SetMinimum(0); mg->SetMaximum(yhi); }
   }
   if (opt.legend && ss.size() > 1) leg->Draw();
   ReneDrawMarkers(mg, opt.markers);

   if (wantInset) {
      TPad *p = new TPad(Form("inset_%s", fileName), "", ix1, iy1, ix2, iy2);
      p->SetFillStyle(4000); p->SetFillColor(0);
      p->SetLeftMargin(0.22); p->SetBottomMargin(0.22); p->SetRightMargin(0.04); p->SetTopMargin(0.08);
      p->SetGridy(); p->SetLogy();
      p->Draw(); p->cd();
      bool any2 = false;
      TMultiGraph *mg2 = ReneMakeGraphs(ss, nullptr, any2);
      mg2->SetTitle(";;log scale");
      mg2->Draw("A");
      ReneStyleAxes(mg2, opt.timeFmt, 0.07, 0.06);
      mg2->GetXaxis()->SetTitle(""); mg2->GetXaxis()->SetNdivisions(404);
      mg2->GetYaxis()->SetTitleOffset(1.0); mg2->GetYaxis()->SetNdivisions(505);
      if (xmin > 0) { double xhiAuto = mg2->GetXaxis()->GetXmax(); if (xhiAuto > xmin) mg2->GetXaxis()->SetLimits(xmin, xhiAuto); gPad->Modified(); }
      c->cd();
   }
   if (pdf.Length()) c->Print(pdf + pdfMode);
   c->Print(pngDir + fileName + ".png");
   return true;
}

#endif
