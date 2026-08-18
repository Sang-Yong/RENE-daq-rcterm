// ---------------------------------------------------------------------------
//  BuildRunSummary.C - production 을 마친 런의 PRD 파일에서 직접 DAQ 운용
//                      지표를 뽑아 run_summary 로 누적한다.
//
//  무엇을 읽나  ★ production 산출물이 정본이다
//     <root>/<NNNNNN>/PRD/PRD_<NNNNNN>.<SSSSS>.root  : TTree "Event"
//     root 는 ':' 로 나눈 목록을 앞에서부터 찾는다. dataflow 가 런을 옮기므로
//     한 곳만 보면 놓친다 -- 기본 /Data_ssd/RAW:/data/RAW:/scratch/RAW.
//        TCBTRGTime  [ns]  TCB 트리거 시각 (되감긴다. 아래 참조)
//        EventType   1 = target only (FADC)
//                    2 = veto only   (SADC)
//                    3 = both
//     서브런의 수집 시각은 같은 런 디렉터리의 원시 FADC 파일 mtime 을 쓴다.
//        <RawDir>/<NNNNNN>/FADC_<NNNNNN>.root.<SSSSS>
//
//  무엇을 쓰나
//     <OutDir>/run_summary.txt   사람이 읽는 고정폭 표 (정본)
//     <OutDir>/run_summary.tsv   되읽기·그림용 탭 구분 표
//
//  이미 있는 런은 건너뛰고 새 런만 이어붙인다(force 로 다시 씀).
//
//  ---- EventType 의 뜻은 추측이 아니라 실측으로 확인했다 ----
//     run 4237 서브런 101 에서
//        EventType==1 : 10,918 개 중 F_Triggered>0 이 10,918
//        EventType==2 : 51,738 개 중 S_Triggered>0 이 51,738
//        EventType==3 : 381 개, 양쪽 다 켜져 있음
//     따라서 total = t1+t2+t3, target = t1+t3, veto = t2+t3, both = t3.
//
//  ---- TCBTRGTime 은 되감긴다. 풀어야 livetime 이 나온다 ----
//  TCB 시계는 약 16.78초(2^24 x 1000 ns)마다 0 으로 돌아간다. 60초짜리 서브런
//  하나에 서너 번 감긴다. AnalysisStep1.C 가 쓰는 규칙을 그대로 따른다 --
//
//        if (t < prev) offset += prev;      globalTime = t + offset
//
//  풀지 않으면 livetime 이 음수가 되거나 16초로 나온다. 실측 확인 :
//  run 4237 서브런 101 에서 이 규칙으로 59.907 s -- 60초 서브런과 맞는다.
//  carry 는 **런 전체에 걸쳐** 이어 간다. 그래야 서브런 사이의 빈 시간(dead)
//  까지 한 시간축에서 잰다.
//
//  ---- 파일에 TTree cycle 이 여러 개 있다 ----
//  PRD 파일에는 Event;2, Event;3 처럼 cycle 이 여럿 있다(생산 중 autosave).
//  TFile::Get("Event") 는 가장 높은 cycle 을 준다. 그것이 완전한 것이므로
//  **cycle 을 더하면 안 된다.** 더하면 이벤트를 두 번 센다.
//
//  사용 :
//     root -l -b -q 'BuildRunSummary.C+(4237, 4240)'         범위
//     root -l -b -q 'BuildRunSummary.C+("4237,4239")'        목록
//     root -l -b -q 'BuildRunSummary.C+(4237, 4240, true)'   이미 있어도 다시
//  경로를 바꾸려면 :
//     root -l -b -q 'BuildRunSummary.C+(4237,4240,false,"/scratch/RunSummary/","/scratch/RAW")'
// ---------------------------------------------------------------------------
#include <TFile.h>
#include <TKey.h>
#include <TObjString.h>
#include <TSystem.h>
#include <TSystemDirectory.h>
#include <TString.h>
#include <TTree.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

//  tsv 스키마가 바뀌면 이 번호를 올린다. 옛 파일을 조용히 잘못 읽는 것보다
//  못 읽는다고 말하는 편이 낫다.
static const int kSchema = 2;

// ---------------------------------------------------------------------------
struct RunSummaryRow {
   int      run        = 0;
   int      nSubrun    = 0;      // PRD 파일이 실제로 있던 서브런 수
   int      nBadSubrun = 0;      // 열리지 않거나 Event 트리가 없던 것
   double   epochStart = -1;     // 첫 서브런 수집 시각 [Unix s]
   double   epochEnd   = -1;
   double   wallSec    = -1;     // epochEnd - epochStart (파일 시각 기준)
   double   spanSec    = -1;     // TCB 시각으로 첫 트리거 ~ 마지막 트리거
   double   liveSec    = 0;      // Σ 서브런 livetime
   double   deadSec    = -1;     // spanSec - liveSec (서브런 사이의 빈 시간)
   long long nType1 = 0, nType2 = 0, nType3 = 0;   // target only / veto only / both
   std::string source = "prd";

   long long nEvents() const { return nType1 + nType2 + nType3; }
   long long nTarget() const { return nType1 + nType3; }
   long long nVeto()   const { return nType2 + nType3; }
   long long nBoth()   const { return nType3; }
   double duty() const { return (spanSec > 0) ? liveSec / spanSec : -1; }
   double rate(long long n) const { return liveSec > 0 ? (double)n / liveSec : -1; }
};

// ---------------------------------------------------------------------------
static TString RunStr(int run) { return TString::Format("%06d", run); }

static std::string FmtEpoch(double e) {
   if (e <= 0) return "-";
   time_t t = (time_t)e; struct tm tmv; localtime_r(&t, &tmv);
   char b[32]; strftime(b, sizeof(b), "%Y-%m-%d %H:%M:%S", &tmv);
   return std::string(b);
}
static std::string FmtCount(long long v) {
   if (v < 0) return "-";
   std::string s = std::to_string(v);
   for (int i = (int)s.size() - 3; i > 0; i -= 3) s.insert(i, ",");
   return s;
}
//  txt 용. 값이 없으면 '-'.
static std::string FmtF(double v, int prec) {
   if (v < 0) return "-";
   char b[64]; snprintf(b, sizeof(b), "%.*f", prec, v); return std::string(b);
}
//  tsv 용. 항상 숫자를 낸다. '-' 를 쓰면 되읽기의 >> 가 실패해 그 행이
//  통째로 사라진다 -- 실제로 그렇게 행을 잃은 적이 있다.
static std::string FmtRaw(double v, int prec) {
   char b[64]; snprintf(b, sizeof(b), "%.*f", prec, v); return std::string(b);
}

static std::vector<int> ParseRunList(const char *s) {
   std::vector<int> out;
   std::stringstream ss(s ? s : "");
   std::string tok;
   while (std::getline(ss, tok, ',')) {
      size_t a = tok.find_first_not_of(" \t");
      if (a == std::string::npos) continue;
      size_t b = tok.find_last_not_of(" \t");
      tok = tok.substr(a, b - a + 1);
      if (tok.empty()) continue;
      size_t dash = tok.find('-');
      if (dash != std::string::npos && dash > 0) {
         int lo = std::atoi(tok.substr(0, dash).c_str());
         int hi = std::atoi(tok.substr(dash + 1).c_str());
         for (int r = lo; r <= hi; ++r) out.push_back(r);
      } else out.push_back(std::atoi(tok.c_str()));
   }
   return out;
}

// ---------------------------------------------------------------------------
//  PRD 디렉터리에서 서브런 번호를 모은다.
static std::vector<int> ListSubruns(const TString &prdDir, const TString &runS) {
   std::vector<int> out;
   TSystemDirectory d("prd", prdDir);
   TList *files = d.GetListOfFiles();
   if (!files) return out;
   TString pref = "PRD_" + runS + ".";
   TIter it(files);
   TSystemFile *sf;
   while ((sf = (TSystemFile *)it())) {
      if (sf->IsDirectory()) continue;
      TString nm = sf->GetName();
      if (!nm.BeginsWith(pref) || !nm.EndsWith(".root")) continue;
      TString num = nm(pref.Length(), nm.Length() - pref.Length() - 5);
      if (num.IsDigit()) out.push_back(num.Atoi());
   }
   delete files;
   std::sort(out.begin(), out.end());
   return out;
}

static double FileEpoch(const TString &path) {
   Long64_t size; Long_t id, flags, modtime;
   if (gSystem->GetPathInfo(path, &id, &size, &flags, &modtime) != 0) return -1;
   return (double)modtime;
}

// ---------------------------------------------------------------------------
//  런 디렉터리를 여러 root 에서 찾는다. 앞에 오는 것이 이긴다.
//  dataflow 가 런을 /Data_ssd -> /data -> /scratch 로 흘려보내므로 한 곳만
//  보면 옮겨진 런을 놓친다. 앞쪽이 빠른 디스크라 속도에서도 유리하다
//  (실측 : 같은 서브런이 로컬 NVMe 1.1 s, /scratch 14.6 s).
static TString FindRunDir(int run, const TString &roots) {
   TString runS = RunStr(run);
   TObjArray *parts = TString(roots).Tokenize(":");
   TString found = "";
   for (int i = 0; i < parts->GetEntries(); ++i) {
      TString r = ((TObjString *)parts->At(i))->GetString().Strip(TString::kBoth);
      if (r.IsNull()) continue;
      if (!r.EndsWith("/")) r += "/";
      if (!gSystem->AccessPathName(r + runS + "/PRD/")) { found = r + runS + "/"; break; }
   }
   delete parts;
   return found;
}

//  FADC 원시 파일을 모든 root 에서 찾아 mtime 을 준다. 없으면 -1.
static double FileEpochAnyRoot(const TString &runS, int sid, const TString &roots) {
   TObjArray *parts = TString(roots).Tokenize(":");
   double ep = -1;
   for (int i = 0; i < parts->GetEntries() && ep <= 0; ++i) {
      TString r = ((TObjString *)parts->At(i))->GetString().Strip(TString::kBoth);
      if (r.IsNull()) continue;
      if (!r.EndsWith("/")) r += "/";
      ep = FileEpoch(TString::Format("%s%s/FADC_%s.root.%05d",
                                     r.Data(), runS.Data(), runS.Data(), sid));
   }
   delete parts;
   return ep;
}

static bool BuildOneRun(int run, const TString &roots, RunSummaryRow &row) {
   TString runS  = RunStr(run);
   TString rdir  = FindRunDir(run, roots);
   if (rdir.IsNull()) {
      printf("  [SKIP] run %d : PRD 디렉터리를 못 찾았다 (%s 아래)\n", run, roots.Data());
      return false;
   }
   TString pdir  = rdir + "PRD/";
   std::vector<int> subs = ListSubruns(pdir, runS);
   if (subs.empty()) {
      printf("  [SKIP] run %d : PRD 파일이 없다\n", run);
      return false;
   }

   row = RunSummaryRow();
   row.run = run;

   //  carry 는 런 전체에 이어 간다. 서브런마다 초기화하면 서브런 사이의
   //  빈 시간을 잴 수 없다.
   double prev = -1, off = 0;
   double runFirst = -1, runLast = 0;

   const int nAll = (int)subs.size();
   for (int k = 0; k < nAll; ++k) {
      int sid = subs[k];
      TString p = TString::Format("%sPRD_%s.%05d.root", pdir.Data(), runS.Data(), sid);
      TFile *f = TFile::Open(p, "READ");
      if (!f || f->IsZombie()) { if (f) f->Close(); row.nBadSubrun++; continue; }
      //  가장 높은 cycle 을 준다. cycle 을 더하면 두 번 세게 된다.
      TTree *t = (TTree *)f->Get("Event");
      if (!t || !t->GetBranch("TCBTRGTime") || !t->GetBranch("EventType")) {
         f->Close(); row.nBadSubrun++; continue;
      }
      //  필요한 가지만 켠다. 파형까지 읽으면 100배 느려진다.
      t->SetBranchStatus("*", 0);
      t->SetBranchStatus("TCBTRGTime", 1);
      t->SetBranchStatus("EventType", 1);
      Double_t tt = 0; Int_t et = 0;
      t->SetBranchAddress("TCBTRGTime", &tt);
      t->SetBranchAddress("EventType", &et);

      double subFirst = -1, subLast = 0;
      Long64_t n = t->GetEntries();
      for (Long64_t i = 0; i < n; ++i) {
         t->GetEntry(i);
         if (prev >= 0 && tt < prev) off += prev;   // AnalysisStep1.C 와 같은 규칙
         double g = tt + off;
         prev = tt;
         if (subFirst < 0) subFirst = g;
         subLast = g;
         if (runFirst < 0) runFirst = g;
         runLast = g;
         if      (et == 1) row.nType1++;
         else if (et == 2) row.nType2++;
         else if (et == 3) row.nType3++;
      }
      if (subFirst >= 0 && subLast > subFirst) row.liveSec += (subLast - subFirst) * 1e-9;
      row.nSubrun++;
      f->Close();

      //  수집 시각은 원시 FADC 파일 mtime. 없으면 PRD 파일 mtime 으로 대신한다.
      //  RAW 와 PRD 가 서로 다른 디스크에 있을 수 있다(예전 --outroot 구성은
      //  RAW 가 /scratch, PRD 가 /Data_ssd 다). 그래서 FADC 는 root 전체에서
      //  찾는다 -- 못 찾아 PRD mtime 으로 떨어지면 런마다 기준이 달라져
      //  추이 그림의 x축이 어긋난다.
      double ep = FileEpochAnyRoot(runS, sid, roots);
      if (ep <= 0) ep = FileEpoch(p);
      if (ep > 0) {
         if (row.epochStart < 0 || ep < row.epochStart) row.epochStart = ep;
         if (ep > row.epochEnd) row.epochEnd = ep;
      }

      if (nAll > 50 && (k % (nAll / 20 ? nAll / 20 : 1) == 0)) {
         printf("\r    run %d : %d/%d 서브런 ...", run, k + 1, nAll);
         fflush(stdout);
      }
   }
   if (nAll > 50) printf("\r%60s\r", "");

   if (row.nSubrun == 0) {
      printf("  [SKIP] run %d : 읽을 수 있는 PRD 가 하나도 없다\n", run);
      return false;
   }
   if (runFirst >= 0 && runLast > runFirst) row.spanSec = (runLast - runFirst) * 1e-9;
   if (row.spanSec > 0) row.deadSec = std::max(0.0, row.spanSec - row.liveSec);
   if (row.epochStart > 0 && row.epochEnd > 0) row.wallSec = row.epochEnd - row.epochStart;
   return true;
}

// ---------------------------------------------------------------------------
static std::map<int, RunSummaryRow> LoadExisting(const TString &tsv, bool &schemaOk) {
   std::map<int, RunSummaryRow> out;
   schemaOk = true;
   std::ifstream in(tsv.Data());
   if (!in) return out;
   std::string line;
   int seen = -1;
   while (std::getline(in, line)) {
      if (line.rfind("# schema ", 0) == 0) { seen = std::atoi(line.c_str() + 9); continue; }
      if (line.empty() || line[0] == '#') continue;
      if (seen != kSchema) { schemaOk = false; return {}; }
      std::stringstream ss(line);
      RunSummaryRow r; std::string src;
      if (!(ss >> r.run >> r.nSubrun >> r.nBadSubrun >> r.epochStart >> r.epochEnd
               >> r.wallSec >> r.spanSec >> r.liveSec >> r.deadSec
               >> r.nType1 >> r.nType2 >> r.nType3 >> src)) continue;
      r.source = src;
      out[r.run] = r;
   }
   if (seen != kSchema && seen != -1) schemaOk = false;
   return out;
}

static void WriteTsv(const TString &path, const std::map<int, RunSummaryRow> &rows) {
   std::ofstream o(path.Data());
   o << "# RENE DAQ run summary (machine readable). BuildRunSummary.C 가 만든다.\n"
        "# schema " << kSchema << "\n"
        "# 입력은 production 산출물 <RawDir>/<run>/PRD/PRD_<run>.<sub>.root 다.\n"
        "# 음수는 '그 정보 없음'. 시각 [Unix s], 시간 [s].\n"
        "# n_type1 = target only(FADC), n_type2 = veto only(SADC), n_type3 = both\n"
        "#run\tn_subrun\tn_bad\tepoch_start\tepoch_end\twall_s\tspan_s\tlive_s\tdead_s"
        "\tn_type1\tn_type2\tn_type3\tsource\n";
   for (const auto &kv : rows) {
      const RunSummaryRow &r = kv.second;
      o << r.run << '\t' << r.nSubrun << '\t' << r.nBadSubrun << '\t'
        << (long long)r.epochStart << '\t' << (long long)r.epochEnd << '\t'
        << FmtRaw(r.wallSec, 3) << '\t' << FmtRaw(r.spanSec, 3) << '\t'
        << FmtRaw(r.liveSec, 3) << '\t' << FmtRaw(r.deadSec, 3) << '\t'
        << r.nType1 << '\t' << r.nType2 << '\t' << r.nType3 << '\t'
        << r.source << '\n';
   }
}

static void WriteTxt(const TString &path, const std::map<int, RunSummaryRow> &rows) {
   std::ofstream o(path.Data());
   time_t now = time(nullptr); struct tm tmv; localtime_r(&now, &tmv);
   char nowbuf[32]; strftime(nowbuf, sizeof(nowbuf), "%Y-%m-%d %H:%M:%S", &tmv);

   o << "===============================================================================\n"
        "  RENE DAQ run summary   (입력 : production 산출물 PRD)\n"
        "  " << nowbuf << " 갱신 · BuildRunSummary.C 생성 · 런 " << rows.size() << "개\n"
        "===============================================================================\n"
        "  livetime  = 서브런마다 (마지막 트리거 - 첫 트리거) 를 더한 값.\n"
        "              TCB 시각을 되감김까지 풀어서 잰다\n"
        "  span      = 런의 첫 트리거부터 마지막 트리거까지 (같은 시간축)\n"
        "  dead      = span - livetime. 서브런 사이의 빈 시간이다\n"
        "  duty      = livetime / span. 1 에 가까울수록 빈 시간이 없다\n"
        "  DAQ start = 첫 서브런의 원시 FADC 파일 mtime (닫힌 시각에 가깝다)\n"
        "  bad       = 열리지 않거나 Event 트리가 없던 서브런 수\n\n";

   o << "-- 런별 -----------------------------------------------------------------------\n";
   char hdr[512];
   snprintf(hdr, sizeof(hdr), "%-7s %-19s %8s %5s %12s %12s %7s %10s\n",
            "run", "DAQ start", "subrun", "bad", "live[s]", "span[s]", "duty", "dead[s]");
   o << hdr;
   for (const auto &kv : rows) {
      const RunSummaryRow &r = kv.second;
      char b[512];
      snprintf(b, sizeof(b), "%-7d %-19s %8d %5d %12s %12s %7s %10s\n",
               r.run, FmtEpoch(r.epochStart).c_str(), r.nSubrun, r.nBadSubrun,
               FmtF(r.liveSec, 1).c_str(), FmtF(r.spanSec, 1).c_str(),
               FmtF(r.duty(), 4).c_str(), FmtF(r.deadSec, 1).c_str());
      o << b;
   }

   o << "\n-- 종류별 이벤트 수 (PRD 의 EventType) ----------------------------------------\n"
        "   EventType 1 = target only (FADC 만)   2 = veto only (SADC 만)   3 = both\n"
        "   total  = 1+2+3      target = 1+3      veto = 2+3      both = 3\n"
        "   (실측 확인 : type1 은 전부 F_Triggered>0, type2 는 전부 S_Triggered>0)\n";
   snprintf(hdr, sizeof(hdr), "%-7s %15s %15s %15s %15s %13s\n",
            "run", "total", "tgt_only", "veto_only", "both", "target");
   o << hdr;
   for (const auto &kv : rows) {
      const RunSummaryRow &r = kv.second;
      char b[512];
      snprintf(b, sizeof(b), "%-7d %15s %15s %15s %15s %13s\n",
               r.run, FmtCount(r.nEvents()).c_str(), FmtCount(r.nType1).c_str(),
               FmtCount(r.nType2).c_str(), FmtCount(r.nType3).c_str(),
               FmtCount(r.nTarget()).c_str());
      o << b;
   }

   o << "\n-- 계수율 [Hz] (livetime 기준) ------------------------------------------------\n";
   snprintf(hdr, sizeof(hdr), "%-7s %12s %12s %12s %12s\n",
            "run", "total", "target", "veto", "both");
   o << hdr;
   for (const auto &kv : rows) {
      const RunSummaryRow &r = kv.second;
      char b[512];
      snprintf(b, sizeof(b), "%-7d %12s %12s %12s %12s\n",
               r.run, FmtF(r.rate(r.nEvents()), 2).c_str(),
               FmtF(r.rate(r.nTarget()), 2).c_str(),
               FmtF(r.rate(r.nVeto()), 2).c_str(),
               FmtF(r.rate(r.nBoth()), 3).c_str());
      o << b;
   }

   o << "\n-- 누적 (런을 순서대로 더해 간다) ---------------------------------------------\n";
   snprintf(hdr, sizeof(hdr), "%-7s %14s %10s %18s\n",
            "run", "cum_live[s]", "cum[day]", "cum_total_ev");
   o << hdr;
   double cumLive = 0, cumDead = 0;
   long long cEv = 0, cTg = 0, cVt = 0, cBo = 0;
   int cSub = 0, cBad = 0;
   double firstE = -1, lastE = -1;
   for (const auto &kv : rows) {
      const RunSummaryRow &r = kv.second;
      cumLive += r.liveSec;
      if (r.deadSec > 0) cumDead += r.deadSec;
      cSub += r.nSubrun; cBad += r.nBadSubrun;
      cEv += r.nEvents(); cTg += r.nTarget(); cVt += r.nVeto(); cBo += r.nBoth();
      if (r.epochStart > 0 && (firstE < 0 || r.epochStart < firstE)) firstE = r.epochStart;
      if (r.epochEnd > lastE) lastE = r.epochEnd;
      char b[512];
      snprintf(b, sizeof(b), "%-7d %14s %10s %18s\n",
               r.run, FmtF(cumLive, 1).c_str(), FmtF(cumLive / 86400.0, 4).c_str(),
               FmtCount(cEv).c_str());
      o << b;
   }

   o << "\n-- 합계 -----------------------------------------------------------------------\n";
   char b[512];
   snprintf(b, sizeof(b), "  런 %zu 개 · 서브런 %d 개 (읽지 못한 것 %d)\n",
            rows.size(), cSub, cBad);                                          o << b;
   snprintf(b, sizeof(b), "  첫 DAQ 시작 : %s\n", FmtEpoch(firstE).c_str());   o << b;
   snprintf(b, sizeof(b), "  마지막 기록 : %s\n", FmtEpoch(lastE).c_str());    o << b;
   snprintf(b, sizeof(b), "  livetime    : %s s  = %s day\n",
            FmtF(cumLive, 1).c_str(), FmtF(cumLive / 86400.0, 4).c_str());     o << b;
   snprintf(b, sizeof(b), "  dead time   : %s s  (livetime 대비 %s %%)\n",
            FmtF(cumDead, 1).c_str(),
            FmtF(cumLive > 0 ? cumDead / cumLive * 100.0 : -1, 4).c_str());    o << b;
   snprintf(b, sizeof(b), "  total ev    : %s\n", FmtCount(cEv).c_str());      o << b;
   snprintf(b, sizeof(b), "  target      : %s\n", FmtCount(cTg).c_str());      o << b;
   snprintf(b, sizeof(b), "  veto        : %s\n", FmtCount(cVt).c_str());      o << b;
   snprintf(b, sizeof(b), "  both        : %s\n", FmtCount(cBo).c_str());      o << b;
   if (cBad > 0) {
      snprintf(b, sizeof(b),
               "\n  [주의] 읽지 못한 서브런이 %d 개 있다. 그만큼 과소평가다.\n", cBad);
      o << b;
   }
   o << "===============================================================================\n";
}

// ---------------------------------------------------------------------------
static void Impl(const std::vector<int> &runs, bool force,
                 const char *outDir, const char *rawRoots) {
   TString out(outDir), raw(rawRoots);
   if (!out.EndsWith("/")) out += "/";

   if (gSystem->mkdir(out, kTRUE) != 0 && gSystem->AccessPathName(out, kWritePermission)) {
      printf("[FATAL] 출력 디렉터리에 쓸 수 없다 : %s\n", out.Data());
      return;
   }
   TString txtPath = out + "run_summary.txt";
   TString tsvPath = out + "run_summary.tsv";

   bool schemaOk = true;
   std::map<int, RunSummaryRow> rows = LoadExisting(tsvPath, schemaOk);
   if (!schemaOk) {
      printf("[FATAL] %s 가 옛 형식이다 (schema %d 가 아니다).\n"
             "        입력이 Monitor/Step1 에서 PRD 로 바뀌어 열이 달라졌다.\n"
             "        옛 파일을 치우고 다시 만들 것 :\n"
             "          mv %s %s.old\n", tsvPath.Data(), kSchema,
             tsvPath.Data(), tsvPath.Data());
      return;
   }
   printf("[INFO] 기존 run_summary : %zu 개 런\n", rows.size());
   printf("[INFO] 입력 : <root>/<run>/PRD/  (읽기 전용)  root = %s\n", raw.Data());

   int nNew = 0, nSkip = 0, nMiss = 0;
   for (int run : runs) {
      if (!force && rows.count(run)) { nSkip++; continue; }
      RunSummaryRow r;
      if (!BuildOneRun(run, raw, r)) { nMiss++; continue; }
      bool replaced = rows.count(run) > 0;
      rows[run] = r;
      nNew++;
      printf("  [%s] run %d : subrun=%d  live=%.1f s (%.4f d)  duty=%.4f  total=%s\n",
             replaced ? "REDO" : " NEW", run, r.nSubrun, r.liveSec,
             r.liveSec / 86400.0, r.duty(), FmtCount(r.nEvents()).c_str());
      //  런 하나가 몇 분 걸린다. 중간에 끊겨도 한 것은 남도록 그때그때 쓴다.
      WriteTsv(tsvPath, rows);
      WriteTxt(txtPath, rows);
   }

   if (nNew == 0) {
      printf("[INFO] 새로 더한 런이 없다 (건너뜀 %d, 자료 없음 %d).\n", nSkip, nMiss);
      return;
   }
   printf("[SAVED] %s\n[SAVED] %s\n", txtPath.Data(), tsvPath.Data());
   printf("[DONE ] 새로/다시 쓴 런 %d, 건너뜀 %d, 자료 없음 %d, 표에 든 런 %zu\n",
          nNew, nSkip, nMiss, rows.size());
}

void BuildRunSummary(int runFirst, int runLast = -1, bool force = false,
                     const char *outDir = "/scratch/RunSummary/",
                     const char *rawRoots = "/Data_ssd/RAW:/data/RAW:/scratch/RAW") {
   if (runLast < runFirst) runLast = runFirst;
   std::vector<int> runs;
   for (int r = runFirst; r <= runLast; ++r) runs.push_back(r);
   Impl(runs, force, outDir, rawRoots);
}

void BuildRunSummary(const char *runList, bool force = false,
                     const char *outDir = "/scratch/RunSummary/",
                     const char *rawRoots = "/Data_ssd/RAW:/data/RAW:/scratch/RAW") {
   std::vector<int> runs = ParseRunList(runList);
   if (runs.empty()) { printf("[FATAL] 런 목록이 비어 있다\n"); return; }
   Impl(runs, force, outDir, rawRoots);
}
