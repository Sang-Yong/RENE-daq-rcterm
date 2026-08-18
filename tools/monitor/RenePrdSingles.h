// ---------------------------------------------------------------------------
//  RenePrdSingles.h - production 산출물(PRD)에서 곧바로 'clean single' 목록을
//                     만든다. 분석 쪽 Step1 + Step2 에 해당하는 부분이다.
//
//  왜 있나
//     예전 BuildPairSummary.C 는 /scratch/junkyo/SampleFiles 의 Step2/Step3
//     산출물을 읽었다. 그러면 저쪽이 그 런을 아직 안 돌렸을 때 이 표가 멈춘다
//     (실제로 2026-08-18 에 1단계는 4291 까지 갔는데 2단계는 4240 에서 멎어
//     있었다). **production 이 끝난 PRD 만 있으면 되도록** 입력을 옮겼다.
//
//  무엇을 읽나  ★ 여기가 정본이다
//     <root>/RAW/<NNNNNN>/PRD/PRD_<NNNNNN>.<SSSSS>.root  : TTree "Event"
//     root 는 여러 곳을 순서대로 찾는다 (dataflow 가 런을 옮기기 때문이다) --
//     /Data_ssd/RAW -> /data/RAW -> /scratch/RAW.
//
//  ---- 물리는 베끼지 않고 분석 코드를 그대로 include 한다 ----
//  파형 -> NPE 변환(GetPed/GetBinAbove/GetQsum/GetSaturation), 보정 상수,
//  컷 값은 전부 /home/ojk/analysis3/essential 의 것을 쓴다. 여기에 베껴 두면
//  저쪽이 바꿨을 때 이 표만 조용히 틀린 값이 된다 (CLAUDE.md §5.8 과 같은
//  이유). 경로는 -DRENE_ANA_DIR=... 로 바꿀 수 있다.
//
//  재현하는 것 (AnalysisStep1.C / AnalysisStep2.C 의 규칙 그대로)
//     1. globalTime = TCBTRGTime + offset.  TCB 시계가 되감기면 offset 보정.
//        carry 는 **런 전체에 이어 간다** -- 서브런마다 0 부터 다시 세면
//        서브런 경계를 넘는 coincidence 창이 깨진다.
//     2. muon veto : SADC 패널 15개 중 위/아래가 함께 켜진 것이 있으면 veto.
//     3. FADC ch0, ch1 파형을 적분해 NPE 를 얻는다 (target 두 PMT).
//     4. Step2 컷 순서대로 버린다 -- muon -> after-muon(dt < veto_cut) ->
//        saturation. 순서를 바꾸면 각 범주의 수가 달라진다.
//     5. 남은 것 중 (q0<5 && q1<5) 를 버리고 q0+q1 > thr 인 것만 single 로
//        남긴다 (essential/Step2Reader.h 의 LoadCleanSingles 와 같은 규칙).
//
//  ---- 서브런 캐시 ----
//  파형을 읽는 것이 비싸다 (실측 : 로컬 NVMe 1.1 s/서브런, /scratch 14.6 s).
//  그래서 서브런마다 single 목록만 작은 ROOT 파일로 남긴다. 24시간 런이면
//  1440개, 런당 약 150 MB 다. 두 번째 실행부터는 파형을 다시 읽지 않는다.
//  캐시에는 그때 쓴 문턱과 veto 창을 같이 적어 두고, 값이 바뀌면 무시한다.
// ---------------------------------------------------------------------------
#ifndef RENE_PRD_SINGLES_H
#define RENE_PRD_SINGLES_H

//  분석 코드의 두 파일을 통째로 include 한다. `#include MACRO "..."` 는
//  이어 붙지 않으므로 경로를 하나씩 통째로 둔다.
#ifndef RENE_ANA_HELPERS
#define RENE_ANA_HELPERS "/home/ojk/analysis3/essential/helper_functions.cc"
#endif
#ifndef RENE_COND_HEADER
#define RENE_COND_HEADER "/home/ojk/analysis3/essential/AnalysisCondition.h"
#endif

#include <TChain.h>
#include <TFile.h>
#include <TObjString.h>
#include <TString.h>
#include <TSystem.h>
#include <TSystemDirectory.h>
#include <TSystemFile.h>
#include <TTree.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

//  파형 -> NPE 와 브랜치 연결. 전역 Fbit/Sbit/FFwaveform/tcbtrgTime 등을 준다.
#include RENE_ANA_HELPERS
//  컷 상수, SetChannel(), S1S2_Candidate, EventID.
#include RENE_COND_HEADER

//  Step1 의 CHARGE_TO_NPE 와 같은 값이어야 한다 (AnalysisStep1.C:23).
//  저쪽은 static const 라 include 로 가져올 수 없어 여기 둔다. 바뀌면
//  두 곳을 함께 고칠 것.
static const double kChargeToNpe = 1.6 * 0.7;   // pC per NPE (gain 0.7)

// ---------------------------------------------------------------------------
//  런을 이어 가는 상태. AnalysisStep1.C 의 TimeCarry 와 같은 뜻이다.
struct ReneCarry {
   double timeOffset   = 0;
   double prevTrigTime = 0;
   double muonTime     = 0;
   bool   started      = false;
};

//  서브런 하나를 처리하고 나온 것
struct ReneSubrunStat {
   int       subrun   = -1;
   long long nIn      = 0;   // PRD 이벤트 수
   long long nMuon    = 0;   // muon veto 로 버린 것
   long long nAfterMu = 0;   // veto 창 안이라 버린 것
   long long nSat     = 0;   // 포화라 버린 것
   long long nClean   = 0;   // Step2 를 통과한 것
   long long nSingle  = 0;   // 그 중 문턱 위 (페어링에 쓰는 것)
   double    tStart   = -1;  // [us] 런 시작을 0 으로 한 시각
   double    tEnd     = -1;
   double    liveSec  = 0;   // (tEnd - tStart) / 1e6
   bool      ok       = false;
};

// ---------------------------------------------------------------------------
static TString ReneRunStr(int run) { return TString::Format("%06d", run); }

//  런 디렉터리를 여러 root 에서 찾는다. 앞에 오는 것이 이긴다 --
//  기본 순서가 /Data_ssd -> /data -> /scratch 인 이유는 속도다(위 주석).
//  roots 는 ':' 로 나눈 목록.
inline TString ReneFindRunDir(int run, const TString &roots) {
   TString runS = ReneRunStr(run);
   TString list = roots;
   TObjArray *parts = list.Tokenize(":");
   TString found = "";
   for (int i = 0; i < parts->GetEntries(); ++i) {
      TString r = ((TObjString *)parts->At(i))->GetString();
      r = r.Strip(TString::kBoth);
      if (r.IsNull()) continue;
      if (!r.EndsWith("/")) r += "/";
      TString pdir = r + runS + "/PRD/";
      if (!gSystem->AccessPathName(pdir)) { found = r + runS + "/"; break; }
   }
   delete parts;
   return found;
}

//  PRD 디렉터리에서 서브런 번호를 모은다.
inline std::vector<int> ReneListSubruns(const TString &runDir, int run) {
   std::vector<int> out;
   TString pdir = runDir + "PRD/";
   TString pref = "PRD_" + ReneRunStr(run) + ".";
   TSystemDirectory d("d", pdir);
   TList *files = d.GetListOfFiles();
   if (!files) return out;
   TIter next(files);
   TSystemFile *sf;
   while ((sf = (TSystemFile *)next())) {
      TString nm = sf->GetName();
      if (sf->IsDirectory()) continue;
      if (!nm.BeginsWith(pref) || !nm.EndsWith(".root")) continue;
      TString num = nm(pref.Length(), 5);
      if (!num.IsDigit()) continue;
      out.push_back(num.Atoi());
   }
   delete files;
   std::sort(out.begin(), out.end());
   return out;
}

// ---------------------------------------------------------------------------
//  SADC 패널 muon veto. AnalysisStep1.C 의 isMuonVeto 와 같다.
inline bool ReneIsMuonVeto(const int *Sbit_) {
   for (int panel = 0; panel < 15; ++panel)
      if (Sbit_[2 * panel] && Sbit_[2 * panel + 1]) return true;
   return false;
}

//  FADC 채널 하나의 NPE. 신호가 없으면 -999 (Step1 의 기본값과 같다).
//  포화 여부는 saturate 에 OR 로 얹는다.
inline double ReneChannelNpe(int ch, int timeWindow, bool &saturate) {
   if (Fbit[ch] == 0 || !FFwaveform[ch]) return -999.0;
   double ped = GetPed(FFwaveform[ch], 0, PEDESTAL_RANGE);
   auto thr = GetBinAbove(FFwaveform[ch], 0, timeWindow, ped, Fthr[ch]);
   int thrTime = thr.second;
   if (thrTime < 0) return -999.0;
   int sIdx = std::max(0, thrTime - 10);
   int eIdx = std::min((int)FFwaveform[ch]->size(), thrTime + 240);
   double integral  = GetQsum(FFwaveform[ch], sIdx, eIdx, ped);
   double charge_pC = DT_NS * ((DYNAMIC_RANGE / RESOLUTION) * integral) / IMPEDANCE;
   if (GetSaturation(FFwaveform[ch])) saturate = true;
   return charge_pC / kChargeToNpe;
}

// ---------------------------------------------------------------------------
//  캐시 파일 경로
inline TString ReneCachePath(const TString &cacheDir, int run, int sub) {
   return TString::Format("%ssingles_%s_%05d.root",
                          cacheDir.Data(), ReneRunStr(run).Data(), sub);
}

//  캐시를 읽는다. thr / vetoCut 이 다르면 못 쓰는 것으로 본다.
inline bool ReneLoadCache(const TString &path, double thr, double vetoCutUs,
                          std::vector<S1S2_Candidate> &out, ReneCarry &carry,
                          ReneSubrunStat &st) {
   if (gSystem->AccessPathName(path)) return false;
   TFile *f = TFile::Open(path, "READ");
   if (!f || f->IsZombie()) { if (f) f->Close(); return false; }
   TTree *tS = (TTree *)f->Get("T_State");
   TTree *tE = (TTree *)f->Get("T_Singles");
   if (!tS || !tE || tS->GetEntries() < 1) { f->Close(); return false; }

   Double_t c_off, c_prev, c_muon, c_thr, c_veto, c_start, c_end;
   Int_t    c_started, c_sub;
   Long64_t c_in, c_mu, c_after, c_sat, c_clean, c_single;
   tS->SetBranchAddress("subrun",      &c_sub);
   tS->SetBranchAddress("time_offset", &c_off);
   tS->SetBranchAddress("prev_trig",   &c_prev);
   tS->SetBranchAddress("muon_time",   &c_muon);
   tS->SetBranchAddress("started",     &c_started);
   tS->SetBranchAddress("thr_npe",     &c_thr);
   tS->SetBranchAddress("veto_us",     &c_veto);
   tS->SetBranchAddress("t_start",     &c_start);
   tS->SetBranchAddress("t_end",       &c_end);
   tS->SetBranchAddress("n_in",        &c_in);
   tS->SetBranchAddress("n_muon",      &c_mu);
   tS->SetBranchAddress("n_aftermu",   &c_after);
   tS->SetBranchAddress("n_sat",       &c_sat);
   tS->SetBranchAddress("n_clean",     &c_clean);
   tS->SetBranchAddress("n_single",    &c_single);
   tS->GetEntry(0);

   //  문턱이나 veto 창이 달라졌으면 이 캐시는 다른 조건의 것이다.
   if (std::fabs(c_thr - thr) > 1e-6 || std::fabs(c_veto - vetoCutUs) > 1e-6) {
      f->Close();
      return false;
   }

   Int_t    e_evt, e_sub;
   Double_t e_t;
   Float_t  e_pe;
   tE->SetBranchAddress("evt_id", &e_evt);
   tE->SetBranchAddress("sub_id", &e_sub);
   tE->SetBranchAddress("t_us",   &e_t);
   tE->SetBranchAddress("pe",     &e_pe);
   Long64_t n = tE->GetEntries();
   for (Long64_t i = 0; i < n; ++i) {
      tE->GetEntry(i);
      out.push_back({e_evt, e_sub, e_t, (double)e_pe});
   }

   carry.timeOffset   = c_off;
   carry.prevTrigTime = c_prev;
   carry.muonTime     = c_muon;
   carry.started      = (c_started != 0);

   st = ReneSubrunStat();
   st.subrun  = c_sub;
   st.nIn     = c_in;     st.nMuon   = c_mu;     st.nAfterMu = c_after;
   st.nSat    = c_sat;    st.nClean  = c_clean;  st.nSingle  = c_single;
   st.tStart  = c_start;  st.tEnd    = c_end;
   st.liveSec = (c_end > c_start) ? (c_end - c_start) * 1e-6 : 0.0;
   st.ok      = true;

   f->Close();
   return true;
}

inline void ReneSaveCache(const TString &path, double thr, double vetoCutUs,
                          const std::vector<S1S2_Candidate> &sing, size_t first,
                          const ReneCarry &carry, const ReneSubrunStat &st) {
   //  임시 이름으로 쓰고 마지막에 옮긴다. 도중에 끊겨도 잘린 파일이 최종
   //  이름을 차지하지 않는다 (postrun.sh 가 rsync 로 하는 것과 같은 이유).
   TString tmp = path + ".tmp";
   TFile *f = TFile::Open(tmp, "RECREATE");
   if (!f || f->IsZombie()) { if (f) f->Close(); return; }

   TTree *tE = new TTree("T_Singles", "clean singles above threshold");
   Int_t    e_evt = 0, e_sub = 0;
   Double_t e_t = 0;
   Float_t  e_pe = 0;
   tE->Branch("evt_id", &e_evt);
   tE->Branch("sub_id", &e_sub);
   tE->Branch("t_us",   &e_t);
   tE->Branch("pe",     &e_pe);
   for (size_t i = first; i < sing.size(); ++i) {
      e_evt = sing[i]._evt_id; e_sub = sing[i]._sub_id;
      e_t   = sing[i]._t_us;   e_pe  = (Float_t)sing[i]._pe_sum;
      tE->Fill();
   }

   TTree *tS = new TTree("T_State", "carry-over and per-subrun counts");
   Int_t    c_sub = st.subrun, c_started = carry.started ? 1 : 0;
   Double_t c_off = carry.timeOffset, c_prev = carry.prevTrigTime;
   Double_t c_muon = carry.muonTime, c_thr = thr, c_veto = vetoCutUs;
   Double_t c_start = st.tStart, c_end = st.tEnd;
   Long64_t c_in = st.nIn, c_mu = st.nMuon, c_after = st.nAfterMu;
   Long64_t c_sat = st.nSat, c_clean = st.nClean, c_single = st.nSingle;
   tS->Branch("subrun",      &c_sub);
   tS->Branch("time_offset", &c_off);
   tS->Branch("prev_trig",   &c_prev);
   tS->Branch("muon_time",   &c_muon);
   tS->Branch("started",     &c_started);
   tS->Branch("thr_npe",     &c_thr);
   tS->Branch("veto_us",     &c_veto);
   tS->Branch("t_start",     &c_start);
   tS->Branch("t_end",       &c_end);
   tS->Branch("n_in",        &c_in);
   tS->Branch("n_muon",      &c_mu);
   tS->Branch("n_aftermu",   &c_after);
   tS->Branch("n_sat",       &c_sat);
   tS->Branch("n_clean",     &c_clean);
   tS->Branch("n_single",    &c_single);
   tS->Fill();

   f->cd(); tE->Write(); tS->Write(); f->Close();
   gSystem->Rename(tmp, path);
}

// ---------------------------------------------------------------------------
//  서브런 하나를 파형부터 처리한다. single 을 sing 뒤에 덧붙이고 carry 를
//  갱신한다. AnalysisStep1.C + AnalysisStep2.C 의 순서를 그대로 따른다.
inline ReneSubrunStat ReneProcessSubrun(const TString &prdPath, int sub, double thr,
                                        double vetoCutUs, ReneCarry &carry,
                                        std::vector<S1S2_Candidate> &sing) {
   ReneSubrunStat st;
   st.subrun = sub;

   TChain chain("Event");
   if (chain.Add(prdPath) == 0) return st;

   chain.SetBranchStatus("*", 0);
   chain.SetBranchStatus("F_Triggered", 1);
   chain.SetBranchStatus("S_Triggered", 1);
   chain.SetBranchStatus("F_Waveform_*", 1);
   chain.SetBranchStatus("TCBTRGTime", 1);
   chain.SetBranchStatus("F_THR", 1);
   chain.SetBranchStatus("F_NDP", 1);
   setbranch(&chain);

   Long64_t n = chain.GetEntries();
   if (n == 0) return st;

   chain.GetEntry(0);
   const int timeWindow = Fndp[0];

   bool firstSet = false;
   for (Long64_t i = 0; i < n; ++i) {
      initializing();
      chain.GetEntry(i);

      //  --- Step1 : 시각 풀기 ---
      if (!carry.started) { carry.timeOffset -= tcbtrgTime; carry.started = true; }
      if (tcbtrgTime < carry.prevTrigTime) carry.timeOffset += carry.prevTrigTime;
      carry.prevTrigTime = tcbtrgTime;
      double globalTime = tcbtrgTime + carry.timeOffset;   // [ns]

      if (!firstSet) { st.tStart = globalTime * DAQ_NS_TO_US; firstSet = true; }
      st.tEnd = globalTime * DAQ_NS_TO_US;
      st.nIn++;

      //  --- Step1 : muon veto. muonTime 갱신이 dt 계산보다 먼저다 ---
      bool isVeto = ReneIsMuonVeto(Sbit);
      if (isVeto) carry.muonTime = globalTime;
      double dt_us = (carry.muonTime > 0) ? (globalTime - carry.muonTime) / 1000.0 : -1.0;

      //  --- Step2 컷. 순서를 바꾸면 범주별 수가 달라진다 ---
      if (isVeto)                            { st.nMuon++;    continue; }
      if (dt_us >= 0 && dt_us < vetoCutUs)   { st.nAfterMu++; continue; }

      bool sat = false;
      double q0 = ReneChannelNpe(0, timeWindow, sat);
      double q1 = ReneChannelNpe(1, timeWindow, sat);
      if (sat) { st.nSat++; continue; }
      st.nClean++;

      //  --- Step2Reader 의 LoadCleanSingles 와 같은 규칙 ---
      //  Step2 가 float 로 저장하므로 여기서도 float 로 깎는다. 그래야
      //  경계에 걸친 이벤트에서 결과가 갈리지 않는다.
      float f0 = (float)q0, f1 = (float)q1;
      if (f0 < 5.0f && f1 < 5.0f) continue;
      double pe = (double)f0 + (double)f1;
      if (pe <= thr) continue;

      sing.push_back({(int)i, sub, globalTime * DAQ_NS_TO_US, pe});
      st.nSingle++;
   }

   st.liveSec = (st.tEnd > st.tStart) ? (st.tEnd - st.tStart) * 1e-6 : 0.0;
   st.ok = true;
   return st;
}

// ---------------------------------------------------------------------------
//  런 하나의 clean single 전부. 캐시가 있으면 파형을 다시 읽지 않는다.
//  서브런은 **번호 순서대로** 처리해야 한다 -- carry 가 이어지기 때문이다.
struct ReneRunSingles {
   int    run       = 0;
   TString runDir   = "";
   int    nSubrun   = 0;
   int    nFromCache= 0;
   int    nRead     = 0;
   int    nBad      = 0;
   long long nIn = 0, nMuon = 0, nAfterMu = 0, nSat = 0, nClean = 0;
   double liveSec   = 0;      // Σ 서브런 livetime
   std::vector<S1S2_Candidate> singles;

   double rateLL() const { return liveSec > 0 ? (double)singles.size() / liveSec : -1; }
};

//  progress : 몇 개마다 한 줄 찍을지. 0 이면 조용히.
inline bool ReneLoadRunSingles(int run, const TString &roots, const TString &cacheDir,
                               double thr, double vetoCutUs, int maxSubrun,
                               int progress, ReneRunSingles &out) {
   out = ReneRunSingles();
   out.run = run;
   out.runDir = ReneFindRunDir(run, roots);
   if (out.runDir.IsNull()) {
      printf("  [SKIP] run %d : PRD 디렉터리를 못 찾았다 (%s 아래)\n", run, roots.Data());
      return false;
   }

   std::vector<int> subs = ReneListSubruns(out.runDir, run);
   if (subs.empty()) {
      printf("  [SKIP] run %d : PRD 파일이 없다 (%sPRD/)\n", run, out.runDir.Data());
      return false;
   }
   if (maxSubrun >= 0)
      subs.erase(std::remove_if(subs.begin(), subs.end(),
                                [&](int s) { return s > maxSubrun; }), subs.end());

   gSystem->mkdir(cacheDir, kTRUE);

   ReneCarry carry;
   TString runS = ReneRunStr(run);
   for (size_t k = 0; k < subs.size(); ++k) {
      int sub = subs[k];
      TString cpath = ReneCachePath(cacheDir, run, sub);
      ReneSubrunStat st;
      size_t before = out.singles.size();

      if (!ReneLoadCache(cpath, thr, vetoCutUs, out.singles, carry, st)) {
         //  캐시가 못 쓰는 것이면 그 위치까지 되돌리고 파형에서 다시 만든다
         out.singles.resize(before);
         TString prd = TString::Format("%sPRD/PRD_%s.%05d.root",
                                       out.runDir.Data(), runS.Data(), sub);
         st = ReneProcessSubrun(prd, sub, thr, vetoCutUs, carry, out.singles);
         if (!st.ok) {
            printf("  [WARN] run %d subrun %d : 읽지 못했다\n", run, sub);
            out.nBad++;
            continue;
         }
         ReneSaveCache(cpath, thr, vetoCutUs, out.singles, before, carry, st);
         out.nRead++;
      } else {
         out.nFromCache++;
      }

      out.nSubrun++;
      out.nIn += st.nIn; out.nMuon += st.nMuon; out.nAfterMu += st.nAfterMu;
      out.nSat += st.nSat; out.nClean += st.nClean;
      out.liveSec += st.liveSec;

      if (progress > 0 && ((k + 1) % progress == 0 || k + 1 == subs.size())) {
         printf("\r    run %d : 서브런 %zu/%zu  (캐시 %d / 새로 읽음 %d)  single %zu   ",
                run, k + 1, subs.size(), out.nFromCache, out.nRead, out.singles.size());
         fflush(stdout);
      }
   }
   if (progress > 0) printf("\n");

   //  페어링은 시간 순서를 전제로 한다. 서브런 순서대로 넣었으니 이미 정렬돼
   //  있어야 하지만, 한 서브런이라도 빠지면 어긋날 수 있어 확인 삼아 정렬한다.
   std::sort(out.singles.begin(), out.singles.end());
   return !out.singles.empty();
}

#endif
