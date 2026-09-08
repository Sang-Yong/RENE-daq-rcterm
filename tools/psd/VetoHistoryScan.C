// 런마다 서브런 몇 개에서 S_THR/F_THR(첫 이벤트), SADC 채널별 트리거 비율, 패널 AND 비율, 이벤트율을 잰다
#include <TChain.h>
#include <TFile.h>
#include <TTree.h>
#include <TSystem.h>
#include <TObjArray.h>
#include <TObjString.h>
#include <TString.h>
#include <cstdio>
void VetoHistoryScan(int run, const char* subs, const char* out){
  const char* roots[]={"/Data_ssd/RAW","/data/RAW","/scratch/RAW"}; TString dir;
  for(auto r: roots){ TString d=TString::Format("%s/%06d/PRD",r,run); if(!gSystem->AccessPathName(d)){dir=d;break;} }
  if(dir.IsNull()) return;
  TString sl=subs; TObjArray* a=sl.Tokenize(","); FILE* fo=fopen(out,"a");
  for(int k=0;k<a->GetEntries();k++){ int s=((TObjString*)a->At(k))->GetString().Atoi();
    TString f=TString::Format("%s/PRD_%06d.%05d.root",dir.Data(),run,s); if(gSystem->AccessPathName(f)) continue;
    TFile F(f); TTree* t=(TTree*)F.Get("Event"); if(!t) continue;
    UShort_t sthr[30], fthr[4]; Int_t sbit[30], fbit[4]; Double_t tt;
    t->SetBranchStatus("*",0); for(auto b:{"S_THR","F_THR","S_Triggered","F_Triggered","TCBTRGTime"}) t->SetBranchStatus(b,1);
    t->SetBranchAddress("S_THR",sthr); t->SetBranchAddress("F_THR",fthr); t->SetBranchAddress("S_Triggered",sbit); t->SetBranchAddress("F_Triggered",fbit); t->SetBranchAddress("TCBTRGTime",&tt);
    Long64_t n=t->GetEntries(); if(n<1000) continue; t->GetEntry(0);
    double c[30]={0},p[15]={0}; long nf=0,nv=0; double prev=0,off=0,t0=-1,t1=0;
    for(Long64_t i=0;i<n;i++){ t->GetEntry(i); if(tt<prev) off+=prev; prev=tt; double g=tt+off; if(t0<0)t0=g; t1=g;
      bool anyF=fbit[0]||fbit[1]; bool anyV=false; for(int q=0;q<15;q++){ bool pa=sbit[2*q]>0&&sbit[2*q+1]>0; p[q]+=pa; anyV|=pa; } for(int j=0;j<30;j++) c[j]+=sbit[j]>0; nf+=anyF; nv+=anyV; }
    double live=(t1-t0)*1e-9; if(live<=0) continue;
    fprintf(fo,"%d\t%d\t%.1f\t%lld\t%.1f\t%.1f\t%d\t%d",run,s,live,n,nf/live,nv/live,fthr[0],fthr[1]);
    for(int j=0;j<30;j++) fprintf(fo,"\t%d",sthr[j]); for(int j=0;j<30;j++) fprintf(fo,"\t%.2f",100.0*c[j]/n); for(int q=0;q<15;q++) fprintf(fo,"\t%.3f",100.0*p[q]/n); fprintf(fo,"\n"); }
  fclose(fo); }
