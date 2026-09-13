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
#include <TGraphErrors.h>
#include <TLegend.h>
#include <TMultiGraph.h>
#include <TPad.h>
#include <TString.h>
#include <TStyle.h>

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

struct TrendSeries {
   std::vector<double> x, y, ey;
   std::string label;
   int color = kBlack, marker = 20;
   void add(double xx, double yy, double e = 0) { x.push_back(xx); y.push_back(yy); ey.push_back(e); }
};

struct TrendPageOpt {
   bool logInset   = false;   // 값이 한 자릿수 넘게 벌어지면 로그축 inset 을 넣는다
   bool legend     = true;    // 계열이 둘 이상이면 범례
   const char *timeFmt = "%y/%m/%d";
   int  width = 1400, height = 700;
};

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

static std::vector<int> ReneEmptyCorners(const std::vector<TrendSeries> &ss, bool logy = false) {
   double xlo = 1e300, xhi = -1e300, ylo = 1e300, yhi = -1e300;
   for (const auto &s : ss) for (size_t i = 0; i < s.x.size(); ++i) {
      xlo = std::min(xlo, s.x[i]); xhi = std::max(xhi, s.x[i]);
   }
   ReneLinearRange(ss, ylo, yhi);        // ★ 자료 범위가 아니라 그려질 축 범위로 잰다 (효율 그림에서 범례가 선 위에 앉았다)
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

//  쪽 하나. 돌려주는 값 : 그렸는가 (계열이 전부 비면 false, 파일도 안 만든다).
//  fileName 은 확장자 없는 이름 (예 "01_rate_candidates_nGd").
static bool DrawTrendPage(const TString &pdf, const TString &pngDir, const char *fileName,
                          const char *title, const char *ytitle,
                          std::vector<TrendSeries> &ss, const char *pdfMode,
                          const TrendPageOpt &opt = TrendPageOpt()) {
   TCanvas *c = new TCanvas(Form("c_%s", fileName), title, opt.width, opt.height);
   c->SetLeftMargin(0.11); c->SetBottomMargin(0.15); c->SetRightMargin(0.04);
   c->SetGridx(); c->SetGridy();

   std::vector<int> corners = ReneEmptyCorners(ss, false);
   bool wantInset = opt.logInset && ReneNeedsLog(ss);
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
   //  선형축 : 0 을 포함하도록 아래를 내린다 (음수 값이 없을 때)
   {
      double ylo, yhi; ReneLinearRange(ss, ylo, yhi);
      if (ylo == 0 && yhi > 0) { mg->SetMinimum(0); mg->SetMaximum(yhi); }
   }
   if (opt.legend && ss.size() > 1) leg->Draw();

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
      c->cd();
   }
   if (pdf.Length()) c->Print(pdf + pdfMode);
   c->Print(pngDir + fileName + ".png");
   return true;
}

#endif
