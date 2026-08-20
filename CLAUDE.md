# CLAUDE.md — RENE 실험 DAQ 프로그램 (RENE_DAQ_term) 작업 지침

이 파일은 Claude Code가 매 세션 자동으로 읽는다.
선행 세션(웹 챗)에서 확정된 사실과 잔여 작업이 전부 여기 있다.
**추측하지 말고 이 문서의 검증 상태를 신뢰하되, "미검증"으로 표시된 것은 반드시 실측하라.**

---

## 0.0 다른 PC 에서 이어받기 ★ 새 작업 PC 라면 여기부터

**이 저장소가 프로젝트의 정본이다.** 작업 PC 가 바뀌어도 아래만 하면 그대로 이어진다.
Claude Code 의 로컬 메모리는 PC 를 따라가지 않으므로 의존하지 말 것.

```bash
git clone https://github.com/Sang-Yong/RENE-daq-rcterm.git
cd RENE-daq-rcterm

# 1) 이 문서를 처음부터 끝까지 읽는다. 특히 §4 검증 상태와 §6 잔여 작업 큐
# 2) 운용 환경(터미널·편집기·화면 배치)을 복원한다
config/dotfiles/install.sh --all

# 3) 사이트 전용 값 두 가지는 저장소에 없다. 새 PC 에 맞게 직접 넣는다
#      build.sh          thisroot.sh / cupdaq_env.sh 의 source 경로
#      src/OnlConsts.hh  RCTERM_DEF_RAWDATA_DIR / RCTERM_DEF_DBFILE
#      config/*.params   (.gitignore 대상. *.params.example 에서 복사해 수정)
#                        rcterm / rcsupervisor / dataflow / notify 네 개다
#      config/notify.params  ★ 알람·메일 자격증명. 비우면 소리만 나고
#                        메일이 안 간다. Gmail 은 '앱 비밀번호'여야 한다 (§11.55)
#      config/rundesc.txt  런 설명(HV 등). 없으면 daq-tmux.sh 가 --desc 를 안 넘겨
#                        rundesc 가 이전 런들과 달라진다 (§11.20)
#      ~/.ssh/config     백업 서버 별칭 'khu' + 키 교환 (docs/DATAFLOW.md §4)
#      RENE_ANA_HELPERS  분석 헤더 경로. ★ 없으면 모니터링 2·3단계가 빌드 실패
#      RENE_COND         (아래 '분석 트리 의존' 참조)

# 4) 빌드
./build.sh

# 5) 화면 구성 (하드웨어는 건드리지 않는다)
scripts/daq-tmux.sh

# 6) 데이터 이동 체인이 도는지 확인. 이것이 멈추면 /Data_ssd 가 차고 DAQ 가 멈춘다
scripts/dataflow.sh --params config/dataflow.params --once --dry-run

# 7) 모니터링이 무엇을 고를지 확인 (아무것도 바꾸지 않는다)
tools/monitor/run-summary.sh --dry-run
tools/monitor/ibd-summary.sh --dry-run
```

**★ 새 서버에서 가장 먼저 깨지는 것 — 분석 트리 의존.**
2026-08-18 부터 `tools/monitor/RenePrdSingles.h` 가 분석 쪽 헤더 **두 개를
컴파일 시점에 include** 한다. 물리를 복제하지 않으려고 그렇게 했고(§11.30),
대가로 **그 경로가 없으면 아예 빌드가 안 된다.**

```
<분석트리>/essential/helper_functions.cc    파형 -> NPE
<분석트리>/essential/AnalysisCondition.h    컷 상수 전부

경로가 다르면          RENE_ANA_HELPERS=/새경로/essential/helper_functions.cc
                       RENE_COND=/새경로/essential/AnalysisCondition.h
```

**rcterm · rcsupervisor · postrun · dataflow 는 이 의존이 없다.** 수집과 이동은
분석 트리가 없어도 그대로 돈다. 못 도는 것은 모니터링 2·3단계뿐이므로, 새 서버에
분석 트리가 없으면 그 둘은 미루고 수집부터 세우면 된다.

**읽는 순서**

| 문서 | 무엇이 있나 |
|---|---|
| `CLAUDE.md` (이 문서) | 확정된 사실, 설계 근거, 검증 상태, 잔여 작업, 세션 기록 |
| `docs/MANUAL.md` | rcterm / rcsupervisor 운용 상세 |
| `docs/POSTRUN.md` | 병합·production 파이프라인의 구조와 성능 근거 |
| `docs/DATAFLOW.md` | 수집 -> 백업 -> 장기보관 데이터 이동의 구조와 실측 근거 |
| `docs/ALARM.md` | 알람·메일·자동 USB 복구. 설정법과 알람이 울렸을 때 할 일 |
| `tools/monitor/README.md` | 모니터링 3단계 — PRD 에서 livetime·이벤트 수 -> IBD 후보 -> 효율 보정 rate 추이 |
| `config/dotfiles/README.md` | 터미널·편집기 설정이 왜 그렇게 되어 있는가. `claude-transcript` 도 여기 |
| `docs/*.pptx` | 발표 자료 — 종합(한/영) · 운용자용(한). **저장소에 없다** — `.gitignore` 대상이라 `tools/slides/make_*.py` 로 만들어 쓴다 |
| `tools/slides/README.md` | 발표자료를 코드로 만드는 이유와 방법. `audit.py` 로 배치를 점검한다 |

**작업을 마칠 때마다 해야 하는 것** — 이것을 빠뜨리면 다음 PC 에서 맥락이 끊긴다.
사용자와 **프로젝트 종료를 합의할 때까지** 계속한다.

1. §11 세션 기록에 **무엇을 왜 했는지** 추가. 결과 수치는 실측값만.
2. §4 검증 상태(✅ / ⚠️)와 §6 잔여 작업 큐를 현재에 맞게 갱신.
3. 프로젝트 기록 페이지를 **같은 주소로** 갱신 (아래).
4. 커밋하고 **`git push origin main`**. 푸시하지 않으면 저장한 것이 아니다.

### 프로젝트 기록 페이지 (= 인수인계 문서)

사용자 계정에 발행된 요약 페이지가 있다. 어느 PC·서버에서든 브라우저로 열 수 있고,
**2026-08-18 부터 인수인계 문서 구실을 하도록 구성했다** — 현재 상태, 데이터 흐름,
모니터링 파이프라인, 서버가 바뀔 때 다시 확인할 경로 표, 먼저 읽을 문서 순서,
놓치기 쉬운 것 넷.

```
https://claude.ai/code/artifact/dbc5ca50-0165-42f6-9bbc-2008f9a8ca67
```

Claude Code 로 갱신할 때는 Artifact 도구에 **`url` 로 위 주소를 넘겨야** 같은 페이지가
갱신된다. 넘기지 않으면 별개의 새 페이지가 생긴다.

**정본은 이 저장소다.** 저 페이지는 읽기용 요약이며, 이어받기에 필요한 것은 전부
저장소 안에 있어야 한다.

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
source /usr/local/bin/thisroot.sh
source /home/frontend/DAQ/DAQ_cup/cupdaq_env.sh
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
src/usbreset      20.0k   ★ 소스가 아니라 실행 파일이다. 아래 설명 참조
src/NOTICE_CODE_RUN.sh    ★ rcterm 과 무관한 보드 점검 스크립트. 아래 설명 참조
config/{rcterm.params.example, rcsupervisor.params.example, SERVER-block.example}
scripts/{killdaq.sh, rcsupervisor.service.example}
scripts/daq-alarm.sh     현장 알람 (사운드카드 + PC 스피커). 사람이 끌 때까지
scripts/daq-notify.sh    사건 -> 알람 + 메일. 감시자가 --notify-cmd 로 부른다
scripts/usb-recover.sh   USB 진단 + usbreset + 확인 런. --diagnose 는 읽기 전용
tools/notify/send_mail.py  SMTP 발송
config/notify.params(.example)   위 넷이 함께 읽는다. ★ 자격증명이 들어간다
tools/monitor/RenePrdSingles.h   PRD -> clean single (= 분석 Step1 + Step2)
tools/monitor/RenePairing.h      single -> 후보 수    (= 분석 Step3 + Step4)
   ★ 위 둘은 분석 쪽 essential 헤더를 include 한다. §0.0 의 경고 참조
docs/MANUAL.md      README.md(26k, 영)      README.ko.md(28k, 한)
```

**`src/usbreset` 는 이 프로젝트의 소스가 아니다.** NOTICE USB 보드(FADC/SADC)를
`USBDEVFS_RESET` 으로 되살리는 CUPDAQ 유틸리티이며, 원본은
`DAQ_cup/CUPDAQ/DAQ/test/usbreset.cc` 다. 2026-08-14 에 이 사이트에서 빌드한
것으로 `DAQ_cup/install/bin/usbreset`(2025-06, 56 kB) 과는 다른 바이너리다.
**사용자 요청으로 추적한다** — 보드가 먹통일 때 손에 잡히는 곳에 있어야 해서다.
소스는 CUPDAQ 쪽 것을 정본으로 두고 여기로 복제하지 않는다(§5.8 과 같은 이유).

> 실행하면 USB 보드가 리셋된다. **수집 중에는 절대 돌리지 말 것.**
> DAQ 를 먼저 내리고(`scripts/killdaq.sh`) 쓴다.
>
> **★ `--help` 가 없다. 인자 없이 실행하면 그 자리에서 보드 3개를 리셋한다.**
> 사용법을 보려는 목적으로도 실행하지 말 것 (2026-08-20 에 한 번 겪었다, §11.51).
> 언제 어떻게 쓰는지는 §11.50 의 복구 절차에 순서대로 적혀 있다.

**`src/NOTICE_CODE_RUN.sh` 도 rcterm 과 무관하다.** NOTICE 벤더 코드
(`~/DAQ/NOTICE/nkfadc500_CNU/notice`)의 보드 점검 매크로를 순서대로 부르는
얇은 래퍼다. 보드가 응답하는지 rcterm 밖에서 확인할 때 쓴다.

```
notice_env.sh 를 source 한 뒤
  SADC : set_M64ADC.C -> run_M64ADC.C -> tcb_test.C -> stop_M64ADC.C
  FADC : tcb_stop.C   -> tcb_test.C
```

> **하드웨어를 직접 건드린다. 수집 중에는 절대 돌리지 말 것.** 보드를 설정하고
> 돌렸다 세우므로 진행 중인 런이 깨진다.

두 파일 모두 **경로가 이 PC 에 하드코딩**되어 있다(`/home/frontend/DAQ/...`).
새 PC 에서는 §0.0 의 사이트 전용 값과 함께 고쳐야 한다. `src/` 에 있는 것은
원래 자리를 그대로 둔 것이고, 성격상으로는 `scripts/` 가 맞다.

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
| **실제 ROOT 6.28/04 빌드** | clean build 성공, 에러 0. §4.4 스텁결함 5종 전부 무관함 확인 (2026-08-13) |
| **rcterm 설정오류 종료코드** | `--config /nonexistent.config` → `exit=1` 실측 확인 |
| **rcsupervisor 테스트 H(로테이션)** | run=900 clean exit → run=901 재시작 → `exit=0`, SIGTERM 정상 전달, 좀비 없음 |
| **rcsupervisor 테스트 I(stale 복구)** | 12초에 stale 감지(기대 ~11초) → SIGTERM → clean exit → run=951 재시작. 좀비 없음 |
| **실 하드웨어 24h 로테이션 운용** | 2026-08-14~15 영광 사이트. run 4280~4287, 1시간 로테이션 정상 (§11 참조) |
| **SIGTERM 정상 마감 (수정 후)** | 가짜 TCB A/B 실측. 구버전=`phase=failed`/exit=2/DB 공백, 수정본=`phase=ended`/exit=0/stime·etime·nfadc·nsadc 전부 기록 |
| **2차 신호 즉시 탈출** | DAQ 가 RunEnded 로 안 갈 때 2번째 SIGTERM → 1초 내 종료 (운영자가 갇히지 않음) |
| **stale DAQ 가드** | 포트에 이미 DAQ 가 있으면 `[FATAL]` + exit=2, **run 번호 발급 전이라 번호 낭비 없음** 실측 |
| **부팅 실패 DB 표기** | 부팅 실패 시 `onlbit=0, runlog='boot failed; run never started'` 기록 실측 |
| **★ 실 하드웨어 24h 로테이션 (수정본)** | **2회 연속 무결** — 4288→4289(08-16), 4289→4290(08-17). 둘 다 `ENDED` + `exit=code 0` + DB 완전 마감. **§11.1 버그 A 수정 확정** (§11.8) |
| **후처리 실시간 추적** | run 4288·4289 모두 **PRD 1440개 전량 완료**, 좀비 0건. FADC=SADC=Merged=PRD 로 수가 정확히 일치 |
| **heartbeat 디렉터리 자가 복구** | 런 도중 `/Data/LOG` 삭제 재현 → 다음 갱신에 스스로 재생성, 런은 exit 0 (§11.10) |
| **데이터 이동 체인 (dataflow)** | 3단계 전부 `--dry-run` 실측. 수집 중/후처리 미완료 런을 정확히 건너뜀 (§11.13) |
| **경희대 백업 실전송** | run 4290 의 `config` + `DAQLOG` 3종 + `db` 를 **실제로 보내고 원격에서 확인**. 재실행 시 마커로 건너뜀 (§11.13) |
| **백업 계정 권한** | `renecomm`(별칭 `khu`, 키 인증) = 7개 카테고리 전부 쓰기 가능. `sykim` = `config`/`db`/`RAW` 만 (§11.14) |
| **경희대 링크 속도** | 500 MB 업로드 31.9초 = **15.7 MB/s**. `/scratch` 의 100 Mb 와 **다른 랜카드**라 서로 대역을 뺏지 않는다 (§11.14) |
| **모니터링 2단계 PRD 직독** | 재구성은 분석 Step2 와 single 목록이 **비트 단위로 동일**(run 4237 sub 100), 페어링은 Step3/Step4 와 **여덟 개 수 전부 일치**(run 4237 전체, single 7,266만) (§11.31) |

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

### 4.3 잔여 작업 — 없음 ✅

착수 시점의 미검증 항목은 모두 닫혔다.

| # | 항목 | 결과 |
|---|---|---|
| 1 | 실 하드웨어 실행 | ✅ 2026-08-14~15 (§11) |
| 2 | 수정본의 첫 로테이션 관찰 | ✅ 2026-08-16, 이후 2회 연속 무결 (§11.5, §11.8) |
| 3 | DAQ 를 tmux 로 이관 | ✅ 2026-08-15. `tmux attach -t daq` |
| 4 | `/Data_ssd` 용량 | ✅ 2026-08-17 재설계. `scripts/dataflow.sh` 가 `/data` -> 백업 -> `/scratch` 로 흘려보낸다 (§11.13). `--keep-local` 은 더 이상 쓰지 않는다 |
| 5 | 외부(경희대) 백업 | ✅ `scripts/backup-khu.sh`. 성격별 카테고리 rsync + 검증 + 재개 (§11.13) |

다음에 손댈 것은 §6 작업 6 의 개선 백로그다(libsqlite3 링크, 모니터 소켓 재연결,
단위 테스트 등). 급한 것은 없다.

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

## 5.8 후처리 파이프라인 (merge + production) — 상세는 `docs/POSTRUN.md`

DAQ 수집 뒤에 `scripts/postrun.sh` 가 붙는다. `DAQ_cup/production` 의
`merge_FADC_SADC_v3_5v.cc` / `production_from_merged_v3_5v.cc` 를 **그대로 호출**하며
매크로를 이 저장소로 복제하지 않는다. 복제하면 두 벌이 갈라진다.

**핵심 사실 (실측)**

- 서브런 1개 = 60초 분량. 처리는 merge 28초 + production 15초 = **43초**
  (run 4238/4239/4240 의 서브런 로그 33,357개 기준)
- **merge 는 병렬화 불가** — 매크로가 서브런 끝에 찍는 `final SADC` /
  `final SADC_evt` / `final before_SADC_trgnum` 이 다음 서브런의 SADC 시작 위치다.
  이걸 넘겨받지 않으면 서브런 경계에서 이벤트를 잃는다.
  **production 은 서브런마다 독립이라 병렬 가능.**
- **heartbeat 의 `subrun` = 지금 기록 중인 파일 번호.** 실측 확인
  (`subrun=829` ↔ `FADC_004288.root.00829` 가 최대 번호). 완료된 것은 0..828.
  **`--lag` 기본값 3** — 서브런 1개가 1분이므로 실시간 수집보다 약 3분 뒤를
  따라간다. 처리 상한 = `heartbeat subrun - 3`. 이 여유가 필요한 이유:
  기록 중인 파일은 아직 안 닫혔고, **NFS 서버 시계가 로컬보다 약 28초 앞서며**
  (실측), DAQ 가 파일을 닫고 flush 할 시간이 필요하다. 덜 쓰인 파일을 열면
  merge 가 Zombie 로 판정해 재시도에 들어가 오히려 느려진다.
- **병목은 CPU 가 아니라 NFS I/O다.** 가동 중 실측 iowait 26~34%, CPU 유휴 61~88%.
  그래서 `--jobs` 를 올려도 크게 나아지지 않는다. 3~4 권장.
- **산출물을 로컬 NVMe 로 빼면 서브런당 41.0초 → 27.7초** (run 4288 실측).
  `--outroot /Data_ssd/RAW` 를 주면 `Merged`/`PRD` 를 거기 만들고 RAW 에는
  심볼릭 링크를 건다. 매크로와 기존 도구는 경로를 그대로 쓰므로 고칠 게 없다.
  단 `/Data_ssd` 는 여유 2.0TB 뿐이라 산출물 기준 **약 9일치**다(`/scratch` 는 48일치).
  주기적으로 옮기거나 지우는 운용이 필요하다.
- 용량: 서브런당 RAW 78MB + Merged 80MB + PRD 77MB. **24h 런 1회가 약 334GB.**

**원본 `merge_FADC_SADC_v3_5v.sh` 의 자동화 저해 요소** (원본은 수정하지 않았다)

1. 완전 대화형 (`read run`, 메뉴 1~4, 스킵 목록)
2. 재개 지점을 **이진 탐색**으로 찾는데, 중간에 실패한 서브런이 있으면 단조성이
   깨져 엉뚱한 곳에서 재개한다 → postrun.sh 는 선형 스캔
3. `Run<run>_DLY_THR.log` 를 `if [ ! -f ]` 후 생성 → **production 을 병렬화하면 레이스**.
   postrun.sh 는 구간 시작 전에 한 번만 만든다
4. 좀비 파일에 `sleep 1m` × 5회 = 5분 낭비
5. `pwd` 상대 경로 (`CodeDir=$pwDir/../Code`)

성공 판정(2PC)과 로그 파일명은 원본과 **동일하게** 유지했다. 따라서
`production/Shell/audit_run.sh` 가 postrun.sh 결과에도 그대로 동작한다.

## 6. 잔여 작업 큐 (우선순위 순)

### 작업 1 — 실제 ROOT 빌드 검증 ★최우선
```bash
source /usr/local/bin/thisroot.sh
source /home/frontend/DAQ/DAQ_cup/cupdaq_env.sh
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

**2026-08-15 추가 수정** — `docs/MANUAL.md`, `config/rcsupervisor.params(.example)`,
`src/rcsupervisor.cc` 에 남아있던 것 중 문맥상 확정 가능한 것만 고쳤다:
복관→복구, 살한다→살핀다, 이상 샜→이상 시, 안 끌나면→안 끝나면,
바꾸려보면→바꾸려면, 처지→조치, 교지 주기→교체 주기, 마간→마감,
안 바리면→안 바뀌면, 생자료로 죽어→쓰기 도중에 죽어(§5.3 근거).

**여전히 보류 3건 — 사용자 확인 필요** (추측 수정 시 의미 왜곡 위험):
- `src/rcsupervisor.cc:8` `"자식이 버지면"` (죽으면? 종료되면?)
- `docs/MANUAL.md:177` `"단으로 감지하고 단으로 복구한다"` (`단으로` 가 무엇인지 불명)
- `config/rcsupervisor.params(.example):26` `"저리드 런"` (저레이트? — CLAUDE.md §10 의
  `"지리드 런"` 도 같은 계열 오염이다)

### 작업 4 — README/MANUAL에 `--params` 위치 기반 규칙 명시 (§5.6) ✅ (2026-08-15 완료)
`README.md` §6, `README.ko.md` §6, `docs/MANUAL.md` 신설 §7.5, `rcterm --help` 에 명시.
rcsupervisor 가 이 규칙에 의존한다는 점(params 뒤에 자기 설정을 덧붙임)까지 기록.

### 작업 5 — 실패 런 DB 고아 행 처리 ✅ (2026-08-15 완료)
`RunControl::MarkFailedRunInDB()` 신설. `Execute()` 에서 사이클 실패 시 호출하여
`onlbit=0` + `runlog` 에 사유를 남긴다. 사유는 `fRunStartWall` 로 구분한다.
- `boot failed; run never started` — STARTRUN 이전에 실패
- `aborted; run started but was not finalized` — 시작은 했으나 마감 실패

### 작업 6.5 — 데이터 흐름 (2026-08-17 구축, §11.13)

구조와 근거는 `docs/DATAFLOW.md`. 남은 것은 **실전 확인**뿐이다.

```bash
# 매번 이것부터. 각 단계가 무엇을 왜 건너뛰는지 한 줄씩 나온다
scripts/dataflow.sh --params config/dataflow.params --once --dry-run

# 새 구성으로 런을 하나 받은 뒤, 1단계만 실제로
scripts/dataflow.sh --params config/dataflow.params --stage 1 --once

# 대용량 백업 첫 실전송 (런당 221 GB / 약 4시간). 사용자 승인 후에
scripts/backup-khu.sh --params config/dataflow.params --run <N>
```

확인할 것 : ① `/Data_ssd` 여유가 실제로 회복되는가 ② 원격 개수가 로컬과 맞는가
③ 후처리가 옮겨진 런을 찾다가 죽지 않는가(§11.13 에서 고쳤으나 실전 미확인).

**2026-08-18 현재 이 셋 다 아직 못 봤다.** `/Data_ssd` 에 런이 `keep_ssd`(=2) 개뿐이라
1단계에 대상이 없고 `/data/RAW` 가 비어 2·3단계도 할 일이 없다(§11.19).
**새 구성으로 런을 3개 이상 받아야 비로소 체인이 실제로 돈다.**

### 작업 6 — 개선 백로그 (여유 있을 때)
- `libsqlite3` 링크 + prepared statement (현재는 임시파일 + 셸 호출, 이스케이프만)
- 모니터 소켓 런당 1회만 오픈 → 런 도중 끊기면 재연결 없음. 주기적 재연결 필요
- `OnlSocket::Connect()` 소켓 타임아웃 3초 하드코딩 → 옵션화
- heartbeat 락 없음. `rename()`은 원자적이나 두 rcterm이 같은 경로를 쓰는 걸 못 막음
  → PID 파일 + `flock`
- rate가 벽시계가 아니라 DAQ 보고 시간 기준 → ns 카운터 정지 시 순간 rate 미정의
- 단위 테스트 없음. config 파싱 / 머저 판정 / 비트마스크 디코딩은 순수 함수라 쉽다
- dataflow 3단계가 `/scratch` 로 옮기는 데 12시간이 걸린다. 100 Mb 링크(§11.12)를
  고치는 것이 정답이고, 그 전까지는 `--drop-merged` 가 유일한 단축 수단이다
- ~~`backup-khu.sh` 는 원격 개수만 검증한다. 체크섬 검증은 너무 비싸다~~
  **2026-08-19 해결. 그리고 "너무 비싸다"는 판단이 틀렸다** — run 4290 PRD
  15.4 GB 기준 전송 17분 40초 대 대조 **1분 00초**다(§11.35). 양쪽이 각자
  계산해 결과만 주고받으므로 링크 부담이 거의 없다. 지금은 기본으로 켜져 있다
  **★ 단 이것은 ssh 전송에만 해당한다.** dataflow 3단계의 `/scratch` 는 NFS
  마운트라 rsync 에게는 로컬 경로이고, 클라이언트가 목적지 전량을 읽어야 해서
  **대조가 전송보다 비싸다** — run 4292 는 전송 10.3시간 대 대조 28시간+ (§11.63)
- **rcterm 에 `--no-quiet` 가 없다.** 감시자가 `--quiet` 를 무조건 붙이므로
  감시자 밑에서는 `PrintScreen()` 을 켤 수 없다. 지금은 `scripts/rcmon.sh` 로
  우회한다. 제대로 고치려면 감시자가 rcterm 출력을 **별도 pty/tmux pane 으로**
  보내야 한다. 단순히 `--no-quiet` 만 추가하면 화면 지우기가 감시자 로그를
  덮는 원래 문제가 되살아난다

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
- **★ 파일 이동은 언제나 rsync 다. `mv` 를 쓰지 않는다.** (2026-08-19 사용자 지침,
  영구) 복사 -> **체크섬 대조** -> 통과한 것만 원본 삭제. 이 순서를 바꾸지 말 것.
  근거 : 옮기는 것이 되돌릴 수 없는 데이터이고, `/scratch` 가 100 Mb 링크에
  붙어 있어(§11.12) 전송이 길고 끊기기 쉽다. **개수만 맞추는 것으로는 부족하다** —
  예전에 끊긴 전송의 잔재를 성공으로 오인한다.
  ```
  전송   rsync -a --partial-dir=.rsync-partial      (--remove-source-files 금지)
  대조   rsync -c -n -i   -> '>f' / '<f' / '*deleting' 줄이 0 이어야 한다
  삭제   대조를 통과한 뒤에만
  ```
  같은 파일시스템 안의 **이름 바꾸기**(`mv -T stage dst`)는 예외다. 자료가
  움직이지 않는 원자적 연산이고, 스테이징을 제자리에 끼우는 데 필요하다.
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
- **★ 로그·heartbeat 는 `rawdatadir` 밑이 아니다.** 이 사이트는 갈라져 있다 —
  RAW 는 `/Data_ssd`, heartbeat·로그는 **`/Data/LOG/`**
  (`rcterm.hb` · `rcterm.log` · `rcsupervisor.log`). `/Data_ssd/LOG/` 에는 DAQ
  자신의 로그(`TCB_*.log` 등)와 운용 스크립트 로그만 있다. 상태를 볼 때
  `/Data_ssd/LOG/rcterm.hb` 를 찾으면 없다(2026-08-19 에 한 번 헛짚었다).
- 배경/지리드 런처럼 이벤트가 드문 측정은 `--stall-grace`를 크게 하거나
  `--no-stall-check`. 안 그러면 정상 런을 이상으로 판정해 재시작한다.
- 장시간 운용은 `tmux` 또는 `nohup ... --quiet &`.
- Ctrl-C/SIGTERM 시 현재 런을 정상 종료하고 DB 기록 후 종료한다.
- **감시자가 `FATAL too many consecutive failures` 로 포기했으면 하드웨어를 의심할 것.**
  같은 노드가 같은 오류로 5번 연속 실패한 것이므로 재기동만 해서는 또 5개를 태운다.
  FADC USB 보드가 걸린 사례와 복구 절차는 §11.49~11.51.
  **2026-08-20 부터는 감시자가 포기하기 전에 `scripts/usb-recover.sh` 를 스스로
  부른다**(§11.55). 그래도 안 되면 알람이 울리고 전문가에게 메일이 간다.
- **감시자 기동 로그에서 `notify=` 줄을 확인할 것.** `(off)` 면 알람·메일이
  꺼진 채로 뜬 것이다. 설정을 안 고쳐 조용히 꺼져 있는 것이 가장 위험하다.
- **알람이 울리면** `scripts/daq-alarm.sh --status` 로 사유를 보고,
  조치한 뒤 `--silence` 로 끈다. 끄는 것과 고치는 것은 다르다.
- **postrun 의 `[FAIL] Producing FAILED (0초)` 는 데이터 문제가 아니다.**
  0초짜리 실패는 로그 파일을 못 열어 ROOT 매크로가 아예 안 돈 것이다 (§11.52).
  이 경우 PRD 가 조용히 하나 빈다. 런 끝에 FADC 개수와 PRD 개수를 대조할 것.
- **postrun 의 `[CORRUPTION DETECTED] ZOMBIE FILE` 도 진단명이 아니다.** merge
  매크로가 rc≠0 이면 무조건 붙는 이름이라 사유는 merge 로그를 봐야 한다
  (`/scratch/LOG/log_merge_FADC_SADC_v3_5v_run<런>_subrun<N>.txt` 의 끝 몇 줄).
  쓰기 도중 죽은 런에서는 거의 언제나 **마지막 SADC 가 안 닫힌 것**이고, 그때는
  부분 Merged 가 정상 ROOT 파일로 남아 있으므로 **PRD 는 살릴 수 있다** (§11.64).

## 11.5 구글시트 런 로그 작성 규칙 ★ 사용자 지침 (2026-08-19, 영구)

대상 시트 — **RENE Offline Data GoodRuns**, 탭 `gid=0`

```
https://docs.google.com/spreadsheets/d/1-8wPIg-Q-DpgsyBeSiwHezxM6QlcqhZ3qspAFGusqD0/edit?gid=0#gid=0
```

### 절대 규칙 ★ 2026-08-20 개정 (사용자 지침)

**금지선은 '기존 행' 이 아니라 '남의 행' 이다.** 처음에는 시트 전체를 불가침으로
적었는데, 사용자가 뜻을 분명히 했다 — **지키라는 것은 다른 계정의 사람들이
써 놓은 행**이고, 우리가 쓴 행은 우리가 다시 고쳐도 된다.

**행 번호로 정하면 안 된다.** 중간에 끼워 넣으면 아래가 전부 밀린다. 실제로
2026-08-20 에 4208~4211 을 넣으면서 그 아래 행 번호가 4씩 밀렸다.
**런 번호로 정한다.**

```
남의 것   282개.  런 번호 4246 이하   (단, 아래 다섯은 제외)
우리 것    19개.  런 4280 이상  +  되메운 4208 4209 4210 4211 4276
```

우리가 쓴 19개 : 4208 4209 4210 4211 4276 4280 4282 4283 4284 4285 4286 4287
4288 4289 4290 4291 4292 4293 4294. **여기에 행을 더할 때마다 이 목록도 늘린다.**
코드에도 같은 경계가 `append_runs.py` 의 `OURS_MIN` · `OURS_EXTRA` 로 박혀 있다.

1. **남의 행은 내용도 위치도 건드리지 않는다.** 값이 틀려 보여도 손대지 않는다.
   순서를 맞추려고 그 사이에 끼워 넣는 것은 위치가 밀리므로 **사용자 승인이 필요**하다
   (2026-08-20 에 승인받고 4208~4211 을 257행에 넣었다).
2. **우리가 쓴 행은 고쳐도 된다.** 잘못 들어갔으면 그 행만 다시 쓴다.
   실제로 그날 순서가 뒤집혀 들어간 네 행을 그렇게 바로잡았다.
3. 이미 있는 Run 번호는 건너뛴다. **같은 런을 두 번 싣지 않는다.**
4. **쓰기 전에 시트 전체를 백업하고, 쓴 뒤 남의 행이 그대로인지 대조한다.**
   `append_runs.py --insert` 가 이것을 자동으로 한다.
5. 파일로 건네지 말고 시트에 직접 쓴다.

### 열별 채우는 법

| 열 | 출처 |
|---|---|
| `Run` | `runcatalog.db` 의 `runnum` |
| `Start Date` / `Start Time` | `stime` |
| `Duration` | `etime - stime` |
| **`Max subrun`** | **마지막 서브런 번호 = 개수 − 1.** 기준은 **RAW(FADC)** 서브런이다 (`FADC_<런>.root*` 개수 − 1). 예 : run 4085 은 47개 -> `46`. ★ 2026-08-20 에 기존 13개 런으로 실증했다 — 그 전까지 이 표는 '개수'라고 적고 있었으나 **틀렸다**. PRD 로 세면 후처리가 덜 끝난 런에서 어긋난다(run 4237 : FADC 12722 / PRD 12720, 시트는 12721). RAW 가 없고 PRD 만 있는 런은 PRD 개수 − 1 로 센다 |
| `Event Rate (kHz)` | `nfadc / tfadc` |
| **`RAW (GB)`** | `<런>` **바로 아래**(하위 폴더 제외)의 `FADC_<런>.root*` + `SADC_<런>.root*` 용량 합 |
| **`PRD (GB)`** | `<런>/PRD` 의 `PRD_<런>.*.root` 용량 합 |
| `Detector` `Source` `PMT-A HV (V)` `PMT-B HV (V)` `THR (mV)` `Coincidence (ns)` `Record length` `Time after HV ON` `TLT` | **비어 있는 런 바로 이전 행의 값을 그대로 복사**한다. 사용자가 나중에 직접 고치며, 고친 뒤에는 그 고친 값을 이어서 복사한다 |
| `Description` | `runcatalog.db` 의 `rundesc`. DAQ 수집 때 사용자가 입력한 것을 **그대로** 옮긴다 |
| `Data issue` | postrun 또는 DAQ 의 **비정상 종료 메시지**. 없으면 **비워 둔다** (`onlbit=0` 이면 `runlog` 를 본다) |

런 디렉터리는 dataflow 가 옮기므로 **`/Data_ssd/RAW` -> `/data/RAW` ->
`/scratch/RAW` 순서로 찾는다**(앞이 이긴다). 한 곳만 보면 놓친다.

### 어느 런을 싣는가 — `onlbit=1` 만 ★ 실증으로 확정

**추측하지 말 것. 기존 시트를 세어서 나온 규칙이다** (2026-08-19).

```
시트에 있는 282개 :  onlbit=1 272,  null 10,  onlbit=0   0개
시트에 없는 180개 :  onlbit=0  67,  null 92,  onlbit=1  21개
```

**`onlbit=0` 인 런은 282행 중 단 하나도 없다.** `boot failed` / `aborted` 는
데이터가 일부 있어도 싣지 않는다. 시트 이름이 GoodRuns 인 것과 일치한다.
`stime` 이 없는 런(진행 중이거나 미마감)도 뺀다 — 기존 행은 Start Date 가
빈 것이 하나도 없다.

`Data issue` 는 **정상 런의 결함**을 적는 칸이다. 기존 25개 예 :
`subrun 00010 FADC RAW not properly closed but recoverable`. 데이터가 없는
런을 등재하는 칸이 아니다.

**수집 중인 런은 넣지 않는다.** 기존 행은 절대 수정할 수 없으므로, 끝나지 않은
런을 넣으면 그 행이 영영 틀린 채로 남는다. 런이 끝난 뒤에 넣는다.

### 쓰기 수단 ✅ (2026-08-19 구축)

```
자격증명   <저장소>/.config/rene/rene-daq-rundata-log-sheet-e8e035ac9d81.json  (gitignore 됨)
           서비스 계정 claude-json@rene-daq-rundata-log-sheet.iam.gserviceaccount.com
           ★ 홈(~/.config/rene) 이 아니라 저장소 안이다. append_runs.py 가
             $RENE_SHEETS_SA -> <저장소>/.config/rene/*.json -> ~/.config/rene/*.json
             순서로 스스로 찾으므로 보통은 --creds 를 줄 필요가 없다
라이브러리 gspread 6.2.1 + google-auth   (pip --user)
도구       tools/sheetlog/append_runs.py   기본이 미리보기. --commit 이라야 쓴다
           tools/sheetlog/khu_scan.sh      로컬에 없는 런을 경희대에서 실측
```

**대상 탭은 이름이 `Y2026B` 이고 gid=0 이다.** 문서에 탭이 10개 있으므로
이름으로 찾지 말고 gid 로 찾을 것. **마지막 Run 번호는 반드시 실행 시점에
읽어서 정한다** — 하드코딩하지 말 것. Drive 커넥터의 markdown 렌더링으로
읽으면 탭이 전부 이어붙어 나와 엉뚱한 탭의 마지막 행을 읽는다(2026-08-19 에
그렇게 '4037' 이라고 잘못 읽었다. 실제로는 4246 이었다).

안전장치 — 마지막 Run 행 **아래에 내용이 하나라도 있으면 멈추고** 아무것도
쓰지 않는다. 기존 행은 읽기만 한다.

### 실측이 느릴 때 ★ `find` 대신 `ls -l`

`/scratch` 는 100 Mb NFS 라(§11.12) **파일마다 stat 을 거는
`find -printf '%s'` 는 못 쓴다** — 5,769개짜리 런 하나에 15분이 지나도 안 끝난다
(`rpc_wait_bit_killable`). **`ls -lU` 는 readdirplus 로 이름과 크기를 한꺼번에
받아오므로 같은 런이 1분이면 끝난다.** 값은 동일함을 확인했다(run 4085 :
`47 / 1517150110 / 1467551134` 양쪽 일치).

---

## 11. 세션 기록 (Claude Code)

### 2026-08-21 — run 4294 백업 착수, 그리고 잘린 꼬리 서브런을 끝까지 복구했다

#### 11.62 착수 시점 실측 — 수집은 건강한데 뒤쪽이 밀려 있었다

```
run 4302   sub=1180  daqtime 19.7h  heartbeat 나이 1초  FADC/SADC 994.9 Hz
supervisor pid 76388 (08-20 06:13 기동).  notify= · recover= 둘 다 붙어 있다
로그       rcterm [ERROR]/[WARN]/[FATAL] 0건.  알람 없음
```

08-20 새벽 FADC 보드 장애(§11.49) 이후 재발 없다. 문제는 수집이 아니라 뒤쪽이었다.

**★ 완결된 정상 런 4294 가 백업이 하나도 안 돼 있었다.** 원격 `RAW/` 는 4292 까지,
`PRD/` 도 4292 까지다. 4293 · 4294 · 4300 · 4301 은 흔적이 없다. run 4294 는
FADC=SADC=Merged=PRD=1440 으로 완결된 24시간 정상 런(334 GB)인데 **사본이 이 PC
하나뿐**이었다. 백업 큐가 옛 런 우선(4289 -> trickle 4200~4290)이라 새 런이 뒤로
밀리는 구조 때문이다.

#### 11.63 ★ 체크섬 대조 비용 — §11.35 의 "1/18" 은 ssh 에만 해당한다

dataflow 가 28시간째 run 4292 를 대조 중이라 추적했다. **고장이 아니라 원래 그만큼
걸리는 것이었다.**

```
전송   /data -> /scratch   348 GB   10시간 17분  (8.96 MB/s)
대조   rsync -a -c -n -i   28시간+ , 착수 시점 292/348 GB = 84%
pid(로컬 /data 읽기)  347 GB 완료
pid(/scratch 읽기)    292 GB 진행중
enp1s0 rx  12.02 MB/s   <- 100 Mb 링크 line rate. 포화
```

§11.35 는 run 4290 PRD 로 재고 "전송 17분 40초 대 대조 1분 00초"라 적었다.
**그것은 ssh 전송이라 양쪽이 각자 계산하고 결과만 주고받기 때문이다.**
`/scratch` 는 NFS 마운트라 rsync 에게는 그냥 로컬 경로다 — **클라이언트가 목적지
348 GB 를 전부 읽어야 한다.** 그래서 3단계에서는 **대조가 전송보다 비싸다.**

정리 : `--verify` 를 쓸 이유가 없다는 §6 백로그의 결론은 **경희대 백업(ssh)에만
유효**하고, dataflow 3단계(NFS)에는 반대다. 24시간 로테이션을 못 따라간다.

#### 11.64 잘린 꼬리 서브런 — 어디까지 살릴 수 있는지 확정했다 ★

run 4291(§11.17 에서 죽음) 과 run 4293(§11.41 외부 접속으로 죽음) 은 둘 다 후처리가
덜 끝나 있었다. **`ZOMBIE FILE` 이라는 postrun 의 표시는 진단명이 아니다** — merge
매크로가 rc≠0 이면 무조건 붙는 이름이라, 실제 사유는 merge 로그를 봐야 한다.

**사유는 하나였다. 런이 죽으면서 마지막 SADC 파일이 안 닫혔다.**

```
log_merge_..._run4293_subrun90.txt 끝
   [END] sadc trg #= 5521865
   FADC subrun = 90, SADC subrun = 91
   Warning: file SADC_004293.root.00091 probably not closed, trying to recover
   Warning: no keys recovered, file has been made a Zombie
   [ERROR] Cannot open SADC file or ZOMBIE
```

**FADC 서브런 N 을 merge 하려면 SADC 서브런 N+1 이 필요하다**(SADC 가 뒤처져
기록되므로). 그래서 마지막 SADC 가 잘리면 **그 앞 서브런까지 같이 못 만든다.**

**★ 그런데 부분 Merged 는 정상 ROOT 파일로 남아 있다.** 매크로가 에러로 빠지기
전까지 쓴 것이 autosave 되어 있다. 확인 : `MERGED_004293.root.00090` 은 Zombie 가
아니고 `AbsEvent` 트리에 42,602 이벤트(정상 ~59,600 의 71%)를 갖고 있다.
재-merge 해도 크기가 바이트까지 같아 **결정적(deterministic)이다.**

그래서 **§11.52 와 같은 요령 — 껍데기를 건너뛰고 production 매크로를 직접 부른다.**

```bash
cd /home/frontend/DAQ/DAQ_cup/production/Code
root -l -b -q 'production_from_merged_v3_5v.cc(<런>,<서브런>,"<데이터디렉터리>")'
```

**결과**

| 런 | 전 | 후 | 한 일 |
|---|---|---|---|
| 4291 | FADC 870 / Merged 867 / PRD 866 | **Merged 869 / PRD 869** | sub 30 은 PRD 만 없어 직접 생성(61,140 ev, 온전) · sub 867 은 postrun 으로 정상 merge+PRD(61,909 ev) · sub 868 은 부분 Merged 에서 PRD 직접 생성(42,588 ev) |
| 4293 | FADC 92 / Merged 91 / PRD 90 | **PRD 91** | sub 90 을 부분 Merged 에서 직접 생성(42,602 ev) |

**남은 것은 각 런의 마지막 서브런 하나씩이고, 이건 복구 불가다.**

```
4291 sub 869   FADC_004291.root.00869 자체가 Zombie (22.7 MB / 정상 74 MB)
4293 sub  91   SADC_004293.root.00091 이 Zombie  ( 0.67 MB / 정상 8.9 MB)
   둘 다 ROOT 의 recover 가 "no keys recovered" 로 실패한다. 키가 하나도 없다
```

**이어받기 상태는 postrun 이 알아서 찾는다** — `--from 867` 로 주면 866 번 merge
로그에서 `(867, 1527, 52077777)` 을 읽어 온다. 손으로 넣을 필요가 없다.
`/scratch` 쪽 심볼릭 링크(§11.36)가 살아 있어 `--rawroot /scratch/RAW` 로 주면
Merged/PRD 는 `/Data_ssd` 에 쓰인다.

#### 11.65 ★ 그 결과 dataflow 가 이 두 런을 영원히 못 옮긴다

```bash
is_processed() {                       # scripts/dataflow.sh:161
   f=$(find -L "$1" -maxdepth 1 -name 'FADC_*.root.*' | wc -l)
   p=$(find -L "$1/PRD" -maxdepth 1 -name '*.root'    | wc -l)
   [ "$f" -gt 0 ] && [ "$p" -eq "$f" ]         # 정확히 같아야 한다
}
```

```
4293   FADC 92  PRD 91   ->  영원히 false. /Data_ssd 에 붙박이다
4291   FADC  0 (RAW 는 /scratch)  ->  §11.40 의 그 이유로 역시 false
```

**설계상의 구멍이다 — 쓰기 도중 죽은 런은 100% 가 될 수 없으므로 자동 이동
대상이 절대 되지 못한다.** 지금 `/Data_ssd/RAW` 에 런이 7개 쌓인 이유의 일부다
(`keep_ssd=2`). 어떻게 고칠지는 **사용자 판단 대기** — 후보는 셋이다.

1. 런 디렉터리에 `.postrun_final` 같은 표식을 두고 `is_processed` 가 그것도 인정
2. `PRD >= FADC - 1` 처럼 꼬리 하나를 봐주기 (조용히 틀릴 여지가 있어 권하지 않는다)
3. 이런 런은 `relocate-run.sh` 로 손으로 옮긴다 (지금 방식)

#### 11.66 run 4294 백업 — 진행 중

```bash
scripts/backup-khu.sh --params config/dataflow.params --mid /Data_ssd --run 4294
```

`--mid /Data_ssd` 가 핵심이다. 기본값은 `/data` 인데 4294 는 아직 SSD 에 있다.
대상 RAW 2880 · PRD 1441 · PNG 1440, 약 222 GB. **전부 로컬 NVMe 라 100 Mb
링크를 전혀 쓰지 않는다**(§11.37 의 그 이점). 로그는
`/Data_ssd/LOG/backup-4294.log`.

실측 속도 **약 7.2 MB/s** — 기대(15.7)의 절반이다. 같은 khu 링크를
`backup-queue-4288-4289`(4289 RAW, 3.6 MB/s) 가 함께 쓰고 있다. 둘이 합쳐
약 11.5 MB/s 로 링크 상한(15.7)에 못 미치므로 서로 굶기지는 않는다.
이 속도면 **약 8.5시간**이다.

### 2026-08-20 — 네트워크 끊김 뒤 전수 점검, 그리고 시트 기록 완료

#### 11.45 끊김의 피해는 없었다 — 확인한 것

세션 도중 네트워크가 끊겨 무엇이 상했는지 전수로 봤다. **수집·이동·백업 어느
것도 죽지 않았다.** DAQ 는 세 노드가 전부 `localhost` 라(§3) 애초에 외부
네트워크와 무관하다.

```
run 4294   heartbeat 나이 0초, phase=running, sub=1279, daqtime 21:20:03
           FADC 1000.24 Hz / SADC 1000.18 Hz
           FADC 1283 = SADC 1283,  Merged 1280 = PRD 1280   (--lag 3 그대로)
supervisor health OK 가 10분마다 끊김 없이 280회. 공백 2건은 08-19 새벽 4293 건
로그       [ERROR]/[WARN]/[FATAL] 0건. TCB 접속은 전부 127.0.0.1
링크       ssh khu 정상, /scratch 마운트 정상, 커널 링크 이벤트 0건
살아있는 것 backup-khu(4288 대조 중) · backup-trickle(양보 대기) ·
           finish-4290-4291(대기) · dataflow(4292 대조 중) · postrun · IBD 되채우기
```

끊긴 것은 **내 작업 쪽뿐이었다** — 시트 기록이 `--commit` 직전에 멈춰 있었다.

#### 11.46 ★ `Max subrun` 은 개수가 아니라 개수 − 1 이다 (§11.5 정정)

§11.5 는 "그 런 폴더의 서브런 **개수**"라고 적고 있었다. **틀렸다.**
기존 행 13개를 디스크와 맞대어 실측했다.

```
run   4085 4204 4207 4226 4232 4234 4237  4238  4239  4240  4241 4243 4246
시트    46   11   19   32  160   60 12721 11148 13019 11436  803 1781 5103
FADC    47   12   20   33  161   61 12722 11149 13020 11437  804 1782 5104
                                                                  전부 개수 − 1
```

**기준은 PRD 가 아니라 RAW(FADC) 다.** 4237 은 PRD 가 12720 뿐인데 시트는
12721 = FADC 12722 − 1 이다. 후처리가 덜 끝난 런에서 둘이 갈라지므로
PRD 로 세면 조용히 어긋난다. RAW 가 없고 PRD 만 있는 런은 PRD 로 센다.

**`RAW (GB)` · `PRD (GB)` 의 이진/십진 규약은 확정하지 못했다.** 기존 행이
서로 어긋난다 — run 4234 는 십진(`bytes/1e9`)에 맞고 run 4232 는 이진(2³⁰)에
가까우며, 4204·4207·4226 은 지금 디스크 값의 **절반쯤**이라 어느 규약으로도
재현되지 않는다(그 뒤 재처리로 PRD 가 커진 것으로 보인다). 차이가 7% 뿐이라
**기존 코드의 2³⁰ 을 그대로 뒀다.** 새로 쓰는 행끼리는 일관된다.

#### 11.47 RAW 와 PRD 가 다른 디스크에 있으면 RAW 를 0 으로 적던 버그

`append_runs.py` 는 런 디렉터리를 `/Data_ssd/RAW:/data/RAW:/scratch/RAW`
순서로 **한 번만** 고르고 그 안에서 RAW 와 PRD 를 둘 다 셌다.

```
run 4290   /Data_ssd/RAW/004290   FADC 0    PRD 200    <- 먼저 잡힌다
           /scratch/RAW/004290    FADC 200  PRD 200
        -> RAW (GB) = 0.0 으로 기록될 뻔했다
```

§11.40 에 적어 둔 그 상태(4290 의 RAW 는 `/scratch`, 산출물은 `/Data_ssd`)가
그대로 함정이 됐다. **RAW 와 PRD 가 각각 root 를 고르도록** 고쳤다. 고친 뒤
4290 은 RAW 15.4 GB 로 나온다. dataflow 가 옮기는 도중인 런(4292 는 `/data`
와 `/scratch` 양쪽)도 같은 이유로 안전해졌다.

곁들여 — 자격증명을 `$RENE_SHEETS_SA` -> `<저장소>/.config/rene/*.json` ->
`~/.config/rene/*.json` 순서로 **스스로 찾게** 했다. 기본값이
`~/.config/rene/sheets-sa.json` 이라 실제 위치(저장소 안)와 달라 `--creds`
없이는 언제나 `FileNotFoundError` 였다. 미리보기도 전부 보여 준다(전엔 3행).

#### 11.48 시트 기록 — run 4280~4292, 10개 행

```
기록 범위  A284:S293   (10행).  282 -> 292 행
검증       쓰기 전에 받아 둔 기존 282행과 쓴 뒤를 대조 -> 차이 0
제외       38개 런 (onlbit!=1 또는 stime 없음). 진행 중인 4294 도 뺐다
빈 칸      4280 은 PRD 가 없어 PRD (GB) 를 비웠다 (0.0 이 아니다)
```

`Max subrun` 은 1439 / 199 / 64 처럼 **개수 − 1** 로 들어갔다.

### 2026-08-20 (아침) — 알람·메일·자동 USB 복구를 붙였다 ★ 사용자 요청

상세는 `docs/ALARM.md`. 여기에는 왜 그렇게 만들었는지와 검증 결과만 적는다.

#### 11.55 무엇을 만들었나

§11.49 의 장애에서 드러난 구멍은 둘이었다. **아무도 두 시간 동안 몰랐다**는
것과, **사람이 손으로 밟은 복구 절차가 어디에도 없었다**는 것이다.

```
scripts/daq-alarm.sh      소리를 켜고 끈다. 사람이 끌 때까지 반복
scripts/daq-notify.sh     사건 하나를 알람+메일로 내보내는 단일 진입점
tools/notify/send_mail.py SMTP 발송
scripts/usb-recover.sh    진단 + usbreset + 확인 런  (최대 2회)
config/notify.params      위 넷이 함께 읽는다. .gitignore 대상
src/rcsupervisor.cc       --notify-cmd / --notify-params / --recover-cmd
                          --no-notify / --no-auto-recover
scripts/rcmon.sh          알람 중이면 붉은 배너
scripts/daq-tmux.sh       notify.params 가 있으면 자동으로 붙인다
```

감시자는 연속 실패 한계에서 **포기하기 전에** `recover-cmd` 를 한 번 부르고,
종료코드 0 이면 실패 카운터를 되돌려 수집을 이어간다.

#### 11.56 설계에서 신경 쓴 것 — 되돌리기 전에 읽을 것

- **안전 게이트를 없애지 말 것.** `usb-recover.sh` 는 맨 처음에 rcterm/daq/
  tcb/merger 와 7809·7814·7815 를 확인하고 하나라도 살아 있으면 exit 3 로
  물러난다. `usbreset` 은 진행 중인 런을 그 자리에서 깬다.
- **진단 없이 리셋하지 않는다.** USB 오류 근거가 없으면 exit 1.
- **최근 로그만 본다** (`recover_log_age_min`, 기본 60분). 처음엔 '최신 3개'로
  짰는데, 장애 로그가 몇 시간 뒤에도 최신 3개 안에 남아 **정상인 보드를 USB
  문제로 오진했다.** 실측으로 잡았다.
- **계수율은 합이 아니라 ADC 별 최솟값.** 한 보드만 죽으면 합·평균은 멀쩡해
  보인다. **§11.49 가 정확히 그 모양이었다** (FADC 먹통 / SADC 1000 Hz 정상).
  heartbeat 의 `ar=` 중 최솟값을 본다.
- **확인 런 없이 복구됐다고 하지 않는다.** 걸린 보드도 `lsusb` 에는 나온다.
  3분 런을 실제로 돌려 ① exit 0 ② 그 런 로그의 USB 오류 0건 ③ FADC 산출
  1 MB 이상 ④ ADC 별 계수율 최솟값이 문턱 이상 — 넷을 다 통과해야 한다.
  확인 런은 `--no-db --run 999999` 라 카탈로그를 더럽히지 않는다.
- **알림은 비동기, 복구는 동기.** 알림 실패가 감시자를 끌고 내려가면 안 된다.
  복구는 결과를 봐야 다음 행동을 정한다.
- **복구 스크립트가 이미 알렸으면 감시자는 `fatal` 을 또 보내지 않는다.**
- 알림·복구를 전부 **바깥 프로그램**으로 뺐다. 감시자가 `RunControl.cc` 를
  링크하지 않는 것과 같은 이유다(§2).

#### 11.57 검증 — 하드웨어를 전혀 건드리지 않고 10종 ★

가짜 `rcterm`/복구 스크립트로 돌렸다. `--bindir` 을 비우면 감시자의 `pkill`
정리가 통째로 생략되므로 **살아 있는 run 4301 옆에서 안전하게** 시험했다.

| 시험 | 결과 |
|---|---|
| 안전 게이트 (수집 중) | `rcterm daq tcb` + 포트 3개 감지, exit 3, 무접촉 |
| 진단 (장애 로그가 창 안) | `FADC` 지목 — 사람이 내린 판정과 일치 |
| 진단 (보드 정상) | "USB 문제 아님" exit 1 |
| 알람 켜기/상태/끄기 | 상태 파일·좀비 정리까지 확인 |
| 소리 경로 | `pw-play` OK / `aplay -D default` OK / `plughw:0,0` 실패(대체) |
| 감시자 A 복구 성공(0) | 실패 카운터 0 으로, 수집 계속, exit 0 |
| 감시자 B 복구 실패(2) | 포기 exit 2, `fatal` 중복 없음 |
| 감시자 C USB 아님(1) | 위와 동일 |
| 감시자 D `--no-auto-recover` | 복구 0회, `fatal` 발송 |
| 감시자 E heartbeat 정지 | `stale` 로 런 번호·사유까지 실어 알림 |

빌드는 clean, 경고 0 (ROOT 6.28/04 · GCC 11.5.0).

#### 11.58 아직 안 된 것 / 사용자 조치가 필요한 것

- ~~메일 자격증명~~ **✅ 완료. 실제 발송까지 확인했다** (§11.59). 책임자 1명과
  전문가 6명 모두에게 수신 확인 메일이 나갔다.
  **값에 `#` 을 쓰면 파서가 주석으로 잘라낸다.**
- **PC 스피커는 root 1회 조치가 필요하다. ★ `usermod` 로는 안 된다.**
  알람은 감시자가 띄우고 감시자는 tmux 서버에서 뻗어나오는데, 이미 떠 있는
  tmux 서버는 `usermod` 이전의 보조그룹을 붙들고 있다. 재로그인해도 tmux 를
  다시 띄우지 않는 한 적용되지 않는다(실측: 계정엔 `input` 이 들어갔는데
  tmux·감시자의 `Groups:` 는 그대로 `18 1001`). **udev 로 소유자를 주면**
  uid 로 판정되어 그 문제가 사라지고 DAQ 중단도 필요 없다. 규칙은
  `docs/ALARM.md`. 안 해도 사운드카드로는 울린다. **아직 안 했다.**
- **외부 스피커가 켜져 있는지 사람이 확인해야 한다.** `--test` 로 소리가 나는
  것은 확인했지만, 실제로 들리는지는 현장에서만 알 수 있다.
- **실제 보드가 걸린 상태의 자동 복구는 아직 못 봤다.** 다음 장애 때 확인된다.
- **새 바이너리는 감시자를 재시작해야 적용된다.** 스크립트 셋은 즉시 쓸 수 있다.

#### 11.59 메일·PC 스피커 설정에서 실측으로 확정한 것 (같은 날 오전)

사용자가 자격증명을 주어 채워 넣고 실제로 보내 봤다. **두 가지가 예상과 달랐다.**

**(1) Gmail 은 계정 비밀번호로 SMTP 를 받지 않는다.**

```
535 5.7.8 Username and Password not accepted.
https://support.google.com/mail/?p=BadCredentials
```

2단계 인증 뒤 발급하는 **앱 비밀번호(16자 소문자)** 여야 한다. 계정 비밀번호와
생김새부터 다르다. 받은 주소에 오타가 있어(`stmp.gamil.com`) `smtp.gmail.com`
으로 바로잡았다.

**앱 비밀번호를 받아 넣으니 곧바로 됐다.** 실측한 것 :

```
SMTP 로그인            ✓
책임자에게 실제 발송   ✓  sfc5302@…
daq-notify 전 경로     ✓  recovered 사건 -> mail rc=0, 알람은 안 울림(설정대로)
도배 방지              ✓  같은 사건 재발송 -> '300초 이내' 로 생략
recovery_failed 예외   ✓  코드상 throttle 을 건너뛴다
전문가 6명 발송        ✓  gmail 4 · naver 2 전원
```

구글은 앱 비밀번호를 네 자씩 띄어 보여주므로 **보이는 대로 붙여넣어도 되게**
`send_mail.py` 가 공백을 걷어낸다. 계정 비밀번호는 SMTP 로 쓸 수 없으니 파일에
남기지 않았다 -- 실제 계정 비밀번호를 평문으로 둘 이유가 없다.

**메일이 실패해도 알람은 울린다.** 실제 사건(`recovery_failed`)을 흘려
확인했다 — 알람이 켜지고, `rcmon` 에 붉은 배너가 뜨고, 메일만 `rc=4` 로
로그에 남았으며 `daq-notify.sh` 는 종료코드 0 으로 돌아왔다. 알림 실패가
감시자를 끌고 내려가지 않게 한 설계(§11.56)가 실제로 그렇게 동작한다.

**(2) ★ PC 스피커는 `usermod -aG input` 으로 해결되지 않는다.**

사용자가 `usermod` 을 실행해 계정에는 `input` 이 들어갔는데도 알람은 여전히
비프를 못 냈다. 원인은 **이미 떠 있는 프로세스의 보조그룹**이다.

```
id frontend            groups=1001(frontend),18(dialout),998(input)   <- 들어갔다
/proc/<tmux>/status    Groups: 18 1001                                <- 그대로다
/proc/<감시자>/status  Groups: 18 1001                                <- 상속했다
```

tmux 서버는 08-18 에 떴다. 알람은 감시자 -> tmux 서버 계보로 뻗어나오므로
**재로그인을 해도 tmux 서버를 다시 띄우지 않는 한(= 수집 중단) 적용되지
않는다.** 그룹이 아니라 **소유자**를 주면 uid 로 판정되어 이 문제가 사라진다.
udev 규칙은 `docs/ALARM.md`. DAQ 를 세우지 않아도 되고 재부팅에도 남는다.

**곁들여 확인** — `/etc/systemd/logind.conf` 의 `KillUserProcesses` 가 `no`
(기본값)라 **로그아웃해도 tmux 안의 DAQ 는 죽지 않는다.** 사용자가 재로그인
하겠다고 해서 먼저 확인했다.

**★ 안내를 여러 줄 heredoc 으로 준 것이 실수였다.** 붙여넣는 과정에서 깨져
`tee` 가 규칙 내용을 **파일 이름으로** 받았고, 저장소에 root 소유 빈 파일
여섯 개(`SUBSYSTEM==input,` `MODE=0660` 등)가 생기고 정작 규칙은 만들어지지
않았다. 치우고 **한 줄짜리 `echo ... | sudo tee`** 로 바꿨다.
**사람이 터미널에 붙여넣을 명령은 한 줄로 줄 것.**

#### 11.60 화면 복사가 안 되는 이유, 그리고 `claude-transcript`

사용자가 "화면을 드래그해 복사하면 제대로 안 된다"고 해서 추적했다.
**tmux 문제가 아니었다** — Claude Code 는 tmux 밖에서 돈다(`sshd -> bash ->
claude`, `TMUX` 없음). tmux 는 애초에 `mouse off` 다.

원인은 **Claude Code 의 TUI 가 마우스 추적을 켜는 것**이다. 그러면 터미널이
드래그를 '글자 선택'이 아니라 '앱에 보낼 마우스 이벤트'로 넘긴다.
`Shift` 를 누른 채 드래그하면 우회된다(macOS Terminal.app 은 `Fn`).

화면과 씨름하는 대신 **원본을 파일로 뽑는** 도구를 만들었다. 대화는
`~/.claude/projects/<경로>/*.jsonl` 에 그대로 쌓인다.

```
config/dotfiles/bin/claude-transcript   -> install.sh 가 ~/bin/ 에 설치
   --list / --last N / --all / -o 파일 / --redact 문자열 / --dir 경로
```

생각과 도구 호출은 빼고 **화면에 낸 글만** 뽑는다. 붙여넣을 수 있는 마크다운이
나온다.

**★ 뽑으면 비밀번호도 딸려 나온다.** 만들자마자 확인해 보니 앱 비밀번호가
섞여 있었다 — 어시스턴트가 답변에서 인용만 해도 그렇다. 견본 파일은 바로
지웠고, `--redact` 를 넣고 저장할 때마다 경고하도록 했다.
**남에게 넘기기 전에 훑어볼 것.**

**곁들여 고친 것 — CMake 가 dotfiles 스크립트의 실행 권한을 죽이고 있었다.**
`install(DIRECTORY ...)` 는 `USE_SOURCE_PERMISSIONS` 가 없으면 전부 644 로
깎는다. 그래서 설치 트리의 `dotfiles/install.sh` 를 §0.0 대로 바로 실행하면
`Permission denied` 였다. 원본 저장소에서 실행하면 되니 여태 안 드러났다.

검증 — 가짜 홈(`HOME=<임시>`)으로 설치해 **다른 PC 를 흉내냈다.** 권한 755 로
들어가고, `~/bin` 이 PATH 에 없으면 알려 주며, 그 홈에서 바로 실행된다.


#### 11.61 시트 되메움 · 발표자료 다시 만들기 (사용자 요청)

**(1) PC 스피커 udev 규칙 — 적용 확인.** 장치 소유자가 `frontend` 로 바뀌었고
알람의 '권한 없음' 경고가 사라졌다. 비프도 직접 울려 확인했다. 규칙 파일명은
`99-rene-pscpkr.rules`(오타)지만 **udev 는 파일명을 따지지 않으므로 그대로
동작하고 재부팅에도 남는다.** 문서의 확인 명령은 파일명에 기대지 않도록
`grep -rn 'PC Speaker' /etc/udev/rules.d/` 로 두는 편이 낫다.

**(2) 빠진 런 8개를 순서에 맞게 되메웠다.** 4200~4294 구간에 49개가 빠져 있었다.
로컬 디스크를 먼저 보고, 경희대를 크로스체크로 썼다.

```
빠진 49개 중  로컬에 데이터 있음 22  /  로컬에도 경희대에도 없음 27
              (없는 27개는 8/14 부팅 실패분. 실제로 데이터가 없다)
실데이터 기준으로 8개 선정  4208 4209 4210 4211 4276 4284 4291 4293
결과  301 -> 302행, 정렬 유지, 중복 0, 남의 행 293개 내용 변화 0건
```

**run 4291 이 압도적이었다** — 서브런 870개(14시간 40분), PRD 866개. 마감만
못 했을 뿐 실데이터다. `onlbit=0` 이라 옛 규칙이 걸러내고 있었다.

**시각은 로컬에서 끌어왔다.** DB 에 `stime` 이 없는 런은 TCB 로그 첫 줄(부팅)과
마지막 FADC 파일 mtime(자료가 멈춘 시각)으로 정한다. **끝을 TCB 로그 마지막
줄로 잡으면 안 된다** — rcterm 이 먼저 떨어져 나가고 DAQ 가 더 쓰는 경우가 있다
(4291 : 로그 22:43 / 마지막 파일 22:53). 유도한 값임을 `Data issue` 에 남긴다.

**★ 버그 하나를 만들었다 잡았다 — 같은 자리에 여럿 넣으면 거꾸로 박힌다.**
아래에서 위로 넣되 같은 index 에 계속 밀어 넣으면 나중 것이 위로 올라간다.
4208~4211 이 4211 4210 4209 4208 순으로 들어갔다. 정렬 키에 런 번호 내림차순을
더해 고쳤고, **그 네 행은 우리가 쓴 것이라 그 자리에서 다시 썼다.**

**(3) 크로스체크를 도구로 만들었다 — `scripts/backup-audit.sh`.**
로컬 1,705 / 경희대 2,940. **로컬에만 있고 백업이 안 된 런이 237개**다
(11.43 의 backlog 와 같은 것). 4200~4302 구간만 봐도 37개다.

```bash
scripts/backup-audit.sh                     화면으로
scripts/backup-audit.sh --mail              결과를 메일로 (daq-notify 의 backup_audit)
scripts/backup-audit.sh --deep 20           최근 20개는 파일 개수까지 대조
```

**읽기만 한다. 수집 중에 돌려도 안전하다.** 원격 목록은 `ssh` 한 번으로 통째로
받는다 — 런마다 붙으면 2천 번이라 몇 시간이 걸린다. `--deep` 도 원격 개수를
한 번에 받아 온다.

셋을 구분해 보고한다 : ① 로컬에만 있다(백업이 밀렸다) ② 원격에만 있다(로컬에서
정리된 옛 런, 정상일 수 있다) ③ 양쪽에 있으나 개수가 다르다(전송이 덜 끝났다).
**원격 `RAW/` 에는 FADC 와 SADC 가 함께 들어가므로 로컬 FADC 개수의 2배가 기준이다.**

**(4) 발표자료 3종을 새로 만들었다.** `tools/slides/` 에 코드로 찍는다.
LibreOffice 가 없어 눈으로 볼 수 없으므로 `audit.py` 로 배치를 수치 점검한다 —
슬라이드 밖으로 나간 도형, 넘치는 글상자, 겹치는 글. **만드는 동안 여섯 군데를
이것으로 잡았다.** 최종본은 세 자료 모두 `문제 없음`.

```
docs/RENE-daq-2026-08-overview-ko.pptx     21장  구조/개선/실측/앞으로
docs/RENE-daq-2026-08-overview-en.pptx     20장  같은 내용 영문
docs/RENE-daq-2026-08-operations-ko.pptx   11장  화면·조작·알람·대처
```

**`.pptx` 는 추적하지 않는다** (`.gitignore` 에 `*.pptx`). 생성기가 저장소에
있으므로 새 PC 에서는 만들어 쓴다 — 이쪽이 정본이고 산출물은 언제든 다시 나온다.

```bash
for f in overview_ko overview_en operations_ko; do python3 tools/slides/make_$f.py; done
python3 tools/slides/audit.py docs/*.pptx
```

옛 자료(`~/DAQ/presentations/`)는 2026-08-17 에서 멈춰 있어 데이터 흐름·모니터링·
보안·알람이 전부 빠져 있었다. 새 것은 그 뒤를 담고, 글머리 기호 대신 흐름도와
막대·표로 보여 준다.


### 2026-08-20 (새벽) — FADC 보드가 먹통이 되어 DAQ 가 2시간 9분 멎었다 ★★

#### 11.49 무슨 일이 있었나 — 로테이션 직후 5연속 부팅 실패

**run 4294 는 24시간을 정상으로 채웠다**(`onlbit=1`, 86,362,424 ev, `ENDED`/exit=0).
문제는 그 다음 런부터다.

```
03:16:08  [SUP] rotation time reached; ending run gracefully
03:16:09  ENDED run=004294          <- 4294 자체는 깨끗하다
03:16:21  cycle 4 launch -> run 4295 ... 03:16:33  exit=code 2
          4296 · 4297 · 4298 · 4299 도 똑같이 12초 만에 exit=2
03:20:17  [SUP] FATAL too many consecutive failures; giving up
```

**다섯 번 전부 같은 자리, 같은 오류다. FADC 한 장만 먹통이었다.**

```
FADCDAQ_0042xx.log   (4295~4299 전부 동일)
  STARTRUN 수신 -> trigger started
  [ERROR] USB3Read: read error:LIBUSB_ERROR_IO [sid=3]
  [ERROR] USB3ReadReg: read error:LIBUSB_ERROR_IO [sid=3]
  [ERROR] CupDAQManager::ReadBCount: error in reading buffer count [sid=3]
  [WARNING] daq will be ended by error
```

- **SADC 는 다섯 런 모두 `LIBUSB_ERROR` 0건.** TCB 도 pedestal 측정까지 정상으로
  끝낸다(FADC/SADC pedestal 값이 로그에 정상 출력됨). 죽은 것은 FADC 뿐이다.
- **`dmesg` 에 FADC 보드의 disconnect/re-enumerate 기록이 없다.** 선이 빠지거나
  전원이 나간 것이 아니라 **펌웨어/엔드포인트가 걸린 상태**다. `usbreset` 이
  다루는 바로 그 경우다.
- run 4294 자신의 로그에도 `LIBUSB_ERROR_TIMEOUT` 이 하나 있는데 **03:16:09,
  ENDRUN 직후 정리 단계**라 성격이 다르다. 정상 마감을 방해하지 않았다.
- **네트워크와 무관하다.** 이 시각 `ssh khu` 정상, `/scratch` 마운트 정상,
  100 Mb 링크는 dataflow 대조로 12.3 MB/s 포화 가동 중이었다.

**감시자는 설계대로 동작했다.** 5회까지 재시도하고 포기했다. 다만 **재시도마다
런 번호를 하나씩 태운다** — 4295~4299 다섯 개가 그렇게 없어졌다. 하드웨어가
물리적으로 고장난 경우에는 재시도가 번호만 갉아먹으므로, 같은 노드가 같은
오류로 연속 실패하면 더 일찍 멈추는 편이 나을 수 있다(미구현).

#### 11.50 복구 절차 — 이 순서 그대로 하면 된다

```bash
# 1) 아무것도 안 돌고 있는지 확인. 하나라도 살아 있으면 usbreset 금지
pgrep -af 'rcsupervisor|rcterm|install/bin/(daq|tcb|merger)'
ss -ltn | grep -E '7809|7814|7815'          # 둘 다 비어야 한다

# 2) 보드 리셋 (NOTICE 보드 3개를 전부 리셋한다)
src/usbreset

# 3) 짧은 런으로 확인. 감시자를 바로 띄우면 또 5번 실패하고 번호만 태운다
install/bin/rcterm --params config/rcterm.params --max-runs 1 --run-length 0.05 \
    --quiet --desc 'FADC board check'
#    합격 기준 : exit=0, onlbit=1, nfadc/tfadc 가 약 1000 Hz,
#                FADC 서브런이 70 MB 대, FADCDAQ 로그에 LIBUSB_ERROR 0건

# 4) 감시자 기동. desc 는 반드시 config/rundesc.txt 것을 쓴다 (§11.20)
install/bin/rcsupervisor --params config/rcsupervisor.params -- --desc '<rundesc.txt 첫 줄>'
```

**실측 결과** — 리셋 뒤 run 4300(3분)이 `onlbit=1` / 180,152 ev / 180.34 s =
**999.0 Hz** / `LIBUSB_ERROR` 0건. 이어서 감시자를 띄워 run 4301 이 1007.5 Hz 로
가동. `rundesc` 가 run 4294 와 **바이트 단위로 일치**함을 확인했다(4288~4294 와
한 측정으로 묶인다). **공백 03:16~05:25, 2시간 9분.**

세션이 이미 있으면 `daq-tmux.sh --start` 는 재구성하지 않고 그냥 붙는다
(살아있는 런 보호). 그때는 위 명령을 `tmux send-keys -t daq:1.2` 로 supervisor
pane 에 직접 보내면 된다.

#### 11.51 ★ `src/usbreset` 는 인자가 없으면 곧바로 리셋한다 — `--help` 가 없다

사용법을 보려고 인자 없이 실행했더니 **NOTICE 보드 3개를 찾아 그대로 리셋**했다.

```
[INFO] %s: %d NOTICE devices found: searchnotice     <- 서식 문자열이 그대로 찍힌다
[INFO] %s: reset USB device %s: main                 x 3
dmesg :  usb 2-1.2 (NKFADC500) · 2-6 (TCB) · 2-1.4 (M64ADC)  reset SuperSpeed USB device
```

이번엔 수집이 멎어 있어 피해가 없었고 오히려 필요한 조치였지만, **돌고 있는
런이 있었으면 그 자리에서 깨졌다.** `--help` / `-h` 도 없다.

**규칙 — 이 파일은 사용법 확인 목적으로도 실행하지 말 것.** 무엇을 하는지는
§2 와 이 절에 적혀 있다. 실행은 위 §11.50 의 1번을 통과한 뒤에만.

#### 11.52 ★ `/scratch/LOG` 의 파일명 하나가 EIO 라 PRD 가 조용히 누락됐다

run 4294 는 FADC/SADC/Merged 가 1440인데 **PRD 만 1439** 였다. 빠진 것은
서브런 **01381** 하나. 추적해 보니 원인이 데이터가 아니라 **로그 파일**이었다.

```
production_from_merged_v3_5v.sh:44   date > $LOG
    $LOG = /scratch/LOG/log_production_v3_5v_run4294_subrun1381.txt
    -> Input/output error

같은 디렉터리에 다른 이름은 전부 정상 생성된다 (short / 인접 서브런 이름 / 긴 이름 모두 OK)
그 이름만 :  ls -> No such file or directory   /   create -> Input/output error
인접 파일  :  subrun 1379 · 1380 · 1382 · 1383 은 전부 존재
```

**NFS 서버(10.0.0.10) 쪽 디렉터리 엔트리가 깨진 것이다.** `/scratch/LOG` 는
348,592개짜리 디렉터리다. 조회는 ENOENT, 생성은 EIO 라 어느 쪽으로도 손댈 수 없다.

**왜 조용히 넘어갔나** — 스크립트가 `root ... >> $LOG 2>&1` 로 매크로를 부른다.
리다이렉트가 EIO 로 실패하면 **매크로가 아예 실행되지 않는다.** postrun 은
`[FAIL] Producing FAILED : Subrun 1381 (0초)` 한 줄만 내고 다음으로 간다.
0초짜리 FAIL 은 데이터 문제가 아니라 **이 종류의 문제**라고 보면 된다.

**우회 — 껍데기를 건너뛰고 매크로를 직접 부른다.** postrun 의 완료 판정은
산출물 파일 stat 이므로(§5.8) 로그가 없어도 정상으로 인식된다.

```bash
cd /home/frontend/DAQ/DAQ_cup/production/Code
root -l -b -q 'production_from_merged_v3_5v.cc(4294,1381,"/Data_ssd/RAW/004294")'
```

76.4 MB 짜리 PRD 가 정상 생성됐고 **run 4294 는 FADC 1440 = SADC 1440 =
Merged 1440 = PRD 1440 으로 완결**됐다. 그 로그 파일 하나는 끝내 못 만들었다 —
서버 쪽 fsck 가 필요하며 사이트 조치 사항이다.

**곁들여 확인** — `dmesg` 의 `sde1` EXT4 aborted journal / superblock I/O error
(08-18, 08-19)는 **마운트돼 있지 않은 유령 장치**다. 우리가 쓰는 것은
`nvme0n1(/Data_ssd)` · `md126p1(/data)` · `10.0.0.10:/data(/scratch)` ·
`sdf1(/backup_hdd)` 이고 이 장애와 무관하다.

#### 11.53 정리한 것

| 대상 | 처리 |
|---|---|
| run 4294 PRD 01381 | 매크로 직접 호출로 생성. **1440/1440 완결** |
| `/Data_ssd/RAW/004295~004299` | 삭제. 전부 빈 ROOT 헤더(FADC 8,157 B = 이벤트 0, PRD 547 B) |
| `/Data_ssd/LOG/*_00429[5-9].log` | **남겼다.** 장애 증거다 |
| 구글시트 | run 4294 한 행 추가 (`A294:S294`). 기존 293행 무결 확인 |
| run 4300 | 3분짜리 보드 점검 런. 시트 등재 여부는 사용자 판단 대기 |

`/Data_ssd/RAW` 최상위의 빈 `Merged`/`PNG` 디렉터리는 2024-11 자 잔재이며 무해하다.

#### 11.54 아직 열려 있는 것

- **FADC 보드가 왜 걸렸는지는 모른다.** 6개월치 로그에서 이 증상은 처음이다
  (`/Data_ssd/LOG` 기준 4295~4299 뿐). 재발하면 §11.50 으로 복구하고, 잦아지면
  보드/케이블/USB 허브를 의심할 것.
- **감시자가 같은 오류로 5번 재시도하며 런 번호를 태운다.** 노드별 오류가
  동일하면 더 일찍 멈추는 편이 낫다. 미구현.
- `/scratch/LOG` 의 깨진 dirent (§11.52). 서버 쪽 조치 필요.
- NFS 가 아직 인터넷에 열려 있다 (§11.41 의 남은 항목). 그대로다.

### 2026-08-19 — 이동 규칙을 체크섬 기반으로 바꾸고, 심볼릭 링크 잔재를 걷어냈다 ★

#### 11.35 사용자 지침 — 이동은 rsync + 체크섬 + 삭제 (영구)

**`mv` 를 쓰지 않는다. 복사 -> 체크섬 대조 -> 통과한 것만 원본 삭제.**
규칙 자체는 §8 에 적었다. 코드 세 곳을 그 규칙에 맞췄다.

| 파일 | 무엇이 바뀌었나 |
|---|---|
| `scripts/backup-khu.sh` | `verify_dir()` 신설. 전송 뒤 `rsync -c -n -i` 로 대조하고, 불일치가 있으면 **완료 표시를 하지 않는다**. 전에는 원격 **개수만** 봤다 |
| `scripts/dataflow.sh` | `move_dir` 을 **보낸다 -> 대조한다 -> 지운다** 세 걸음으로 분리. 전에는 `--remove-source-files` 로 보내면서 지워, 깨졌는지 알기 전에 원본이 사라졌다 |
| `scripts/relocate-run.sh` | **신규.** 목적지가 원본을 가리키는 심볼릭 링크인 경우를 스테이징으로 처리 |

**★ 체크섬 대조는 걱정한 만큼 비싸지 않다 — 실측.** §6 백로그에 "체크섬
검증은 100 Mb/WAN 에서 너무 비싸 넣지 않았다"고 적었던 판단은 **틀렸다.**

```
run 4290 PRD   198 개 / 15.4 GB
   전송   17분 40초  (13.9 MB/s)
   대조      1분 00초              ← 전송의 1/18
```

양쪽이 **각자** 체크섬을 계산해 결과만 주고받으므로 링크로 오가는 것은
거의 없다. 비싼 것은 디스크 읽기뿐이다. **`--no-verify` 를 쓸 이유가 없다.**

#### 11.36 심볼릭 링크는 왜 있었나 — 그리고 왜 이제 없어야 하나

사용자 지적으로 추적했다. **만든 것은 `postrun.sh` 의 `ensure_outdirs()` 이고,
`--outroot` 를 줬을 때만 생긴다** (`scripts/postrun.sh` 의 `ln -s`).

**당시에는 근거가 있었다.** 그때는 RAW 가 `/scratch` 에 있었고, 산출물만이라도
로컬 NVMe 에 만들려고 `--outroot /Data_ssd/RAW` 를 줬다 (서브런당 41.0 ->
27.7초, §5.8). production 매크로가 `$DataDir/Merged/...` 를 **경로로 박아
쓰기** 때문에, 매크로를 고치지 않으려고 기대하는 자리에 링크를 걸었다.

**2026-08-17 (§11.13) 부터 그 이유가 사라졌다.** 수집 자체가 `/Data_ssd` 로
왔으므로 산출물을 딴 데 만들 까닭이 없다. 지금 설계는 이렇다.

```
/Data_ssd 에서 수집하고 후처리한다  (RAW · Merged · PRD · PNG 전부 여기)
   -> 경희대 백업, 체크섬 대조
      -> 대조를 통과한 것만 /scratch 로 옮긴다
```

**어느 단계에도 심볼릭 링크가 낄 자리가 없다.** 실측으로 확인했다.

```
돌고 있는 postrun   --follow --jobs 3 --lag 3 --rawroot /Data_ssd/RAW   (--outroot 없음)
daq-tmux.sh:155     위와 동일하게 띄운다
run 4292            /Data_ssd/RAW/004292/{Merged,PNG,PRD} 전부 실제 디렉터리, 링크 0개
                    /scratch/RAW/004292 는 아예 없다
사이트 전체 링크    정확히 4개. 전부 4290·4291 것이다
```

`--outroot` 를 **폐기 표시**했다 — 주면 큰 소리로 알린다. 지우지는 않았다.
`--archive-now` 가 이 값에 의존하는데, 그것이 바로 옛 구성을 되돌리는 도구다.

#### 11.37 4290·4291 백업 — 순서를 바꾼 것이 6배를 갈랐다 ★

착수 시점 실측 : 원격에 **`RAW`/`PRD`/`PNG` 밑으로 4288~4292 가 하나도 없다.**
§11.15 에서 보낸 것은 4290 의 `config` · `DAQLOG` · `db` 뿐이었다.

처음에 RAW 부터 보냈더니 **2.2 MB/s** 였다. 원인은 우리가 아니었다 —
`/scratch` 가 포화 상태였다.

```
/scratch 읽기    3.6 MB/s     ← 다른 분석 작업(TrigCounts.C, DrawStep2_v7.C,
                                 AB_MuonCheck.C)과 monitoring 되채우기가 함께 쓴다
/Data_ssd 읽기   2.9 GB/s
```

**그래서 PRD 를 먼저 보내도록 순서를 바꿨다.** 4290·4291 의 PRD 는 심볼릭
링크를 따라 `/Data_ssd` 에서 읽으므로 **100 Mb 링크를 전혀 쓰지 않는다.**

```
/scratch 에서 읽을 때    2.2 MB/s
/Data_ssd 에서 읽을 때  13.9 MB/s     ← 6배. KHU 링크 상한(15.7)에 근접
```

**옮기기 전에 백업하라**는 규칙이 여기서 나온다. 산출물이 `/Data_ssd` 에
있는 동안 보내면 빠르고, `/scratch` 로 보낸 뒤에 백업하면 6배 느리다.
사용자가 지시한 순서(수집 -> 후처리 -> 백업 -> 이동)가 성능 면에서도 옳다.

`/Data_ssd/LOG/backup-driver.sh` 로 1단계(PRD·DAQLOG·config) -> 2단계(RAW·PNG)
순서로 돌린다. 로그는 `/Data_ssd/LOG/backup-4290-4291.log`.

**기존 원격 폴더는 건드리지 않는다** — `--delete` 를 쓰지 않고, 새 디렉터리
(`RAW/004290` 등)와 새 파일만 만든다.

#### 11.39 백업 마커가 백업을 실패시키던 버그 ★

run 4290/4291 의 RAW 가 **정확히 하나씩 모자라다**며 실패했다.

```
로컬  find -L "$src" -maxdepth 1 -type f   = 401   ← .backup_done 을 센다
rsync --exclude='.*'                       → 400   ← 그건 보내지 않는다
원격  ls -1 | wc -l                        = 400
검사  400 < 401  ->  "원격 개수 부족"              ← 실제로는 전부 갔다
```

`push_dir` 의 `n_src` 가 **rsync 의 제외 규칙을 반영하지 않는** 기존 버그다.
하필 그 점파일이 이 스크립트가 만드는 마커라, **백업이 성공할수록 다음
백업이 실패하는** 모양이었다. 고침 — `! -name '.*'` 을 붙였다.

**4288/4289 에는 영향이 없었다.** 카테고리 순서가 `RAW PRD PNG ...` 라
RAW 를 할 때는 아직 마커가 없다. 4290/4291 만 §11.15 때 만들어진 마커를
이미 갖고 있어서 걸렸다. `PRD`/`PNG` 는 하위 디렉터리이고 점파일이 없어
무사했다. **RAW 는 실제로 전부 전송돼 있었다** (원격 400 / 1740 개 확인).

#### 11.40 run 4290 후처리 완결 — 그런데 dataflow 가 막힌 이유는 그게 아니었다

빠져 있던 서브런 197·198·199 를 처리했다. 61초, 실패 0.
**FADC 200 = SADC 200 = Merged 200 = PRD 200.** 새 PRD 3개는 경희대에
보충 전송하고 체크섬 대조까지 마쳤다(원격 201개 = 200 root + DLY_THR 로그).

**하지만 dataflow 의 "후처리 미완료. 대기" 는 이것 때문이 아니었다.**

```bash
is_processed() {
   f=$(find -L "$1" -maxdepth 1 -name 'FADC_*.root.*' | wc -l)   # /Data_ssd/RAW/004290 -> 0
   p=$(find -L "$1/PRD" -maxdepth 1 -name '*.root' | wc -l)
   [ "$f" -gt 0 ] && [ "$p" -eq "$f" ]                            # f=0 이라 언제나 false
}
```

4290 의 FADC 는 `/scratch` 에 있고 `/Data_ssd/RAW/004290` 에는 Merged/PRD 만
있다. **PRD 를 200개로 채워도 이 검사는 영원히 통과하지 못한다.**
4290·4291 은 애초에 1단계(`/Data_ssd` -> `/data`)에 태울 런이 아니다 —
RAW 가 이미 최종 목적지에 있다. 진짜 해소는 `relocate-run.sh` 로
`/Data_ssd` 에서 Merged/PRD 를 걷어내는 것이고, 그러면 `/Data_ssd/RAW` 에
`keep_ssd`(=2) 개인 4292·4293 만 남아 1단계가 할 일이 없어진다.

#### 11.41 ★★ run 4293 이 외부 접속 때문에 죽었다 — 사이트 조치 필요

2026-08-19 03:15, run 4293 이 시작 1시간 31분 만에 죽고 감시자가 4294 로
재시작했다. DB 는 `onlbit=0, 'aborted; run started but was not finalized'`.

**감시자가 죽인 것이 아니다. rcterm 이 스스로 `exit=2` 로 빠졌다.**
직전까지 완전히 정상이었다(03:15:01, sub=90, 1007 Hz).

```
TCB_004293.log
03:15:01 [INFO]    [TCB]: new client connection, fd 15, ip: 78.142.18.222, port 63881
03:15:11 [INFO]    [TCB]: adding to list of sockets at 1
03:15:11 [WARNING] [TCB] Unknown command [788586541] received
03:15:11 [INFO]    [TCB]: host disconnected, fd 9, ip: 78.142.18.222
03:15:11 [WARNING] [TCB] Unknown command [1971156704] received
03:15:26 FADCDAQ/SADCDAQ : host disconnected 127.0.0.1  ← rcterm 이 떨어져 나갔다
```

**`78.142.18.222` 는 외부 주소다.** DAQ 제어 포트가 인터넷에 열려 있다.

```
ss -ltn
LISTEN 0 3 0.0.0.0:7809      ← TCB
LISTEN 0 3 0.0.0.0:7814      ← FADCDAQ
LISTEN 0 3 0.0.0.0:7815      ← SADCDAQ
이 PC 의 공인 IP : 203.230.111.71 (enp0s31f6)
```

프로토콜(§3)에 인증이 없다. 32바이트를 보낼 수 있으면 누구나 `ENDRUN`(3)
이나 `EXIT`(4)를 보낼 수 있다. **이번엔 쓰레기 값이라 연결만 끊고 끝났지만,
우연히 유효한 명령이면 런을 세울 수 있다.**

**전수 조사 결과 (2026-08-19).** 처음에 `/Data_ssd/LOG` 만 보고 "2건뿐"이라고
적었던 것은 **틀렸다** — 거기엔 최근 런 로그밖에 없다. `/scratch/LOG` 의 DAQ
로그를 전부 훑었다.

```
외부 접속 기록   749 건
고유 IP          153 개
기간             2026-02-04 ~ 2026-08-17  (6.5 개월, 상시)
영향받은 런      41 개
맞은 포트        TCB 264 · SADCDAQ 254 · FADCDAQ 231   (세 개 전부)
월별             2월 39 · 5월 174 · 6월 199 · 7월 220 · 8월 108   (늘고 있다)
실제로 바이트를 보낸 것 = "Unknown command"   960 건
```

**★ 그런데 960건 중 유효 명령값(1,2,3,4,10,12,14,21)과 맞은 것은 한 번도 없다.**
가장 흔한 값은 `0`(212회) 과 `788586541`·`1971156704`(각 137회)인데, 뒤의 둘은
2월과 8월에 똑같이 나온다 — 같은 스캐너의 고정 페이로드다. **외부에서 DAQ
명령을 성공시킨 적은 없다.**

**피해는 명령이 아니라 소켓 자리를 뺏는 데서 온다.** TCB 는 `LISTEN 0 3` 으로
backlog 가 3뿐이다. 스캐너가 자리를 차지하면 rcterm 의 연결이 밀려난다 —
4293 로그의 `adding to list of sockets at 1` 직후 rcterm 이 떨어져 나간 것이
정확히 그 모양이다.

**인과가 분명한 것은 run 4293 하나다.** 외부 접속이 있었던 41개 런 중 37개는
`onlbit=1` 로 정상 마감됐다. 나머지 4개(3527 · 4180 · 4222 · 4291)는 시각이
붙지 않는다 — 특히 **run 4291 의 마지막 외부 접속은 15:25 이고 죽은 것은
22:49 라 7시간 반 차이다. §11.17 은 여전히 원인 미상이다.** 외부 접속으로
설명하지 말 것.

**★ 조치 완료 (2026-08-19 20시경. 사용자가 root 로 실행).**

착수 시점에는 "firewalld 가 active 이지만 설정을 읽을 권한이 없다"고만 적어
두었는데, 사용자가 `firewall-cmd --list-all` 을 붙여 주어 확정됐다.
**추측이 아니라 `public` 존이 DAQ 포트를 명시적으로 열고 있었다.**

```
public (active)
  interfaces: enp0s31f6                        <- 공인 IP (203.230.111.71) 쪽
  ports: 7809/tcp 7813/tcp 7814/tcp 7815/tcp 7816/tcp 50022/tcp 4280/tcp
         2049/tcp 111/tcp 2049/udp 111/udp 40000-40002/udp 40000-40002/tcp
```

여섯 개를 뺐다 — 쓰는 것 셋(`7809` `7814` `7815`)과 **아무도 듣지 않는 죽은
규칙 셋**(`7813` `7816` `4280`. `ss -ltn` 으로 확인).

```bash
for p in 7809 7813 7814 7815 7816 4280; do
  sudo firewall-cmd --permanent --zone=public --remove-port=$p/tcp
done
sudo firewall-cmd --reload
```

**닫아도 수집에 영향이 없다 — 근거와 실측 둘 다 있다.**

- run 4294 의 config 가 세 노드 전부 `localhost` 다
  (`SERVER 0 TCB localhost 7809` 등). firewalld 는 루프백을 거르지 않는다.
- 닫은 직후 실측 : heartbeat 나이 **1초**, `phase=running`, `subrun=1006`,
  FADCDAQ 1001.24 Hz / SADCDAQ 1001.18 Hz. run 4294 는 그대로 돌았다.

차단 자체는 아직 **바깥에서 확인하지 않았다.** 변경 전 마지막 외부 접속이
15:11:57(`210.117.211.131`, 세 포트 동시 = 스캐너)이고 변경은 그 뒤라, 로그의
공백은 증거가 못 된다. 다만 `public` 은 `target: default` 라 명시 허용하지
않은 것을 거부하므로 규칙상으로는 확정이다. 굳이 실측하려면 외부 지점
(예 `ssh khu`)에서 접속해 보면 되는데, 살아 있는 런의 backlog(3) 를 잠깐
쓰므로 급하지 않다.

**★ 남은 것 — NFS 가 아직 인터넷에 열려 있다. DAQ 포트보다 성격이 나쁘다.**

```
public 존   2049/tcp 2049/udp 111/tcp 111/udp        <- 그대로 열림
ss -ltn     0.0.0.0:2049  0.0.0.0:111  0.0.0.0:20048  <- 전부 LISTEN
```

이 PC 가 NFS **서버**도 돌리고 있다. DAQ 포트는 6.5개월간 유효 명령이 한 번도
안 맞았지만(위 전수 조사) 이쪽은 그런 종류가 아니다. **다만 누가 마운트하고
있는지 모른 채 닫으면 남의 작업을 끊는다.** 먼저 확인할 것 :

```bash
sudo exportfs -v                                # 무엇을 누구에게 내보내나
ss -tn state established '( sport = :2049 )'    # 지금 붙어 있는 클라이언트
firewall-cmd --get-active-zones                 # enp1s0(10.0.0.11) 는 어느 존인가
```

마지막 줄이 필요한 이유 — **`enp1s0` 이 `public` 의 interfaces 목록에 없다.**
다른 존에 있다는 뜻이고 그 존이 무엇을 여는지는 위 출력에 안 나온다.

근본적으로는 `daq`/`tcb` 가 `0.0.0.0` 이 아니라 `127.0.0.1` 에만 bind 하는
것이 옳다. 단일 PC 구성(`kISREMOTEDAQ=False`)이라 외부에서 붙을 이유가 없다.
그것은 CUPDAQ 쪽 변경이다. 방화벽은 그 전까지의 가림막이다.

#### 11.42 ★ 돌고 있는 스크립트를 제자리에서 고쳐 오류를 만들었다 (내 실수)

`dataflow` pane 에 `backup-khu.sh: 줄 469: ====...====: 명령어를 찾을 수 없음`.

```
03:49:55  dataflow 가 backup-khu.sh 를 띄움 (run 4292, 325 GB — 7시간 걸린다)
10:57:15  §11.39 의 점파일 버그를 고치며 파일을 제자리에서 덮어씀   ← 돌고 있는데
11:07:49  그 인스턴스가 바이트 위치로 이어 읽다 주석 조각을 실행
```

**bash 는 스크립트를 바이트 위치로 이어 읽는다.** `dataflow.sh` 와
`postrun.sh` 는 rename 으로 갈아끼웠으면서 `backup-khu.sh` 만 덮어썼다.

피해는 제한적이다 — 이미 읽어 파싱한 `for` 루프 안(실제 백업)은 무사하고,
아직 안 읽은 꼬리(마지막 db 스냅샷)만 깨진다. db 는 dataflow 가 주기마다
다시 뜨므로 잃은 것이 없다. **run 4292 백업은 정상 완료됐다.**

**규칙 — 스크립트를 고칠 때는 언제나 임시 파일에 쓰고 `mv` 로 갈아끼운다.**
그러면 돌던 프로세스는 옛 inode 를 그대로 붙들어 무사하고, 다음 실행부터
새 코드가 적용된다.

#### 11.43 옛 런(4200~4290) 백업 — 저우선순위로 걸어 두었다

사용자 지적으로 확인 : **원격 `RAW/` 에 4200~4290 구간이 사실상 비어 있다.**

```
로컬 /scratch/RAW   64 개 런 (4200~4290)
원격 RAW/           004219 · 004288 · 004290 뿐        ← 나머지 61 개 미백업
원격 RAW/ 전체      2,222 개 런, 000488 ~ 004292
원격 여유           20 TB
```

`scripts/backup-trickle.sh` 를 새로 만들었다. **양보하는 것이 이 도구의 전부다.**

1. 더 급한 작업(`backup-queue-*`, `finish-*`, dataflow 이동, relocate)이 돌면
   **아예 멈춰 서서 기다린다.** 이것이 가장 중요하다.
2. `rsync --bwlimit`(기본 2000 KB/s = 링크의 약 1/4). **병목이 네트워크라
   nice/ionice 만으로는 양보가 되지 않는다.**
3. `nice 19` + `ionice -c2 -n7`. `-c3`(유휴)은 쓰지 않는다 — 굶어서 진행이
   멈춘다(§11.11 실측).

런 하나씩, **최신 것부터**. 진행은 `.backup_done` 마커에 남으므로 언제 끊어도
이어진다. 기본 카테고리는 **`RAW` 만** — 이 런들에는 `Merged`/`PNG`/`PRD` 도
있어서 전부 보내면 양이 몇 배가 된다. 필요하면 `--only RAW,PRD,PNG`.

```bash
scripts/backup-trickle.sh --dry-run
scripts/backup-trickle.sh --from 4200 --to 4290              # 지금 걸어 둔 것
```
로그 : `/Data_ssd/LOG/backup-trickle-4200-4290.log`

#### 11.44 `/scratch` 와 경희대 저장소는 다른 디스크다 — 확인함

원격 `df` 가 우리 `/scratch` 와 **숫자까지 같아서**(140T / 113T / 20T / 86%)
같은 저장소가 아닌지 의심했다. 아니다.

```
로컬  10.0.0.10:/data                      -> /scratch          최상위 RAW LOG CONFIG ...
원격  jammanbo.lo:/srv/storage/raid1/data  -> /store/cpnr-data   최상위 JSNS2 RENE
시험  /scratch 에 표시 파일을 만들고 원격에서 찾음 -> 없음
```

**백업은 제대로 별도 저장소에 쌓이고 있다.** 크기가 우연히 같았을 뿐이다.
같은 의심이 다시 들면 위 표시 파일 시험이 가장 빠르다.

#### 11.38 아직 열려 있는 것

- **run 4288·4289 백업 — 사용자 승인, 큐에 넣었다 (2026-08-19 01:10).**
  `/Data_ssd/LOG/backup-queue-4288-4289.sh` 가 4290/4291 작업이 끝나기를
  기다렸다가 이어서 돈다. 로그는 `/Data_ssd/LOG/backup-4288-4289.log`.
  이 둘은 4290/4291 과 달리 **RAW·PRD·PNG 가 전부 `/scratch` 의 실제
  디렉터리**(심볼릭 링크 0개)라, PRD 를 먼저 보내는 요령이 통하지 않는다 —
  어느 카테고리든 포화된 100 Mb 링크로 읽어야 한다. 각 1440 서브런,
  합쳐 약 440 GB. **현재 경합 수준에서 1.5~2.5일 걸린다.**
- `/scratch/LOG` 의 postrun merge 로그(`log_merge_*.txt`, 전체 343,733개)를
  백업할지. 원격 `DAQLOG` 는 `FADCDAQ`/`SADCDAQ`/`TCB` 세 종류만 쌓는 구조다.
- ~~`dataflow.sh` pane 을 재시작해야 한다~~ **완료 (2026-08-19 01:07).**
  `sleep 600` 대기 중일 때 `C-c` 후 재실행했다. 새 pid 가 `(deleted)` 가 아닌
  살아있는 파일을 읽는 것과, 체크섬 코드가 들어 있는 것을 확인했다.
  **여기서 배운 것 — 돌고 있는 셸 스크립트는 rename 으로 갈아끼워야 한다.**
  제자리에서 고치면 bash 가 바이트 위치로 이어 읽다가 엉뚱한 것을 실행한다.
  갈아끼운 뒤에는 반드시 재시작해야 새 코드가 적용된다.


### 2026-08-18 (오후) — 모니터링 입력을 PRD 로 일원화했다 ★

#### 11.29 무엇이 문제였나

착수 시점의 실측 : 1단계(run_summary)는 run 4291 까지 갔는데 **2·3단계는
4240 에서 멎어 있었다.** 원인은 우리 쪽 버그가 아니라 **입력의 성격**이었다 —
2단계가 `/scratch/junkyo/SampleFiles/Step3` 의 페어링 산출물을 읽기만 했고,
거기에는 `Run004221` · `Run004237` 대의 것뿐이었다. 분석 쪽이 4286~4291 을
아직 안 돌렸다는 뜻이고, 그 디렉터리는 `ojk` 소유 755 라 우리가 만들 수도 없다.

사용자 지적대로 **세 단계 전부 production 산출물(PRD)을 봐야 한다.**
1단계는 §11.28 에서 이미 바꿨고, 이번에 2·3단계를 옮겼다.

#### 11.30 무엇을 만들었나

```
tools/monitor/RenePrdSingles.h   PRD -> clean single   (= 분석 Step1 + Step2)
tools/monitor/RenePairing.h      single -> 후보 수     (= 분석 Step3 + Step4)
tools/monitor/BuildPairSummary.C 위 둘을 엮고 표를 쓴다 (입력 절반을 재작성)
```

**물리는 베끼지 않았다.** 파형 -> NPE 변환과 컷 상수는 분석 쪽
`essential/helper_functions.cc` · `AnalysisCondition.h` 를 **통째로 include**
한다(§5.8 과 같은 원칙). 예외는 페어링 loop 하나뿐인데, 분석 쪽
`RunBothChannels.C::PairAndSelect` 는 파일을 쓰는 것이 목적이라 **세기만 하는
진입점이 없어서**다. 그래서 갈라질 수 있고, 그래서 실행할 때마다 분석 Step4 가
있는 런에서는 **수를 대조하고 다르면 알린다.**

곁들여 :

- 1·2단계 모두 런 디렉터리를 **여러 root 에서** 찾는다
  (`/Data_ssd/RAW:/data/RAW:/scratch/RAW`, 앞이 이긴다). dataflow 가 런을
  옮기므로 한 곳만 보면 놓친다.
- **R_LL 을 3단계가 재지 않는다.** 2단계가 런 전체의 single 을 이미 세므로
  `pair_summary.tsv` 의 `r_ll` 열을 읽는다 — 표본이 아니라 **전수**다.
  이로써 3단계에서도 `junkyo` 의존이 사라졌다. `rll.tsv` 는 만들지 않는다.
- `pair_summary.tsv` 에 `# schema 2`. 열이 달라졌으므로 옛 파일은 조용히
  잘못 읽지 않고 버린다. 옛 값은 `/scratch/RunSummary/old-schema1/` 에 남겼다.
- 런 하나가 끝날 때마다 표를 쓴다(예전엔 전부 끝나고 한 번). 런당 몇 분~몇
  시간이라 중간에 끊기면 다 날아갔다.
- FADC 원시 파일 mtime 도 **모든 root 에서** 찾는다. 예전 `--outroot` 구성은
  RAW 가 `/scratch`, PRD 가 `/Data_ssd` 라 둘이 다른 디스크에 있다. 못 찾아
  PRD mtime 으로 떨어지면 런마다 기준이 달라져 추이 그림의 x축이 어긋난다.

#### 11.31 검증 — 두 토막으로 나눠서 실측했다 ★

나누지 않으면 어디가 틀렸는지 알 수 없다.

**(A) 재구성** — run 4237 서브런 98~100 을 순서대로 돌려 carry 를 세운 뒤
서브런 100 을 같은 서브런의 분석 Step2 part 와 대조.

```
single 개수  here 5,739  analysis 5,739   일치
evt_id 어긋남 0 · pe 어긋남 0 (최대 0 NPE) · 간격 어긋남 0 (최대 0 us)
```

**single 목록이 비트 단위로 같다.** clean 11,356 개도 §11.27 에 적어 둔 값과
같다.

**(B) 페어링** — 분석 Step2 에서 읽은 **같은 입력**(run 4237 전체, single
72,658,494 개)에 `RenePairing.h` 를 돌려 Step3/Step4 와 대조.

```
_nGd  paired 7,879/7,879   acci 3,023/3,023     ibd 2,097/2,097     ibd_acci 1,377/1,377
_nH   paired 798,857/…     acci 664,641/…       ibd 601,739/…       ibd_acci 551,422/…
```

**여덟 개 전부 일치.** (A)+(B) 로 PRD -> single -> 후보 전 구간이 확정됐다.

#### 11.32 ★ 비용 — 어느 디스크에 있느냐가 13배를 가른다

같은 코드, 같은 서브런인데 :

| 위치 | 서브런당 | 24시간 런(1440) | 병목 |
|---|---|---|---|
| `/Data_ssd` (로컬 NVMe) | **1.11초** | 약 27분 | CPU (cpu 1.09 ≈ real 1.11) |
| `/scratch` (100 Mb NFS) | 14.58초 | 약 5.8시간 | 링크 (§11.12) |

**런이 `/Data_ssd` 에 있을 때 돌리는 것이 압도적으로 유리하다.** dataflow 가
`/scratch` 로 보내고 나면 13배가 된다. run 4237 처럼 12,720 서브런짜리는
`/scratch` 에서 51시간이다 — 옛 런을 되채우는 것은 급하지 않다.

서브런마다 single 을 캐시한다(`<OUT>/cache/singles`). 실측 — run 4290(197
서브런) 처음 228초, 캐시 재사용 **0.7초**, 수는 동일. 캐시 14 MB(서브런당
71 KB)라 24시간 런이면 약 100 MB. 캐시에 그때 쓴 문턱과 veto 창을 적어 두고
값이 바뀌면 무시한다.

#### 11.33 실제로 돌린 것

```
run 4290  서브런 197  live 11,820 s  single 1,047,623  R_LL 88.63 Hz   [228 s]
   _nGd  paired 103     ibd 26      acci 10.9      cand 15.1 ± 6.1
   _nH   paired 9,490   ibd 8,019   acci 7,494.3   cand 524.7 ± 124.4
run 4291  서브런 865  live 51,900 s  single 4,607,001  R_LL 88.77 Hz  [1,019 s]
   _nGd  paired 478     ibd 153     acci 99.0      cand 54.0 ± 15.8
   _nH   paired 40,997  ibd 34,787  acci 32,929.5  cand 1,857.5 ± 259.9
```

3단계까지 통과해 4개 점으로 7쪽 그림과 PNG 가 새로 나왔다.
보정 rate 는 `_nGd` 123.6 ± 49.6 (4290) / 100.6 ± 29.5 (4291) /day.
되채우는 순서는 **최신 런부터**다.

**맞물리는 것 셋을 확인했다.**

- **옛 표와 이어진다** — Part B 의 run 4237 `_nGd` `ibd 2,097`/`ibd_acci 1,377`
  은 옛 표의 `acci 1,363.2` · `cand 733.8` 과 그대로 맞는다(`0.99 x 1,377`).
  입력을 바꿔도 **같은 런이면 같은 행**이 나온다.
- **1단계와 livetime 이 맞는다** — 4291 이 `51,899.941` 대 `51,899.9 s`.
- **깨진 서브런을 두 단계가 독립적으로 같은 곳에서 짚었다** — run 4291 서브런
  866. 그 런이 쓰기 도중 끊겨 마지막 파일이 잘려 있다(§11.17). 조용히 넘기지
  않고 1단계는 `읽지 못한 서브런 1 개`, 2단계는 `[WARN] ... 읽지 못했다` 로
  알린다.

#### 11.34 고칠 때 다시 밟기 쉬운 것

- **Step2 컷 순서** — muon -> after-muon -> saturation. 바꾸면 범주별 수가
  달라진다. `muonTime` 갱신이 `dt` 계산보다 먼저인 것도 그대로 두어야 한다.
- **single 문턱 비교는 `float` 로 깎아서** 한다. Step2 가 float 로 저장하므로
  double 로 비교하면 경계에 걸친 이벤트에서 결과가 갈린다.
- **carry 는 런 전체에 이어 간다.** 서브런마다 0 부터 다시 세면 서브런 경계를
  넘는 coincidence 창이 깨진다. 그래서 서브런은 **번호 순서대로** 처리한다.
- `pair_summary.tsv` 의 열 순서는 `BuildRateTrend.C` 가 그대로 읽는다.
  `WriteTsv` 를 건드리면 3단계도 함께 볼 것 (§11.28 과 같은 함정이다).

### 2026-08-18 (새벽) — 중단 상태 정리와 재기동 (run 4292 가동)

#### 11.17 착수 시점의 실측 상태

DAQ 가 **멎어 있었다.** `rcsupervisor` / `rcterm` / `daq` / `tcb` / `merger` 전부
없고 7809·7814·7815 도 비어 있었다. tmux 세션 `daq` 도 없다.

마지막 런은 **4291** — 08-17 08:16 시작, 08-17 22:53 에 끊겼다.
DB 행은 `stime`/`etime`/`onlbit` 이 전부 NULL 인 고아 행이었다.

| 근거 | 값 |
|---|---|
| 마지막 heartbeat (`/Data/LOG/rcterm.hb`) | 22:49:29, `phase=running` `subrun=875` `daqtime=52203.2` `totev=104,223,444` |
| 마지막 FADC 서브런 | `00869`, 22:53:53, **22 MB** (정상 74 MB) → 쓰기 도중 끊김 |
| 서브런 수 | FADC 870 / Merged 867 / PRD 867 |

heartbeat 가 22:49 에 멈춘 뒤에도 DAQ 는 22:53 까지 파일을 썼다. **rcterm 이 먼저
사라지고 DAQ 가 남아 있다가 나중에 죽은 모양**이다. 무엇이 죽였는지는 로그가
남아 있지 않아 확정할 수 없다 — `/Data/LOG/rcsupervisor.log` 는 §11.10 의
삭제된 inode 문제로 되살아나지 않았고, `rcterm.log` 는 그 뒤 23:32 의
`--dry-run` 테스트 한 줄로 덮여 있다. **추측하지 않고 사실만 적는다.**

#### 11.18 run 4291 을 DB 에 마감 표기했다

§11.2 의 선례(4284 등)와 `MarkFailedRunInDB()` 의 규약을 그대로 따랐다 —
`onlbit=0`, 시간·개수 컬럼은 **NULL 로 남긴다**(DAQ 가 보고하지 않은 값을
파일 mtime 으로 추정해 채우면 나중에 진짜 기록과 구분할 수 없다).
근거는 `runlog` 에 문장으로 남겼다.

```sql
UPDATE runcatalog SET onlbit=0, runlog='aborted; run started but was not
  finalized (marked 20260818-013000); last heartbeat 2026-08-17 22:49:29
  phase=running subrun=875 daqtime=52203.2 totev=104223444; last FADC
  subrun 00869 written 22:53:53 and is truncated' WHERE runnum=4291;
```

수정 전 스냅샷을 `/Data_ssd/runcatalog.pre-4291-mark.db` 에 남겼다.

#### 11.19 `/Data_ssd` 용량 압박은 해소됐다 — §11.7·§11.9 를 대체한다

```
/Data_ssd  3.7T 중 3.3T 여유 (8% 사용)      ← §11.9 의 "7일 뒤 가득 참" 은 무효
/data      32T 중 31T 여유
/scratch   140T 중 20T 여유 (86% 사용)      ← 이제 여기가 가장 빡빡하다
```

`/Data_ssd` 에 남은 것은 `004290`(30 GB) · `004291`(130 GB) 둘뿐이다. 세션 사이에
정리가 있었던 것으로 보이나 **무엇을 누가 지웠는지는 확인하지 못했다.**

`dataflow.sh --once --dry-run` 은 조용히 끝난다. 정상이다 — `keep_ssd = 2` 이고
SSD 에 런이 정확히 2개라 1단계 대상이 없고, `/data/RAW` 가 비어 있어 2·3단계도
할 일이 없다. **파이프라인이 막힌 것이 아니라 흘려보낼 것이 없는 상태다.**

#### 11.20 재기동 시 런 설명(desc)이 끊기던 문제 — `config/rundesc.txt`

`daq-tmux.sh` 는 `config/rundesc.txt` 가 있으면 그 내용을 `-- --desc` 로 넘기는데
**그 파일이 사이트에 없었다.** 그대로 기동하면 `rcterm.params` 의
`desc = RENE cup continuous data taking` 가 쓰여 4288~4291 과 `rundesc` 가
달라지고, DB 에서 같은 측정으로 묶이지 않는다. §11.4 에서 손으로 복원했던 것과
같은 일이 매번 반복될 자리다.

- run 4290 의 `rundesc` 에서 rcterm 이 자동으로 붙이는 `, Split T [m] = 1` 을 떼어
  `config/rundesc.txt` 를 만들었다. 재조립해 **바이트 단위로 일치**함을 확인했다.
- **줄 끝 공백 한 칸이 실제로 의미가 있다.** 원본이 `... No source ` 로 끝나므로
  이것을 빠뜨리면 `No source,` 가 되어 어긋난다(만들면서 한 번 겪었다).
- `daq-tmux.sh` 가 주석·빈 줄을 버리고 첫 내용 줄만 쓰도록 고쳤다. 예전에는
  `cat` 통째였다.
- `config/rundesc.txt` 는 `.gitignore` 에 넣고 `.example` 을 추가했다. HV 값 같은
  사이트 값이라 `*.params` 와 같은 취급이다.

**desc 의 `26.08.14.` 는 이제 날짜가 맞지 않는다.** 이전 런들과 묶으려고 일부러
그대로 두었다. 새 측정 구간을 시작할 생각이면 `config/rundesc.txt` 를 고칠 것.

#### 11.21 재기동 — run 4292 가동 확인

`scripts/daq-tmux.sh --start` 와 `git push` 둘 다 **이 세션의 권한 정책에 막혀
사용자가 직접 실행했다.** 우회하지 않았다. 결과는 확인했다.

```
rcsupervisor  pid 104512   --params config/rcsupervisor.params -- --desc '...'
rcterm        pid 104547   --max-runs 1 --run-length 24.016667 --quiet
tmux daq      2026-08-18 01:43:55 생성
heartbeat     run=4292 phase=running   FADC 999.98 Hz / SADC 1023.75 Hz
```

**`rundesc.txt` 가 의도대로 동작했다** — run 4292 의 `rundesc` 가 run 4290 과
**바이트 단위로 일치**한다. 4288~4292 가 카탈로그에서 한 측정으로 묶인다.
`--dry-run` 으로 먼저 확인한 부팅 순서(FADCDAQ → SADCDAQ → TCB)와 `-p 60`,
`rawdatadir=/Data_ssd` 도 그대로 반영됐다.

푸시는 `git fetch` 후 `git log origin/main..HEAD` 가 비었음을 확인했다.
**이 PC 에서 push 는 Claude 가 끝낼 수 없다** — origin 이 HTTPS 이고 자격증명이
`credential.helper cache --timeout=84000` 뿐이며 SSH 키는 등록돼 있지 않다.
캐시가 만료되면 `could not read Username` 으로 실패하므로, 커밋까지만 하고
사용자에게 안내한 뒤 위 방법으로 확인할 것.

#### 11.22 저장소 정리 — 추적할 것과 지운 것

작업 트리에 오래 방치돼 있던 미추적 파일 넷을 정리했다. **사용자 판단으로
둘은 추적하고 둘은 지웠다.**

| 대상 | 처리 | 근거 |
|---|---|---|
| `src/usbreset` | 추적 | NOTICE USB 보드 리셋. 부팅 실패 때 손에 잡혀야 한다 |
| `src/NOTICE_CODE_RUN.sh` | 추적 | 벤더 보드 점검 매크로 래퍼. 보드가 응답하는지 rcterm 밖에서 본다 |
| `old_build/` (47파일 1.0MB) | 삭제 | CMake 잔재. 안의 유일본 없음을 확인하고 지웠다 |
| `both_command` | 삭제 | 런 명령 메모. 내용이 DB 에 남아 있다 |

지우기 전에 **유일본이 없음을 실측으로 확인**했다.

- `old_build/{usbreset, NOTICE_CODE_RUN.sh}` 는 `src/` 것과 **바이트 동일**
- `old_build/sample_command_README` 의 내용은 `both_command` 안에 그대로 있었다
- `both_command` 의 상세 desc(SADC PID/THR 배열, TLT 구성)는 **런 카탈로그에
  392개 행(run 3877~4281)으로 남아 있다.** 필요하면 여기서 꺼낸다

```bash
sqlite3 /Data_ssd/runcatalog.db "select rundesc from runcatalog where runnum=4281;"
```

두 실행물의 성격과 주의사항은 §2 에 적었다. **둘 다 하드웨어를 직접 건드리므로
수집 중에는 돌리지 말 것.** 경로가 이 PC 에 하드코딩되어 있다는 것도 함께.

#### 11.25 run_summary — 분석 산출물에서 DAQ 운용 지표를 뽑는다

사용자 요청으로 새 도구를 만들었다. 상세는 `tools/monitor/README.md`.

```
tools/monitor/run-summary.sh              -> /scratch/RunSummary/run_summary.{txt,tsv}
tools/monitor/BuildRunSummary.C           (ROOT 매크로. 껍데기가 이것을 부른다)
```

**물리 분석 코드는 `/home/ojk/analysis3` 것을 그대로 읽는다.** 복제하지 않았다
(§5.8 에서 production 매크로를 호출만 한 것과 같은 이유다). 1순위로
`Monitor/monitor_Run<N>.root` 의 `T_Monitor` 를, 없으면
`Step1/step1_Run<N>.root` 의 `T_LiveTime` 을 읽는다.

**제약 — `/home/ojk/analysis3` 와 `/scratch/junkyo/SampleFiles` 는 `ojk` 소유
755 라 `frontend` 가 쓸 수 없다.** 그래서 코드는 이 저장소에, 산출물은
world-writable 인 `/scratch` 아래 두었다. 입력은 읽기만 한다.

**설계에서 신경 쓴 것 — `0` 과 `-` 를 구분한다.** 계수가 없는 서브런이 섞이면
합만으로는 '전부 더한 것'과 '있는 것만 더한 것'이 구분되지 않는다. 그래서
계수마다 값이 있던 서브런 비율을 `cov[%]` 로 함께 낸다. 실제로 run 4237~4239 는
`target` 이 `0` 이고 `cov` 는 100 이었다 — 누락이 아니라 그 production 에
표적 계수기가 없었던 것이다. 이걸 구분하지 않았으면 조용히 틀린 표가 됐다.

`muon`(Step2 `T_Muon`)은 **SADC veto 태그와 같은 것을 센다.** 실측으로 `veto`
열과 수가 정확히 일치한다(4237~4240 네 런 모두). 별개 물리량이 아니다.

**검증** — run 4063 · 4084 · 4221~4234 · 4237~4240 으로 monitor 경로 /
Step1 대체 경로 / 이어붙이기 / 건너뛰기 / 정렬 / 미분석 런 무시를 전부 실측.
현재 표에 15개 런, 누적 livetime 33.6일.

**아직 안 한 것** — 자동화(지금은 수동 실행), 그리고 `runcatalog.db` 와의 대조.
DB 의 `nfadc`/`tfadc` 는 DAQ 가 보고한 값이고 run_summary 의 `n_events`/`live` 는
데이터에서 나온 값이라, 나란히 놓으면 수집과 저장 사이의 손실이 보인다.

#### 11.26 pair_summary — neutrino candidate 까지 (§11.25 의 다음 단계)
※ **입력 부분은 2026-08-18 오후에 무효가 됐다. §11.29~11.34 로 대체한다** —
페어링을 더 이상 읽어 오지 않고 PRD 에서 직접 한다. 우발 빼기 규약과 선원 런
구분은 그대로 유효하다.

단계마다 코드 하나, 스크립트 하나로 나눴다(사용자 제안).

```
1) run-summary.sh + BuildRunSummary.C   -> livetime, 종류별 이벤트 수
2) ibd-summary.sh + BuildPairSummary.C  -> IBD 후보 수 (채널별)
```

페어링은 **새로 하지 않는다.** `RunBothChannels.C` 가 만든 `T_IBD` /
`T_IBD_Acci` 를 읽기만 한다. (※ 이 문장은 §11.30 에서 뒤집혔다.) 우발 빼기는 `DrawIBD.C` 의 규약을 그대로 따랐다 —
on-time 창폭과 off-time 창폭이 달라서 `(DT_MAX-DT_MIN)/DT_MAX` 를 곱해 뺀다.
배율을 1 로 두면 과하게 빼서 후보가 낮게 나온다.

**컷 상수는 `essential/AnalysisCondition.h` 를 직접 include 한다.** 베끼면
저쪽이 컷을 바꿨을 때 이 표만 조용히 틀린다. 덕분에 알게 된 것 —
`README_pipeline.md` 는 n-Gd S2 를 `[7.77,9.36]` 이라 적었지만 **코드에서 그
줄은 주석이고 실제로는 `[6.0,10.0]`** 이다.

**선원 런을 구분하는 것이 이 도구의 핵심 판단이다.** AmBe·Cf252 교정 런은
후보가 백만 단위로 나온다(4224 nGd : cand 844,815 / S/B 272.9 대 4237 nGd :
cand 734 / S/B 0.54). 런카탈로그 `rundesc` 에서 선원 이름을 뽑아 `runtype.tsv`
를 만들고, **채널별 합계는 `src=none` 인 런만 더한다.** 종류를 모르면(`?`)
안전하게 뺀다.

지금 값 (선원 없는 런 5개, livetime 29.8일) :
`_nGd` cand 2,192±101 = **73.5±3.4 /day** (S/B 0.54) ·
`_nH` cand 166,633±1,950 = 5,589±65 /day (S/B 0.09).
**개략값이다** — 우발만 뺀 것이고 효율·우주선 배경 보정이 없다.

**★ 버그 하나를 만들었다 잡았다 — tsv 에 `-` 를 쓰면 행이 사라진다.**
값이 없을 때 `txt` 처럼 `-` 를 쓰면 되읽기의 `>>` 가 실패해 그 행이 통째로
버려진다. run_summary 가 15행에서 8행으로 줄고 run 4084 가 없어진 뒤에야 알았다.
`FmtF`(txt, `-` 를 낸다) 와 `FmtRaw`(tsv, 항상 숫자) 를 나눴다. **표에 열을
추가할 때 이걸 다시 밟기 쉽다.**

#### 11.28 1단계 입력을 production 산출물(PRD)로 바꿨다 ★

사용자 지적 — run_summary 는 **production 을 마친 데이터**를 봐야 한다.
입력을 `SampleFiles/{Monitor,Step1}` 에서
**`/scratch/RAW/<런>/PRD/PRD_<런>.<서브런>.root`** 로 바꿨다.

PRD 의 `Event` 트리에서 직접 센다.

- **`EventType` 의 뜻은 추측하지 않고 실측했다.** run 4237 서브런 101 에서
  `EventType==1` 10,918 개가 전부 `F_Triggered>0`, `==2` 51,738 개가 전부
  `S_Triggered>0`, `==3` 381 개는 양쪽. 따라서 **1=target only, 2=veto only,
  3=both** 이고 `total=1+2+3`, `target=1+3`, `veto=2+3`.
- **`TCBTRGTime` 은 약 16.78초(2²⁴×1000 ns)마다 되감긴다.** 60초 서브런에
  서너 번 감긴다. `AnalysisStep1.C` 의 규칙(`if (t<prev) offset+=prev`)을 그대로
  따랐다. 풀지 않으면 livetime 이 음수가 되거나 16초로 나온다. carry 는
  **런 전체에 이어 간다** — 그래야 서브런 사이 빈 시간까지 한 축에서 잰다.
- **PRD 파일에 TTree cycle 이 여러 개다**(`Event;2`, `Event;3` — 생산 중
  autosave). `Get("Event")` 가 최고 cycle 을 주고 그것이 완전한 것이다.
  **cycle 을 더하면 두 번 센다.**

**검증 — 기존 분석 체인과 정확히 일치한다.**

```
PRD 직독     run 4234  subrun 61  live 2486.5 s  total 14,627,857
Step1 경유   run 4234  subrun 61  live 2486.5 s  total 14,627,857
```

**속도가 문제다.** 파형을 빼고 두 가지 가지만 읽어도 `/scratch` 가 100 Mb
링크라(§11.12) 서브런당 약 1.3초다 — 24시간 런(1440) 약 30분, 12,720 서브런
런은 몇 시간. 그래서 `--newest N` 으로 끊는다(`monitor-all.sh` 기본 2개).
지금 PRD 가 있는 런이 **1,406개**라 끊지 않으면 첫 실행이 며칠 물린다.
런 하나가 끝날 때마다 파일을 써서 중간에 끊겨도 한 것은 남는다.

**열이 바뀌어 `# schema 2` 를 넣었다.** 옛 tsv 는 조용히 잘못 읽지 않고
거부한다. 2·3단계가 이 열 순서를 그대로 읽으므로(`live_s` 자리가 밀리면
`span_s` 를 livetime 으로 쓰게 된다) 함께 고쳤다. **`WriteTsv` 를 건드리면
`BuildPairSummary.C` · `BuildRateTrend.C` 도 같이 볼 것.**

Step2 계수(`n_clean`/`n_muon`/`n_aftermu`)는 PRD 에 없으므로 1단계에서 뺐다.
그 정보는 2·3단계가 쓰는 것이라 잃은 것은 없다.

#### 11.27 rate_trend — 시간축 추이와 효율 보정, 그리고 자동화

3단계로 완성했다. 각 단계가 코드 하나 + 스크립트 하나다.

```
1) run-summary.sh  + BuildRunSummary.C   livetime, 종류별 이벤트 수
2) ibd-summary.sh  + BuildPairSummary.C  IBD 후보 수 (채널별)
3) rate-trend.sh   + BuildRateTrend.C    효율 보정 + 시간축 그림
   monitor-all.sh                        위 셋을 순서대로 (--follow 로 반복)
```

x축은 **그 런의 DAQ 시작 시각**이다. 표가 누적되므로 런이 끝날 때마다 그림
오른쪽 끝에 점이 하나 붙는다. 7쪽(후보 수 / 보정 전 rate / **보정 rate** /
효율 / 우발 / R_LL / 누적)이고 쪽마다 PNG 도 나온다. 두 채널이 100배쯤
차이나서 후보·rate 쪽은 **로그축**이다 — 선형이면 n-Gd 이 안 보인다.

**효율은 새로 만들지 않고 분석 쪽 정의를 그대로 썼다.**
`eps_T = exp(-DT_MIN/tau) - exp(-DT_MAX/tau)` (`diagnostics/EffCutFlow.C:86`,
tau = n-Gd 25 / n-H 171 us), `eps_iso = exp(-R_LL*(ISO_PRE+ISO_POST))`
(`diagnostics/IsolationEfficiency.C:62`). **`eps_E` 는 봉우리 fit 이 필요해
자동으로 못 구한다 — 기본 1.0 이고 보정에서 빠져 있다** (`--eps-e` 로 넣을 수 있다).

**★ R_LL 을 n_clean/live 로 추정하면 안 된다.** (표본으로 재던 방식은
§11.30 에서 전수로 바뀌었다. 아래 '왜 안 되는지'는 그대로 유효하다.) Step2 의 `T_Event` 에는 에너지
문턱이 없어서(muon/afterMu/saturation 컷만) 1.2 MeV 미만이 절반쯤 섞여 있다.
실측 — run 4237 서브런 100 에서 `T_Event` 11,356 개 중 1.2 MeV 이상은
**5,740 개뿐**. 그대로 썼으면 R_LL 이 두 배가 되고 보정 rate 가 부풀려졌다.
그래서 Step2 part 를 **서브런 20개 표본으로 열어 직접 센다**(rate 라 전수
조사가 필요 없다). `rll.tsv` 에 캐시해 런당 한 번만 잰다.

지금 값 — R_LL 92~95 Hz 로 안정, eps_T 0.942 / eps_iso 0.945 / eps_tot 0.890.
`_nGd` 보정 rate 93.3 → 81.9 → 83.7 → 59.5 /day (run 4237~4240).

**문서와 코드가 어긋난 곳을 또 찾았다** — `README_pipeline.md` §4-1 에 적힌
매크로 11개(`IsolationEfficiency.C` 등)가 최상위에 없다. 전부
`diagnostics/` 에 있다. 인용할 때 경로를 확인할 것.

**자동화** — `monitor-all.sh --follow` (기본 1시간). 각 단계가 이미 처리한 런을
건너뛰므로 반복이 안전하다. 한 바퀴마다 채널별 가장 최근 점을 한 줄로 찍는다.
**tmux 화면 배치는 건드리지 않았다**(§11.24 에서 막 정한 것이라) — 붙이려면
`tmux new-window -t daq -n monitor '...--follow'`.

#### 11.24 pane 이름을 바꿨더니 레이아웃 복원이 깨졌다 ★교훈

사용자 요청으로 pane 제목 둘을 바꿨다.

```
monitor                                 -> DAQ Run Status(monitor)
dataflow (ssd -> data -> khu -> scratch)
     -> dataflow: /Data_ssd(RAW)->/data(PRD)->khu(backup)->scratch(save)
```

**`daq-layout.sh` 가 pane 을 제목으로 찾는다는 것을 잊고 있었다.** 그것도
`index($0,t)==1` 로 **앞부분 일치**였다. `"DAQ Run Status(monitor)"` 는
`monitor` 로 시작하지 않으므로 바꾼 즉시 `monitor pane 을 찾을 수 없다` 로
죽었다. 실행해 보고 알았다.

수정 — 부분문자열 일치(`index($0,t)>0`)로 바꿨다. 제목은 사람이 읽으라고
붙이는 것이라 앞뒤로 말이 붙는 게 자연스럽다. 열쇠말 다섯(`monitor`
`supervisor` `postrun` `work space` `dataflow`)은 서로 다른 제목에 겹쳐
나오지 않는 것을 확인했다. **§5.2 에서 ADC 종류를 `name[0]` 이 아니라
부분문자열로 판정하기로 한 것과 같은 성격의 실수**다.

**곁들여 원래 있던 버그 하나를 찾았다.** 레이아웃을 실제로 돌려 보니
`postrun` pane 이 **1행**이었다. 왼쪽 열을 아래에서 위로 잡는 코드였는데,
`tmux resize-pane -y` 는 그 pane 의 **아래쪽 경계**를 움직인다. postrun 을
4행으로 만든 뒤 supervisor 를 7행으로 만들면 그 경계가 도로 내려와 postrun 이
1행으로 찌그러진다. "두 번 적용해 보정한다"는 주석은 오히려 반대였다.

위에서 아래로(`monitor` → `supervisor`, 마지막 `postrun` 은 나머지를 받게)
바꾸니 159x39 창에서 **24 : 7 : 5** 로 정확히 떨어진다(28:8:5 를 36행에
정규화한 값). 반복 실행해도 같은 값이다.

```
DAQ Run Status(monitor)   73x24      work space   85x26
supervisor                73x7       dataflow:    85x11
postrun                   73x5
```

#### 11.23 아직 열려 있는 것

- run 4291 의 남은 서브런(FADC 870 대 PRD 867) 후처리. 재기동했으니 postrun
  pane 이 따라잡을 것이다. **확인하지 않았다.**
- 예전 구성(`Merged`/`PRD` 가 심볼릭 링크)인 4290·4291 을 어떻게 할지는 여전히
  §11.16 의 열린 질문이다.
- 이동 체인 실전 통과. `/Data_ssd` 에 런이 `keep_ssd`(=2) 개를 넘어야 1단계가
  돈다. **4292 가 끝나고 후처리까지 완료되면 그때가 첫 기회다.**
- **다음 확인 지점 : 2026-08-19 01:43 경 로테이션(4292 → 4293).** 통과하면
  로테이션 3회 연속 무결이 된다.

### 2026-08-17 (밤) — 데이터 흐름 재설계 : 수집 -> 백업 -> 장기보관

#### 11.13 무엇을 만들었나

사용자 요구는 한 문장이었다. **RAW 는 `/Data_ssd` 에 수집하고, 후처리를 거친
파일들은 `/data` 로 옮기고, 경희대 서버에 성격별로 rsync 백업하고, 백업이 끝난
것은 `/scratch` 로 보내 장기 보관한다.** 이것을 스크립트 두 개로 구현했다.

| 파일 | 하는 일 |
|---|---|
| `scripts/dataflow.sh` | 3단계 이동 (재작성). 설정 파일·백업 연동·부속 파일 이동 추가 |
| `scripts/backup-khu.sh` | **신규.** 성격별 카테고리 rsync + 원격 개수 검증 + 재개 마커 |
| `config/dataflow.params(.example)` | **신규.** 두 스크립트가 함께 읽는 설정 |
| `docs/DATAFLOW.md` | **신규.** 구조와 실측 근거 |

```
   /Data_ssd  ──1──►  /data  ──2──►  khu:/store/cpnr-data/RENE
   (NVMe 3.7T)        (32T)     └──3──►  /scratch (NFS 140T)
```

곁들여 고친 것

- `rcterm` 의 `rawdatadir` 기본값을 `/Data_ssd` 로. RAW·LOG·CONFIG 가 전부
  로컬 NVMe 로 간다 (`src/OnlConsts.hh`, `config/rcterm.params(.example)`).
- `postrun.sh` 의 `--rawroot` 기본값을 `/Data_ssd/RAW` 로. `--outroot` 와
  심볼릭 링크가 더 이상 필요 없다.
- **`postrun.sh` 가 추적 모드에서 `die` 하지 않게 했다.** dataflow 가 끝난 런을
  옮기고 나면 데이터 디렉터리가 사라지는데, 그 때문에 후처리 전체가 죽으면
  수집 추적이 멈춘다. 이제 한 줄 알리고 다음 주기로 넘긴다.
- `daq-tmux.sh` 에 **dataflow pane 추가** (오른쪽 아래). `daq-layout.sh` 가
  오른쪽 열 비율(`work space : dataflow = 7 : 3`)도 정규화한다.

#### 11.14 실측으로 확정한 것

**두 개의 랜카드. 속도가 10배 다르다.** 이것이 설계 전부를 결정했다.

| 인터페이스 | 속도 | 쓰임 | 실측 |
|---|---|---|---|
| `enp1s0` (10.0.0.11) | 100 Mb | `/scratch` NFS | 7.7 MB/s |
| `enp0s31f6` (203.230.111.71) | 1000 Mb | 경희대 백업 | **15.7 MB/s** (500 MB / 31.9초) |

**경로가 다르므로 2단계(백업)와 3단계(/scratch)는 동시에 돌려도 서로를 굶기지
않는다.** 24시간 런 1회 기준으로 백업 약 3.9시간, `/scratch` 이동 약 12.1시간이라
둘 다 여유가 있다.

**서브런당 크기 (실측, run 4290/4291)** — FADC 71.4 + SADC 8.6 + Merged 78.8 +
PRD 73.7 = **232 MB**. 1440 서브런 = **런당 334 GB**.

**백업 계정** — 사용자는 `sykim` / 비밀번호를 알려 줬으나, 실측해 보니
`sykim` 은 `config` · `db` · `RAW` **세 곳에만** 쓰기 권한이 있다.
`PRD` · `PNG` · `DAQLOG` · `Data` 는 `renecomm:users` 의 `drwxr-xr-x` 라
그 계정으로는 백업의 절반이 조용히 실패한다. 반면 `~/.ssh/config` 에 이미 있던
**`khu` 별칭(renecomm, 키 인증)은 7개 전부 쓰기 가능**이다. 그래서 `khu` 를 쓴다.
**설정 파일에 비밀번호를 적지 않았다.**
(사용자가 말한 `ssh knu` / `frontend` 계정은 실제로 없다 — 별칭은 `khu` 이고
원격 계정은 `renecomm` 이다. `frontend@hep.khu.ac.kr` 은 접속 거부된다.)

**Merged 는 백업하지 않는다.** 원격 트리에 `Merged` 카테고리가 아예 없고
(실측), 런당 114 GB 인데 RAW 로부터 다시 만들 수 있는 중간 산출물이다.
필요하면 `--with-merged`.

**PRD 원격 배치** — 최근 런 몇 개는 `PRD/<run>/PRD/` 로 한 겹 더 들어가 있고
나머지 대다수는 `PRD/<run>/` 평면이다(20개 중 14 평면). 새로 보내는 것은
`RAW` · `PNG` 와 같은 **평면**으로 통일했다.

#### 11.15 실제로 보내 본 것 / 아직 아닌 것

- ✅ run 4290 의 `config` + `DAQLOG` 3종을 **실전송**하고 원격에서 확인.
  재실행하니 마커를 보고 건너뛰었다. `db` 도 실전송
  (`db/runcatalog.2026-08-17.db`, sqlite3 `.backup` 스냅샷).
- ⚠️ **대용량 카테고리(RAW · PRD · PNG)는 아직 실전송하지 않았다.** 런 하나가
  221 GB / 약 4시간이라 사용자 승인 없이 시작하지 않았다. `--dry-run` 으로
  대상·개수·경로가 맞는 것은 확인했다.
- ⚠️ **1단계·3단계의 실제 이동도 아직 하지 않았다.** dry-run 만 돌렸다.
  지금 `/Data_ssd` 에 있는 run 4290·4291 은 예전 `--outroot` 구성이라
  `Merged`/`PRD` 가 `/scratch` 쪽 심볼릭 링크와 얽혀 있다. dataflow 는 이 상태를
  **감지해서 손대지 않는다**(`has_symlink_subdir`). 새 구성으로 수집하는
  다음 런부터 자연스럽게 정상 경로를 탄다.

#### 11.16 남은 판단 — 사용자 확인이 필요한 것

1. **예전 런(4290·4291 및 그 이전)을 어떻게 할 것인가.** 심볼릭 링크가 얽힌
   상태라 자동 이동 대상이 아니다. 백업만 먼저 하려면
   `backup-khu.sh --mid /scratch --run <N>` 으로 `/scratch` 에서 바로 보낼 수 있다
   (링크를 따라가도록 `find -L` 로 고쳐 두었다).
2. **`--drop-merged` 를 켤 것인가.** `/scratch` 이동이 12.1시간에서 8.0시간으로
   줄고 런당 114 GB 를 아낀다. 데이터를 지우는 설정이라 기본은 꺼 두었다.
3. **100 Mb 스토리지 링크(§11.12).** 고치면 3단계가 12시간에서 1~2시간이 된다.
   사이트 차원의 조치가 필요하다.

### 2026-08-15 — 실운용에서 드러난 버그 3종 수정 ★중요

#### 11.1 rcterm 자체 버그 3종 (rc.py 회귀가 아니라 rcterm 고유 결함)

**버그 A — SIGTERM 으로 끝낸 런이 DB 에 기록되지 않는다 (최우선)**
`WaitState()` 첫 줄이 `if (fgStop) return false;` 였다. 정지 요청(감시자 로테이션의
SIGTERM, 운영자 Ctrl-C)이 들어오면 모니터 루프를 빠져나와 `ENDRUN` 을 보낸 직후
`WaitState(kRUNENDED)` 가 **즉시** false 를 반환한다 → `ok=false` → `FinalizeRunInDB()`
통째로 생략 → 데이터 파일은 멀쩡한데 DB 에는 `stime/etime` NULL 인 고아 행만 남고
heartbeat 는 `phase=failed`, 종료코드는 2(실패)가 된다.

**감시자 로테이션은 매번 SIGTERM 으로 런을 끝내므로 이 경로가 매 런 재현된다.**
실운용 증거 — `/Data/LOG/rcterm.log` 에서 성공 런은 `ENDRUN → ENDED → EXIT`,
run 4276·4284·4287 은 `ENDRUN → (ENDED 없음) → EXIT`. 8/14 인수인계 문서가
"확인 필요"로 남긴 run 4276 DB 마감 누락이 바로 이것이다.

수정: `WaitState(state, timeout, bool ignoreStop=false)`. 런 종료 확인
(`kRUNENDED`, `kPROCENDED`)만 `ignoreStop=true` 로 부른다. 부팅/설정 단계는
그대로 즉시 빠져나간다. **두 번째 신호(`fgStop>=2`)는 "즉시 나가라"** 로 취급해
DAQ 가 영영 RunEnded 로 안 갈 때 운영자가 갇히지 않게 했다
(`RequestStop()` 이 1 로 고정하지 않고 증가시킨다).

**버그 B — 남은 DAQ 가 있으면 옛 런의 TCB 에 붙는다**
이전 런의 `tcb` 가 살아있으면 새로 띄운 `tcb` 는 7809 를 못 잡고 죽는데, rcterm 은
그 포트에 그냥 접속해 **옛 런의 tcb** 를 붙든다. 그 tcb 는 `status=0x8`(Running,
Booted 비트 없음)을 답하므로 `timeout waiting for Booted (status=0x8)` 로
bootTimeout 내내 헛기다리다 실패한다. run 번호도 한 개 버려진다.
실측 증거 — `TCB_004269.log` 22:23:55 에 **run 4270 의 rcterm 이 접속**.

수정: `StaleDaqPresent()` 신설. `Execute()` 에서 **run 번호 발급보다 먼저** 검사해
번호를 낭비하지 않는다. 직전 런이 내려가는 중일 수 있으므로 10초까지 기다린 뒤
그래도 응답하면 `[FATAL]` + `killdaq.sh` 안내 + exit=2
(감시자의 `CleanupStale` 후 재시작으로 풀리는 상황이므로 1 이 아니라 2).
탈출구로 `--no-stale-check` 추가.

**버그 C — 실패한 런이 DB 에 무표기 고아 행으로 남는다** → 작업 5 참조.

#### 11.2 8/14 현장 상황 (인수인계 문서 요약)

- 22:37 nouveau GSP MMU fault 로 화면 프리징. DAQ 자체는 계속 정상 가동했다.
  → **NVIDIA 독점 드라이버 전환 완료** (8/15 04:06 재부팅,
  `rd.driver.blacklist=nouveau nvidia-drm.modeset=1`, `nvidia-smi` 정상).
- DAQ 가 `gnome-terminal-server → bash → rcsupervisor → rcterm` 로 물려 있었다.
  X 가 죽으면 런이 통째로 날아간다. **tmux 이관은 아직 미완** (§4.3).
- 8/15 03:30 에 4247~4284 고아 행을 수동 SQL 로 표기 완료
  (`boot failed...` / `aborted...`). run 4287 도 수동 마감.

#### 11.3 검증 방법 (하드웨어 미사용)

`$CLAUDE_JOB_DIR/tmp/tcbtest/faketcb.py` — 32바이트 프로토콜만 흉내내는 가짜
TCB/ADC(포트 17809/17814/17815). `ENDRUN` 수신 후 `END_DELAY` 초 뒤에 RunEnded 로
가므로 이 대기 구간에서 구/신 동작이 갈린다. 가짜 `executedaq.sh` 를 `--bindir`
로 물려 하드웨어를 전혀 건드리지 않는다.

| 테스트 | 결과 |
|---|---|
| 1. stale 가드 | `[FATAL] already listening ... status=0x2`, exit=2, run 번호 미발급(700 유지) ✅ |
| 2. SIGTERM 마감 | `phase=ended`, exit=0, `stime/etime/onlbit=1/nfadc=15811/nsadc=15811` ✅ |
| 3. A/B 구버전(HEAD) 동일 시나리오 | `phase=failed`, exit=2, DB 행 전부 NULL — **운영 증상 그대로 재현** ✅ |
| 4. 부팅 실패 표기 | `onlbit=0, runlog='boot failed; run never started'` ✅ |
| 5. 2차 신호 탈출 | RunEnded 안 오는 상태에서 2차 SIGTERM → 1초 내 종료 ✅ |

clean build 경고·에러 0 (ROOT 6.28/04, GCC 11.5.0).

### 2026-08-17 (오후) — `/Data/LOG` 삭제 사고와 그 수정

#### 11.10 디렉터리가 사라지자 멀쩡한 런이 죽었다 ★재발 방지

08:09 에 `/Data/LOG` 가 통째로 삭제됐다(사용자가 `/data` 를 정리하면서 함께).
이 디렉터리에는 `rcterm.params` / `rcsupervisor.params` 가 가리키는 세 가지가 있다 —
heartbeat, rcterm 로그, 감시자 로그.

```
08:09  /Data/LOG 삭제
       rcterm 이 heartbeat 를 쓸 수 없게 됨 → WriteHeartbeat 가 조용히 return
       감시자는 그것을 'rcterm 이 죽었다' 로 판단
08:12  run 4290 을 죽이고 run 4291 로 재시작        ← 멀쩡한 런이었다
       heartbeat 는 여전히 못 쓰므로 5분마다 반복될 상황
08:22  /Data/LOG 재생성 → heartbeat 즉시 복구, 반복 중단
```

**원인은 rcterm 이 자기 상태 파일의 상위 디렉터리를 확인하지 않은 것.**
`$RAWDATA_DIR/{LOG,CONFIG}` 는 부팅 전에 `mkdir -p` 하면서(§3 숨은 함정)
정작 `--heartbeat` / `--log` / `--rootout` 의 경로는 보지 않았다. 같은 종류의
실수가 한 곳 더 남아 있었던 것이다.

**수정** — `RunControl::EnsureParentDir()` 신설. rcterm 은 위 세 경로를,
rcsupervisor 는 자기 로그 경로를 시작 시 만든다. 그리고 **`WriteHeartbeat()` 가
스스로 복구한다** — 파일을 못 열면 디렉터리를 다시 만들고 한 번 재시도한 뒤
경고를 남긴다. **조용히 포기하던 것이 '디렉터리 없음'을 '죽은 런'으로 보이게 만든
진짜 원인**이므로 여기가 핵심이다.

**검증** — 가짜 검출기로 런을 돌리는 도중 디렉터리를 통째로 삭제 →
다음 갱신에서 heartbeat 복구, 경고 1회 출력, 런은 `exit 0` 으로 정상 종료.

**잃은 것은 없다.** 원시 데이터는 `/scratch/RAW` 라 무관하고,
**run 4290 은 이 장애 중에도 `onlbit=1` 로 깨끗하게 마감됐다** — §11.1 버그 A
수정이 예상치 못한 강제 종료 상황에서도 동작한다는 뜻이다.

**남은 흔적** — `rcsupervisor.log` 는 감시자가 삭제된 inode 를 붙들고 있어
(`fd 3 -> ... (deleted)`) 디렉터리를 다시 만들어도 되살아나지 않는다.
감시자를 재시작해야 하는데 수집이 끊기므로 하지 않았다. 다음 재시작 때 복구된다.

#### 11.12 ★ NFS 가 100 Mb 링크에 붙어 있다 — 사이트 전체에 영향

정리가 217 GB 에 3시간 넘게 걸려 추적한 결과, rsync 도 NFS 설정(v4.2,
rsize/wsize 1MB)도 아니었다. **스토리지로 가는 경로가 100 Mb 인터페이스다.**

```
enp0s31f6   1000 Mb/s   203.230.111.71     ← 놀고 있음
enp1s0       100 Mb/s   10.0.0.11          ← NFS 트래픽
ip route get 10.0.0.10  →  dev enp1s0
```

100 Mb = 이론 최대 12.5 MB/s. 실측 쓰기 **7.7 MB/s**(이론치 62%).
DAQ 기록과 postrun 읽기가 같은 링크를 나눠 쓰므로 사실상 포화다.

- 스트림을 2개로 늘려도 **7.7 MB/s 그대로** → 클라이언트 동시성 문제가 아니다
- NFS WRITE 실행 **2,011 ms**(RTT 270 ms) → 포화된 파이프 뒤 1.7초 큐 대기
- ping RTT **10.6 ms**(로컬인데 정상은 0.1~0.3 ms)
- 링크 오류·드롭 0 → 불량이 아니라 속도 협상/배선 문제

**이것은 후처리만의 문제가 아니다.** DAQ 원시 데이터도 이 링크로 나간다.
현재 수집률(2,020 Hz, 약 1.3 MB/s)은 여유가 있지만, 링크의 10%를 이미 쓰고 있고
후처리·분석이 겹치면 경합한다. **사이트 차원에서 확인할 가치가 크다.**

개선안은 `docs/POSTRUN.md` 에 정리했다. 요약하면 (1) 1 Gb 인터페이스로 옮기거나
배선/포트를 고친다 (2) 파생물은 옮기지 말고 필요할 때 재생성한다
(3) 링크가 그대로면 `--outroot` 를 쓰지 않는 편이 낫다 — 로컬로 버는 13초가
나중 전송 비용에 다 잡아먹힌다.

#### 11.11 정리 기능과 화면 설정

- **`postrun.sh --keep-local N` / `--archive-now`** — 끝난 런의 산출물을
  로컬 디스크에서 RAW 트리로 되돌린다. 이동은 **rsync**(`-a --remove-source-files
  --info=progress2`). 임시 이름으로 받아 완료 후 rename 하므로 끊겨도 잘린 파일이
  최종 이름을 차지하지 않는다. 자세한 것은 `docs/POSTRUN.md`.
- **`ionice -c3` 은 쓰지 말 것.** 후처리에 밀려 분당 4파일까지 굶는다. `-c2 -n7` 권장.
- **화면 배치 기본값을 실사용 값으로 갱신** — 좌우 46:54, 왼쪽 높이 28:8:5.
- **`scripts/rcmon-window.sh`** — tmux 는 pane 별 글꼴 크기를 지원하지 않으므로,
  큰 글꼴 전용 gnome-terminal 프로파일(`RENE monitor`)을 만들어 상태 화면을
  별도 창으로 띄운다. rcmon.sh 는 읽기 전용이라 몇 개를 띄워도 무방하다.

### 2026-08-17 — 로테이션 2회 연속 무결. 전수 점검 통과

#### 11.8 1.5일 연속 운용 전수 점검 — 이상 0건

로테이션이 두 번(4288→4289→4290) 지나갔다. 두 번 다 동일하게 정상 마감했다.
**한 번은 우연일 수 있지만 두 번은 재현이다.**

| 점검 | 결과 |
|---|---|
| 감시자 이상 신호 (8/15 이후) | `recovering`/`restart`/`FATAL`/`WARN` **0건** (health OK 286회) |
| rcterm 로그 `[ERROR]`/`[WARN]`/`[FATAL]` | **0건** |
| run 4288 완결성 | FADC 1440 = SADC 1440 = Merged 1440 = **PRD 1440** |
| run 4289 완결성 | FADC 1440 = SADC 1440 = Merged 1440 = **PRD 1440** |
| 좀비/손상 서브런 | **0건** (양쪽 런 모두) |
| 신규 고아 행 | **0건** — 4288·4289 모두 완전 마감 |

```
runnum 4288  2026-08-15 04:52:06 → 2026-08-16 04:51:54  onlbit 1  87,335,612 ev  1011.0 Hz  24.0 h
runnum 4289  2026-08-16 04:52:24 → 2026-08-17 04:52:11  onlbit 1  87,635,256 ev  1014.5 Hz  24.0 h
```

**dead time** 29초 / 26초 — §5.5 에 적은 10~40초 범위 안이다.
**FADC 와 SADC 파일 수가 1440 으로 정확히 일치**한다. 한쪽 누락이 없다는 뜻이다.

#### 11.9 용량 — 이제 가장 급하다  ※ 2026-08-18 무효. §11.19 로 대체

```
/Data_ssd  3.7T 중 여유 1.6T      런당 산출물 217~219 GB      →  약 7일
```

산출물이 런당 217 GB 이고 여유가 1.5 TB 다. **약 7일 뒤 가득 찬다.**
`postrun.sh --outroot` 로 로컬에 쓰는 선택이 속도에서는 옳았지만(41.0→27.7초)
보관에서는 빡빡하다. 끝난 런의 `Merged`/`PRD` 를 `/scratch` 로 옮기는 정리가 필요하다.
지금 당장 손댈 후보:

```bash
# 예시 — 검증(audit_run.sh)이 끝난 런을 NFS 로 되돌린다
mv /Data_ssd/RAW/004288 /scratch/RAW/004288.derived
```
심볼릭 링크가 `/scratch/RAW/<run>/{Merged,PRD}` 에 걸려 있으므로 옮긴 뒤 링크를
고쳐 주어야 한다. 자동화하려면 `postrun.sh` 에 정리 옵션을 붙이는 편이 낫다.

### 2026-08-16 — 수정본의 첫 로테이션 검증 ★결론

#### 11.5 버그 A 수정이 실 하드웨어에서 확정됐다

2026-08-16 04:51:54, run 4288 이 24시간을 채우고 감시자가 로테이션을 걸었다.
**8월 14일까지 매번 기록을 잃던 바로 그 지점이다.**

```
04:51:54 [SUP] rotation time reached (24.0000 h); ending run gracefully
04:51:55 ENDED run=004288          ← 수정 전에는 이 줄이 없었다
04:52:01 [SUP] cycle 1 finished : exit=code 0  (rotation)   ← 전에는 code 2
04:52:24 STARTED run=004289        ← dead time 30초 (§5.5 의 10~40초 범위)
```

DB 도 완전히 마감됐다.

```
runnum 4288   stime 2026-08-15 04:52:06   etime 2026-08-16 04:51:54   onlbit 1
              nfadc 87,335,612 / tfadc 86,388.2      nsadc 87,329,088 / tsadc 86,387.9
```

수정 전 로테이션(run 4284)의 행은 여전히 비어 있어 바로 옆에서 대조된다.

**이후 24시간 무사고.** 로테이션 뒤 `recovering` / `restart` / `FATAL` 은 한 건도 없다
(로그의 22건은 전부 8/15 이전 것). health 점검 누적 281회.

#### 11.6 후처리가 실시간을 따라잡았다

- run 4288 : PRD **1440개 전량** 완료
- run 4289 : 서브런 1371 대비 PRD **1368** — `--lag 3` 설정값 그대로 따라붙었다

밀렸던 800여 서브런을 소화하고 정상 추적 상태에 들어갔다. 로컬 NVMe 로 옮긴
효과(§5.8)가 확인된 셈이다.

#### 11.7 새로 급해진 것 — `/Data_ssd` 용량  ※ 2026-08-18 무효. §11.19 로 대체

실측 소비가 **약 400 GB/일**(런 2개분 산출물)이다. 여유가 2.0 TB → 1.6 TB 로 줄었다.
**약 7일 뒤 가득 찬다.** 앞서 "9일치"로 적었던 것은 런 1개 기준이었고, 실제로는
직전 런과 현재 런의 산출물이 함께 남으므로 더 빠듯하다.
오래된 런의 `Merged`/`PRD` 를 `/scratch` 로 옮기거나 지우는 정책이 필요하다.

#### 11.4 커밋 / 재기동

`origin/main` 에 3개 커밋 푸시 완료 — `fix:`(소스 3파일) / `docs:`(문서·example
6파일) / `fix:`(killdaq.sh 실행권한). 사이트 전용 변경(`build.sh` 의 `source` 2줄,
`OnlConsts.hh` 의 `/scratch/RAW`·`/Data_ssd` 경로)은 **의도적으로 커밋하지 않았다.**
`config/*.params` 는 `.gitignore` 대상이라 로컬에만 있다.

**재기동 (2026-08-15 04:51, run 4288~)** — tmux 세션 `daq` 에서:

```bash
tmux attach -t daq            # 접속.  Ctrl-B 누른 뒤 D 로 분리
install/bin/rcsupervisor --params config/rcsupervisor.params -- --desc '<8/14 과 동일한 desc>'
```

**화면 구성은 `scripts/daq-tmux.sh` 하나로 재현된다.**

```
+---------------------------+----------------------+
| DAQ Run Status(monitor) 28|  work space (vi 등) 7|
|   = rcmon.sh              |                      |
+---------------------------+                      |
| supervisor               8|                      |
+---------------------------+----------------------+
| postrun                  5|  dataflow:          3|
|                           |  /Data_ssd(RAW)      |
|                           |  ->/data(PRD)        |
|                           |  ->khu(backup)       |
|                           |  ->scratch(save)     |
+---------------------------+----------------------+
             46%                       54%
```

왼쪽에 DAQ 관련 3개를 세로로 쌓고(위에서부터 **28 : 8 : 5**),
오른쪽은 작업용 셸과 데이터 이동(**7 : 3**). 좌우는 **46 : 54**.
(착수 시점에 적었던 `6 : 2 : 2` / `4.5 : 5.5` 는 실사용하며 위 값으로 바뀌었다.
dataflow pane 은 2026-08-17 에 추가됐다 — §11.11, §11.13)

**pane 제목은 장식이 아니다.** `daq-layout.sh` 가 제목 안의 열쇠말
(`monitor` / `supervisor` / `postrun` / `work space` / `dataflow`)로 pane 을
찾는다. 제목을 바꿀 때 그 낱말을 빼면 레이아웃 복원이 깨진다 (§11.24).

**비율이 어긋나면 `scripts/daq-layout.sh`** (tmux 안에서는 `Ctrl-B` 다음 `=`).
퍼센트로 준 크기는 지정 순간의 창 크기로 계산되어 열/행 수로 굳으므로,
터미널 크기나 폰트를 바꾸면 반드시 어긋난다. `daq-tmux.sh` 도 창을 만든 뒤
이 스크립트를 한 번 불러 정규화한다 — `split-window -p` 의 반올림은
창이 작을수록 크게 빗나가기 때문이다.

비율을 바꾸려면 환경변수로 준다.

```bash
DAQ_LAYOUT_LR=45  DAQ_LAYOUT_H="6 2 2"  scripts/daq-layout.sh
```

**pane 별로 글꼴 크기를 다르게 할 수는 없다.** 폰트는 터미널 에뮬레이터가
창 단위로 갖는 속성이고 tmux 에는 폰트 옵션 자체가 없다. 특정 화면만 크게
보려면 큰 글꼴 프로파일로 터미널 창을 하나 더 띄워서
`scripts/rcmon.sh`(상태 화면) 또는 `tail -f /Data/LOG/rcterm.log`(rcterm 출력)를
따로 돌리면 된다. rcmon.sh 는 heartbeat 를 읽기만 하므로 몇 개를 띄워도 무방하다.

- 인자 없이 실행하면 **화면만** 만든다(하드웨어 미접촉). `--start` 를 줘야 기동한다.
- **rcsupervisor 가 이미 돌고 있으면 절대 다시 띄우지 않고** 감시자 로그를 tail 한다.
  돌아가는 자식의 출력을 새 pane 으로 옮길 수는 없기 때문이다.
- 세션이 이미 있으면 재구성하지 않고 붙는다. 살아있는 런 보호가 목적이다.
- 감시자 실행 여부는 **`pgrep -x rcsupervisor`** 로 본다. 절대경로로 `pgrep -f`
  하면 상대경로로 띄운 실제 프로세스를 놓치고(실측), 검사하는 셸 자신의 명령줄까지
  잡는 오탐이 난다.

**`scripts/rcmon.sh` 가 왜 필요한가** — 감시자는 rcterm 에 `--quiet` 를
**무조건** 붙인다(`rcsupervisor.cc:138`). `PrintScreen()` 이 매 갱신마다
`\033[2J` 로 화면을 지워 감시자의 `[SUP]` 로그를 덮어버리기 때문이다. 그래서
감시자 밑에서는 전체 화면을 볼 방법이 없다. rcmon.sh 는 heartbeat 파일만 읽어
같은 화면을 그린다(읽기 전용, DAQ 무영향). heartbeat 나이를 함께 표시하므로
rcterm 이 멎으면 화면에서 바로 보인다.

살아있는 pane 을 죽이지 않고 배치를 바꿀 때는 `join-pane` 을 쓴다.
kill 후 재실행하면 그 순간 런이 끊긴다.

`--` 뒤 인자는 감시자가 **자기 옵션 뒤에** 붙이므로(rcsupervisor.cc:145) 항상 이긴다.
desc 는 run 4287 의 `rundesc` 에서 rcterm 이 자동으로 붙이는 `, Split T [m] = 1` 을
떼어내 복원했고, run 4288 의 `rundesc` 가 4287 과 완전히 일치함을 확인했다.

**주의 — §8 규칙 위반 기록.** "운영 디렉터리에서 소스 수정 금지" 와 달리 이번엔
운영 디렉터리에서 직접 수정·빌드했다. 착수 시점에 DAQ 프로세스가 0개이고 7809 가
비어 있음을 확인한 뒤 진행했다. **지금은 run 4288 이 이 디렉터리의 바이너리로
가동 중이므로, 다음 소스 수정은 반드시 별도 클론에서 할 것.**

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

