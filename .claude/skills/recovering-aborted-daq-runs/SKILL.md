---
name: recovering-aborted-daq-runs
description: Use when a RENE DAQ run ended abnormally - postrun printed "ZOMBIE FILE" or "Producing FAILED (0초)", a run's PRD count does not match its FADC count, dataflow keeps saying "후처리 미완료. 대기", or a finished run will not leave /Data_ssd.
---

# 비정상 종료한 런 복구하기

런이 쓰기 도중 죽으면 **마지막 서브런 파일이 안 닫힌 채** 남는다. 그 하나가
앞 서브런까지 끌고 내려가고, 결국 그 런은 `PRD 개수 == FADC 개수` 를 영원히
만족하지 못해 `dataflow` 의 `is_processed()` 를 통과하지 못한다.

**핵심 원리 — 대부분은 복구된다. 진짜로 못 쓰는 것은 원본에 키가 하나도 없는
파일뿐이다.** 서둘러 버리지 말고 먼저 사유를 읽어라.

## 절대 규칙

1. **ROOT 로 열리는 파일은 절대 격리하지 않는다.** 원본이 멀쩡한데 PRD 만 없는
   것은 다시 돌리면 되는 것이다. 격리하면 멀쩡한 데이터를 묻는다.
2. **수집 중인 런은 건드리지 않는다.** `/Data/LOG/rcterm.hb` 의 `run=` 을 먼저
   본다. postrun 은 `--lag 3` 으로 따라오므로 가동 중에는 **언제나** PRD 가
   서너 개 적고 마지막 SADC 는 안 닫혀 있다. 정상이다. 고칠 것이 아니다.
3. **`src/usbreset` 를 돌리지 않는다.** 이 증상과 무관하고, 인자 없이 실행하면
   그 자리에서 보드를 리셋한다(`--help` 가 없다). CLAUDE.md §11.51.

## 1. 무엇이 빠졌는지 센다

```bash
scripts/badrun.sh --scan --params config/dataflow.params --from <런-20>
```

손으로 셀 때는 **`ls -U` (readdir) 만** 쓴다. `/scratch` 는 100 Mb NFS 라
파일마다 stat 을 거는 `find -printf '%s'` 는 런 하나에 15분이 지나도 안 끝난다.

RAW 와 PRD 가 **다른 디스크에 있을 수 있다** — 각각 따로 찾아라
(`/Data_ssd/RAW` → `/data/RAW` → `/scratch/RAW`).

## 2. ★ merge 로그 끝 4줄을 읽는다 — 여기서 진짜 사유가 나온다

```bash
tail -4 /scratch/LOG/log_merge_FADC_SADC_v3_5v_run<런>_subrun<N>.txt
```

**postrun 의 `[CORRUPTION DETECTED] ZOMBIE FILE` 은 진단명이 아니다.** merge
매크로가 rc≠0 이면 무엇 때문이든 붙는 이름이다. 로그를 안 읽고 이 표시만 믿으면
멀쩡한 서브런을 corrupt 로 오판한다.

## 3. 사유별로 갈라진다

| 로그 끝에 보이는 것 | 뜻 | 할 일 |
|---|---|---|
| `Cannot open SADC file or ZOMBIE: SADC_...<N+1>` | **다음** SADC 가 죽어 이 서브런을 못 끝냈다. 자기 원본은 멀쩡하다 | 부분 Merged 에서 PRD 를 직접 만든다 (아래) |
| `Cannot open FADC file or ZOMBIE: FADC_...<N>` | 자기 원본이 죽었다 | 복구 불가. 4단계로 |
| `[FAIL] Producing FAILED (0초)` 또는 **merge 가 0초에 rc=1** | 로그 파일을 못 열어 매크로가 **아예 안 돌았다**. 데이터 문제가 아니다 | 로그 이름을 시험해 보고(아래) 매크로를 직접 부른다 |
| 로그가 없거나 원본이 다 열린다 | 그냥 후처리가 안 됐다 | `scripts/postrun.sh <런> --from A --to B` |

**FADC 서브런 N 을 merge 하려면 SADC 서브런 N+1 이 필요하다** (SADC 가 뒤처져
기록되므로). 이 한 가지가 "마지막 하나가 앞 것까지 끌고 내려가는" 이유다.

### ★ 0초 실패 — 데이터가 아니라 로그 디렉터리를 의심하라

`/scratch/LOG` 는 35만 개짜리 디렉터리이고 **엔트리가 깨진 이름들이 있다.**
조회는 ENOENT, 생성은 EIO 라 어느 쪽으로도 손댈 수 없다. 껍데기 스크립트가
`date > $LOG` 로 로그를 먼저 만드는데 그것이 실패하면 **매크로가 아예 실행되지
않고** 0초 만에 rc≠0 이 된다. merge 와 production **둘 다** 이렇게 죽는다.

```bash
# 이름 하나를 실제로 만들어 본다. 이웃 이름은 되는데 이것만 안 되면 그 문제다
date > /scratch/LOG/log_merge_FADC_SADC_v3_5v_run<런>_subrun<N>.txt   && rm -f "$_"
date > /scratch/LOG/log_production_v3_5v_run<런>_subrun<N>.txt        && rm -f "$_"
```

**이것이 옛 런의 PRD 결손을 만든 원인이기도 하다** — 처음 처리할 때도 같은 EIO
로 매크로가 안 돌았고, 아무도 모르게 구멍이 남았다. 원본 데이터는 멀쩡하다.

**우회 — merge 도 직접 부를 수 있다.** 이어받기 상태는 직전 서브런의 merge
로그에서 읽는다(그 파일은 대개 멀쩡하다).

```bash
tail -3 /scratch/LOG/log_merge_FADC_SADC_v3_5v_run<런>_subrun<N-1>.txt
#   final SADC = 5916   final SADC_evt = 633   final before_SADC_trgnum = 24634670

cd /home/frontend/DAQ/DAQ_cup/production/Code
root -l -b -q 'merge_FADC_SADC_v3_5v.cc(<런>,<맨끝서브런>,<N>,5916,633,24634670,"<데이터디렉터리>")'
root -l -b -q 'production_from_merged_v3_5v.cc(<런>,<N>,"<데이터디렉터리>")'
```

**직전 로그가 없으면 하지 말 것.** postrun 은 그때 `state=(N,0,0)` 으로
초기화하는데, 그러면 그 서브런의 앞부분 SADC 이벤트를 잃은 채 산출물이 나온다.
**개수는 맞지만 내용이 조용히 부족하다 — PRD 가 없는 것보다 나쁘다.**

## 4. 부분 Merged 에서 PRD 를 살린다

merge 가 에러로 빠져도 **그때까지 쓴 것이 autosave 되어 정상 ROOT 파일로 남는다.**
먼저 확인하고, 살아 있으면 껍데기 스크립트를 건너뛰고 매크로를 직접 부른다.

```bash
# 살아 있나? (Zombie 가 아니고 AbsEvent 트리가 있으면 쓸 수 있다)
root -l -b -q -e 'TFile*f=TFile::Open("<데이터디렉터리>/Merged/MERGED_<런>.root.<N>");
  printf("%s\n", (f&&!f->IsZombie())?"OK":"ZOMBIE");'

# 살아 있으면
cd /home/frontend/DAQ/DAQ_cup/production/Code
root -l -b -q 'production_from_merged_v3_5v.cc(<런>,<N>,"<데이터디렉터리>")'
```

postrun 의 완료 판정은 산출물 stat 이므로 로그가 없어도 정상으로 인식된다.
만든 PRD 의 이벤트 수가 그 Merged 와 같은지 확인할 것.

**실측 예 (run 4293 sub 90)** — 42,602 이벤트, 정상 서브런의 71%. 잘린 꼬리
때문에 짧을 뿐 물리적으로 유효한 데이터다. 버리면 그만큼 잃는다.

## 5. 못 살리는 것만 격리한다

```bash
scripts/badrun.sh --quarantine --run <런> --params config/dataflow.params --dry-run
scripts/badrun.sh --quarantine --run <런> --params config/dataflow.params
```

`<런>/badrun/` 으로 옮기고 목록에 한 줄 남긴다. 이동·백업은 저절로 따라간다
(설계 근거는 CLAUDE.md §5.9). 격리 뒤 막힘이 풀렸는지 확인한다.

```bash
f=$(find -L <런디렉터리> -maxdepth 1 -name 'FADC_*.root.*' | wc -l)
p=$(find -L <런디렉터리>/PRD -maxdepth 1 -name '*.root' | wc -l)
echo "$f $p"    # 같아야 dataflow 가 옮긴다
```

## 진단할 때 밟기 쉬운 것

| 함정 | 실제 |
|---|---|
| `pgrep -af <이름>` 로 "누가 이 런을 쓰나" 확인 | **자기를 부른 셸의 명령줄까지 잡는다.** 한 번은 그 결과로 자기 셸을 죽였다. `ps -eo pid=,args=` 로 자기 조상을 빼고, 프로그램 이름을 줄 맨 앞에서 확인하라 |
| 가동 중인 런의 PRD 가 3개 적다 | `--lag 3` 이다. 정상 |
| `[FAIL] ... (0초)` 를 데이터 손상으로 읽음 | 매크로가 안 돈 것이다 (§11.52) |
| 개수만 보고 corrupt 로 단정 | 원본을 열어 보기 전엔 모른다 |
| 서브런을 아무 순서로 merge | **번호 순서대로** 해야 한다. SADC 위치가 앞에서 넘어온다 (§5.8) |
| 옛 런을 통째로 다시 훑음 | `/scratch` 에서 13배 느리다 (§11.32). 구간을 끊어라 |
| 0초 실패를 데이터 손상으로 읽음 | 로그 이름을 만들어 보라. EIO 면 디렉터리 문제다 |
| 직전 merge 로그 없이 재처리 | 내용이 조용히 짧아진다. 차라리 두어라 |

## 마지막에 할 것

`/Data_ssd/LOG/badrun_list.txt` 가 갱신됐는지 보고, `scripts/badrun.sh --export`
로 `docs/BADRUNS.md` 사본을 맞춘 뒤, CLAUDE.md §11 에 무엇을 왜 했는지 남긴다.
**어떤 서브런을 왜 포기했는지는 반드시 적는다** — 나중에 개수가 안 맞는 이유를
설명하는 유일한 근거다.
