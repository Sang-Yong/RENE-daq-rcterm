# DAQ 모니터링 요약 — livetime 부터 neutrino candidate 까지

**세 단계 전부 production 산출물(PRD)만 읽는다.** 다른 계정의 분석 산출물에
기대지 않으므로, production 이 끝난 런은 곧바로 표에 들어온다.

```
<root>/RAW/<런번호>/PRD/PRD_<런번호>.<서브런>.root      ← 이것이 유일한 입력
root = /Data_ssd/RAW : /data/RAW : /scratch/RAW        앞에 오는 것이 이긴다
```

root 를 여럿 두는 이유는 두 가지다. dataflow 가 런을 `/Data_ssd → /data →
/scratch` 로 흘려보내므로 한 곳만 보면 옮겨진 런을 놓치고, **앞쪽이 압도적으로
빠르다** — 같은 서브런이 로컬 NVMe 1.1초, `/scratch` 14.6초다(100 Mb 링크,
CLAUDE.md §11.12). `RUNSUM_RAW` 로 바꾼다. **읽기만 한다.**

단계마다 코드 하나, 스크립트 하나다. 순서가 있고, 앞 단계가 없어도 죽지는 않는다
(그 칸만 비고 나중에 다시 돌리면 채워진다).

| 순서 | 스크립트 | 매크로 | 내는 것 |
|---|---|---|---|
| 1 | `run-summary.sh` | `BuildRunSummary.C` | livetime, 종류별 이벤트 수 → `run_summary.{txt,tsv}` |
| 2 | `ibd-summary.sh` | `BuildPairSummary.C` (+`RenePrdSingles.h`, `RenePairing.h`) | 페어링해서 IBD 후보 수·R_LL → `pair_summary.{txt,tsv}` |
| 3 | `rate-trend.sh` | `BuildRateTrend.C` | 효율 보정 + 시간축 추이 그림 → `rate_trend.{pdf,tsv}`, `*.png` |
| 전부 | `monitor-all.sh` | — | 위 셋을 순서대로. 자동화는 이것을 쓴다 |

```bash
tools/monitor/monitor-all.sh              # 한 번 (1→2→3)
tools/monitor/monitor-all.sh --follow     # 1시간마다 계속 갱신
tools/monitor/ibd-summary.sh --missing    # 아직 안 센 런을 알려준다
```

**런이 하나 끝날 때마다 그림 오른쪽 끝에 점이 하나 붙는다.** x축은 그 런의 DAQ
시작 시각이고, 표가 누적되므로 다시 돌리기만 하면 추이가 계속 자란다. 지우고
새로 그리는 것이 아니다.

2단계 상세는 §6, 3단계는 §8 부터. 1단계는 바로 아래.

---

# 1단계 : run_summary — production 산출물(PRD)에서 뽑는 DAQ 운용 지표

**입력은 production 을 마친 데이터다.** 파형은 읽지 않고 두 가지만 본다.

```
<root>/<런번호>/PRD/PRD_<런번호>.<서브런>.root     TTree "Event"
      TCBTRGTime  [ns]  TCB 트리거 시각
      EventType   1 = target only(FADC) · 2 = veto only(SADC) · 3 = both
<root>/<런번호>/FADC_<런번호>.root.<서브런>        수집 시각(mtime)
```

FADC 원시 파일은 **모든 root 에서 찾는다.** 예전 `--outroot` 구성은 RAW 가
`/scratch`, PRD 가 `/Data_ssd` 라 둘이 다른 디스크에 있다. 못 찾아 PRD mtime
으로 떨어지면 런마다 기준이 달라져 3단계 그림의 x축이 어긋난다.

## 1. EventType 의 뜻은 실측으로 확인했다

문서를 믿지 않고 트리거 플래그와 대조했다 (run 4237 서브런 101).

| EventType | 개수 | `F_Triggered>0` | `S_Triggered>0` |
|---|---|---|---|
| 1 | 10,918 | 10,918 | 9 |
| 2 | 51,738 | 1 | 51,738 |
| 3 | 381 | 378 | 377 |

따라서 `total = 1+2+3`, `target = 1+3`, `veto = 2+3`, `both = 3`.

## 2. TCBTRGTime 은 되감긴다 ★

TCB 시계는 약 **16.78초**(2²⁴×1000 ns)마다 0 으로 돌아간다. 60초 서브런 하나에
서너 번 감긴다. `AnalysisStep1.C` 가 쓰는 규칙을 그대로 따른다.

```
if (t < prev) offset += prev;        globalTime = t + offset
```

풀지 않으면 livetime 이 음수가 되거나 16초로 나온다. carry 는 **런 전체에
이어 간다** — 그래야 서브런 사이의 빈 시간까지 한 시간축에서 잰다.

```
livetime = Σ (서브런의 마지막 트리거 − 첫 트리거)
span     = 런의 첫 트리거 ~ 마지막 트리거
dead     = span − livetime          duty = livetime / span
```

## 3. TTree cycle 이 여러 개다 ★

PRD 파일에는 `Event;2`, `Event;3` 처럼 cycle 이 여럿 있다(생산 중 autosave).
`TFile::Get("Event")` 가 **가장 높은 cycle** 을 주고 그것이 완전한 것이다.
**cycle 을 더하면 이벤트를 두 번 센다.**

## 4. 기존 분석 체인과 일치한다 (검증)

같은 런을 두 경로로 계산해 대조했다.

```
PRD 직독     run 4234  subrun 61  live 2486.5 s  total 14,627,857
Step1 경유   run 4234  subrun 61  live 2486.5 s  total 14,627,857
```

## 4.1 속도 — 끊어서 따라잡는다

파형을 빼고 `TCBTRGTime`·`EventType` 두 가지만 읽지만, `/scratch` 가 100 Mb
링크라(CLAUDE.md §11.12) 서브런당 약 **1.3초**다.

| 런 크기 | 걸리는 시간 |
|---|---|
| 61 서브런 | 약 80초 |
| 1,440 서브런 (24시간 런) | 약 30분 |
| 12,720 서브런 | 몇 시간 |

그래서 `--newest N` 으로 한 번에 처리할 런 수를 끊는다. `monitor-all.sh` 는
기본 2개다. 끊지 않으면 첫 실행이 며칠 물린다(지금 PRD 가 있는 런이 1,406개).
런 하나가 끝날 때마다 파일을 쓰므로 중간에 끊겨도 한 것은 남는다.

대상 런 찾기는 `/scratch/RAW/<6자리>/PRD` 디렉터리 존재로만 판단한다(약 40초).
안에 파일이 있는지까지 확인하면 NFS 왕복이 배로 든다.

## 5. `tsv` 에는 `-` 를 쓰지 않는다 ★고칠 때 주의

`txt` 에서 값이 없으면 `-` 로 찍지만, **`tsv` 에는 반드시 숫자(없으면 음수)를
쓴다.** 되읽기가 `>>` 로 파싱하기 때문에 `-` 를 만나면 그 행 전체가 조용히
버려진다. 실제로 그렇게 표가 15행에서 8행으로 줄고 run 4084 가 사라진 적이 있다.
`FmtF`(txt 용, `-` 를 낸다)와 `FmtRaw`(tsv 용, 항상 숫자)를 섞지 말 것.

`run_summary.tsv` 첫머리에 `# schema <N>` 이 있다. 열 구성이 바뀌면 이 번호를
올리고, 옛 파일은 **조용히 잘못 읽지 말고 거부한다**. 2·3단계가 이 열 순서를
그대로 읽으므로(`live_s` 자리가 어긋나면 `span_s` 를 livetime 으로 쓰게 된다)
`WriteTsv` 를 고칠 때 `BuildPairSummary.C` · `BuildRateTrend.C` 도 함께 볼 것.

---

# 6단계 : pair_summary — neutrino candidate (개략)

**★ 2026-08-18 에 입력이 바뀌었다.** 예전에는 분석 쪽
`/scratch/junkyo/SampleFiles/Step3` 의 페어링 산출물을 읽기만 했다. 그러면
저쪽이 그 런을 아직 안 돌렸을 때 이 표가 멈춘다 — 실제로 1단계가 run 4291 까지
갔는데 2단계는 4240 에서 멎어 있었다. 이제 **1단계와 똑같이 PRD 를 읽고
페어링까지 여기서 한다.**

```
PRD ──► clean single ──► 페어링 ──► IBD 후보 수 + R_LL
     RenePrdSingles.h   RenePairing.h
     (= 분석 Step1+Step2) (= 분석 Step3+Step4)
```

## 6.0 물리는 베끼지 않는다. 분석 코드를 include 한다

파형 → NPE 변환, 보정 상수, 컷 값은 전부 분석 쪽 것을 그대로 쓴다.

```c
#include "/home/ojk/analysis3/essential/helper_functions.cc"   // GetPed/GetQsum/…
#include "/home/ojk/analysis3/essential/AnalysisCondition.h"   // DT_*/S2_*/ISO_*
```

베껴 두면 저쪽이 바꿨을 때 이 표만 조용히 틀린 값이 된다(§5.8 에서 production
매크로를 호출만 한 것과 같은 이유다). 경로는 `RENE_ANA_HELPERS` /
`RENE_COND_HEADER` 로 바꾼다.

**예외는 페어링 loop 하나뿐이다.** 분석 쪽 `RunBothChannels.C::PairAndSelect`
는 결과를 파일로 쓰는 것이 목적이라 **세기만 하는 진입점이 없다.** 그래서
`RenePairing.h` 에 loop 을 따로 두었고, 그만큼 갈라질 수 있다. 그래서
`ibd-summary.sh` 는 분석 Step4 가 있는 런에서 **매번 수를 대조하고** 다르면
알린다.

## 6.0.1 재현하는 규칙 (분석 Step1/Step2 그대로)

1. `globalTime = TCBTRGTime + offset`. TCB 시계가 되감기면 보정하고, carry 는
   **런 전체에 이어 간다** — 서브런마다 0 부터 다시 세면 서브런 경계를 넘는
   coincidence 창이 깨진다.
2. muon veto : SADC 패널 15개 중 위/아래가 함께 켜진 것이 있으면 veto.
   **`muonTime` 갱신이 `dt` 계산보다 먼저다.**
3. FADC ch0·ch1 파형을 적분해 NPE 를 얻는다.
4. Step2 컷을 **이 순서로** — muon → after-muon(`dt < 150 us`) → saturation.
   순서를 바꾸면 범주별 수가 달라진다.
5. `(q0<5 && q1<5)` 를 버리고 `q0+q1 > 610.6 NPE`(1.2 MeV) 인 것만 single 로
   남긴다. **`float` 로 깎아서 비교한다** — Step2 가 float 로 저장하므로
   그렇게 하지 않으면 경계에 걸친 이벤트에서 결과가 갈린다.

## 6.0.2 검증 — 분석 체인과 수가 정확히 맞는다 ★

두 토막으로 나눠 실측했다. 나누지 않으면 어디가 틀렸는지 알 수 없다.

**(A) 재구성** — run 4237 서브런 98~100 을 순서대로 돌려 carry 를 세운 뒤,
서브런 100 을 같은 서브런의 분석 Step2 part 와 대조했다.

```
single 개수   here 5,739   analysis 5,739     일치
evt_id 어긋남  0
pe 어긋남      0        (최대 0 NPE)
간격 어긋남    0        (최대 0 us)
```

**single 목록이 비트 단위로 같다.** clean 11,356 개도 예전에 기록해 둔 값과
같다.

**(B) 페어링** — 분석 Step2 에서 읽은 **같은 입력**(run 4237 전체, single
72,658,494 개)에 `RenePairing.h` 를 돌려 Step3/Step4 트리와 대조했다.

| | `_nGd` here / analysis | `_nH` here / analysis |
|---|---|---|
| paired | 7,879 / 7,879 | 798,857 / 798,857 |
| paired_acci | 3,023 / 3,023 | 664,641 / 664,641 |
| ibd | 2,097 / 2,097 | 601,739 / 601,739 |
| ibd_acci | 1,377 / 1,377 | 551,422 / 551,422 |

**여덟 개 전부 일치.** (A)+(B) 로 PRD → single → 후보 전 구간이 분석 체인과
같은 값을 낸다는 것이 확인됐다.

## 6.0.3 비용과 캐시 ★ 여기가 실무에서 제일 중요하다

파형을 읽으므로 1단계보다 훨씬 비싸다. **어느 디스크에 있느냐가 13배를 가른다.**

| 위치 | 서브런당 | 24시간 런(1440) | 병목 |
|---|---|---|---|
| `/Data_ssd` (로컬 NVMe) | **1.1초** | 약 27분 | CPU |
| `/scratch` (100 Mb NFS) | 14.6초 | 약 5.8시간 | 링크 |

그래서 **런이 아직 `/Data_ssd` 에 있을 때 돌리는 것이 압도적으로 유리하다.**
dataflow 가 `/scratch` 로 보내고 나면 13배가 된다.

서브런마다 single 목록을 캐시한다(`<OUT>/cache/singles`). 실측 —

```
run 4290 (197 서브런)  처음 228초  →  캐시 재사용 0.7초   (수는 동일)
캐시 크기 14 MB (서브런당 71 KB).  24시간 런이면 약 100 MB
```

중간에 끊겨도 한 것은 남고, 런 하나가 끝날 때마다 표를 쓴다. 캐시에는 그때 쓴
문턱과 veto 창을 함께 적어 두고, 값이 바뀌면 무시하고 다시 만든다.

자동화에서는 `--newest N` 으로 끊는다(`monitor-all.sh` 기본 2개). 끊지 않으면
PRD 가 있는 런이 1,400개가 넘어 첫 실행이 며칠 물린다.

## 6.1 우발 빼기 — `DrawIBD.C` 규약을 그대로 따른다

on-time 창은 `dt ∈ [DT_MIN, DT_MAX]` 라 폭이 `DT_MAX − DT_MIN` 인데,
off-time 창은 `[DT_ACCI, DT_ACCI + DT_MAX]` 라 폭이 `DT_MAX` 다. **두 폭이
같지 않다.** 그래서 폭 비율로 맞춘 뒤 뺀다.

```
acciScale   = (DT_MAX − DT_MIN) / DT_MAX        n-Gd 0.99 · n-H 0.995
N_candidate = N_IBD − acciScale × N_IBD_Acci
err         = sqrt(N_IBD + acciScale² × N_IBD_Acci)      통계 오차만
```

배율을 1 로 두면 우발을 과하게 빼서 후보가 낮게 나온다.
`DrawIBD.C:164` 의 `h_dt_sub->Add(h_dt_on, h_dt_acci, 1.0, -acciScale)` 와
같은 양을 세는 것이 목적이므로, **규약을 바꾸려면 그쪽과 함께 바꿀 것.**

## 6.2 컷 상수는 복제하지 않는다 (§6.0 참조)

표에 찍히는 컷은 **문서가 아니라 코드에서 읽은 값**이다. 그래서 표에 찍히는 컷은 **문서가 아니라 코드에서 읽은 값**이다. 둘이 다를 수
있다 — `README_pipeline.md` 는 n-Gd S2 를 `[7.77, 9.36]` 이라 적었지만
코드에서 그 줄은 주석이고 실제로는 **`[6.0, 10.0]`** 이 쓰인다(2026-08-18 확인).

## 6.3 선원 런을 반드시 구분한다 ★

AmBe · Cf252 를 넣고 받은 교정 런은 **후보 수가 백만 단위로 나온다.** 선원이
만든 중성자이지 neutrino 가 아니다. 구분하지 않으면 합계가 통째로 무의미해진다.

`ibd-summary.sh` 가 런 카탈로그(`runcatalog.db`)의 `rundesc` 에서 선원 이름을
뽑아 `runtype.tsv` 를 만들고, 매크로가 그것을 붙인다.

- `src = none` — 선원 없음. **채널별 합계는 이것만 더한다.**
- `src = AmBe` / `Cf252` / … — 교정 런. 표에는 남기되 합계에서 뺀다.
- `src = ?` — 카탈로그에 없거나 설명에서 못 읽었다. 안전하게 합계에서 뺀다.

실측 예 (같은 n-Gd 채널인데 자릿수가 다르다) :

```
4224  _nGd  AmBe     ibd 847,911   acci 3,095.7   cand 844,815.3   S/B 272.90
4237  _nGd  none     ibd   2,097   acci 1,363.2   cand     733.8   S/B   0.54
```

## 6.4 지금 나오는 값

**입력이 바뀌면서 표를 처음부터 다시 만들고 있다.** 옛 표(분석 Step3/Step4 를
읽던 것)는 열이 달라 `# schema 2` 검사에 걸려 자동으로 버려진다. 옛 값은
`/scratch/RunSummary/old-schema1/` 에 남겨 두었다.

```
run 4290  서브런 197  live 11,820 s  single 1,047,623  R_LL 88.63 Hz   [228 s]
   _nGd   paired 103     ibd 26      acci 10.9      cand 15.1 ± 6.1
   _nH    paired 9,490   ibd 8,019   acci 7,494.3   cand 524.7 ± 124.4
run 4291  서브런 865  live 51,900 s  single 4,607,001  R_LL 88.77 Hz  [1,019 s]
   _nGd   paired 478     ibd 153     acci 99.0      cand 54.0 ± 15.8
   _nH    paired 40,997  ibd 34,787  acci 32,929.5  cand 1,857.5 ± 259.9
```

**옛 표와도 맞는다.** Part B 에서 나온 run 4237 `_nGd` 의 `ibd 2,097` /
`ibd_acci 1,377` 은 옛 표의 `ibd 2,097` · `acci 1,363.2` · `cand 733.8` 과
그대로 이어진다(`acci = 0.99 x 1,377`). 입력을 바꿨어도 **같은 런이면 같은 행**이
나온다는 뜻이다.

**깨진 서브런은 조용히 넘기지 않는다.** run 4291 은 서브런 866 을 읽지 못했다고
알린다 — 그 런이 쓰기 도중에 끊겨 마지막 파일이 잘려 있기 때문이다(§11.17).
1단계도 같은 서브런을 `읽지 못한 서브런 1 개`로 표시한다. **두 도구가 독립적으로
같은 곳을 짚었다.**

livetime 도 두 단계가 맞는다 — 4291 이 1단계 `51,899.941 s`, 2단계 `51,899.9 s`.

되채우는 순서는 **최신 런부터**다. 옛 런은 PRD 가 `/scratch` 에 있어 13배
비싸고(§6.0.3), run 4237 처럼 12,720 서브런짜리는 51시간이 걸린다. 급하지 않다.

**이 cand 는 개략값이다.** 우발만 뺀 것이고 검출 효율, 우주선 유발 배경
(fast neutron, ⁹Li/⁸He), 컷 효율 보정이 들어 있지 않다. 물리 결과가 아니라
**"수집이 정상이면 이만큼 나온다"는 운용 지표**로 볼 것. n-H 의 S/B 가 0.1
언저리인 것은 이 채널에서 추가 컷 없이는 정상이다.

# 8단계 : rate_trend — 시간축 추이와 효율 보정

`rate-trend.sh` 가 `pair_summary` 를 읽어 **시각을 x축으로** 그린다. 쪽마다
PNG 도 하나씩 나오므로 화면에 띄워 두기 좋다.

| 쪽 | PNG | 내용 |
|---|---|---|
| 1 | `rate_trend_candidates.png` | 런당 IBD 후보 수 (우발 뺀 값) |
| 2 | `rate_trend_rate_raw.png` | 보정 전 rate [/day] |
| 3 | `rate_trend_rate_corrected.png` | **효율 보정 rate [/day]** ← 핵심 |
| 4 | `rate_trend_efficiency.png` | ε_iso, ε_tot 추이 |
| 5 | `rate_trend_accidental.png` | 우발 [/day] |
| 6 | `rate_trend_rll.png` | R_LL — ε_iso 가 흔들리면 여기가 원인이다 |
| 7 | `rate_trend_cumulative.png` | 누적 후보 수 |

두 채널의 크기가 100배쯤 달라서 후보 수·rate 쪽은 **로그축**이다. 선형축이면
n-Gd 이 바닥에 깔려 보이지 않는다.

## 8.1 효율 — 분석 쪽 정의를 그대로 쓴다

```
eps_T   = exp(-DT_MIN/tau) - exp(-DT_MAX/tau)        diagnostics/EffCutFlow.C:86
          포획시간 tau : n-Gd 25 us, n-H 171 us       같은 파일 :85
eps_iso = exp(-R_LL x (ISO_PRE + ISO_POST))          diagnostics/IsolationEfficiency.C:62
          R_LL = 1.2 MeV 이상 clean single 의 rate

rate_corr = rate_raw / (eps_T x eps_iso x eps_E)
```

**ε_E(에너지창)는 자동으로 구할 수 없다.** 봉우리 fit 이 필요해 사람이 봐야
한다. 기본 1.0 이고 보정에서 **빠져 있다.** 값을 알면 넣어 줄 수 있다.

```bash
tools/monitor/rate-trend.sh --eps-e 0.85
```

## 8.2 R_LL 은 2단계가 전수로 준다 ★

`run_summary` 의 `n_clean / live` 를 R_LL 로 쓰고 싶어지지만 **틀린다.**
clean 이벤트에는 에너지 문턱이 없다(muon / after-muon / saturation 컷만).
실측 — run 4237 서브런 100 에서 clean 11,356 개 중 1.2 MeV 이상은
**5,739 개뿐**이다. 그대로 쓰면 R_LL 이 두 배가 되고 ε_iso 가 낮아져
보정 rate 가 부풀려진다.

예전에는 여기서 분석 Step2 part 를 서브런 20개쯤 **표본으로** 열어 쟀다.
이제 2단계가 PRD 에서 런 전체의 single 을 이미 세므로 `pair_summary.tsv` 의
`r_ll` 열을 그대로 읽는다 — **표본이 아니라 전수**이고, `/scratch/junkyo` 에
기대지 않는다. `rll.tsv` 는 더 이상 만들지 않는다(옛 파일이 있으면 `r_ll` 이
비어 있는 행에만 예비로 쓴다).

다시 재려면 2단계를 다시 돌린다 : `ibd-summary.sh --force <런>`.

## 8.3 지금 나오는 값

```
run 4290  R_LL 88.63 Hz  eps_T 0.942  eps_iso 0.948  eps_tot 0.894
   _nGd  rate 110.4 -> 보정 123.6 ± 49.6 /day
run 4291  R_LL 88.77 Hz  eps_T 0.942  eps_iso 0.948  eps_tot 0.894
   _nGd  rate  89.9 -> 보정 100.6 ± 29.5 /day
```

R_LL 이 지금까지 잰 런에서 88~95 Hz 로 안정적이라 ε_iso 도 0.948 근처에서
거의 변하지 않는다. 4290 은 livetime 이 3.3시간뿐이라 오차가 크다.

## 9. 자동화

`monitor-all.sh --follow` 가 세 단계를 주기적으로 돈다(기본 1시간). 각 단계가
이미 처리한 런을 건너뛰므로 몇 번을 돌려도 안전하다.

```bash
# tmux 새 창으로 (기존 화면 배치는 건드리지 않는다)
tmux new-window -t daq -n monitor 'tools/monitor/monitor-all.sh --follow'

# cron 이면 ROOT 환경을 먼저 잡아야 한다
0 * * * * . /usr/local/bin/thisroot.sh; \
          /home/frontend/DAQ/RENE-daq-rcterm/tools/monitor/monitor-all.sh --quiet
```

한 바퀴가 끝날 때마다 채널별 **가장 최근 점**을 한 줄로 찍는다. 그것만 봐도
수집이 정상인지 감이 온다.

**페어링을 이제 여기서 한다.** 다른 계정의 산출물을 기다리지 않으므로
production 이 끝난 런은 곧바로 표에 들어온다. 아직 안 센 런은
`ibd-summary.sh --missing` 이 알려 준다.

2단계가 1단계보다 비싸므로 `--newest` 는 **두 단계 모두에** 적용된다.

---

## 10. 지금 상태와 다음

- **입력을 PRD 로 일원화했다(2026-08-18).** 세 단계 모두 다른 계정의 분석
  산출물 없이 돈다. 검증은 §6.0.2 — 재구성은 single 목록이 비트 단위로 같고,
  페어링은 여덟 개 수가 전부 일치한다.
- 표는 다시 채우는 중이다. 최신 런부터, `/Data_ssd` 에 있는 동안 돌리는 것이
  13배 싸다(§6.0.3).
- 하지 않은 것
  - `runcatalog.db` 의 `nfadc`/`tfadc`(DAQ 가 보고한 값) 대 `n_events`/`live`
    (데이터에서 나온 값) 대조. 나란히 놓으면 수집과 저장 사이의 손실이 보인다.
  - ε_E(에너지창 효율). 봉우리 fit 이 필요해 자동으로 못 구한다. 기본 1.0 이고
    보정에서 빠져 있다.
  - 병합 런은 다루지 않는다. 단일 런만 센다.
  - 페어링 loop 은 분석 쪽에 세기 전용 진입점이 없어 따로 두었다. 저쪽이
    `RunBothChannels.C` 를 고치면 여기도 고쳐야 한다 — 대조가 알려 준다.
