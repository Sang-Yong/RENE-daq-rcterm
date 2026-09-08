// ---------------------------------------------------------------------------
//  BuildMetrics.C - DST 에서 런 지표를 계산한다. PRD 는 읽지 않는다.
//  IBD/acci 는 legacy(BuildPairSummary)와 같은 값이어야 하며 metrics.sh
//  --verify 가 그것을 대조한다. 배경 3종(Li/He · fast-n · 상관 다중중성자)과
//  accidental 교차검증·PSD 통계는 ★예비 레시피 v2 다 (2026-09-08).
//
//  레시피의 근거 : docs/superpowers/specs/2026-09-08-background-recipes-v2-design.md
//     accidental  off-window(기존) + R_S1·R_S2·T·live 곱 (RENE PTEP 2025 §2, Daya Bay Eq.1)
//     fast-n      prompt 창을 [fn_e_lo, fn_e_hi] MeV 로 올린 페어링을 0차·1차 외삽
//                 (Daya Bay 1402.6876 §4.3). ★ T_Sat(포화 사건)을 합쳐 센다 --
//                 12 MeV 이상은 실측 93 % 가 포화라 single 만으로는 표본이 없다
//     Li/He       직전 샤워링 뮤온까지의 시간 분포를 Daya Bay Eq.2 로 적합 :
//                    f(t) = N_LiHe [R λ_Li e^{-λ_Li t} + (1-R) λ_He e^{-λ_He t}]
//                         + N_unc R_μ e^{-R_μ t}
//                 R_μ(샤워링 뮤온 rate)는 데이터에서 고정. v1 은 우발항을 상수로
//                 두어 후보의 56 % 를 Li/He 로 흡수했다(§11.156). 같은 적합을
//                 **다음** 샤워링 뮤온까지의 시간(시간 역방향)에도 걸어 대조한다 --
//                 물리 상관이 없으니 0 과 맞아야 한다
//     mult_rej    multiplicity 가 걸러낸 on-time 쌍에서 우발 몫을 뺀 것 = 뮤온 유발
//                 다중 중성자(NEOS 'correlated background') 지표
//     PSD         1-3 MeV single 의 꼬리비율 γ-band 평균·RMS 와, IBD 후보 prompt 중
//                 mean + psd_nsig·rms 를 넘는 수 (NEOS §4.3.2.2 의 p_psd 를 런 단위로).
//                 실측 분리력이 약해(FoM 0.5) 사건별 컷이 아니라 **추이**로 본다
//
//  무엇을 읽나
//     <OutDir>/dst/DST_<NNNNNN>.root   (BuildMonitorDst.C 산출물, schema 1 또는 2)
//                                      T_Singles(evt_id/sub_id/t_us/pe[/psd])
//                                      T_Sat(sub_id/t_us/pe)        schema 2 만
//                                      T_Muons(sub_id/t_us/pe/sat)
//                                      T_Info(run/thr_npe/veto_us/n_subrun/
//                                             n_bad/live_s/built/schema)
//                                      schema 1 DST 면 psd 열은 -1, T_Sat 은
//                                      비어 있는 것으로 읽는다 (fast-n 은 그만큼
//                                      과소, fn_sat_frac=-1 로 표에 남는다)
//     <OutDir>/runtype.tsv             선원 정보. ibd-summary.sh 가 만든다
//                                      (없어도 죽지 않는다 -- src="?" 로 남는다)
//
//  무엇을 쓰나
//     <OutDir>/metrics_summary.tsv     schema 2. 열 순서는 WriteTsv 참조.
//                                      앞 18 열은 schema 1 과 같은 자리다 --
//                                      웹·시트 소비자가 14/16/18 열을 읽는다.
//
//  ---- 페어링은 legacy 와 같은 것을 쓴다 ----
//  RenePairing.h::PairAndCountW 는 BuildPairSummary.C 의 PairAndCount 가
//  내부적으로 위임하는 바로 그 구현이다. 다른 것은 입력뿐이다 -- legacy 는
//  PRD 를 그때그때 읽어 clean single 을 다시 만들고, 여기는 DST 의 T_Singles 를
//  그대로 읽는다. 두 경로가 같은 값을 내는지는 metrics.sh --verify 가
//  pair_summary.tsv 와 대조해서 확인한다(전환 게이트).
//
//  ---- IBD 컷 오버라이드 ----
//  마지막 인자 ibdOverrides ("dt_max_us=120,s2_lo_mev=5.5" 꼴) 가 있으면
//  AnalysisCondition.h 대신 그 값으로 페어링한다. 빈 문자열이 기본이고, 그때만
//  legacy 와 컷이 같아 metrics.sh --verify 로 대조할 수 있다.
//  TSV 의 컷 열에는 언제나 **적용된 실효값**이 들어간다.
// ---------------------------------------------------------------------------
#include "RenePrdSingles.h"     // S1S2_Candidate, SetChannel, ChannelTag, ReneMuon, ReneSat
#include "RenePairing.h"
#include <algorithm>            // std::sort, std::lower_bound
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>
#include <TF1.h>
#include <TH1D.h>
#include <TStopwatch.h>

//  tsv 스키마가 바뀌면 올린다. 옛 파일을 조용히 잘못 읽는 것보다
//  못 읽는다고 말하는 편이 낫다 (BuildPairSummary.C 와 같은 규칙).
static const int kMetricsSchema = 2;

static const double kTauLiS = 0.257;    // ⁹Li  평균수명 [s]  (Daya Bay 1402.6876)
static const double kTauHeS = 0.172;    // ⁸He  평균수명 [s]

struct MetRow {                 // 열 순서는 WriteTsv 와 같아야 한다
   int run = 0; std::string tag, src = "?", liheStat = "off";
   double liveS = -1, rll = -1;
   long long nPaired=-1,nPairedAcci=-1,nIbd=-1,nIbdAcci=-1,nSingle=-1;
   int nSubrun=-1; long long nMu=-1,nMuShower=-1;
   double nLihe=-1,eLihe=-1; long long nFnSide=-1; double nFnSideScaled=-1;
   //  ---- schema 2 부터 ----
   double nFnSideLin=-1, fnSatFrac=-1;
   double nLiheRev=-1, eLiheRev=-1, rMuShower=-1;
   double nAcciRp=-1, nMultRej=-1;
   double psdMean=-1, psdRms=-1; long long nIbdPsdNlike=-1;
   //  ---- 컷 열 ----
   double dtMin=-1,dtMax=-1,dtAcci=-1,s2Lo=-1,s2Hi=-1,isoPre=-1,isoPost=-1;
   double muShowerNpe=-1,fnELo=-1,fnEHi=-1,liheFitLo=-1,liheFitHi=-1;
   double liheLiFrac=-1, psdNsig=-1;
};

//  DST 를 읽는다. psd 는 sing 과 같은 길이(schema 1 이면 전부 -1),
//  sats 는 schema 1 이면 비어 있다. 둘 다 '없음' 을 값으로 남겨 두어
//  뒤에서 -1 / 비어 있음 으로 구분해 쓴다.
static bool LoadDst(const TString &dst, std::vector<S1S2_Candidate> &sing,
                    std::vector<Float_t> &psd, std::vector<ReneSat> &sats,
                    std::vector<ReneMuon> &mu, double &liveS, int &nSubrun,
                    int &schema) {
   TFile *f = TFile::Open(dst, "READ");
   if (!f || f->IsZombie()) { if (f) f->Close(); return false; }
   TTree *tS = (TTree *)f->Get("T_Singles");
   TTree *tM = (TTree *)f->Get("T_Muons");
   TTree *tI = (TTree *)f->Get("T_Info");
   TTree *tX = (TTree *)f->Get("T_Sat");
   if (!tS || !tM || !tI || tI->GetEntries() < 1) { f->Close(); return false; }
   const bool hasPsd = tS->GetBranch("psd") != nullptr;
   Int_t s_evt, s_sub; Double_t s_t; Float_t s_pe, s_psd = -1;
   tS->SetBranchAddress("evt_id", &s_evt); tS->SetBranchAddress("sub_id", &s_sub);
   tS->SetBranchAddress("t_us", &s_t);     tS->SetBranchAddress("pe", &s_pe);
   if (hasPsd) tS->SetBranchAddress("psd", &s_psd);
   for (Long64_t i = 0; i < tS->GetEntries(); ++i) {
      tS->GetEntry(i);
      sing.push_back({s_evt, s_sub, s_t, (double)s_pe});
      psd.push_back(hasPsd ? s_psd : (Float_t)-1);
   }
   if (tX) {
      Int_t x_sub; Double_t x_t; Float_t x_pe;
      tX->SetBranchAddress("sub_id", &x_sub); tX->SetBranchAddress("t_us", &x_t);
      tX->SetBranchAddress("pe", &x_pe);
      for (Long64_t i = 0; i < tX->GetEntries(); ++i) {
         tX->GetEntry(i); sats.push_back({x_sub, x_t, x_pe});
      }
   }
   Int_t m_sub; Double_t m_t; Float_t m_pe; Char_t m_sat;
   tM->SetBranchAddress("sub_id", &m_sub); tM->SetBranchAddress("t_us", &m_t);
   tM->SetBranchAddress("pe", &m_pe);      tM->SetBranchAddress("sat", &m_sat);
   for (Long64_t i = 0; i < tM->GetEntries(); ++i) {
      tM->GetEntry(i); mu.push_back({m_sub, m_t, m_pe, m_sat});
   }
   Int_t i_nsub, i_schema = 1; Double_t i_live;
   tI->SetBranchAddress("n_subrun", &i_nsub); tI->SetBranchAddress("live_s", &i_live);
   if (tI->GetBranch("schema")) tI->SetBranchAddress("schema", &i_schema);
   tI->GetEntry(0); nSubrun = i_nsub; liveS = i_live; schema = i_schema;
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
//  ---- Li/He ----
//  '샤워링 뮤온' = target 파형이 있고(pe > 0) NPE 가 문턱을 넘은 뮤온.
//  순수 veto 뮤온은 pe = -1 이라 문턱이 아무리 낮아도 세어지지 않는다.
//  ★ 문턱의 뜻은 '에너지가 큰 뮤온' 이 아니라 **rate 를 낮추는 손잡이**다.
//    적분창이 1 µs 라 NPE 가 5만을 넘지 못하고(실측), 문턱 20000 이면 target
//    뮤온 3.05 Hz 중 0.63 Hz 가 남는다. 1/R_μ = 1.6 s 가 τ(⁹Li)=0.257 s 와
//    6 배 떨어져야 적합의 두 지수가 갈린다.
static std::vector<double> ShowerTimes(const std::vector<ReneMuon> &mu,
                                       double muShowerNpe) {
   std::vector<double> s;
   for (const auto &m : mu)
      if (m.pe > muShowerNpe) s.push_back(m.t_us);
   std::sort(s.begin(), s.end());
   return s;
}

//  후보 prompt 마다 직전(reverse=false) 또는 직후(reverse=true) 샤워링 뮤온까지의
//  |dt| [s] 를 h 에 담는다. 앞(뒤)에 샤워링 뮤온이 없는 후보는 뺀다 -- 런 시작
//  (끝)을 뮤온으로 치면 첫 빈이 부풀어 적합이 그리로 끌려간다.
static void LiHeWalk(const std::vector<double> &promptT,
                     const std::vector<double> &showers, bool reverse, TH1D *h) {
   std::vector<double> pt = promptT;
   std::sort(pt.begin(), pt.end());
   if (!reverse) {
      size_t j = 0; bool have = false; double last = 0;
      for (double t : pt) {
         while (j < showers.size() && showers[j] < t) { last = showers[j]; ++j; have = true; }
         if (!have) continue;
         h->Fill((t - last) * 1e-6);
      }
   } else {
      //  다음 샤워링 뮤온 : lower_bound(첫 shower > t)
      for (double t : pt) {
         auto it = std::upper_bound(showers.begin(), showers.end(), t);
         if (it == showers.end()) continue;
         h->Fill((*it - t) * 1e-6);
      }
   }
}

//  Daya Bay Eq.2. 자유 파라미터는 N_LiHe([0]) 와 N_unc([1]) 둘뿐이다.
//  [2]=R_μ, [3]=빈 폭, [4]=Li 분율 R, [5]=λ_Li, [6]=λ_He 는 고정.
//  빈 폭을 곱해 두는 것은 '밀도 × 빈 폭 = 그 빈의 기대 계수' 여야 [0]/[1] 이
//  곧 개수로 읽히기 때문이다. 우도 적합("L") -- 꼬리 빈이 0 인 경우가 많아
//  χ² 로 하면 편향된다.
static bool FitLiHe(TH1D *h, const TString &fname, double lo, double hi,
                    double rMu, double liFrac, double &n, double &e) {
   TF1 f(fname,
         "[3]*([0]*([4]*[5]*exp(-[5]*x)+(1-[4])*[6]*exp(-[6]*x)) + [1]*[2]*exp(-[2]*x))",
         lo, hi);
   double tot = h->Integral(1, h->GetNbinsX());
   f.SetParameters(0.1 * tot, tot, rMu, h->GetBinWidth(1), liFrac, 1.0 / kTauLiS, 1.0 / kTauHeS);
   f.FixParameter(2, rMu);
   f.FixParameter(3, h->GetBinWidth(1));
   f.FixParameter(4, liFrac);
   f.FixParameter(5, 1.0 / kTauLiS);
   f.FixParameter(6, 1.0 / kTauHeS);
   f.SetParLimits(0, 0, 1e9); f.SetParLimits(1, 0, 1e9);
   int rc = h->Fit(&f, "QRLN0");
   if (rc != 0) return false;
   n = f.GetParameter(0);
   e = f.GetParError(0);
   return true;
}

// ---------------------------------------------------------------------------
//  "k=v,k=v" 를 PairWindows 에 얹는다. 빈 문자열이면 아무것도 하지 않는다
//  (= AnalysisCondition.h 값 그대로. 그때만 legacy 대조가 성립한다).
//  *_mev 는 분석 헤더 자신의 MeVToNpe() 로 NPE 가 된다 (컨트롤러 판정 R5 --
//  선형 상수를 쓰면 창 정의와 변환이 어긋난다).
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

//  tsv 전용. 항상 고정 소수 자릿수로 낸다. '-' 같은 표시용 텍스트를 쓰면
//  되읽기의 >> 가 실패해 그 행이 통째로 사라진다.
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
               >> r.nFnSide >> r.nFnSideScaled
               >> r.nFnSideLin >> r.fnSatFrac
               >> r.nLiheRev >> r.eLiheRev >> r.rMuShower
               >> r.nAcciRp >> r.nMultRej
               >> r.psdMean >> r.psdRms >> r.nIbdPsdNlike
               >> r.dtMin >> r.dtMax >> r.dtAcci
               >> r.s2Lo >> r.s2Hi >> r.isoPre >> r.isoPost
               >> r.muShowerNpe >> r.fnELo >> r.fnEHi
               >> r.liheFitLo >> r.liheFitHi >> r.liheLiFrac >> r.psdNsig))
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
        "\tn_fn_side\tn_fn_side_scaled"
        "\tn_fn_side_lin\tfn_sat_frac\tn_lihe_rev\te_lihe_rev\tr_mu_shower"
        "\tn_acci_rp\tn_mult_rej\tpsd_mean\tpsd_rms\tn_ibd_psd_nlike"
        "\tdt_min\tdt_max\tdt_acci\ts2_lo\ts2_hi\tiso_pre\tiso_post"
        "\tmu_shower_npe\tfn_e_lo\tfn_e_hi\tlihe_fit_lo\tlihe_fit_hi\tlihe_li_frac\tpsd_nsig\n";
   for (const auto &kv : rows) {
      const MetRow &r = kv.second;
      o << r.run << '\t' << r.tag << '\t' << r.src << '\t' << FmtRaw(r.liveS, 3) << '\t'
        << r.nPaired << '\t' << r.nPairedAcci << '\t' << r.nIbd << '\t' << r.nIbdAcci << '\t'
        << r.nSingle << '\t' << FmtRaw(r.rll, 4) << '\t' << r.nSubrun << '\t'
        << r.nMu << '\t' << r.nMuShower << '\t'
        << FmtRaw(r.nLihe, 3) << '\t' << FmtRaw(r.eLihe, 3) << '\t' << r.liheStat << '\t'
        << r.nFnSide << '\t' << FmtRaw(r.nFnSideScaled, 3) << '\t'
        << FmtRaw(r.nFnSideLin, 3) << '\t' << FmtRaw(r.fnSatFrac, 4) << '\t'
        << FmtRaw(r.nLiheRev, 3) << '\t' << FmtRaw(r.eLiheRev, 3) << '\t' << FmtRaw(r.rMuShower, 5) << '\t'
        << FmtRaw(r.nAcciRp, 3) << '\t' << FmtRaw(r.nMultRej, 3) << '\t'
        << FmtRaw(r.psdMean, 5) << '\t' << FmtRaw(r.psdRms, 5) << '\t' << r.nIbdPsdNlike << '\t'
        << r.dtMin << '\t' << r.dtMax << '\t' << r.dtAcci << '\t'
        << r.s2Lo << '\t' << r.s2Hi << '\t' << r.isoPre << '\t' << r.isoPost << '\t'
        << r.muShowerNpe << '\t' << r.fnELo << '\t' << r.fnEHi << '\t'
        << r.liheFitLo << '\t' << r.liheFitHi << '\t' << r.liheLiFrac << '\t' << r.psdNsig << '\n';
   }
}

// ---------------------------------------------------------------------------
//  fast-n 사이드밴드의 1차(선형) 외삽. prompt 에너지[MeV]를 [lo,hi] 에서 pol1 로
//  적합해 신호창 [sLo,sHi] 로 적분한다. 표본이 적거나(5 미만) 적합이 안 되면
//  false -- 그때는 0차(평평) 값만 쓴다.
static bool LinearExtrap(const std::vector<double> &promptMev, double lo, double hi,
                         double sLo, double sHi, double &n) {
   if (promptMev.size() < 5 || hi <= lo) return false;
   int nb = std::max(4, std::min(20, (int)promptMev.size() / 5));
   TH1D h("hfn", "", nb, lo, hi);
   h.SetDirectory(nullptr);
   for (double e : promptMev) h.Fill(e);
   //  χ² 적합. 우도("L")는 pol1 이 음수를 예측하는 빈에서 실패해 rc≠0 이 되기
   //  쉽다(run 4305 n-H 사이드밴드 1,602 개에서 실측). 표본 5 개 이상만 받는다.
   TF1 f("ffn", "pol1", lo, hi);
   int rc = h.Fit(&f, "QRN0");
   if (rc != 0) return false;
   //  밀도(빈당 계수/빈 폭)로 적분해야 개수가 된다
   n = f.Integral(sLo, sHi) / h.GetBinWidth(1);
   if (!(n >= 0)) n = 0;   // 음수 외삽은 0 으로 -- 배경이 음수일 수는 없다
   return true;
}

// ---------------------------------------------------------------------------
static void Impl(const std::vector<int> &runs, const TString &out,
                 double muShowerNpe, double liheFitLoS, double liheFitHiS,
                 int liheMinCand, double fnELoMev, double fnEHiMev,
                 double liheLiFrac, double psdNsig, bool force, const TString &ibdOvr) {
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

   //  ★ 예비 레시피의 손잡이. 값이 어디서 왔는지 로그에 남긴다.
   printf("[INFO] 배경 컷 (★예비 v2) : muShowerNpe=%.1f liheFit=[%.3f,%.1f]s "
          "liheMinCand=%d liFrac=%.2f fnE=[%.2f,%.2f]MeV psdNsig=%.1f\n",
          muShowerNpe, liheFitLoS, liheFitHiS, liheMinCand, liheLiFrac,
          fnELoMev, fnEHiMev, psdNsig);
   if (!ibdOvr.IsNull())
      printf("[INFO] ★ IBD 컷 오버라이드 : %s  (legacy 와 컷이 다르다. "
             "--verify 는 거부된다)\n", ibdOvr.Data());

   const Channel chans[2] = {CH_NGD, CH_NH};
   int nNew = 0, nSkip = 0, nMiss = 0;
   for (int run : runs) {
      bool haveAll = true;
      for (Channel ch : chans) {
         SetChannel(ch);
         if (!rows.count(RowKey(run, ChannelTag(ch).Data()))) haveAll = false;
      }
      if (!force && haveAll) { nSkip += 2; continue; }

      TString dst = out + TString::Format("dst/DST_%s.root", ReneRunStr(run).Data());
      std::vector<S1S2_Candidate> sing; std::vector<Float_t> psd;
      std::vector<ReneSat> sats; std::vector<ReneMuon> mu;
      double liveS = 0; int nSubrun = 0, dstSchema = 1;
      TStopwatch w; w.Start();
      if (!LoadDst(dst, sing, psd, sats, mu, liveS, nSubrun, dstSchema)) {
         printf("  [SKIP] run %d : DST 없음 (dst-build.sh 먼저)\n", run);
         nMiss++;
         continue;
      }
      w.Stop();
      printf("  run %d : DST(schema %d) 로드 singles=%zu sat=%zu muons=%zu live=%.1fs subrun=%d  [%.1f s]\n",
             run, dstSchema, sing.size(), sats.size(), mu.size(), liveS, nSubrun, w.RealTime());
      if (dstSchema < 2)
         printf("  [WARN] run %d : schema 1 DST 라 psd·T_Sat 이 없다. PSD 열은 -1, "
                "fast-n 은 포화 사건 없이 센다 (dst-build.sh 로 다시 만들 것)\n", run);

      //  ---- 샤워링 뮤온 : 태그와 무관. 런에서 한 번만 ----
      std::vector<double> showers = ShowerTimes(mu, muShowerNpe);
      double rMu = (liveS > 0) ? showers.size() / liveS : -1;
      printf("  run %d : 샤워링 뮤온 %zu 개 (pe > %.0f NPE, R_μ = %.3f Hz, 1/R = %.2f s, τ_Li = %.3f s)\n",
             run, showers.size(), muShowerNpe, rMu, rMu > 0 ? 1 / rMu : -1, kTauLiS);
      //  두 지수(R_μ 와 λ_Li)가 가까우면 적합이 둘을 못 가른다. 2 배 안이면 'degen'.
      const bool degenerate = (rMu > 0) && (std::fabs(std::log(rMu * kTauLiS)) < std::log(2.0));
      if (degenerate)
         printf("  [WARN] run %d : R_μ %.3f Hz 가 1/τ_Li %.3f Hz 의 2 배 안이다 -- Li/He 적합이\n"
                "         우발항과 축퇴한다. lihe_stat=degen 으로 낸다. mu_shower_npe 를 올릴 것\n",
                run, rMu, 1 / kTauLiS);

      //  ---- PSD γ-band : 1-3 MeV single 의 꼬리비율 평균·RMS (태그 무관) ----
      double psdMean = -1, psdRms = -1;
      {
         double s = 0, s2 = 0; long long n = 0;
         for (size_t k = 0; k < sing.size(); ++k) {
            if (psd[k] < 0) continue;
            double mev = NpeToMeV(sing[k]._pe_sum);
            if (mev < 1.0 || mev > 3.0) continue;
            s += psd[k]; s2 += (double)psd[k] * psd[k]; n++;
         }
         if (n >= 100) {
            psdMean = s / n;
            double var = s2 / n - psdMean * psdMean;
            psdRms = var > 0 ? std::sqrt(var) : 0;
         }
      }

      //  ---- fast-n 용 합집합 : single + 포화 사건. 시간 순 ----
      //  multiplicity 판정이 '모든 원소가 LOWER 위' 를 전제하므로(RenePairing.h)
      //  LOWER 아래의 포화 사건(있을 리 없지만)은 넣지 않는다.
      std::vector<S1S2_Candidate> all = sing;
      {
         double lower = LOWER_LIMIT;
         for (const auto &x : sats)
            if (x.pe > lower) all.push_back({-1, x.sub, x.t_us, (double)x.pe});
         std::sort(all.begin(), all.end());
      }

      for (Channel ch : chans) {
         SetChannel(ch);
         std::string tag = ChannelTag(ch).Data();
         std::string key = RowKey(run, tag);
         if (!force && rows.count(key)) { nSkip++; continue; }

         PairWindows w2 = CurrentPairWindows();
         double s2LoMev = S2_E_MIN_MEV, s2HiMev = S2_E_MAX_MEV;
         ApplyOverrides(w2, s2LoMev, s2HiMev, ibdOvr);
         std::vector<double> promptT;
         PairCounts pc = PairAndCountW(sing, w2, &promptT);
         const double acciScale = (w2.dtMax > 0) ? (w2.dtMax - w2.dtMin) / w2.dtMax : 1.0;

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
         r.rMuShower = rMu;
         r.dtMin = w2.dtMin; r.dtMax = w2.dtMax; r.dtAcci = w2.dtAcci;
         r.s2Lo = s2LoMev; r.s2Hi = s2HiMev;
         r.isoPre = w2.isoPre; r.isoPost = w2.isoPost;
         r.muShowerNpe = muShowerNpe;
         r.fnELo = fnELoMev; r.fnEHi = fnEHiMev;
         r.liheFitLo = liheFitLoS; r.liheFitHi = liheFitHiS;
         r.liheLiFrac = liheLiFrac; r.psdNsig = psdNsig;
         r.psdMean = psdMean; r.psdRms = psdRms;
         auto ir = rtype.find(run);
         if (ir != rtype.end()) r.src = ir->second;

         //  ---- accidental 교차검증 : R_S1 · R_S2 · T · live (Daya Bay Eq.1) ----
         //  창 안 single 의 rate 곱. off-window 값(n_paired_acci × acciScale)과
         //  같은 양(multiplicity 전)을 세므로 나란히 놓을 수 있다.
         {
            long long nS1 = 0, nS2 = 0;
            for (const auto &e : sing) {
               if (e._pe_sum >= w2.s1lo && e._pe_sum <= w2.s1hi) nS1++;
               if (e._pe_sum >= w2.s2lo && e._pe_sum <= w2.s2hi) nS2++;
            }
            r.nAcciRp = (liveS > 0) ? (double)nS1 * (double)nS2 * (w2.dtMax - w2.dtMin) * 1e-6 / liveS : -1;
         }

         //  ---- 상관 다중중성자 지표 : multiplicity 가 걸러낸 쌍의 우발 초과분 ----
         r.nMultRej = (double)(pc.nCoinc - pc.nCoincMult)
                    - acciScale * (double)(pc.nAcci - pc.nAcciMult);

         //  ---- Li/He (★예비 v2) : 직전 샤워링 뮤온 + 시간 역방향 대조 ----
         {
            TH1D h("hdt", "", 200, 0, liheFitHiS);   h.SetDirectory(nullptr);
            TH1D hr("hdtr", "", 200, 0, liheFitHiS); hr.SetDirectory(nullptr);
            LiHeWalk(promptT, showers, false, &h);
            LiHeWalk(promptT, showers, true,  &hr);
            double nInRange = h.Integral(1, h.GetNbinsX());
            if (showers.empty() || rMu <= 0) {
               r.liheStat = "noshower";
            } else if (nInRange < liheMinCand) {
               r.liheStat = "lowstat";
            } else {
               double nL = -1, eL = -1, nR = -1, eR = -1;
               TString fn = TString::Format("flihe_%06d%s", run, tag.c_str());
               bool okF = FitLiHe(&h,  fn,        liheFitLoS, liheFitHiS, rMu, liheLiFrac, nL, eL);
               bool okR = FitLiHe(&hr, fn + "_r", liheFitLoS, liheFitHiS, rMu, liheLiFrac, nR, eR);
               if (okF) { r.nLihe = nL; r.eLihe = eL; r.liheStat = degenerate ? "degen" : "ok"; }
               else       r.liheStat = "nofit";
               if (okR) { r.nLiheRev = nR; r.eLiheRev = eR; }
            }
            printf("         Li/He dt 표본 %.0f (창 안), 역방향 %.0f\n",
                   nInRange, hr.Integral(1, hr.GetNbinsX()));
         }

         //  ---- fast-n (★예비 v2) : 사이드밴드 = single ∪ 포화, 0차·1차 외삽 ----
         {
            PairWindows wf = w2;
            wf.s1lo = MeVToNpe(fnELoMev);
            wf.s1hi = MeVToNpe(fnEHiMev);
            std::vector<double> sideT, sideE;
            PairCounts fc = PairAndCountW(all, wf, &sideT, &sideE);
            r.nFnSide = fc.nCoincMult;
            double sigLo = NpeToMeV(w2.s1lo), sigHi = NpeToMeV(w2.s1hi);
            double sigW  = sigHi - sigLo;                       // [MeV]
            double sideW = fnEHiMev - fnELoMev;                 // [MeV]
            double nFlat = (sideW > 0 && sigW > 0) ? fc.nCoincMult * (sigW / sideW) : -1;
            std::vector<double> sideMev;
            for (double e : sideE) sideMev.push_back(NpeToMeV(e));
            double nLin = -1;
            bool okLin = LinearExtrap(sideMev, fnELoMev, fnEHiMev, sigLo, sigHi, nLin);
            //  사이드밴드 에너지 구간에 든 사건 중 포화 사건 비율 (schema 1 이면 -1)
            if (dstSchema >= 2) {
               long long nSat = 0, nSg = 0;
               for (const auto &x : sats) if (x.pe >= wf.s1lo && x.pe <= wf.s1hi) nSat++;
               for (const auto &e : sing) if (e._pe_sum >= wf.s1lo && e._pe_sum <= wf.s1hi) nSg++;
               r.fnSatFrac = (nSat + nSg > 0) ? (double)nSat / (double)(nSat + nSg) : 0;
            }
            r.nFnSideLin = okLin ? nLin : nFlat;
            //  ★ 사이드밴드가 대부분 포화 사건이면(실측 run 4305 : 100 %) 에너지 축이
            //    잘린 적분값이라 스펙트럼 모양이 뜻을 잃는다 -- 잘린 값이 위쪽에 쌓여
            //    기울기가 양수가 되고 1차 외삽이 0 으로 떨어진다(실측 n-Gd 7.7 대 0.0).
            //    그때는 0차(평평) 값만 쓴다. 1차 값은 정보로 남긴다.
            const bool energyAxisClipped = (r.fnSatFrac > 0.5);
            r.nFnSideScaled = (nFlat < 0) ? -1
                            : energyAxisClipped ? nFlat : 0.5 * (nFlat + r.nFnSideLin);
            if (wf.s1lo < w2.s1hi)
               printf("  [WARN] run %d%-5s : fast-n 사이드밴드 하한(%.0f NPE)이 S1 신호창 "
                      "상한(%.0f NPE)보다 낮다. n_fn_side 에 IBD prompt 가 섞인다\n",
                      run, tag.c_str(), wf.s1lo, w2.s1hi);
         }

         //  ---- PSD n-like : IBD 후보 prompt 중 γ-band 에서 psd_nsig σ 이상 벗어난 수 ----
         if (psdMean >= 0 && psdRms > 0) {
            long long nl = 0;
            for (double t : promptT) {
               //  prompt 시각 -> single 인덱스 (T_Singles 는 시간 순)
               S1S2_Candidate key{0, 0, t, 0};
               auto it = std::lower_bound(sing.begin(), sing.end(), key);
               if (it == sing.end() || it->_t_us != t) continue;
               size_t k = (size_t)(it - sing.begin());
               if (psd[k] >= 0 && psd[k] > psdMean + psdNsig * psdRms) nl++;
            }
            r.nIbdPsdNlike = nl;
         }

         bool replaced = rows.count(key) > 0;
         rows[key] = r;
         nNew++;
         printf("  [%s] run %d%-5s : paired=%lld  ibd=%lld  acci=%lld (rp %.1f)  mult_rej=%.1f  "
                "single=%lld  live=%.1fs  r_ll=%.2fHz\n",
                replaced ? "REDO" : " NEW", run, tag.c_str(),
                r.nPaired, r.nIbd, r.nIbdAcci, r.nAcciRp, r.nMultRej, r.nSingle, r.liveS, r.rll);
         printf("         ★예비 : lihe=%.1f±%.1f (%s)  rev=%.1f±%.1f  fn_side=%lld "
                "(환산 %.1f, 선형 %.1f, sat_frac %.2f%s)  psd γ %.4f±%.4f  n-like %lld\n",
                r.nLihe, r.eLihe, r.liheStat.c_str(), r.nLiheRev, r.eLiheRev,
                r.nFnSide, r.nFnSideScaled, r.nFnSideLin, r.fnSatFrac,
                r.fnSatFrac > 0.5 ? " -> 평평만" : "",
                r.psdMean, r.psdRms, r.nIbdPsdNlike);
      }
      //  런 하나가 몇 분 걸릴 수 있다. 중간에 끊겨도 한 것은 남도록 그때그때 쓴다.
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
//  muShowerNpe..psdNsig : 배경 레시피 v2 의 ★예비 컷. metrics.sh 가
//     config/monitorcuts.params 에서 읽어 넘긴다.
//  ibdOverrides : "k=v,k=v" (기본 빈 문자열 = AnalysisCondition.h 그대로).
void BuildMetrics(const char *runList, const char *outDir, double muShowerNpe,
                  double liheFitLoS, double liheFitHiS, int liheMinCand,
                  double fnELoMev, double fnEHiMev, double liheLiFrac, double psdNsig,
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
        fnELoMev, fnEHiMev, liheLiFrac, psdNsig, force, ovr);
}
