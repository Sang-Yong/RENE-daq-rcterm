# RENE-daq-rcterm (한국어)

**RENE / CUPDAQ** 데이터 수집 시스템용 **텍스트 전용(headless) 런 컨트롤**.
**CERN ROOT 기반 C++17**로 작성되었습니다.

[Sang-Yong/RENE-daq](https://github.com/Sang-Yong/RENE-daq)의
`DAQ_cup/DAQRC/rc.py`에서 **PyQt5 GUI를 제거**하고 재작성한 것으로, DAQ를 전적으로
스크립트·cron·systemd로 구동할 수 있으며 무인으로 수 주간 연속 운용할 수 있습니다.

English: **[README.md](README.md)** · 운용 매뉴얼: [docs/MANUAL.md](docs/MANUAL.md)

---

## 1. 이 프로그램의 실체

`rc.py`는 하드웨어를 직접 건드리지 않았습니다. 실제 하드웨어 제어는 CUPDAQ 실행
파일(`daq`, `merger`, `tcb`)이 담당하며, `rc.py`가 한 일은 세 가지뿐입니다.

| 역할 | 방식 |
|---|---|
| **Boot** | config의 `SERVER` 라인을 파싱해 노드별로 `executedaq.sh` 실행 |
| **Control** | TCB의 TCP 소켓(`localhost:7809`)에 32바이트 명령 전송 |
| **Monitor** | 각 DAQ 소켓에 질의해 이벤트 수와 경과 시간 수신 |

`rcterm`은 정확히 이 세 역할만 재현합니다. **하드웨어 드라이버 코드를 재작성하지
않았기 때문에** 이식 위험이 낮습니다.

독립된 실행 파일 두 개가 생성됩니다.

| 바이너리 | 책임 |
|---|---|
| **`rcterm`** | 런 컨트롤 1회분: boot → configure → start → monitor → end → exit |
| **`rcsupervisor`** | N시간마다 런 번호를 교체하고, 이상 감지 시 DAQ를 자동 재시작 |

---

## 2. 저장소 구성

```
RENE-daq-rcterm/
├── CMakeLists.txt                          빌드 (ROOT Core/RIO/Tree만)
├── build.sh                                일괄 빌드 스크립트
├── README.md / README.ko.md
├── src/
│   ├── OnlConsts.hh       2.3 kB   프로토콜 상수 (onlconsts.py 대응)
│   ├── OnlSocket.hh       4.7 kB   32바이트 메시지 소켓 클라이언트 (헤더 전용)
│   ├── RunControl.hh      4.7 kB   RunControl / DaqNode / TrgStat 선언
│   ├── RunControl.cc     39.5 kB   config 파싱, 상태머신, DB, 출력
│   ├── rcterm.cc          8.0 kB   rcterm의 main()
│   └── rcsupervisor.cc   23.9 kB   rcsupervisor의 main() (자체 완결)
├── config/
│   ├── rcterm.params.example
│   ├── rcsupervisor.params.example
│   └── SERVER-block.example            이중 머저 SERVER 블록 템플릿
├── scripts/
│   ├── killdaq.sh                      daq/merger/tcb 비상 정리
│   └── rcsupervisor.service.example    systemd 유닛 템플릿
└── docs/
    └── MANUAL.md                       상세 운용 매뉴얼
```

### 2.1 내부 의존 관계

```
OnlConsts.hh        말단 - 프로젝트 의존 없음, ROOT 의존도 없음
     ▲
OnlSocket.hh        헤더 전용; OnlConsts.hh + POSIX 소켓
     ▲
RunControl.hh       OnlSocket.hh + TString.h
     ▲
     ├── RunControl.cc      + TFile, TTree, TNamed, TSystem
     ├── rcterm.cc          + TSystem
     └── rcsupervisor.cc    OnlConsts.hh + OnlSocket.hh 만
                            (RunControl.hh를 의도적으로 include하지 않음)
```

`rcsupervisor`는 `RunControl.cc`를 **컴파일·링크하지 않습니다.** 프로토콜 상수와
소켓 클라이언트만 필요하므로, 런 컨트롤 상태머신에 결함이 생겨도 감시자가 함께
죽지 않습니다. **감시자는 감시 대상보다 단순해야 한다**는 원칙에 따른 의도적
격리입니다.

### 2.2 번역 단위 / 링크 구성

| 타깃 | 소스 | ROOT 라이브러리 |
|---|---|---|
| `rcterm` | `rcterm.cc`, `RunControl.cc` | Core, RIO, Tree |
| `rcsupervisor` | `rcsupervisor.cc` | Core |

현재 `rcsupervisor`도 빌드 단순화를 위해 `root-config --libs` 전체를 링크하지만,
실제로 쓰는 것은 `TString`과 `gSystem`뿐입니다. §9.11 참고.

---

## 3. 의존성

### 3.1 빌드 시 필수

| 구성요소 | 검증 버전 | 용도 | 없으면 |
|---|---|---|---|
| **CERN ROOT** | 6.2x 이상 | `TFile`/`TTree` 모니터 출력, `TString`, `gSystem` | 빌드 실패 |
| **GCC** | 11.5.0 (Rocky 9.8), 14.2.0에서도 검증 | C++17 | — |
| **CMake** | 3.16 이상 (3.31.8 검증) | 빌드 드라이버 | §4.3의 `g++` 직접 컴파일 사용 |
| **glibc / POSIX** | 최신 계열 | 소켓, `fork`, `waitpid`, `signal`, `rename` | — |

사용하는 ROOT 컴포넌트는 **`Core`, `RIO`, `Tree` 뿐**입니다. `Gui`, `Gpad`,
`Graf`, Cling 딕셔너리, `ROOT::Math`를 쓰지 않으므로 headless·최소 ROOT 빌드로도
충분합니다.

### 3.2 실행 시에만 필요

| 구성요소 | 용도 | 없으면 |
|---|---|---|
| `sqlite3` CLI | `runcatalog.db`에서 런 번호 발급 | `--no-db --run N`으로 우회 |
| `executedaq.sh` + `daq` / `merger` / `tcb` | 실제 DAQ | 아무것도 동작하지 않음 |
| `pkill`, `kill` | 감시자의 강제 복구 경로 | 복구가 SIGTERM 수준으로 약화 |
| `cp` | config를 `$RAWDATA_DIR/CONFIG`로 스테이징 | 부팅 실패 |

Rocky Linux 9에서 SQLite CLI 설치:

```bash
sudo dnf install -y sqlite
```

### 3.3 의도적으로 제거한 의존성

| 제거 대상 | 원래 용도 | 대체 방식 |
|---|---|---|
| **PyQt5** | GUI 전체 | 터미널 화면 갱신 또는 `--quiet` 한 줄 로그 |
| **pydblite** | 런 번호 발급 | `sqlite3` CLI + `last_insert_rowid()` |
| **Python 3** | 전부 | 실행 시 전혀 필요 없음 |
| **ssh / scp** | 원격 노드 부팅 | 로컬 `cp` + `gSystem->Exec` (단일 PC 사이트) |

PyQt5 제거가 실무적으로 가장 큰 이득입니다. Rocky Linux 9에서 PyQt5 설치가 까다로운
데다, 무인 운용 DAQ의 필수 의존성에 GUI 툴킷이 들어갈 이유가 없습니다.

ssh/scp 경로는 사이트 상수 `kISREMOTEDAQ`가 `False`이고 모든 노드가 `localhost`
이므로 제거했습니다. 향후 다중 호스트로 확장한다면 §9.12를 보십시오.

### 3.4 SQLite 스키마 호환성

`pydblite.sqlite`는 평범한 SQLite 테이블을 사용하므로 C++ 측과 스키마 호환됩니다.
`create_runcatalog_db.py`를 대조해 확인했습니다.

```sql
CREATE TABLE runcatalog (
  runnum  INTEGER PRIMARY KEY AUTOINCREMENT,   -- rowid 별칭
  runtype TEXT, rundesc TEXT, shift TEXT, config TEXT,
  stime TEXT, etime TEXT,
  onlbit INTEGER, offbit INTEGER, runlog TEXT
  -- nfadc/tfadc, nsadc/tsadc, niadc/tiadc 는 DB를 -f / -s / -i 옵션으로
  -- 생성했을 때만 존재함
);
```

`runnum`이 `INTEGER PRIMARY KEY`이므로 곧 rowid입니다. 따라서
`INSERT ...; SELECT last_insert_rowid();`는 `pydblite`의 `table.insert()`가
반환하던 값과 정확히 동일하며, 기존 GUI로 취득한 런들과 번호가 연속됩니다.

`rcterm`은 시작 시 `PRAGMA table_info(runcatalog)`를 실행해 **실제로 존재하는
컬럼만** 기록하므로, `-f`/`-s` 없이 만든 카탈로그에서도 SQL 오류가 나지 않습니다.

---

## 4. 빌드

### 4.1 빠른 방법

```bash
git clone https://github.com/Sang-Yong/RENE-daq-rcterm.git
cd RENE-daq-rcterm
source /opt/root/bin/thisroot.sh      # ROOT 설치 경로에 맞게 수정
./build.sh                            # -> install/bin/{rcterm,rcsupervisor}
```

### 4.2 CMake 직접 실행

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PWD/install
cmake --build build -j$(nproc)
cmake --install build
```

### 4.3 CMake 없이

```bash
g++ -std=c++17 -O2 -Wall -Isrc -o rcterm \
    src/rcterm.cc src/RunControl.cc $(root-config --cflags --libs)
g++ -std=c++17 -O2 -Wall -Isrc -o rcsupervisor \
    src/rcsupervisor.cc $(root-config --cflags --libs)
```

---

## 5. 빠른 시작

```bash
cp config/rcterm.params.example       config/rcterm.params
cp config/rcsupervisor.params.example config/rcsupervisor.params
vi config/rcterm.params        # shift, config, onldaqdir, rawdatadir, heartbeat

# 1) 반드시 먼저 실행. 모든 명령과 SQL을 출력하고,
#    하드웨어를 건드리지 않으며 아무것도 기록하지 않습니다.
install/bin/rcterm --params config/rcterm.params --dry-run

# 2) 단축 로테이션 테스트: 5분 런, 2사이클, 1분 진단 주기
install/bin/rcsupervisor --params config/rcsupervisor.params \
    --run-length 0.0833 --margin 2 --check-period 60 --stall-grace 120 --max-cycles 2

# 3) 상시 운용: 24시간 로테이션, 무한 반복
tmux new -s daq
install/bin/rcsupervisor --params config/rcsupervisor.params
```

> **`heartbeat` 경로는 `rcterm.params`와 `rcsupervisor.params`에서 반드시
> 동일해야 합니다.** 다르면 감시자가 heartbeat를 영원히 "stale"로 판정해 DAQ를
> 무한 재시작합니다. 가장 흔한 설정 실수입니다.

---

## 6. `rcterm` 옵션

우선순위는 **커맨드라인 / `--params` 파일 > 환경변수 > 컴파일 기본값** 입니다.
`--params` 파일 안에서는 앞의 `--`를 생략하고 `key = value` 형식으로 쓰며, `#`
이후는 주석입니다.

### 6.1 런 정의

| 옵션 | 의미 | 기본값 |
|---|---|---|
| `--shift NAME` | 카탈로그에 기록되는 시프트/운용자 이름 | — |
| `--runtype TYPE` | `physics` / `calibration` / `test` | `test` |
| `--desc "TEXT"` | 자유 서술 런 설명 | — |
| `--config FILE` | `SERVER` 라인을 포함하는 DAQ config 파일 | — |
| `--split-time MIN` | 서브런 분할 주기(**분**), TCB에 `-p <초>`로 전달 | 1 |
| `--no-tcb-split` | `-p`를 아예 전달하지 않음 (구버전 TCB 대응) | 꺼짐 |
| `--run-length HOUR` | 런 번호 교체까지의 런 길이 | 24 |
| `--max-runs N` | 로테이션 사이클 수, `0`은 무한 | 0 |
| `--badrun` | 불량 런으로 표시 (`onlbit = 0`) | 정상 |
| `--merger-type KIND` | 노드 이름이 모호할 때 머저의 ADC 종류를 강제 | 자동 |

### 6.2 카탈로그 데이터베이스

| 옵션 | 의미 |
|---|---|
| `--dbfile FILE` | `runcatalog.db` 경로 |
| `--no-db` | 카탈로그를 전혀 사용하지 않음 |
| `--run N` | 런 번호 직접 지정, `--no-db`와 함께 필수 |

### 6.3 사이트 경로 및 엔드포인트

| 옵션 | 환경변수 | 의미 |
|---|---|---|
| `--onldaqdir DIR` | `ONLDAQ_DIR` | DAQ 설치 prefix, `bin/`을 포함해야 함 |
| `--rawdatadir DIR` | `RAWDATA_DIR` | 원자료 루트, 그 아래 `LOG/`·`CONFIG/`를 생성 |
| `--bindir DIR` | — | 바이너리 디렉터리 재지정 (기본 `$ONLDAQ_DIR/bin`) |
| `--exescript NAME` | — | 부팅 스크립트 이름 (기본 `executedaq.sh`) |
| `--daqserver IP` | `DAQSERVER_IP` | TCB 호스트 (기본 `localhost`) |
| `--daqport N` | `DAQSERVER_PORT` | TCB 포트 (기본 `7809`) |
| — | `RUNCATALOG_DB` | `--dbfile`의 기본값 |

### 6.4 출력 및 진단

| 옵션 | 의미 |
|---|---|
| `--update SEC` | 화면·heartbeat 갱신 주기 |
| `--quiet` | 전체 화면 갱신 대신 갱신마다 한 줄 출력 (로깅용) |
| `--log FILE` | 텍스트 로그를 파일에 추가 |
| `--rootout FILE` | `daqmon` `TTree`를 ROOT 파일로 기록 |
| `--heartbeat FILE` | `rcsupervisor`가 읽는 기계 판독용 상태 파일 기록 |
| `--boot-timeout SEC` | 모든 노드가 *Booted*에 도달할 때까지의 대기 한도 |
| `--state-timeout SEC` | 그 외 상태 전이 대기 한도 |
| `--dry-run` | 모든 명령과 SQL을 출력하고 실행은 하지 않음 |
| `--params FILE` | 파일에서 옵션 로드 |
| `-h`, `--help` | 사용법 |

`rcterm`은 옵션 파싱 또는 `Init()` 실패 시 **종료 상태 1**, 정상 종료 시 **0**을
반환합니다. `rcsupervisor`는 이 값으로 "설정 오류"와 "정상 런 종료"를 구분합니다.

### 6.5 GUI → CLI 대응

| `rc.py` 위젯 | `rcterm` 대응 |
|---|---|
| `ShiftConfig` | `--shift NAME` |
| `RunTypeConfig` | `--runtype ...` |
| `RunDescConfig` | `--desc "TEXT"` |
| `ConfigFileButton` | `--config FILE` |
| `SplitTimeConfig` | `--split-time MIN` |
| Boot / Config / Start / End / Exit 버튼 | 순서대로 자동 수행 |
| GOODRUN 확인 대화상자 | `--badrun` |
| — (신규 기능) | `--run-length`, `--heartbeat`, `--rootout`, `--dry-run` |

### 6.6 모니터 `TTree` (`--rootout`)

트리 이름은 `daqmon`이고, 갱신마다 한 엔트리가 채워집니다.

| 브랜치 | 타입 | 의미 |
|---|---|---|
| `ctime` | `Double_t` | 샘플의 UNIX 시각 |
| `run`, `subrun` | `Int_t` | 런 / 서브런 번호 |
| `state` | `Int_t` | 해석된 DAQ 상태 인덱스 |
| `daqtime` | `Double_t` | DAQ가 보고한 경과 시간 [s] |
| `ndaq` | `Int_t` | 모니터 중인 노드 수 |
| `nev[ndaq]` | `Long64_t` | 노드별 누적 이벤트 수 |
| `srate[ndaq]` | `Double_t` | 순간 rate [Hz] |
| `arate[ndaq]` | `Double_t` | 런 시작 이후 평균 rate [Hz] |

노드 이름은 `daqnames`라는 `TNamed` 객체로 함께 저장되므로, 오프라인에서 브랜치
인덱스를 노드 이름으로 되돌릴 수 있습니다.

---

## 7. `rcsupervisor`

### 7.1 제어 흐름

```
rcsupervisor
  ├─ 다음 인자로 rcterm 을 fork/exec:  --params <rcterm-params>
  │                                    --max-runs 1
  │                                    --run-length (run-length + margin)
  │                                    --quiet
  │                                    --heartbeat <경로>
  │                                    [--no-db --run N]   --no-db 일 때만
  │                                    [커맨드라인의 `--` 뒤 전부]
  ├─ 정확히 run-length 시점에 rcterm PID 에만 SIGTERM
  │     └─ rcterm 이 ENDRUN → RUNENDED → EXIT 수행, 카탈로그 행 마감
  ├─ 자식이 종료되면 새 런 번호로 다음 사이클 시작
  └─ --check-period 마다 5중 진단 수행, 실패 시 복구
```

자식에게는 `--run-length`로 **요청 길이 + `--margin`**을 주고, 감시자가 요청 길이
시점에 종료시킵니다. margin은 **런 종료 시점을 감시자가 결정**하도록 하기 위한
것이며, `rcterm` 자체 타이머는 감시자가 죽었을 때를 위한 예비 장치입니다.

### 7.2 런 번호를 발급하는 주체

**`rcsupervisor`는 데이터베이스를 전혀 건드리지 않습니다.** SQL을 포함하지 않고
`sqlite3`를 호출하지도 않습니다. 매 사이클 새로 기동된 `rcterm`이 카탈로그에 행을
삽입하고 `last_insert_rowid()`를 읽어 스스로 런 번호를 발급합니다. 감시자가
`--run N`을 명시적으로 넘기는 것은 `--no-db` 모드일 때뿐이며, 이때는 감시자가
사이클마다 번호를 직접 증가시킵니다.

따라서 DB 경로·시프트·런 타입·split time 등 모든 런 속성은 **`rcterm`의 params
파일**에서 설정합니다. 감시자에는 `--shift`, `--config`, `--split-time`,
`--dbfile`, `--onldaqdir`, `--rawdatadir` 옵션이 **의도적으로 없습니다.**

### 7.3 시그널 정책 (중요)

SIGTERM은 **`rcterm` PID 하나에만** 보내며, **프로세스 그룹에는 절대 보내지
않습니다.** `executedaq.sh`가 `daq`, `merger`, `tcb`를 같은 프로세스 그룹의
백그라운드로 띄우기 때문에, 그룹에 시그널을 보내면 DAQ가 기록 중에 죽어 마지막
원자료 파일이 손상됩니다. 정상 경로에서는 `rcterm`이 `EXIT` 명령으로 DAQ를 얌전히
내립니다. 강제 종료(그룹 `SIGKILL` 후 `pkill`)는 정상 경로가 이미 실패한
**복구 경로에서만** 사용합니다.

### 7.4 heartbeat 파일 형식

`rcterm --heartbeat FILE`은 임시 파일에 쓴 뒤 `rename()`하므로, 읽는 쪽이 부분
기록 상태를 관측하는 일이 없습니다.

```
time=1786554086       # 이 샘플의 벽시계 시각. 낡으면 rcterm 이 멈춘 것
phase=running         # booting|booted|configured|running|ending|ended|error|failed|notrunning
run=123
subrun=45
state=Running
statebit=3
error=0
status=8
daqtime=1234.5
totev=98765           # 전역 이벤트 합, stall 감지용
ndaq=2
daq0=FADCDAQ n=98700 sr=321.4 ar=320.6
daq1=SADCDAQ n=65 sr=4.6 ar=4.6
```

### 7.5 5중 진단

하나만 걸려도 이상으로 판정합니다.

| # | 점검 | 이상 판정 조건 | 해제 옵션 |
|---|---|---|---|
| 1 | heartbeat 신선도 | `--stale-limit`(300초) 초과 | — |
| 2 | `error=` 필드 | 값이 1 | — |
| 3 | `phase` / `state` 정합 | *Running* 이 아님 | — |
| 4 | TCB 소켓 직접 조회 | 연결 실패, 무응답, ERROR 비트, 미가동 | `--no-socket-check` |
| 5 | `totev` 증가 | `--stall-grace`(1800초) 동안 정지 | `--no-stall-check` |

3~5번은 매 기동 후 `--boot-grace`(300초) 동안 유예되므로, 정상적인 부팅 지연을
고장으로 오판하지 않습니다.

### 7.6 복구 절차

```
1) rcterm PID 에 SIGTERM                  정상 마감 시도, 카탈로그 갱신 포함
2) --grace(180초) 내 미종료               프로세스 그룹에 SIGKILL
3) pkill -f "<bindir>/{tcb,merger,daq}"   SIGTERM 후 잔존 프로세스에 SIGKILL
4) --settle(10초) 대기
5) --backoff(30초) 후 새 런 번호로 재시작
```

`--max-consec-fail`(기본 5) 회 연속 실패하면 감시자는 쓰레기 런을 대량 생산하지
않도록 스스로 종료합니다. 사이클이 한 번 성공하면 카운터가 초기화됩니다.

### 7.7 `rcsupervisor` 옵션

| 옵션 | 의미 | 기본값 |
|---|---|---|
| `--rcterm PATH` | `rcterm` 바이너리 경로 | 감시자와 같은 디렉터리의 `./rcterm` |
| `--rcterm-params FILE` | `rcterm`에 넘길 params 파일 | — |
| `--run-length HOUR` | 로테이션 주기 | 24 |
| `--margin MIN` | 자식에게 추가로 주는 `--run-length` 여유분 | 30 |
| `--max-cycles N` | 사이클 수, `0`은 무한 | 0 |
| `--max-runs N` | `--max-cycles`의 별칭 | 0 |
| `--check-period SEC` | 진단 주기 | 600 |
| `--stale-limit SEC` | heartbeat 노후 판정 한계 | 300 |
| `--boot-grace SEC` | 매 기동 후 유예 시간 | 300 |
| `--stall-grace SEC` | `totev`가 정지해 있어도 허용하는 시간 | 1800 |
| `--no-stall-check` | 5번 점검 해제 | 꺼짐 |
| `--no-socket-check` | 4번 점검 해제 | 꺼짐 |
| `--grace SEC` | SIGTERM에서 SIGKILL로 승격하기까지의 대기 | 180 |
| `--settle SEC` | 정리 후 대기 | 10 |
| `--backoff SEC` | 재시작 전 대기 | 30 |
| `--max-consec-fail N` | 연속 실패 허용 횟수 | 5 |
| `--heartbeat FILE` | heartbeat 경로, **`rcterm` params와 일치 필수** | — |
| `--bindir DIR` | `pkill` 패턴 구성에 쓰는 바이너리 디렉터리 | — |
| `--daqserver IP`, `--daqport N` | 4번 점검용 TCB 엔드포인트 | localhost:7809 |
| `--no-db` | 감시자가 `--run`으로 런 번호를 직접 발급 | 꺼짐 |
| `--run N` | `--no-db` 모드의 첫 런 번호 | — |
| `--log FILE`, `--quiet`, `--dry-run`, `--params FILE`, `-h` | `rcterm`과 동일 | — |

단독 `--` 뒤의 인자는 `rcterm`에 그대로 전달됩니다. 감시자가 모르는 옵션을 넘기는
탈출구입니다.

```bash
rcsupervisor --params config/rcsupervisor.params -- --rootout /Data/LOG/mon.root
```

---

## 8. 원본 `rc.py`에서 발견해 회피한 버그

모두 상위 저장소 소스를 직접 읽어 확인한 것이며, `rcterm`에서 교정되었습니다.

1. **`SplitTimeConfig.setText(self.SplitTime)`** — `str`이 필요한 메서드에 `int`를
   넘겨 `TypeError`가 발생합니다. 초기값 60도 "1분"이라는 라벨 표기와 어긋납니다.
2. **AMOREADC를 쓰는 순간 부팅 순서가 깨집니다.** `sortfunc(e)`가 반환하는 `e[2]`는
   노드 이름이 아니라 `dopt` 문자열입니다. TCB의 `dopt`는 `-d`로 시작하므로
   `pop(0)`이 우연히 TCB를 맨 뒤로 보내 정상처럼 보입니다. 그러나 AMOREADC의
   `dopt`는 `-a`로 시작하고 `'a' < 'd'`이므로 **TCB 대신 AADC가 맨 뒤로 가고**,
   TCB가 자기 클라이언트보다 먼저 부팅됩니다. `rcterm`은 문자열 비교가 아니라
   노드 mode(`MERGER → ADC → TCB`)로 순서를 강제합니다.
3. **`MERGER`라는 이름의 노드가 MADC로 오분류됩니다.** `rc.py`는 ADC 종류 문자를
   `name[0].lower()`로 얻는데, `MERGER`는 `m`이 되어 `-m`(MADC)이 됩니다. `rcterm`은
   부분문자열(`FADC`, `SADC`, `IADC`, `GADC`, `AMOREADC`, `MADC`)로 판정하므로
   `FADCMERGER`는 `-f`, `SADCMERGER`는 `-s`로 정확히 갈립니다.
4. **기존 텍스트 모드 `rcterm.py`는 실행 자체가 불가능합니다.** 현재 소스에 없는
   `onlutils.send_message()`와 `onlconsts.kSOFTWARE_VER`를 호출하고,
   `executedaq.sh`가 아니라 `executenulldaq.sh`를 실행하며, split time을 전달하지
   않습니다. 재활용할 수 없었습니다.
5. **주석과 코드가 반대입니다.** `split_time = self.SplitTime * 60`은 분→초 변환인데
   주석은 `[s] -> [m]`이라고 적혀 있습니다. `executedaq.sh -p`는 **초** 단위입니다.
6. **`$RAWDATA_DIR/LOG`를 아무도 만들지 않습니다.** `executedaq.sh`가 그 디렉터리로
   표준출력·표준오류를 리다이렉트하므로, 없으면 **DAQ가 아무 진단도 남기지 않고
   조용히 죽습니다.** `rcterm`은 부팅 전에 `$RAWDATA_DIR/LOG`와
   `$RAWDATA_DIR/CONFIG`를 `mkdir -p`로 생성합니다.

### 8.1 `rcterm`이 수행하는 config 검증

| 상황 | 조치 |
|---|---|
| ADC 노드 이름에서 ADC 종류를 알 수 없음 | **치명적 오류로 정지** |
| 머저 이름에 종류가 없고 config의 ADC 종류가 2개 이상 | **정지**, 이름 변경 또는 `--merger-type` 요구 |
| 머저 이름에 종류가 없고 ADC 종류가 정확히 1개 | 자동 추론 후 로그로 통지 |
| 같은 종류의 머저가 2개 | **정지** |
| 머저에 대응하는 ADC가 없음 | 경고, 그리고 `-x`를 부착하지 않음 |
| 두 노드가 같은 `ip:port` 사용 | **정지** |
| 머저 포트가 22 | 경고 (SSH 포트임) |

`-x`는 **같은 종류의** 머저가 존재할 때만 ADC에 부착됩니다. 따라서 실행되지 않는
머저로 데이터를 보내라고 ADC에 지시하는 일이 발생하지 않습니다.

---

## 9. 알려진 한계와 개선이 필요한 부분

영향이 큰 것부터 정직하게 나열합니다.

**9.1 실제 하드웨어에서 아직 검증되지 않았습니다. 남은 위험 중 가장 큽니다.**
빌드는 무경고로 통과했고 부팅 명령 생성은 `--dry-run`으로 확인했지만, 실제 DAQ에서
런을 취득해 본 적은 없습니다. 상시 운용 전에 `--dry-run` → 2사이클 단축 테스트 →
한 사이클 전체 관찰 순서를 반드시 거치십시오.

**9.2 런 간 dead time은 0이 아니며 대략 10~40초입니다.** 프로토콜에는
`CONFIGRUN`, `STARTRUN`, `ENDRUN`, `EXIT` 네 명령만 있고 **가동 중 런 번호를 바꾸는
명령이 없습니다.** 런 번호는 `executedaq.sh -r <run>`으로 프로세스를 띄우는 시점에
고정되므로 로테이션에는 프로세스 재기동이 필수입니다. 실측 dead time은 매 사이클
로그에 남습니다. dead time이 반드시 0이어야 한다면 런을 나누지 말고 서브런만
쓰십시오: `--max-runs 1 --run-length 8760 --split-time 1`.

**9.3 `sqlite3`를 링크하지 않고 서브프로세스로 호출합니다.** `RunSQL()`이 임시 SQL
파일을 만들어 셸로 실행합니다. `--desc`의 인용부호는 이스케이프하지만 파라미터
바인딩보다 약하며, 런마다 프로세스 생성 비용이 듭니다. 개선안: `libsqlite3`를
링크하고 prepared statement를 사용.

**9.4 rate를 벽시계가 아니라 DAQ가 보고한 경과 시간으로 계산합니다.** DAQ의 나노초
카운터가 멈추면 순간 rate가 0으로 떨어지는 대신 정의되지 않는 값이 되어 stall 감지가
약간 약해집니다. 개선안: 벽시계 기준 rate를 함께 계산해 교차 검증.

**9.5 모니터 소켓을 런당 한 번만 열고 재연결하지 않습니다.** 런 도중 ADC 모니터
소켓이 끊기면 다음 사이클까지 해당 카운터가 멈춥니다. DAQ 자체는 계속 동작하므로
자료 결함이 아니라 모니터링 결함입니다. 개선안: 실패 시 주기적 재연결.

**9.6 소켓 타임아웃이 `OnlSocket::Connect()`에 3초로 하드코딩되어 있습니다.** 부하가
높은 장비에서는 정상 응답이 이를 초과해 고장으로 오판될 수 있습니다. 개선안: 옵션화.

**9.7 heartbeat 파일에 락이 없습니다.** `rename()` 기록은 원자적이므로 단일 독자에는
충분하지만, 두 `rcterm` 인스턴스가 같은 경로를 공유하는 것을 막지 못해 감시자가
혼란에 빠질 수 있습니다. 개선안: PID 파일 + `flock`, 그리고 감시자가 감시 대상 PID를
검증하도록 보강.

**9.8 자동화 테스트가 없습니다.** config 파싱, 머저 종류 판정, 비트마스크 해석은 모두
순수 함수여서 테스트하기 쉽습니다. 개선안: 골든 `SERVER` 블록과 기대 부팅 명령을 담은
`tests/` 타깃 추가.

**9.9 런이 정상인지 확인되기 전에 카탈로그 행을 먼저 삽입합니다.** 부팅이 실패하면
`etime`이 빈 행이 남습니다. 개선안: 그런 행을 명시적으로 abort 상태로 표시.

**9.10 상태머신 타임아웃이 전이별 고정값입니다.** FADC 펌웨어 적재가 느리면 성공할
수 있었던 부팅도 `--boot-timeout`을 초과합니다. 현재 대처는 값을 수동으로 늘리는
것뿐입니다.

**9.11 `rcsupervisor`가 필요 이상으로 ROOT를 링크합니다.** 실제로 쓰는 것은 `TString`
과 `gSystem`뿐이므로 ROOT 의존을 완전히 없앨 수 있고, 그러면 ROOT 설치가 깨져도
감시자는 살아남습니다. 개선안: 두 용도를 `std::string`과 `std::system`으로 대체.

**9.12 설계상 단일 호스트 전용입니다.** `kISREMOTEDAQ`가 `False`이므로 ssh/scp 처리를
모두 제거했습니다. 사이트가 다중 호스트로 확장되면 부팅과 config 스테이징 단계를 원격
호출로 되살려야 합니다. 모니터링과 제어 경로는 이미 TCP 기반이므로 수정이 필요 없습니다.

**9.13 상위 저장소의 `test_wj_merger.config`는 머저를 쓰기 전에 두 곳을 고쳐야
합니다.** `MERGER` 노드가 SSH 포트인 22번을 사용하고 있고, 이름에 ADC 종류가 없습니다.
노드 이름을 `FADCMERGER`, `SADCMERGER`로 바꾸고 포트를 수정하십시오. `rcterm`은 두
문제를 각각 경고와 치명적 오류로 잡아냅니다.

---

## 10. 검증 현황

| 항목 | 상태 |
|---|---|
| g++ 14.2, `-std=c++17 -Wall -Wextra` 컴파일 | **통과**, 경고 0건 |
| 두 바이너리 링크 | **통과** |
| 이중 머저 종류 판정 (`FADCMERGER`→`-f`, `SADCMERGER`→`-s`) | **통과** (`--dry-run`) |
| 부팅 순서 `MERGER → ADC → TCB` | **통과** |
| `--split-time 1` → TCB `-p 60` 변환 | **통과** |
| `--no-tcb-split` 시 `-p` 제거 | **통과** |
| §8.1의 config 검증 7종 전부 | **통과** |
| 같은 종류 머저가 있을 때만 `-x` 부착 | **통과** |
| 초기화 실패 시 종료 상태 1 | **통과** (소스 확인: `if (!rc.Init()) return 1;`) |
| 실제 ROOT 헤더로 빌드·링크 | **미검증** (스텁 헤더 사용) |
| 실제 DAQ 하드웨어에서 실행 | **미검증** |
| 하드웨어에서 `rcsupervisor` 로테이션·복구 | **미검증** |

컴파일 검증에는 실제 ROOT 시그니처를 재현한 스텁 헤더를 사용했습니다.
`TSystem::AccessPathName()`의 반전된 반환 규약과 `TObject::Write()`의 const/non-const
오버로드까지 동일하게 맞추었습니다.

---

## 11. 라이선스 및 출처

[Sang-Yong/RENE-daq](https://github.com/Sang-Yong/RENE-daq)의 CUPDAQ / RENE DAQ
소프트웨어에서 파생되었습니다. `OnlConsts.hh`의 프로토콜 상수는
`DAQ_cup/DAQRC/onlconsts.py`를 그대로 반영합니다. 상위 프로젝트의 라이선스를
따르십시오.
