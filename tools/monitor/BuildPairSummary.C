// ---------------------------------------------------------------------------
//  BuildPairSummary.C - production 산출물(PRD)에서 곧바로 IBD 후보를 세어
//                       채널별로 누적한다.
//
//  BuildRunSummary.C 가 'DAQ 가 무엇을 받았나'라면 이쪽은 그 다음 단계 --
//  '그 중 몇 개가 IBD 후보로 남았나'다. 둘은 run 번호로 이어지고,
//  **둘 다 같은 것을 읽는다 : production 이 끝난 PRD.**
//
//  무엇을 읽나  ★ 2026-08-18 에 여기가 바뀌었다
//     <root>/RAW/<NNNNNN>/PRD/PRD_<NNNNNN>.<SSSSS>.root   TTree "Event"
//     root 는 ':' 로 나눈 목록을 앞에서부터 찾는다.
//     기본 /Data_ssd/RAW:/data/RAW:/scratch/RAW  (dataflow 가 런을 옮긴다)
//
//     예전에는 /scratch/junkyo/SampleFiles 의 Step3/Step4 트리를 읽었다.
//     그러면 분석 쪽이 그 런을 아직 페어링하지 않았을 때 이 표가 멈춘다 --
//     실제로 2026-08-18 에 1단계는 run 4291 까지 갔는데 2단계는 4240 에서
//     멎어 있었다. 이제 PRD 만 있으면 스스로 끝까지 간다.
//
//  무엇을 쓰나
//     <OutDir>/pair_summary.txt   사람이 읽는 표
//     <OutDir>/pair_summary.tsv   되읽기·그림용 (schema 2)
//     <OutDir>/cache/singles/     서브런별 single 캐시 (RenePrdSingles.h)
//
//  ---- 어디에 무엇이 있나 ----
//     RenePrdSingles.h  PRD -> clean single (= 분석 Step1 + Step2).
//                       파형 -> NPE 와 컷 상수는 분석 쪽 essential 을
//                       include 해서 쓴다. 베끼지 않는다.
//     RenePairing.h     single -> 후보 수 (= 분석 Step3 + Step4).
//                       분석 쪽에 **세기만 하는** 진입점이 없어 loop 을
//                       따로 두었다. 그래서 갈라질 수 있다.
//     이 파일           위 둘을 엮고 표를 쓴다.
//
//  **분석 쪽이 페어링을 바꾸면 RenePairing.h 도 바꿔야 한다.** 그래서 아래
//  CheckAgainstAnalysis() 로 Step4 산출물이 있는 런에서는 매번 수를 맞춰 본다.
//  실측(run 4237, single 72,658,494 개)으로 여덟 개 수가 전부 일치했다.
//
//  ---- 우발(accidental) 빼기 : DrawIBD.C 의 규약을 그대로 따른다 ----
//  on-time 창은 dt in [DT_MIN, DT_MAX] 라 폭이 (DT_MAX - DT_MIN) 인데,
//  off-time 창은 [DT_ACCI, DT_ACCI + DT_MAX] 라 폭이 DT_MAX 다. 두 폭이
//  같지 않으므로(약 1% 차이) 폭 비율로 맞춘 뒤 뺀다.
//
//      acciScale   = (DT_MAX_US - DT_MIN_US) / DT_MAX_US
//      N_candidate = N_IBD - acciScale * N_IBD_Acci
//
//  이 배율을 1 로 두면 우발을 과하게 빼서 후보 수가 낮게 나온다.
//
//  ---- R_LL 을 여기서 함께 낸다 ----
//  1.2 MeV 이상 clean single 의 rate 다. 3단계(BuildRateTrend.C)가 고립 효율
//  eps_iso 를 구하는 데 쓴다. 예전에는 Step2 part 를 서브런 몇 개 표본으로
//  열어 쟀는데, 이제 런 전체의 single 을 이미 갖고 있으므로 **표본이 아니라
//  전수**다. rll.tsv 는 더 이상 만들지 않는다.
//
//  사용 :
//     root -l -b -q 'BuildPairSummary.C+(4237, 4240)'
//     root -l -b -q 'BuildPairSummary.C+("4237,4239")'
//     root -l -b -q 'BuildPairSummary.C+(4237, 4240, true)'   이미 있어도 다시
// ---------------------------------------------------------------------------
#include <TFile.h>
#include <TObjString.h>
#include <TStopwatch.h>
#include <TSystem.h>
#include <TTree.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

//  PRD -> clean single. 컷 상수(DT_*/S2_*/ISO_*)와 SetChannel() 도 이 안에서
//  분석 쪽 AnalysisCondition.h 를 include 해 가져온다.
#include "RenePrdSingles.h"
//  페어링 loop. 검증 코드도 같은 것을 쓴다 (복사본을 검증하면 뜻이 없다).
#include "RenePairing.h"

//  tsv 스키마가 바뀌면 올린다. 옛 파일을 조용히 잘못 읽는 것보다
//  못 읽는다고 말하는 편이 낫다.
static const int kPairSchema = 2;

// ---------------------------------------------------------------------------
struct PairRow {
   int         run     = 0;
   std::string tag     = "";     // _nGd | _nH
   double      liveSec = -1;     // PRD 에서 잰 값 (Σ 서브런 livetime)
   //  선원 런인지. runtype.tsv(런카탈로그의 rundesc 에서 뽑은 것)에서 온다.
   //  이것이 없으면 AmBe 교정 런의 중성자를 neutrino 후보로 읽게 된다.
   std::string src     = "?";    // AmBe | Cs137 | ... | none | ?

   long long nPaired     = -1;   // coincidence 창 안의 쌍
   long long nPairedAcci = -1;   // off-window 쌍
   long long nIbd        = -1;   // 거기에 multiplicity 까지 통과
   long long nIbdAcci    = -1;

   double dtMin = -1, dtMax = -1, dtAcci = -1;   // 그때 쓴 창 [us]
   double s2Lo  = -1, s2Hi  = -1;                // delayed 에너지창 [MeV]
   double isoPre = -1, isoPost = -1;             // multiplicity 창 [us]

   long long nSingle = -1;       // 1.2 MeV 이상 clean single
   double    rll     = -1;       // [Hz] nSingle / liveSec (전수)
   int       nSubrun = -1;       // 실제로 읽은 서브런 수

   double acciScale() const {
      return (dtMax > 0) ? (dtMax - dtMin) / dtMax : -1;
   }
   double nAcci() const {   // 창폭을 맞춘 우발 기대값
      return (nIbdAcci >= 0 && acciScale() > 0) ? acciScale() * (double)nIbdAcci : -1;
   }
   double nCand() const {   // neutrino candidate (개략)
      return (nIbd >= 0 && nAcci() >= 0) ? (double)nIbd - nAcci() : -1;
   }
   //  통계 오차만. 계통(효율·컷 안정성)은 포함하지 않는다.
   double nCandErr() const {
      if (nIbd < 0 || nIbdAcci < 0) return -1;
      double s = acciScale();
      return std::sqrt((double)nIbd + s * s * (double)nIbdAcci);
   }
   double sOverB() const {
      double a = nAcci();
      return (a > 0 && nCand() >= 0) ? nCand() / a : -1;
   }
   //  multiplicity 로 걸러낸 비율
   double multRej() const {
      return (nPaired > 0 && nIbd >= 0) ? 1.0 - (double)nIbd / (double)nPaired : -1;
   }
   double liveDay() const { return liveSec > 0 ? liveSec / 86400.0 : -1; }
   double candPerDay() const {
      double d = liveDay();
      return (d > 0 && nCand() >= 0) ? nCand() / d : -1;
   }
   double candPerDayErr() const {
      double d = liveDay();
      return (d > 0 && nCandErr() >= 0) ? nCandErr() / d : -1;
   }
};

// ---------------------------------------------------------------------------
static std::string FmtF(double v, int prec) {
   if (v < 0) return "-";
   char b[64]; snprintf(b, sizeof(b), "%.*f", prec, v); return std::string(b);
}
//  tsv 전용. 항상 숫자를 낸다 (없는 값은 음수). '-' 를 쓰면 되읽기의 >> 가
//  실패해 그 행이 통째로 사라진다 -- 실제로 그렇게 행을 잃었다.
static std::string FmtRaw(double v, int prec) {
   char b[64]; snprintf(b, sizeof(b), "%.*f", prec, v); return std::string(b);
}
//  음수도 뜻이 있는 값(뺀 결과는 음수가 될 수 있다)
static std::string FmtSigned(double v, int prec) {
   if (v <= -1e29) return "-";
   char b[64]; snprintf(b, sizeof(b), "%.*f", prec, v); return std::string(b);
}
static std::string FmtCount(long long v) {
   if (v < 0) return "-";
   std::string s = std::to_string(v);
   for (int i = (int)s.size() - 3; i > 0; i -= 3) s.insert(i, ",");
   return s;
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

//  runtype.tsv : "<run>\t<src>" 두 열. ibd-summary.sh 가 런카탈로그에서 만든다.
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

//  옛 스키마(1)는 열이 셋 적다. 조용히 잘못 읽지 않고 버린다.
static std::map<std::string, PairRow> LoadExisting(const TString &tsv, bool &schemaOld) {
   std::map<std::string, PairRow> out;
   schemaOld = false;
   std::ifstream in(tsv.Data());
   if (!in) return out;
   int schema = 1;
   std::string line;
   while (std::getline(in, line)) {
      if (line.rfind("# schema", 0) == 0) { schema = std::atoi(line.c_str() + 8); continue; }
      if (line.empty() || line[0] == '#') continue;
      if (schema != kPairSchema) { schemaOld = true; return {}; }
      std::stringstream ss(line);
      PairRow r;
      // 열 순서는 WriteTsv 와 반드시 같아야 한다
      if (!(ss >> r.run >> r.tag >> r.src >> r.liveSec
               >> r.nPaired >> r.nPairedAcci >> r.nIbd >> r.nIbdAcci
               >> r.dtMin >> r.dtMax >> r.dtAcci
               >> r.s2Lo >> r.s2Hi >> r.isoPre >> r.isoPost
               >> r.nSingle >> r.rll >> r.nSubrun))
         continue;
      out[RowKey(r.run, r.tag)] = r;
   }
   return out;
}

static void WriteTsv(const TString &path, const std::map<std::string, PairRow> &rows) {
   std::ofstream o(path.Data());
   o << "# RENE IBD pair summary (machine readable). BuildPairSummary.C 가 만든다.\n"
        "# schema " << kPairSchema << "\n"
        "# 입력은 production 산출물 <root>/RAW/<run>/PRD/ 다. 페어링도 여기서 한다.\n"
        "# 음수는 '그 정보 없음'. 시간 [s], 창 [us], 에너지 [MeV], r_ll [Hz].\n"
        "# n_cand = n_ibd - (dt_max-dt_min)/dt_max * n_ibd_acci  (DrawIBD.C 규약)\n"
        "# src = 그 런에 들어 있던 선원. AmBe 등 선원 런의 cand 는 neutrino 가 아니다.\n"
        "#run\ttag\tsrc\tlive_s\tn_paired\tn_paired_acci\tn_ibd\tn_ibd_acci"
        "\tdt_min\tdt_max\tdt_acci\ts2_lo\ts2_hi\tiso_pre\tiso_post"
        "\tn_single\tr_ll\tn_subrun\n";
   for (const auto &kv : rows) {
      const PairRow &r = kv.second;
      o << r.run << '\t' << r.tag << '\t' << r.src << '\t' << FmtRaw(r.liveSec, 3) << '\t'
        << r.nPaired << '\t' << r.nPairedAcci << '\t'
        << r.nIbd << '\t' << r.nIbdAcci << '\t'
        << r.dtMin << '\t' << r.dtMax << '\t' << r.dtAcci << '\t'
        << r.s2Lo << '\t' << r.s2Hi << '\t' << r.isoPre << '\t' << r.isoPost << '\t'
        << r.nSingle << '\t' << FmtRaw(r.rll, 4) << '\t' << r.nSubrun << '\n';
   }
}

static void WriteTxt(const TString &path, const std::map<std::string, PairRow> &rows) {
   std::ofstream o(path.Data());
   time_t now = time(nullptr); struct tm tmv; localtime_r(&now, &tmv);
   char nowbuf[32]; strftime(nowbuf, sizeof(nowbuf), "%Y-%m-%d %H:%M:%S", &tmv);

   o << "===============================================================================\n"
        "  RENE IBD pair summary — neutrino candidate (개략)\n"
        "  " << nowbuf << " 갱신 · BuildPairSummary.C 생성 · 행 " << rows.size() << "개\n"
        "  입력 : production 산출물 <root>/RAW/<run>/PRD/  (페어링도 여기서 한다)\n"
        "===============================================================================\n"
        "  single    = 1.2 MeV 이상 clean single. muon/after-muon/포화를 뺀 것\n"
        "  R_LL      = single / livetime.  표본이 아니라 전수다\n"
        "  paired    = coincidence 창을 만족한 쌍 (delayed 하나에 prompt 하나)\n"
        "  ibd       = 거기에 multiplicity(고립) 컷까지 통과\n"
        "  acci      = off-window 쌍에 창폭 배율을 곱한 우발 기대값\n"
        "  cand      = ibd - acci.  이것이 개략적인 neutrino candidate 수다\n"
        "  err       = 통계 오차만 sqrt(ibd + scale^2 * ibd_acci).\n"
        "              효율·컷 안정성 같은 계통은 들어 있지 않다\n"
        "  S/B       = cand / acci\n"
        "  mult_rej  = 1 - ibd/paired.  multiplicity 컷이 걸러낸 비율\n"
        "\n"
        "  창폭 배율 = (dt_max - dt_min) / dt_max  -- on-time 창과 off-time 창의\n"
        "  폭이 같지 않아서 필요하다. DrawIBD.C 와 같은 규약이다.\n"
        "  '-' 는 그 정보가 아직 없다는 뜻이다.\n\n";

   // ---- 채널별 컷 ----
   o << "-- 채널 컷 (AnalysisCondition.h 의 SetChannel() 이 실제로 쓰는 값) ------------\n"
        "   문서가 아니라 코드에서 읽은 값이다. 둘이 다를 수 있다 --\n"
        "   README_pipeline.md 는 n-Gd S2 를 [7.77,9.36] 이라 적었지만 코드에서\n"
        "   그 줄은 주석이고 실제로는 [6.0,10.0] 이 쓰인다(2026-08-18 확인).\n";
   char hdr[512];
   snprintf(hdr, sizeof(hdr), "%-6s %10s %10s %10s %14s %12s\n",
            "tag", "dt[us]", "dt_acci", "scale", "S2[MeV]", "iso[us]");
   o << hdr;
   {
      std::map<std::string, PairRow> byTag;
      for (const auto &kv : rows) byTag[kv.second.tag] = kv.second;
      for (const auto &kv : byTag) {
         const PairRow &r = kv.second;
         char b[512];
         snprintf(b, sizeof(b), "%-6s %10s %10s %10s %14s %12s\n",
                  r.tag.c_str(),
                  (FmtF(r.dtMin, 0) + "-" + FmtF(r.dtMax, 0)).c_str(),
                  FmtF(r.dtAcci, 0).c_str(), FmtF(r.acciScale(), 4).c_str(),
                  (FmtF(r.s2Lo, 2) + "-" + FmtF(r.s2Hi, 2)).c_str(),
                  (FmtF(r.isoPre, 0) + "/" + FmtF(r.isoPost, 0)).c_str());
         o << b;
      }
   }

   // ---- 런별 ----
   o << "\n-- 런 × 채널 -----------------------------------------------------------------\n";
   o << "   src 가 none 이 아닌 런은 **선원을 넣고 받은 교정 런**이다.\n"
        "   그 cand 는 neutrino 가 아니라 선원이 만든 중성자다. 더하지 말 것.\n";
   snprintf(hdr, sizeof(hdr), "%-7s %-6s %-7s %12s %12s %12s %13s %8s %9s\n",
            "run", "tag", "src", "paired", "ibd", "acci", "cand", "S/B", "mult_rej");
   o << hdr;
   for (const auto &kv : rows) {
      const PairRow &r = kv.second;
      char b[512];
      snprintf(b, sizeof(b), "%-7d %-6s %-7s %12s %12s %12s %13s %8s %9s\n",
               r.run, r.tag.c_str(), r.src.c_str(),
               FmtCount(r.nPaired).c_str(), FmtCount(r.nIbd).c_str(),
               FmtF(r.nAcci(), 1).c_str(), FmtSigned(r.nCand(), 1).c_str(),
               FmtF(r.sOverB(), 2).c_str(), FmtF(r.multRej(), 4).c_str());
      o << b;
   }

   // ---- single / R_LL ----
   o << "\n-- single 과 R_LL (PRD 에서 전수로 센 값) -------------------------------------\n"
        "   R_LL 은 3단계의 고립 효율 eps_iso = exp(-R_LL*(ISO_PRE+ISO_POST)) 에 쓴다.\n"
        "   채널과 무관한 양이라 같은 런의 두 줄은 같은 값이다.\n";
   snprintf(hdr, sizeof(hdr), "%-7s %-6s %8s %14s %12s %12s\n",
            "run", "tag", "subrun", "single", "live[s]", "R_LL[Hz]");
   o << hdr;
   for (const auto &kv : rows) {
      const PairRow &r = kv.second;
      char b[512];
      snprintf(b, sizeof(b), "%-7d %-6s %8s %14s %12s %12s\n",
               r.run, r.tag.c_str(),
               (r.nSubrun >= 0 ? std::to_string(r.nSubrun) : std::string("-")).c_str(),
               FmtCount(r.nSingle).c_str(), FmtF(r.liveSec, 1).c_str(),
               FmtF(r.rll, 2).c_str());
      o << b;
   }

   // ---- livetime 기준 ----
   o << "\n-- livetime 기준 --------------------------------------------------------------\n"
        "   livetime 은 페어링에 쓴 서브런의 것을 그대로 더한 값이다.\n"
        "   run_summary 의 live_s 와 같은 방식으로 재므로 서로 맞아야 한다.\n";
   snprintf(hdr, sizeof(hdr), "%-7s %-6s %-7s %10s %14s %18s\n",
            "run", "tag", "src", "live[day]", "cand", "cand/day");
   o << hdr;
   for (const auto &kv : rows) {
      const PairRow &r = kv.second;
      char b[512];
      std::string perday = (r.candPerDay() > -1e29 && r.liveDay() > 0)
         ? FmtSigned(r.candPerDay(), 1) + "±" + FmtF(r.candPerDayErr(), 1)
         : std::string("-");
      snprintf(b, sizeof(b), "%-7d %-6s %-7s %10s %14s %18s\n",
               r.run, r.tag.c_str(), r.src.c_str(),
               FmtF(r.liveDay(), 4).c_str(), FmtSigned(r.nCand(), 1).c_str(), perday.c_str());
      o << b;
   }

   // ---- 채널별 합계 ----
   o << "\n-- 채널별 합계 (선원 없는 런만) ----------------------------------------------\n"
        "   선원 런(src != none)과 종류를 모르는 런(src = ?)은 **빼고** 더한다.\n"
        "   섞으면 교정 중성자가 neutrino 후보에 들어간다.\n";
   snprintf(hdr, sizeof(hdr), "%-6s %6s %12s %14s %14s %20s %8s %16s\n",
            "tag", "runs", "live[day]", "ibd", "acci", "cand", "S/B", "cand/day");
   o << hdr;
   std::map<std::string, std::vector<const PairRow *>> byTag;
   for (const auto &kv : rows) byTag[kv.second.tag].push_back(&kv.second);
   for (const auto &kv : byTag) {
      double live = 0, acci = 0, cand = 0, var = 0;
      long long ibd = 0;
      int nrun = 0, nliveKnown = 0, nExcluded = 0;
      for (const PairRow *r : kv.second) {
         if (r->nIbd < 0) continue;
         if (r->src != "none") { nExcluded++; continue; }
         nrun++;
         ibd  += r->nIbd;
         acci += r->nAcci();
         cand += r->nCand();
         double e = r->nCandErr(); if (e > 0) var += e * e;
         if (r->liveSec > 0) { live += r->liveSec; nliveKnown++; }
      }
      double liveDay = live / 86400.0;
      char b[512];
      std::string perday = (liveDay > 0)
         ? FmtSigned(cand / liveDay, 1) + "±" + FmtF(std::sqrt(var) / liveDay, 1)
         : std::string("-");
      snprintf(b, sizeof(b), "%-6s %6d %12s %14s %14s %20s %8s %16s\n",
               kv.first.c_str(), nrun, FmtF(liveDay, 4).c_str(),
               FmtCount(ibd).c_str(), FmtF(acci, 1).c_str(),
               (FmtSigned(cand, 1) + "±" + FmtF(std::sqrt(var), 1)).c_str(),
               FmtF(acci > 0 ? cand / acci : -1, 2).c_str(), perday.c_str());
      o << b;
      if (nliveKnown < nrun) {
         snprintf(b, sizeof(b),
                  "       [주의] %s : livetime 을 아는 런이 %d/%d 뿐이라 cand/day 는"
                  " 그만큼 과대평가다\n", kv.first.c_str(), nliveKnown, nrun);
         o << b;
      }
      if (nExcluded > 0) {
         snprintf(b, sizeof(b),
                  "       %s : 선원 런/종류 미상 %d 개를 위 합계에서 뺐다\n",
                  kv.first.c_str(), nExcluded);
         o << b;
      }
      if (nrun == 0) {
         snprintf(b, sizeof(b),
                  "       [주의] %s : 선원 없는 런이 하나도 없다. 위 줄은 빈 합계다\n",
                  kv.first.c_str());
         o << b;
      }
   }

   o << "\n  주의 -- 여기 cand 는 **개략값**이다. 우발만 뺀 것이고 검출 효율,\n"
        "  우주선 유발 배경(fast neutron, 9Li/8He), 컷 효율 보정이 들어 있지 않다.\n"
        "  물리 결과가 아니라 '수집이 정상이면 이만큼 나온다'는 운용 지표로 볼 것.\n"
        "===============================================================================\n";
}

// ---------------------------------------------------------------------------
//  분석 쪽 Step4 산출물이 있으면 수를 맞춰 본다. 페어링 규칙이 갈라졌는지
//  보는 유일한 방법이라 **자동으로 늘 해 본다**. 없으면 조용히 넘어간다.
static void CheckAgainstAnalysis(int run, const std::string &tag,
                                 long long nIbd, long long nIbdAcci,
                                 const TString &sampleDir) {
   if (sampleDir.IsNull()) return;
   TString f4 = TString::Format("%sStep3/step4_Run%s%s.root",
                                sampleDir.Data(), ReneRunStr(run).Data(), tag.c_str());
   if (gSystem->AccessPathName(f4)) return;
   TFile *f = TFile::Open(f4, "READ");
   if (!f || f->IsZombie()) { if (f) f->Close(); return; }
   TTree *t1 = (TTree *)f->Get("T_IBD");
   TTree *t2 = (TTree *)f->Get("T_IBD_Acci");
   long long a = t1 ? t1->GetEntries() : -1;
   long long b = t2 ? t2->GetEntries() : -1;
   f->Close();
   if (a < 0) return;
   const char *mark = (a == nIbd && b == nIbdAcci) ? "일치" : "★ 다르다";
   printf("    [대조] run %d%-5s : 분석 Step4 ibd=%lld acci=%lld / 여기 %lld %lld  -> %s\n",
          run, tag.c_str(), a, b, nIbd, nIbdAcci, mark);
   if (a != nIbd || b != nIbdAcci)
      printf("           페어링 규칙이 갈라졌을 수 있다. RunBothChannels.C 를 확인할 것\n");
}

// ---------------------------------------------------------------------------
static void Impl(const std::vector<int> &runs, bool force, const char *outDir,
                 const char *rawRoots, double vetoCutUs, int maxSubrun,
                 const char *sampleDir) {
   TString out(outDir), roots(rawRoots), sample(sampleDir ? sampleDir : "");
   if (!out.EndsWith("/")) out += "/";
   if (!sample.IsNull() && !sample.EndsWith("/")) sample += "/";

   if (gSystem->mkdir(out, kTRUE) != 0 && gSystem->AccessPathName(out, kWritePermission)) {
      printf("[FATAL] 출력 디렉터리에 쓸 수 없다 : %s\n", out.Data());
      return;
   }
   TString txtPath  = out + "pair_summary.txt";
   TString tsvPath  = out + "pair_summary.tsv";
   TString cacheDir = out + "cache/singles/";

   bool schemaOld = false;
   std::map<std::string, PairRow> rows = LoadExisting(tsvPath, schemaOld);
   if (schemaOld) {
      printf("[WARN] 기존 pair_summary.tsv 가 옛 스키마다. 버리고 새로 만든다.\n"
             "        입력이 Step3/Step4 에서 PRD 로 바뀌어 열이 달라졌다.\n");
   }
   printf("[INFO] 기존 pair_summary : %zu 행 (%s)\n", rows.size(), tsvPath.Data());
   printf("[INFO] 입력 : <root>/<run>/PRD/  root = %s\n", roots.Data());
   printf("[INFO] 캐시 : %s\n", cacheDir.Data());

   std::map<int, std::string> rtype = LoadRunTypes(out + "runtype.tsv");
   printf("[INFO] 선원 정보를 아는 런 : %zu 개 (runtype.tsv)\n", rtype.size());
   if (rtype.empty())
      printf("[WARN] runtype.tsv 가 없다. 선원 런을 구분할 수 없어 합계에서 "
             "전부 제외된다 -- ibd-summary.sh 로 돌리면 자동으로 만들어진다\n");

   //  single 문턱은 두 채널의 S1/S2 최소값 중 가장 낮은 것이다. 이 값 아래는
   //  어느 채널에서도 쓰이지 않으므로 캐시에 담을 필요가 없다.
   //  (RunBothChannels.C 가 Step2 를 읽을 때 쓰는 thr 과 같은 계산이다)
   SetChannel(CH_NH);  double thrNH = std::min(S1_MIN_NPE, S2_MIN_NPE);
   SetChannel(CH_NGD); double thrGd = std::min(S1_MIN_NPE, S2_MIN_NPE);
   const double thr = std::min(thrNH, thrGd);
   printf("[INFO] single 문턱 : %.1f NPE (%.3f MeV)\n", thr, thr / _NPE_MEV);

   const Channel chans[2] = {CH_NGD, CH_NH};
   int nNew = 0, nSkip = 0, nMiss = 0;
   for (int run : runs) {
      //  두 채널 모두 이미 있으면 PRD 를 아예 열지 않는다. 이것이 없으면
      //  이미 끝난 런의 파형을 매번 다시 읽게 된다.
      bool haveAll = true;
      for (Channel ch : chans) {
         SetChannel(ch);
         if (!rows.count(RowKey(run, ChannelTag(ch).Data()))) haveAll = false;
      }
      if (!force && haveAll) { nSkip += 2; continue; }

      TStopwatch w; w.Start();
      ReneRunSingles rs;
      if (!ReneLoadRunSingles(run, roots, cacheDir, thr, vetoCutUs, maxSubrun, 50, rs)) {
         nMiss++;
         continue;
      }
      w.Stop();
      printf("  run %d : 서브런 %d (캐시 %d / 새로 %d / 실패 %d)  single %zu  "
             "live %.1f s  R_LL %.2f Hz  [%.1f s]\n",
             run, rs.nSubrun, rs.nFromCache, rs.nRead, rs.nBad, rs.singles.size(),
             rs.liveSec, rs.rateLL(), w.RealTime());

      for (Channel ch : chans) {
         SetChannel(ch);
         std::string tag = ChannelTag(ch).Data();
         std::string key = RowKey(run, tag);
         if (!force && rows.count(key)) { nSkip++; continue; }

         PairCounts pc = PairAndCount(rs.singles);

         PairRow r;
         r.run = run;
         r.tag = tag;
         r.liveSec = rs.liveSec;
         r.nPaired = pc.nCoinc;   r.nPairedAcci = pc.nAcci;
         r.nIbd    = pc.nCoincMult; r.nIbdAcci  = pc.nAcciMult;
         r.dtMin = DT_MIN_US; r.dtMax = DT_MAX_US; r.dtAcci = DT_ACCI_US;
         r.s2Lo  = S2_E_MIN_MEV; r.s2Hi = S2_E_MAX_MEV;
         r.isoPre = ISO_PRE_US;  r.isoPost = ISO_POST_US;
         r.nSingle = (long long)rs.singles.size();
         r.rll     = rs.rateLL();
         r.nSubrun = rs.nSubrun;
         auto ir = rtype.find(run);
         if (ir != rtype.end()) r.src = ir->second;

         bool replaced = rows.count(key) > 0;
         rows[key] = r;
         nNew++;
         printf("  [%s] run %d%-5s : paired=%s  ibd=%s  acci=%.1f  cand=%.1f±%.1f\n",
                replaced ? "REDO" : " NEW", run, tag.c_str(),
                FmtCount(r.nPaired).c_str(), FmtCount(r.nIbd).c_str(),
                r.nAcci(), r.nCand(), r.nCandErr());
         CheckAgainstAnalysis(run, tag, r.nIbd, r.nIbdAcci, sample);
      }
      //  런 하나가 몇 분~몇 시간이다. 중간에 끊겨도 한 것은 남도록 그때그때
      //  쓴다 (BuildRunSummary.C 와 같은 이유).
      WriteTsv(tsvPath, rows);
      WriteTxt(txtPath, rows);
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
   WriteTxt(txtPath, rows);
   printf("[SAVED] %s\n[SAVED] %s\n", txtPath.Data(), tsvPath.Data());
   printf("[DONE ] 새로/다시 쓴 행 %d, 선원 보충 %d, 건너뜀 %d, 자료 없음 %d, 표에 %zu 행\n",
          nNew, nFilled, nSkip, nMiss, rows.size());
}

// ---------------------------------------------------------------------------
//  rawRoots : ':' 로 나눈 목록. 앞에 오는 것이 이긴다.
//  sampleDir: 분석 산출물. 대조에만 쓴다. ""(빈 문자열)이면 대조하지 않는다.
void BuildPairSummary(int runFirst, int runLast = -1, bool force = false,
                      const char *outDir    = "/scratch/RunSummary/",
                      const char *rawRoots  = "/Data_ssd/RAW:/data/RAW:/scratch/RAW",
                      double vetoCutUs = 150.0, int maxSubrun = -1,
                      const char *sampleDir = "/scratch/junkyo/SampleFiles/") {
   if (runLast < runFirst) runLast = runFirst;
   std::vector<int> runs;
   for (int r = runFirst; r <= runLast; ++r) runs.push_back(r);
   Impl(runs, force, outDir, rawRoots, vetoCutUs, maxSubrun, sampleDir);
}

void BuildPairSummary(const char *runList, bool force = false,
                      const char *outDir    = "/scratch/RunSummary/",
                      const char *rawRoots  = "/Data_ssd/RAW:/data/RAW:/scratch/RAW",
                      double vetoCutUs = 150.0, int maxSubrun = -1,
                      const char *sampleDir = "/scratch/junkyo/SampleFiles/") {
   std::vector<int> runs = ParseRunList(runList);
   if (runs.empty()) { printf("[FATAL] 런 목록이 비어 있다\n"); return; }
   Impl(runs, force, outDir, rawRoots, vetoCutUs, maxSubrun, sampleDir);
}
