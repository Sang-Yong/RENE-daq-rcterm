# CLAUDE.md — RENE_DAQ_term 작업 지침

이 파일은 Claude Code가 매 세션 자동으로 읽는다.
선행 세션(웹 챗)에서 확정된 사실과 잔여 작업이 전부 여기 있다.
**추측하지 말고 이 문서의 검증 상태를 신뢰하되, "미검증"으로 표시된 것은 반드시 실측하라.**

---

## 0. 이 프로젝트가 무엇인가

`RENE-daq/DAQ_cup/DAQRC/rc.py`(PyQt5 GUI 런컨트롤)를 **CERN ROOT 기반 C++17
텍스트 런컨트롤**로 재작성한 것. 저장소: `github.com/Sang-Yong/RENE-daq-rcterm`

**핵심 전제 — rc.py는 하드웨어를 직접 제어하지 않는다.** 하드웨어 제어는 CUPDAQ
바이너리(`daq`, `merger`, `tcb`)가 한다. rc.py가 한 일은 세 가지뿐이다:
config의 `SERVER` 라인 파싱 → 노드별 `executedaq.sh` 실행 / TCB 소켓에 32바이트
명령 전송 / 각 DAQ 소켓 폴링. **하드웨어 드라이버는 한 줄도 다시 쓰지 않았다.**

산출물 2개:
- `rcterm` — 런 1회 (boot → config → start → monitor → end)
- `rcsupervisor` — N시간(기본 24h) 로테이션 + 10분 주기 진단/자동 복구

대상: Rocky Linux 9.8 / GCC 11.5.0 / CMake 3.31.8 / **단일 PC**
(`kISREMOTEDAQ=False` 확인 → ssh/scp 코드 완전 제거, 로컬 `cp` + `gSystem->Exec`)

## 1. 빌드

```bash
<<<<<<< HEAD
source /usr/local/bin/thisroot.sh
source /home/frontend/DAQ/DAQ_cup/cupdaq_env.sh
=======
source /opt/root/bin/thisroot.sh
>>>>>>> 967823e2c503573ecd56ebb2f42251f03aff103e
./build.sh                       # → install/bin/{rcterm,rcsupervisor}
```
ROOT 컴포넌트는 **Core, RIO, Tree만**. Gui/Gpad/Graf 불필요(headless ROOT 충분).
런타임에 `sqlite3` CLI 필요(없으면 `--no-db --run N`).

CMake 없이:
```bash
g++ -std=c++17 -O2 -Wall -Isrc -o rcterm src/rcterm.cc src/RunControl.cc \
    $(root-config --cflags --libs)
g++ -std=c++17 -O2 -Wall -Isrc -o rcsupervisor src/rcsupervisor.cc \
    $(root-config --cflags --libs)
```

## 2. 파일 구성과 의존 관계

```
src/OnlConsts.hh    2.3k   프로토콜 상수 (onlconsts.py 미러)
src/OnlSocket.hh    4.7k   32바이트 소켓 클라이언트 (header-only)
src/RunControl.hh   4.7k
src/RunControl.cc  39.5k   config파싱 / 상태머신 / DB / 화면출력 / TTree
src/rcterm.cc       8.0k
src/rcsupervisor.cc 23.9k
config/{rcterm.params.example, rcsupervisor.params.example, SERVER-block.example}
scripts/{killdaq.sh, rcsupervisor.service.example}
docs/MANUAL.md      README.md(26k, 영)      README.ko.md(28k, 한)
```

```
OnlConsts.hh ← OnlSocket.hh ← RunControl.hh ← {RunControl.cc, rcterm.cc}
rcsupervisor.cc → OnlConsts.hh + OnlSocket.hh 만 include (RunControl.hh 제외)
```

**`rcsupervisor`는 `RunControl.cc`를 링크하지 않는다. 의도적이다.** 상태머신 버그가
감시자까지 끌고 내려가면 자동 복구라는 목적 자체가 무너진다. 이 분리를 깨지 말 것.

## 3. 프로토콜 — 소스 실측으로 확정. 수정 금지

- 메시지 = **32 byte = 8-byte little-endian unsigned × 4** (`m1~m4`)
- 명령: `CONFIGRUN=1 STARTRUN=2 ENDRUN=3 EXIT=4 QUERYDAQSTATUS=10
  QUERYRUNINFO=12 QUERYTRGINFO=14 QUERYMONITOR=21`
- **상태는 정수가 아니라 비트마스크**: `status & (1 << state)`
  `Down0 Booted1 Configured2 Running3 RunEnded4 ProcEnded5 Warning6 Error7`
- `QUERYRUNINFO` → `m2`=subrun `m3`=start `m4`=end
- `QUERYTRGINFO` → `m1`=이벤트수 `m2`=경과시간 **[ns]**
- 사이트 기본값: `localhost:7809`, `kONLDAQ_DIR=/home/frontend/DAQ/DAQ_cup/install`,
  `kRAWDATA_DIR=/Data`, `kSPLIT_TIME=180s`, `kRUNCATALOGDBFILE=/Data/runcatalog.db`

**실행 파일명은 `daq` / `merger` / `tcb`** (daqfadc 아님). `executedaq.sh`가
`-d/-m/-t`로 매핑. `killdaq.sh`와 supervisor `pkill` 패턴도 이 이름 기준.

**`tcb -p`(splitting-time)는 지원됨.** `daqopt.hh`에 `{"splitting-time",
required_argument, nullptr, 'p'}`, 기본 3600초, `tcb.cc`가
`SetOutputSplitTime(option.sptime)`. `--split-time <분>` → `-p <초>` 전달.
구버전 대비 탈출구로 `--no-tcb-split` 제공.

**DB**: `runnum INTEGER PRIMARY KEY AUTOINCREMENT` = rowid 별칭이므로
`INSERT ...; SELECT last_insert_rowid();` 가 pydblite `table.insert()` 반환값과
동일. 기동 시 `PRAGMA table_info(runcatalog)`로 존재하는 컬럼만 기록
(`-f/-s/-i` 없이 만든 DB에도 안전).

**숨은 함정**: `executedaq.sh`가 `${RAWDATA_DIR}/LOG/`로 리다이렉트한다.
**이 디렉터리가 없으면 DAQ가 조용히 죽는다.** rcterm이 부팅 전
`$RAWDATA_DIR/{LOG,CONFIG}`를 `mkdir -p` 한다.

## 4. 검증 상태 — 여기서부터 작업 시작

### 4.1 검증 완료 ✅ (재검증 불필요)

| 항목 | 결과 |
|---|---|
| 컴파일 g++14.2 `-Wall -Wextra` | 소스 경고 **0** (스텁 헤더 경고만 있었음) |
| 링크 | rcterm 158,896B / rcsupervisor 80,816B |
| 이중 머저 분기 | `FADCMERGER→-f`, `SADCMERGER→-s` |
| 부팅 순서 | `MERGER → ADC → TCB` |
| split time | `--split-time 1` → TCB `-p 60` |
| 방어로직 9종 | 전수 통과 (§4.2) |
| **`[FATAL]` 종료코드** | FATAL 11종 전부 `exit=1`, 사이클실패 `exit=2`, 정상 `0` |
| **sqlite3 run 번호 발급** | seed DB에서 `run=2` 정상 발급 실측 |
| **heartbeat 파일** | `pid=` 포함 12줄, `.tmp`→`rename()` 원자적 확인 |
| **`--params` 로딩** | 동작 확인. 단 **위치 기반** (§5.6) |
| 라이브 부팅 경로 | LOG/CONFIG 자동생성, config→`CONFIG/000002.config` 복사 확인 |
<<<<<<< HEAD
| **실제 ROOT 6.28/04 빌드** | clean build 성공, 에러 0. §4.4 스텁결함 5종 전부 무관함 확인 (2026-08-13) |
| **rcterm 설정오류 종료코드** | `--config /nonexistent.config` → `exit=1` 실측 확인 |
| **rcsupervisor 테스트 H(로테이션)** | run=900 clean exit → run=901 재시작 → `exit=0`, SIGTERM 정상 전달, 좀비 없음 |
| **rcsupervisor 테스트 I(stale 복구)** | 12초에 stale 감지(기대 ~11초) → SIGTERM → clean exit → run=951 재시작. 좀비 없음 |
=======
>>>>>>> 967823e2c503573ecd56ebb2f42251f03aff103e

종료코드가 0/1/2 세 값으로 갈리는 것은 설계상 이상적이다 — supervisor가
"설정 오류(재시작 무의미)" / "런 실패(재시작 가치 있음)" / "정상"을 구분할 수 있다.
**이 구분을 깨는 변경을 하지 말 것.**

### 4.2 방어로직 9종 (전부 실측 통과)

| 시나리오 | 기대 |
|---|---|
| 무종류 `MERGER` + ADC 2종 | `[FATAL] ... has no ADC kind ... 2 ADC kinds` |
| 위 + `--merger-type fadc` | `[INFO] forced to FADC` 후 정상 |
| 무종류 `MERGER` + ADC 1종 | `[INFO] inferred as FADC` |
| 동종 머저 2개 | `[FATAL] two mergers of the same kind` |
| `ip:port` 중복 | `[FATAL] duplicated endpoint` |
| 머저 포트 22 | `[WARN] port 22 is the SSH port` |
| 종류 불명 ADC | `[FATAL] cannot determine ADC type` |
| 대응 ADC 없는 머저 | `[WARN] no matching ADC` + **`-x` 미부착** |
| `--no-tcb-split` | `(TCB -p : DISABLED)`, `-p` 제거 |

### 4.3 미검증 ⚠️ — 잔여 작업 3건

| # | 항목 | 방법 |
|---|---|---|
<<<<<<< HEAD
| 1 | **실 하드웨어 실행 — 최대 리스크** | dry-run → 2사이클 단축 → 1회전 관찰 |
=======
| 1 | **실제 ROOT 헤더로 빌드** | `./build.sh` — 선행 검증은 전부 스텁 헤더 기반이었음 |
| 2 | **rcsupervisor 사이클/복구** | §6 테스트 H·I |
| 3 | **실 하드웨어 실행 — 최대 리스크** | dry-run → 2사이클 단축 → 1회전 관찰 |
>>>>>>> 967823e2c503573ecd56ebb2f42251f03aff103e

### 4.4 스텁 결함 5종 (오해 금지)

선행 세션은 ROOT 부재로 스텁 헤더 9종을 썼다. 컴파일이 막힌 API 5개는
**소스 결함이 아니라 스텁의 불완전함**이며, 전부 실제 ROOT에 존재한다:
`TString::operator const char*`, `EAccessMode`, `TSystem::WorkingDirectory`,
`TObject::Write() const` 오버로드, `TFile::Open()`.
**오히려 소스가 실제 ROOT API를 정확히 사용한다는 방증이다.**
실제 ROOT 빌드에서 이들 관련 에러가 나면 그때는 진짜 문제이므로 보고할 것.

## 5. 설계 판단과 근거 ★ 되돌리기 전에 반드시 읽을 것

**5.1 부팅 순서를 문자열 정렬이 아니라 노드 mode로 강제한다.**
rc.py의 `sortfunc(e)`는 `e[2]`를 반환하는데 이는 노드 이름이 아니라 `dopt`
문자열이다. TCB의 `dopt`는 `-d`로 시작해 `pop(0)`이 우연히 맨 뒤로 보내지만,
AMOREADC는 `-a`로 시작하고 `'a' < 'd'` 이므로 **TCB 대신 AADC가 마지막**이 된다.
그러면 TCB가 클라이언트보다 먼저 떠서 접속이 깨진다.

**5.2 ADC 종류를 `name[0]`이 아니라 부분문자열로 판정한다.**
rc.py는 `name[0].lower()`를 쓴다. 이름이 `MERGER`면 `m` → MADC로 오분류.
현재는 `FADC/SADC/IADC/GADC/AMOREADC/AADC/MADC` 부분문자열 탐색. 판정 불가 시
**조용히 넘기지 않고 에러로 정지**한다(잘못된 플래그가 하드웨어로 가는 것보다 낫다).

**5.3 SIGTERM은 프로세스 그룹이 아니라 rcterm PID에만 보낸다.**
`executedaq.sh`가 `daq/tcb/merger`를 백그라운드로 띄우므로 같은 그룹에 들어간다.
그룹에 SIGTERM을 보내면 **DAQ가 쓰기 도중 죽어 마지막 파일이 상한다.** 정상 경로는
rcterm이 `EXIT` 명령으로 DAQ를 얌전히 내리게 하는 것이고, 강제 종료(SIGKILL +
그룹 + `pkill`)는 **복구 경로에서만** 쓴다.

**5.4 pydblite 대신 sqlite3 CLI 서브프로세스.** C++에서 pydblite를 못 쓴다.
`libsqlite3` 링크가 정석이나 ROOT 빌드 구성에 따라 번거로워 CLI로 갔다. 개선 대상.

**5.5 런 로테이션 dead time(10~40초)은 0으로 만들 수 없다.** 프로토콜에 "실행 중
run number 변경" 명령이 **없다**. run number는 `executedaq.sh -r`로 프로세스 기동
시점에 고정된다. dead time 0이 필요하면 런을 나누지 말고 서브런만 쓸 것:
`--max-runs 1 --run-length 8760 --split-time 1`.

**5.6 `--params`는 위치 기반이다.** `--params` 파일 내용을 인자 배열의 그 위치에
펼치므로 **"뒤에 오는 것이 이긴다"**. `--shift A --params f` → 파일이 이김.
`--params f --shift A` → CLI가 이김. **`--params`는 항상 맨 앞에 둘 것.**
(README/MANUAL에 이 설명이 아직 없다 → §6 작업 3)

**5.7 dry-run은 heartbeat를 만들지 않는다.** 첫 기록이 `booting` 단계이고 dry-run은
그 전에 빠져나간다. 정상 동작이나 감시자 연동을 dry-run으로 테스트할 수 없다.

## 6. 잔여 작업 큐 (우선순위 순)

### 작업 1 — 실제 ROOT 빌드 검증 ★최우선
```bash
<<<<<<< HEAD
source /usr/local/bin/thisroot.sh
source /home/frontend/DAQ/DAQ_cup/cupdaq_env.sh
=======
source /opt/root/bin/thisroot.sh
>>>>>>> 967823e2c503573ecd56ebb2f42251f03aff103e
rm -rf build install && ./build.sh 2>&1 | tail -60
ls -la install/bin/
install/bin/rcterm --help | head -30
```
에러가 나면 §4.4를 참고해 스텁 문제와 진짜 문제를 구분할 것.

### 작업 2 — rcsupervisor 로테이션/복구 검증
가짜 rcterm을 자식으로 물려 **하드웨어 없이** 로직만 검증한다.
`/tmp/suptest/fake_rcterm.sh`를 만들 것: `--heartbeat`, `--run` 인자를 파싱하고,
1초마다 heartbeat 12줄(`time/pid/phase=running/run/subrun/state=Running/
statebit=3/error=0/status=8/daqtime/totev/ndaq`)을 `.tmp`→`mv`로 쓰고,
`trap ... TERM`으로 clean exit하며 `$TRACE`에 `run=`과 SIGTERM 수신을 기록.
환경변수 `FAKE_MODE=stale`이면 3초 후 heartbeat 갱신을 멈춰 고장을 모사.

- **테스트 H (로테이션)**: `FAKE_MODE=good`, `--run-length 0.0056 --margin 1
  --max-cycles 2 --check-period 5 --stale-limit 20 --boot-grace 3
  --no-stall-check --no-socket-check --grace 5 --settle 1 --backoff 1
  --no-db --run 900`
  → 기대: `run=900` clean exit → `run=901` 재시작 → supervisor `exit=0`.
  **SIGTERM이 자식에게 정확히 전달되어 clean exit 하는지가 핵심.**
- **테스트 I (stale 복구)**: `FAKE_MODE=stale`, `--run-length 1 --check-period 4
  --stale-limit 8 --boot-grace 3 --grace 4 --run 950`
  → 기대: ~11초에 stale 감지 → SIGTERM → `run=951` 재시작.
  **종료 후 `pgrep -af fake_rcterm.sh`가 비어야 한다**(좀비 남으면 복구 누수).

실제 옵션명은 `rcsupervisor --help`로 확인할 것(`--rcterm` 경로 지정 옵션 존재 여부 포함).

<<<<<<< HEAD
### 작업 3 — 한글 텍스트 깨짐 수정 ✅ (2026-08-13 완료)
동작 무관이나 사용자가 매일 보는 화면이다.

지정된 sed 전부 적용 완료. 원 grep 패턴은 `src config docs README*.md` 전체에서 0건.
추가로 `docs/MANUAL.md`, `src/RunControl.cc`에도 같은 패턴이 남아있어 함께 수정함
(모니타→모니터, 카타로그→카탈로그, 부톥→부팅, 부분벇본→부분문자열, 버긎가→버그가).
`src/rcsupervisor.cc` 한글 주석 54줄 전수 육안 검토 후 `횝득`→`획득` 추가 수정.

**미해결 1건**: `src/rcsupervisor.cc:8` `"자식이 버지면 새 run 번호로 다시 실행한다"` —
`버지면`이 문법에 맞지 않으나 원래 의도한 단어(죽으면/종료되면 등)를 추측으로 바꾸면
기술 문서 의미가 왜곡될 위험이 있어 **수정하지 않고 보류**. 사용자 확인 필요.

`README.ko.md`(한글 줄 341개)는 원 grep 패턴 기준으로는 0건이었으나 줄 단위 육안
전수 검토는 아직 하지 않았다. 필요시 추가 요청할 것.
=======
### 작업 3 — 한글 텍스트 깨짐 수정
동작 무관이나 사용자가 매일 보는 화면이다.
```bash
sed -i 's/입력항에 1:1 대원/입력란에 1:1 대응/g' src/rcterm.cc config/rcterm.params.example
sed -i 's/통식으로/형태로/; s/전용이부/전용이며/; s/복관이 함족된다/복구가 포함된다/' src/rcterm.cc
sed -i 's/작성답/작성법/; s/아래 토색을/아래 예시를/; s/부분벇본/부분문자열/;
        s/에러로 멈진다/에러로 멈춘다/; s/실제로 바지 않는/실제로 쓰지 않는/;
        s/부톥한다/부팅한다/' config/SERVER-block.example
sed -i 's/카타로그/카탈로그/g; s/모니타/모니터/g; s/설진본/설치본/' config/rcterm.params.example
# 전수 확인 — 결과가 비어야 완료
grep -rn '대원\|작성답\|벇본\|멈진다\|부톥\|카타로그\|모니타\|설진본\|통식\|전용이부\|함족' \
     src config docs README*.md
```
`rcsupervisor.cc`, `RunControl.cc`, `docs/MANUAL.md`, `README.ko.md`는 아직 전수
검사되지 않았다. 위 `grep`에 걸리는 것 외에도 문맥상 어색한 한글이 있으면 고칠 것.
>>>>>>> 967823e2c503573ecd56ebb2f42251f03aff103e

### 작업 4 — README/MANUAL에 `--params` 위치 기반 규칙 명시 (§5.6)

### 작업 5 — 실패 런 DB 고아 행 처리
run 번호는 부팅 **전에** 발급되므로 부팅 실패 시 `stime/etime/onlbit`가 NULL인
행이 남는다(rc.py도 동일 구조라 회귀는 아님). 24h 로테이션 중 반복 실패하면 쌓인다.
→ 실패 시 `UPDATE runcatalog SET onlbit=0, runlog='boot failed' WHERE runnum=N`.

### 작업 6 — 개선 백로그 (여유 있을 때)
- `libsqlite3` 링크 + prepared statement (현재는 임시파일 + 셸 호출, 이스케이프만)
- 모니터 소켓 런당 1회만 오픈 → 런 도중 끊기면 재연결 없음. 주기적 재연결 필요
- `OnlSocket::Connect()` 소켓 타임아웃 3초 하드코딩 → 옵션화
- heartbeat 락 없음. `rename()`은 원자적이나 두 rcterm이 같은 경로를 쓰는 걸 못 막음
  → PID 파일 + `flock`
- rate가 벽시계가 아니라 DAQ 보고 시간 기준 → ns 카운터 정지 시 순간 rate 미정의
- 단위 테스트 없음. config 파싱 / 머저 판정 / 비트마스크 디코딩은 순수 함수라 쉽다

### 작업 7 — 실 하드웨어 검증 (사용자와 함께)
```
① install/bin/rcterm --params config/rcterm.params --dry-run
② rcterm --max-runs 1 --run-length 0.05        (단일 단축 런)
③ rcsupervisor --run-length 0.0833 --margin 2 --check-period 60 --max-cycles 2
④ tmux new -s daq && rcsupervisor --params config/rcsupervisor.params
```

## 7. rc.py 원본 버그 7종 (rcterm에서 수정됨 — 회귀시키지 말 것)

1. `SplitTimeConfig.setText(self.SplitTime)` — int 전달 → `TypeError`
2. AMOREADC 존재 시 부팅 순서 붕괴 (§5.1)
3. `MERGER`가 MADC로 오분류 (§5.2)
4. 기존 `rcterm.py`는 **실행 자체가 불가** — 존재하지 않는
   `onlutils.send_message()` / `onlconsts.kSOFTWARE_VER` 호출,
   `executenulldaq.sh` 실행, split time 미전달
5. 주석 `# WJ: [s] -> [m]`이 코드(`SplitTime * 60`, 분→초)와 반대
6. `$RAWDATA_DIR/LOG` 미생성 → DAQ 조용히 사망 (§3 숨은 함정)
7. `test_wj_merger.config`의 `MERGER` 포트가 **22(SSH)** 이고 이름에 ADC 종류 없음
   → 머저 쓰기 전에 `FADCMERGER`/`SADCMERGER`로 개명 + 포트 수정 필요

## 8. 작업 규칙 (Claude Code 준수 사항)

- **DAQ가 실행 중인 운영 디렉터리에서 소스를 수정하지 말 것.** 별도 클론에서
  수정·빌드·커밋하고, 운영 디렉터리는 `git pull`만 한다.
- 하드웨어를 건드리는 실행은 **반드시 `--dry-run`으로 먼저** 확인하고,
  실제 실행은 사용자 승인 후에만.
- `pkill`, `killall`, `kill -9`를 임의로 실행하지 말 것. 실행 중 DAQ가 죽으면
  데이터 파일이 손상된다. 필요하면 `scripts/killdaq.sh`를 사용자에게 안내할 것.
- 프로토콜 상수(§3)와 설계 판단(§5)은 근거가 있다. 바꾸려면 먼저 이유를 설명할 것.
- 커밋 메시지는 기존 스타일을 따를 것(`docs:`, `fix:`, 영문, 명령형).
- 검증하지 않은 것을 "검증했다"고 쓰지 말 것. 이 문서의 ✅/⚠️ 구분을 유지하라.

## 9. 디버그 플레이북

```
1. install/bin/rcterm --help                 바이너리 정상?
2. rcterm --params ... --dry-run              명령 조립 정상?
3. dry-run 출력의 executedaq.sh 한 줄을 손으로 실행
4. ls -la $RAWDATA_DIR/LOG/                   DAQ 로그 생겼나?
5. cat $RAWDATA_DIR/LOG/TCB_*.log             TCB 살아있나?
6. ss -ltnp | grep 7809                       TCB listen 중인가?
7. rcterm 실전 1회 (--max-runs 1 --run-length 0.05)
8. rcsupervisor 2사이클 단축 테스트
9. 24h 로테이션 1회전 관찰
```

## 10. 운용 주의점

- **heartbeat 경로는 `rcterm.params`와 `rcsupervisor.params`에서 반드시 동일.**
  다르면 감시자가 영원히 stale로 보고 무한 재시작한다.
- 배경/지리드 런처럼 이벤트가 드문 측정은 `--stall-grace`를 크게 하거나
  `--no-stall-check`. 안 그러면 정상 런을 이상으로 판정해 재시작한다.
- 장시간 운용은 `tmux` 또는 `nohup ... --quiet &`.
- Ctrl-C/SIGTERM 시 현재 런을 정상 종료하고 DB 기록 후 종료한다.

<<<<<<< HEAD
## 11. 세션 기록 (Claude Code)

### 2026-08-13 — §6 작업 1~3 수행

**작업 1 — 실제 ROOT 빌드 검증 ✅**
- `source /usr/local/bin/thisroot.sh && source cupdaq_env.sh && rm -rf build install && ./build.sh`
- ROOT 6.28/04, GCC 11.5.0로 clean build 성공. 에러 0, §4.4 스텁결함 5종 관련 문제 전혀
  없음 — 소스가 실제 ROOT API를 정확히 사용함을 확정.
- `install/bin/{rcterm,rcsupervisor}` 생성, `--help` 정상. sqlite3 CLI는 이 호스트에
  미설치 (`--no-db` 필요, 기존에 알려진 사항).
- 부가 검증: `rcterm --shift T --config /nonexistent.config --no-db --run 1 --dry-run`
  → `exit=1` 확인.

**작업 2 — rcsupervisor 로테이션/복구 검증 ✅**
- `/tmp/suptest/fake_rcterm.sh` 작성: `--heartbeat`/`--run` 파싱, 실제 `WriteHeartbeat()`와
  동일한 12줄 포맷을 `.tmp`→`mv`로 원자적 기록, `trap TERM`으로 clean exit,
  `FAKE_MODE=stale`이면 3초 후 heartbeat 갱신 중단.
- **테스트 H(로테이션)**: `FAKE_MODE=good`로 실행 → run=900 clean exit → run=901 재시작 →
  supervisor `exit=0`. SIGTERM이 자식에 정확히 전달됨을 trace.log로 확인, 좀비 프로세스 없음.
- **테스트 I(stale 복구)**: `FAKE_MODE=stale`로 실행 → 런 시작 12초 후 stale 감지(기대 ~11초,
  일치) → SIGTERM → clean exit → run=951로 재시작. 좀비 프로세스 없음.
  (참고: 최초 시도에 `--max-cycles 1`을 잘못 줘서 재시작 확인 전에 종료됐음 →
  `--max-cycles 2`로 재실행하여 확인. `exit=124`는 테스트용 `timeout` 래퍼가 세 번째
  backoff 대기 중 강제 종료시킨 것으로, supervisor 자체 결함 아님.)
- 실제 옵션명은 `rcsupervisor --help`로 확인 후 사용 (`--rcterm` 존재 확인).

**작업 3 — 한글 텍스트 깨짐 수정 ✅**
- §6에 명시된 sed 전부 적용 (`src/rcterm.cc`, `config/rcterm.params.example`,
  `config/SERVER-block.example`). 원 grep 패턴 `src config docs README*.md` 전체 0건.
- 지정 범위 밖이었던 `docs/MANUAL.md`, `src/RunControl.cc`에도 동일 패턴이 남아있어
  함께 수정 (모니타→모니터, 카타로그→카탈로그, 부톥→부팅, 부분벇본→부분문자열,
  버긎가→버그가).
- `src/rcsupervisor.cc` 한글 주석 54줄을 육안으로 전수 검토 → `횝득`→`획득` 추가 수정.
- 수정 후 재빌드로 컴파일 문제없음 확인.

**미해결 — 사용자 확인 필요**
- `src/rcsupervisor.cc:8` `"자식이 버지면 새 run 번호로 다시 실행한다"` — `버지면`이
  비문이나 의도한 단어(죽으면/종료되면 등)를 추측으로 바꾸면 의미가 왜곡될 위험이 있어
  **수정 보류**.
- `README.ko.md`(한글 341줄)는 패턴 grep은 통과했으나 줄 단위 육안 전수 검토는 미실시.

**갱신 안 됨 (다음 세션 대상)**
- §4.3 잔여 항목: 실 하드웨어 실행 검증 (§6 작업 7, 사용자와 함께 진행 필요) —
  이번 세션에서 시도하지 않음.

=======
>>>>>>> 967823e2c503573ecd56ebb2f42251f03aff103e
