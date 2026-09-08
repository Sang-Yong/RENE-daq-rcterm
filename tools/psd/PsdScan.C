// ---------------------------------------------------------------------------
//  PsdScan.C - 중성자 선원 런(AmBe · Cf252)과 물리 런의 PRD 파형에서 펄스 모양
//              변수를 이벤트마다 뽑아 작은 트리로 남긴다 (읽기 전용 입력).
//              PSD 기준을 세우기 위한 1단계 -- 무엇이 갈리는지 보려면 먼저 변수를
//              여러 개 뽑아 두어야 한다. 판단은 PsdAnalyze.C 가 한다.
//
//  표본 태그 (NEOS §4.3.2 · 김진유 §5.1.5 의 방법을 이 트리에 맞춘 것)
//     tagN   이 사건 뒤 [1,100] µs 안에 n-Gd 포획(6-10 MeV)이 따른다  -> 중성자(recoil) 풍부
//     tagG   이 사건이 어떤 사건 뒤 [1,400] µs 안에 오고 자기 에너지가 포획창(n-H 1.87-2.59
//            또는 n-Gd 6-10 MeV)에 든다                                   -> 포획 γ (γ 참조)
//  둘 다 '순수' 하지는 않다 -- AmBe 는 4.44 MeV γ 가 중성자와 함께 나오고 Cf252 는
//  분열 γ 가 섞인다. 그래서 PsdAnalyze 가 두 성분 분해로 평균을 뽑는다.
//
//  변수 (채널 0·1 각각 + 합)
//     q        NPE (ReneChannelNpe 와 같은 적분창 -10..+240 샘플)
//     pk       피크 위치 [샘플], cfd 50 % 상승 시각 [샘플, 소수]
//     rise     10 %→90 % 상승 [샘플]      fwhm  반치폭 [샘플]
//     pkfrac   피크 높이 / 전체 적분 (NEOS 의 q/f 역수)
//     tail20/30/40/50   피크+N 샘플 이후 적분 / 전체
//     late     피크+100 샘플(200 ns) 이후 / 전체
//     mt       전하 가중 평균 시각 [샘플], cfd 기준  (NEOS 의 t̄)
//     asym     (q0-q1)/(q0+q1)  -- 위치 대용
//     sat      포화 여부
//
//  사용 : root -l -b -q 'PsdScan.C+(2830, "/scratch/RunSummary/psd/", 0, 5, 100)'
//         run · 출력 디렉터리 · 서브런 범위 · 위치[mm](모르면 -1)
// ---------------------------------------------------------------------------
#include "../monitor/RenePrdSingles.h"
#include <TFile.h>
#include <TTree.h>
#include <cmath>

struct WfVars {
   float q=-1, pk=-1, cfd=-1, rise=-1, fwhm=-1, pkfrac=-1;
   float tail20=-1, tail30=-1, tail40=-1, tail50=-1, late=-1, mt=-1;
   char  sat=0, has=0;
};

static WfVars ChannelVars(int ch, int timeWindow) {
   WfVars v;
   if (Fbit[ch] == 0 || !FFwaveform[ch]) return v;
   const std::vector<unsigned short> &w = *FFwaveform[ch];
   double ped = GetPed(FFwaveform[ch], 0, PEDESTAL_RANGE);
   auto thr = GetBinAbove(FFwaveform[ch], 0, timeWindow, ped, Fthr[ch]);
   int thrT = thr.second;
   if (thrT < 0) return v;
   int sI = std::max(0, thrT - 10), eI = std::min((int)w.size(), thrT + 240);
   auto mx = GetMax(FFwaveform[ch], sI, eI, ped);
   int pk = mx.second; double amp = mx.first;
   double tot = GetQsum(FFwaveform[ch], sI, eI, ped);
   if (tot <= 0 || amp <= 0) return v;
   v.has = 1;
   v.q  = (float)((DT_NS * ((DYNAMIC_RANGE / RESOLUTION) * tot) / IMPEDANCE) / kChargeToNpe);
   v.pk = pk;
   v.sat = GetSaturation(FFwaveform[ch]) ? 1 : 0;
   //  CFD 50 % (상승 쪽, 선형 보간)  -- AnalysisStep1.C 와 같은 정의
   double cfd = pk;
   for (int k = pk; k > sI; --k) {
      double y1 = w[k] - ped, y0 = w[k-1] - ped;
      if (y0 < 0.5*amp && y1 >= 0.5*amp) { cfd = (y1 > y0) ? (k-1) + (0.5*amp - y0)/(y1 - y0) : k; break; }
   }
   v.cfd = (float)cfd;
   //  10 % / 90 % 상승, 반치폭
   double t10 = -1, t90 = -1;
   for (int k = sI; k <= pk; ++k) { double y = w[k]-ped; if (t10 < 0 && y >= 0.1*amp) t10 = k; if (t90 < 0 && y >= 0.9*amp) { t90 = k; break; } }
   v.rise = (t10 >= 0 && t90 >= 0) ? (float)(t90 - t10) : -1;
   int hl = pk, hr = pk;
   while (hl > sI && w[hl]-ped >= 0.5*amp) --hl;
   while (hr < eI-1 && w[hr]-ped >= 0.5*amp) ++hr;
   v.fwhm = (float)(hr - hl);
   v.pkfrac = (float)(amp / tot);
   auto tailFrom = [&](int off) { int t = std::min(eI, pk + off); return (float)(GetQsum(FFwaveform[ch], t, eI, ped) / tot); };
   v.tail20 = tailFrom(20); v.tail30 = tailFrom(30); v.tail40 = tailFrom(40); v.tail50 = tailFrom(50);
   v.late   = tailFrom(100);
   double s = 0;
   for (int k = sI; k < eI; ++k) s += (w[k]-ped) * (k - cfd);
   v.mt = (float)(s / tot);
   return v;
}

void PsdScan(int run, const char *outDir, int sub0 = 0, int sub1 = 99999, int posMm = -1,
             const char *roots = "/Data_ssd/RAW:/data/RAW:/scratch/RAW") {
   TString runDir = ReneFindRunDir(run, roots);
   if (runDir.IsNull()) { printf("[SKIP] run %d : PRD 없음\n", run); return; }
   std::vector<int> subs = ReneListSubruns(runDir, run);
   TString out = outDir; if (!out.EndsWith("/")) out += "/";
   gSystem->mkdir(out, kTRUE);
   TString fn = out + TString::Format("psdscan_%06d.root", run);
   TFile *fo = TFile::Open(fn + ".tmp", "RECREATE");
   TTree *t = new TTree("psd", "per-event pulse-shape variables");
   Int_t b_run = run, b_sub = 0, b_evt = 0, b_pos = posMm; Double_t b_t = 0;
   Float_t b_pe = 0, b_asym = 0; Char_t b_sat = 0, b_veto = 0, b_tagN = 0, b_tagG = 0;
   Float_t b_dtPrev = -1, b_dtNext = -1, b_eNext = -1, b_ePrev = -1, b_dtMu = -1;
   WfVars c0, c1;
   t->Branch("run", &b_run); t->Branch("sub", &b_sub); t->Branch("evt", &b_evt); t->Branch("pos", &b_pos);
   t->Branch("t_us", &b_t); t->Branch("pe", &b_pe); t->Branch("asym", &b_asym);
   t->Branch("sat", &b_sat); t->Branch("veto", &b_veto); t->Branch("dt_mu", &b_dtMu);
   t->Branch("tagN", &b_tagN); t->Branch("tagG", &b_tagG);
   t->Branch("dt_prev", &b_dtPrev); t->Branch("e_prev", &b_ePrev);
   t->Branch("dt_next", &b_dtNext); t->Branch("e_next", &b_eNext);
   t->Branch("c0", &c0, "q/F:pk/F:cfd/F:rise/F:fwhm/F:pkfrac/F:tail20/F:tail30/F:tail40/F:tail50/F:late/F:mt/F:sat/B:has/B");
   t->Branch("c1", &c1, "q/F:pk/F:cfd/F:rise/F:fwhm/F:pkfrac/F:tail20/F:tail30/F:tail40/F:tail50/F:late/F:mt/F:sat/B:has/B");

   //  이벤트를 한 서브런씩 모아 두고(시간·에너지), 앞뒤 이웃으로 태그를 정한다.
   struct Ev { double t; float pe; bool veto; };
   SetChannel(CH_NGD); double gdLo = S2_MIN_NPE, gdHi = S2_MAX_NPE;
   SetChannel(CH_NH);  double hLo  = S2_MIN_NPE, hHi  = S2_MAX_NPE;
   double prevT = 0, off = 0, muT = -1; bool started = false;
   long nDone = 0;
   for (int sub : subs) {
      if (sub < sub0 || sub > sub1) continue;
      TString prd = TString::Format("%sPRD/PRD_%06d.%05d.root", runDir.Data(), run, sub);
      TChain ch("Event"); if (ch.Add(prd) == 0) continue;
      ch.SetBranchStatus("*", 0);
      for (auto b : {"F_Triggered","S_Triggered","F_Waveform_*","TCBTRGTime","F_THR","F_NDP"}) ch.SetBranchStatus(b, 1);
      setbranch(&ch);
      Long64_t n = ch.GetEntries(); if (n == 0) continue;
      ch.GetEntry(0); const int tw = Fndp[0];
      std::vector<Ev> ev; ev.reserve(n);
      std::vector<WfVars> v0(n), v1(n); std::vector<double> dtmu(n, -1);
      for (Long64_t i = 0; i < n; ++i) {
         initializing(); ch.GetEntry(i);
         if (!started) { off = -tcbtrgTime; started = true; }
         if (tcbtrgTime < prevT) off += prevT; prevT = tcbtrgTime;
         double g = (tcbtrgTime + off) * DAQ_NS_TO_US;
         bool veto = ReneIsMuonVeto(Sbit);
         if (veto) muT = g;
         dtmu[i] = (muT >= 0) ? g - muT : -1;
         v0[i] = ChannelVars(0, tw); v1[i] = ChannelVars(1, tw);
         float pe = (v0[i].has ? v0[i].q : 0) + (v1[i].has ? v1[i].q : 0);
         ev.push_back({g, pe, veto});
      }
      for (Long64_t i = 0; i < n; ++i) {
         if (ev[i].veto || !(v0[i].has || v1[i].has)) continue;
         b_sub = sub; b_evt = (int)i; b_t = ev[i].t; b_pe = ev[i].pe;
         b_asym = (v0[i].has && v1[i].has && ev[i].pe > 0) ? (v0[i].q - v1[i].q) / ev[i].pe : 0;
         b_sat = (v0[i].sat || v1[i].sat) ? 1 : 0; b_veto = 0; b_dtMu = (float)dtmu[i];
         c0 = v0[i]; c1 = v1[i];
         //  다음 사건(비 veto)까지
         b_dtNext = -1; b_eNext = -1; b_tagN = 0;
         for (Long64_t j = i + 1; j < n; ++j) { if (ev[j].veto) continue; double dt = ev[j].t - ev[i].t;
            if (b_dtNext < 0) { b_dtNext = (float)dt; b_eNext = ev[j].pe; }
            if (dt > 100.0) break;
            if (dt >= 1.0 && ev[j].pe >= gdLo && ev[j].pe <= gdHi) { b_tagN = 1; break; } }
         b_dtPrev = -1; b_ePrev = -1; b_tagG = 0;
         for (Long64_t j = i - 1; j >= 0; --j) { if (ev[j].veto) continue; double dt = ev[i].t - ev[j].t;
            if (b_dtPrev < 0) { b_dtPrev = (float)dt; b_ePrev = ev[j].pe; }
            if (dt > 400.0) break;
            bool inCap = (ev[i].pe >= hLo && ev[i].pe <= hHi) || (ev[i].pe >= gdLo && ev[i].pe <= gdHi);
            if (dt >= 1.0 && inCap && ev[j].pe > LOWER_LIMIT) { b_tagG = 1; break; } }
         t->Fill();
      }
      nDone++;
      printf("\r  run %d sub %d : %lld ev  (%ld 서브런)   ", run, sub, n, nDone); fflush(stdout);
   }
   printf("\n");
   fo->cd(); t->Write(); fo->Close();
   gSystem->Rename(fn + ".tmp", fn);
   printf("[SAVED] %s\n", fn.Data());
}
