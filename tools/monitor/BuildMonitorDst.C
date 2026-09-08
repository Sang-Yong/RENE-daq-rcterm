// ---------------------------------------------------------------------------
//  BuildMonitorDst.C - PRD 에서 런당 DST 하나를 만든다 (2차 프로덕션).
//  뮤온 시각과 클린 싱글만 담는다. 컷이 바뀌어도 PRD 를 다시 읽지 않고
//  이 파일에서 재계산하는 것이 목적이다 (CLAUDE.md 스펙 2026-09-08).
//  ★ 산출물은 재생 가능 캐시다 -- 백업하지 않는다.
//
//  무엇을 읽나
//     <root>/RAW/<NNNNNN>/PRD/PRD_<NNNNNN>.<SSSSS>.root  (RenePrdSingles.h)
//
//  무엇을 쓰나
//     <OutDir>/dst/DST_<NNNNNN>.root   T_Singles + T_Muons + T_Info
//     <OutDir>/cache/                  서브런별 확장 캐시 (RenePrdSingles.h).
//                                      ibd-summary.sh 가 쓰는 cache/singles/
//                                      와는 **다른 자리다** -- 그쪽 캐시는
//                                      뮤온이 없어(§ RenePrdSingles.h 주석)
//                                      여기서 그대로 읽으면 carry 가 꼬인다.
//                                      이 자리는 이 매크로가 쓴 것만 있으므로
//                                      항상 세 트리(Singles/State/Muons)가
//                                      함께 있다.
//
//  ★ 스펙 §3 의 싱글별 dt_prev_muon 열은 저장하지 않는다 -- 샤워링 문턱이
//    파라미터라 뮤온 트리에서 그때그때 계산해야 맞고, 싱글에 박아 두면
//    문턱이 바뀔 때 낡는다. 스펙의 목적(레시피가 바뀌어도 PRD 재독 없음)은
//    뮤온 트리가 채운다. 스펙 대비 의도된 정련이다.
// ---------------------------------------------------------------------------
#include "RenePrdSingles.h"
#include <TStopwatch.h>
#include <ctime>

static bool DstUpToDate(const TString &path, int nSubNow) {
   if (gSystem->AccessPathName(path)) return false;
   TFile *f = TFile::Open(path, "READ");
   if (!f || f->IsZombie()) { if (f) f->Close(); return false; }
   TTree *ti = (TTree *)f->Get("T_Info");
   if (!ti || ti->GetEntries() < 1) { f->Close(); return false; }
   Int_t nsub = -1; ti->SetBranchAddress("n_subrun", &nsub); ti->GetEntry(0);
   f->Close();
   return nsub == nSubNow;      // 서브런이 늘었으면 다시 만든다
}

static void BuildOne(int run, const TString &out, const TString &roots,
                     double thr, double vetoCutUs, bool force, int maxSubrun) {
   TString runDir = ReneFindRunDir(run, roots);
   if (runDir.IsNull()) { printf("  [SKIP] run %d : PRD 없음\n", run); return; }
   std::vector<int> subs = ReneListSubruns(runDir, run);
   if (subs.empty())    { printf("  [SKIP] run %d : PRD 비었음\n", run); return; }
   if (maxSubrun >= 0)
      subs.erase(std::remove_if(subs.begin(), subs.end(),
                                [&](int x) { return x > maxSubrun; }), subs.end());

   TString dstDir = out + "dst/";      gSystem->mkdir(dstDir, kTRUE);
   TString cache  = out + "cache/";    gSystem->mkdir(cache,  kTRUE);
   TString dst = dstDir + TString::Format("DST_%s.root", ReneRunStr(run).Data());
   if (!force && DstUpToDate(dst, (int)subs.size())) {
      printf("  [OK]   run %d : DST 최신 (서브런 %zu)\n", run, subs.size()); return;
   }

   ReneCarry carry;
   std::vector<S1S2_Candidate> sing;
   std::vector<ReneMuon> muons;
   double liveS = 0; int nBad = 0, nRead = 0, nFromCache = 0;
   TStopwatch w; w.Start();

   for (int sub : subs) {
      TString cpath = ReneCachePath(cache, run, sub);
      ReneSubrunStat st;
      size_t sBefore = sing.size(), mBefore = muons.size();
      //  부분 캐시 히트(예: 뮤온 없는 옛 캐시)가 carry 를 전진시킨 채로 남으면 안 된다 -- 실패 시 되돌린다.
      ReneCarry saved = carry;
      bool ok = ReneLoadCache(cpath, thr, vetoCutUs, sing, carry, st) &&
                ReneLoadCacheMuons(cpath, muons);
      if (!ok) {
         //  둘 중 하나라도 없으면 파형에서 새로 만든다 (확장 캐시로 덮어씀)
         carry = saved;
         sing.resize(sBefore); muons.resize(mBefore);
         TString prd = TString::Format("%sPRD/PRD_%s.%05d.root",
                          runDir.Data(), ReneRunStr(run).Data(), sub);
         st = ReneProcessSubrun(prd, sub, thr, vetoCutUs, carry, sing, &muons);
         if (!st.ok) { printf("  [WARN] run %d sub %d 읽기 실패\n", run, sub);
                       nBad++; continue; }
         ReneSaveCache(cpath, thr, vetoCutUs, sing, sBefore, carry, st,
                       &muons, mBefore);
         nRead++;
      } else nFromCache++;
      liveS += st.liveSec;
   }
   w.Stop();

   //  임시 이름으로 쓰고 rename (RenePrdSingles.h 의 캐시와 같은 이유)
   TString tmp = dst + ".tmp";
   TFile *f = TFile::Open(tmp, "RECREATE");
   if (!f || f->IsZombie()) { printf("  [FAIL] run %d : DST 를 못 쓴다\n", run); return; }
   //  T_Singles : 런 전체, 시간 순 (sing 은 서브런 오름차순으로 이어 붙였고
   //  서브런 안에서도 시간 순이라 그대로 순서가 맞는다).
   TTree *tSing = new TTree("T_Singles", "clean singles, whole run, time order");
   Int_t    s_evt = 0, s_sub = 0;
   Double_t s_t   = 0;
   Float_t  s_pe  = 0;
   tSing->Branch("evt_id", &s_evt);
   tSing->Branch("sub_id", &s_sub);
   tSing->Branch("t_us",   &s_t);
   tSing->Branch("pe",     &s_pe);
   for (const auto &sc : sing) {
      s_evt = sc._evt_id; s_sub = sc._sub_id;
      s_t   = sc._t_us;   s_pe  = (Float_t)sc._pe_sum;
      tSing->Fill();
   }

   //  T_Muons : 런 전체, 시간 순. pe=-1 은 target 파형이 없는 순수 veto 뮤온.
   TTree *tMu = new TTree("T_Muons", "muon veto events, whole run, time order");
   Int_t    m_sub = 0;
   Double_t m_t   = 0;
   Float_t  m_pe  = -1;
   Char_t   m_sat = 0;
   tMu->Branch("sub_id", &m_sub);
   tMu->Branch("t_us",   &m_t);
   tMu->Branch("pe",     &m_pe);
   tMu->Branch("sat",    &m_sat);
   for (const auto &mc : muons) {
      m_sub = mc.sub; m_t = mc.t_us; m_pe = mc.pe; m_sat = mc.sat;
      tMu->Fill();
   }

   //  T_Info : 한 줄짜리 메타데이터. schema=1 은 이 스키마 세대의 번호다 --
   //  나중에 열이 바뀌면 읽는 쪽이 이 값으로 갈라 쓸 수 있다.
   TTree *tInfo = new TTree("T_Info", "DST build metadata (one entry)");
   Int_t    i_run = run, i_nsub = (Int_t)subs.size(), i_nbad = nBad, i_schema = 1;
   Double_t i_thr = thr, i_veto = vetoCutUs, i_live = liveS;
   Long64_t i_built = (Long64_t)time(nullptr);
   tInfo->Branch("run",      &i_run);
   tInfo->Branch("thr_npe",  &i_thr);
   tInfo->Branch("veto_us",  &i_veto);
   tInfo->Branch("n_subrun", &i_nsub);
   tInfo->Branch("n_bad",    &i_nbad);
   tInfo->Branch("live_s",   &i_live);
   tInfo->Branch("built",    &i_built);
   tInfo->Branch("schema",   &i_schema);
   tInfo->Fill();

   f->cd();
   tSing->Write();
   tMu->Write();
   tInfo->Write();
   f->Close();
   gSystem->Rename(tmp, dst);
   printf("  [DST]  run %d : singles %zu  muons %zu  live %.0f s  "
          "(캐시 %d / 새로 %d / 실패 %d)  [%.1f s]\n",
          run, sing.size(), muons.size(), liveS, nFromCache, nRead, nBad,
          w.RealTime());
}

void BuildMonitorDst(const char *runList, const char *outDir,
                     const char *rawRoots, double vetoCutUs = 150.0,
                     bool force = false, int maxSubrun = -1) {
   //  thr : BuildPairSummary.C 와 같은 계산이어야 캐시가 공유된다
   SetChannel(CH_NH);  double thrNH = std::min(S1_MIN_NPE, S2_MIN_NPE);
   SetChannel(CH_NGD); double thrGd = std::min(S1_MIN_NPE, S2_MIN_NPE);
   const double thr = std::min(thrNH, thrGd);
   TString out = outDir; if (!out.EndsWith("/")) out += "/";
   TString ls = runList;
   TObjArray *parts = ls.Tokenize(",");
   for (int i = 0; i < parts->GetEntries(); ++i) {
      int run = ((TObjString *)parts->At(i))->GetString().Atoi();
      if (run > 0) BuildOne(run, out, rawRoots, thr, vetoCutUs, force, maxSubrun);
   }
   delete parts;
}
