# 런 서머리 웹 모니터링 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 런당 1줄 요약 표 + 런마다 점이 쌓이는 추이 그림을 만들고, 구글
시트/드라이브를 거쳐 구글사이트에 자동 게시한다. fast-n·Li/He 를 계산할 수
있도록 PRD 위에 2차 프로덕션(DST) 단계를 새로 둔다.

**Architecture:** 기존 tools/monitor 3단계(run-summary → ibd-summary →
rate-trend)에 DST 빌드·메트릭·웹 발행을 더한다. DST 는 뮤온 시각과 클린
싱글을 담은 런당 ROOT 파일 1개로, 컷이 바뀌어도 PRD 재독 없이 재계산하게
한다. 발행은 모듈(publish_google.py)로 분리해 나중에 다른 호스팅으로
갈아끼울 수 있다.

**Tech Stack:** bash + ROOT 6.28 (ACLiC 매크로) + python3(gspread 6.2.1,
google-auth — 기존 설치본만, 새 pip 의존 금지)

**Spec:** docs/superpowers/specs/2026-09-08-run-summary-web-design.md

## Global Constraints

- 작업 클론은 `~/DAQ/work-web`. 운영 디렉터리(`~/DAQ/RENE-daq-rcterm`)는 git pull 만 (CLAUDE.md §8).
- 하드웨어·수집 무접촉. 실데이터(PRD)는 **읽기만**. 쓰는 곳은
  `/scratch/RunSummary/{cache,dst,web}` · `/Data_ssd/LOG` 뿐.
- 새 pip 설치 금지. `*.params` 는 gitignore, `*.params.example` 만 커밋.
- `pair_summary.tsv`/`run_summary.tsv` 의 기존 스키마 불변. rcterm/rcsupervisor 무접촉.
- `metrics_source` 기본값은 `legacy` — Task 4 패리티 게이트 통과 + 사용자 승인 전에 dst 로 바꾸지 않는다.
- fast-n·Li/He 수치에는 반드시 '(예비)' 표기 (스펙 §4).
- 커밋 메시지: 영어 명령형(`feat:`/`fix:`/`docs:`/`test:`) + 기존 Co-Authored-By 푸터.
- bash 함정 준수 (CLAUDE.md §11.142): `local` 분리 선언, `pgrep -x`, PID 로만 kill, awk `FILENAME` 구분.
- 테스트는 `/scratch` 가 없으면 `SKIP` 을 찍고 exit 0 (성공으로 위장하지 않고 SKIP 줄로 표시).
- ROOT 매크로 실행 전 환경: `command -v root >/dev/null || . /usr/local/bin/thisroot.sh`
  (rate-trend.sh 와 같은 방식). 분석 헤더는 이 서버에
  `/home/ojk/analysis3/essential/` 로 존재함을 확인했다.

---

### Task 1: RenePrdSingles.h — 뮤온 수집 확장

DST 의 재료인 뮤온(시각·target NPE)을 기존 Step1/Step2 루프에서 **같은
루프로** 뽑는다. 물리 루프를 복제하면 갈라지므로(§5.8 원칙) 기존
`ReneProcessSubrun` 에 선택 인자를 더한다. 기본값이 nullptr 이라 기존
호출부(BuildPairSummary.C)는 재컴파일만으로 동작이 같다.

**Files:**
- Modify: `tools/monitor/RenePrdSingles.h`
- Test: `tests/monitor-muons.test.sh`

**Interfaces (뒤 Task 들이 쓴다):**
- Produces: `struct ReneMuon { Int_t sub; Double_t t_us; Float_t pe; Char_t sat; };`
  (pe = target 두 채널 NPE 합. FADC 신호가 없는 순수 veto 뮤온은 pe = -1, sat = 0)
- Produces: `ReneProcessSubrun(prdPath, sub, thr, vetoCutUs, carry, sing, std::vector<ReneMuon>* muons = nullptr)`
- Produces: `ReneSaveCache(path, thr, vetoCutUs, sing, first, carry, st, const std::vector<ReneMuon>* muons = nullptr, size_t muFirst = 0)`
  — muons 를 주면 캐시에 `T_Muons` 트리가 추가된다 (없으면 기존 그대로)
- Produces: `bool ReneLoadCacheMuons(const TString& path, std::vector<ReneMuon>& out)`
  — `T_Muons` 가 없으면 false (= 확장 전 캐시)
- Consumes: 기존 `ReneCarry`/`ReneSubrunStat`/`ReneIsMuonVeto`/`ReneChannelNpe` 그대로.

- [ ] **Step 1: 구조체와 시그니처 추가**

`RenePrdSingles.h` 의 `ReneSubrunStat` 정의 바로 아래에:

```cpp
//  DST 용 뮤온 한 건. pe 는 target(ch0+ch1) NPE 합 -- FADC 신호가 없는
//  순수 veto 뮤온은 -1 이다 (target 을 지나지 않은 뮤온은 Li/He 의
//  '샤워링' 판정 대상이 아니다). sat 은 포화 여부.
struct ReneMuon {
   Int_t    sub  = -1;
   Double_t t_us = 0;
   Float_t  pe   = -1;
   Char_t   sat  = 0;
};
```

`ReneProcessSubrun` 선언을 다음으로 바꾼다 (기본 인자라 기존 호출부 불변):

```cpp
inline ReneSubrunStat ReneProcessSubrun(const TString &prdPath, int sub, double thr,
                                        double vetoCutUs, ReneCarry &carry,
                                        std::vector<S1S2_Candidate> &sing,
                                        std::vector<ReneMuon> *muons = nullptr) {
```

루프 안, `if (isVeto) carry.muonTime = globalTime;` 다음의
`if (isVeto) { st.nMuon++;    continue; }` 를 다음으로 바꾼다:

```cpp
      if (isVeto) {
         st.nMuon++;
         if (muons) {
            //  target NPE. Fbit==0 이면 ReneChannelNpe 가 -999 를 주므로
            //  '순수 veto 뮤온' 은 pe=-1 로 남는다. 포화돼도 적분값은
            //  낸다 -- 과소평가일 뿐이고 sat 플래그로 구분한다.
            bool msat = false;
            double m0 = ReneChannelNpe(0, timeWindow, msat);
            double m1 = ReneChannelNpe(1, timeWindow, msat);
            ReneMuon mu;
            mu.sub  = sub;
            mu.t_us = globalTime * DAQ_NS_TO_US;
            if (m0 > -900 || m1 > -900)
               mu.pe = (Float_t)((m0 > -900 ? m0 : 0) + (m1 > -900 ? m1 : 0));
            mu.sat  = msat ? 1 : 0;
            muons->push_back(mu);
         }
         continue;
      }
```

- [ ] **Step 2: 캐시 저장에 T_Muons 추가**

`ReneSaveCache` 시그니처 끝에 `const std::vector<ReneMuon> *muons = nullptr,
size_t muFirst = 0` 를 더하고, `tS->Fill();` 다음 `f->cd();` 앞에:

```cpp
   if (muons) {
      TTree *tM = new TTree("T_Muons", "muon veto events (for DST)");
      Int_t    m_sub = 0; Double_t m_t = 0; Float_t m_pe = -1; Char_t m_sat = 0;
      tM->Branch("sub_id", &m_sub);
      tM->Branch("t_us",   &m_t);
      tM->Branch("pe",     &m_pe);
      tM->Branch("sat",    &m_sat);
      for (size_t i = muFirst; i < muons->size(); ++i) {
         m_sub = (*muons)[i].sub; m_t = (*muons)[i].t_us;
         m_pe  = (*muons)[i].pe;  m_sat = (*muons)[i].sat;
         tM->Fill();
      }
      f->cd(); tM->Write();
   }
```

- [ ] **Step 3: 뮤온 캐시 로더 추가**

`ReneLoadCache` 정의 다음에:

```cpp
//  확장 캐시에서 T_Muons 만 읽는다. 없으면 false -- 확장 전 캐시라는
//  뜻이고, 그 서브런은 파형에서 다시 만들어야 한다.
inline bool ReneLoadCacheMuons(const TString &path,
                               std::vector<ReneMuon> &out) {
   if (gSystem->AccessPathName(path)) return false;
   TFile *f = TFile::Open(path, "READ");
   if (!f || f->IsZombie()) { if (f) f->Close(); return false; }
   TTree *tM = (TTree *)f->Get("T_Muons");
   if (!tM) { f->Close(); return false; }
   Int_t m_sub; Double_t m_t; Float_t m_pe; Char_t m_sat;
   tM->SetBranchAddress("sub_id", &m_sub);
   tM->SetBranchAddress("t_us",   &m_t);
   tM->SetBranchAddress("pe",     &m_pe);
   tM->SetBranchAddress("sat",    &m_sat);
   Long64_t n = tM->GetEntries();
   for (Long64_t i = 0; i < n; ++i) {
      tM->GetEntry(i);
      out.push_back({m_sub, m_t, m_pe, m_sat});
   }
   f->Close();
   return true;
}
```

- [ ] **Step 4: 시험 스크립트 작성 (실패부터 확인)**

`tests/monitor-muons.test.sh` — 실데이터 읽기 전용. run 4237 서브런 100
(비트 단위 검증에 썼던 기준)으로 ① 뮤온 수집이 싱글 결과를 바꾸지 않고
② 뮤온 수 == st.nMuon 이고 ③ 확장 캐시를 기존 로더가 그대로 읽는지 본다.

```bash
#!/usr/bin/env bash
# monitor-muons.test.sh -- RenePrdSingles.h 뮤온 수집이 기존 동작을 바꾸지
# 않는지. 실데이터는 읽기만 하고 캐시는 임시 디렉터리에 쓴다.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh 2>/dev/null
command -v root >/dev/null 2>&1 || { echo "SKIP: ROOT 없음"; exit 0; }
RUNDIR=""
for r in /Data_ssd/RAW /data/RAW /scratch/RAW; do
   [ -f "$r/004237/PRD/PRD_004237.00100.root" ] && RUNDIR=$r && break
done
[ -n "$RUNDIR" ] || { echo "SKIP: run 4237 PRD 없음"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/t.C" <<EOF
#include "$DIR/tools/monitor/RenePrdSingles.h"
void t() {
   TString prd = "$RUNDIR/004237/PRD/PRD_004237.00100.root";
   double thr; { SetChannel(CH_NH); double a=std::min(S1_MIN_NPE,S2_MIN_NPE);
                 SetChannel(CH_NGD); double b=std::min(S1_MIN_NPE,S2_MIN_NPE);
                 thr = std::min(a,b); }
   ReneCarry c1, c2;
   std::vector<S1S2_Candidate> s1, s2;
   std::vector<ReneMuon> mu;
   ReneSubrunStat a = ReneProcessSubrun(prd, 100, thr, 150.0, c1, s1);
   ReneSubrunStat b = ReneProcessSubrun(prd, 100, thr, 150.0, c2, s2, &mu);
   printf("CHK singles_same=%d\n", (int)(s1.size()==s2.size()));
   printf("CHK nmuon_match=%d\n", (int)((long long)mu.size()==b.nMuon));
   printf("CHK muon_sorted=%d\n", (int)std::is_sorted(mu.begin(), mu.end(),
          [](const ReneMuon&x,const ReneMuon&y){return x.t_us<y.t_us;}));
   TString cp = "$T/cache_"; gSystem->mkdir(cp, kTRUE); cp += "/";
   TString path = ReneCachePath(cp, 4237, 100);
   ReneSaveCache(path, thr, 150.0, s2, 0, c2, b, &mu, 0);
   std::vector<S1S2_Candidate> s3; ReneCarry c3; ReneSubrunStat st3;
   printf("CHK legacy_load=%d\n", (int)ReneLoadCache(path, thr, 150.0, s3, c3, st3));
   printf("CHK legacy_n=%d\n", (int)(s3.size()==s2.size()));
   std::vector<ReneMuon> mu2;
   printf("CHK muon_load=%d\n", (int)(ReneLoadCacheMuons(path, mu2) && mu2.size()==mu.size()));
}
EOF
OUT=$(root -l -b -q "$T/t.C+" 2>&1)
echo "$OUT" | grep -q 'CHK singles_same=1' || { echo "FAIL singles"; echo "$OUT" | tail -20; exit 1; }
for k in nmuon_match muon_sorted legacy_load legacy_n muon_load; do
   echo "$OUT" | grep -q "CHK $k=1" || { echo "FAIL $k"; echo "$OUT" | tail -20; exit 1; }
done
echo "PASS monitor-muons (6/6)"
```

- [ ] **Step 5: 시험이 실패하는 것을 확인** (수정 전 헤더로)

Run: `bash tests/monitor-muons.test.sh`
Expected: 컴파일 에러 (ReneMuon 미정의) 또는 FAIL — 아직 구현 전이므로.
(구현을 Step 1~3 에서 먼저 했다면 이 단계는 '캐시에 T_Muons 가 실제로
생기는지' `rootls` 로 눈 확인으로 대체한다.)

- [ ] **Step 6: 시험 통과 확인**

Run: `bash tests/monitor-muons.test.sh`
Expected: `PASS monitor-muons (6/6)`

- [ ] **Step 7: 기존 2단계가 여전히 도는지 확인** (회귀)

Run: `cd ~/DAQ/work-web && tools/monitor/ibd-summary.sh --dry-run 2>&1 | tail -5`
Expected: 정상 출력 (에러 0). 컴파일만 다시 되고 동작 동일.

- [ ] **Step 8: Commit**

```bash
cd ~/DAQ/work-web && git add tools/monitor/RenePrdSingles.h tests/monitor-muons.test.sh
git commit -m "feat: collect muon times in the singles pass, for the DST"
```

---

### Task 2: RenePairing.h — 창을 인자로 받는 변형 + prompt 시각 수집

fast-n 사이드밴드는 S1 창만 다른 페어링이고, Li/He 는 후보의 prompt 시각이
필요하다. 루프를 복제하지 않도록 창 구조체를 받는 `PairAndCountW` 를 만들고
기존 `PairAndCount` 는 그것에 위임한다. 위임이 결과를 바꾸지 않는 것은
Task 4 의 패리티 게이트가 실측으로 다시 확인한다.

**Files:**
- Modify: `tools/monitor/RenePairing.h`
- Test: `tests/monitor-pairing.test.sh`

**Interfaces:**
- Produces: `struct PairWindows { double s1lo,s1hi,s2lo,s2hi,dtMin,dtMax,dtAcci,isoPre,isoPost,lower; };`
- Produces: `inline PairWindows CurrentPairWindows()` — SetChannel 후의 전역 컷을 복사
- Produces: `inline PairCounts PairAndCountW(const std::vector<S1S2_Candidate>&, const PairWindows&, std::vector<double>* onPromptT = nullptr)`
  — onPromptT 를 주면 multiplicity 통과 on-time 쌍의 **prompt(S1) t_us** 를 push
- 기존 `PairAndCount(ev)` = `PairAndCountW(ev, CurrentPairWindows())` 로 위임 (시그니처 불변)

- [ ] **Step 1: 구현**

`PairCounts` 정의 다음에 창 구조체와 수집기를 넣고, 기존 `PairAndCount` 본문을
`PairAndCountW` 로 옮긴 뒤 상수 참조를 전부 `w.` 멤버로 바꾼다:

```cpp
struct PairWindows {
   double s1lo, s1hi, s2lo, s2hi;
   double dtMin, dtMax, dtAcci;
   double isoPre, isoPost, lower;
};

//  SetChannel(CH_NGD/CH_NH) 직후의 전역 컷을 복사한다. PairAndCountW 는
//  전역을 직접 읽지 않으므로, 창만 바꾼 페어링(fast-n 사이드밴드)을
//  전역을 건드리지 않고 돌릴 수 있다.
inline PairWindows CurrentPairWindows() {
   PairWindows w;
   w.s1lo = S1_MIN_NPE; w.s1hi = S1_MAX_NPE;
   w.s2lo = S2_MIN_NPE; w.s2hi = S2_MAX_NPE;
   w.dtMin = DT_MIN_US; w.dtMax = DT_MAX_US; w.dtAcci = DT_ACCI_US;
   w.isoPre = ISO_PRE_US; w.isoPost = ISO_POST_US; w.lower = LOWER_LIMIT;
   return w;
}

inline PairCounts PairAndCountW(const std::vector<S1S2_Candidate> &ev,
                                const PairWindows &w,
                                std::vector<double> *onPromptT = nullptr) {
   //  (기존 PairAndCount 본문 그대로, 다만
   //   S1_MIN_NPE -> w.s1lo, S1_MAX_NPE -> w.s1hi,
   //   S2_MIN_NPE -> w.s2lo, S2_MAX_NPE -> w.s2hi,
   //   DT_MIN_US -> w.dtMin, DT_MAX_US -> w.dtMax, DT_ACCI_US -> w.dtAcci,
   //   ISO_PRE_US -> w.isoPre, ISO_POST_US -> w.isoPost,
   //   LOWER_LIMIT -> w.lower 로 치환.
   //   on-time 루프의 `c.nCoincMult++;` 자리는 다음으로 :
   //       if (passMult(...)) {
   //          c.nCoincMult++;
   //          if (onPromptT) onPromptT->push_back(s1._t_us);
   //       }
   //   off-time 루프는 수집하지 않는다.)
}

inline PairCounts PairAndCount(const std::vector<S1S2_Candidate> &ev) {
   return PairAndCountW(ev, CurrentPairWindows());
}
```

치환은 기계적으로: 본문을 복사한 뒤 `sed` 가 아니라 손으로 10개 상수를
바꾸고, 바꾼 수가 정확히 위 10종인지 diff 로 확인한다.

- [ ] **Step 2: 합성 시험 작성**

`tests/monitor-pairing.test.sh` — ROOT 만 있으면 돈다 (실데이터 불필요.
단 AnalysisCondition.h 는 include 되므로 분석 트리는 필요).

```bash
#!/usr/bin/env bash
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh 2>/dev/null
command -v root >/dev/null 2>&1 || { echo "SKIP: ROOT 없음"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/t.C" <<'EOF2'
#include "TOOLDIR/RenePrdSingles.h"
#include "TOOLDIR/RenePairing.h"
void t() {
   SetChannel(CH_NGD);
   PairWindows w = CurrentPairWindows();
   //  손으로 만든 이벤트 : S1(창 안 에너지) 하나 + 그 dt 창 안 S2 하나.
   //  에너지는 창 중앙값으로 잡아 어떤 사이트 상수여도 통과한다.
   double e1 = 0.5*(w.s1lo+w.s1hi), e2 = 0.5*(w.s2lo+w.s2hi);
   double dt = 0.5*(w.dtMin+w.dtMax);
   std::vector<S1S2_Candidate> ev;
   ev.push_back({0,0, 1000.0,           e1});
   ev.push_back({1,0, 1000.0+dt,        e2});
   ev.push_back({2,0, 1000.0+w.dtAcci+dt, e2});   // 우발 창 상대
   std::vector<double> pt;
   PairCounts a = PairAndCountW(ev, w, &pt);
   PairCounts b = PairAndCount(ev);
   printf("CHK delegate=%d\n", (int)(a.nCoinc==b.nCoinc && a.nAcci==b.nAcci
          && a.nCoincMult==b.nCoincMult && a.nAcciMult==b.nAcciMult));
   printf("CHK found_pair=%d\n", (int)(a.nCoincMult>=1));
   printf("CHK prompt_t=%d\n", (int)(!pt.empty() && std::fabs(pt[0]-1000.0)<1e-9));
   //  S1 창을 비켜 세우면 쌍이 사라져야 한다
   PairWindows w2 = w; w2.s1lo = e1*10; w2.s1hi = e1*20;
   PairCounts c = PairAndCountW(ev, w2);
   printf("CHK window_moves=%d\n", (int)(c.nCoincMult==0));
}
EOF2
sed -i "s|TOOLDIR|$DIR/tools/monitor|g" "$T/t.C"
OUT=$(root -l -b -q "$T/t.C+" 2>&1)
for k in delegate found_pair prompt_t window_moves; do
   echo "$OUT" | grep -q "CHK $k=1" || { echo "FAIL $k"; echo "$OUT" | tail -20; exit 1; }
done
echo "PASS monitor-pairing (4/4)"
```

- [ ] **Step 3: 시험 통과 확인**

Run: `bash tests/monitor-pairing.test.sh`
Expected: `PASS monitor-pairing (4/4)`

- [ ] **Step 4: Commit**

```bash
cd ~/DAQ/work-web && git add tools/monitor/RenePairing.h tests/monitor-pairing.test.sh
git commit -m "feat: window-parameterized pairing with prompt-time collection"
```

---

### Task 3: BuildMonitorDst.C + dst-build.sh — 2차 프로덕션

런 하나를 서브런 순서대로 훑어(carry 유지) 확장 캐시를 채우고, 캐시에서
`DST_<런>.root` 를 조립한다. 이미 확장 캐시가 있는 서브런은 파형을 다시
읽지 않는다. 산출물은 재생 가능 캐시다 (백업·dataflow 무관).

**Files:**
- Create: `tools/monitor/BuildMonitorDst.C`
- Create: `tools/monitor/dst-build.sh` (rate-trend.sh 패턴)
- Test: `tests/monitor-dst.test.sh`

**Interfaces:**
- Produces: `/scratch/RunSummary/dst/DST_<NNNNNN>.root`
  - `T_Singles` : evt_id/I, sub_id/I, t_us/D, pe/F (시간 순)
  - `T_Muons`   : sub_id/I, t_us/D, pe/F, sat/B (시간 순)
  - `T_Info`    : run/I, thr_npe/D, veto_us/D, n_subrun/I, n_bad/I, live_s/D, built/L, schema/I(=1)
- Produces: 매크로 진입점 `void BuildMonitorDst(const char* runList, const char* outDir, const char* rawRoots, double vetoCutUs = 150.0, bool force = false, int maxSubrun = -1)`
  — runList 는 "4237" 또는 "4237,4239" 꼴. maxSubrun 은 시험용 (BuildPairSummary 와 같은 뜻)
- ★ 스펙 §3 의 싱글별 dt_prev_muon 열은 **저장하지 않는다** — 샤워링 문턱이
  파라미터라 뮤온 트리에서 그때그때 계산해야 맞고(BuildMetrics 의 두 포인터),
  싱글에 박아 두면 문턱이 바뀔 때 낡는다. 스펙의 목적(레시피가 바뀌어도 PRD
  재독 없음)은 뮤온 트리가 채운다. 스펙 대비 의도된 정련이다.
- Consumes: Task 1 의 `ReneProcessSubrun(...,&muons)` / `ReneSaveCache(...,&muons,muFirst)` / `ReneLoadCacheMuons`
- dst-build.sh 사용법: `dst-build.sh --list 4237,4240 [--force] [--dry-run] [--max-subrun N]`
  환경 `RUNSUM_OUT`(기본 /scratch/RunSummary), `RENE_RAW_ROOTS`(기본 /Data_ssd/RAW:/data/RAW:/scratch/RAW)

- [ ] **Step 1: 매크로 작성**

`tools/monitor/BuildMonitorDst.C` 핵심 흐름 (thr 계산은 BuildPairSummary.C:477-480 과
같은 식이어야 캐시가 공유된다):

```cpp
//  BuildMonitorDst.C - PRD 에서 런당 DST 하나를 만든다 (2차 프로덕션).
//  뮤온 시각과 클린 싱글만 담는다. 컷이 바뀌어도 PRD 를 다시 읽지 않고
//  이 파일에서 재계산하는 것이 목적이다 (CLAUDE.md 스펙 2026-09-08).
//  ★ 산출물은 재생 가능 캐시다 -- 백업하지 않는다.
#include "RenePrdSingles.h"
#include <TStopwatch.h>

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
      bool ok = ReneLoadCache(cpath, thr, vetoCutUs, sing, carry, st) &&
                ReneLoadCacheMuons(cpath, muons);
      if (!ok) {
         //  둘 중 하나라도 없으면 파형에서 새로 만든다 (확장 캐시로 덮어씀)
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
   /*  T_Singles / T_Muons / T_Info 를 위 Interfaces 브랜치 그대로 채운다.
       (evt_id,sub_id,t_us,pe) <- sing,  (sub_id,t_us,pe,sat) <- muons,
       T_Info <- run, thr, vetoCutUs, subs.size(), nBad, liveS,
                 (Long64_t)time(nullptr), schema=1  */
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
```

주석 자리(`/* ... */`)의 트리 채우기는 Interfaces 의 브랜치 명세를 그대로
코드로 옮긴다 — `ReneSaveCache` 의 브랜치 작성부와 같은 모양이다.

- [ ] **Step 2: dst-build.sh 작성** (rate-trend.sh 를 본뜬 60줄 내외)

```bash
#!/usr/bin/env bash
# dst-build.sh - PRD 에서 런당 DST 하나를 만든다 (2차 프로덕션 단계).
#   사용 : dst-build.sh --list 4237,4240 [--force] [--dry-run]
#   환경 : RUNSUM_OUT (기본 /scratch/RunSummary)
#          RENE_RAW_ROOTS (기본 /Data_ssd/RAW:/data/RAW:/scratch/RAW)
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=${RUNSUM_OUT:-/scratch/RunSummary}
ROOTS=${RENE_RAW_ROOTS:-/Data_ssd/RAW:/data/RAW:/scratch/RAW}
LIST=""; FORCE=false; DRY=0
while [ $# -gt 0 ]; do
   case "${1:-}" in
      --list)    LIST=${2:-}; shift 2 ;;
      --force)   FORCE=true; shift ;;
      --dry-run) DRY=1; shift ;;
      --max-subrun) MAXSUB=${2:-\-1}; shift 2 ;;
      -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
      *) echo "모르는 옵션 : $1"; exit 1 ;;
   esac
done
MAXSUB=${MAXSUB:--1}
[ -n "$LIST" ] || { echo "--list 가 필요하다"; exit 1; }
[ -d "$OUT" ]  || { echo "출력 디렉터리가 없다 : $OUT (\/scratch 마운트 확인)"; exit 1; }
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh
command -v root >/dev/null 2>&1 || { echo "ROOT 를 찾을 수 없다"; exit 1; }
echo "DST   : $OUT/dst/   런 : $LIST"
[ "$DRY" = 1 ] && { echo "(dry-run) 여기서 멈춘다"; exit 0; }
root -l -b -q "$DIR/BuildMonitorDst.C+(\"$LIST\", \"$OUT/\", \"$ROOTS\", 150.0, $FORCE, $MAXSUB)"
```

- [ ] **Step 3: 시험 작성 + 실행**

`tests/monitor-dst.test.sh` — 가장 작은 완결 런(run 4220, 서브런 1개)으로:

```bash
#!/usr/bin/env bash
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh 2>/dev/null
command -v root >/dev/null 2>&1 || { echo "SKIP: ROOT 없음"; exit 0; }
RUN=4220
FOUND=0
for r in /Data_ssd/RAW /data/RAW /scratch/RAW; do
   [ -d "$r/00$RUN/PRD" ] && FOUND=1 && break
done
[ "$FOUND" = 1 ] || { echo "SKIP: run $RUN PRD 없음"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/out"
# 1) 첫 빌드 (파형 경로)
RUNSUM_OUT="$T/out" "$DIR/tools/monitor/dst-build.sh" --list $RUN > "$T/log1" 2>&1 \
   || { echo "FAIL build1"; tail -20 "$T/log1"; exit 1; }
DST="$T/out/dst/DST_00$RUN.root"
[ -s "$DST" ] || { echo "FAIL: DST 없음"; exit 1; }
# 2) 트리 셋 존재 + 싱글 수 == 캐시 싱글 수
OUT=$(root -l -b -q -e "
   TFile f(\"$DST\");
   TTree*s=(TTree*)f.Get(\"T_Singles\"); TTree*m=(TTree*)f.Get(\"T_Muons\");
   TTree*i=(TTree*)f.Get(\"T_Info\");
   printf(\"CHK trees=%d\n\", (int)(s&&m&&i));
   printf(\"CHK muons_pos=%d\n\", (int)(m->GetEntries()>0));
" 2>&1)
echo "$OUT" | grep -q 'CHK trees=1'     || { echo "FAIL trees"; exit 1; }
echo "$OUT" | grep -q 'CHK muons_pos=1' || { echo "FAIL muons"; exit 1; }
# 3) 재실행은 캐시 경로 -- '캐시 1 / 새로 0' 이어야 한다
RUNSUM_OUT="$T/out" "$DIR/tools/monitor/dst-build.sh" --list $RUN --force > "$T/log2" 2>&1
grep -q '캐시 1 / 새로 0' "$T/log2" || { echo "FAIL resume"; tail -5 "$T/log2"; exit 1; }
# 4) force 없는 재실행은 '최신' 으로 건너뛴다
RUNSUM_OUT="$T/out" "$DIR/tools/monitor/dst-build.sh" --list $RUN > "$T/log3" 2>&1
grep -q 'DST 최신' "$T/log3" || { echo "FAIL uptodate"; exit 1; }
# 5) 서브런 경계 단조성 -- run 4237 을 서브런 0~1 만으로 새 캐시에 빌드,
#    두 트리 모두 t_us 가 경계를 넘어 단조 증가해야 한다 (carry 확인)
FOUND2=0
for r in /Data_ssd/RAW /data/RAW /scratch/RAW; do
   [ -f "$r/004237/PRD/PRD_004237.00001.root" ] && FOUND2=1 && break
done
if [ "$FOUND2" = 1 ]; then
   mkdir -p "$T/out2"
   RUNSUM_OUT="$T/out2" "$DIR/tools/monitor/dst-build.sh" --list 4237 --max-subrun 1 \
      > "$T/log4" 2>&1 || { echo "FAIL build-4237"; tail -10 "$T/log4"; exit 1; }
   OUT2=$(root -l -b -q -e "
      TFile f(\"$T/out2/dst/DST_004237.root\");
      for (const char* tn : {\"T_Singles\", \"T_Muons\"}) {
         TTree* t=(TTree*)f.Get(tn); Double_t tu; t->SetBranchAddress(\"t_us\",&tu);
         double prev=-1e18; bool mono=true; int nsub2=0; Int_t sb;
         t->SetBranchAddress(\"sub_id\",&sb);
         std::set<int> ss2;
         for (Long64_t i=0;i<t->GetEntries();++i){ t->GetEntry(i);
            if (tu<prev) mono=false; prev=tu; ss2.insert(sb); }
         printf(\"CHK %s_mono=%d nsub=%zu\n\", tn, (int)mono, ss2.size());
      }" 2>&1)
   echo "$OUT2" | grep -q 'CHK T_Singles_mono=1 nsub=2' || { echo "FAIL boundary-singles"; exit 1; }
   echo "$OUT2" | grep -q 'CHK T_Muons_mono=1 nsub=2'   || { echo "FAIL boundary-muons"; exit 1; }
   echo "PASS monitor-dst (6/6)"
else
   echo "PASS monitor-dst (4/4, 경계 시험 SKIP: 4237 없음)"
fi
```

Run: `bash tests/monitor-dst.test.sh`
Expected: `PASS monitor-dst (6/6)`

- [ ] **Step 4: 실측 기록** — 24h 런 하나(예: 4305)로 DST 를 만들어 크기와
소요 시간을 재고 수치를 적어 둔다 (Task 10 문서에 들어간다).

Run: `tools/monitor/dst-build.sh --list 4305 2>&1 | tail -3 && ls -lh /scratch/RunSummary/dst/`
Expected: `[DST] run 4305 : ...` 와 파일 크기. (기존 싱글 캐시가 있으면
뮤온이 없어 전부 재생성된다 — 처음 한 번은 파형 비용을 낸다.)

- [ ] **Step 5: Commit**

```bash
cd ~/DAQ/work-web && git add tools/monitor/BuildMonitorDst.C tools/monitor/dst-build.sh tests/monitor-dst.test.sh
git commit -m "feat: second-production DST stage (muons + clean singles per run)"
```

---

### Task 4: BuildMetrics.C (IBD 패리티) + metrics.sh + 전환 게이트

DST 만 읽어 페어링을 다시 하고 `metrics_summary.tsv` 를 쓴다. 이 Task 의
합격선은 **legacy 와의 일치**다: run 4237 + 최근 완결 런 1개에서
n_ibd·n_ibd_acci 가 pair_summary.tsv 와 같아야 한다.

**Files:**
- Create: `tools/monitor/BuildMetrics.C`
- Create: `tools/monitor/metrics.sh`
- Test: `tests/monitor-metrics.test.sh` (패리티 부분)

**Interfaces:**
- Produces: `<RUNSUM_OUT>/metrics_summary.tsv` schema 1, 열 순서:
  `run tag src live_s n_paired n_paired_acci n_ibd n_ibd_acci n_single r_ll n_subrun n_mu n_mu_shower n_lihe e_lihe lihe_stat n_fn_side n_fn_side_scaled n_fn_mutag dt_min dt_max dt_acci s2_lo s2_hi iso_pre iso_post mu_shower_npe fn_e_lo fn_e_hi fn_tag_s lihe_fit_lo lihe_fit_hi`
  (앞 11열은 pair_summary schema 2 와 같은 의미·순서. 음수 = 정보 없음.
   lihe_stat 은 문자열 ok|lowstat|nofit|off)
- Produces: 매크로 진입점
  `void BuildMetrics(const char* runList, const char* outDir, double muShowerNpe, double liheFitLoS, double liheFitHiS, int liheMinCand, double fnELoMev, double fnEHiMev, double fnTagS, bool force = false)`
- Produces: `metrics.sh --list A,B [--force] [--verify] [--dry-run]`
  — `--verify` 는 metrics_summary 와 pair_summary 의 공통 (run,tag) 행에서
  n_ibd·n_ibd_acci 를 대조해 다르면 exit 1 (전환 게이트의 실행형)
- Consumes: Task 2 `PairAndCountW`/`CurrentPairWindows`, Task 3 DST 파일.
- 이 Task 에서 Li/He·fast-n 열은 **자리만** 만들고 -1/off 로 채운다 (Task 5 가 채운다).

- [ ] **Step 1: 매크로 골격 작성** — DST 로더 + 태그별 페어링 + TSV.

```cpp
//  BuildMetrics.C - DST 에서 런 지표를 계산한다. PRD 는 읽지 않는다.
//  IBD/acci 는 legacy(BuildPairSummary)와 같은 값이어야 하며 metrics.sh
//  --verify 가 그것을 대조한다. Li/He·fast-n 은 Task 5 에서 채운다.
#include "RenePrdSingles.h"     // S1S2_Candidate, SetChannel, ChannelTag
#include "RenePairing.h"
#include <fstream>
#include <map>
#include <sstream>

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
```

메인 루프 (런마다):

```cpp
   //  런마다 : DST 로드 -> 두 태그 페어링 -> 행 갱신 -> 그때그때 저장
   for (int run : runs) {
      TString dst = out + TString::Format("dst/DST_%s.root", ReneRunStr(run).Data());
      std::vector<S1S2_Candidate> sing; std::vector<ReneMuon> mu;
      double liveS = 0; int nSubrun = 0;
      if (!LoadDst(dst, sing, mu, liveS, nSubrun)) {
         printf("  [SKIP] run %d : DST 없음 (dst-build.sh 먼저)\n", run); continue;
      }
      const Channel chans[2] = {CH_NGD, CH_NH};
      for (Channel ch : chans) {
         SetChannel(ch);
         PairWindows w = CurrentPairWindows();
         std::vector<double> promptT;
         PairCounts pc = PairAndCountW(sing, w, &promptT);
         MetRow r;  /* run/tag/liveS/counts/컷값을 legacy 와 같은 자리에.
                       r.nSingle = sing.size(); r.rll = liveS>0? sing.size()/liveS : -1;
                       r.nMu = mu.size();
                       Li/He·fast-n 은 -1/off (Task 5).  */
         rows[key(run, r.tag)] = r;
      }
      WriteTsv(...); WriteTxt 는 만들지 않는다(웹이 표를 대신한다);
   }
```

TSV 헤더(첫 3줄)는 pair_summary 방식으로:

```
# RENE run metrics (machine readable). BuildMetrics.C 가 만든다. DST 입력.
# schema 1
#run	tag	src	live_s	... (Interfaces 의 열 순서 그대로)
```

src 는 legacy 와 같은 `runtype.tsv` 를 읽어 채운다 (`LoadRunTypes` 를
BuildPairSummary.C 에서 그대로 옮겨 적는다 — 12줄짜리 파서다).

- [ ] **Step 2: metrics.sh 작성** (dst-build.sh 와 같은 뼈대 + `--verify`)

--verify 구현 (awk, FILENAME 으로 파일을 가른다 — NR==FNR 금지):

```bash
verify() {
   local mfile="$OUT/metrics_summary.tsv" pfile="$OUT/pair_summary.tsv"
   [ -r "$mfile" ] && [ -r "$pfile" ] || { echo "[VERIFY] 두 표가 다 있어야 한다"; return 1; }
   awk -F'\t' -v M="$mfile" '
      /^#/ { next }
      FILENAME==M { ibd[$1 $2]=$7; acc[$1 $2]=$8; next }
      ($1 $2) in ibd {
         n++
         if (ibd[$1 $2] != $7 || acc[$1 $2] != $8) {
            bad++
            printf "  [DIFF] run %s%s : metrics ibd=%s acci=%s / legacy ibd=%s acci=%s\n",
                   $1, $2, ibd[$1 $2], acc[$1 $2], $7, $8 }
      }
      END {
         printf "[VERIFY] 공통 %d 행, 불일치 %d\n", n, bad
         exit (n>0 && bad==0) ? 0 : 1
      }' "$mfile" "$pfile"
}
```

- [ ] **Step 3: 패리티 시험 작성 + 실행**

`tests/monitor-metrics.test.sh`: run 4237 의 DST 를 만들고(`dst-build.sh
--list 4237` — 캐시 덕에 두 번째부터는 빠르다), `metrics.sh --list 4237`
후 `metrics.sh --verify` 가 exit 0 이고 출력에 `불일치 0` 이 있는지.
pair_summary 에 4237 행이 없으면 `ibd-summary.sh --list 4237` 로 먼저 만든다.
/scratch 없으면 SKIP.

Run: `bash tests/monitor-metrics.test.sh`
Expected: `PASS monitor-metrics` + `[VERIFY] 공통 2 행, 불일치 0`

- [ ] **Step 4: 최근 완결 런 1개로도 게이트 확인** (스펙 §4 의 두 번째 기준 런)

Run: `R=$(awk -F'\t' '!/^#/{r=$1} END{print r}' /scratch/RunSummary/pair_summary.tsv); tools/monitor/dst-build.sh --list $R && tools/monitor/metrics.sh --list $R --verify`
Expected: `불일치 0`. 이 결과를 Task 10 의 문서에 기록한다.
**여기서 불일치가 나면 dst 전환은 보류하고 원인을 잡는다 — Task 5 로
넘어가되 metrics_source 는 legacy 로 남긴다.**

- [ ] **Step 5: Commit**

```bash
cd ~/DAQ/work-web && git add tools/monitor/BuildMetrics.C tools/monitor/metrics.sh tests/monitor-metrics.test.sh
git commit -m "feat: DST-based metrics with legacy parity gate"
```

---

### Task 5: Li/He + fast-n (예비 레시피) + monitorcuts.params

**Files:**
- Modify: `tools/monitor/BuildMetrics.C`
- Modify: `tools/monitor/metrics.sh` (params 읽어 매크로 인자로)
- Create: `config/monitorcuts.params.example`
- Test: `tests/monitor-bg.test.sh` (합성 DST 픽스처)

**Interfaces:**
- Consumes: Task 4 의 MetRow/TSV 자리, Task 2 의 `PairAndCountW(ev, w, &promptT)`.
- Produces: metrics_summary.tsv 의 n_lihe·e_lihe·lihe_stat·n_fn_side·n_fn_side_scaled·n_fn_mutag 실값.
- Produces: `BuildMetrics` 마지막 인자 `const char* ibdOverrides = ""` —
  `"dt_max_us=120,s2_lo_mev=5.5"` 꼴. 빈 문자열 = AnalysisCondition.h 값
  그대로 (기본). 허용 키 10종 = PairWindows 의 멤버와 1:1
  (`s1_lo_npe s1_hi_npe s2_lo_mev s2_hi_mev dt_min_us dt_max_us dt_acci_us
  iso_pre_us iso_post_us lower_npe`; *_mev 는 `_NPE_MEV` 로 곱해 NPE 로).
  metrics.sh 는 monitorcuts.params 의 같은 키(주석 해제 시)를 모아 넘긴다.
  **오버라이드가 하나라도 있으면 `--verify` 는 거부한다** — legacy 와 컷이
  다르니 대조가 무의미하고, 게이트를 통과한 척하게 둘 수 없다.
- `config/monitorcuts.params.example` 키:

```
# 새 지표(예비)의 손잡이. ★ 분석팀 검증 전까지 웹에 '(예비)' 로 표시된다.
mu_shower_npe = 3000    # 이 NPE 초과 target 뮤온을 '샤워링' 으로 본다 ★미검증
lihe_fit_lo_s = 0.002   # Li/He 적합 창 [s]
lihe_fit_hi_s = 10.0
lihe_min_cand = 100     # 이보다 후보가 적으면 적합하지 않는다 (lowstat)
fn_e_lo_mev   = 12.0    # fast-n prompt 사이드밴드 [MeV] ★미검증
fn_e_hi_mev   = 50.0
fn_tag_s      = 0.1     # 직전 샤워링 뮤온에서 이 시간 안의 후보 수 = n_fn_mutag

# ---- IBD 컷 오버라이드 (스펙 §4 '컷 변경 = DST 초 단위 재계산') ----
# 주석을 풀면 AnalysisCondition.h 대신 이 값을 쓴다. ★ 하나라도 풀면
# metrics.sh --verify 가 거부한다 (legacy 와 컷이 달라 대조가 무의미).
# dt_max_us   = 120
# s2_lo_mev   = 5.5
# s2_hi_mev   = 10.5
# iso_pre_us  = 200
# iso_post_us = 400
```

- [ ] **Step 1: Li/He 계산 구현** (태그별 promptT 사용, 값은 태그별로 계산)

```cpp
//  후보 prompt 마다 직전 '샤워링 뮤온'(pe > muShowerNpe, pe>0)까지의 dt 를
//  두 포인터로 잰다 (양쪽 다 시간 순). 이전 뮤온이 없으면 제외.
static void LiHeFill(const std::vector<double> &promptT,
                     const std::vector<ReneMuon> &mu, double muShowerNpe,
                     TH1D *h) {
   size_t j = 0; double lastShower = -1;
   std::vector<double> showers;
   for (const auto &m : mu) if (m.pe > muShowerNpe) showers.push_back(m.t_us);
   for (double t : promptT) {
      while (j < showers.size() && showers[j] < t) { lastShower = showers[j]; ++j; }
      if (lastShower > 0) h->Fill((t - lastShower) * 1e-6);   // us -> s
   }
}
//  적합 : N_Li/tauLi * exp(-t/tauLi) * bw + N_He/tauHe * ... + 상수
//  tau 는 고정 (9Li 257 ms, 8He 172 ms). n_lihe = N_Li + N_He.
//  h 엔트리 < liheMinCand -> stat="lowstat", 적합 실패 -> "nofit".
```

TF1 (binWidth 를 [3]에 고정 파라미터로 넣는다):

```cpp
   TF1 f("flihe", "[0]/0.257*exp(-x/0.257)*[3] + [1]/0.172*exp(-x/0.172)*[3] + [2]",
         liheFitLoS, liheFitHiS);
   f.SetParameters(10, 10, 1, h->GetBinWidth(1));
   f.FixParameter(3, h->GetBinWidth(1));
   f.SetParLimits(0, 0, 1e9); f.SetParLimits(1, 0, 1e9); f.SetParLimits(2, 0, 1e9);
   int rc = h->Fit(&f, "QRN0");
   if (rc == 0) { r.nLihe = f.GetParameter(0) + f.GetParameter(1);
                  r.eLihe = std::hypot(f.GetParError(0), f.GetParError(1));
                  r.liheStat = "ok"; }
   else r.liheStat = "nofit";
```

히스토그램: `TH1D h("hdt","",200, 0, liheFitHiS);` (런·태그마다 새로).

- [ ] **Step 2: fast-n 두 추정치 구현**

```cpp
   //  (a) 사이드밴드 : S1 창만 고에너지로 바꾼 페어링. 전역은 건드리지 않는다.
   PairWindows wf = w;
   wf.s1lo = fnELoMev * _NPE_MEV; wf.s1hi = fnEHiMev * _NPE_MEV;
   PairCounts fc = PairAndCountW(sing, wf);
   r.nFnSide = fc.nCoincMult;
   double sigW = (w.s1hi - w.s1lo), sideW = (wf.s1hi - wf.s1lo);
   r.nFnSideScaled = (sideW > 0) ? fc.nCoincMult * (sigW / sideW) : -1;
   //  (b) 뮤온 태그 : 직전 샤워링 뮤온에서 fn_tag_s 안의 후보 수
   //      (LiHeFill 과 같은 두 포인터. dt < fnTagS 이면 ++)
```

★ 주의 주석을 코드에 남긴다: 싱글 단계의 포화 컷 때문에 고에너지
사이드밴드는 포화 미만 사건만 남는다 — 예비 추정치인 이유다.

- [ ] **Step 3: metrics.sh 에서 params 읽기** — `config/monitorcuts.params` 가
있으면 키를 읽어 매크로 인자로 (없으면 example 의 기본값 상수). IBD
오버라이드 키 10종은 존재하는 것만 `k=v,` 로 이어붙여 `ibdOverrides` 로
넘기고, 비어 있지 않은데 `--verify` 를 청하면 그 자리에서 거부한다:

```bash
[ -n "$IBD_OVR" ] && [ "$DO_VERIFY" = 1 ] && {
   echo "[VERIFY] IBD 오버라이드($IBD_OVR)가 있어 legacy 대조가 무의미하다. 거부한다."
   exit 1; }
```

매크로 쪽 파싱(BuildMetrics.C, PairWindows 를 채운 뒤 적용, ~20줄):

```cpp
static void ApplyOverrides(PairWindows &w, const TString &ovr) {
   TObjArray *kv = TString(ovr).Tokenize(",");
   for (int i = 0; i < kv->GetEntries(); ++i) {
      TString t = ((TObjString *)kv->At(i))->GetString();
      Ssiz_t eq = t.First('='); if (eq < 1) continue;
      TString k = t(0, eq); double v = TString(t(eq + 1, t.Length())).Atof();
      if      (k == "s1_lo_npe")  w.s1lo = v;
      else if (k == "s1_hi_npe")  w.s1hi = v;
      else if (k == "s2_lo_mev")  w.s2lo = v * _NPE_MEV;
      else if (k == "s2_hi_mev")  w.s2hi = v * _NPE_MEV;
      else if (k == "dt_min_us")  w.dtMin = v;
      else if (k == "dt_max_us")  w.dtMax = v;
      else if (k == "dt_acci_us") w.dtAcci = v;
      else if (k == "iso_pre_us") w.isoPre = v;
      else if (k == "iso_post_us") w.isoPost = v;
      else if (k == "lower_npe")  w.lower = v;
      else printf("  [WARN] 모르는 오버라이드 키 : %s\n", k.Data());
   }
   delete kv;
}
```

TSV 의 컷 열(dt_min..iso_post)에는 **적용된 실효값**을 적는다 (오버라이드
여부를 표 자체가 증언하게).

기본값용 'key = value' 파서는 dataflow.sh 방식 6줄:

```bash
getp() {   # getp <키> <기본값>
   local k=$1; local d=$2
   [ -r "$CUTS" ] || { echo "$d"; return; }
   awk -F= -v k="$k" '$1 ~ "^[ \t]*"k"[ \t]*$" {gsub(/[ \t#].*$/,"",$2); print $2; f=1}
        END{if(!f) exit 1}' "$CUTS" 2>/dev/null || echo "$d"
}
```

- [ ] **Step 4: 합성 픽스처 시험** — `tests/monitor-bg.test.sh` 가 ROOT 로
가짜 DST 를 만든다: 뮤온 1,000개(전부 pe=5000 샤워링, 10 s 간격) + 각 뮤온
뒤 τ=0.257 s 지수분포 dt 로 후보성 싱글 쌍 500개(S1+S2, IBD 창 통과하게
배치) + 평평한 우발 배경. 그 DST 에 BuildMetrics 를 돌려:

```
CHK lihe_stat=ok
CHK lihe_range=1        # n_lihe 가 참값 500 의 ±3σ(e_lihe 기준) 안
CHK fn_side_zero=1      # 고에너지 싱글을 안 넣었으므로 n_fn_side==0
CHK mutag_pos=1         # fn_tag_s=1.0 로 주면 n_fn_mutag > 0
CHK override_moves=1    # ibdOverrides 로 S2 창을 비켜 세우면 n_ibd 가 준다
CHK verify_refused=1    # 오버라이드 있는 채 --verify -> exit 1 + '거부' 문구
```

픽스처 생성 매크로는 시험 스크립트 안 heredoc 으로 두고, Task 3 의 DST
브랜치 명세와 같은 이름으로 쓴다. S1/S2 에너지·dt 배치는 Task 2 시험처럼
`CurrentPairWindows()` 중앙값으로 만들어 사이트 상수와 무관하게 한다.

Run: `bash tests/monitor-bg.test.sh`
Expected: `PASS monitor-bg (6/6)`

- [ ] **Step 5: 실런 확인 + 패리티 재확인** — run 4237 에 다시 돌려
`--verify` 가 여전히 `불일치 0` (Li/He 추가가 IBD 열을 안 건드림).

Run: `tools/monitor/metrics.sh --list 4237 --force && tools/monitor/metrics.sh --verify`

- [ ] **Step 6: Commit**

```bash
cd ~/DAQ/work-web && git add tools/monitor/BuildMetrics.C tools/monitor/metrics.sh config/monitorcuts.params.example tests/monitor-bg.test.sh
git commit -m "feat: preliminary Li/He fit and fast-n estimators from the DST"
```

---

### Task 6: BuildRateTrend.C — 타입별 rate 4그림

**Files:**
- Modify: `tools/monitor/BuildRateTrend.C`
- Test: `tests/monitor-typetrend.test.sh`

**Interfaces:**
- Produces: `rate_trend_evt_total.png`, `rate_trend_evt_target.png`,
  `rate_trend_evt_veto.png`, `rate_trend_evt_coinc.png` (기존 rate_trend_* 옆)
- Consumes: run_summary.tsv 파싱 블록(238행 부근)과 `Series`/`DrawPage`.

- [ ] **Step 1: 구현** — run_summary 파싱 블록에서 n_type1~3 도 읽도록 확장:

```cpp
   //  기존 : int run, nsub, nbad; double es, ee, wall, span, lv;
   //  추가로 dead 와 타입별 수까지 읽는다 (schema 2 의 10~12열)
   double dead; long long t1, t2, t3;
   if (!(ss >> run >> nsub >> nbad >> es >> ee >> wall >> span >> lv
            >> dead >> t1 >> t2 >> t3)) continue;
```

`#include <array>` 를 추가하고, epoch/live 맵 옆에 `std::map<int, std::array<double,4>> typeRate;` 를 만들어
`lv>0` 이면 `{(t1+t2+t3)/lv, t1/lv, t2/lv, t3/lv}` 를 담는다. PDF 페이지들
뒤(누적 그림 다음, `printf("[SAVED]...` 앞)에 네 페이지 추가:

```cpp
   {  // 8~11) DAQ 이벤트 rate (런당 점 하나. 표의 타입별 수와 같은 자료)
      const char *nm[4] = {"evt_total", "evt_target", "evt_veto", "evt_coinc"};
      const char *tt[4] = {"Total trigger rate", "Target only (FADC) rate",
                           "VETO only (SADC) rate", "VETO+Target coincidence rate"};
      const int   cl[4] = {kBlack, kRed + 1, kBlue + 1, kGreen + 2};
      for (int k = 0; k < 4; ++k) {
         Series s; s.label = tt[k]; s.color = cl[k]; s.marker = 20;
         for (auto &kv : typeRate) {
            auto ie = epoch.find(kv.first);
            if (ie == epoch.end()) continue;
            s.x.push_back(ie->second); s.y.push_back(kv.second[k]);
         }
         std::vector<Series> v{s};
         DrawPage(pdf, png, nm[k], tt[k], "Rate [Hz]", v, "", false, page);
      }
   }
```

`DrawPage` 의 실제 시그니처(`pdfMode`/`logy`/`page` 자리)는 168행 정의를
보고 그대로 맞춘다 — 기존 호출부(343행)와 같은 꼴이면 된다.

- [ ] **Step 2: 시험** — `tests/monitor-typetrend.test.sh`: 픽스처
run_summary.tsv + pair_summary.tsv (각 3행) 를 임시 RUNSUM_OUT 에 두고
rate-trend.sh 실행 → 4개 PNG 존재 + 크기 > 5KB + 기존 7종도 그대로 생성.
픽스처 행은 실제 스키마 그대로 (Task 4 의 열 주석 참조). /scratch 불필요
(임시 디렉터리라 ROOT 만 있으면 된다). rate-trend.sh 의 COND 검사 때문에
분석 트리는 필요 — 없으면 SKIP.

Run: `bash tests/monitor-typetrend.test.sh`
Expected: `PASS monitor-typetrend`

- [ ] **Step 3: 실자료 확인** — `tools/monitor/rate-trend.sh` 를 실제로 돌려
`/scratch/RunSummary/rate_trend_evt_*.png` 4개가 생기는지, 기존 그림이
그대로인지 본다.

- [ ] **Step 4: Commit**

```bash
cd ~/DAQ/work-web && git add tools/monitor/BuildRateTrend.C tests/monitor-typetrend.test.sh
git commit -m "feat: per-type trigger-rate trend plots, one dot per run"
```

---

### Task 7: gen-summary-html.sh — 런당 1줄 표 페이지

로컬 HTML 은 발행 수단이 바뀌어도 남는 공통 산출물이다 (파일로 열어 보거나
나중에 경희대/자체 서버로 발행할 때 그대로 쓴다).

**Files:**
- Create: `tools/monitor/gen-summary-html.sh`
- Test: `tests/monitor-html.test.sh`

**Interfaces:**
- 사용법: `gen-summary-html.sh <TSV디렉터리> <출력.html> <metrics_source:legacy|dst> <refresh_s>`
- Consumes: run_summary.tsv + pair_summary.tsv (+ metrics_summary.tsv, dst 일 때)
- Produces: 스펙 §5 의 15열 표. 최신 런이 위. `<meta http-equiv="refresh">`,
  갱신 시각 스탬프, dst 모드의 fast-n·Li/He 값 옆 `(예비)`, legacy 모드는 `—`.

- [ ] **Step 1: 구현** — bash + awk 단일 파일 (~150줄). 골자:

```bash
#!/usr/bin/env bash
# gen-summary-html.sh <tsvdir> <out.html> <legacy|dst> <refresh_s>
set -u
TSV=${1:?}; OUTF=${2:?}; SRC=${3:-legacy}; REFRESH=${4:-600}
RS="$TSV/run_summary.tsv"; PS="$TSV/pair_summary.tsv"; MS="$TSV/metrics_summary.tsv"
[ -r "$RS" ] && [ -r "$PS" ] || { echo "표의 입력이 없다 : $RS / $PS"; exit 1; }
[ "$SRC" = dst ] && [ ! -r "$MS" ] && { echo "metrics_source=dst 인데 $MS 가 없다"; exit 1; }
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
awk -F'\t' -v RSF="$RS" -v PSF="$PS" -v MSF="${MS:-}" -v SRC="$SRC" '
   /^#/ { next }
   FILENAME==RSF { run[$1]=1; es[$1]=$4; live[$1]=$8; wall[$1]=$6
                   t1[$1]=$10; t2[$1]=$11; t3[$1]=$12; next }
   FILENAME==PSF { if (SRC=="legacy") { ibd[$1 $2]=$7; acc[$1 $2]=$8
                     rll[$1]=$17; src[$1]=$3 } next }
   FILENAME==MSF { if (SRC=="dst")    { ibd[$1 $2]=$7; acc[$1 $2]=$8
                     rll[$1]=$10; src[$1]=$3
                     lihe[$1]=$14; lihestat[$1]=$16; fns[$1]=$18 } next }
   END {
      n = asorti(run, order)          # gawk. 내림차순은 출력 루프에서 역순으로
      for (k = n; k >= 1; --k) {
         r = order[k]
         # 각 열을 탭으로 내보낸다. 없는 값은 "-".
         printf "%s\t%s\t...\n", r, es[r] ...
      }
   }' "$RS" "$PS" ${MS:+"$MS"} > "$TMP"
```

END 블록은 15열을 만든다: run · 시작시각(`strftime("%Y-%m-%d %H:%M", es)`)
· live/wall(`h` 단위 소수1) · 전체(t1+t2+t3) · t1 · t2 · t3 · IBD nGd ·
acci nGd · IBD nH · acci nH · R_LL · fast-n · Li/He · 선원. fast-n/Li-He 는
SRC=dst 이고 lihe_stat=="ok" 일 때만 수치+`(예비)`, 아니면 `—`.
그 다음 HTML 래퍼를 heredoc 으로 쓰고 `$TMP` 를 `<tr>` 로 변환한다:

```bash
{
cat <<HTML
<!DOCTYPE html><html lang="ko"><head><meta charset="utf-8">
<meta http-equiv="refresh" content="$REFRESH">
<title>RENE Run Summary</title>
<style>
 body{font-family:sans-serif;margin:16px;background:#fafafa}
 table{border-collapse:collapse;font-size:13px;white-space:nowrap}
 th,td{border:1px solid #ccc;padding:3px 8px;text-align:right}
 th{background:#eef;position:sticky;top:0}
 td:first-child,th:first-child{text-align:center;font-weight:bold}
 .src{color:#a50}  .pre{color:#888;font-size:11px}
</style></head><body>
<h2>RENE Run Summary</h2>
<p>갱신 : $(date '+%F %T')  ·  출처 : $SRC  ·  fast-n·Li/He 는 분석팀 검증 전 <span class="pre">(예비)</span></p>
<table><tr><th>Run</th><th>시작</th><th>live/wall [h]</th><th>전체</th>
<th>Target only</th><th>VETO only</th><th>V+T</th><th>IBD nGd</th><th>acci nGd</th>
<th>IBD nH</th><th>acci nH</th><th>R_LL [Hz]</th><th>fast-n</th><th>Li/He</th><th>선원</th></tr>
HTML
awk -F'\t' '{ printf "<tr>"; for(i=1;i<=NF;i++) printf "<td>%s</td>", $i; print "</tr>" }' "$TMP"
echo "</table></body></html>"
} > "$OUTF"
echo "[SAVED] $OUTF ($(grep -c '<tr>' "$OUTF") 행)"
```

- [ ] **Step 2: 픽스처 시험** — `tests/monitor-html.test.sh`: 3런짜리 픽스처
TSV 로 legacy/dst 두 모드 생성 후 확인: ① 행 수 == 런 수+1(헤더) ② 첫 데이터
행이 가장 큰 런 ③ legacy 모드에 `—` 가 있고 `(예비)` 없음 ④ dst 모드에
`(예비)` 있음 ⑤ 선원 런의 src 표기 ⑥ refresh 메타에 준 값. ROOT 불필요 —
언제나 돈다.

Run: `bash tests/monitor-html.test.sh`
Expected: `PASS monitor-html (6/6)`

- [ ] **Step 3: Commit**

```bash
cd ~/DAQ/work-web && git add tools/monitor/gen-summary-html.sh tests/monitor-html.test.sh
git commit -m "feat: one-row-per-run summary page generator"
```

---

### Task 8: publish_google.py — 시트 append + 드라이브 그림 교체

**Files:**
- Create: `tools/monitor/publish_google.py`
- Create: `config/websummary.params.example`
- Test: `tests/monitor-publish.test.sh` (--dry-run 만. 실 API 는 Task 10)

**Interfaces:**
- 사용법:
  `publish_google.py --params config/websummary.params [--dry-run] [--init]`
- Consumes: Task 7 이 만든 표 데이터와 같은 TSV 들 + rate_trend PNG 들.
- Produces(실행 시): 시트에 새 런 행 append, 드라이브 파일 내용 교체.
  `--init` 은 PNG 들을 새 파일로 올리고 `map_file` 을 쓰고 퍼가기 URL 을 찍는다.
- `config/websummary.params.example`:

```
# 웹 서머리 발행 설정. 실파일(websummary.params)은 gitignore 대상.
sheet_id      =            # 런 서머리 전용 새 스프레드시트 (GoodRuns 아님!)
sheet_gid     = 0
drive_folder_id =          # 서비스 계정과 공유한 드라이브 폴더
map_file      = config/websummary.map   # --init 이 쓴다 (이름<TAB>fileId)
metrics_source = legacy    # 패리티 게이트 + 사용자 승인 후에만 dst
refresh_s     = 600
webroot       = /scratch/RunSummary/web
tsv_dir       = /scratch/RunSummary
publish       = 1          # 0 이면 로컬 생성까지만
start_run     = 4280       # 이 번호부터 싣는다
```

- [ ] **Step 1: 구현** (~250줄). 뼈대:

```python
#!/usr/bin/env python3
"""런 서머리를 구글 시트/드라이브로 발행한다.
   시트 : 새 런 행만 append (기존 행 불변 -- 쓰기 전 백업, 쓴 뒤 되대조)
   드라이브 : map_file 의 이름->fileId 로 PNG 내용을 같은 ID 에 교체
   --init : PNG 를 새 파일로 올리고 map_file 과 퍼가기 URL 을 찍는다
   새 pip 의존 없음 : gspread + google-auth + urllib 뿐이다."""
import argparse, glob, json, os, sys, time, urllib.request

SCOPES = ["https://www.googleapis.com/auth/spreadsheets",
          "https://www.googleapis.com/auth/drive"]

def find_creds():            # append_runs.py 의 순서 그대로
    env = os.environ.get("RENE_SHEETS_SA")
    if env and os.path.isfile(env): return env
    here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    for d in (os.path.join(here, ".config", "rene"), os.path.expanduser("~/.config/rene")):
        hit = sorted(glob.glob(os.path.join(d, "*.json")))
        if hit: return hit[0]
    return None

def read_params(path):
    p = {}
    for ln in open(path, encoding="utf-8"):
        ln = ln.split("#", 1)[0].strip()
        if "=" in ln:
            k, v = ln.split("=", 1); p[k.strip()] = v.strip()
    return p

def read_tsv(path):
    rows = []
    if not os.path.isfile(path): return rows
    for ln in open(path, encoding="utf-8"):
        if ln.startswith("#") or not ln.strip(): continue
        rows.append(ln.rstrip("\n").split("\t"))
    return rows

def build_rows(p):
    """TSV 셋을 합쳐 시트 열(= HTML 표와 같은 15열) 리스트를 만든다.
       gen-summary-html.sh 와 같은 조인 규칙. run 오름차순 (시트는 아래로
       자라는 것이 자연스럽다 -- HTML 만 최신을 위로 뒤집는다)."""
    d = p["tsv_dir"]; src = p.get("metrics_source", "legacy")
    start = int(p.get("start_run", "0"))
    rs = {int(r[0]): r for r in read_tsv(os.path.join(d, "run_summary.tsv"))}
    pair_f = "metrics_summary.tsv" if src == "dst" else "pair_summary.tsv"
    ibd = {}   # (run, tag) -> row
    for r in read_tsv(os.path.join(d, pair_f)):
        ibd[(int(r[0]), r[1])] = r
    out = []
    for run in sorted(rs):
        if run < start: continue
        r = rs[run]
        es, live, wall = float(r[3]), float(r[7]), float(r[5])
        t1, t2, t3 = int(r[9]), int(r[10]), int(r[11])
        gd = ibd.get((run, "_nGd")); nh = ibd.get((run, "_nH"))
        def col(row, i): return row[i] if row else "-"
        rll = col(gd, 9 if src == "dst" else 16)
        srcflag = col(gd, 2)
        if src == "dst" and gd and len(gd) > 18 and gd[15] == "ok":
            lihe = f"{float(gd[13]):.1f}(예비)"; fn = f"{float(gd[17]):.1f}(예비)"
        else:
            lihe = fn = "—"
        out.append([run, time.strftime("%Y-%m-%d %H:%M", time.gmtime(es)),
                    f"{live/3600:.1f}/{wall/3600:.1f}", t1 + t2 + t3, t1, t2, t3,
                    col(gd, 6), col(gd, 7), col(nh, 6), col(nh, 7),
                    rll, fn, lihe, srcflag])
    return out

def drive_update(token, file_id, path, dry):
    if dry:
        print(f"  (dry) drive update {os.path.basename(path)} -> {file_id}"); return True
    req = urllib.request.Request(
        f"https://www.googleapis.com/upload/drive/v3/files/{file_id}?uploadType=media",
        data=open(path, "rb").read(), method="PATCH",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "image/png"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status == 200

def drive_create(token, folder_id, name, path):
    """--init 전용 : multipart 업로드로 새 파일. fileId 를 돌려준다."""
    meta = json.dumps({"name": name, "parents": [folder_id]}).encode()
    png = open(path, "rb").read()
    B = b"rene_boundary_7f3a"
    body = (b"--" + B + b"\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n"
            + meta + b"\r\n--" + B + b"\r\nContent-Type: image/png\r\n\r\n"
            + png + b"\r\n--" + B + b"--")
    req = urllib.request.Request(
        "https://www.googleapis.com/upload/drive/v3/files"
        "?uploadType=multipart&fields=id",
        data=body, method="POST",
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": f"multipart/related; boundary={B.decode()}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)["id"]

HEADER = ["Run", "Start", "live/wall [h]", "Total", "Target only", "VETO only",
          "V+T", "IBD nGd", "acci nGd", "IBD nH", "acci nH", "R_LL [Hz]",
          "fast-n", "Li/He", "Source"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--params", required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--init", action="store_true")
    a = ap.parse_args()
    p = read_params(a.params)
    for k in ("sheet_id", "tsv_dir", "webroot"):
        if not p.get(k) and not (a.init and k == "sheet_id"):
            sys.exit(f"[FATAL] {a.params} 에 {k} 가 비어 있다")
    rows = build_rows(p)
    print(f"[INFO] 표 행 : {len(rows)} (출처 {p.get('metrics_source','legacy')})")
    if a.dry_run and not a.init:
        for r in rows[-3:]: print("  (dry) sheet row:", r)
        pngs = sorted(glob.glob(os.path.join(p["webroot"], "*.png")))
        fmap = read_map(p.get("map_file", ""))
        for n, fid in fmap.items():
            print(f"  (dry) drive update {n}.png -> {fid}")
        print(f"[DRY] 시트 {len(rows)} 행 후보, 그림 {len(fmap)}/{len(pngs)} 개 교체 예정")
        return
    creds = find_creds()
    if not creds: sys.exit("[FATAL] 서비스 계정 json 을 찾지 못했다")
    from google.oauth2.service_account import Credentials
    import google.auth.transport.requests, gspread
    cr = Credentials.from_service_account_file(creds, scopes=SCOPES)
    cr.refresh(google.auth.transport.requests.Request())
    if a.init:
        fmap = {}
        for f in sorted(glob.glob(os.path.join(p["webroot"], "*.png"))):
            n = os.path.splitext(os.path.basename(f))[0]
            fid = drive_create(cr.token, p["drive_folder_id"], n + ".png", f)
            fmap[n] = fid
            print(f"[INIT] {n}.png -> fileId {fid}")
            print(f"       퍼가기 URL : https://drive.google.com/thumbnail?id={fid}&sz=w1600")
        with open(p["map_file"], "w", encoding="utf-8") as fh:
            for n, fid in fmap.items(): fh.write(f"{n}\t{fid}\n")
        print(f"[INIT] {p['map_file']} 에 {len(fmap)}줄을 썼다")
        return
    ws = gspread.authorize(cr).open_by_key(p["sheet_id"]) \
               .get_worksheet_by_id(int(p.get("sheet_gid", "0")))
    grid = ws.get_all_values()
    bdir = "/Data_ssd/LOG/websummary"; os.makedirs(bdir, exist_ok=True)
    bak = os.path.join(bdir, time.strftime("sheet-backup-%Y%m%d%H%M%S.tsv"))
    with open(bak, "w", encoding="utf-8") as fh:
        for r in grid: fh.write("\t".join(r) + "\n")
    if not grid:
        ws.append_row(HEADER, value_input_option="RAW"); grid = [HEADER]
    have = {r[0] for r in grid[1:] if r and r[0].isdigit()}
    new = [[str(c) for c in r] for r in rows if str(r[0]) not in have]
    if new:
        ws.append_rows(new, value_input_option="RAW")
        back = ws.get_all_values()[-len(new):]
        if [r[:len(HEADER)] for r in back] != new:
            sys.exit("[FATAL] 되대조 실패 -- 시트에 쓴 것과 읽은 것이 다르다")
        print(f"[SHEET] {len(new)} 행 추가 + 되대조 통과 (백업 {bak})")
    else:
        print("[SHEET] 새 행 없음")
    fmap = read_map(p.get("map_file", ""))
    nup = 0
    for n, fid in fmap.items():
        f = os.path.join(p["webroot"], n + ".png")
        if os.path.isfile(f) and drive_update(cr.token, fid, f, False): nup += 1
    print(f"[DRIVE] {nup}/{len(fmap)} 개 교체")

def read_map(path):
    m = {}
    if path and os.path.isfile(path):
        for ln in open(path, encoding="utf-8"):
            if "\t" in ln:
                n, fid = ln.rstrip("\n").split("\t", 1); m[n] = fid
    return m
```

토큰: `google.oauth2.service_account.Credentials.from_service_account_file(
creds, scopes=SCOPES)` 후 `cr.refresh(google.auth.transport.requests.Request())`
→ `cr.token`. gspread 는 같은 creds 객체로 `gspread.authorize(cr)`.

`--init` 출력 형식 (사용자가 사이트에 붙일 것):

```
[INIT] rate_trend_candidates.png -> fileId 1AbC...
       퍼가기 URL : https://drive.google.com/thumbnail?id=1AbC...&sz=w1600
...
[INIT] config/websummary.map 에 11줄을 썼다
```

- [ ] **Step 2: --dry-run 시험** — `tests/monitor-publish.test.sh`: 픽스처
TSV/PNG/params(map 포함, 가짜 fileId)로 `--dry-run` 실행 → ① 네트워크 접근
없이 rc=0 ② 시트에 붙일 행 목록이 표와 같은 런들 ③ `(dry) drive update`
줄 수 == map 줄 수 ④ params 에 sheet_id 가 비면 명확한 에러. python3 만
있으면 돈다 (gspread import 는 dry-run 에선 시트 접근 전에만 — 없으면 SKIP).

Run: `bash tests/monitor-publish.test.sh`
Expected: `PASS monitor-publish (4/4)`

- [ ] **Step 3: Commit**

```bash
cd ~/DAQ/work-web && git add tools/monitor/publish_google.py config/websummary.params.example tests/monitor-publish.test.sh
git commit -m "feat: Google Sheets/Drive publisher for the run summary"
```

---

### Task 9: websummary.sh — 오케스트레이션 + cron

**Files:**
- Create: `tools/monitor/websummary.sh`
- Test: `tests/websummary.test.sh`
- Modify: crontab (구현 마지막 단계에서, 기존 백업 관례대로)

**Interfaces:**
- 사용법: `websummary.sh [--params config/websummary.params] [--dry-run] [--status] [--force]`
- 순서: 게이트(완결 런 목록) → run-summary.sh → dst-build.sh → metrics.sh
  (--verify 는 경고만) → ibd-summary.sh(legacy 원본 유지) → rate-trend.sh →
  gen-summary-html.sh → publish_google.py
- 상태 파일: `/Data_ssd/LOG/websummary.state` (`last_run=` 한 줄)
- 로그: `/Data_ssd/LOG/websummary.log`
- 잠금: `flock` + `WEBSUMMARY_LOCK` 로 갈아끼움 가능 (§11.150 의 교훈)

- [ ] **Step 1: 구현** (~180줄). 핵심 부분:

```bash
#!/usr/bin/env bash
# websummary.sh - 런 서머리 웹 발행 오케스트레이터. cron 매시 27분.
#   완결(FADC==PRD)된 새 런이 있을 때만 일한다. /scratch 가 없으면 조용히
#   물러난다 (감시·발행이 스스로 죽어 사고가 되지 않게 -- chainwatch 원칙).
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
MON=$DIR/tools/monitor
PARAMS=$DIR/config/websummary.params
DRY=0; FORCE=0
# ... 인자 파싱 (--params/--dry-run/--status/--force) ...
LOG=/Data_ssd/LOG/websummary.log
STATE=/Data_ssd/LOG/websummary.state
LOCK=${WEBSUMMARY_LOCK:-/tmp/websummary.lock}
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

exec 9>"$LOCK" || exit 0
flock -n 9 || { log "이미 돌고 있다. 물러난다"; exit 0; }

TSVDIR=$(getp tsv_dir /scratch/RunSummary)
mountpoint -q /scratch || { log "/scratch 가 없다. 이번 회차는 쉰다"; exit 0; }
[ -d "$TSVDIR" ] || { log "$TSVDIR 이 없다. 쉰다"; exit 0; }

# getp 는 Task 5 metrics.sh 와 같은 6줄 파서를 이 파일에도 둔다 (websummary.params 용)

# ---- 완결 게이트 : sheetlog-auto.sh 의 run_complete 와 같은 판정 ----
#      시험이 픽스처 트리를 끼울 수 있게 환경으로 뺀다
ROOTS=${WEBSUMMARY_ROOTS:-"/Data_ssd/RAW /data/RAW /scratch/RAW"}
run_complete() {
   local rr d f p
   rr=$1
   for d in $ROOTS; do
      [ -d "$d/$rr" ] || continue
      f=$(ls -U "$d/$rr"     2>/dev/null | grep -c "^FADC_$rr\.root\.")
      p=$(ls -U "$d/$rr/PRD" 2>/dev/null | grep -c '\.root$')
      [ "$f" -gt 0 ] && [ "$p" -eq "$f" ] && return 0
   done
   return 1
}
# start_run(params)~현재까지 훑어 '완결 && > last_run' 목록을 만든다.
# 후보가 없고 --force 도 아니면 log 없이 exit 0 (cron 이 시끄러우면 안 된다).
```

이후: `--dry-run` 이면 무엇을 할지 목록만 찍고 종료. 실행이면 단계 호출을
전부 `nice -n 15 ionice -c2 -n7` 로 감싸 수집·후처리를 방해하지 않게 하고
(`--list "$NEWLIST"` 전달), `metrics.sh --verify` 는 실패해도 log 경고만
(legacy 가 웹 출처인 동안은 발행을 막지 않는다), HTML 생성, `publish=1` 이면
publish_google.py, 성공 시 `last_run=` 갱신. 단계 실패는 log 남기고 exit 1
(상태 파일은 갱신하지 않아 다음 회차에 재시도).

- [ ] **Step 2: 시험** — `tests/websummary.test.sh` 6건: ① 완결 게이트
(가짜 RAW 트리: FADC 3 / PRD 3 → 통과, FADC 3 / PRD 2 → 제외 — ROOTS 를
픽스처로 치환할 수 있게 `WEBSUMMARY_ROOTS` 환경으로 빼 둔다) ② 새 런
없으면 조용히 exit 0 ③ `--dry-run` 이 상태 파일·웹 산출물을 안 바꿈
④ /scratch 없는 상황(mountpoint 를 PATH 앞의 가짜로 대체) → exit 0 ⑤ 잠금
겹침 → 둘째가 물러남 ⑥ `env -i bash tests/...` cron 환경.

Run: `bash tests/websummary.test.sh`
Expected: `PASS websummary (6/6)`

- [ ] **Step 3: cron 등록** (운영 PC 에서, 배포 후에 한다 — Task 10 체크리스트로 미룸)

```bash
crontab -l > ~/crontab.bak-$(date +%Y%m%d%H%M)
( crontab -l; echo '27 * * * * /home/frontend/DAQ/RENE-daq-rcterm/tools/monitor/websummary.sh >/dev/null 2>&1' ) | crontab -
```

- [ ] **Step 4: Commit**

```bash
cd ~/DAQ/work-web && git add tools/monitor/websummary.sh tests/websummary.test.sh
git commit -m "feat: web-summary orchestrator with completeness gate and cron guardrails"
```

---

### Task 10: 문서 + 통합 (사용자 작업 포함)

**Files:**
- Modify: `tools/monitor/README.md` (새 단계 4~5 절, DST=재생 가능 캐시 명시)
- Modify: `CLAUDE.md` (§11 세션 기록 + §11.142 '돌고 있는 것' 에 cron 추가,
  DST 백업 제외 명시)
- Modify: `.gitignore` (`config/websummary.params`, `config/websummary.map`,
  `config/monitorcuts.params` 확인·추가)

- [ ] **Step 1: 전체 시험 일괄 실행**

Run: `cd ~/DAQ/work-web && for t in tests/monitor-*.test.sh tests/websummary.test.sh; do echo "== $t"; bash "$t" || exit 1; done`
Expected: 전부 PASS (또는 사유 있는 SKIP)

- [ ] **Step 2: README.md 갱신** — 파이프라인 표를 5단계로, DST 스키마·비용
실측치(Task 3 Step 4 의 수치), metrics_summary 열 정의, 전환 게이트 사용법
(`metrics.sh --verify`), '예비' 물리량의 뜻과 레시피 확정 시 바꿀 자리
(monitorcuts.params) 를 적는다.

- [ ] **Step 3: CLAUDE.md 세션 기록** — 무엇을 왜 했는지 + 실측치 + DST 는
백업 대상이 아님 + cron 27분 항목. §11.142 의 '돌고 있는 것' 과 '상태 보는
법'(`websummary.sh --status`) 갱신.

- [ ] **Step 4: Commit + push 안내**

```bash
cd ~/DAQ/work-web && git add -A && git commit -m "docs: run-summary web monitor stages, schemas, and operations"
```

push 는 자격증명 캐시가 필요하므로 사용자에게 요청한다.

- [ ] **Step 5: 배포** — 운영 디렉터리에서 `git pull` (돌고 있는 것에 안전 —
git 은 새 inode 로 쓴다, §11.139 실측). cron 등록(Task 9 Step 3).

- [ ] **Step 6: 사용자 1회성 구글 작업 안내** (스펙 §7 의 4개) — 완료되면:

```bash
tools/monitor/publish_google.py --params config/websummary.params --init
tools/monitor/websummary.sh --dry-run     # 무엇이 발행될지 확인
tools/monitor/websummary.sh               # 첫 실발행
```

`--init` 출력의 퍼가기 URL 목록 + 시트 임베드 순서를 안내문으로 정리해
전달한다. 드라이브 썸네일 캐시 지연을 첫 갱신에서 실측해 문서에 적는다.

- [ ] **Step 7: 전환 판단 재료 정리** — `metrics.sh --verify` 결과(기준 런
2개)를 사용자에게 보고하고, 승인이 나면 `websummary.params` 의
`metrics_source = dst` 로 바꾼다. 승인 전엔 legacy 유지.
