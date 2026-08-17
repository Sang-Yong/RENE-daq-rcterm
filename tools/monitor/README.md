# DAQ 모니터링 요약 — livetime 부터 neutrino candidate 까지

단계마다 코드 하나, 스크립트 하나다. 순서가 있고, 앞 단계가 없어도 죽지는 않는다
(그 칸만 비고 나중에 다시 돌리면 채워진다).

| 순서 | 스크립트 | 매크로 | 내는 것 |
|---|---|---|---|
| 1 | `run-summary.sh` | `BuildRunSummary.C` | livetime, 종류별 이벤트 수 → `run_summary.{txt,tsv}` |
| 2 | `ibd-summary.sh` | `BuildPairSummary.C` | IBD 후보 수 (채널별) → `pair_summary.{txt,tsv}` |
| 3 | `rate-trend.sh` | `BuildRateTrend.C` | 효율 보정 + 시간축 추이 그림 → `rate_trend.{pdf,tsv}`, `*.png` |
| 전부 | `monitor-all.sh` | — | 위 셋을 순서대로. 자동화는 이것을 쓴다 |

```bash
tools/monitor/monitor-all.sh              # 한 번 (1→2→3)
tools/monitor/monitor-all.sh --follow     # 1시간마다 계속 갱신
tools/monitor/ibd-summary.sh --missing    # 페어링이 안 된 런을 찾아준다
```

**런이 하나 끝날 때마다 그림 오른쪽 끝에 점이 하나 붙는다.** x축은 그 런의 DAQ
시작 시각이고, 표가 누적되므로 다시 돌리기만 하면 추이가 계속 자란다. 지우고
새로 그리는 것이 아니다.

2단계 상세는 §6, 3단계는 §8 부터. 1단계는 바로 아래.

---

# 1단계 : run_summary — production 산출물(PRD)에서 뽑는 DAQ 운용 지표

**입력은 production 을 마친 데이터다.**

```
/scratch/RAW/<런번호>/PRD/PRD_<런번호>.<서브런>.root     TTree "Event"
      TCBTRGTime  [ns]  TCB 트리거 시각
      EventType   1 = target only(FADC) · 2 = veto only(SADC) · 3 = both
/scratch/RAW/<런번호>/FADC_<런번호>.root.<서브런>        수집 시각(mtime)
```

경로는 `RUNSUM_RAW`(기본 `/scratch/RAW`)로 바꾼다. **읽기만 한다.**

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

페어링 결과에서 IBD 후보 수를 채널별로 뽑는다. **여기서 페어링을 새로 하지
않는다.** `RunBothChannels.C` 가 만든 것을 읽기만 한다.

```
Step3/step3_Run<NNNNNN><tag>.root : T_Paired      coincidence 를 만족한 쌍
                                    T_Paired_Acci off-window 대조 표본
Step3/step4_Run<NNNNNN><tag>.root : T_IBD         + multiplicity(고립) 통과
                                    T_IBD_Acci
```

`tag` 는 `_nGd` / `_nH`. 없으면 `ibd-summary.sh --missing` 이 돌려야 할 명령을
알려 준다(그 코드는 `ojk` 계정 것이라 그쪽에서 돌려야 한다).

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

## 6.2 컷 상수는 복제하지 않는다

`DT_MIN` / `DT_MAX` / `S2` 창 / `ISO` 는 분석 쪽
`essential/AnalysisCondition.h` 를 **직접 include** 해서 쓴다. 베껴 두면 저쪽이
컷을 바꿨을 때 이 표만 조용히 틀린 값이 된다. 경로는 `RENE_COND` 환경변수
(또는 `-DRENE_COND_HEADER=`)로 바꾼다.

그래서 표에 찍히는 컷은 **문서가 아니라 코드에서 읽은 값**이다. 둘이 다를 수
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

선원 없는 런 5개(4084 · 4237~4240), livetime 29.8일 기준.

| 채널 | ibd | acci | cand | S/B | cand/day |
|---|---|---|---|---|---|
| `_nGd` | 6,262 | 4,069.9 | 2,192 ± 101 | 0.54 | **73.5 ± 3.4** |
| `_nH` | 1,989,144 | 1,822,510.7 | 166,633 ± 1,950 | 0.09 | 5,589 ± 65 |

**이 cand 는 개략값이다.** 우발만 뺀 것이고 검출 효율, 우주선 유발 배경
(fast neutron, ⁹Li/⁸He), 컷 효율 보정이 들어 있지 않다. 물리 결과가 아니라
**"수집이 정상이면 이만큼 나온다"는 운용 지표**로 볼 것. n-H 의 S/B 0.09 는
이 채널에서 추가 컷 없이는 정상이다.

---

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

## 8.2 R_LL 은 추정하지 않고 잰다 ★

`run_summary` 의 `n_clean / live` 를 R_LL 로 쓰고 싶어지지만 **틀린다.**
Step2 의 `T_Event` 에는 에너지 문턱이 없다(muon / after-muon / saturation 컷만).
실측 — run 4237 의 서브런 100 에서 `T_Event` 11,356 개 중 1.2 MeV 이상은
**5,740 개뿐**이었다. 그대로 쓰면 R_LL 이 두 배가 되고 ε_iso 가 낮아져
보정 rate 가 부풀려진다.

그래서 Step2 part 를 **서브런 20개쯤 표본으로 열어 직접 센다.** rate 라서
전수 조사가 필요 없다. 결과는 `rll.tsv` 에 캐시하므로 런당 한 번만 잰다.
다시 재려면 `--remeasure`.

## 8.3 지금 나오는 값 (선원 없는 런 4개)

```
run 4237  R_LL 95.03 Hz   eps_T 0.942  eps_iso 0.945  eps_tot 0.890
   _nGd   rate 83.1 -> 보정 93.3 /day        _nH  6008.7 -> 7842.8 /day
run 4240  R_LL 92.62 Hz
   _nGd   rate 53.0 -> 보정 59.5 /day        _nH  6740.4 -> 8763.8 /day
```

R_LL 이 92~95 Hz 로 안정적이라 ε_iso 도 0.945 근처에서 거의 변하지 않는다.

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

**페어링 자체는 돌리지 않는다.** `RunBothChannels.C` 는 `ojk` 계정의 코드라
그쪽에서 돌려야 한다. 빠진 런은 `ibd-summary.sh --missing` 이 명령까지 만들어
준다.

---

## 10. 지금 상태와 다음

- 실측 검증 완료 — 1단계는 run 4063 · 4084 · 4221~4234 · 4237~4240,
  2단계는 페어링된 13개 런 × 2채널 = 26행, 3단계는 선원 없는 런 4개의
  R_LL 측정과 7쪽 그림. monitor 경로 / Step1 대체 경로 / 이어붙이기 /
  건너뛰기 / 정렬 / 미분석 런 무시 / **되읽기 라운드트립** / R_LL 캐시를
  모두 확인했다.
- 하지 않은 것
  - `runcatalog.db` 의 `nfadc`/`tfadc`(DAQ 가 보고한 값) 대 `n_events`/`live`
    (데이터에서 나온 값) 대조. 나란히 놓으면 수집과 저장 사이의 손실이 보인다.
  - 병합 런(`step4_Run004237+004238_nGd.root` 같은 것)은 건너뛴다. 단일 런만 센다.
  - 시간에 따른 후보율 추이(그림). 지금은 표까지다.
