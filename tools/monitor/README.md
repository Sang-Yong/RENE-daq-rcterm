# DAQ 모니터링 요약 — livetime 부터 neutrino candidate 까지

단계마다 코드 하나, 스크립트 하나다. 순서가 있고, 앞 단계가 없어도 죽지는 않는다
(그 칸만 비고 나중에 다시 돌리면 채워진다).

| 순서 | 스크립트 | 매크로 | 내는 것 |
|---|---|---|---|
| 1 | `run-summary.sh` | `BuildRunSummary.C` | livetime, 종류별 이벤트 수 → `run_summary.{txt,tsv}` |
| 2 | `ibd-summary.sh` | `BuildPairSummary.C` | IBD 후보 수 (채널별) → `pair_summary.{txt,tsv}` |

```bash
tools/monitor/run-summary.sh          # 1단계
tools/monitor/ibd-summary.sh          # 2단계
tools/monitor/ibd-summary.sh --show   # 결과
tools/monitor/ibd-summary.sh --missing  # 페어링이 안 된 런을 찾아준다
```

2단계 상세는 이 문서 §6 부터. 1단계는 바로 아래.

---

# 1단계 : run_summary — production 을 마친 런의 DAQ 운용 지표

수집이 끝나고 병합·production 까지 지난 런에서 **livetime 과 종류별 이벤트 수**를
뽑아 하나의 표로 누적한다. rcterm 이 남기는 런 카탈로그(`runcatalog.db`)가
"DAQ 가 무엇을 했다고 보고했는가"라면, 이쪽은 **"실제로 데이터에 무엇이 남았는가"**다.

```
tools/monitor/run-summary.sh              새로 끝난 런을 전부 이어붙인다
tools/monitor/run-summary.sh 4237 4240    범위를 지정해서
tools/monitor/run-summary.sh --show       결과만 본다
tools/monitor/run-summary.sh --dry-run    무엇을 할지만 본다
```

산출물은 `/scratch/RunSummary/` 에 둘이 생긴다.

| 파일 | 쓰임 |
|---|---|
| `run_summary.txt` | 사람이 읽는 고정폭 표. 이것이 정본이다 |
| `run_summary.tsv` | 그림 그릴 때 쓰는 탭 구분 표. 이어붙이기도 이 파일을 되읽는다 |

---

## 1. 무엇을 읽는가 — 기존 분석 코드에 얹는다

물리 분석 코드는 `/home/ojk/analysis3` 에 있고 **그대로 쓴다. 복제하지 않는다**
(`docs/POSTRUN.md` 에서 production 매크로를 호출만 하는 것과 같은 이유다 —
복제하면 두 벌이 갈라진다).

```
AnalysisStep1.C(run)                 -> Step1/step1_Run<NNNNNN>.root   : T_LiveTime
BuildMonitorSummary.C+(run, run)     -> Monitor/monitor_Run<NNNNNN>.root : T_Monitor
RateMonitor.C("run")                 -> 그림 (PDF)
                                          |
                        run-summary.sh 는 여기의 T_Monitor 를 읽는다
```

- **1순위 `T_Monitor`** — 서브런별 `duration_sec`, `epoch`, `gap_sec`,
  `n_events` / `n_veto` / `n_target` / `n_both`, 그리고 Step2 의
  `n_clean` / `n_muon` / `n_aftermu` 까지 들어 있다.
- **2순위 `T_LiveTime`** — `monitor_Run*.root` 가 아직 없는 런은 이쪽으로
  집계한다. Step2 계수는 빠지고, 그 칸은 `-` 로 남는다.
  `BuildMonitorSummary.C+(run)` 를 먼저 돌리면 채워진다.

**입력은 읽기만 한다.** `SampleFiles` 는 `ojk` 계정 소유이고 이 도구는 거기에
아무것도 쓰지 않는다. 쓰는 곳은 `RUNSUM_OUT` 뿐이다.

경로를 바꾸려면 환경변수로 준다.

```bash
RUNSUM_OUT=/somewhere RUNSUM_SAMPLE=/other/SampleFiles tools/monitor/run-summary.sh
```

---

## 2. 무엇을 계산하는가

**livetime 의 정의는 `AnalysisStep1.C` 를 그대로 따른다.** 새로 만들지 않았다.

```
서브런 livetime = (T_State.end_time - start_time) * 1e-9      [TCB 시각, ns]
런   livetime   = 서브런 livetime 의 합
```

| 항목 | 뜻 |
|---|---|
| `DAQ start` | 첫 서브런의 원시 FADC 파일 mtime. **파일이 닫힌 시각에 가깝다** |
| `live[s]` | 위 정의의 합 |
| `span[s]` | 첫 서브런 시작부터 마지막 서브런 끝까지 (TCB 시각) |
| `duty` | `live / span`. 1 에 가까울수록 죽은 시간이 없다 |
| `dead[s]` | Σ max(다음 서브런까지의 간격 − livetime, 0) |

종류별 이벤트 수는 트리거 계수를 서브런에 걸쳐 누적하고, 파생값을 함께 낸다.

```
tgt_only  = target - both
veto_only = veto   - both
neither   = total - tgt_only - veto_only - both
```

`muon` 은 Step2 의 `T_Muon` 이며 **SADC veto 태그와 같은 것을 센다** —
실측으로 `veto` 열과 수가 정확히 일치한다(run 4237~4240). 별개의 물리량이
아니므로 둘을 더하지 말 것.

---

## 3. `cov` 열을 반드시 볼 것

계수가 없는 서브런이 섞여 있으면 **합만 보고는 '전부 더한 것'과 '있는 것만
더한 것'을 구분할 수 없다.** 그래서 각 계수마다 값이 있던 서브런의 비율을
`cov[%]` 로 함께 적는다.

- `cov = 100.0` — 런 전체를 덮은 합이다.
- `cov < 100.0` — **그만큼 과소평가된 합이다.** 합계 블록에도 경고가 붙는다.
- `cov = 0.0` — 그 계수가 아예 없다. 값은 `-` 로 나온다.

`0` 과 `-` 는 다르다. `0` 은 "0 이라고 기록됨", `-` 는 "기록이 없음"이다.
실제로 run 4237~4239 는 `target` 이 `0` 이고 `cov` 는 100 이다 — 누락이 아니라
그 production 에 표적 계수기가 없었다는 뜻이다.

---

## 4. 이어붙이기

이미 표에 있는 런은 건너뛴다. 그래서 몇 번을 돌려도 안전하고, 끝난 런이
생길 때마다 부르면 된다.

```bash
tools/monitor/run-summary.sh            # 새 런만 더한다
tools/monitor/run-summary.sh --force 4240   # 이미 있어도 다시 계산해 덮어쓴다
```

되읽기는 `run_summary.tsv` 로 한다(`txt` 는 표시용 서식이 섞여 있다).
**두 파일의 열 순서는 `WriteTsv()` 와 `LoadExisting()` 이 짝을 이룬다.**
열을 추가할 때는 반드시 양쪽을 함께 고칠 것.

---

## 5. `tsv` 에는 `-` 를 쓰지 않는다 ★고칠 때 주의

`txt` 에서 값이 없으면 `-` 로 찍지만, **`tsv` 에는 반드시 숫자(없으면 음수)를
쓴다.** 되읽기가 `>>` 로 파싱하기 때문에 `-` 를 만나면 그 행 전체가 조용히
버려진다. 실제로 그렇게 표가 15행에서 8행으로 줄고 run 4084 가 사라진 적이 있다.
`FmtF`(txt 용, `-` 를 낸다)와 `FmtRaw`(tsv 용, 항상 숫자)를 섞지 말 것.

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

## 7. 지금 상태와 다음

- 실측 검증 완료 — 1단계는 run 4063 · 4084 · 4221~4234 · 4237~4240,
  2단계는 페어링된 13개 런 × 2채널 = 26행. monitor 경로 / Step1 대체 경로 /
  이어붙이기 / 건너뛰기 / 정렬 / 미분석 런 무시 / **되읽기 라운드트립**을
  모두 확인했다.
- 아직 자동화하지 않았다. **수동 실행이다.** 동작을 지켜본 뒤 postrun /
  dataflow 처럼 tmux pane 에서 주기 실행으로 올리는 것이 다음 단계다.
- 하지 않은 것
  - `runcatalog.db` 의 `nfadc`/`tfadc`(DAQ 가 보고한 값) 대 `n_events`/`live`
    (데이터에서 나온 값) 대조. 나란히 놓으면 수집과 저장 사이의 손실이 보인다.
  - 병합 런(`step4_Run004237+004238_nGd.root` 같은 것)은 건너뛴다. 단일 런만 센다.
  - 시간에 따른 후보율 추이(그림). 지금은 표까지다.
