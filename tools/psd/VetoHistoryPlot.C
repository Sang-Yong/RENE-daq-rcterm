#include <TGraph.h>
#include <TMultiGraph.h>
#include <TCanvas.h>
#include <TLegend.h>
#include <TAxis.h>
#include <TStyle.h>
#include <TLine.h>
#include <fstream>
#include <sstream>
#include <vector>
void VetoHistoryPlot(const char* tsv="/scratch/RunSummary/psd/veto_history.tsv", const char* out="/scratch/RunSummary/psd/"){
  gStyle->SetOptStat(0); gStyle->SetTimeOffset(0);
  std::ifstream in(tsv); std::string l; std::vector<std::vector<double>> R; 
  while(std::getline(in,l)){ if(l.empty()||l[0]=='#') continue; std::stringstream ss(l); std::vector<double> v; std::string f; int k=0; while(std::getline(ss,f,'\t')){ if(k==2){k++;continue;} v.push_back(atof(f.c_str())); k++; } R.push_back(v); }
  // columns after dropping date: 0 run 1 epoch 2 n_sub 3 fadc 4 veto 5 thr2 6 thr3 7 thr9 8 ch2 9 ch3 10.. panel0..14
  int pan[6]={0,1,2,3,8,11}; int col[6]={kRed+1,kBlue+1,kGreen+2,kMagenta+1,kOrange+7,kCyan+2};
  auto mk=[&](int c, double lo){ TGraph* g=new TGraph(); for(auto&v:R){ if(v[0]<lo) continue; g->SetPoint(g->GetN(), v[1], v[c]); } g->Sort(); return g; };
  auto page=[&](const char* name,const char* title,const char* yt,std::vector<std::pair<TGraph*,const char*>> gs, double lo){
    TCanvas c(name,title,1300,600); c.SetGridx(); c.SetGridy(); TMultiGraph* mg=new TMultiGraph(); TLegend* lg=new TLegend(0.78,0.6,0.97,0.9); lg->SetBorderSize(0); int k=0;
    for(auto&p:gs){ p.first->SetMarkerStyle(20); p.first->SetMarkerColor(col[k%6]); p.first->SetLineColor(col[k%6]); mg->Add(p.first,"LP"); lg->AddEntry(p.first,p.second,"lp"); k++; }
    mg->SetTitle(Form("%s;DAQ start [MM/DD];%s",title,yt)); mg->Draw("A"); TAxis* ax=mg->GetXaxis(); ax->SetTimeDisplay(1); ax->SetTimeFormat("%m/%d"); ax->SetTimeOffset(0,"gmt"); lg->Draw();
    c.Print(TString(out)+name+".png"); };
  std::vector<std::pair<TGraph*,const char*>> P; for(int i=0;i<6;i++) P.push_back({mk(10+pan[i],4280), Form("panel %d",pan[i])});
  page("veto_panel_trend","VETO panel AND fraction per run (subrun-averaged, runs >= 4280)","fraction of events [%]",P,4280);
  page("veto_rate_trend","VETO-tagged event rate per run","rate [Hz]",{{mk(4,4280),"veto (any panel AND)"}},4280);
  page("veto_panel1_pmts","Panel 1 PMTs (ch2, ch3) trigger fraction per run","fraction [%]",{{mk(8,4280),"ch2"},{mk(9,4280),"ch3"},{mk(11,4280),"panel 1 AND"}},4280);
  printf("[SAVED] %sveto_*.png\n", out);
}
