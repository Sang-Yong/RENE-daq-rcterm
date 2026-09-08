// ---------------------------------------------------------------------------
//  BuildMetrics.C - DST 에서 런 지표를 계산한다. PRD 는 읽지 않는다.
//  IBD/acci 는 legacy(BuildPairSummary)와 같은 값이어야 하며 metrics.sh
//  --verify 가 그것을 대조한다. Li/He·fast-n 은 ★예비 레시피다.
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
//  ---- Li/He·fast-n 은 ★예비 레시피다 (분석팀 검증 전) ----
//  n_lihe/e_lihe/lihe_stat 과 n_fn_side/n_fn_side_scaled/n_fn_mutag 를 여기서
//  채운다. 문턱·창·사이드밴드는 하나도 여기 박아 두지 않는다 -- 전부
//  config/monitorcuts.params 에서 매크로 인자로 들어오고, 그때 쓴 값을 TSV 의
//  컷 열(mu_shower_npe/fn_e_lo/fn_e_hi/fn_tag_s/lihe_fit_lo/lihe_fit_hi)에
//  함께 적는다. 표만 보고 '어떤 컷의 결과인가' 를 알 수 있어야 하기 때문이다.
//  웹은 검증 전까지 이 값을 '(예비)' 로 표시한다.
//
//  ---- IBD 컷 오버라이드 ----
//  마지막 인자 ibdOverrides ("dt_max_us=120,s2_lo_mev=5.5" 꼴) 가 있으면
//  AnalysisCondition.h 대신 그 값으로 페어링한다. 빈 문자열이 기본이고, 그때만
//  legacy 와 컷이 같아 metrics.sh --verify 로 대조할 수 있다 -- 오버라이드가
//  하나라도 있으면 metrics.sh 가 --verify 를 그 자리에서 거부한다.
//  TSV 의 컷 열에는 언제나 **적용된 실효값**이 들어간다.
// ---------------------------------------------------------------------------
#include "RenePrdSingles.h"     // S1S2_Candidate, SetChannel, ChannelTag
#include "RenePairing.h"
#include <algorithm>            // std::sort (두 포인터의 전제)
#include <cmath>                // std::hypot (Li/He 오차 합성)
#include <cstdlib>              // std::atoi (LoadExisting 의 schema 파싱)
#include <fstream>
#include <map>
#include <sstream>
#include <TF1.h>
#include <TH1D.h>
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
//  ---- Li/He·fast-n 의 공통 걸음 ----
//  '샤워링 뮤온' = target 파형이 있고(pe > 0) NPE 가 문턱을 넘은 뮤온.
//  순수 veto 뮤온은 pe = -1 이라(RenePrdSingles.h) 문턱이 아무리 낮아도
//  샤워링으로 세어지지 않는다 -- target 을 지나지 않은 뮤온은 target 안에
//  Li/He 를 만들지 못한다.
//
//  런 하나에 뮤온이 수천만 건이라(실측 run 4305 : 6,865만) 태그마다 다시
//  훑지 않는다. 런에서 한 번만 뽑아 두고 두 태그가 나눠 쓴다.
static std::vector<double> ShowerTimes(const std::vector<ReneMuon> &mu,
                                       double muShowerNpe) {
   std::vector<double> s;
   for (const auto &m : mu)
      if (m.pe > muShowerNpe) s.push_back(m.t_us);
   //  DST 는 이미 시간 순이지만, 아래 두 포인터의 전제라 못박는다
   //  (샤워링 뮤온은 전체의 일부라 정렬 자체는 싸다).
   std::sort(s.begin(), s.end());
   return s;
}

//  후보 prompt 마다 **직전 샤워링 뮤온**까지의 dt 를 재서 히스토그램에 담고,
//  같은 걸음에서 fast-n 의 뮤온 태그 수(dt < fnTagS)도 센다. 둘 다 '직전
//  뮤온까지의 시간' 이라 한 번만 걸으면 된다.
//
//  ★ 앞에 샤워링 뮤온이 없는 후보(런 첫머리)는 뺀다. 런 시작을 뮤온으로
//    치면 첫 빈이 부풀어 적합이 그리로 끌려간다.
static void LiHeWalk(const std::vector<double> &promptT,
                     const std::vector<double> &showers,
                     double fnTagS, TH1D *h, long long *nTag) {
   if (nTag) *nTag = 0;
   //  promptT 는 delayed 순서로 쌓인다. S2 는 시간 순이지만 dt 가 제각각이라
   //  prompt 시각은 국소적으로 어긋날 수 있다(dt=2us 짜리 뒤에 dt=100us 짜리).
   //  두 포인터는 양쪽이 시간 순이어야 하므로 사본을 정렬해 쓴다.
   std::vector<double> pt = promptT;
   std::sort(pt.begin(), pt.end());
   size_t j = 0;
   bool   have = false;
   double lastShower = 0;
   for (double t : pt) {
      while (j < showers.size() && showers[j] < t) {
         lastShower = showers[j]; ++j; have = true;
      }
      if (!have) continue;
      double dtS = (t - lastShower) * 1e-6;      // us -> s
      if (h) h->Fill(dtS);
      if (nTag && dtS < fnTagS) (*nTag)++;
   }
}

//  ⁹Li(τ=257 ms) + ⁸He(τ=172 ms) + 상수(우발). τ 는 **고정**이다 -- 이
//  통계로 τ 까지 띄우면 두 성분이 서로를 흡수해 아무 값이나 나온다.
//  [3] = 빈 폭. 파라미터로 두고 고정하는 것은 적합 함수가 '밀도 × 빈 폭 =
//  그 빈의 기대 계수' 여야 [0]/[1] 이 곧 개수로 읽히기 때문이다.
//
//  ★ lo(= lihe_fit_lo_s)는 이 binning 에서 **빈 폭보다 작으면 아무 일도 하지
//    않는다.** ROOT 는 적합에 쓸 빈을 빈 **중심**으로 고르므로, 첫 빈의 중심
//    (빈 폭/2 = lihe_fit_hi_s/400, 기본값이면 0.025 s)보다 작은 lo 는 어떤 빈도
//    빼지 않는다. 기본값 0.002 s 가 바로 그 경우다 -- 첫 빈을 정말 빼려면
//    빈 폭(lihe_fit_hi_s/200, 기본 0.05 s) 위로 올려야 한다. TSV 의
//    lihe_fit_lo 열에는 '요청한 값' 이 그대로 적힌다.
static bool FitLiHe(TH1D *h, const TString &fname, double lo, double hi,
                    double &n, double &e) {
   TF1 f(fname, "[0]/0.257*exp(-x/0.257)*[3] + [1]/0.172*exp(-x/0.172)*[3] + [2]",
         lo, hi);
   f.SetParameters(10, 10, 1, h->GetBinWidth(1));
   f.FixParameter(3, h->GetBinWidth(1));
   f.SetParLimits(0, 0, 1e9); f.SetParLimits(1, 0, 1e9); f.SetParLimits(2, 0, 1e9);
   int rc = h->Fit(&f, "QRN0");
   if (rc != 0) return false;
   n = f.GetParameter(0) + f.GetParameter(1);
   e = std::hypot(f.GetParError(0), f.GetParError(1));
   return true;
}

// ---------------------------------------------------------------------------
//  "k=v,k=v" 를 PairWindows 에 얹는다. 빈 문자열이면 아무것도 하지 않는다
//  (= AnalysisCondition.h 값 그대로. 그때만 legacy 대조가 성립한다).
//  키 10종은 PairWindows 의 멤버와 1:1 이다.
//
//  ★ *_mev 는 **분석 헤더 자신의 MeVToNpe() 로** NPE 로 바꾼다. 창 상수를
//    만든 바로 그 함수다 (AnalysisCondition.h : S2_MIN_NPE = MeVToNpe(6)).
//    선형 상수 _NPE_MEV 를 곱하면 창을 정의한 식과 변환식이 어긋나, 같은 MeV
//    숫자가 기본값과 다른 창이 된다 (6 MeV : 3632 대 3053 NPE). 지금은
//    's2_lo_mev = 6' 이 기본 창을 정확히 되살린다 -- 오버라이드가 무엇을
//    바꾸는지 MeV 숫자만 보고 알 수 있다는 뜻이다 (컨트롤러 판정 R5).
//    ★ 그래도 --verify 는 오버라이드가 있으면 언제나 거부한다. 값이 우연히
//    기본과 같은지를 부동소수 비교로 가려 게이트를 여는 것보다, 거부하는
//    쪽이 안전하다. 실효값은 TSV 의 컷 열에 적히므로 표가 스스로 증언한다.
//
//  s2LoMev/s2HiMev 는 TSV 의 s2_lo/s2_hi 열에 적을 실효값[MeV]이다. NPE 에서
//  되돌려 나눌 수 없어(정변환이 비선형) 따로 받는다.
static void ApplyOverrides(PairWindows &w, double &s2LoMev, double &s2HiMev,
                           const TString &ovr) {
   if (ovr.IsNull()) return;
   TObjArray *kv = TString(ovr).Tokenize(",");
   for (int i = 0; i < kv->GetEntries(); ++i) {
      TString t = ((TObjString *)kv->At(i))->GetString();
      t = t.Strip(TString::kBoth);
      Ssiz_t eq = t.First('=');
      if (eq < 1) continue;
      TString k = t(0, eq);
      double  v = TString(t(eq + 1, t.Length())).Atof();
      k = k.Strip(TString::kBoth);
      if      (k == "s1_lo_npe")   w.s1lo = v;
      else if (k == "s1_hi_npe")   w.s1hi = v;
      else if (k == "s2_lo_mev")  { w.s2lo = MeVToNpe(v); s2LoMev = v; }
      else if (k == "s2_hi_mev")  { w.s2hi = MeVToNpe(v); s2HiMev = v; }
      else if (k == "dt_min_us")   w.dtMin = v;
      else if (k == "dt_max_us")   w.dtMax = v;
      else if (k == "dt_acci_us")  w.dtAcci = v;
      else if (k == "iso_pre_us")  w.isoPre = v;
      else if (k == "iso_post_us") w.isoPost = v;
      else if (k == "lower_npe")   w.lower = v;
      else printf("  [WARN] 모르는 오버라이드 키 : %s\n", k.Data());
   }
   delete kv;
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
                 double fnTagS, bool force, const TString &ibdOvr) {
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

   //  ★ 예비 레시피의 손잡이. 값이 어디서 왔는지 로그에 남긴다 -- 나중에
   //    'n_lihe 가 왜 저 값이냐' 를 이 한 줄로 되짚을 수 있어야 한다.
   printf("[INFO] Li/He·fast-n 컷 (★예비) : muShowerNpe=%.1f "
          "liheFit=[%.3f,%.1f]s liheMinCand=%d fnE=[%.2f,%.2f]MeV fnTagS=%.2fs\n",
          muShowerNpe, liheFitLoS, liheFitHiS, liheMinCand, fnELoMev, fnEHiMev, fnTagS);
   if (!ibdOvr.IsNull())
      printf("[INFO] ★ IBD 컷 오버라이드 : %s  (legacy 와 컷이 다르다. "
             "--verify 는 거부된다)\n", ibdOvr.Data());

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

      //  샤워링 뮤온은 태그와 무관하다. 런에서 한 번만 뽑는다.
      std::vector<double> showers = ShowerTimes(mu, muShowerNpe);
      printf("  run %d : 샤워링 뮤온 %zu 개 (pe > %.0f NPE, 전체 뮤온의 %.3f%%)\n",
             run, showers.size(), muShowerNpe,
             mu.empty() ? 0.0 : 100.0 * showers.size() / mu.size());
      //  ★ 이 레시피가 성립하려면 '상관 없는 후보의 dt 분포' 가 평평해야 한다.
      //    샤워링 뮤온 간격이 τ(0.257 s)와 비슷해지면 그 분포 자체가 지수꼴이라
      //    적합의 상수항이 그것을 담지 못하고 [0]/[1] 이 통째로 흡수한다.
      //    조용히 두면 그 수를 Li/He 로 읽게 되므로 미리 말해 준다.
      //    (실측 run 4305 : 간격 0.75 s -> n_lihe 가 후보의 절반을 넘었다.)
      if (liveS > 0 && !showers.empty()) {
         double gap = liveS / (double)showers.size();
         if (gap < 5 * 0.257)
            printf("  [WARN] run %d : 샤워링 뮤온 평균 간격 %.2f s 가 Li/He τ(0.257 s)에\n"
                   "         가깝다. 상관 없는 후보의 dt 분포도 지수꼴이라 적합이 그것을\n"
                   "         Li/He 로 흡수한다 -- n_lihe 는 **상한**으로 읽을 것\n", run, gap);
      }

      for (Channel ch : chans) {
         SetChannel(ch);
         std::string tag = ChannelTag(ch).Data();
         std::string key = RowKey(run, tag);
         if (!force && rows.count(key)) { nSkip++; continue; }

         PairWindows w2 = CurrentPairWindows();
         //  s2_lo/s2_hi 열은 MeV 다 (w2.s2lo/s2hi 는 NPE). 오버라이드가
         //  없으면 SetChannel() 이 채운 전역 그대로 -- BuildPairSummary.C 와
         //  같은 값이라야 두 표를 나란히 읽을 수 있다.
         double s2LoMev = S2_E_MIN_MEV, s2HiMev = S2_E_MAX_MEV;
         ApplyOverrides(w2, s2LoMev, s2HiMev, ibdOvr);
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
         r.nMuShower = (long long)showers.size();
         //  ---- 컷 열에는 '적용된 실효값' 을 적는다 (오버라이드 여부를 표
         //  자체가 증언하게) ----
         r.dtMin = w2.dtMin; r.dtMax = w2.dtMax; r.dtAcci = w2.dtAcci;
         r.s2Lo = s2LoMev; r.s2Hi = s2HiMev;
         r.isoPre = w2.isoPre; r.isoPost = w2.isoPost;
         r.muShowerNpe = muShowerNpe;
         r.fnELo = fnELoMev; r.fnEHi = fnEHiMev; r.fnTagS = fnTagS;
         r.liheFitLo = liheFitLoS; r.liheFitHi = liheFitHiS;
         auto ir = rtype.find(run);
         if (ir != rtype.end()) r.src = ir->second;

         //  ---- Li/He (★예비) ----
         //  후보 prompt 의 '직전 샤워링 뮤온까지의 dt' 분포를 τ 고정 2성분 +
         //  상수로 적합한다. 히스토그램은 런·태그마다 새로 만들고 gDirectory
         //  에 넣지 않는다 -- 같은 이름이 쌓이면 ROOT 가 조용히 갈아치운다.
         TH1D h("hdt", "", 200, 0, liheFitHiS);
         h.SetDirectory(nullptr);
         long long nTag = 0;
         LiHeWalk(promptT, showers, fnTagS, &h, &nTag);
         r.nFnMutag = nTag;
         //  ★ 게이트도 화면에 찍는 표본 수도 **창 안(1..nbins)** 만 센다.
         //    GetEntries() 는 overflow(dt > lihe_fit_hi_s)까지 세는데, 그것은
         //    적합에 한 번도 쓰이지 않는 사건이다. 그것으로 lowstat 을 면하면
         //    '적합에 쓸 것이 100개 있다' 는 판정이 거짓이 된다.
         double nInRange = h.Integral(1, h.GetNbinsX());
         if (nInRange < liheMinCand) {
            r.liheStat = "lowstat";
         } else {
            double nL = -1, eL = -1;
            TString fname = TString::Format("flihe_%06d%s", run, tag.c_str());
            if (FitLiHe(&h, fname, liheFitLoS, liheFitHiS, nL, eL)) {
               r.nLihe = nL; r.eLihe = eL; r.liheStat = "ok";
            } else {
               r.liheStat = "nofit";
            }
         }

         //  ---- fast-n (★예비) ----
         //  (a) 사이드밴드 : S1 창만 고에너지로 바꾼 페어링. **전역은 건드리지
         //      않는다** -- 창을 구조체로 받는 PairAndCountW 를 쓰는 이유다.
         //  ★ 이 값이 예비인 이유 : 싱글을 만들 때 이미 포화(saturation) 사건을
         //    버렸다(RenePrdSingles.h 의 Step2 순서). 그래서 고에너지
         //    사이드밴드에는 '포화 미만' 인 것만 남아 있고, 진짜 fast-n prompt
         //    의 상당 부분이 여기 오지 못한다. 외삽 배수(sigW/sideW)도 스펙트럼이
         //    평평하다는 가정이라, 분석팀 검증 전까지는 크기 정도로만 읽을 것.
         //  ★ MeV -> NPE 는 창 상수를 만든 그 함수(MeVToNpe)로 한다. 선형
         //    _NPE_MEV 로 바꾸면 12 MeV 가 6106 NPE 가 되어 S1 신호창
         //    상한(MeVToNpe(12) = 7265 NPE) **안으로 들어온다** -- 사이드밴드가
         //    아니라 신호창의 일부가 된다 (컨트롤러 판정 R5).
         //    ★ 경계는 양쪽 다 닫혀 있다. fn_e_lo_mev = 12 면 사이드밴드가
         //    S1_MAX_NPE 에서 **정확히 시작**하므로 그 값에 딱 걸린 사건 하나는
         //    신호창과 사이드밴드 양쪽에 든다. 겹침이 싫으면 문턱을 조금 올린다.
         PairWindows wf = w2;
         wf.s1lo = MeVToNpe(fnELoMev);
         wf.s1hi = MeVToNpe(fnEHiMev);
         PairCounts fc = PairAndCountW(sing, wf);
         r.nFnSide = fc.nCoincMult;
         //  ★ 외삽 배수는 **MeV 폭의 비**다 (레시피가 그렇게 정의돼 있다).
         //    NPE 폭으로 재면 답이 달라진다 -- MeVToNpe 가 비선형이라 같은
         //    MeV 폭이라도 고에너지 쪽 NPE 폭이 더 넓기 때문이다
         //    (실측 : NPE 비 0.2877 대 MeV 비 0.2842).
         //    신호 쪽은 **실효 창**을 MeVToNpe 의 역함수로 되돌려 잰다. 그러면
         //    오버라이드가 없을 때는 헤더의 S1 MeV 상수와 같은 값이 되고
         //    (10.8 = 12.0 - 1.2), s1_*_npe 오버라이드가 있을 때도 실제로 쓴
         //    창을 잰다.
         double sigW  = NpeToMeV(w2.s1hi) - NpeToMeV(w2.s1lo);   // [MeV]
         double sideW = fnEHiMev - fnELoMev;                     // [MeV]
         r.nFnSideScaled = (sideW > 0 && sigW > 0)
                              ? fc.nCoincMult * (sigW / sideW) : -1;
         //  사이드밴드가 신호 창과 겹치면 '사이드밴드' 가 아니다. 조용히
         //  두면 그 수를 fast-n 으로 읽게 되므로 한 번 말해 준다.
         if (wf.s1lo < w2.s1hi)
            printf("  [WARN] run %d%-5s : fast-n 사이드밴드 하한(%.0f NPE)이 S1 신호창 "
                   "상한(%.0f NPE)보다 낮다. n_fn_side 에 IBD prompt 가 섞인다\n",
                   run, tag.c_str(), wf.s1lo, w2.s1hi);

         bool replaced = rows.count(key) > 0;
         rows[key] = r;
         nNew++;
         printf("  [%s] run %d%-5s : paired=%lld  ibd=%lld  acci=%lld  "
                "single=%lld  live=%.1fs  r_ll=%.2fHz\n",
                replaced ? "REDO" : " NEW", run, tag.c_str(),
                r.nPaired, r.nIbd, r.nIbdAcci, r.nSingle, r.liveS, r.rll);
         printf("         ★예비 : lihe=%.1f±%.1f (%s, dt 표본 %.0f)  "
                "fn_side=%lld (환산 %.1f)  fn_mutag=%lld\n",
                r.nLihe, r.eLihe, r.liheStat.c_str(), nInRange,
                r.nFnSide, r.nFnSideScaled, r.nFnMutag);
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
//  muShowerNpe..fnTagS : Li/He·fast-n 의 ★예비 컷. metrics.sh 가
//     config/monitorcuts.params 에서 읽어 넘긴다.
//  ibdOverrides : "k=v,k=v" (기본 빈 문자열 = AnalysisCondition.h 그대로).
//     허용 키 10종은 ApplyOverrides 참조.
void BuildMetrics(const char *runList, const char *outDir, double muShowerNpe,
                  double liheFitLoS, double liheFitHiS, int liheMinCand,
                  double fnELoMev, double fnEHiMev, double fnTagS,
                  bool force = false, const char *ibdOverrides = "") {
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
   TString ovr = ibdOverrides ? ibdOverrides : "";
   ovr = ovr.Strip(TString::kBoth);
   Impl(runs, out, muShowerNpe, liheFitLoS, liheFitHiS, liheMinCand,
        fnELoMev, fnEHiMev, fnTagS, force, ovr);
}
