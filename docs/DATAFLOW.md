# DATAFLOW — 수집부터 백업·장기보관까지 데이터가 흐르는 길

`scripts/dataflow.sh` 와 `scripts/backup-khu.sh` 가 하는 일, 그리고 왜 그렇게
되어 있는지. 후처리(merge + production) 자체는 `docs/POSTRUN.md` 를 볼 것.

---

## 1. 전체 그림

```
   DAQ 수집 + 후처리          백업 대기            외부 백업            장기 보관
   /Data_ssd      ──1──►      /data      ──2──►   경희대(khu)
   NVMe  3.7 T                RAID  32 T     └──3──►  /scratch  NFS 140 T
   ▲                                                      
   └ rcterm 의 rawdatadir                                 
     postrun.sh 도 여기서 처리한다
```

| 단계 | 무엇을 | 조건 |
|---|---|---|
| 1 | `/Data_ssd` → `/data` | 후처리 완료(PRD 개수 == FADC 개수) + 수집 중이 아님 + 최근 `keep_ssd` 개 제외 |
| 2 | `/data` → khu 서버 | 카테고리별 rsync. 성공한 카테고리만 마커에 기록 |
| 3 | `/data` → `/scratch` | **2단계가 끝난 런만.** 여기가 최종 보관 |

세 위치 모두 구조가 같다.

```
<root>/RAW/<run>/{FADC,SADC}_<run>.root.<서브런>   원시 데이터
<root>/RAW/<run>/Merged/  PRD/  PNG/               후처리 산출물
<root>/LOG/{TCB,FADCDAQ,SADCDAQ}_<run>.log         DAQ 로그
<root>/CONFIG/<run>.config                         그 런에 쓴 설정
```

`RAW/<run>` 만 옮기고 로그·config 를 두고 오면 나중에 짝을 못 찾는다. 그래서
1단계와 3단계는 **셋을 항상 함께** 옮긴다.

---

## 2. 왜 이렇게 나눴나 — 두 개의 랜카드

이 PC 에는 랜카드가 둘이고, **속도가 10배 다르다**(실측).

| 인터페이스 | 속도 | 무엇이 지나가나 | 실측 처리량 |
|---|---|---|---|
| `enp1s0` (10.0.0.11) | **100 Mb** | `/scratch` NFS | **7.7 MB/s** |
| `enp0s31f6` (203.230.111.71) | 1000 Mb | 경희대 백업 | **15.7 MB/s** |

이 사실이 설계 전부를 결정한다.

- **수집과 후처리를 NFS 위에서 하면 안 된다.** 하루 생산량이 334 GB 인데
  100 Mb 링크로는 그것만으로 12 시간이 걸린다. DAQ 기록과 후처리 읽기가
  같은 링크를 나눠 쓰면 서로를 굶긴다. 그래서 둘 다 로컬 NVMe 에서 끝낸다.
- **2단계와 3단계는 서로 대역을 뺏지 않는다.** 경희대로 가는 길과 `/scratch`
  로 가는 길이 다른 랜카드라, 동시에 돌려도 된다.
- 경희대 쪽 15.7 MB/s 는 WAN 한계로 보인다(ssh 암호화 부하가 아니다 —
  요즘 CPU 는 100 MB/s 이상 낸다).

`enp0s31f6` 이 1 Gb 인데 `enp1s0` 이 100 Mb 인 것은 **사이트에서 고쳐 볼 값어치가
크다.** 스토리지 링크가 1 Gb 가 되면 3단계가 12 시간에서 1~2 시간으로 줄어든다.
자세한 진단은 `CLAUDE.md` §11.12.

---

## 3. 용량과 시간 — 24시간 런 1회 기준 (전부 실측)

서브런 1개 = 60초 분량.

| 종류 | 서브런당 | 1440 서브런(24h) |
|---|---|---|
| FADC | 71.4 MB | 103 GB |
| SADC | 8.6 MB | 12 GB |
| Merged | 78.8 MB | 114 GB |
| PRD | 73.7 MB | 106 GB |
| **합계** | **232 MB** | **334 GB** |

| 작업 | 옮기는 양 | 링크 | 걸리는 시간 |
|---|---|---|---|
| 2단계 백업 (RAW + PRD) | 221 GB | 15.7 MB/s | **약 3.9 h** |
| 3단계 `/scratch` (전부) | 334 GB | 7.7 MB/s | **약 12.1 h** |
| 3단계 (`--drop-merged`) | 221 GB | 7.7 MB/s | 약 8.0 h |

**런 하나가 24시간이므로 둘 다 여유가 있다.** 다만 3단계는 하루의 절반을 쓴다.
링크를 1 Gb 로 고치거나 `--drop-merged` 를 켜면 크게 줄어든다.

디스크 여유 (2026-08-17 기준)

| 위치 | 크기 | 여유 | 런 몇 개분 |
|---|---|---|---|
| `/Data_ssd` | 3.7 T | 3.3 T | 약 9 |
| `/data` | 32 T | 31 T | 약 92 |
| `/scratch` | 140 T | 19.5 T | 약 58 |
| khu `/store/cpnr-data` | 140 T | 21 T | 약 95 (Merged 제외) |

---

## 4. 백업 — 성격별로 목적지가 다르다

원격 트리가 이미 성격별로 나뉘어 있어서(`RAW / PRD / PNG / DAQLOG / config / db`)
그 관례를 그대로 따른다. 한 덩어리로 밀어 넣지 않는다.

```
  로컬 (/data)                             khu:/store/cpnr-data/RENE
  ------------------------------------    ---------------------------
  RAW/<run>/{FADC,SADC}_*.root.*     ──►  RAW/<run>/
  RAW/<run>/PRD/PRD_*.root           ──►  PRD/<run>/
  RAW/<run>/PNG/*.png                ──►  PNG/<run>/
  LOG/TCB_<run>.log                  ──►  DAQLOG/TCB/TCB_<run>.log.gz
  LOG/FADCDAQ_<run>.log              ──►  DAQLOG/FADCDAQ/…log.gz
  LOG/SADCDAQ_<run>.log              ──►  DAQLOG/SADCDAQ/…log.gz
  CONFIG/<run>.config                ──►  config/<run>.config
  /Data_ssd/runcatalog.db            ──►  db/runcatalog.<YYYY-MM-DD>.db
```

### Merged 는 보내지 않는다 ★의도적★

- 원격 트리에 `Merged` 카테고리가 **아예 없다**(실측 확인).
- 런당 114 GB 인데 RAW 로부터 언제든 다시 만들 수 있는 중간 산출물이다.
- 보내려면 `--with-merged`.

### 로그는 압축해서 보낸다

원격은 `.log.gz` 로 쌓여 있다. 원본을 그 자리에서 압축하지는 않는다 —
`/scratch/LOG` 쪽 관례가 평문이고 사람이 `tail` 로 열어 보는 파일이기 때문이다.
보낼 것만 임시로 만들어 쓰고 지운다.

### DB 는 sqlite3 스냅샷

살아 있는 sqlite 파일을 그냥 복사하면 쓰기 도중의 반쪽 상태가 갈 수 있다.
`sqlite3 .backup` 이 잠금을 잡고 일관된 스냅샷을 뜬다. 원격 이름에 날짜를 붙여
기존 관례(`runcatalog.<YYYY-MM-DD>.db`)를 따르므로 세대별로 남는다.

### 접속 — 비밀번호를 쓰지 않는다

`~/.ssh/config` 의 `khu` 별칭을 쓴다.

```
Host khu
  User renecomm
  HostName hep.khu.ac.kr
  Port 2223
  PreferredAuthentications publickey
```

이 계정은 위 7개 디렉터리 **전부에 쓰기 권한이 있다**(실측 확인).

> **왜 `sykim` 이 아닌가** — `sykim` 계정으로도 들어가지지만 쓰기 권한이
> `config` / `db` / `RAW` 세 곳뿐이다. `PRD` · `PNG` · `DAQLOG` · `Data` 는
> `renecomm:users` 소유의 `drwxr-xr-x` 라서 백업의 절반이 조용히 실패한다.
> 게다가 비밀번호를 파일에 적어야 한다. **설정 파일에 비밀번호를 쓰지 말 것.**
> 다른 계정이 필요하면 `--host user@host` 로 넘기고 키를 교환할 것.

---

## 5. 안전 장치

| 장치 | 무엇을 막나 |
|---|---|
| `heartbeat` 확인 | 수집 중인 런은 어느 단계에서도 건드리지 않는다 |
| `keep_ssd` | 후처리가 뒤따라오는 동안 원본을 지키다 |
| 후처리 완료 판정 | PRD 개수 == FADC 개수. 처리 안 끝난 런을 옮기지 않는다 |
| `rsync --partial-dir` | 끊겨도 **잘린 파일이 최종 이름을 차지하지 않는다** |
| 이동 후 개수 검증 | 목적지 개수가 모자라면 원본을 지운다 |
| 원격 개수 검증 | 카테고리 전송 후 원격 파일 수를 세어 확인한 뒤 마커를 남긴다 |
| `.backup_done` 마커 | 백업 안 끝난 런은 3단계로 넘어가지 못한다 |
| `flock` | 같은 런을 두 프로세스가 동시에 옮기는 것을 막는다 |
| 심볼릭 링크 감지 | 예전 `--outroot` 구성의 잔재가 있으면 손대지 않고 알린다 |

### `keep_ssd` 를 왜 2 로 두나

`postrun.sh` 는 런이 바뀐 **직후에** 직전 런의 잔여 서브런을 마저 처리한다.
`keep_ssd = 1` 이면 그 사이에 dataflow 가 직전 런을 옮겨가 후처리가 헛돌 수 있다.
2 로 두면 한 로테이션의 여유가 생긴다. 런당 334 GB 이고 `/Data_ssd` 가 3.7 T 라
2 는 넉넉하다. **3 을 넘기지 말 것 — 여기가 차면 DAQ 가 멈춘다.**

---

## 6. 사용

### 평소 (tmux 우하단 pane 에서 자동으로 뜬다)

pane 제목이 흐름을 그대로 적어 둔 것이라 어디까지 갔는지 눈으로 찾기 쉽다.

```
dataflow: /Data_ssd(RAW)->/data(PRD)->khu(backup)->scratch(save)
```

```bash
scripts/daq-tmux.sh --start        # dataflow pane 이 --follow 로 함께 뜬다
```

### 손으로

```bash
# 무엇을 할지만 확인 — 파일시스템을 건드리지 않는다
scripts/dataflow.sh --params config/dataflow.params --once --dry-run

# 한 바퀴
scripts/dataflow.sh --params config/dataflow.params --once

# 계속 (10분 주기)
scripts/dataflow.sh --params config/dataflow.params --follow

# 특정 단계만
scripts/dataflow.sh --params config/dataflow.params --stage 1 --once
```

### 백업만 따로

```bash
scripts/backup-khu.sh --params config/dataflow.params --run 4290 --dry-run
scripts/backup-khu.sh --params config/dataflow.params --run 4290
scripts/backup-khu.sh --params config/dataflow.params --all
scripts/backup-khu.sh --params config/dataflow.params --db-only
scripts/backup-khu.sh --params config/dataflow.params --run 4290 --only PRD,PNG
```

`/scratch` 에 이미 올라가 있는 예전 런도 그대로 보낼 수 있다.

```bash
scripts/backup-khu.sh --params config/dataflow.params --mid /scratch --run 4290
```

### 설정

`config/dataflow.params` (`.gitignore` 대상. `.example` 에서 복사해 쓴다).
`dataflow.sh` 와 `backup-khu.sh` 가 같은 파일을 읽고, 자기가 모르는 키는 무시한다.

**`rcterm.params` 의 `rawdatadir` 과 `dataflow.params` 의 `ssd_root` 는 같아야 한다.**
`heartbeat` 도 `rcterm.params` 와 같아야 한다 — 다르면 수집 중인 런을 알아보지
못하고 손을 댄다.

---

## 7. 막혔을 때

```
1. scripts/dataflow.sh --params config/dataflow.params --once --dry-run
      -> 각 단계가 무엇을 왜 건너뛰는지 한 줄씩 나온다
2. df -h /Data_ssd            여유가 min_free_gb 아래면 큰 경고가 이미 떠 있다
3. 1단계가 '후처리 미완료' 로 멈춰 있나
      -> postrun pane 을 볼 것. PRD 개수가 FADC 개수에 못 미치면 여기서 막힌다
4. 2단계가 실패하나
      ssh khu 'echo ok'       키 인증이 살아 있나
      cat /data/RAW/<run>/.backup_done    어느 카테고리까지 갔나
5. 3단계가 '백업 미완료' 로 멈춰 있나
      -> 4번의 마커를 볼 것. 급하면 --no-backup 으로 3단계만 진행할 수 있다
         (백업 없이 NFS 로 넘어간다는 뜻이므로 사유를 남길 것)
6. rm -f /tmp/.dataflow.$(id -u).lock    죽은 프로세스가 락을 쥐고 있을 때만
```

**막힌 채로 오래 두면 `/Data_ssd` 가 차고, 차면 DAQ 가 멈춘다.** dataflow 는
장식이 아니라 수집 체인의 일부다.

---

## 백업이 밀렸는지 확인하기 — `scripts/backup-audit.sh`

로컬이 우선이고 경희대는 크로스체크다. 이 도구가 셋을 갈라 보고한다.

```bash
scripts/backup-audit.sh                       화면으로
scripts/backup-audit.sh --from 4200 --to 4300 구간을 좁혀서
scripts/backup-audit.sh --deep 20             최근 20개는 파일 개수까지
scripts/backup-audit.sh --mail                결과를 메일로 (알람은 울리지 않는다)
```

| | 뜻 | 할 일 |
|---|---|---|
| ① 로컬에만 있다 | 아직 백업이 안 됐다 | 옛 런이면 `backup-trickle.sh`, 최근 런이면 dataflow 가 막혔는지 본다 |
| ② 원격에만 있다 | 로컬에서 정리된 옛 런 | 대개 정상이다 |
| ③ 개수가 다르다 | 전송이 덜 끝났다 | 그 런만 다시 보낸다 |

**읽기만 하므로 수집 중에 돌려도 안전하다.** 원격 목록은 `ssh` 한 번으로 통째로
받는다 — 런마다 접속하면 2천 번이라 몇 시간이 걸린다.

**③ 의 기준에 주의.** 원격 `RAW/<run>/` 에는 FADC 와 SADC 가 **함께** 들어간다.
그래서 로컬 FADC 개수의 **2배**가 원격 기대값이다. 이걸 1배로 보면 정상인 런이
전부 어긋난 것으로 나온다.
