# run_summary — production 을 마친 런의 DAQ 운용 지표

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

## 5. 지금 상태와 다음

- 실측 검증 완료 — run 4063 · 4084 · 4221~4234 · 4237~4240 으로
  monitor 경로, Step1 대체 경로, 이어붙이기, 건너뛰기, 정렬을 모두 확인했다.
- 아직 자동화하지 않았다. **수동 실행이다.** 동작을 지켜본 뒤 postrun /
  dataflow 처럼 tmux pane 에서 주기 실행으로 올리는 것이 다음 단계다.
- 하지 않은 것 : rcterm 의 `runcatalog.db` 와 대조. DB 의 `nfadc` / `tfadc` 는
  DAQ 가 보고한 값이고 여기 `n_events` / `live` 는 데이터에서 나온 값이라,
  둘을 나란히 놓으면 **수집과 저장 사이의 손실**이 보인다. 해 볼 가치가 있다.
