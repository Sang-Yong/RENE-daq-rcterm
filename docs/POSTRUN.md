# 후처리 파이프라인 (merge + production)

DAQ 수집 뒤에 붙는 단계다. `scripts/postrun.sh` 가 드라이버이고,
실제 물리 코드는 `DAQ_cup/production` 의 것을 **그대로 호출한다.**
매크로를 이 저장소로 복제하지 않는다 — 복제하면 두 벌이 갈라진다.

---

## 1. 데이터 흐름

```
FADC_%06d.root.%05d   (타겟, 서브런당 ~70 MB)  ┐
                                              ├─ merge_FADC_SADC_v3_5v.cc
SADC_%06d.root.%05d   (VETO,  서브런당 ~8 MB) ┘        │
                                                       ↓
                              Merged/MERGED_%06d.root.%05d   (~80 MB)
                              PNG/merge_..._run%d_subrun%d.png   (QC 캔버스)
                                                       │
                                production_from_merged_v3_5v.cc
                                                       ↓
                              PRD/PRD_%06d.%05d.root          (~77 MB)
                              PRD/Run%06d_DLY_THR.log
```

- `merge` 는 FADC 와 SADC 를 **트리거 번호**로 맞춘다. 어긋남이 1000 을 넘으면
  선형 탐색 대신 이진 탐색으로 점프하고, 32비트 트리거 번호 오버플로우도 접는다.
  TCB 시간차 히스토그램과 누락 매트릭스를 PNG 로 남긴다.
- `production` 은 파형에 채널별 문턱값을 적용해 PRD 트리를 만든다.
  v3.5v 에서 IBD 반동시계수용 `S_VETO_DeltaT` 브랜치가 추가됐다.
  문턱값과 딜레이는 `LOG/TCB_%06d.log` 의 `WJ` 줄에서 읽는다.

**성공 판정은 2단계(2PC)다.** 둘 다 있어야 그 서브런이 끝난 것이다.

| 로그 | 있어야 하는 문자열 |
|---|---|
| `log_merge_FADC_SADC_v3_5v_run<N>_subrun<M>.txt` | `final before_SADC_trgnum` |
| `log_production_v3_5v_run<N>_subrun<M>.txt` | `SUCCESS` |

`postrun.sh` 는 이 판정과 로그 파일명을 원본과 **동일하게** 쓴다.
따라서 `production/Shell/audit_run.sh` 가 이 결과에도 그대로 동작한다.

---

## 2. 성능 — 왜 production 만 병렬화하는가

run 4238 / 4239 / 4240 의 서브런 로그 **33,357 개**를 실측했다.

| 단계 | 소요 | 병렬화 |
|---|---|---|
| merge | **28 초** | ✗ 불가 |
| production | **15 초** | ✓ 가능 |
| 합계 | **43 초** | |

서브런 1개는 **60초 분량**이다. 직렬로 돌려도 여유가 28% 있다.
그런데 이 여유는 얇다 — run 4287 을 처리한 구간에서는 다른 작업과 경합해
**86초**까지 늘어져 실시간의 1.4배로 뒤처지는 것을 실측했다.

**merge 를 병렬화할 수 없는 이유**: 매크로가 서브런을 끝낼 때
`final SADC` / `final SADC_evt` / `final before_SADC_trgnum` 을 찍는데,
이것이 다음 서브런의 SADC 시작 위치다. FADC 와 SADC 는 서브런 경계가
어긋나므로(파일이 통째로 날아가면 수만 트리거가 벌어진다) 이 상태를
넘겨받지 않으면 경계에서 이벤트를 잃는다.

**production 은 서브런마다 완전히 독립**이다 (`MERGED_N` → `PRD_N`).
그래서 병렬로 뺀다. 임계경로가 merge 28초로 내려가 여유가 2.1배가 된다.

```
직렬   : [merge 28][prod 15][merge 28][prod 15]      43초/서브런
병렬화 : [merge 28][merge 28][merge 28]              28초/서브런
              └prod┘   └prod┘   └prod┘  (동시 3개)
```

**용량** — 서브런당 RAW 78 MB + Merged 80 MB + PRD 77 MB = 235 MB.
24시간 런(1440 서브런)이면 **약 334 GB/일**. `/scratch` 여유 16 TB 기준 약 48일치다.
보관 정책이 필요하다.

### 병목은 CPU 가 아니라 NFS I/O 다

가동 중 실측: **iowait 26~34%, CPU 유휴 61~88%.** ROOT 프로세스도 17~29% CPU 에
머문다. 즉 코어를 더 쓴다고 빨라지지 않는다. `--jobs` 를 3~4 이상 올려도
효과가 없고, NFS 동시 스트림만 늘어 DAQ 쓰기와 경합한다.

**산출물을 로컬 디스크로 빼면 눈에 띄게 빨라진다.** run 4288 에서 실측:

| 산출물 위치 | 서브런당 | 표본 |
|---|---|---|
| `/scratch` (NFS) | **41.0 초** | n=21 |
| `/Data_ssd` (로컬 NVMe) | **27.7 초** | n=15 |

RAW 읽기는 여전히 NFS 이므로 iowait 이 0 이 되지는 않지만(24% 수준),
쓰기 절반이 로컬로 빠지면서 서브런당 13.3초를 벌었다.
60초 분량 대비 여유가 **1.5배 → 2.1배**로 늘어난다.

`--outroot` 를 주면 `Merged` / `PRD` 를 그쪽에 만들고 RAW 디렉터리에는
심볼릭 링크를 건다. 매크로는 `$DataDir/Merged/...` 를 그대로 쓰므로
**물리 코드도 기존 도구도 고칠 필요가 없다.**

```bash
scripts/postrun.sh --follow --outroot /Data_ssd/RAW
```

이미 실제 디렉터리가 있는 런은 스스로 옮기지 않고 경고만 한다.
데이터를 임의로 움직이지 않기 위해서다. 손으로 옮기려면:

```bash
mv /scratch/RAW/004288/Merged /Data_ssd/RAW/004288/Merged
mv /scratch/RAW/004288/PRD    /Data_ssd/RAW/004288/PRD
ln -s /Data_ssd/RAW/004288/Merged /scratch/RAW/004288/Merged
ln -s /Data_ssd/RAW/004288/PRD    /scratch/RAW/004288/PRD
```

**주의** — `/Data_ssd` 는 3.7 TB 중 2.0 TB 여유다. 24시간 런 1회가 산출물로만
약 226 GB 를 쓰므로 **약 9일치**밖에 안 된다. `/scratch` 보다 훨씬 빡빡하다.
로컬에 두고 쓰다가 주기적으로 NFS 로 옮기거나 지우는 운용이 필요하다.

---

## 3. 추적 모드 — 수집을 뒤따라간다

24시간 런은 서브런이 1440개다. 런이 끝난 뒤 몰아서 처리하면
**17시간짜리 후처리**가 매일 쌓인다. 그래서 수집 중에 뒤따라가며 처리한다.

안전선은 **rcterm heartbeat** 에서 얻는다. 실측으로 확인한 대응 관계:

```
heartbeat 의 subrun=829  ==  지금 기록 중인 파일 FADC_004288.root.00829
따라서 완료된 서브런은 0 .. 828
```

`--lag N`(기본 **3**) 만큼 더 물러나 처리한다. 서브런 1개가 1분이므로
**실시간 수집보다 약 3분 뒤를 따라간다.**

```
subrun 845  기록 중        <- 아직 안 닫힌 파일. 절대 건드리지 않는다
subrun 844  완료           ┐
subrun 843  완료           ┘ lag 여유 (flush / 시계 오차 흡수)
subrun 842  ─────> 처리 상한 = subrun - 3
```

3분을 두는 이유는 세 가지다.

1. heartbeat 의 `subrun` 은 **지금 기록 중인** 파일이다. 아직 닫히지 않았다.
2. **NFS 서버 시계가 로컬보다 약 28초 앞선다**(실측). mtime 만으로 완료를
   판정할 수 없다.
3. DAQ 가 파일을 닫고 flush 하는 데 시간이 걸린다. 덜 쓰인 파일을 열면
   merge 매크로가 Zombie 로 판정해 재시도에 들어간다.

여유를 줄이려면 `--lag 2` 처럼 낮출 수 있지만, 좀비 판정이 늘면 재시도로
오히려 느려진다. 처리가 실시간을 못 따라가는 상황이면 `--lag` 를 줄이는 것보다
출력을 로컬 디스크로 옮기는 편이 효과가 크다(§2 참조).

런이 넘어가면(heartbeat 의 run 이 바뀌면) 이전 런을 **끝까지** 처리한 뒤
새 런으로 넘어간다. heartbeat 가 120초 이상 갱신되지 않으면 수집이 끝난
것으로 보고 남은 서브런을 마저 처리한다.

---

## 4. 원본 스크립트에서 고친 것

`merge_FADC_SADC_v3_5v.sh` 는 손으로 돌리기 위한 도구다. 자동화하려면
아래가 걸린다. **원본은 수정하지 않았다** — `postrun.sh` 가 대신 처리한다.

| # | 원본 | postrun.sh |
|---|---|---|
| 1 | `read run` + 메뉴 1~4 + 스킵 목록. 완전 대화형 | 인자와 heartbeat 로 결정 |
| 2 | 재개 지점을 **이진 탐색**(91~110행). 중간에 실패한 서브런이 있으면 단조성이 깨져 엉뚱한 곳에서 재개 | 앞에서부터 선형으로 훑는다. stat 뿐이라 충분히 빠르고, 구멍이 있어도 정확하다 |
| 3 | `Run<run>_DLY_THR.log` 를 `if [ ! -f ]` 검사 후 생성. **병렬화하면 레이스** | 구간 시작 전에 한 번만 만든다 |
| 4 | 좀비 파일에 `sleep 1m` × 5회 = 5분 낭비 | `--max-retry`(기본 2회, 10초) |
| 5 | `pwd` 상대 경로. 다른 곳에서 실행하면 조용히 어긋남 | 절대 경로로 고정, 시작 시 검사 |
| 6 | FADC/SADC 개수 불일치는 경고만 | 동일 (경고). 물리 판단이라 임의로 막지 않는다 |
| 7 | 우선순위 조정 없음 | `nice`(기본 10)로 수집을 방해하지 않는다 |

**고치지 않은 것** — `maxsubrun = FADC 개수 - 1` 은 서브런이 0부터 연속이라고
가정한다. 중간 파일이 없으면 전체가 밀린다. 원본과 동일하게 두었다.
이 가정이 깨지는 상황은 DAQ 쪽 문제이므로 후처리에서 감추면 안 된다.

---

## 5. 사용법

```bash
# 지금 무엇을 처리할지만 확인 (아무것도 건드리지 않는다)
scripts/postrun.sh --once --dry-run

# 수집을 뒤따라가며 계속 처리 (권장 형태)
scripts/postrun.sh --follow --jobs 3 --lag 3 --outroot /Data_ssd/RAW

# 특정 런만
scripts/postrun.sh 4288
scripts/postrun.sh 4288 --from 100 --to 200

# tmux 배치에 포함해서 한 번에 (우하단 pane)
scripts/daq-tmux.sh
scripts/daq-tmux.sh --no-postrun      # 후처리 없이
```

주요 옵션은 `--jobs`(production 병렬 개수), `--lag`(기록 중인 서브런에서 몇 개
뒤까지 = 실시간 대비 몇 분 뒤를 따라갈지), `--outroot`(산출물 저장 위치),
`--nice`, `--poll`. 자세한 것은 `--help`.

`scripts/daq-tmux.sh` 는 우하단 pane 에서 위 권장 형태를 그대로 띄운다.

**중단은 Ctrl-C.** 진행 중인 production 을 기다린 뒤 종료한다.
다시 시작하면 2PC 판정으로 끝난 서브런을 건너뛰고 이어서 한다.

**검증은 기존 도구를 쓴다.**

```bash
cd /home/frontend/DAQ/DAQ_cup/production/Shell && ./audit_run.sh 004288
```

---

## 6. 운용 주의점

- **DAQ 가 도는 중에 처리해도 된다.** 측정상 DAQ 는 0.14 코어만 쓰고(12코어 중),
  기록 중인 서브런은 `--lag` 로 피한다. 다만 `--jobs` 를 코어 수 가까이 올리면
  NFS I/O 에서 경합이 생길 수 있다. 3~4 를 권장한다.
- **서브런 분할이 1분이라는 전제**로 여유를 계산했다.
  `--split-time` 을 바꾸면 이 문서의 초 단위 수치를 다시 재야 한다.
- 처리 로그는 `/scratch/LOG` 에 서브런당 3개씩 쌓인다.
  이미 7만 개가 넘는다. 정리 정책이 필요하다.
- `postrun.sh` 는 `libRawObjs` 가 필요하다(`cupdaq_env.sh`). ROOT 나 CUPDAQ 환경이
  없으면 스스로 source 하고, 그래도 없으면 시작하지 않는다.
