# rcterm / rcsupervisor 상세 매뉴얼

대상 환경 : Rocky Linux 9.8 / GCC 11.5.0 / CMake 3.31.8 / CERN ROOT / 단일 PC

---

## 1. 이 프로그램이 하는 일

`DAQ_cup/DAQRC/rc.py` 는 하드웨어를 직접 제어하지 않는다. 실제 제어는
`CUPDAQ` 가 빌드한 실행파일(`tcb`, `daq`, `merger`)가 담당하고,
`rc.py` 는 다음 3가지만 한다.

| 역할 | 방식 |
|---|---|
| Boot | config 의 `SERVER` 라인을 읽어 `executedaq.sh` 를 노드별로 실행 |
| Control | TCB 소켓(기본 `localhost:7809`)에 32바이트 명령 전송 |
| Monitor | 각 DAQ 소켓에 `QUERYRUNINFO` / `QUERYTRGINFO` 를 보내 통계 수집 |

그러므로 `rcterm` 은 **네트워키 프로토콜 클라이언트 + 상태기계 + 화면 출력**만
재구현한 것이고, 하드웨어 드라이버를 다시 쓴 것이 아니다. `CUPDAQ`
라이밌러리에 전혀 링크하지 않는다.

### 검증된 프로토콜 (`onlconsts.py` / `onlutils.py` 실측)

메시지는 **32바이트 = little-endian 8바이트 unsigned 4개**.

```
[m1: 0..7][m2: 8..15][m3: 16..23][m4: 24..31]
```

| 명령 | 값 | 설명 |
|---|---|---|
| `kCONFIGRUN` | 1 | 하드웨어 config 적용 |
| `kSTARTRUN` | 2 | 수집 시작 |
| `kENDRUN` | 3 | 런 종료 |
| `kEXIT` | 4 | 프로세스 종료 |
| `kQUERYDAQSTATUS` | 10 | 상태 반환 |
| `kQUERYRUNINFO` | 12 | m2=subrun, m3=start, m4=end |
| `kQUERYTRGINFO` | 14 | m1=이벤트 수, m2=경과시간[ns] |
| `kQUERYMONITOR` | 21 | 모니터 가능 여부 |

**상태는 정수가 아니라 비트마스크다.** `status & (1 << state)`.
Down=0, Booted=1, Configured=2, Running=3, RunEnded=4, ProcEnded=5,
Warning=6, **Error=7**.

---

## 2. 원본 대별 수정 내역

새 프로그램은 원본 `rc.py` / `rcterm.py` 의 다음 문제를 사전에 회피하거나
고친 것이다.

| 원본 문제 | 새 프로그램 |
|---|---|
| `rcterm.py` 가 없는 `onlutils.send_message()` 를 5회 호출 → `AttributeError` | 처음부터 다시 작성 |
| `rcterm.py` 가 `executenulldaq.sh`(테스트용) 를 호출, split time 미전달 | `executedaq.sh` + `-p` 전달 |
| `rc.py` : `SplitTimeConfig.setText(int)` → `TypeError` | 해당 없음 (GUI 없음) |
| `rc.py` : 정렬키가 name 이 아니라 `dopt` 문자열 → AADC 사용시 TCB 가 마지막이 아님 | `MERGER → ADC → TCB` 를 mode 로 명시 강제 |
| `rc.py` : `name[0].lower()` 로 ADC 종류 판정 → `MERGER` 를 `-m`(MADC) 로 오인 | `FADC/SADC/...` 부분문자열 판정 → `FADCMERGER`/`SADCMERGER` 정확 분리 |
| 주석 `[s] -> [m]` 과 코드(`*60`, 분→초) 모슴 | 분 입력 → 초 변환을 명시 |
| PyQt5 / pydblite 의존 | 제거 (sqlite3 CLI 로 대진) |
| `$RAWDATA_DIR/LOG` 이 없으면 DAQ 가 조용히 죽음 | 부팅 전 `mkdir -p` |

---

## 3. 설치된 파일 이름 통보

`install/bin/` 에 들어있는 것은 `daqfadc` 가 아니다. 실제로는

```
daq  merger  tcb  stddaq  nulldaq  nullmerger  nulltcb  usbreset
executedaq.sh  executenulldaq.sh
```

이고, `executedaq.sh` 가 `-d/-m/-t` 를 `daq/merger/tcb` 로 맵핑한다.

```bash
-d) EXE="daq"    ;;
-m) EXE="merger" ;;
-t) EXE="tcb"    ;;
...
${ONLDAQ_DIR}/bin/$EXE $DAQOPT > ${RAWDATA_DIR}/LOG/${DAQNAME}_${RUNNUMSTR}.log 2>&1 &
```

이 리다이렉트 대상 때문에 `$RAWDATA_DIR/LOG` 가 반드시 있어야 한다.

### `-p` (split time) 지원 여부

`CUPDAQ/DAQ/DAQ/daqopt.hh` 에 이미 정의되어 있다.

```cpp
{"splitting-time", required_argument, nullptr, 'p'},
const char * const short_options = "c:o:d:n:t:r:p:q:v:fgmishx";
int sptime;
void init() { ... sptime = 60 * 60; }     // 기본 3600초
```

그리고 `CUPDAQ/DAQ/test/tcb.cc` 에서

```cpp
DAQ->SetOutputSplitTime(option.sptime);
```

으로 사용된다. 즉 `-p` 는 지원되며, `rcterm --split-time <분>` 이
`-p <초>` 로 변환되어 TCB 에 전달된다.

> 만야 설치된 바이러리가 구버전이라 `-p` 를 모른다면 `--no-tcb-split` 을
> 사용하십시오. 그러면 `-p` 를 붙이지 않고 TCB 내장 기본값(3600초)을 사용합니다.

---

## 4. 런 카탈로그 DB 연동

`create_runcatalog_db.py` 스키마 :

```sql
CREATE TABLE runcatalog (
  runnum  INTEGER PRIMARY KEY AUTOINCREMENT,   -- rowid 별칭 = run number
  runtype TEXT, rundesc TEXT, shift TEXT, config TEXT,
  stime   TEXT, etime   TEXT,
  onlbit  INTEGER, offbit INTEGER, runlog TEXT
  -- nfadc/tfadc, nsadc/tsadc, niadc/tiadc 는 생성 시 옵션(-f/-s/-i)으로만 추가된다
);
```

`runnum` 이 `INTEGER PRIMARY KEY` → **rowid 별칭**이므로
`INSERT` 후 `SELECT last_insert_rowid()` 를 하면 pydblite 의 `table.insert()`
반환값과 정확하게 동일한 run number 를 얻는다. 즉 스키마 호환이 보장된다.

`nfadc` 등은 DB 생성 옵션에 따라 없을 수 있어서, `PRAGMA table_info` 로
컬럼 존재를 먼지 확인한 뒤에만 UPDATE 한다.

카탈로그 조회 :

```bash
sqlite3 -header -column /Data/runcatalog.db \
  "SELECT runnum,shift,runtype,stime,etime,onlbit FROM runcatalog
   ORDER BY runnum DESC LIMIT 10;"
```

---

## 5. heartbeat 파일 포맷

`rcterm --heartbeat FILE` 가 매 갱신마다 쓰는 key=value 파일이다.
tmp 에 쓴 뒤 `rename()` 하므로 부분적으로 읽힐 일이 없다.

```
time=1786554086          # epoch. 이 값이 오래되면 rcterm 이 멈춘 것
pid=12345                # 이 파일을 쓴 rcterm 프로세스의 PID
phase=running            # booting|booted|configured|running|ending|ended|error|failed|notrunning
run=123
subrun=45
state=Running
statebit=3
error=0
status=8
daqtime=1234.5
totev=98765              # 전역 이벤트 합 → stall 감지용
ndaq=2
daq0=FADCDAQ n=98700 sr=321.4 ar=320.6
daq1=SADCDAQ n=65 sr=4.6 ar=4.6
```

이 파일은 감시자 전용이 아니다. 샤/파이섬으로도 그대로 파싱해서 사용할 수 있다.

```bash
# 현재 rate 한 줄로 보기
awk -F= '/^daq[0-9]+=/{print $2}' /Data/LOG/rcterm.hb
```

---

## 6. 감시자의 진단 기준

`rcsupervisor` 는 `--check-period`(기본 600초) 마다 아래를 살핀다.
쉽게 말해 **단으로 감지하고 단으로 복구한다.**

| # | 점검 | 이상 판정 |
|---|---|---|
| 1 | heartbeat 가 읽힐지 / `time=` 가 새로운가 | `--stale-limit`(300s) 초과 → rcterm 멈춤 |
| 2 | `error=` 바이트 | 1 → DAQ 에러 |
| 3 | `phase=running` 인데 `state` 가 Running 이 아님 | 이상 |
| 4 | TCB 소켓에 직접 `QUERYDAQSTATUS` | 연결 실패 / 무은답 / ERROR 바이트 / 미가동 |
| 5 | `totev` 가 증가하는가 | `--stall-grace`(1800s) 동안 정지 → 이상 |

기동 구간(`--boot-grace`, 기본 300초)은 3~5를 유예한다.

### 이상 시 복구 순서

```
1) rcterm PID 에만 SIGTERM        → ENDRUN→EXIT, DB 기록하고 정상 종료 시도
2) --grace (180s) 안에 안 끝나면  → 프로세스 그룹에 SIGKILL
3) pkill -f "<bindir>/{tcb,merger,daq}"  → 남은 DAQ 정리
4) --settle (10s) 대기
5) --backoff (30s) 대기 후 새 run 번호로 재시작
```

**중요 : SIGTERM 은 그룹이 아니라 rcterm 단일 PID 에만 보낸다.**
그룹에 보내면 `daq/tcb/merger` 가 쓰기 도중에 죽어 마지막 파일이 상한다.

`--max-consec-fail`(기본 5) 번 연속 실패하면 감시자도 종료한다.
무한 재시작 루프로 쓰레기 런을 대량 생산하는 상황을 막기 위한 장치다.

---

## 7. 런 로테이션의 dead time

프로토콜에 "실행 중 run number 변경" 명령이 없다. run number 는
`executedaq.sh -r <run>` 으로 프로세스 기동 시점에 고정된다. 즉
런 번호를 바꾸려면 프로세스를 내렸다 올려야 한다.

```
[run N 수집 24h] → ENDRUN → EXIT → cleanup → boot → CONFIG → START → [run N+1]
                    └────── dead time (보통 10~40초) ──────┘
```

감시자 로그에 매 사이클마다 기록된다.

```
2026-08-13 09:00:12 [SUP] cycle 2 finished : exit=code 0  (rotation)
```

dead time 을 0 으로 해야 한다면 런을 나누지 않고 서브런만 사용해야 한다.

```bash
# 런 1개, 1분마다 서브런으로 분할 → dead time 없지만 카탈로그는 1행
rcterm --params config/rcterm.params --max-runs 1 --run-length 8760 --split-time 1
```

| 방식 | dead time | 카탈로그 | 권장 상황 |
|---|---|---|---|
| 24h 로테이션 (기본) | 사이클당 10~40s | 하루 1행 | 일반 운용 |
| 서브런만 | 0 | 1행에 누적 | dead time 을 절대 못 만드는 경우 |

---

## 7.5 `--params` 는 위치 기반이다

`--params` 파일의 내용은 **인자 배열에서 `--params` 가 있던 그 자리에 그대로
펼쳐진다.** 따라서 **뒤에 오는 것이 이긴다.**

```bash
rcterm --shift A --params f.params      # f.params 의 shift 가 이긴다
rcterm --params f.params --shift A      # 커맨드라인의 --shift A 가 이긴다
```

**`--params` 는 항상 맨 앞에 둘 것.** `rcsupervisor` 도 이 규칙에 의존해서
params 파일 뒤에 자기 설정을 덧붙인다.

```
rcterm --params <file> --max-runs 1 --run-length 24.016667 --quiet --heartbeat <hb>
       └ 사용자 설정 ┘ └──────── 감시자가 덮어쓰는 로테이션 설정 ────────┘
```

그래서 `rcterm.params` 안의 `max-runs` / `run-length` 는 감시자가 관리할 때
무시된다. 반대로 `heartbeat` 경로는 두 params 파일에서 **반드시 같아야** 한다.
다르면 감시자가 영원히 stale 로 판정해 무한 재시작한다.

---

## 8. 문제 해결

| 증상 | 원인 / 조치 |
|---|---|
| `a DAQ is already listening on ...:7809` | 이전 런의 `daq/tcb/merger` 가 살아있다. 새 tcb 가 포트를 잡지 못하고 rcterm 이 옛 런에 붙는 것을 막은 것. `scripts/killdaq.sh` 로 정리 후 재시작 |
| `not found or not executable : .../executedaq.sh` | `--onldaqdir` / `--bindir` 확인. `install/bin/` 직하여야 함 |
| `cannot connect to TCB` | 대부분 부팅 실패. `$RAWDATA_DIR/LOG/TCB_*.log` 확인. `--boot-timeout 180` 으로 늘려보기 |
| `no SERVER line found` | config 의 `SERVER` 라인에 `#` 이 들어있으면 rc.py 와 동일하게 생략된다. 라인 끝 주석도 안 된다 |
| `cannot determine ADC type from name` | ADC 이름에 `FADC`/`SADC` 등이 포함되어야 함 |
| `merger has no ADC kind in its name` | `MERGER` → `FADCMERGER` / `SADCMERGER` 로 이름 변경, 또는 `--merger-type` |
| `two mergers of the same kind` | 같은 종류 merger 가 2개. config 정리 필요 |
| `duplicated endpoint` | 같은 ip:port 를 다른 노드가 쓰고 있다 |
| `[WARN] port 22 is the SSH port` | config 의 merger 포트가 22 로 되어있다. 실사용하려면 고칠 것 |
| `table 'runcatalog' not found` | `create_runcatalog_db.py` 로 만든 DB 가 아님. 또는 `--no-db --run N` |
| `sqlite3 not found` | `sudo dnf install -y sqlite` |
| `timeout waiting for Configured` | 하드웨어 config 값 문제. DAQ 로그 확인 |
| 화면이 깨짐 / 리다이렉트 시 지더부 | `--quiet` 사용 (감시자는 자동으로 붙인다) |
| 감시자가 계속 재시작함 | `--stall-grace` 가 짧지 않은지 확인. 지리드 런이면 `--no-stall-check` |
| 감시자가 이상을 못 잡음 | `heartbeat` 경로가 rcterm/rcsupervisor 에서 동일한지 확인 |

---

## 9. 상태 수동 점검 명령

```bash
# 현재 DAQ 프로세스
scripts/killdaq.sh -n            # 드라이런 : 목록만 보기

# heartbeat 나이
date +%s; grep '^time=' /Data/LOG/rcterm.hb

# 감시자 로그
tail -f /Data/LOG/rcsupervisor.log

# 모니터링 TTree
root -l /Data/LOG/rcterm_mon.root
root [1] daqmon->Draw("srate[0]:ctime", "", "l")
root [2] daqnames->GetTitle()
```
