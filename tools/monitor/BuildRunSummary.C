// ---------------------------------------------------------------------------
//  BuildRunSummary.C - production 을 마친 런에서 DAQ 운용 지표를 뽑아
//                      run_summary 로 누적한다.
//
//  무엇을 읽나
//     1순위  <SampleDir>/Monitor/monitor_Run<NNNNNN>.root : T_Monitor
//            (BuildMonitorSummary.C 산출물. Step2 계수까지 들어 있다)
//     2순위  <SampleDir>/Step1/step1_Run<NNNNNN>.root     : T_LiveTime
//            (AnalysisStep1.C 산출물. clean/muon 계수는 없다)
//
//  무엇을 쓰나
//     <OutDir>/run_summary.txt   사람이 읽는 고정폭 표 (정본)
//     <OutDir>/run_summary.tsv   그림 그릴 때 쓰는 탭 구분 표
//
//  이미 있는 런은 건너뛰고 새 런만 이어붙인다(--force 로 다시 씀).
//  두 파일 모두 run 번호 오름차순을 유지한다.
//
//  사용 :
//     root -l -b -q 'BuildRunSummary.C(4237, 4240)'          범위
//     root -l -b -q 'BuildRunSummary.C("4237,4239,4240")'    목록
//     root -l -b -q 'BuildRunSummary.C(4237, 4240, true)'    이미 있어도 다시 씀
//  경로를 바꾸려면 :
//     root -l -b -q 'BuildRunSummary.C(4237,4240,false,"/scratch/RunSummary/","/scratch/junkyo/SampleFiles/")'
//
//  livetime 의 정의 — AnalysisStep1.C 를 그대로 따른다.
//     서브런 livetime = (T_State.end_time - start_time) * 1e-9   [TCB 시각, ns]
//     런  livetime    = 서브런 livetime 의 합
//  DAQ 시작 시각은 첫 서브런의 epoch 다. 이것은 원시 FADC 파일의 mtime 이라
//  '그 서브런이 닫힌 시각'에 가깝다. 벽시계 경과와 livetime 의 차이가
//  곧 죽은 시간이므로 duty 로 함께 적는다.
// ---------------------------------------------------------------------------
#include <TFile.h>
#include <TTree.h>
#include <TSystem.h>
#include <TString.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
//  한 런의 집계 결과
// ---------------------------------------------------------------------------
struct RunSummaryRow {
   int      run          = 0;
   int      nSubrun      = 0;
   double   epochStart   = -1;   // 첫 서브런 epoch [Unix s]
   double   epochEnd     = -1;   // 마지막 서브런 epoch [Unix s]
   double   wallSec      = -1;   // epochEnd - epochStart
   double   spanSec      = -1;   // (마지막 start_ns - 첫 start_ns) + 마지막 duration
   double   liveSec      = 0;    // Σ duration_sec
   double   deadSec      = 0;    // Σ max(gap - duration, 0)
   // 이벤트 수 (서브런 누적). 음수면 그 정보가 없다는 뜻이다.
   long long nEvents     = -1;
   long long nVeto       = -1;
   long long nTarget     = -1;
   long long nBoth       = -1;
   long long nClean      = -1;
   long long nMuon       = -1;
   long long nAfterMu    = -1;
   //  각 계수에 값이 있던 서브런 수. 일부만 있는 런을 완전한 합으로 착각하지
   //  않으려면 이것이 있어야 한다. 실제로 4237~4239 는 n_target 이 없고
   //  4240 만 있다 -- 합만 보면 구분이 안 된다.
   int covTrig           = 0;    // n_events/veto/target/both 중 최소 커버리지
   int covStep2          = 0;    // n_clean/muon/aftermu 중 최소 커버리지
   std::string source    = "-";  // monitor | step1

   double duty() const {
      double base = (spanSec > 0) ? spanSec : wallSec;
      return (base > 0) ? liveSec / base : -1;
   }
   double rate(long long n) const {
      return (n >= 0 && liveSec > 0) ? (double)n / liveSec : -1;
   }
   double pctTrig()  const { return nSubrun > 0 ? 100.0 * covTrig  / nSubrun : -1; }
   double pctStep2() const { return nSubrun > 0 ? 100.0 * covStep2 / nSubrun : -1; }
   // 파생 분류. 하나라도 없으면 -1.
   long long targetOnly() const {
      return (nTarget >= 0 && nBoth >= 0) ? nTarget - nBoth : -1;
   }
   long long vetoOnly() const {
      return (nVeto >= 0 && nBoth >= 0) ? nVeto - nBoth : -1;
   }
   long long neither() const {
      if (nEvents < 0 || nTarget < 0 || nVeto < 0 || nBoth < 0) return -1;
      return nEvents - (nTarget - nBoth) - (nVeto - nBoth) - nBoth;
   }
};

// ---------------------------------------------------------------------------
//  보조
// ---------------------------------------------------------------------------
static TString RunStr(int run) { return TString::Format("%06d", run); }

static std::string FmtEpoch(double e) {
   if (e <= 0) return "-";
   time_t t = (time_t)e;
   struct tm tmv;
   localtime_r(&t, &tmv);
   char buf[32];
   strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &tmv);
   return std::string(buf);
}

//  큰 수는 자릿수를 세기 어렵다. 천 단위로 끊어 준다.
static std::string FmtCount(long long v) {
   if (v < 0) return "-";
   std::string s = std::to_string(v);
   for (int i = (int)s.size() - 3; i > 0; i -= 3) s.insert(i, ",");
   return s;
}

static std::string FmtF(double v, int prec) {
   if (v < 0) return "-";
   char buf[64];
   snprintf(buf, sizeof(buf), "%.*f", prec, v);
   return std::string(buf);
}

//  tsv 전용. 항상 숫자를 낸다 (없는 값은 음수). FmtF 와 달라야 한다.
static std::string FmtRaw(double v, int prec) {
   char buf[64];
   snprintf(buf, sizeof(buf), "%.*f", prec, v);
   return std::string(buf);
}

static std::vector<int> ParseRunList(const char *s) {
   std::vector<int> out;
   std::stringstream ss(s ? s : "");
   std::string tok;
   while (std::getline(ss, tok, ',')) {
      // 공백 제거
      size_t a = tok.find_first_not_of(" \t");
      if (a == std::string::npos) continue;
      size_t b = tok.find_last_not_of(" \t");
      tok = tok.substr(a, b - a + 1);
      if (tok.empty()) continue;
      size_t dash = tok.find('-');
      if (dash != std::string::npos && dash > 0) {          // "4237-4240"
         int lo = std::atoi(tok.substr(0, dash).c_str());
         int hi = std::atoi(tok.substr(dash + 1).c_str());
         for (int r = lo; r <= hi; ++r) out.push_back(r);
      } else {
         out.push_back(std::atoi(tok.c_str()));
      }
   }
   return out;
}

// ---------------------------------------------------------------------------
//  런 하나 집계
// ---------------------------------------------------------------------------
//  서브런 하나를 담는다. 두 입력이 주는 항목이 달라 공통형으로 받는다.
struct SubrunRow {
   int       sid   = -1;
   double    start = 0;    // TCB 시각 [ns]
   double    dur   = 0;    // livetime [s]
   double    epoch = -1;   // [Unix s]
   double    gap   = -1;   // 다음 서브런까지 [s]
   long long nEv = -1, nVt = -1, nTg = -1, nBo = -1;
   long long nCl = -1, nMu = -1, nAf = -1;
};

static bool ReadMonitor(int run, const TString &sampleDir, std::vector<SubrunRow> &out) {
   TString path = TString::Format("%sMonitor/monitor_Run%s.root", sampleDir.Data(), RunStr(run).Data());
   if (gSystem->AccessPathName(path)) return false;
   TFile *f = TFile::Open(path, "READ");
   if (!f || f->IsZombie()) { if (f) f->Close(); return false; }
   TTree *t = (TTree *)f->Get("T_Monitor");
   if (!t) { f->Close(); return false; }

   Int_t sid; Double_t start, epoch, dur, gap;
   Long64_t nEv, nVt, nTg, nBo, nCl, nMu, nAf;
   t->SetBranchAddress("subrun_id",    &sid);
   t->SetBranchAddress("start_ns",     &start);
   t->SetBranchAddress("epoch",        &epoch);
   t->SetBranchAddress("duration_sec", &dur);
   t->SetBranchAddress("gap_sec",      &gap);
   t->SetBranchAddress("n_events",     &nEv);
   t->SetBranchAddress("n_veto",       &nVt);
   t->SetBranchAddress("n_target",     &nTg);
   t->SetBranchAddress("n_both",       &nBo);
   t->SetBranchAddress("n_clean",      &nCl);
   t->SetBranchAddress("n_muon",       &nMu);
   t->SetBranchAddress("n_aftermu",    &nAf);

   for (Long64_t i = 0; i < t->GetEntries(); ++i) {
      t->GetEntry(i);
      out.push_back({sid, start, dur, epoch, gap, nEv, nVt, nTg, nBo, nCl, nMu, nAf});
   }
   f->Close();
   return !out.empty();
}

static bool ReadStep1(int run, const TString &sampleDir, std::vector<SubrunRow> &out) {
   TString path = TString::Format("%sStep1/step1_Run%s.root", sampleDir.Data(), RunStr(run).Data());
   if (gSystem->AccessPathName(path)) return false;
   TFile *f = TFile::Open(path, "READ");
   if (!f || f->IsZombie()) { if (f) f->Close(); return false; }
   TTree *t = (TTree *)f->Get("T_LiveTime");
   if (!t) { f->Close(); return false; }

   Int_t sid; Double_t start, end, dur, epoch = -1;
   Long64_t nEv = -1, nVt = -1, nTg = -1, nBo = -1;
   t->SetBranchAddress("subrun_id",    &sid);
   t->SetBranchAddress("start_time",   &start);
   t->SetBranchAddress("end_time",     &end);
   t->SetBranchAddress("duration_sec", &dur);
   if (t->GetBranch("epoch"))    t->SetBranchAddress("epoch",    &epoch);
   if (t->GetBranch("n_events")) t->SetBranchAddress("n_events", &nEv);
   if (t->GetBranch("n_veto"))   t->SetBranchAddress("n_veto",   &nVt);
   if (t->GetBranch("n_target")) t->SetBranchAddress("n_target", &nTg);
   if (t->GetBranch("n_both"))   t->SetBranchAddress("n_both",   &nBo);

   for (Long64_t i = 0; i < t->GetEntries(); ++i) {
      t->GetEntry(i);
      out.push_back({sid, start, dur, epoch, -1, nEv, nVt, nTg, nBo, -1, -1, -1});
   }
   f->Close();
   return !out.empty();
}

//  누적기. 한 서브런이라도 값이 있으면 그 항목은 살아난다.
//  값이 있던 서브런 수를 함께 센다 -- 합만으로는 '전부 더한 것'과
//  '있는 것만 더한 것'을 구분할 수 없기 때문이다.
static void Accum(long long &dst, long long v, int *cov = nullptr) {
   if (v < 0) return;
   dst = (dst < 0 ? 0 : dst) + v;
   if (cov) (*cov)++;
}

static bool BuildOneRun(int run, const TString &sampleDir, RunSummaryRow &row) {
   std::vector<SubrunRow> subs;
   const char *src = "monitor";
   if (!ReadMonitor(run, sampleDir, subs)) {
      src = "step1";
      if (!ReadStep1(run, sampleDir, subs)) {
         printf("  [SKIP] run %d : Monitor 도 Step1 도 없다 (아직 분석 전)\n", run);
         return false;
      }
      printf("  [INFO] run %d : monitor 요약이 없어 Step1 로 집계한다 "
             "(clean/muon 계수 없음. BuildMonitorSummary.C+(%d) 를 먼저 돌리면 채워진다)\n",
             run, run);
   }
   std::sort(subs.begin(), subs.end(),
             [](const SubrunRow &a, const SubrunRow &b) { return a.sid < b.sid; });

   row = RunSummaryRow();
   row.run     = run;
   row.source  = src;
   row.nSubrun = (int)subs.size();

   int covEv = 0, covVt = 0, covTg = 0, covBo = 0, covCl = 0, covMu = 0, covAf = 0;
   for (size_t i = 0; i < subs.size(); ++i) {
      const SubrunRow &s = subs[i];
      if (s.dur > 0) row.liveSec += s.dur;

      // gap 이 없는 입력(Step1)에서는 이웃 start_ns 로 직접 만든다
      double gap = s.gap;
      if (gap < 0 && i + 1 < subs.size()) gap = (subs[i + 1].start - s.start) * 1e-9;
      if (gap > 0 && s.dur > 0 && gap > s.dur) row.deadSec += gap - s.dur;

      if (s.epoch > 0) {
         if (row.epochStart < 0 || s.epoch < row.epochStart) row.epochStart = s.epoch;
         if (s.epoch > row.epochEnd) row.epochEnd = s.epoch;
      }
      Accum(row.nEvents,  s.nEv, &covEv);
      Accum(row.nVeto,    s.nVt, &covVt);
      Accum(row.nTarget,  s.nTg, &covTg);
      Accum(row.nBoth,    s.nBo, &covBo);
      Accum(row.nClean,   s.nCl, &covCl);
      Accum(row.nMuon,    s.nMu, &covMu);
      Accum(row.nAfterMu, s.nAf, &covAf);
   }
   row.covTrig  = std::min(std::min(covEv, covVt), std::min(covTg, covBo));
   row.covStep2 = std::min(covCl, std::min(covMu, covAf));

   if (row.epochStart > 0 && row.epochEnd > 0) row.wallSec = row.epochEnd - row.epochStart;
   if (!subs.empty()) {
      // DAQ 시작을 기점으로 한 경과. TCB 시각이라 파일 mtime 보다 믿을 만하다.
      row.spanSec = (subs.back().start - subs.front().start) * 1e-9 + subs.back().dur;
   }
   return true;
}

// ---------------------------------------------------------------------------
//  기존 run_summary.tsv 를 읽어 이미 있는 런을 알아낸다.
//  txt 는 사람이 읽는 표라 표시용 서식이 섞여 있다. 되읽기는 tsv 만 한다.
// ---------------------------------------------------------------------------
static std::map<int, RunSummaryRow> LoadExisting(const TString &tsvPath) {
   std::map<int, RunSummaryRow> out;
   std::ifstream in(tsvPath.Data());
   if (!in) return out;
   std::string line;
   while (std::getline(in, line)) {
      if (line.empty() || line[0] == '#') continue;
      std::stringstream ss(line);
      RunSummaryRow r;
      std::string src;
      // 열 순서는 WriteTsv 와 반드시 같아야 한다
      if (!(ss >> r.run >> r.nSubrun >> r.epochStart >> r.epochEnd
               >> r.wallSec >> r.spanSec >> r.liveSec >> r.deadSec
               >> r.nEvents >> r.nVeto >> r.nTarget >> r.nBoth
               >> r.nClean >> r.nMuon >> r.nAfterMu
               >> r.covTrig >> r.covStep2 >> src))
         continue;
      r.source = src;
      out[r.run] = r;
   }
   return out;
}

static void WriteTsv(const TString &path, const std::map<int, RunSummaryRow> &rows) {
   std::ofstream o(path.Data());
   o << "# RENE DAQ run summary (machine readable). BuildRunSummary.C 가 만든다.\n"
        "# 음수는 '그 정보 없음'. 시각은 Unix 초, 시간은 초, rate 는 livetime 기준.\n"
        "# cov_trig / cov_step2 = 그 계수에 값이 있던 서브런 수. n_subrun 과\n"
        "# 같지 않으면 합이 런 전체를 덮지 않는다는 뜻이다.\n"
        "#run\tn_subrun\tepoch_start\tepoch_end\twall_s\tspan_s\tlive_s\tdead_s"
        "\tn_events\tn_veto\tn_target\tn_both\tn_clean\tn_muon\tn_aftermu"
        "\tcov_trig\tcov_step2\tsource\n";
   for (const auto &kv : rows) {
      const RunSummaryRow &r = kv.second;
      //  tsv 는 되읽기용이다. 값이 없으면 '-' 가 아니라 음수를 쓴다 --
      //  '-' 를 쓰면 LoadExisting 의 >> 가 실패해서 그 행이 통째로 사라진다.
      //  (실제로 그렇게 run 4084 가 표에서 없어졌다. '-' 는 txt 에서만 쓴다)
      o << r.run << '\t' << r.nSubrun << '\t'
        << (long long)r.epochStart << '\t' << (long long)r.epochEnd << '\t'
        << FmtRaw(r.wallSec, 3) << '\t' << FmtRaw(r.spanSec, 3) << '\t'
        << FmtRaw(r.liveSec, 3) << '\t' << FmtRaw(r.deadSec, 3) << '\t'
        << r.nEvents << '\t' << r.nVeto << '\t' << r.nTarget << '\t' << r.nBoth << '\t'
        << r.nClean << '\t' << r.nMuon << '\t' << r.nAfterMu << '\t'
        << r.covTrig << '\t' << r.covStep2 << '\t'
        << r.source << '\n';
   }
}

static void WriteTxt(const TString &path, const std::map<int, RunSummaryRow> &rows) {
   std::ofstream o(path.Data());
   time_t now = time(nullptr);
   char nowbuf[32];
   struct tm tmv; localtime_r(&now, &tmv);
   strftime(nowbuf, sizeof(nowbuf), "%Y-%m-%d %H:%M:%S", &tmv);

   o << "===============================================================================\n"
        "  RENE DAQ run summary\n"
        "  " << nowbuf << " 갱신 · BuildRunSummary.C 생성 · 런 " << rows.size() << "개\n"
        "===============================================================================\n"
        "  livetime  = 서브런 (end_time - start_time) 의 합. TCB 시각 기준\n"
        "  span      = 첫 서브런 시작부터 마지막 서브런 끝까지 (TCB 시각)\n"
        "  duty      = livetime / span. 1 에 가까울수록 죽은 시간이 없다\n"
        "  DAQ start = 첫 서브런의 원시 FADC 파일 mtime. 파일이 닫힌 시각에 가깝다\n"
        "  '-' 는 그 정보가 아직 없다는 뜻이다 (Step2 미완료 등)\n"
        "\n";

   // ---- 런별 표 ----
   o << "-- 런별 -----------------------------------------------------------------------\n";
   char hdr[512];
   snprintf(hdr, sizeof(hdr), "%-7s %-19s %8s %12s %12s %7s %8s %s\n",
            "run", "DAQ start", "subrun", "live[s]", "span[s]", "duty", "dead[s]", "source");
   o << hdr;
   for (const auto &kv : rows) {
      const RunSummaryRow &r = kv.second;
      char buf[512];
      snprintf(buf, sizeof(buf), "%-7d %-19s %8d %12s %12s %7s %8s %s\n",
               r.run, FmtEpoch(r.epochStart).c_str(), r.nSubrun,
               FmtF(r.liveSec, 1).c_str(), FmtF(r.spanSec, 1).c_str(),
               FmtF(r.duty(), 4).c_str(), FmtF(r.deadSec, 1).c_str(),
               r.source.c_str());
      o << buf;
   }

   // ---- 종류별 이벤트 수 ----
   o << "\n-- 종류별 이벤트 수 -----------------------------------------------------------\n"
        "   total      = TCB 가 낸 전체 트리거\n"
        "   veto       = SADC(외부 veto) 가 때린 것\n"
        "   target     = FADC(표적) 가 때린 것\n"
        "   both       = 둘 다\n"
        "   tgt_only   = target - both        veto_only = veto - both\n"
        "   neither    = total - tgt_only - veto_only - both\n";
   o << "   cov        = 이 계수를 가진 서브런의 비율. 100 이 아니면 아래 합은\n"
        "                런 전체가 아니라 '값이 있던 서브런만' 더한 것이다\n";
   snprintf(hdr, sizeof(hdr), "%-7s %14s %14s %14s %14s %14s %14s %12s %7s\n",
            "run", "total", "veto", "target", "both", "tgt_only", "veto_only", "neither", "cov[%]");
   o << hdr;
   for (const auto &kv : rows) {
      const RunSummaryRow &r = kv.second;
      char buf[512];
      snprintf(buf, sizeof(buf), "%-7d %14s %14s %14s %14s %14s %14s %12s %7s\n",
               r.run, FmtCount(r.nEvents).c_str(), FmtCount(r.nVeto).c_str(),
               FmtCount(r.nTarget).c_str(), FmtCount(r.nBoth).c_str(),
               FmtCount(r.targetOnly()).c_str(), FmtCount(r.vetoOnly()).c_str(),
               FmtCount(r.neither()).c_str(), FmtF(r.pctTrig(), 1).c_str());
      o << buf;
   }

   // ---- 분석 후 계수 ----
   o << "\n-- 분석 후 계수 (Step2) -------------------------------------------------------\n"
        "   clean      = muon 태그도 veto 창도 포화도 아닌 것\n"
        "   muon       = muon 태그. Step2 의 T_Muon 이며 SADC veto 태그와 같은 것을\n"
        "                센다 (실측: 위 표의 veto 와 수가 정확히 일치한다)\n"
        "   aftermu    = muon 직후 창에 들어온 것\n";
   snprintf(hdr, sizeof(hdr), "%-7s %14s %14s %14s %12s %12s %7s\n",
            "run", "clean", "muon", "aftermu", "clean[Hz]", "muon[Hz]", "cov[%]");
   o << hdr;
   for (const auto &kv : rows) {
      const RunSummaryRow &r = kv.second;
      char buf[512];
      snprintf(buf, sizeof(buf), "%-7d %14s %14s %14s %12s %12s %7s\n",
               r.run, FmtCount(r.nClean).c_str(), FmtCount(r.nMuon).c_str(),
               FmtCount(r.nAfterMu).c_str(),
               FmtF(r.rate(r.nClean), 4).c_str(), FmtF(r.rate(r.nMuon), 4).c_str(),
               FmtF(r.pctStep2(), 1).c_str());
      o << buf;
   }

   // ---- 계수율 ----
   o << "\n-- 계수율 [Hz] (livetime 기준) ------------------------------------------------\n";
   snprintf(hdr, sizeof(hdr), "%-7s %12s %12s %12s %12s\n",
            "run", "total", "veto", "target", "both");
   o << hdr;
   for (const auto &kv : rows) {
      const RunSummaryRow &r = kv.second;
      char buf[512];
      snprintf(buf, sizeof(buf), "%-7d %12s %12s %12s %12s\n",
               r.run, FmtF(r.rate(r.nEvents), 2).c_str(), FmtF(r.rate(r.nVeto), 2).c_str(),
               FmtF(r.rate(r.nTarget), 2).c_str(), FmtF(r.rate(r.nBoth), 2).c_str());
      o << buf;
   }

   // ---- 누적 ----
   double cumLive = 0, cumDead = 0;
   long long cEv = -1, cVt = -1, cTg = -1, cBo = -1, cCl = -1, cMu = -1;
   int cSub = 0, nPartTrig = 0, nPartStep2 = 0;
   double firstEpoch = -1, lastEpoch = -1;
   o << "\n-- 누적 (런을 순서대로 더해 간다) ---------------------------------------------\n";
   snprintf(hdr, sizeof(hdr), "%-7s %14s %10s %16s %16s\n",
            "run", "cum_live[s]", "cum[day]", "cum_total_ev", "cum_clean");
   o << hdr;
   for (const auto &kv : rows) {
      const RunSummaryRow &r = kv.second;
      cumLive += r.liveSec;
      if (r.deadSec > 0) cumDead += r.deadSec;
      cSub += r.nSubrun;
      Accum(cEv, r.nEvents); Accum(cVt, r.nVeto);  Accum(cTg, r.nTarget);
      Accum(cBo, r.nBoth);   Accum(cCl, r.nClean); Accum(cMu, r.nMuon);
      if (r.nSubrun > 0 && r.covTrig  < r.nSubrun) nPartTrig++;
      if (r.nSubrun > 0 && r.covStep2 < r.nSubrun) nPartStep2++;
      if (r.epochStart > 0 && (firstEpoch < 0 || r.epochStart < firstEpoch)) firstEpoch = r.epochStart;
      if (r.epochEnd   > lastEpoch) lastEpoch = r.epochEnd;
      char buf[512];
      snprintf(buf, sizeof(buf), "%-7d %14s %10s %16s %16s\n",
               r.run, FmtF(cumLive, 1).c_str(), FmtF(cumLive / 86400.0, 4).c_str(),
               FmtCount(cEv).c_str(), FmtCount(cCl).c_str());
      o << buf;
   }

   o << "\n-- 합계 -----------------------------------------------------------------------\n";
   char buf[512];
   snprintf(buf, sizeof(buf), "  런 %zu 개 · 서브런 %d 개\n", rows.size(), cSub);              o << buf;
   snprintf(buf, sizeof(buf), "  첫 DAQ 시작 : %s\n", FmtEpoch(firstEpoch).c_str());          o << buf;
   snprintf(buf, sizeof(buf), "  마지막 기록 : %s\n", FmtEpoch(lastEpoch).c_str());           o << buf;
   snprintf(buf, sizeof(buf), "  livetime    : %s s  = %s day\n",
            FmtF(cumLive, 1).c_str(), FmtF(cumLive / 86400.0, 4).c_str());                     o << buf;
   snprintf(buf, sizeof(buf), "  dead time   : %s s  (livetime 대비 %s %%)\n",
            FmtF(cumDead, 1).c_str(),
            FmtF(cumLive > 0 ? cumDead / cumLive * 100.0 : -1, 4).c_str());                    o << buf;
   snprintf(buf, sizeof(buf), "  total ev    : %s\n", FmtCount(cEv).c_str());                  o << buf;
   snprintf(buf, sizeof(buf), "  veto        : %s\n", FmtCount(cVt).c_str());                  o << buf;
   snprintf(buf, sizeof(buf), "  target      : %s\n", FmtCount(cTg).c_str());                  o << buf;
   snprintf(buf, sizeof(buf), "  both        : %s\n", FmtCount(cBo).c_str());                  o << buf;
   snprintf(buf, sizeof(buf), "  clean       : %s\n", FmtCount(cCl).c_str());                  o << buf;
   snprintf(buf, sizeof(buf), "  muon        : %s\n", FmtCount(cMu).c_str());                  o << buf;
   if (nPartTrig > 0 || nPartStep2 > 0) {
      o << "\n  [주의] 계수가 런 전체를 덮지 않는 런이 있다 --\n";
      if (nPartTrig > 0) {
         snprintf(buf, sizeof(buf), "         트리거 계수 %d 개 런, ", nPartTrig); o << buf;
      }
      if (nPartStep2 > 0) {
         snprintf(buf, sizeof(buf), "Step2 계수 %d 개 런", nPartStep2); o << buf;
      }
      o << "\n         위 표의 cov 열을 볼 것. 합계는 그만큼 과소평가다.\n";
   }
   o << "===============================================================================\n";
}

// ---------------------------------------------------------------------------
//  본체
// ---------------------------------------------------------------------------
static void BuildRunSummaryImpl(const std::vector<int> &runs, bool force,
                                const char *outDir, const char *sampleDir) {
   TString out(outDir), sample(sampleDir);
   if (!out.EndsWith("/"))    out    += "/";
   if (!sample.EndsWith("/")) sample += "/";

   if (gSystem->mkdir(out, kTRUE) != 0 && gSystem->AccessPathName(out, kWritePermission)) {
      printf("[FATAL] 출력 디렉터리에 쓸 수 없다 : %s\n", out.Data());
      return;
   }

   TString txtPath = out + "run_summary.txt";
   TString tsvPath = out + "run_summary.tsv";

   std::map<int, RunSummaryRow> rows = LoadExisting(tsvPath);
   printf("[INFO] 기존 run_summary : %zu 개 런 (%s)\n", rows.size(), tsvPath.Data());

   int nNew = 0, nSkip = 0, nMiss = 0;
   for (int run : runs) {
      if (!force && rows.count(run)) { nSkip++; continue; }
      RunSummaryRow r;
      if (!BuildOneRun(run, sample, r)) { nMiss++; continue; }
      bool replaced = rows.count(run) > 0;
      rows[run] = r;
      nNew++;
      printf("  [%s] run %d : subrun=%d  live=%.1f s (%.4f d)  duty=%.4f  total=%s  source=%s\n",
             replaced ? "REDO" : " NEW", run, r.nSubrun, r.liveSec, r.liveSec / 86400.0,
             r.duty(), FmtCount(r.nEvents).c_str(), r.source.c_str());
   }

   if (nNew == 0) {
      printf("[INFO] 새로 더한 런이 없다 (건너뜀 %d, 자료 없음 %d). 파일은 그대로 둔다.\n",
             nSkip, nMiss);
      return;
   }

   WriteTsv(tsvPath, rows);
   WriteTxt(txtPath, rows);
   printf("[SAVED] %s\n[SAVED] %s\n", txtPath.Data(), tsvPath.Data());
   printf("[DONE ] 새로/다시 쓴 런 %d, 건너뜀 %d, 자료 없음 %d, 표에 든 런 %zu\n",
          nNew, nSkip, nMiss, rows.size());
}

//  범위로 : BuildRunSummary(4237, 4240)
void BuildRunSummary(int runFirst, int runLast = -1, bool force = false,
                     const char *outDir    = "/scratch/RunSummary/",
                     const char *sampleDir = "/scratch/junkyo/SampleFiles/") {
   if (runLast < runFirst) runLast = runFirst;
   std::vector<int> runs;
   for (int r = runFirst; r <= runLast; ++r) runs.push_back(r);
   BuildRunSummaryImpl(runs, force, outDir, sampleDir);
}

//  목록으로 : BuildRunSummary("4237,4239,4240")  또는 "4237-4240,4288"
void BuildRunSummary(const char *runList, bool force = false,
                     const char *outDir    = "/scratch/RunSummary/",
                     const char *sampleDir = "/scratch/junkyo/SampleFiles/") {
   std::vector<int> runs = ParseRunList(runList);
   if (runs.empty()) { printf("[FATAL] 런 목록이 비어 있다 : '%s'\n", runList ? runList : ""); return; }
   BuildRunSummaryImpl(runs, force, outDir, sampleDir);
}
