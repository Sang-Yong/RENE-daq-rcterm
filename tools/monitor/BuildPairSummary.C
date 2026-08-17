// ---------------------------------------------------------------------------
//  BuildPairSummary.C - 페어링 결과에서 neutrino(IBD) candidate 수를 뽑아
//                       채널별로 누적한다.
//
//  BuildRunSummary.C 가 'DAQ 가 무엇을 받았나'라면 이쪽은 그 다음 단계 --
//  '그 중 몇 개가 IBD 후보로 남았나'다. 둘은 run 번호로 이어진다.
//
//  무엇을 읽나 (분석 코드의 산출물. 여기서 페어링을 새로 하지 않는다)
//     <SampleDir>/Step3/step3_Run<NNNNNN><tag>.root : T_Paired , T_Paired_Acci
//     <SampleDir>/Step3/step4_Run<NNNNNN><tag>.root : T_IBD    , T_IBD_Acci
//     <OutDir>/run_summary.tsv                      : livetime (있으면 이어붙인다)
//  tag 는 "_nGd" / "_nH". 없으면 RunBothChannels.C(<run>) 를 먼저 돌려야 한다.
//
//  무엇을 쓰나
//     <OutDir>/pair_summary.txt   사람이 읽는 표
//     <OutDir>/pair_summary.tsv   되읽기·그림용
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
//  DrawIBD.C:164 의 h_dt_sub->Add(h_dt_on, h_dt_acci, 1.0, -acciScale) 와
//  같은 양을 세는 것이 목적이다. 규약을 바꾸려면 그쪽과 함께 바꿀 것.
//
//  ---- 컷 상수는 복제하지 않는다 ----
//  DT_MIN/DT_MAX 등은 분석 쪽 essential/AnalysisCondition.h 에서 가져온다.
//  여기에 베껴 두면 저쪽이 컷을 바꿨을 때 이 표만 조용히 틀린 값이 된다.
//  경로는 -DRENE_COND_HEADER=... 로 바꿀 수 있다.
//
//  사용 :
//     root -l -b -q 'BuildPairSummary.C+(4237, 4240)'
//     root -l -b -q 'BuildPairSummary.C+("4237,4239")'
//     root -l -b -q 'BuildPairSummary.C+(4237, 4240, true)'   이미 있어도 다시
// ---------------------------------------------------------------------------
#ifndef RENE_COND_HEADER
#define RENE_COND_HEADER "/home/ojk/analysis3/essential/AnalysisCondition.h"
#endif

#include <TFile.h>
#include <TTree.h>
#include <TSystem.h>
#include <TString.h>

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

//  컷 상수와 SetChannel() / ChannelTag() 를 가져온다.
#include RENE_COND_HEADER

// ---------------------------------------------------------------------------
struct PairRow {
   int         run     = 0;
   std::string tag     = "";     // _nGd | _nH
   double      liveSec = -1;     // run_summary.tsv 에서 이어붙인 값
   //  선원 런인지. runtype.tsv(런카탈로그의 rundesc 에서 뽑은 것)에서 온다.
   //  이것이 없으면 AmBe 교정 런의 중성자를 neutrino 후보로 읽게 된다.
   std::string src     = "?";    // AmBe | Cs137 | ... | none | ?

   long long nPaired     = -1;   // Step3 T_Paired       (coincidence)
   long long nPairedAcci = -1;   // Step3 T_Paired_Acci  (off-window)
   long long nIbd        = -1;   // Step4 T_IBD          (multiplicity 통과)
   long long nIbdAcci    = -1;   // Step4 T_IBD_Acci

   double dtMin = -1, dtMax = -1, dtAcci = -1;   // 그때 쓴 창 [us]
   double s2Lo  = -1, s2Hi  = -1;                // delayed 에너지창 [MeV]
   double isoPre = -1, isoPost = -1;             // multiplicity 창 [us]

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
static TString RunStr(int run) { return TString::Format("%06d", run); }

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

//  run_summary.tsv 에서 livetime 만 가져온다. 없으면 그냥 비운다.
static std::map<int, double> LoadLivetimes(const TString &tsv) {
   std::map<int, double> out;
   std::ifstream in(tsv.Data());
   if (!in) return out;
   std::string line;
   while (std::getline(in, line)) {
      if (line.empty() || line[0] == '#') continue;
      std::stringstream ss(line);
      int run, nsub; double es, ee, wall, span, live;
      if (!(ss >> run >> nsub >> es >> ee >> wall >> span >> live)) continue;
      out[run] = live;
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

static long long EntriesOf(TFile *f, const char *name) {
   if (!f || f->IsZombie()) return -1;
   TTree *t = (TTree *)f->Get(name);
   return t ? t->GetEntries() : -1;
}

// ---------------------------------------------------------------------------
static bool BuildOne(int run, Channel ch, const TString &sampleDir,
                     double vetoCutUs, PairRow &row) {
   SetChannel(ch);                       // DT_*/S2_*/ISO_* 가 이 채널 값으로 바뀐다
   TString tag  = ChannelTag(ch);
   TString vtag = (vetoCutUs == 150.0) ? "" : TString::Format("_veto%.0f", vetoCutUs);

   TString f3n = TString::Format("%sStep3/step3_Run%s%s%s.root",
                                 sampleDir.Data(), RunStr(run).Data(), tag.Data(), vtag.Data());
   TString f4n = TString::Format("%sStep3/step4_Run%s%s%s.root",
                                 sampleDir.Data(), RunStr(run).Data(), tag.Data(), vtag.Data());

   bool has3 = !gSystem->AccessPathName(f3n);
   bool has4 = !gSystem->AccessPathName(f4n);
   if (!has3 && !has4) return false;     // 이 채널은 아직 페어링 전

   row = PairRow();
   row.run = run;
   row.tag = tag.Data();
   row.dtMin = DT_MIN_US; row.dtMax = DT_MAX_US; row.dtAcci = DT_ACCI_US;
   row.s2Lo  = S2_E_MIN_MEV; row.s2Hi = S2_E_MAX_MEV;
   row.isoPre = ISO_PRE_US;  row.isoPost = ISO_POST_US;

   if (has3) {
      TFile *f3 = TFile::Open(f3n, "READ");
      row.nPaired     = EntriesOf(f3, "T_Paired");
      row.nPairedAcci = EntriesOf(f3, "T_Paired_Acci");
      if (f3) f3->Close();
   }
   if (has4) {
      TFile *f4 = TFile::Open(f4n, "READ");
      row.nIbd     = EntriesOf(f4, "T_IBD");
      row.nIbdAcci = EntriesOf(f4, "T_IBD_Acci");
      if (f4) f4->Close();
   } else {
      printf("  [WARN] run %d%s : step4 가 없다. multiplicity 이전 수만 적는다\n",
             run, tag.Data());
   }
   return true;
}

// ---------------------------------------------------------------------------
static std::string RowKey(int run, const std::string &tag) {
   char b[32]; snprintf(b, sizeof(b), "%06d", run);
   return std::string(b) + tag;
}

static std::map<std::string, PairRow> LoadExisting(const TString &tsv) {
   std::map<std::string, PairRow> out;
   std::ifstream in(tsv.Data());
   if (!in) return out;
   std::string line;
   while (std::getline(in, line)) {
      if (line.empty() || line[0] == '#') continue;
      std::stringstream ss(line);
      PairRow r;
      // 열 순서는 WriteTsv 와 반드시 같아야 한다
      if (!(ss >> r.run >> r.tag >> r.src >> r.liveSec
               >> r.nPaired >> r.nPairedAcci >> r.nIbd >> r.nIbdAcci
               >> r.dtMin >> r.dtMax >> r.dtAcci
               >> r.s2Lo >> r.s2Hi >> r.isoPre >> r.isoPost))
         continue;
      out[RowKey(r.run, r.tag)] = r;
   }
   return out;
}

static void WriteTsv(const TString &path, const std::map<std::string, PairRow> &rows) {
   std::ofstream o(path.Data());
   o << "# RENE IBD pair summary (machine readable). BuildPairSummary.C 가 만든다.\n"
        "# 음수는 '그 정보 없음'. 시간 [s], 창 [us], 에너지 [MeV].\n"
        "# n_cand = n_ibd - (dt_max-dt_min)/dt_max * n_ibd_acci  (DrawIBD.C 규약)\n"
        "# src = 그 런에 들어 있던 선원. AmBe 등 선원 런의 cand 는 neutrino 가 아니다.\n"
        "#run\ttag\tsrc\tlive_s\tn_paired\tn_paired_acci\tn_ibd\tn_ibd_acci"
        "\tdt_min\tdt_max\tdt_acci\ts2_lo\ts2_hi\tiso_pre\tiso_post\n";
   for (const auto &kv : rows) {
      const PairRow &r = kv.second;
      o << r.run << '\t' << r.tag << '\t' << r.src << '\t' << FmtRaw(r.liveSec, 3) << '\t'
        << r.nPaired << '\t' << r.nPairedAcci << '\t'
        << r.nIbd << '\t' << r.nIbdAcci << '\t'
        << r.dtMin << '\t' << r.dtMax << '\t' << r.dtAcci << '\t'
        << r.s2Lo << '\t' << r.s2Hi << '\t' << r.isoPre << '\t' << r.isoPost << '\n';
   }
}

static void WriteTxt(const TString &path, const std::map<std::string, PairRow> &rows) {
   std::ofstream o(path.Data());
   time_t now = time(nullptr); struct tm tmv; localtime_r(&now, &tmv);
   char nowbuf[32]; strftime(nowbuf, sizeof(nowbuf), "%Y-%m-%d %H:%M:%S", &tmv);

   o << "===============================================================================\n"
        "  RENE IBD pair summary — neutrino candidate (개략)\n"
        "  " << nowbuf << " 갱신 · BuildPairSummary.C 생성 · 행 " << rows.size() << "개\n"
        "===============================================================================\n"
        "  paired    = Step3 T_Paired.      coincidence 를 만족한 쌍\n"
        "  ibd       = Step4 T_IBD.         거기에 multiplicity(고립) 컷까지 통과\n"
        "  acci      = Step4 T_IBD_Acci 에 창폭 배율을 곱한 우발 기대값\n"
        "  cand      = ibd - acci.  이것이 개략적인 neutrino candidate 수다\n"
        "  err       = 통계 오차만 sqrt(ibd + scale^2 * ibd_acci).\n"
        "              효율·컷 안정성 같은 계통은 들어 있지 않다\n"
        "  S/B       = cand / acci\n"
        "  mult_rej  = 1 - ibd/paired.  multiplicity 컷이 걸러낸 비율\n"
        "\n"
        "  창폭 배율 = (dt_max - dt_min) / dt_max  -- on-time 창과 off-time 창의\n"
        "  폭이 같지 않아서 필요하다. DrawIBD.C 와 같은 규약이다.\n"
        "  '-' 는 그 정보가 아직 없다는 뜻이다 (페어링 전 등).\n\n";

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

   // ---- livetime 기준 ----
   o << "\n-- livetime 기준 (run_summary.tsv 에서 이어붙인 값) ---------------------------\n"
        "   live 가 '-' 면 그 런이 아직 run_summary 에 없다는 뜻이다.\n"
        "   run-summary.sh 를 먼저 돌리면 채워진다.\n";
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
static void Impl(const std::vector<int> &runs, bool force,
                 const char *outDir, const char *sampleDir, double vetoCutUs) {
   TString out(outDir), sample(sampleDir);
   if (!out.EndsWith("/"))    out    += "/";
   if (!sample.EndsWith("/")) sample += "/";

   if (gSystem->mkdir(out, kTRUE) != 0 && gSystem->AccessPathName(out, kWritePermission)) {
      printf("[FATAL] 출력 디렉터리에 쓸 수 없다 : %s\n", out.Data());
      return;
   }
   TString txtPath = out + "pair_summary.txt";
   TString tsvPath = out + "pair_summary.tsv";

   std::map<std::string, PairRow> rows = LoadExisting(tsvPath);
   printf("[INFO] 기존 pair_summary : %zu 행 (%s)\n", rows.size(), tsvPath.Data());

   std::map<int, std::string> rtype = LoadRunTypes(out + "runtype.tsv");
   printf("[INFO] 선원 정보를 아는 런 : %zu 개 (runtype.tsv)\n", rtype.size());
   if (rtype.empty())
      printf("[WARN] runtype.tsv 가 없다. 선원 런을 구분할 수 없어 합계에서 "
             "전부 제외된다 -- ibd-summary.sh 로 돌리면 자동으로 만들어진다\n");

   std::map<int, double> live = LoadLivetimes(out + "run_summary.tsv");
   printf("[INFO] livetime 을 아는 런 : %zu 개 (run_summary.tsv)\n", live.size());
   if (live.empty())
      printf("[WARN] run_summary.tsv 가 없다. cand/day 는 비워 둔다 -- "
             "run-summary.sh 를 먼저 돌릴 것\n");

   const Channel chans[2] = {CH_NGD, CH_NH};
   int nNew = 0, nSkip = 0, nMiss = 0;
   for (int run : runs) {
      bool anyForRun = false;
      for (Channel ch : chans) {
         SetChannel(ch);
         std::string key = RowKey(run, ChannelTag(ch).Data());
         if (!force && rows.count(key)) { nSkip++; anyForRun = true; continue; }
         PairRow r;
         if (!BuildOne(run, ch, sample, vetoCutUs, r)) continue;
         auto it = live.find(run);
         if (it != live.end()) r.liveSec = it->second;
         auto ir = rtype.find(run);
         if (ir != rtype.end()) r.src = ir->second;
         bool replaced = rows.count(key) > 0;
         rows[key] = r;
         nNew++; anyForRun = true;
         printf("  [%s] run %d%-5s : paired=%s  ibd=%s  acci=%.1f  cand=%.1f±%.1f\n",
                replaced ? "REDO" : " NEW", run, r.tag.c_str(),
                FmtCount(r.nPaired).c_str(), FmtCount(r.nIbd).c_str(),
                r.nAcci(), r.nCand(), r.nCandErr());
      }
      if (!anyForRun) {
         printf("  [SKIP] run %d : step3/step4 가 없다 "
                "(RunBothChannels.C(%d) 를 먼저 돌릴 것)\n", run, run);
         nMiss++;
      }
   }

   //  이미 있던 행도 livetime / 선원이 새로 생겼으면 채워 준다.
   int nLiveFilled = 0;
   for (auto &kv : rows) {
      if (kv.second.liveSec <= 0) {
         auto it = live.find(kv.second.run);
         if (it != live.end() && it->second > 0) { kv.second.liveSec = it->second; nLiveFilled++; }
      }
      if (kv.second.src == "?") {
         auto ir = rtype.find(kv.second.run);
         if (ir != rtype.end()) { kv.second.src = ir->second; nLiveFilled++; }
      }
   }
   if (nLiveFilled > 0) printf("[INFO] livetime/선원을 새로 채운 칸 : %d\n", nLiveFilled);

   if (nNew == 0 && nLiveFilled == 0) {
      printf("[INFO] 새로 더한 것이 없다 (건너뜀 %d, 자료 없음 %d). 파일은 그대로 둔다.\n",
             nSkip, nMiss);
      return;
   }
   WriteTsv(tsvPath, rows);
   WriteTxt(txtPath, rows);
   printf("[SAVED] %s\n[SAVED] %s\n", txtPath.Data(), tsvPath.Data());
   printf("[DONE ] 새로/다시 쓴 행 %d, livetime 보충 %d, 건너뜀 %d, 자료 없음 %d, 표에 %zu 행\n",
          nNew, nLiveFilled, nSkip, nMiss, rows.size());
}

void BuildPairSummary(int runFirst, int runLast = -1, bool force = false,
                      const char *outDir    = "/scratch/RunSummary/",
                      const char *sampleDir = "/scratch/junkyo/SampleFiles/",
                      double vetoCutUs = 150.0) {
   if (runLast < runFirst) runLast = runFirst;
   std::vector<int> runs;
   for (int r = runFirst; r <= runLast; ++r) runs.push_back(r);
   Impl(runs, force, outDir, sampleDir, vetoCutUs);
}

void BuildPairSummary(const char *runList, bool force = false,
                      const char *outDir    = "/scratch/RunSummary/",
                      const char *sampleDir = "/scratch/junkyo/SampleFiles/",
                      double vetoCutUs = 150.0) {
   std::vector<int> runs = ParseRunList(runList);
   if (runs.empty()) { printf("[FATAL] 런 목록이 비어 있다\n"); return; }
   Impl(runs, force, outDir, sampleDir, vetoCutUs);
}
