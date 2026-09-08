// ---------------------------------------------------------------------------
//  BuildMetrics.C - DST 에서 런 지표를 계산한다. PRD 는 읽지 않는다.
//  IBD/acci 는 legacy(BuildPairSummary)와 같은 값이어야 하며 metrics.sh
//  --verify 가 그것을 대조한다. Li/He·fast-n 은 Task 5 에서 채운다.
//
//  무엇을 읽나
//     <OutDir>/dst/DST_<NNNNNN>.root   (BuildMonitorDst.C 산출물)
//                                      T_Singles(evt_id/sub_id/t_us/pe)
//                                      T_Muons(sub_id/t_us/pe/sat)
//                                      T_Info(run/thr_npe/veto_us/n_subrun/
//                                             n_bad/live_s/built/schema)
//     <OutDir>/runtype.tsv             선원 정보. ibd-summary.sh 가 만든다
//                                      (없어도 죽지 않는다 -- src="?" 로 남는다)
//
//  무엇을 쓰나
//     <OutDir>/metrics_summary.tsv     schema 1. 열 순서는 WriteTsv 참조.
//                                      .txt 짝은 만들지 않는다 -- 웹이 표를
//                                      대신 그린다(BuildPairSummary.C 의
//                                      pair_summary.txt 와 다른 점).
//
//  ---- 페어링은 legacy 와 같은 것을 쓴다 ----
//  RenePairing.h::PairAndCountW 는 BuildPairSummary.C 의 PairAndCount 가
//  내부적으로 위임하는 바로 그 구현이다(Task 2). 다른 것은 입력뿐이다 --
//  legacy 는 PRD 를 그때그때 읽어 clean single 을 다시 만들고
//  (RenePrdSingles.h), 여기는 이미 만들어진 DST 의 T_Singles 를 그대로
//  읽는다. 두 경로가 같은 값을 내는지는 metrics.sh --verify 가
//  pair_summary.tsv 와 대조해서 확인한다(전환 게이트).
//
//  ---- Li/He·fast-n 은 아직이다 ----
//  n_lihe/e_lihe/lihe_stat 과 n_fn_side/n_fn_side_scaled/n_fn_mutag, 그리고
//  그 컷 값을 기록하는 열(mu_shower_npe/fn_e_lo/fn_e_hi/fn_tag_s/
//  lihe_fit_lo/lihe_fit_hi)까지 전부 MetRow 의 기본값(-1/"off") 그대로
//  둔다 -- 여기서 다시 대입하지 않는다. 매크로 인자로는 받아 두어 Task 5 가
//  시그니처를 바꾸지 않고 채울 수 있게 한다.
// ---------------------------------------------------------------------------
#include "RenePrdSingles.h"     // S1S2_Candidate, SetChannel, ChannelTag
#include "RenePairing.h"
#include <cstdlib>              // std::atoi (LoadExisting 의 schema 파싱)
#include <fstream>
#include <map>
#include <sstream>
#include <TStopwatch.h>

//  tsv 스키마가 바뀌면 올린다. 옛 파일을 조용히 잘못 읽는 것보다
//  못 읽는다고 말하는 편이 낫다 (BuildPairSummary.C 와 같은 규칙).
static const int kMetricsSchema = 1;

struct MetRow {                 // 열 순서는 WriteTsv 와 같아야 한다
   int run = 0; std::string tag, src = "?", liheStat = "off";
   double liveS = -1, rll = -1;
   long long nPaired=-1,nPairedAcci=-1,nIbd=-1,nIbdAcci=-1,nSingle=-1;
   int nSubrun=-1; long long nMu=-1,nMuShower=-1;
   double nLihe=-1,eLihe=-1; long long nFnSide=-1; double nFnSideScaled=-1;
   long long nFnMutag=-1;
   double dtMin=-1,dtMax=-1,dtAcci=-1,s2Lo=-1,s2Hi=-1,isoPre=-1,isoPost=-1;
   double muShowerNpe=-1,fnELo=-1,fnEHi=-1,fnTagS=-1,liheFitLo=-1,liheFitHi=-1;
};

static bool LoadDst(const TString &dst, std::vector<S1S2_Candidate> &sing,
                    std::vector<ReneMuon> &mu, double &liveS, int &nSubrun) {
   TFile *f = TFile::Open(dst, "READ");
   if (!f || f->IsZombie()) { if (f) f->Close(); return false; }
   TTree *tS = (TTree *)f->Get("T_Singles");
   TTree *tM = (TTree *)f->Get("T_Muons");
   TTree *tI = (TTree *)f->Get("T_Info");
   if (!tS || !tM || !tI || tI->GetEntries() < 1) { f->Close(); return false; }
   Int_t s_evt, s_sub; Double_t s_t; Float_t s_pe;
   tS->SetBranchAddress("evt_id", &s_evt); tS->SetBranchAddress("sub_id", &s_sub);
   tS->SetBranchAddress("t_us", &s_t);     tS->SetBranchAddress("pe", &s_pe);
   for (Long64_t i = 0; i < tS->GetEntries(); ++i) {
      tS->GetEntry(i); sing.push_back({s_evt, s_sub, s_t, (double)s_pe});
   }
   Int_t m_sub; Double_t m_t; Float_t m_pe; Char_t m_sat;
   tM->SetBranchAddress("sub_id", &m_sub); tM->SetBranchAddress("t_us", &m_t);
   tM->SetBranchAddress("pe", &m_pe);      tM->SetBranchAddress("sat", &m_sat);
   for (Long64_t i = 0; i < tM->GetEntries(); ++i) {
      tM->GetEntry(i); mu.push_back({m_sub, m_t, m_pe, m_sat});
   }
   Int_t i_nsub; Double_t i_live;
   tI->SetBranchAddress("n_subrun", &i_nsub); tI->SetBranchAddress("live_s", &i_live);
   tI->GetEntry(0); nSubrun = i_nsub; liveS = i_live;
   f->Close(); return true;
}

//  runtype.tsv : "<run>\t<src>" 두 열. BuildPairSummary.C 의 LoadRunTypes 를
//  그대로 옮겨 적었다 -- 두 표가 같은 파일을 같은 규칙으로 읽어야 한다.
static std::map<int, std::string> LoadRunTypes(const TString &tsv) {
   std::map<int, std::string> out;
   std::ifstream in(tsv.Data());
   if (!in) return out;
   std::string line;
   while (std::getline(in, line)) {
      if (line.empty() || line[0] == '#') continue;
      std::stringstream ss(line);
      int run; std::string src;
      if (!(ss >> run >> src)) continue;
      out[run] = src;
   }
   return out;
}

// ---------------------------------------------------------------------------
static std::string RowKey(int run, const std::string &tag) {
   char b[32]; snprintf(b, sizeof(b), "%06d", run);
   return std::string(b) + tag;
}

//  tsv 전용. 항상 고정 소수 자릿수로 낸다 (BuildPairSummary.C 의 FmtRaw 와
//  같다). '-' 같은 표시용 텍스트를 쓰면 되읽기의 >> 가 실패해 그 행이
//  통째로 사라진다.
static std::string FmtRaw(double v, int prec) {
   char b[64]; snprintf(b, sizeof(b), "%.*f", prec, v); return std::string(b);
}

//  옛 스키마는 열이 다르다. 조용히 잘못 읽지 않고 버린다.
static std::map<std::string, MetRow> LoadExisting(const TString &tsv, bool &schemaOld) {
   std::map<std::string, MetRow> out;
   schemaOld = false;
   std::ifstream in(tsv.Data());
   if (!in) return out;
   int schema = 1;
   std::string line;
   while (std::getline(in, line)) {
      if (line.rfind("# schema", 0) == 0) { schema = std::atoi(line.c_str() + 8); continue; }
      if (line.empty() || line[0] == '#') continue;
      if (schema != kMetricsSchema) { schemaOld = true; return {}; }
      std::stringstream ss(line);
      MetRow r;
      // 열 순서는 WriteTsv 와 반드시 같아야 한다
      if (!(ss >> r.run >> r.tag >> r.src >> r.liveS
               >> r.nPaired >> r.nPairedAcci >> r.nIbd >> r.nIbdAcci
               >> r.nSingle >> r.rll >> r.nSubrun
               >> r.nMu >> r.nMuShower
               >> r.nLihe >> r.eLihe >> r.liheStat
               >> r.nFnSide >> r.nFnSideScaled >> r.nFnMutag
               >> r.dtMin >> r.dtMax >> r.dtAcci
               >> r.s2Lo >> r.s2Hi >> r.isoPre >> r.isoPost
               >> r.muShowerNpe >> r.fnELo >> r.fnEHi >> r.fnTagS
               >> r.liheFitLo >> r.liheFitHi))
         continue;
      out[RowKey(r.run, r.tag)] = r;
   }
   return out;
}

static void WriteTsv(const TString &path, const std::map<std::string, MetRow> &rows) {
   std::ofstream o(path.Data());
   o << "# RENE run metrics (machine readable). BuildMetrics.C 가 만든다. DST 입력.\n"
        "# schema " << kMetricsSchema << "\n"
        "#run\ttag\tsrc\tlive_s\tn_paired\tn_paired_acci\tn_ibd\tn_ibd_acci"
        "\tn_single\tr_ll\tn_subrun\tn_mu\tn_mu_shower\tn_lihe\te_lihe\tlihe_stat"
        "\tn_fn_side\tn_fn_side_scaled\tn_fn_mutag"
        "\tdt_min\tdt_max\tdt_acci\ts2_lo\ts2_hi\tiso_pre\tiso_post"
        "\tmu_shower_npe\tfn_e_lo\tfn_e_hi\tfn_tag_s\tlihe_fit_lo\tlihe_fit_hi\n";
   for (const auto &kv : rows) {
      const MetRow &r = kv.second;
      o << r.run << '\t' << r.tag << '\t' << r.src << '\t' << FmtRaw(r.liveS, 3) << '\t'
        << r.nPaired << '\t' << r.nPairedAcci << '\t' << r.nIbd << '\t' << r.nIbdAcci << '\t'
        << r.nSingle << '\t' << FmtRaw(r.rll, 4) << '\t' << r.nSubrun << '\t'
        << r.nMu << '\t' << r.nMuShower << '\t'
        << FmtRaw(r.nLihe, 3) << '\t' << FmtRaw(r.eLihe, 3) << '\t' << r.liheStat << '\t'
        << r.nFnSide << '\t' << FmtRaw(r.nFnSideScaled, 3) << '\t' << r.nFnMutag << '\t'
        << r.dtMin << '\t' << r.dtMax << '\t' << r.dtAcci << '\t'
        << r.s2Lo << '\t' << r.s2Hi << '\t' << r.isoPre << '\t' << r.isoPost << '\t'
        << r.muShowerNpe << '\t' << r.fnELo << '\t' << r.fnEHi << '\t' << r.fnTagS << '\t'
        << r.liheFitLo << '\t' << r.liheFitHi << '\n';
   }
}

// ---------------------------------------------------------------------------
static void Impl(const std::vector<int> &runs, const TString &out,
                 double muShowerNpe, double liheFitLoS, double liheFitHiS,
                 int liheMinCand, double fnELoMev, double fnEHiMev,
                 double fnTagS, bool force) {
   TString tsvPath = out + "metrics_summary.tsv";

   bool schemaOld = false;
   std::map<std::string, MetRow> rows = LoadExisting(tsvPath, schemaOld);
   if (schemaOld) {
      printf("[WARN] 기존 metrics_summary.tsv 가 옛 스키마다. 버리고 새로 만든다.\n");
   }
   printf("[INFO] 기존 metrics_summary : %zu 행 (%s)\n", rows.size(), tsvPath.Data());
   printf("[INFO] 입력 : %sdst/DST_<run>.root\n", out.Data());

   std::map<int, std::string> rtype = LoadRunTypes(out + "runtype.tsv");
   printf("[INFO] 선원 정보를 아는 런 : %zu 개 (runtype.tsv)\n", rtype.size());
   if (rtype.empty())
      printf("[WARN] runtype.tsv 가 없다. 선원 런을 구분할 수 없어 src 가 "
             "'?' 로 남는다 -- ibd-summary.sh 를 한 번 돌리면 생긴다\n");

   //  Li/He·fast-n 은 이번 버전에서 계산하지 않는다(자리만 -1/off). 인자는
   //  Task 5 가 시그니처를 바꾸지 않고 실제로 쓸 수 있도록 받아만 둔다.
   printf("[INFO] Li/He·fast-n 컷 (미적용, Task 5 예정) : muShowerNpe=%.1f "
          "liheFit=[%.3f,%.1f]s liheMinCand=%d fnE=[%.2f,%.2f]MeV fnTagS=%.2fs\n",
          muShowerNpe, liheFitLoS, liheFitHiS, liheMinCand, fnELoMev, fnEHiMev, fnTagS);

   const Channel chans[2] = {CH_NGD, CH_NH};
   int nNew = 0, nSkip = 0, nMiss = 0;
   for (int run : runs) {
      //  두 태그 모두 이미 있으면 DST 를 아예 열지 않는다 -- BuildPairSummary.C
      //  의 haveAll 과 같은 이유다. DST 는 서브런 하나짜리 캐시보다 훨씬
      //  커서(24h 런이면 뮤온만 수천만 건) 다시 읽을 이유가 없으면 안 읽는다.
      bool haveAll = true;
      for (Channel ch : chans) {
         SetChannel(ch);
         if (!rows.count(RowKey(run, ChannelTag(ch).Data()))) haveAll = false;
      }
      if (!force && haveAll) { nSkip += 2; continue; }

      TString dst = out + TString::Format("dst/DST_%s.root", ReneRunStr(run).Data());
      std::vector<S1S2_Candidate> sing; std::vector<ReneMuon> mu;
      double liveS = 0; int nSubrun = 0;
      TStopwatch w; w.Start();
      if (!LoadDst(dst, sing, mu, liveS, nSubrun)) {
         printf("  [SKIP] run %d : DST 없음 (dst-build.sh 먼저)\n", run);
         nMiss++;
         continue;
      }
      w.Stop();
      printf("  run %d : DST 로드 singles=%zu muons=%zu live=%.1fs subrun=%d  [%.1f s]\n",
             run, sing.size(), mu.size(), liveS, nSubrun, w.RealTime());

      for (Channel ch : chans) {
         SetChannel(ch);
         std::string tag = ChannelTag(ch).Data();
         std::string key = RowKey(run, tag);
         if (!force && rows.count(key)) { nSkip++; continue; }

         PairWindows w2 = CurrentPairWindows();
         std::vector<double> promptT;
         PairCounts pc = PairAndCountW(sing, w2, &promptT);

         MetRow r;
         r.run = run; r.tag = tag;
         r.liveS = liveS;
         r.nPaired = pc.nCoinc;     r.nPairedAcci = pc.nAcci;
         r.nIbd    = pc.nCoincMult; r.nIbdAcci    = pc.nAcciMult;
         r.nSingle = (long long)sing.size();
         r.rll     = (liveS > 0) ? (double)sing.size() / liveS : -1;
         r.nSubrun = nSubrun;
         r.nMu     = (long long)mu.size();
         r.dtMin = w2.dtMin; r.dtMax = w2.dtMax; r.dtAcci = w2.dtAcci;
         //  s2_lo/s2_hi 는 MeV 단위다 (w2.s2lo/s2hi 는 NPE). BuildPairSummary.C
         //  와 똑같이, SetChannel() 이 채운 전역을 그대로 읽는다.
         r.s2Lo = S2_E_MIN_MEV; r.s2Hi = S2_E_MAX_MEV;
         r.isoPre = w2.isoPre; r.isoPost = w2.isoPost;
         auto ir = rtype.find(run);
         if (ir != rtype.end()) r.src = ir->second;
         //  Li/He·fast-n 열(과 그 컷 값 열)은 MetRow 의 기본값 -1/"off" 그대로
         //  둔다 -- Task 5 가 채운다.

         bool replaced = rows.count(key) > 0;
         rows[key] = r;
         nNew++;
         printf("  [%s] run %d%-5s : paired=%lld  ibd=%lld  acci=%lld  "
                "single=%lld  live=%.1fs  r_ll=%.2fHz\n",
                replaced ? "REDO" : " NEW", run, tag.c_str(),
                r.nPaired, r.nIbd, r.nIbdAcci, r.nSingle, r.liveS, r.rll);
      }
      //  런 하나가 몇 분 걸릴 수 있다. 중간에 끊겨도 한 것은 남도록 그때그때
      //  쓴다 (BuildRunSummary.C/BuildPairSummary.C 와 같은 이유).
      WriteTsv(tsvPath, rows);
   }

   //  이미 있던 행에 선원이 새로 생겼으면 채워 준다.
   int nFilled = 0;
   for (auto &kv : rows) {
      if (kv.second.src != "?") continue;
      auto ir = rtype.find(kv.second.run);
      if (ir != rtype.end()) { kv.second.src = ir->second; nFilled++; }
   }
   if (nFilled > 0) printf("[INFO] 선원을 새로 채운 행 : %d\n", nFilled);

   if (nNew == 0 && nFilled == 0 && !schemaOld) {
      printf("[INFO] 새로 더한 것이 없다 (건너뜀 %d, 자료 없음 %d). 파일은 그대로 둔다.\n",
             nSkip, nMiss);
      return;
   }
   WriteTsv(tsvPath, rows);
   printf("[SAVED] %s\n", tsvPath.Data());
   printf("[DONE ] 새로/다시 쓴 행 %d, 선원 보충 %d, 건너뜀 %d, 자료 없음 %d, 표에 %zu 행\n",
          nNew, nFilled, nSkip, nMiss, rows.size());
}

// ---------------------------------------------------------------------------
//  runList : ',' 로 나눈 목록 (dst-build.sh/BuildMonitorDst.C 와 같은 꼴).
//  muShowerNpe..fnTagS : Li/He·fast-n 컷. 이번 버전은 쓰지 않지만 Task 5 가
//  시그니처를 바꾸지 않고 채울 수 있도록 자리를 잡아 둔다.
void BuildMetrics(const char *runList, const char *outDir, double muShowerNpe,
                  double liheFitLoS, double liheFitHiS, int liheMinCand,
                  double fnELoMev, double fnEHiMev, double fnTagS,
                  bool force = false) {
   TString out(outDir);
   if (!out.EndsWith("/")) out += "/";
   if (gSystem->mkdir(out, kTRUE) != 0 && gSystem->AccessPathName(out, kWritePermission)) {
      printf("[FATAL] 출력 디렉터리에 쓸 수 없다 : %s\n", out.Data());
      return;
   }
   TString ls = runList;
   TObjArray *parts = ls.Tokenize(",");
   std::vector<int> runs;
   for (int i = 0; i < parts->GetEntries(); ++i) {
      int run = ((TObjString *)parts->At(i))->GetString().Atoi();
      if (run > 0) runs.push_back(run);
   }
   delete parts;
   if (runs.empty()) { printf("[FATAL] 런 목록이 비어 있다\n"); return; }
   Impl(runs, out, muShowerNpe, liheFitLoS, liheFitHiS, liheMinCand,
        fnELoMev, fnEHiMev, fnTagS, force);
}
