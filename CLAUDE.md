# CLAUDE.md — RENE 실험 DAQ 프로그램 (RENE_DAQ_term) 작업 지침

이 파일은 Claude Code가 매 세션 자동으로 읽는다.
선행 세션(웹 챗)에서 확정된 사실과 잔여 작업이 전부 여기 있다.
**추측하지 말고 이 문서의 검증 상태를 신뢰하되, "미검증"으로 표시된 것은 반드시 실측하라.**

---

## 0.0 다른 PC 에서 이어받기 ★ 새 작업 PC 라면 여기부터

**이 저장소가 프로젝트의 정본이다.** 작업 PC 가 바뀌어도 아래만 하면 그대로 이어진다.
Claude Code 의 로컬 메모리는 PC 를 따라가지 않으므로 의존하지 말 것.

> **★ 지금 어디까지 했고 다음에 무엇을 하는지는 §11.142 '여기서 이어받는다' 에 있다.**
> 돌고 있는 것, 상태 보는 명령, 바로 다음에 할 일, 열려 있는 것 전부가 그 한 절에
> 모여 있다. 세션이 끊겨 이어받는 것이라면 **§0.0 다음에 바로 그리로 갈 것.**

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
#                        저장소 서버 별칭 'store' = 10.0.0.10:7777 (§11.118)
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
| `docs/HISTORY-2026-08.md` | **옛 세션 기록 (2026-08-13 ~ 08-25).** §11.100 이하 참조는 여기서 찾는다 |
| `docs/PROGRESS.md` | **지금까지 진행한 사항 요약** — 경과 · 산출물 · 현재 상태 · 남은 것. 상세는 이 문서 §11 |
| `docs/MANUAL.md` | rcterm / rcsupervisor 운용 상세 |
| `docs/POSTRUN.md` | 병합·production 파이프라인의 구조와 성능 근거 |
| `docs/DATAFLOW.md` | 수집 -> 백업 -> 장기보관 데이터 이동의 구조와 실측 근거 |
| `docs/ALARM.md` | 알람·메일·자동 USB 복구. 설정법과 알람이 울렸을 때 할 일 |
| `.claude/skills/recovering-aborted-daq-runs/SKILL.md` | **런이 비정상 종료했을 때 무엇부터 하나.** Claude Code 가 증상을 보면 스스로 읽는다 |
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
scripts/netcheck.sh      바깥 링크가 실제로 얼마를 내는지 잰다. 읽기 전용
                         ★ 대역은 실제로 쓴다. --local-only 는 안 쓴다 (§11.121)
scripts/sheetlog-auto.sh 구글시트 런 로그 자동 등재. cron 이 부른다 (§11.126)
                         ★ 완결된 런까지만 쓴다. --status 는 읽기 전용
scripts/chainwatch.sh    후처리 사슬·계수율 감시. cron 이 5분마다 부른다 (§11.138)
                         ★ 읽기 전용. --status 로 지금 무엇이 빠졌는지 본다
scripts/storage-backup.sh 스토리지 서버의 외장하드 아카이브. 하드 여러 개를 순서대로
                         ★ 이 PC 가 아니라 저장소 서버에서 돈다. 거기 배포 이름은
                           /home/frontend/data_backup_simple_code9.sh (§11.143)
                         ★ 기본이 --dry-run 이 아니다. 원본을 지운다. 먼저 --dry-run
scripts/mailq-send.sh    위 스크립트가 /data/MAILQ 에 떨군 메일을 내보낸다
                         ★ 이 PC 의 cron 이 5분마다. --status 는 읽기 전용 (§11.144)
tests/storage-backup.test.sh   위 둘의 시험. 하드·자료·메일을 건드리지 않는다
tests/mailq-send.test.sh       (§11.146. BACKUP_TEST_HOOK 으로 용량 판정만 갈아끼운다)
scripts/badrun.sh        문제 런 판정 + 못 쓰는 원시 파일 격리 + 통합 목록
                         ★ 읽기 전용이 기본. --quarantine 이라야 파일을 옮긴다
scripts/runcheck.sh      끝난 런의 산출물 개수 대조 + 빈 것의 사유 + 복구
                         ★ 읽기 전용이 기본. --fix 라야 매크로를 부른다 (§11.99)
scripts/swap-logdir.sh   로그 루트를 통째로 갈아끼운다 (§11.101)
                         ★ 런 경계에서. 서브런 30 넘으면 스스로 멈춘다
scripts/logrotate-daq.sh 로그를 종류별 폴더로 나누고 한 폴더가 커지지 않게 한다
                         ★ 상한 1만. postrun 이 주기마다 부른다 (§11.103)
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
| **10G 스토리지 링크** | 2026-08-26 개통. `/scratch` 읽기 **838 MB/s** · 쓰기 **534 MB/s** (옛 7.7 MB/s), RTT 10.6 -> **0.31 ms**, 오류 0 (§11.115) |
| **저장소 서버 ssh** | `ssh store` (10.0.0.10:7777, 키 인증). §11.101 의 `No route to host` 는 방화벽 REJECT 였다 (§11.118) |
| **외장하드 2개 순차 백업** | `scripts/storage-backup.sh` 시험 57건 + `mailq-send.sh` 42건 전부 통과. 실서버 `--dry-run` 정상, 메일 경로는 실제 발송 rc=0 까지 확인 (§11.143~11.146) |

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

## 5.9 badrun — 쓰기 도중 죽은 런을 어떻게 다루는가  ★ 2026-08-21

**문제.** 런이 쓰기 도중 죽으면 마지막 서브런 파일이 안 닫힌 채 남는다. ROOT 가
열지 못하므로(`no keys recovered`) merge 도 production 도 못 한다. 그러면 그 런은
**PRD 개수 == FADC 개수** 를 영원히 만족할 수 없고, `dataflow.sh:161` 의
`is_processed()` 가 통과시키지 않아 `/Data_ssd` 에 붙박이가 된다. 자동 이동 대상이
**절대** 되지 못한다는 뜻이라, 설계상의 구멍이었다.

**해법 — 못 쓰는 원시 파일을 `<런>/badrun/` 으로 옮긴다.**

```
/Data_ssd/RAW/004293/
   FADC_004293.root.00000 ~ .00090      91개 정상
   Merged/ 91  PRD/ 91                  부분 Merged 에서 살린 sub 90 포함
   badrun/
      FADC_004293.root.00091   5.1 MB   (정상 73 MB)
      SADC_004293.root.00091   0.67 MB  (정상 8.9 MB, keys 없음)
      README.txt               격리 사유
```

**★ 이동·백업 쪽은 한 줄도 고치지 않았다.** 셋이 저절로 맞아떨어진다.

| 곳 | 왜 그대로 되나 |
|---|---|
| `is_processed()` | `-maxdepth 1` 이라 하위 폴더를 안 센다 → 격리하는 순간 통과 |
| `move_dir` (`dataflow.sh:182`) | `find -type f` 가 재귀라 `badrun/` 이 함께 간다 |
| `bk_RAW` (`backup-khu.sh:292`) | `/Merged /PRD /PNG` 만 제외 → `khu:.../RAW/<런>/badrun/` |

개수 검증도 안전하다 — `n_src` 는 `-maxdepth 1` 로 세고 원격은 `ls -1` 이라
`badrun` 디렉터리 항목이 하나 더 잡힌다. 검사는 `n_dst < n_src` 이므로 통과하고,
`verify_dir` 의 `rsync -c` 는 재귀라 `badrun/` 안까지 대조한다.

**★ 안전 규칙 — 열리는 파일은 절대 격리하지 않는다.**
원본이 멀쩡한데 PRD 만 없는 것은 **다시 돌리면 되는 것**이지 badrun 이 아니다.
실제로 run 4291 서브런 30 이 그랬고, 격리했으면 멀쩡한 61,140 이벤트를 묻을
뻔했다. 서브런마다 판정을 셋으로 나눈다.

```
bad_raw   자기 FADC 또는 SADC 가 안 열린다        -> 격리. 짝은 함께 옮긴다
blocked   자기 원본은 멀쩡한데 다음 SADC 가 죽어  -> 격리하지 않는다.
          merge 를 끝낼 수 없다                       부분 Merged 에서 PRD 복구 가능
gap       전부 잘 열린다                          -> 격리하지 않는다. 재처리하면 된다
```

**짝은 함께 옮긴다.** 한쪽만 죽어도 그 서브런의 FADC·SADC 를 함께 격리한다.
짝 없는 FADC 는 혼자서는 merge 도 production 도 못 하므로 최상위에 남겨 두면
PRD 개수와 영원히 어긋나 런이 그대로 막힌다.

**이동은 같은 파일시스템 안 `mv -T` 다.** §8 이 명시한 예외(자료가 움직이지 않는
원자적 연산)라 rsync + 체크섬 절차가 필요 없다. `<런>/badrun/` 은 언제나 런
디렉터리 안이므로 파일시스템을 넘지 않는다.

**비용을 세 단계로 나눈 이유.** `/scratch` 는 100 Mb NFS 라(§11.12) 전 구간
1,972 개 런을 다 열어 보면 몇 시간이 된다.

```
1단계  런마다 readdir 로 개수만 센다                    (ls -U. find -printf 금지)
2단계  PRD == FADC 이고 FADC > 0 이면 정상. 끝           여기서 대부분이 걸러진다
3단계  나머지만 ROOT 로 열어 본다. 런당 상한 40개,       잘림은 언제나 런의 끝에서
       그것도 꼬리부터                                   일어나기 때문이다
```

`PRD` 가 하나도 없는 런은 서브런을 열어 보지 않는다(`not_processed`). 안 그러면
한 런에 수천 번 ROOT 를 띄운다.

**목록은 정본 하나 + 저장소 사본.** 정본은 `/Data_ssd/LOG/badrun_list.txt` 이고
`backup-khu` 가 db 옆으로 함께 보낸다. 사본은 `docs/BADRUNS.md` 로, 다른 PC 에서
`git clone` 만 해도 보이게 한다. **사본은 생성물이다** — 손으로 고치지 말 것.

**★ 격리를 마친 런도 목록에 영구히 남는다.** 격리하면 개수가 맞아떨어져 '정상'으로
보이는데, 그대로 떨어뜨리면 문제가 있었다는 사실 자체가 사라진다. 그래서
`badrun/` 이 있는 런은 개수와 무관하게 언제나 싣는다. 분류일시도 보존한다.

**onlbit 이 NULL 인 행은 싣지 않는다.** 약 1,000건이 있고 rc.py 시절의 역사적
정상이라(회귀가 아니다) 그것까지 실으면 목록이 쓸모없어진다. 디스크에 실제 결함이
있으면 개수 대조에서 따로 잡힌다.

**수집 중인 런은 절대 싣지 않는다.** postrun 이 `--lag 3` 으로 따라오므로 가동
중에는 언제나 PRD 가 서너 개 적고, 기록 중인 마지막 SADC 는 아직 안 닫혀 ROOT 가
열지 못한다. 그대로 두면 멀쩡한 런이 매 훑기마다 `prd_gap` 으로 잡힌다
(실측 : run 4302 가 `FADC 1263 / PRD 1260` 으로 걸렸다).

---

## 6. 잔여 작업 큐 (우선순위 순)

**작업 1~5 · 6.5 · 7 은 전부 끝났다.** 무엇을 어떻게 했는지는 세션 기록에 있다.

| 작업 | 결과 |
|---|---|
| 1. 실제 ROOT 빌드 검증 | ✅ 2026-08-13. ROOT 6.28/04 · GCC 11.5.0 clean build |
| 2. rcsupervisor 로테이션/복구 검증 | ✅ 2026-08-13. 가짜 rcterm 으로 테스트 H·I 통과 |
| 3. 한글 텍스트 깨짐 수정 | ✅ 2026-08-13·15. 보류 3건은 사용자 확인 대기 (아래) |
| 4. `--params` 위치 규칙 문서화 (§5.6) | ✅ 2026-08-15 |
| 5. 실패 런 DB 고아 행 표기 | ✅ 2026-08-15. `MarkFailedRunInDB()` |
| 6.5 데이터 흐름 구축 | ✅ 2026-08-17. `docs/DATAFLOW.md` |
| 7. 실 하드웨어 검증 | ✅ 2026-08-14 이후 상시 운용 중 |

**작업 3 의 보류 3건 — 추측으로 고치면 의미가 왜곡되므로 그대로 두었다.**
`src/rcsupervisor.cc:8` "자식이 버지면" · `docs/MANUAL.md:177` "단으로 감지하고
단으로 복구한다" · `config/rcsupervisor.params:26` "저리드 런".

### 작업 6 — 개선 백로그 (여유 있을 때)
- `libsqlite3` 링크 + prepared statement (현재는 임시파일 + 셸 호출, 이스케이프만)
- 모니터 소켓 런당 1회만 오픈 → 런 도중 끊기면 재연결 없음. 주기적 재연결 필요
- `OnlSocket::Connect()` 소켓 타임아웃 3초 하드코딩 → 옵션화
- heartbeat 락 없음. `rename()`은 원자적이나 두 rcterm이 같은 경로를 쓰는 걸 못 막음
  → PID 파일 + `flock`
- rate가 벽시계가 아니라 DAQ 보고 시간 기준 → ns 카운터 정지 시 순간 rate 미정의
- 단위 테스트 없음. config 파싱 / 머저 판정 / 비트마스크 디코딩은 순수 함수라 쉽다
- ~~dataflow 3단계가 `/scratch` 로 옮기는 데 12시간이 걸린다. 100 Mb 링크(§11.12)를
  고치는 것이 정답이고, 그 전까지는 `--drop-merged` 가 유일한 단축 수단이다~~
  **2026-08-26 해결 — 링크를 10 Gb 로 올렸다** (§11.115). 쓰기 7.7 -> 534 MB/s.
  `--drop-merged` 를 켤 이유가 사라졌다. **다만 3단계가 실제로 도는 것은 아직
  못 봤다** — 산술이 아니라 실측으로 §11.117 의 표를 채울 것
- ~~`backup-khu.sh` 는 원격 개수만 검증한다. 체크섬 검증은 너무 비싸다~~
  **2026-08-19 해결. 그리고 "너무 비싸다"는 판단이 틀렸다** — run 4290 PRD
  15.4 GB 기준 전송 17분 40초 대 대조 **1분 00초**다(§11.35). 양쪽이 각자
  계산해 결과만 주고받으므로 링크 부담이 거의 없다. 지금은 기본으로 켜져 있다
  **★ 단 이것은 ssh 전송에만 해당한다.** dataflow 3단계의 `/scratch` 는 NFS
  마운트라 rsync 에게는 로컬 경로이고, 클라이언트가 목적지 전량을 읽어야 해서
  **대조가 전송보다 비싸다** — run 4292 는 전송 10.3시간 대 대조 28시간+ (§11.63)
  **★ 이것도 100 Mb 전제다.** 2026-08-26 에 10 Gb 가 됐으므로 다시 재야 한다 (§11.117)
- `postrun`·`runcheck` 의 '수집 중' 게이트가 heartbeat 의 `run=` 만 보고
  `phase=ended` 를 무시한다. 런이 끝난 직후에는 언제나 그 런을 수집 중으로 읽어
  꼬리 서브런을 처리하지 못한다 (§11.111). 지금은 `--heartbeat` 를 비켜 주어 넘긴다
- **`usb-recover.sh` 의 진단이 TCB 고장을 못 잡는다.** `FADCDAQ`·`SADCDAQ` 로그만
  훑고(`usb-recover.sh:148,152`), 오류 패턴도 `LIBUSB_ERROR_IO`·`read error` 계열
  뿐이라 `USB3TCBWrite: write error:LIBUSB_ERROR_TIMEOUT` 과 한 글자도 안 겹친다.
  실측 : 오류 43건짜리 로그를 0건으로 센다 (§11.120). **둘 다 고쳐야 잡힌다**
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
- **런이 비정상 종료했으면 `scripts/badrun.sh --scan` 을 돌릴 것.** 못 쓰는 원시
  파일을 `<런>/badrun/` 으로 격리해야 그 런이 자동 이동 대상이 된다(§5.9).
  격리 전까지는 `/Data_ssd` 에 붙박이로 남아 용량을 먹는다. 무엇이 문제였는지는
  `/Data_ssd/LOG/badrun_list.txt` (사본 `docs/BADRUNS.md`) 하나만 보면 된다.
- **`badrun.sh --scan` 에 `--run`/`--from` 을 주고 `--update-list` 를 함께 쓰면
  예전에는 목록이 그 몇 줄로 줄었다.** 2026-08-22 에 고쳐서 이제는 병합한다
  (§11.87). 정본이 상하면 `docs/BADRUNS.md` 의 코드 울타리 안이 그대로 사본이다.
- **★ 0초 만에 실패하면 데이터가 아니라 `/scratch/LOG` 를 의심할 것.** 그 이름의
  로그를 만들 수 있는지 `date > <로그경로>` 로 시험하라. EIO 면 깨진 dirent 이고
  매크로는 아예 실행되지 않은 것이다. merge·production 둘 다 이렇게 죽는다 (§11.68).
- **백업이 `원격 개수 부족` 으로 실패하면 괄호 안의 개수 자리를 볼 것.**
  `( / 8)` 처럼 **비어 있으면 데이터 문제가 아니라 일시적인 ssh 끊김**이다.
  2026-08-22 에 재시도를 넣어 고쳤으므로(§11.81) 이제는 다섯 번 붙어 본 뒤에만
  포기하고, 그때는 '원격 개수를 확인하지 못했다' 로 따로 낸다.
- **★ 런이 끝나면 `scripts/runcheck.sh` 를 돌릴 것.** `/scratch/LOG` 의 깨진
  dirent 때문에 런마다 서브런 두어 개가 조용히 빈다(§11.52 · §11.68 · §11.89 ·
  §11.95 — 네 번 겪었다). 개수를 대조하고 사유까지 밝히며, 직전 merge 로그에서
  carry 를 읽어 복구 명령을 그대로 찍는다. `--fix` 를 붙이면 실행까지 한다 —
  **carry 를 못 읽으면 건너뛴다**(§11.68). 서버 쪽 fsck 가 되기 전까지 이 대조가
  가장 값싼 방어다 (§11.99).
- **★ 로그는 종류별 폴더에 쌓이고 1만 개에서 폴더째 빠진다** (§11.103).
  `scripts/logrotate-daq.sh --status` 로 본다. **루트에 production 로그가 몇 개
  보이는 것은 정상이다** — 껍데기가 거기 쓰고 postrun 이 5분마다 쓸어담는다.
  DAQ 로그는 런이 바뀔 때 `RAW_log/` 로 옮겨지므로 `/Data_ssd/LOG` 가 깨끗해진다.
- **★ 결손이 잦아지면 로그 디렉터리를 갈아끼운다.** 손상되는 것은 파일이 아니라
  **디렉터리 자신**이다 — 같은 이름이 새 디렉터리에서는 그냥 만들어진다(§11.101).
  `scripts/swap-logdir.sh --verify` 로 지금 막혀 있는지 보고, 막혔으면
  **postrun 을 먼저 멈춘 뒤** 갈아끼운다(§11.102). 로그 4,320 개/런이라 석 달쯤이
  주기다.
- **★ postrun 을 세울 때 pane 에서 `C-c` 를 누르지 말 것.** 포그라운드 프로세스
  그룹 전체에 SIGINT 라 매크로까지 죽고 **반쪽짜리 Merged 가 남는다.** 완료 판정이
  `[ -s ]` 뿐이라 그 반쪽을 완료로 읽는다(§11.85 의 `empty_merged`). 셸 PID 에만
  `kill -TERM <pid>` 를 보내면 진행 중인 merge 를 끝내고 스스로 빠진다 (§11.109).
- **★ 시트 등재는 이제 cron 이 한다** (§11.126). `scripts/sheetlog-auto.sh --status`
  로 밀린 런을 본다. 쓸 때마다 메일이 오므로 **메일이 안 오는데 런이 쌓이면**
  후처리가 덜 끝났거나(완결 게이트가 미루는 중) cron 이 죽은 것이다.
  손으로 밀어 넣으려면 `--force`, 시험은 `--dry-run`.
- **★ 감시자는 '수집이 도는가' 만 본다. 그 밖은 `scripts/chainwatch.sh` 가 본다.**
  후처리가 죽거나(`/scratch` 가 빠지면 그렇게 된다) 계수율이 떨어져도 감시자는
  조용하다. 2026-09-01 에 둘 다 겪었다 (§11.138). `--status` 로 언제든 볼 수 있다.
  **알림이 안 오는데 이상하다 싶으면 cron 이 사는지부터 볼 것** (`crontab -l`).
- **★ 계수율이 떨어지면 보드보다 HV 를 먼저 의심할 것.** 2026-09-01 에 0 Hz 의
  원인이 PMT HV 였는데 보드 진단에 30분을 헛되이 썼다 (§11.131).
- **★ `df` 가 멀쩡해 보여도 마운트가 유령일 수 있다** (§11.124). USB 디스크가
  떨어졌다 다른 이름으로 붙으면 `findmnt` 는 옛 장치를 가리키고 `df` 는 캐시된
  수치를 낸다. `ls /dev/sd*` 로 **그 장치가 실제로 있는지** 먼저 볼 것.
- **★ rsync 이 `Input/output error (5)` 로 무더기 실패하면 장치가 사라진 것이다.**
  "디스크 이름이 바뀌어서 끊긴다"는 인과가 반대다 — **끊겼기 때문에 다시 붙으면서
  다음 빈 이름을 받는 것**이다. `dmesg` 에서 `device offline` 과 곧이은
  `Attached SCSI disk` 를 찾을 것. 저장소 서버의 USB 백업 디스크에서 실제로 겪었다
  (§11.123). UUID 로 마운트하면 오인만 막을 뿐 **끊김 자체는 안 멎는다.**
- **★★ 보드가 `LIBUSB_ERROR_TIMEOUT` 으로 부팅 실패하면 `usbreset` 만으로 안 된다.**
  `usbreset` 은 USB 링크만 다시 맺고 보드 안의 FPGA·펌웨어 상태는 그대로다.
  **보드 크레이트 전원을 내렸다 올려야** 풀린다 — **PC 재부팅으로는 안 된다**
  (보드가 자체 전원을 쓴다). 그리고 전원을 내리면 트리거 설정이 날아가므로
  **`src/NOTICE_CODE_RUN.sh` 로 반드시 다시 설정할 것.** 안 하면 계수율이
  정상의 20배가 넘는다(실측 23,527 Hz). 전체 절차는 §11.119.
- **★ 감시자 없이 `rcterm` 을 직접 돌리면 실패 시 `daq`·`tcb` 가 고아로 남는다.**
  포트 3개를 계속 잡아 다음 시도를 막는다. `scripts/killdaq.sh -b <bindir>` 로
  치울 것 — **인자 없이 부르면 `bin directory not found` 로 실패한다** (§11.119).
- **★ 살아 있는 DAQ 를 찾을 때 `pgrep -f` 를 쓰지 말 것.** 저장소 경로에
  `rcterm` 이 들어 있어(`RENE-daq-rcterm`) 자기 셸과 postrun·dataflow 까지
  잡힌다. `pgrep -x rcsupervisor|rcterm|daq|tcb|merger` 로 볼 것 (§11.67 · §11.119).
- **★ 전원을 내리기 전에 `sudo umount /scratch`.** `hard` 마운트라 스토리지가
  먼저 사라지면 종료가 그 자리에서 멎는다. fstab 에 `nofail` 이 없어 부팅도
  늘어질 수 있다 (§11.113).
- **★ 저장소 서버 백업은 Merged 를 담지 않는다** (§11.152). 뺀 것은 원본에 남고
  `dataflow` 의 M단계가 지운다. Merged 까지 담으려면 `--no-skip`.
  **★ 청소를 켜기 전에 저장소 서버에서 백업이 도는지 볼 것** — 같은 트리라
  원본을 지워 rsync 를 죽인다 (§11.151 에서 7시간 38분을 날렸다).
- **★ Merged 는 물리 자료가 아니라 재처리 캐시다** (§11.149, 실측). 분석 입력은
  PRD 하나로 충분하다. `dataflow.sh --merged-keep N` 으로 최근 N 개 런만 남기고
  청소한다 (§11.150). **기본은 꺼져 있고**, `--dry-run` 으로 먼저 볼 것.
  **★ PRD 는 이 규칙의 대상이 아니다** — 지우지 말 것.
- **★ 저장소 서버의 외장하드 백업은 이제 하드 두 개를 순서대로 쓴다** (§11.143).
  `ssh store` 로 가서 `/home/frontend/data_backup_simple_code9.sh`. 하드 하나가
  차면 그 자리에서 다음 하드로 이어지고, **다음 하드가 없거나 가득 차면 멈추고
  메일이 온다.** 결과는 언제나 메일로 오므로(하드 UUID·시리얼 포함) 어느 하드를
  뽑을지 본문만 보면 된다. **띄우기 전에 이미 도는 것부터 볼 것** (§11.141).
  메일이 안 오면 `scripts/mailq-send.sh --status` 로 큐를 본다.
  **★ 새 하드를 끼웠으면 `sudo chown` 부터** — 갓 포맷한 하드의 루트는 root 소유라
  백업 폴더를 만들 수 없다. 기동 화면이 `쓰기 권한 없음` 으로 알려준다 (§11.148).
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
우리 것    29개.  런 4280 이상  +  되메운 4208 4209 4210 4211 4276
```

우리가 쓴 29개 : 4208 4209 4210 4211 4276 4280 4282 4283 4284 4285 4286 4287
4288 4289 4290 4291 4292 4293 4294 4300 4301 4302 4303 4304 4305 4306 4307
4313 4314.
**여기에 행을 더할 때마다 이 목록도 늘린다.**
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
자동       scripts/sheetlog-auto.sh        ★ 2026-08-28 부터 cron 이 매시 07분에
           부른다. 5개 이상 밀리면 즉시, 아니면 하루 한 번. 쓸 때마다 메일.
           후처리가 완결된(FADC==PRD) 런까지만 쓴다 (§11.126)
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

> **옛 기록은 `docs/HISTORY-2026-08.md` 에 있다.** 2026-08-13 ~ 08-25 분을
> 그리로 옮겼다 (절 번호 §11.x 는 그대로다). `CLAUDE.md` 는 매 세션 통째로
> 읽히므로 최근 것만 여기 둔다. **§11.100 이하를 가리키는 참조는 그 파일에서 찾는다.**

### 2026-09-03 — 백업 하드를 두 개 순서대로 쓰게 하고, 결과를 메일로 보낸다

#### 11.143 ★★ `scripts/storage-backup.sh` — 하드가 차면 다음 하드로 이어간다

사용자 요청 : 하드를 두 개(`/backup_hdd` · `/backup_hdd_2`) 개별 마운트해 두었으니
**하나가 담을 수 있을 때까지 담고 나면 다음 하드로 그대로 이어지게** 할 것. 그리고
**다음 하드가 가득 차 있거나 마운트되어 있지 않으면 오류를 남기고 멈출 것.**

**★ 이 스크립트는 이제 저장소가 정본이다.** §11.140 이 "그 서버에만 있다"고 적어
둔 것을 바로잡았다 — `scripts/storage-backup.sh` 가 정본이고, 스토리지 서버에는
`/home/frontend/data_backup_simple_code9.sh` 로 배포한다. **`code8` 은 손대지 않고
그대로 남겨 두었다** (되돌릴 자리).

```
하드 두 개   /backup_hdd    /dev/sdb1  UUID e39bd49a-048e-4d7e-adab-e4bdf37d902f  1.8T
             /backup_hdd_2  /dev/sdc1  UUID 09387574-057f-4e82-9a54-5de598765876  1.8T
             둘 다 ST2000DM008. 2026-09-03 기준 양쪽 다 비어 있었다
```

**한 회차를 마친 뒤의 판단 — 여기가 이 변경의 전부다.**

```
남은 일이 없다 (원본이 비었거나 남은 것이 '사용 중' 런뿐)
      -> ✅ 성공 종료 (exit 0).  ★ 다음 하드는 건드리지도 않는다
남은 일이 있다  +  이 하드가 실제로 찼다
      -> 다음 하드로 넘어간다.  그때 메일 한 통 (그 하드를 뽑아 가도 된다는 뜻)
남은 일이 있다  +  이 하드는 안 찼다   (--split never 로 큰 런이 안 들어갈 때)
      -> ★ 하드를 바꿔도 소용없다. 사유를 적고 멈춘다. 하드를 헛되이 태우지 않는다
```

넘어가는 그 순간에만 요청하신 오류 판정을 한다.

```
다음 하드가 마운트돼 있지 않다   -> 오류 + 메일 + exit 1
다음 하드에 여유 공간이 없다      -> 오류 + 메일 + exit 1
목록의 하드를 다 썼는데 남았다    -> "교체하세요" + 메일 + exit 3
연속 3회 전송 실패                -> 하드웨어 의심. 다음 하드로 넘어가지 않는다 + exit 1
```

**★ 첫 하드가 이미 가득 차 있는 것은 오류가 아니다.** 지난 세션에서 채운 것이므로
그냥 다음 하드로 넘어간다. 이것을 오류로 두면 이어받기가 매번 막힌다.

code8 의 안전장치는 전부 그대로다 — flock + 프로세스 검사, 30분 정숙 검사,
`.rsync-partial` 검사, skip 목록, **보낸다 -> 개수·바이트 대조 -> 통과한 것만
지운다**, 지우기 직전 원본 재확인.

#### 11.144 ★★ 메일 — 스토리지 서버에는 인터넷 경로가 없다

설계를 가른 실측이다. **추측하지 말 것.**

```
ssh store 'ip route'          10.0.0.0/24 dev ens6f1  ... 이것 하나뿐. 기본 경로 없음
ssh store 'getent hosts smtp.gmail.com'   rc=2        DNS 도 안 된다
ssh store 'ls ~/.ssh'         authorized_keys 뿐 — 개인키가 없어 DAQ PC 로 되돌아
                              붙지도 못한다 (그쪽 sshd 는 50022 에 있다)
```

그래서 **파일로 떨구고 DAQ PC 가 집어 보낸다.** `/data` 는 DAQ PC 에서 `/scratch`
이므로 이미 있는 마운트만 쓴다 — **새 열쇠도, 새 신뢰 방향도 만들지 않았다.**

```
store   /data/MAILQ/<시각>-<pid>-<번호>.tmp 에 쓰고 -> .mail 로 rename (원자적)
DAQ PC  cron 5분  ->  scripts/mailq-send.sh  ->  tools/notify/send_mail.py
        성공 sent/ · 5회 실패 failed/ · 그 사이엔 큐에 두고 재시도
        ★ /scratch 가 빠져 있으면 조용히 물러난다. 큐는 남아 나중에 나간다
```

보내는 때는 **하드가 가득 차 넘어갈 때 한 통 + 세션이 끝날 때 종합 한 통 +
오류로 멈출 때 한 통.** 수신자는 `mail_to`(책임자 1명)다 — 하드가 찬 것은
11명이 현장에 가야 하는 일이 아니다.

본문에 **장치명 · UUID · 모델 · 시리얼 · 용량/사용/여유/채움률 · 담긴 런 범위 ·
남은 일 · 그 세션 로그 끝 40줄**이 들어간다. 새벽에 이것만 보고 어느 하드를
뽑을지 알 수 있어야 한다.

**설계에서 신경 쓴 것**

- **메일이 안 나가도 백업은 계속된다.** `queue_mail` 은 어떤 실패에도 0 을
  돌려준다. 큐 디렉터리를 못 써도 그 사실만 화면에 적고 백업을 마친다.
  알림이 감시 대상을 죽이면 없느니만 못하다 (`daq-notify.sh` 와 같은 원칙).
- **`mailq-send.sh --dry-run` 은 큐를 소비하지 않는다.** 시험을 쓰다 잡은 결함이다 —
  사람이 설정을 점검하려고 돌렸다가 아직 안 나간 알림을 지워 버리면 아무도 못 본다.
- **겹쳐 돌지 못한다.** cron 5분보다 한 회차가 길어질 수 있어(망이 느릴 때)
  `flock` 으로 막는다. 보내다 죽어 `.sending` 으로 남은 것은 30분 뒤 되살린다.

#### 11.145 ★★ 시험이 잡은 두 함정 — 둘 다 `pgrep -f` 와 계획 파일이다

**① `pgrep -f` 가 이번엔 '조상' 과 '이미 죽은 것' 을 잡았다.**
§11.67 · §11.119 · §11.141 에 이어 네 번째다. code8 의 걸러내기는 **자손만** 뺀다.

```
조상       나를 띄운 셸의 argv 에 스크립트 경로가 통째로 들어 있으면 그대로 걸린다
           (ssh 로 긴 명령을 보내거나 heredoc 으로 띄울 때가 그렇다)
이미 죽음   $( ) 는 이 스크립트의 명령줄을 물려받은 서브셸을 잠깐 만든다.
           pgrep 은 그것을 잡는데 우리가 ps 로 확인할 때는 벌써 사라져 있어
           조상 추적이 빈손으로 끝나고 -> '남의 백업' 으로 오인한다
```

**시험에서 이것 때문에 한 회차도 시작하지 못했다** (57건 중 38건 실패).
고침은 셋이다 — 내 조상 목록을 미리 만들어 빼고, `ps -o args=` 가 비면
(죽은 것이면) 건너뛰고, 자손 추적은 그대로 둔다.

> **★ code8 에도 같은 구멍이 있다.** 타이밍에 따라 "이미 백업이 돌고 있습니다" 로
> 안 도는 일이 생길 수 있다. code8 은 되돌릴 자리로 남겨 둔 것이라 고치지 않았다.

**② 회차 사이에 계획 파일을 지워야 한다. 이것이 가장 위험한 자리였다.**

```
$PLANDIR/list.<런>  이 앞 하드의 것으로 남아 있으면
   -> 이번 회차가 그것을 그대로 읽어
   -> 보내지도 않은 파일을 '대조 통과' 로 보고 원본에서 지운다
```

시험 [6] 이 이것을 잡는다 — 하드 셋에 걸쳐 옮긴 뒤 **원본 목록(경로+바이트)과
세 하드를 합친 목록이 완전히 같은가**를 본다. 한 파일이라도 새면 깨진다.

#### 11.146 검증 — 하드도 자료도 메일도 건드리지 않고 99건

용량·마운트 판정을 `disk_is_mounted` / `disk_cap_kb` / `disk_used_kb` /
`disk_avail_kb` 네 함수로 빼고, `BACKUP_TEST_HOOK` 으로 갈아끼울 수 있게 했다
(§11.135 의 `DATAFLOW_ALLOW_UNMOUNTED` 와 같은 성격의 탈출구). **rsync 는 진짜로
돌고 파일도 진짜로 옮겨진다** — 그래야 '보내지 않은 것을 지우지 않는가' 를 볼 수 있다.

```
tests/storage-backup.test.sh   57건 통과
   하드1 -> 하드2 이어담기 · 첫 하드에 다 들어가면 둘째를 안 건드림
   다음 하드 미마운트 / 가득참 -> exit 1 + 메일 · 하드 소진 -> exit 3
   ★ 회차 사이 계획 파일 누수 없음 (원본과 바이트 단위 일치, 중복 0)
   연속 실패 -> 중단하고 다음 하드로 안 넘어감 · '사용 중' 런만 남으면 정상 종료
   --dry-run · 첫 하드가 이미 가득 · 첫 하드 미마운트 · --no-mail
   큐를 못 써도 백업은 끝난다 · cron 환경(env -i)

tests/mailq-send.test.sh       42건 통과
   발송/실패/재시도/5회 포기 · 본문에 'subject:' 'body:' 가 있어도 정확히 가름
   .sending 되살리기 · 갓 만든 .sending 은 안 건드림 · 마운트 없으면 조용히 물러남
   겹쳐 돌지 않음(flock) · --status 읽기 전용 · --dry-run 이 큐를 안 비움 · cron 환경
```

**실서버 확인 (읽기 전용)** — `data_backup_simple_code9.sh --dry-run`

```
/backup_hdd 여유 1.70 TB 에 run 002443 을 8,697 / 53,210 개로 잘라 담는 계획
   FADC 8537 (서브런 00000~10536) · Merged 2 · PRD 2 · PNG 156
   1.70 TB · 50 MB/s 로 약 9시간 53분 -> 끝나면 여유 2.0 GB
   그 뒤 /backup_hdd_2 로 이어진다
```

**메일 경로 실측** — 스토리지 서버에서 `/data/MAILQ` 에 넣은 파일이 DAQ PC 의
`/scratch/MAILQ` 로 보이고, `send_mail.py` 가 `[RENE DAQ] ...  -> sfc5302@gmail.com`
으로 해석해 **실제 발송 rc=0** 까지 확인했다.

> **★ 그 확인 중에 의도하지 않은 메일이 한 통 나갔다.** cron 을 먼저 설치한 뒤
> 배관 확인용 파일을 넣었는데, 지우기 전에 5분 주기가 먼저 돌아 제목이
> `배관 확인 (발송하지 않음)` 인 메일이 그대로 발송됐다. 내용은 무해하다.
> **cron 이 도는 큐에 '보내지 않을 파일' 을 두지 말 것** — 큐에 들어가는 순간
> 그것은 보낼 메일이다.

#### 11.151 ★★ 백업이 7시간 반 만에 끊겼다 — 내가 켠 청소가 원본을 지웠다

사용자 신고 : "백업이 한 번에 안 끝나고 중간에 끊겼다. 하드 1번을 다 못 채우고
2번으로 넘어갔다." **로그를 보니 원인이 셋이고, 첫째는 내가 만든 것이다.**

```
09-04 00:16:20  저장소 서버 백업이 /data/RAW/002443 전송 시작 (Merged 5,952개 포함)
09-04 03:44:23  ★ 내가 켠 Merged 청소가 그 폴더를 지움 — 4,687개 / 1,055 GB
09-04 07:54:24  FAIL rsync 002443 rc=24  ("vanished source files")
```

**저장소 서버의 `/data` 는 이 PC 의 `/scratch` 와 같은 곳이다.** 두 기계가 같은
트리를 만지는데 서로의 프로세스를 볼 수 없다. §11.141 에 "저장소 서버에서
무언가 띄우기 전에 이미 도는 것부터 보라" 고 적어 두고, **정작 이 PC 에서 청소를
켤 때 저쪽을 안 봤다.** 7시간 38분어치 전송이 날아갔다.

**둘째 — 이미 목적지에 있는 파일을 '옮겼다' 고 센다.**

```
18:01:51  002443 전송 시작
18:02:11  부분백업 12,683 개 (남은 19,083 개)     ← 38초에 12,683 개?
18:02:29  종료 code=3 : 더 담지 못했습니다        ← 하드에 427 GB 가 남은 채
```

38초에 12,683개를 옮길 수는 없다. ①에서 이미 보내 놓고 실패해 원본이 남아 있던
파일들이라 rsync 가 건너뛴 것이다. **계획은 여유만큼 파일을 고르는데 그중 이미
목적지에 있는 것을 세지 않아**, 할당량이 다 차고도 하드는 한 바이트도 안 줄었다.

**셋째 — 한 회차에 계획을 한 번만 세운다.** 계획을 다 실행하면 자리가 남아 있어도
다시 계획하지 않고 회차를 끝낸다.

#### 11.152 ★★ 네 가지를 고쳤다 (code9 · code10 양쪽)

| | 무엇 | 왜 |
|---|---|---|
| **A** | `SKIP_DIRS` (기본 `Merged`) — Merged 를 백업하지 않는다 | 경합 원천 제거 + 하드 1/3 절약 |
| **B** | 이미 목적지에 있는 파일은 **용량으로 세지 않는다** | 하드가 실제로 찬다 |
| **C** | 자리가 남으면 **한 하드 안에서 다시 계획**한다 | 하드를 끝까지 채운다 |
| **D** | `rc=24` 는 **살아남은 것만 추려 대조**한다 | 7시간을 통째로 버리지 않는다 |

**A 의 근거는 §11.149 다** — Merged 에는 PRD 에 없는 물리 정보가 없다. 재생 가능한
캐시를 장기 보관 하드에 넣느라 1.8 TB 하드의 3분의 1(실측 625 GB)을 쓰고 있었다.
**뺀 Merged 는 원본에 남는다** — 지우는 것은 `dataflow` 의 M단계 몫이다.

**★ 시험이 잡은 것 셋 — 셋 다 안 잡았으면 운영에서 터졌다.**

```
① awk 의 NR==FNR 관용구는 첫 파일이 비면 무너진다
     목적지가 비어 있는 것이 오히려 보통이라, 두 번째 파일을 첫 파일로 오인해
     한 줄도 안 내보낸다 -> 계획이 통째로 비어 아무것도 백업되지 않았다
     고침 : FILENAME 으로 가른다
② Merged 를 빼자 '백업할 파일이 0 개인 런' 이 생겼는데 full 갈래가 그것을
     걸러내지 않아 0개짜리 계획을 만들고, 매 회차 '부분 백업했다' 로 세어
     ★ 한 하드에서 무한 반복했다 (시험에서 3,531 회차)
     고침 : NF==0 이면 계획에 넣지 않는다 + '남은 일' 판정도 같은 눈으로 본다
③ 다회차 시험이 처음엔 아무것도 검증하지 못했다 — 그 숫자에서는 첫 계획이
     하드를 정확히 채워 2회차가 필요 없었다. du 가 Merged 까지 세어 계획이
     실제보다 크게 잡히는 현실적인 상황으로 다시 짰다
```

**검증 107건** (한글판) — 실하드·실데이터·실메일 무접촉. 새로 넣은 것은
A(Merged 제외 / `--no-skip`) · B(이미 있는 파일) · C(다회차) · D(rc=24 생존자) ·
**회차 폭주 방지**다.

**★ 두 판본을 같은 패치로 고쳤다.** 코드 줄이 바이트 단위로 같다는 점을 이용해
하나의 패치를 양쪽에 적용하고 문구만 갈아 끼웠다. 끝나고 **주석·문자열·heredoc 을
뺀 '코드 뼈대'가 같은지 기계로 확인**했다 — 다른 곳은 어순 차이 한 줄뿐이다
(`X 중 Y` ↔ `Y of X`).

#### 11.149 ★★ Merged 에 물리 정보가 있는가 — 실측으로 답했다. 없다

사용자 질문 : "Merged 는 production 용 파일이지 분석에 쓸 내용은 없어 보인다.
보관·분석할 물리 정보가 있나? PRD 만으로 충분한가?"

**답 : 없다. PRD 하나로 충분하다.** run 4322 서브런 100(57,523 이벤트)을 열어
대조했다. **추측이 아니라 값으로 확인한 것이다.**

| | Merged (`AbsEvent`) | PRD (`Event`) |
|---|---|---|
| 이벤트 | 57,523 | **같음** |
| FADC | ID 1·2·3·4, 각 57,523 회 | **같음** |
| SADC | ID 30 종, 총 1,725,690 hit | **ID·개수 모두 같음** |
| 파형 | `ArrayS` | `F_Waveform_0..3` |
| 크기 | 75.5 MB | 70.9 MB |

**파형이 같은 데이터임을 값으로 확인했다** — 앞 200 이벤트 파형 총합이 양쪽
**349,409.1** 로 일치한다.

**PRD 가 안 가진 것은 넷뿐이고 셋은 비어 있다.**

```
fStartTime · fEndTime · fTrgType · fNHit    ★ 전 이벤트가 상수. DAQ 가 안 채운다
SADC 쪽 EventInfo 사본                      FADC 와 fTrgNum·fTCBTrgTime 차이 0 건
fTrgTime                                    ← 유일하게 이벤트마다 다른 값
```

**★ 그 `fTrgTime` 은 TCB 시계를 풀어 놓은 것이다.**

```
fTrgTime     폭 59.991 초   되감김 0 회      ← 서브런 60 초를 한 번에 덮는다
fTCBTrgTime  폭 16.777 초   되감김 4 회      ← PRD 가 갖는 것
차이 : 되감김 구간 안에서 상수
```

즉 독립적인 물리량이 아니라 **PRD 의 `TCBTRGTime` 에서 복원되는 값**이다. 분석이
이미 그 되감김을 풀고 있고(§ 모니터링), 그 결과가 분석 체인과 비트 단위로
일치함이 §11.31 에서 확인돼 있다.

**그리고 SADC 는 파형이 어디에도 없다** — `AChannel` 이 `fADC`·`fTime` 뿐이다.
전하적분형 보드라 원래 파형이 없고, PRD 의 `S_ADC`·`S_PeakTime` 이 그 전부다.

**오히려 PRD 가 더 갖는다** — `F_THR`·`S_THR`(문턱값) · `F_NDP` ·
`S_VETO_DeltaT` · `EventType` 은 Merged 에 없다.

> **결론 — Merged 는 물리 자료가 아니라 재처리 캐시다.** 남겨 두는 값어치는
> production 을 다시 돌릴 때 merge(서브런당 28초)를 건너뛰는 것뿐이다.
> **★ 다만 PRD 를 지우는 것은 전혀 다른 이야기다.** PRD 도 RAW 에서 다시 만들
> 수 있지만 서브런당 43초가 들고, 무엇보다 `DLY_THR` 로그가 있어야 한다
> (그 로그가 없어 production 이 통째로 죽은 것이 §11.139 다).

#### 11.150 ★★ `dataflow.sh` 에 Merged 청소(M단계)를 넣었다

사용자 요청. 기존 `--drop-merged` 는 **3단계에서만, 전부 아니면 전무**라
`/scratch` 에 이미 쌓인 것을 손대지 못했다. 용량의 대부분이 거기 있다.

```
--merged-keep N     최근 N 개 런의 Merged 만 남기고 나머지를 지운다
                    ssd · mid · nfs 세 뿌리를 모두 훑는다
--stage M           청소만 한다.  기본값은 0 = 청소 안 함
```

**★ 보관 창은 세 뿌리를 합쳐서 센다.** 뿌리마다 따로 세면 3배가 남는다.

**지우기 전 관문 넷 — 하나라도 걸리면 손대지 않는다**

```
1  수집 중인 런이 아니다
2  PRD 가 완결이다     RAW 가 있으면  PRD 개수 == FADC 개수
                       RAW 가 없으면  PRD 가 1개 이상        ← 아카이브된 런
3  PRD 에 0 바이트 파일이 없다
4  Merged 가 심볼릭 링크가 아니다 (옛 --outroot 구성)
```

**★ 관문 2 가 두 갈래인 것이 핵심이다.** 외장하드로 아카이브된 런은 RAW 가 없어
`is_processed()` 가 영원히 거짓이다. 그 갈래가 없으면 **정작 용량을 가장 많이
먹는 옛 런이 청소에서 통째로 빠진다.**

**실측 (읽기 전용 dry-run, 1분 소요)**

```
지울 대상   런 1,394 개 · Merged 206,585 개 · 34.8 TB   (전부 /scratch)
            중앙값 3 G · 최대 1,331 G
손대지 않음 42 개  — PRD없음 25 · 후처리미완료 17
/scratch    지금 여유 19 T -> 청소하면 약 54 T
```

**★ 회차당 상한 `--merged-max N` (기본 20000 파일).** M단계는 주기의 **맨 끝**에
도는데, 처음 켤 때는 지울 것이 20만 개가 넘어 **12.5시간**이 걸린다(실측 4.6
파일/초, NFS 메타데이터 병목). 그동안 1·2·3 단계가 통째로 밀린다. 상한을 두면
매 주기 조금씩 지우고 나머지 단계는 제때 돈다.

```
런 수가 아니라 파일 수로 잰다   런 하나가 3 GB ~ 1,331 GB 로 400배 차이라
                               런 수로는 걸리는 시간을 묶을 수 없다
상한은 런을 시작하기 전에만 본다 그래야 상한보다 큰 런(최대 38,795 개)도
                               언젠가 지워진다. 중간에 끊으면 영영 남는다
```

**기본값은 꺼짐이다.** `git pull` 만으로 자료가 지워지기 시작하면 안 된다.
켜려면 `config/dataflow.params` 에 `keep_merged = 5` 를 넣고 **dataflow 를
재시작한다**(돌고 있는 것은 옛 inode 를 붙들고 있다, §11.135).

**검증 46종** — 실데이터·실디스크 무접촉. 보관 창 · 세 뿌리 합산 · 관문 넷 ·
기본값 꺼짐 · `--dry-run` · 전체 주기 연결 · cron 환경.

**곁들여 고친 것** — `LOCK` 경로가 고정이라 **운영 중인 dataflow 와 잠금이 겹쳐
시험이 조용히 exit 0 으로 끝났다.** `DATAFLOW_LOCK` 으로 갈아끼울 수 있게 했다.
그리고 `--stage M` 을 주면 `[ "$STAGE" -eq 2 ]` 가 "정수가 필요하다"로 죽어
문자열 비교로 바꿨다.

#### 11.148 ★★ 첫 실행이 죽었다 — 원인은 분할이 아니라 갓 포맷한 하드의 권한

사용자 신고 : "런 폴더 용량이 백업하드보다 커서 백업이 불가하다는 메시지와 함께
중단됐다. 서브런별로 채울 수 있을 때까지 채우는 부분이 왜 미반영됐나."

**★ 분할은 반영돼 있었고 정상 동작했다.** 로그가 그것을 그대로 보여준다.

```
[01:05:48]  002443 전송 시작 (part) -> /backup_hdd      <- 8,697 / 53,210 개로 잘랐다
rsync: [Receiver] mkdir "/backup_hdd/RENE_data_backup/002443" failed:
                  No such file or directory (2)
[01:05:48] FAIL rsync 002443 rc=11
[01:06:12] 종료 code=3 : 담을 수 없는 런이 남았습니다 (런 1673 개)   <- ★ 오진
```

**진짜 원인.** 두 하드를 그날 00:18 · 00:19 에 새로 포맷했다. 그래서 마운트 루트가
`root:root 755` 이고 `frontend` 가 그 밑에 `RENE_data_backup` 을 만들 수 없다.

```
drwxr-xr-x 3 0 0 /backup_hdd        <- 갓 포맷한 상태
drwxr-xr-x 3 0 0 /backup_hdd_2
mkdir: cannot create directory '/backup_hdd/RENE_data_backup': Permission denied
```

**옛 하드에서는 안 나던 문제다** — 그 폴더가 이미 있었고 `frontend` 소유였다.
`code8` 도 같은 구멍이 있으나 그 하드를 계속 써서 드러나지 않았다.

**★ 내가 만든 진짜 결함은 셋이다. 권한은 사이트 상태이고, 아래가 코드 문제다.**

```
① mkdir -p "$DEST" 2>/dev/null      사유를 삼켰다. 그래서 아무도 권한을 의심하지 못했다
② 그 검사가 계획 뒤에 있었다         1,723 개를 다 재고 첫 rsync 에서야 죽는다
③ 진도가 없으면 무조건 stuck 으로     '--split 으로는 쪼갤 수 없다' 를 찍었다.
                                     ★ 그 문장이 사람을 분할 코드로 보냈다.
                                       게다가 SPLIT_MODE 가 이미 always 인데
                                       "always 로 실행하세요" 라고 하는 자가당착이었다
```

**고침**

| 무엇 | 어떻게 |
|---|---|
| `dest_ready()` | 하드에 들어가는 첫 줄에서 **만들어 보고 · 써 보고 · 지운다**. `-w` 만으로는 root 스쿼시·읽기전용 재마운트를 못 잡는다 |
| 실패 메시지 | OS 가 낸 사유를 **그대로** 싣고 `sudo chown` 명령까지 찍는다 |
| 전송 중 `mkdir` | 실패를 삼키지 않고 사유와 함께 낸다 |
| 회차 뒤 판정 | `N_FAIL > 0` 이면 **`xferfail`**(전송 실패, exit 1), 아니면 `stuck`. `stuck` 은 **진짜로 쪼개기가 제약일 때만** `--split` 을 말한다 |
| 기동 화면 | 하드마다 장치 · 여유 · **쓰기 가능 여부**를 먼저 보여준다 |

**★ 곁들여 잡은 것 — `--dry-run` 이 메일을 보냈다.** 오류 경로가 전부 `finish` 를
지나는데 거기서 큐에 넣고 있었다. 미리보기가 바깥으로 나가면 '아무것도 바꾸지
않는다'는 약속이 깨진다. `queue_mail` 에서 한 번에 막았다.

**새 시험 둘 — 이번 일을 그대로 재현한다**

```
[15] 런 하나가 어느 하드보다도 크다   -> 하드 셋에 걸쳐 나뉘고, 원본과 바이트 단위 일치,
                                        중복 0, 매니페스트 3개.  ★ 사용자가 의심한 바로 그 기능
[16] 마운트는 됐는데 쓸 수 없다       -> 계획을 세우기 전에 exit 1, OS 사유 그대로, chown 안내
                                        같은 상황을 --dry-run 으로 하면 메일은 안 나간다
[17] 전송 실패를 stuck 으로 오진 않는다 -> exit 1 이고 --split 을 지목하지 않는다
[18] 기동 화면이 하드 상태를 먼저 보여준다
```

`storage-backup` **80건** + `mailq-send` **42건** 통과.

**★ 이번 일에서 남길 교훈.** 오진 메시지는 틀린 정보보다 나쁘다 — 사람을 **멀쩡한
코드로 보낸다.** 사용자가 분할 코드를 의심한 것은 전적으로 내 메시지 탓이다.
진단은 **자기가 아는 유일한 설명을 고르지 말고, 근거가 없으면 없다고 말해야 한다.**

**사람이 해야 할 것 (root 필요. 이 세션은 sudo 암호가 없어 못 했다)**

```bash
ssh store
sudo chown frontend:frontend /backup_hdd /backup_hdd_2
/home/frontend/data_backup_simple_code9.sh --dry-run     # 계획 확인
nohup /home/frontend/data_backup_simple_code9.sh > ~/sykim/backup_log/code9.log 2>&1 &
```

#### 11.147 이 변경으로 늘어난 운용 항목

```
cron (DAQ PC)   */5 * * * * scripts/mailq-send.sh      메일 큐 비우기
                ★ 기존 crontab 은 ~/crontab.bak-<날짜시각> 로 백업해 두었다
상태 보기       scripts/mailq-send.sh --status         읽기 전용
                ssh store '/home/frontend/data_backup_simple_code9.sh --dry-run'
큐              store:/data/MAILQ  =  DAQ PC:/scratch/MAILQ   (sent/ · failed/ 하위)
```

**★ 갓 포맷한 하드는 먼저 소유권을 넘겨야 한다** (§11.148). 기동 화면의 '쓸 하드'
줄에 `쓰기 권한 없음` 이 보이면 거기 찍힌 `sudo chown` 을 먼저 실행한다.

**★ 백업을 띄우기 전에 이미 도는 것부터 볼 것** (§11.141 은 여전히 유효하다).

```
ssh store 'ps -eo pid,lstart,args | grep -E "data_backup|storage-backup" | grep -v grep'
```

### 2026-09-02 — 저장소 서버의 외장하드 아카이브 스크립트를 다시 만들었다

#### 11.140 ★★ `/backup_hdd` 아카이브 — 폴더 하나가 1,700개를 막고 있었다

**★ 이것은 우리 파이프라인이 아니다.** 저장소 서버(`ssh store`) 안에서 `/data/RAW`
를 USB 외장하드로 **옮기고 원본을 지우는** 아카이브 작업이고, 스크립트는
`/home/frontend/data_backup_simple_code*.sh` 다 (`code7` 이 원본, `code8` 이 새 판이다).

> **★ 2026-09-03 에 이 절이 낡았다.** 그때 "이 저장소에는 없다" 고 적었으나, 이제는
> `scripts/storage-backup.sh` 가 정본이고 그 서버에 `code9` 로 배포한다 (§11.143).
> **아래 `code8` 이야기는 그 배경으로 읽을 것.** `code8` 은 되돌릴 자리로 남겨 두었다.
`postrun`·`dataflow`·`backup-khu` 와는 별개다. **다만 `/data/RAW` 는 우리 `/scratch/RAW` 와 같은 곳이라 충돌한다** —
아래 §11.141 의 경고를 볼 것.

**증상** — `code7` 이 폴더 하나가 안 들어가면 그 자리에서 `exit` 했다. 하필
디렉터리 맨 앞이 **002443(6.71 TB)** 이라, 하드에 1.6 TB 가 비어 있는데도
**한 개도 못 담고 끝났다.**

```
런 1,750 개 · 최상위 파일 508,163 개
중앙값 23 파일(~2 GB) · 90% 125 파일 · 최대 38,795 파일
하드보다 큰 런 10 개 (6.71 · 3.81 · 3.02 · 2.44 · … TB)
```

**`code8` 로 다시 썼다.** 옵션 없이 그냥 돌리면 된다.

| 무엇 | 왜 |
|---|---|
| 안 들어가면 건너뛰고 계속 담는다 | 하드를 남김없이 채운다 (채움률 99%) |
| 하드보다 큰 런은 **파일 단위로 잘라** 여러 하드에 나눠 담는다 | 6.7 TB 런도 결국 전부 백업된다 |
| **들어가는 파일은 모두** 담는다 (앞에서 끊지 않는다) | FADC 78 MB · SADC 9 MB 로 크기가 섞여 있어 차이가 크다 |
| 시작할 때 계획·소요시간·서브런 범위를 보여준다 | 8시간짜리 작업을 눈감고 시작하지 않는다 |
| **보낸다 -> 대조한다 -> 통과한 것만 지운다** | `code7` 은 `--remove-source-files` 로 보내면서 지웠다. 08-27 에 하드가 떨어졌을 때 0 바이트 파일 138 개가 그렇게 생겼다 |
| 속도 기본 50 MB/s | 무제한(79 MB/s)에서 하드가 떨어진 적이 있다 |

**남은 원본이 곧 진행 상태다.** 대조를 통과한 파일만 지우므로, 새 하드를 꽂고
같은 명령을 다시 치면 남은 것부터 이어진다. 상태 파일을 따로 두지 않는다.
어느 조각이 어느 하드에 있는지는 하드 안 `<런>/.part_manifest.txt` 와 서버의
`backup_log/parts_index.txt` 에 남는다.

**★ 시험이 잡은 진짜 버그 — `du -sb` 로 대조하면 안 된다.**

```
du -sb 는 디렉터리 자신의 크기까지 센다. 그 값이 파일시스템마다 다르다
   원본 XFS  ↔  외장하드 ext4     ->  멀쩡히 옮긴 폴더도 매번 대조 실패
고침 : find -type f -printf '%s' 로 파일 바이트만 더한다
```

이걸 못 잡았으면 **한 폴더도 못 옮겼을 것이다.** 하드 3개에 걸친 복원 시험
(37개 파일 105,906,176 바이트 → 빠짐·중복 0)에서 드러났다.

#### 11.141 ★★ 백업 스크립트를 두 개 띄웠다 — 내가 낸 사고와 그 방어

02:24 에 백업을 띄웠는데 **01:48 부터 이미 하나가 돌고 있었다.** 확인하지 않은
내 잘못이다.

```
pid 21588  01:48:45  002456 전송 중 (30M)   <- 사용자가 돌린 것
pid 38281  02:24:09  002443 전송 중 (50M)   <- 내가 확인 없이 띄운 것
```

**왜 나쁜가.** 같은 USB 하드에 동시에 **80 MB/s** — 08-27 에 이 하드가 버스에서
떨어진 바로 그 속도다. 그리고 둘 다 `df` 로 남은 용량을 계산하므로 서로의 소비를
모른 채 계획을 세운다. 하드가 예상보다 일찍 차서 둘 다 실패한다.

**잃은 것은 없었다** — 대조 전에는 원본을 지우지 않는 설계 덕에 `/data/RAW/002443`
53,210 개가 그대로였다. 내가 띄운 쪽만 세웠고, 이미 보낸 27 GB 는 유효한 파일이라
남겨 두었다(다음에 rsync 가 건너뛴다).

**★ `flock` 만으로는 부족하다.** 옛 판본으로 띄운 것은 그 잠금을 쥐지 않는다.
그래서 **프로세스 목록도 함께** 본다.

```
❌ 이미 백업이 돌고 있습니다 (pid 21588).
   Wed Sep  2 01:48:45 2026 /bin/bash ./data_backup_simple_code8.sh
```

`pgrep -f` 가 자기 자신과 `$(...)` 서브셸까지 잡는 것은 조상을 거슬러 빼서
해결했다 — §11.67 에서 badrun 이 밟은 것과 같은 함정이다.

**곁들여 넣은 충돌 방어 넷** (우리 파이프라인과 부딪히지 않게)

```
최근 30분 안에 바뀐 파일이 있는 런은 건드리지 않는다   <- 누가 쓰는 중이다
.rsync-partial 이 남아 있는 런도 건드리지 않는다        <- 전송이 진행 중이다
backup_log/backup_skip.txt 에 적은 런은 영구 제외
지우기 직전에 원본 크기를 다시 확인 -> 그 사이 바뀐 파일은 남긴다
```

**★ `find` 에 `-type f` 를 빠뜨리면 디렉터리 자신의 mtime 이 걸려 모든 런이
'사용 중' 이 된다.** 시험에서 백업이 한 개도 안 되는 것으로 드러났다.

**★ 교훈 — 남의 서버에서 무언가를 띄우기 전에 이미 도는 것부터 본다.**
`ps -eo pid,lstart,args | grep <이름>` 한 줄이면 됐다.

### 2026-09-01 — 전자계는 되살렸으나 계수가 0. 그리고 공인 IP 가 10G 포트로 옮겨져 있었다

#### 11.129 착수 시점 — 전부 멎어 있었다

```
DAQ        rcsupervisor · rcterm · daq · tcb · merger 전부 없음. 7809/7814/7815 비어 있음
tmux       세션 없음 (서버 자체가 없다)
/scratch   ★ 마운트되지 않았다. 10.0.0.10 무응답
run 4318   08-31 04:03 에 전체가 함께 사라져 aborted 로 표기돼 있다 (앞 세션이 기록)
run 4319·4320   09-01 03:48~03:49 부팅 실패. TCB USB3TCBRead LIBUSB_ERROR_TIMEOUT -> no module linked
확인 런    03:58 과 04:02 에 --run 999999 로 두 번 돌아 있었다
             1차 : 평균 6,960 Hz (순간 21,621 Hz)  <- 전원 재투입 뒤 트리거 설정이 날아간 모습 (§11.119)
             2차 : 0 events
```

#### 11.130 ★★ 0 Hz 의 원인을 좁힌 과정 — 두 개의 함정을 지났다

**함정 1 — SADC TLT 되읽기가 0 이다. 이것은 정상이다.**

```
SADCT config   : SUBPED(1)  TLT1~8(FFFE)
SADCT register : SUBPED(0)  TLT1~8(0)        <- 쓴 값과 다르다
```

"트리거 룩업테이블이 안 박혔다" 로 읽기 쉽다. **틀렸다.** 1,700만 이벤트를 정상으로
받은 run 4318 의 로그가 **똑같이 0 으로 되읽는다.** 이 되읽기는 원래 0 이다.
**정상 런의 로그와 대조하지 않았으면 여기서 엉뚱한 곳을 팠을 것이다.**

**함정 2 — 진짜 차이는 FADC DRAM 정렬이었고, `usbreset` 두 번째에 풀렸다.**

타임스탬프만 지우고 정상 런과 통째로 diff 했더니 실질적 차이가 **딱 한 덩이**였다.

```
run 4318 (정상)   DRAM(0) is aligned, delay = 5, bitslip = 0   ... 8개 전부
지금              Fail to align DRAM(0)!                        ... 8개 전부
```

FADC 의 이벤트 버퍼 메모리가 안 올라온 것이다. **그런데 설정은 "성공"으로 끝난다** —
`ConfigFADC: FADCT[mid= 3] was configured` 가 그대로 찍히고 아무도 오류를 내지 않는다.
로그를 끝까지 읽지 않으면 보이지 않는다.

```
NOTICE_CODE_RUN.sh  rc=0, pedestal 3691~3719 (§11.119 의 정상 범위)
usbreset (1회)      -> 확인 런 : DRAM 8/8 실패, 0 events
usbreset (2회)      -> 확인 런 : DRAM 8/8 정렬 (delay 5,4,4,4,3,3,3,3 = 정상 런과 같은 값)
```

**★ `usbreset` 를 한 번 더 걸어 볼 것.** §11.119 는 "usbreset 로는 안 된다"고 적었는데,
그것은 **TCB 의 LIBUSB_ERROR_TIMEOUT** 이야기였다. **FADC DRAM 정렬 실패는 두 번째
usbreset 로 풀렸다.** 전원 재투입을 부르기 전에 한 번 더 시도할 값어치가 있다.

**그리고 그래도 계수는 0 이었다.**

#### 11.131 ★★ 지금 상태 — 전자계는 정상, 신호가 없다

DRAM 까지 풀린 뒤 정상 런과 다시 통째로 대조했다. **차이가 없다.**

```
TCB 링크        FADCT[mid= 3] found @ 3 · SADCT[mid=65] found @ 4
설정            TCB · FADC · SADC 레지스터가 run 4318 과 한 줄도 다르지 않다
DRAM            8/8 정렬, delay 값까지 동일
pedestal        FADC 3908~3939 · SADC 443~486  (정상 런과 1~2 카운트 차이 = 온도 드리프트)
LIBUSB 오류     TCB · FADCDAQ · SADCDAQ 전부 0 건
DAQ config      /Data_ssd/CONFIG/999999.config 가 004317.config 와 바이트 동일
트리거          started -> stopped 정상
결과            72초 · 180초 두 번 다 FADCDAQ 0 events / SADCDAQ 0 events
```

**★ 여기서 멈췄다. 다음은 사람이 현장에서 볼 일이다.**

FADC 문턱은 pedestal 위 **80 카운트**뿐이고(ch3·ch4 는 5000000 = 비활성) 정상이면 PMT
암계수만으로도 약 1,000 Hz 가 나온다. **두 ADC 가 동시에 정확히 0 이라는 것은 아날로그
입력이 아예 없다는 뜻이다.** 가장 유력한 것은 **PMT HV 가 꺼져 있는 것** — 08-31 새벽
정지 때 내리고 안 올렸을 수 있다. 그 다음이 신호 케이블이다.

```
확인할 것   1) HV 전원 (rundesc 기준 PMT_A 1680V · PMT_B 1642V)
            2) FADC 입력 케이블 (ch1 · ch2 만 쓴다)
            3) 위 둘이 멀쩡하면 그때 보드 크레이트 전원 재투입 -> NOTICE_CODE_RUN.sh (§11.119)
```

**감시자는 일부러 띄우지 않았다.** 0 Hz 인 채로 띄우면 빈 런으로 런 번호만 태운다.

**★ 확인됐다 — HV 였다.** 사용자가 "PMT 에 HV 가 제대로 걸리지 않았다"며 올려 주었고,
곧바로 돌린 확인 런이 합격했다.

```
FADCDAQ  185,220 events / 180.3 s = 1027.2 Hz      (run 4307 이 1015.7 Hz)
SADCDAQ  184,832 events / 180.0 s = 1027.1 Hz
LIBUSB   TCB · FADCDAQ · SADCDAQ 전부 0 건.   DRAM 8/8 정렬
서브런   FADC 74~76 MB · SADC 8.8~9.0 MB      (정상 크기)
```

**전자계는 처음부터 멀쩡했고 신호만 없었다.** §11.130 에서 DRAM 정렬을 고친 것은
필요한 일이었지만, 0 Hz 의 원인은 아니었다. **다음에 0 Hz 를 만나면 보드를 파기 전에
HV 부터 물을 것** — 여기서는 보드 진단에 30분을 썼고 답은 검출기 쪽에 있었다.

수집을 재개했다 : `scripts/daq-tmux.sh --start` -> **run 4321**, 약 1023 Hz.
`rundesc` 는 `config/rundesc.txt` 에서 그대로 넘어가 이전 런들과 묶인다 (§11.20).

**★ `daq-tmux.sh --start` 는 tty 없이 부르면 마지막 `tmux attach` 에서
`open terminal failed` 를 낸다.** 그 앞의 구성은 `tmux new-session -d` 라 전부 끝난
뒤이므로 **실패가 아니다** — 세션과 감시자는 정상으로 떠 있다. 확인은
`tmux ls` 와 `pgrep -x rcsupervisor` 로 한다.

#### 11.132 ★★ 공인 IP 가 10G 포트로 옮겨져 있었다 — 지금은 되지만 재부팅하면 끊긴다

사용자 신고 : "1G 로 연결했던 203.230.111.71 에서 통신이 안 된다."
**실측하니 지금 이 순간 .71 은 살아 있다. 다만 1G 포트가 아니다.**

```
enp3s0f0   X710 port0, DAC, 10 Gbps   203.230.111.71   <- 지금 여기에 붙어 있다 (프로파일 daq_gateway)
enp0s31f6  온보드 1G, 케이블 꽂힘, 1000Mb/s Full 링크   IP 없음   <- 08-31 21:55 에 autoconnect=no 로 꺼졌다
enp1s0     캐리어 없음 (§11.115 에서 내린 그대로)
enp3s0f1   X710 port1, 10 Gbps        10.0.0.11        <- 저장소용. 그대로
```

**밖에서 확인했다 (경희대 서버에서 이쪽으로).**

```
203.230.111.71   ping 10.07 ms 손실 0 · 50022/tcp OPEN        <- 정상
203.230.111.75   ping 100% 손실 · 50022 · 22 전부 닫힘        <- 아무것도 없다
나가는 방향      8.8.8.8 38.6 ms · 1.1.1.1 8.2 ms · DNS OK · ssh khu OK · 게이트웨이 2.38 ms
```

**★ 그런데 저장된 프로파일과 실제가 어긋나 있다. 이것이 진짜 위험이다.**

```
daq_gateway 의 저장된 주소   ipv4.addresses : 203.230.111.75/24     <- 파일 (04:13 수정)
실제 적용된 주소             IP4.ADDRESS[1] : 203.230.111.71/24     <- 살아 있는 것
```

프로파일만 .75 로 고치고 반영은 하지 않은 상태다. **재부팅하거나 NM 을 다시 적용하는
순간 .75 로 뜨고, 위에서 보듯 .75 는 밖에서 전혀 안 잡힌다.** 사용자가 겪은 "통신이
안 된다"가 바로 이 상태로 넘어갔던 순간일 가능성이 높다.

곁들여 — **꺼 둔 `enp0s31f6` · `enp1s0` 프로파일에도 `203.230.111.71/24` 가 그대로
박혀 있다.** 셋이 같은 주소를 갖고 있어 어느 하나라도 autoconnect 가 켜지면 충돌한다.

**고칠 것 (root 필요. 이 세션은 sudo 비밀번호가 없어 실행하지 못했다)**

```bash
# 저장된 주소를 살아 있는 값으로 되돌린다. 반영은 안 되므로 지금 연결이 끊기지 않는다
sudo nmcli connection modify daq_gateway ipv4.addresses 203.230.111.71/24
sudo nmcli connection modify daq_gateway connection.zone public   # DAQ 포트가 열리지 않게 못박는다
```

**★ `nmcli connection up` 을 지금 하지 말 것.** 원격 접속이 그 자리에서 끊긴다.
주소를 실제로 바꾸는 작업은 콘솔에서 할 것.

**1G 로 되돌릴 값어치는 없다.** §11.121 에서 바깥 경로가 약 145 Mbps 에서 막혀 있음을
실측했다. 1G 든 10G 든 그 위로는 못 간다. **지금 10G 포트에 붙어 있는 것은 손해가 아니다.**
결정해야 할 것은 속도가 아니라 **사이트 스위치가 어느 포트/MAC 에 .71 을 등록해 두었나**
하나뿐이다. 지금 밖에서 잘 닿으므로 등록은 새 포트로 맞춰져 있다.

```
옛 1G 포트 MAC   4c:d7:17:a7:f7:b8 (enp0s31f6)
지금 쓰는 MAC    44:49:88:0c:e3:14 (enp3s0f0)
```

#### 11.133 ★★ 저장소 서버는 살아 있는데 프레임이 한 장도 안 온다 — 우리 쪽 설정은 그대로다

처음에 "저장소 서버가 꺼져 있다"고 적었다. **사용자가 살아 있다고 알려 주어 다시 쟀고,
결론이 바뀌었다** — 서버는 살아 있고, **문제는 그 사이의 L2 경로다.**

**실측 — 상대에게서 오는 프레임이 0 이다**

```
enp3s0f1        10 Gbps · carrier up · rx_errors 0 · rx_crc_errors 0 · rx_dropped 0
port.rx_unicast     0        <- ★ 상대의 ICMP 는 한 장도 안 왔다
port.rx_broadcast   0        <- ★ 상대의 ARP 도 한 장도 안 왔다
port.rx_multicast  76        <- 무언가는 15초에 한 번쯤 멀티캐스트를 보낸다
커널이 본 RX        bytes 0 · packets 0 · mcast 0
tx_broadcast      111        <- 우리 ARP 는 나가고 있다
```

**이 수치가 "서버에서 여기로 핑이 간다"와 정면으로 어긋난다.** 유니캐스트·브로드캐스트가
부팅 이래 각각 0 이면 **그 핑은 이 포트로 도착한 적이 없다.** 다른 경로로 갔거나 다른
대상이었다고 보아야 한다.

**멀티캐스트만 76 장 오는 것이 실마리다.** 케이블 반대편이 죽어 있으면 0 이다. 살아
있으면서 유니캐스트·브로드캐스트를 한 장도 안 보내는 것은 둘 중 하나다.

```
A  반대편이 스위치다      LLDP/STP 같은 멀티캐스트만 흘린다. 그 VLAN 에 저장소 서버가 없다
B  반대편 호스트의 인터페이스가 IPv4 없이 UP 이다
        IPv6 MLD/RS 멀티캐스트만 내보내고, IPv4 가 없으니 우리에게 ARP 를 걸 일도 없다
```

**세그먼트를 훑어도 아무도 없다.** `10.0.0.{1,2,5,9,10,11,12,20,100,254}` 중 응답한 것은
**우리 자신(10.0.0.11)뿐**이다. IPv6 `ff02::1` 이웃탐색에도 우리만 답한다.

**공인망으로 우회할 수 있는지도 확인했다 — 안 된다.**

```
203.230.111.0/24 전체 훑기
   살아 있는 호스트   .1(게이트웨이) .2 .71(우리) .74 .100 .145
   2049 열린 곳       .71(우리 자신) · .100
   7777 열린 곳       없음        <- 저장소 서버의 ssh 포트다. 공인망에 없다
203.230.111.100    NFS 서버는 맞다 (mountd 892 · v2/3/4 · RTT 0.27 ms)
                   그러나 MAC 00:11:32 = **Synology**. §11.118 의 Rocky 9.6 서버가 아니다
                   export 목록도 우리에게는 비어 있다.  ★ 우회 경로가 못 된다
```

**★ 우리 쪽 설정은 §11.115 기록과 한 글자도 다르지 않다.**

```
storage10g   interface enp3s0f1 · autoconnect 예 · zone trusted
             ipv4.method manual · 10.0.0.11/24 · never-default 예
firewalld    trusted: enp3s0f1        (DAQ 포트를 막는 public 과 분리돼 있다)
sysctl       rp_filter · arp_ignore · arp_filter 전부 기본값. ip_forward 0
경로         10.0.0.0/24 dev enp3s0f1 뿐. §11.115 처럼 죽은 인터페이스가 가로채지 않는다
```

**즉 08-31 작업으로 바뀐 것은 공인망 쪽뿐이고**(온보드 1G -> enp3s0f0, 그리고 §11.132 의
.75), **저장소 링크의 우리 쪽 구성은 손대지 않았다.** 남은 것은 케이블이거나 상대편이다.

**★ 가장 값싼 판별 — 케이블을 저장소 서버 쪽에서 뽑아 본다.**

```
저장소 서버 쪽에서 그 DAC 를 뽑는다  ->  이쪽에서 cat /sys/class/net/enp3s0f1/carrier
   0 이 된다   -> 그 케이블이 정말 저장소 서버로 간다. 문제는 상대 인터페이스 설정이다 (B)
   1 그대로다  -> ★ 우리 f1 은 저장소 서버가 아니라 다른 것(스위치)에 꽂혀 있다 (A)
```

**저장소 서버에서 확인할 것 (순서대로)**

```bash
ip -br addr                          # 10.0.0.10 이 어느 인터페이스에 있나. 아예 없나
ip -br link                          # 10G 포트가 UP 인가
ethtool <10g> | grep -E 'Speed|Link detected'
ip route get 10.0.0.11               # ★ 핵심. 10G 포트로 나가는가?
                                     #   다른 인터페이스로 나가면 '핑이 된다'는 것은
                                     #   이 링크가 산다는 증거가 아니다
ping -c3 10.0.0.11 ; ip neigh show | grep 10.0.0.11
ethtool -S <10g> | grep -E 'tx_unicast|tx_broadcast|rx_unicast'
nmcli con show                       # 재부팅 뒤 프로파일이 autoconnect 로 올라왔나
```

**막혀 있는 것** — postrun(`production/LOG` 가 `/scratch/DAQ_LOG` 심볼릭 링크다) ·
dataflow 3단계 · monitor. 경희대 백업(2단계)은 공인망이라 **영향 없이 돈다.**
수집도 `/Data_ssd` 라 무관하다. `/Data_ssd` 여유 3.1T + `/data` 30T 이므로
**며칠은 버틴다.** 급하지 않다.

**★ fstab 에서 `nofail` 이 사라졌다.** §11.116 에서 넣어 둔 것이 되돌아가 있다.

```
지금    10.0.0.10:/data  /scratch  nfs  defaults 0 0
있어야  10.0.0.10:/data  /scratch  nfs  defaults,nofail,x-systemd.mount-timeout=30 0 0
```

서버가 안 잡히는 지금 이대로 재부팅하면 **부팅이 NFS 를 기다리며 늘어진다.**

**★ 해결됐다 — 원인이 둘이었고 30분 간격으로 하나씩 풀렸다.**

```
05:33:26   ping 응답 시작.  ssh store 성공 (nfs-server / ens6f1 UP 10.0.0.10/24 / /data 140T)
           그때까지 상대 인터페이스에 IPv4 가 붙어 있지 않았다
05:41 경   방화벽 존을 public -> trusted 로 바꾸자 NFS 가 열렸다
           그 전  111 · 892 · 20048 REJECT / 2049 만 OPEN
           그 뒤  showmount -e -> '/data *'   rpcinfo -> v3 · v4 ready
05:41      mount 성공.  nfs4 vers=4.2 rsize/wsize 1M · 140T · 86%
```

**★ 서버 프로파일 이름은 `ens6f1`(파일도 `ens6f1.nmconnection`)이고, 주소·게이트웨이·
`never-default` 는 처음부터 옳았다. 틀린 것은 `connection.zone` 이 비어 있던 것 하나뿐이다** —
비어 있으면 firewalld 가 기본 존(`public`)에 넣고, `public` 은 rpcbind(111)·mountd(892)를
막는다. NFSv4 는 2049 만 쓰므로 그때도 마운트 자체는 가능했다.

```bash
# 링크를 끊지 않는 순서 (con up 은 인터페이스를 내렸다 올려 ssh 가 끊긴다)
sudo firewall-cmd --permanent --zone=trusted --change-interface=ens6f1
sudo firewall-cmd --reload
sudo nmcli con mod ens6f1 connection.zone trusted      # 재활성화 뒤에도 유지
```

**★ 진단에서 값어치가 컸던 것 — 카운터를 종류별로 본 것.**

```
rx_unicast 0 · rx_broadcast 0        -> 상대의 ARP·ICMP 가 한 장도 안 온다 (IPv4 없음)
rx_broadcast 만 15초에 1장씩          -> 상대 인터페이스는 살아 있으나 주소를 못 찾는 중
rx_unicast 가 갑자기 +23             -> 그 순간 상대가 올라왔다
```

`ping` 만 보면 셋이 전부 "안 된다" 로 같아 보인다. **`ethtool -S` 의 종류별 카운터가
'상대가 죽었나 / 주소가 없나 / 방화벽인가' 를 갈라 준다.**

**★ 그리고 내 기록 스크립트에 버그가 있어 한 번 잘못 보고했다.** `PU=0` 으로 초기화한
뒤 `[ "$PU" = 0 ] && PU=$U` 로 첫 표본을 잡게 했는데, `rx_unicast` 가 계속 0 이라
**매 주기마다 기준선이 다시 잡혀** 변화가 영원히 안 잡혔다. 실제로는 브로드캐스트가
7분에 47장 오고 있었다. **0 이 정상값일 수 있는 변수를 '초기화 안 됨' 표시로 쓰지 말 것.**

#### 11.135 ★★ dataflow 가 마운트를 확인하지 않았다 — 루트를 채울 뻔했다

수집을 재개하고 pane 을 훑다가 잡았다. **`/scratch` 가 빠진 채로 3단계가 돌면
루트 파일시스템을 채운다.**

```
/scratch    마운트 아님. 루트(/) 위의 빈 디렉터리, 퍼미션 0777, 여유 137 G
stage3()    move_dir "$src" "$NFS/RAW/$rp"   <- 마운트 검사가 한 줄도 없다
런 하나     약 330 GB
keep_mid=0  이라 백업이 끝난 런은 곧바로 3단계 대상이 된다
```

rsync 는 그 자리가 원래 NFS 였다는 것을 알 방법이 없다. 그대로 두면 4316 의 백업이
끝나는 순간(약 4시간 뒤) 330 GB 를 루트로 쏟아붓고, **루트가 차면 DAQ 만이 아니라
시스템 전체가 멎는다.** 데이터가 사라지지는 않지만(§8 대로 대조 뒤에 지운다) 복구가
훨씬 비싼 사고다.

**고침 — `dest_mounted()` 를 만들고 1·3단계 첫 줄에서 검사한다.**

```bash
dest_mounted() {                     # $1 = 확인할 경로
   [ "${DATAFLOW_ALLOW_UNMOUNTED:-0}" = "1" ] && return 0
   mountpoint -q "$1" 2>/dev/null
}
```

1단계(`/Data_ssd -> /data`)에도 같이 넣었다. `/data` 가 빠지면 같은 사고가 난다.
목적지가 마운트가 아닌 구성을 일부러 쓸 일이 있으면 `DATAFLOW_ALLOW_UNMOUNTED=1`.

**검증**

```
/scratch -> 건너뜀   /data -> 진행   /Data_ssd -> 진행   override=1 -> 강제 진행
재기동 뒤 실제 동작 : [1] run 004317 : /Data_ssd -> /data  (7201 파일 / 약 331G) 로 정상 진행
```

**★ 갈아끼우는 순서에서 배운 것.** 돌고 있었으므로 §11.42 대로 임시 파일 + `mv` 로
바꿨는데, **그것만으로는 부족하다** — 돌던 인스턴스는 옛 inode 를 붙들고 있어
그대로 두면 몇 시간 뒤 가드 없는 3단계를 돈다(§11.70 에서 이틀을 그렇게 보냈다).
그래서 그 자리에서 재기동했다.

```
1  dataflow 셸 PID 에만 kill -TERM        trap 이 exit 130 이라 자식이 끝나면 빠진다
2  그런데 안 빠진다                        stage2 의 rsync 가 몇 시간짜리라 bash 가
                                           포그라운드 자식을 기다리는 중이다
3  backup-khu 와 그 rsync 에도 TERM        그제서야 셋 다 정상 종료
4  마커 확인                               .backup_done 이 안 생겼다 = 완료로 오인하지 않는다
                                           부분 전송은 원격의 .rsync-partial 에 남는다
5  pane 에서 재기동
```

**★ `--partial-dir` 의 부분 파일은 로컬이 아니라 받는 쪽에 생긴다.** 로컬에
`.rsync-partial` 이 없다고 진행이 날아간 것으로 읽지 말 것.

#### 11.136 run 4318 복구 — 그리고 `runcheck --fix` 가 다음 서브런의 carry 를 끊는다

```
전  FADC 147 / SADC 147 / Merged 145 / PRD 145 / badrun 2 (서브런 00147 격리됨)
후  FADC 147 / SADC 147 / Merged 147 / PRD 147            ★ 완결
```

**sub 00145** 는 `scripts/runcheck.sh --run 4318 --fix` 가 그대로 복구했다(carry 있음).

**★ 그런데 그 다음 서브런이 막혔다.** `--fix` 는 껍데기를 건너뛰고 매크로를 직접
부르므로(§11.52 이래의 우회법) **껍데기가 쓰는 merge 로그가 안 남는다.** 그 로그가
바로 다음 서브런의 carry 원천이라, 145 를 고치자마자 146 이 `carry=no` 로 손댈 수
없게 됐다. **도구가 자기 다음 걸음을 막은 셈이다.**

우회는 간단하다 — **145 의 merge 를 한 번 더 돌려 출력에서 carry 를 읽는다.** 매크로는
결정적이라(§11.64) 산출물이 같다.

```
final SADC = 146 · final SADC_evt = 840 · final before_SADC_trgnum = 8960399
```

**★ 더 중요한 발견 — 격리된 파일이 '앞 서브런의 merge' 에는 쓸 수 있다.**

sub 00146 은 자기 원본은 멀쩡한데 **다음 SADC(00147)가 격리돼 있어** merge 를 못 하는
`blocked` 상태였다(§5.9). 그 SADC 를 **복사해서**(원본은 badrun 에 그대로) 되돌리고
merge 를 돌렸더니 —

```
rc=0 · Total merged events = 59256 · final SADC = 147 · 81.4 MB (정상 크기)
AbsEvent 항목 59,256 · 이어서 PRD 76.4 MB 정상 생성
```

**부분 Merged 가 아니라 완전한 merge 였다.** `badrun.sh` 의 판정("ROOT 로 안 열린다")은
**그 서브런 자신의 산출물을 만들 수 있느냐**의 이야기이고, **앞 서브런이 필요로 하는
앞부분은 멀쩡히 읽힌다.** 잘림은 언제나 파일 끝에서 일어나기 때문이다.

**규칙 — `blocked` 서브런은 이렇게 살린다.**

```
1  격리된 다음 SADC 를 cp 로 되돌린다   (mv 가 아니다. badrun 원본을 남긴다)
2  앞 서브런의 merge 로그에서 carry 를 읽는다. 없으면 그 merge 를 다시 돌려 뽑는다
3  merge -> production
4  임시 복사본을 지운다                  badrun/ 은 손대지 않는다
5  runcheck 로 개수 대조
```

이로써 `is_processed()` 가 통과해 **run 4318 이 자동 이동 대상이 됐다.** `badrun/` 은
그대로 두었으므로 문제가 있었다는 사실은 목록에 영구히 남는다(§5.9).
`badrun.sh --scan --run 4318 --update-list` 로 목록도 병합 갱신했다(625 런).

#### 11.137 ★ 10G 링크 실측 — §11.117 이 비워 둔 자리를 채운다

`/scratch` 가 돌아온 김에, **후처리·이동이 실제로 도는 중에** 쟀다.

| 측정 | 옛 100 Mb | 지금 10G | 배수 |
|---|---|---|---|
| `/scratch` 읽기 | — | **508 MB/s** | — |
| `/scratch` 쓰기 (버퍼드 8M, fsync) | 7.7 MB/s | **504 MB/s** | **65** |
| RTT | 10.6 ms | **0.29 ms** | 37 |

§11.115 의 유휴 시 값(읽기 838 · 쓰기 534)보다 읽기가 낮은 것은 **postrun 3잡과
dataflow 가 동시에 돌고 있어서**다. 부하 중에도 500 MB/s 대를 유지한다.

**§11.117 의 표에서 산술로만 적어 둔 것들이 이제 실측으로 뒷받침된다** — 3단계
런당 12시간이라는 옛 전제는 무효이고, `--drop-merged` 를 켤 이유도 없다.
다만 **3단계가 끝까지 도는 것은 아직 못 봤다**(그때 `/data` 에 대상이 없었다).

#### 11.138 ★★ 감시자 밖의 그물 — `scripts/chainwatch.sh` (사용자 요청 C-8 · C-9)

같은 날 두 번, **고장 자체보다 '아무도 모른 채 지나간 시간'이 더 비쌌다.**

```
① /scratch 가 빠지자 postrun 이 죽었다.  알림 0.  사람이 pane 을 볼 때까지 몰랐다
     수집은 /Data_ssd 라 멀쩡했고 heartbeat 도 정상이라 감시자는 조용했다
② PMT HV 가 내려가 계수가 0 이 됐다.     알림 0.  rcterm 은 '정상 실행 중' 이다
     감시자의 stall 검사는 재시작만 되풀이해 런 번호만 태웠다 (4319 · 4320)
```

**감시자가 보는 것은 '수집이 도는가' 뿐이다.** 그 바깥을 보는 그물을 따로 놓았다.

```
chain_down   /scratch 마운트 · postrun · dataflow 중 하나가 없다
rate_low     수집은 도는데 ADC 별 계수율 최솟값이 문턱(기본 400 Hz) 아래다
```

**설계에서 신경 쓴 것 — 되돌리기 전에 읽을 것**

- **운용 중일 때만 본다.** tmux 세션 `daq` 도 없고 감시자도 없으면 사람이 일부러
  세운 것이다. **정비하는 사람에게 알람을 울리는 감시는 곧 꺼지게 된다.**
  세워 둔 동안에는 연속 카운터도 0 으로 되돌려, 다음 기동 때 곧바로 메일이
  나가는 일이 없게 했다.
- **합·평균이 아니라 ADC 별 최솟값.** 한 보드만 죽으면 합은 멀쩡해 보인다
  (§11.56 에서 `usb-recover.sh` 가 같은 이유로 같은 방식을 쓴다).
- **연속 2회여야 알리고, 이어지는 동안은 1시간에 한 번만.** 5분마다 같은 메일이
  오면 사람이 필터를 만든다. 그러면 감시가 없는 것과 같아진다.
- **warmup 180초.** 런이 막 뜨면 계수율이 정상적으로 0 이다. 로테이션마다
  거짓 경보를 내면 역시 무시당한다.
- **죽지 않는다.** heartbeat 가 없어도, 상태 파일을 못 써도 종료코드 0 이다.
  감시가 스스로 넘어지면 없느니만 못하다 (`daq-notify.sh` 와 같은 원칙).
- **`pgrep -f` 를 그대로 쓰지 않는다.** 저장소 경로에 `rcterm` 이 들어 있어
  자기 셸과 조상까지 잡힌다 (§11.67 · §11.119). 조상을 빼고 센다.
- **★ CLI 옵션이 params 파일보다 우선한다.** `usb-recover.sh` 는 반대 순서인데,
  거기서는 `--min-rate` 를 손으로 주고 시험하는 일이 잦아 **친 대로 동작하는**
  쪽을 택했다. 이 차이를 스크립트 머리 주석에 적어 두었다.

**메일 본문에 진단을 담았다.** 새벽에 받은 사람이 본문만 보고 움직일 수 있어야
한다. `rate_low` 본문은 **"보드보다 HV 를 먼저 의심하라"로 시작한다** — 오늘
그 순서를 거꾸로 밟아 30분을 헛되이 썼기 때문이다.

**검증 16종 — 하드웨어·실데이터·실메일을 전혀 건드리지 않았다.**

| 시험 | 결과 |
|---|---|
| `--status` (실 시스템) | 마운트·postrun·dataflow·계수율·카운터를 한 화면에 ✅ |
| gate off | 조용히 물러나고 카운터를 0 으로 ✅ |
| 정상 상태 | 알림 없음, 카운터 0 ✅ |
| chain_down 1회차 / 2회차 | 연속 1 은 침묵, 2 에서 알림 ✅ |
| 재알림 억제 | 즉시 3회차는 '알림 생략' ✅ |
| 해소 | '해소됨' 을 남기고 카운터 0 ✅ |
| rate_low (FADC 5 / SADC 980) | **최솟값 5.0 Hz 로 잡는다** — 합·평균이면 놓쳤다 ✅ |
| 정상 계수율 (1000/1000) | 조용 ✅ |
| warmup (daqtime 10) | 판정하지 않음 ✅ |
| heartbeat 오래됨 / phase=ending / 파일 없음 | 셋 다 판정하지 않고 exit 0 ✅ |
| params vs CLI 우선순위 | CLI 가 이긴다 ✅ |
| **cron 환경 (`env -i`)** | 정상. **환경변수가 없어 죽는 것이 cron 의 고전적 함정이다** ✅ |
| `daq-notify` 새 사건 2종 | ON 맵·파서·본문 안내까지 ✅ |

**§8 대로 별도 클론(`~/DAQ/work-c89`)에서 작업했다.** 운영 디렉터리는 run 4321 이
그 바이너리로 돌고 있으므로 `git pull` 만 한다.

**★ 배포할 때 하나 주의.** `daq-notify.sh` 는 감시자가 사건마다 부르는 파일이다.
`git pull` 이 그 자리를 덮어쓰므로, 사건이 나는 순간과 겹치면 §11.42 의 그
문제가 난다. 창이 아주 좁지만, **알람이 울리고 있지 않을 때 당길 것.**

#### 11.139 ★★ 4200번대 재처리 — 막고 있던 것은 데이터가 아니라 `DLY_THR` 로그였다

사용자 지시로 **4200 ~ 현재 구간을 전수 조사**했다 (읽기 전용, 원격 목록은 ssh 1회).

```
런 122 개   OK 59 · 후처리 결손 21 · 로컬에 없음 42
```

**후처리가 덜 된 실제 물리 런(onlbit=1)은 10 개이고, 그중 8 개가 경희대에 사본이 없다.**

| 런 | 시간 | FADC | PRD | 결손 | 경희대 백업 |
|---|---|---|---|---|---|
| 4219 | 105.9 h | 6,355 | 320 | 6,035 | RAW 6,355 **완료** |
| 4224 | 23.6 h | 1,416 | 1,225 | 191 | ★ 없다 |
| 4240 | 190.6 h | 11,437 | 9,206 | 2,231 | ★ 없다 |
| 4241 | 13.4 h | 804 | 0 | 804 | ★ 없다 |
| 4242 | 26.4 h | 1,586 | 0 | 1,586 | ★ 없다 |
| 4243 | 29.7 h | 1,782 | 0 | 1,782 | ★ 없다 |
| 4244 | 259.8 h | 15,589 | 0 | 15,589 | ★ 없다 |
| 4245 | 133.6 h | 8,017 | 0 | 8,017 | ★ 없다 |
| 4246 | 85.1 h | 5,104 | 0 | 5,104 | 부분 2,456 / 5,104 |
| 4280 | 1.1 h | 65 | 0 | 65 | ★ 없다 |

나머지 11 개(4233 4235 4236 4271 4273 4274 4276 4277 4279 4281 …)는 `onlbit=0` 이고
서브런이 1~19 개뿐인 시험·부팅실패 런이다.

**원시 파일은 10 개 런 전부 `FADC == SADC` 로 온전하다.** merge 를 막을 것이 없다.

#### ★ 그런데 재처리를 걸자마자 전부 `Producing FAILED (2초)` 로 쏟아졌다

merge 는 멀쩡히 되는데 production 만 2초 만에 죽는다. **§11.52 의 '0초 실패' 와
비슷해 보이지만 원인이 다르다.**

```
production_from_merged_v3_5v.cc(4280,0,...)
   terminate called after throwing an instance of 'std::out_of_range'
     what():  vector::_M_range_check: __n (which is 0) >= this->size() (which is 0)
```

`PRD/Run<런>_DLY_THR.log` 이 **없거나 비어 있었다.** production 매크로가 이것을 읽어
채널별 DLY/THR 벡터를 만드는데, 비면 첫 접근에서 그대로 죽는다.

```
4219 · 4224 · 4240   10 줄 정상   <- 이 셋만 PRD 가 일부라도 있는 이유다
4241 ~ 4246          ★ 파일 자체가 없다
4280                 ★ 있는데 0 줄
```

**왜 안 만들어졌나 — postrun 이 옛 자리만 보고 있었다.**

```bash
# scripts/postrun.sh (고치기 전)
local tcblog="$RAWROOT/../LOG/TCB_${rp}.log"     # = /scratch/LOG/TCB_<런>.log
```

**§11.103 에서 DAQ 로그를 `/scratch/DAQ_LOG/RAW_log/` 로 옮긴 뒤 그 자리에는
아무것도 없다.** 그래서 조건이 조용히 거짓이 되고, 아무 말 없이 넘어간 뒤
production 이 런 전체에 걸쳐 죽는다. `runcheck.sh` 의 `ensure_dly_thr` 도 같은
옛 경로를 보고 있었다.

**고침 — `find_tcblog()` 를 두 스크립트에 넣어 다섯 자리를 본다.**

```
<로그루트>/RAW_log/  ->  <로그루트>/RAW_log.old<최신부터>  ->  <로그루트> 평면
   ->  <RAW루트>/../LOG (옛 자리)  ->  /Data_ssd/LOG (수집 중인 런)
```

못 찾으면 **조용히 넘어가지 않고 무엇을 어디서 찾았는지 찍는다.** 이번에 원인을
찾는 데 시간이 걸린 이유가 바로 그 침묵이었다.

**재생 방법이 정확하다는 것을 먼저 확인했다** — `grep WJ <TCB로그>` 가 정상본
3 개(4219 · 4224 · 4240)와 **바이트 단위로 일치**한다. 그 뒤에 빠진 7 개를 만들었고,
run 4280 서브런 0 이 78 MB PRD 로 정상 생성되는 것을 보고 재개했다.

#### ★ 시험이 잡은 bash 함정 — `local a=$1 b="${a}"` 는 b 가 빈다

고친 `find_tcblog` 를 실제 런으로 시험하니 **전부 '못 찾음'** 이 나왔다. 코드가
아니라 한 줄의 문법이었다.

```bash
f() { local rp=$1 base="TCB_${rp}.log"; ... }   ->  base = 'TCB_.log'     ★
g() { local rp=$1; local base="TCB_${rp}.log"; } ->  base = 'TCB_004241.log'
```

**bash 는 `local` 의 낱말을 대입 전에 전부 전개한다.** `${rp}` 는 아직 비어 있다.
시험을 안 했으면 '고쳤다' 고 적어 두고 다음에 똑같이 막혔을 것이다.

#### 돌고 있는 것 (둘 다 재개 가능하고, 수집을 방해하지 않는다)

```
/Data_ssd/LOG/backup-priority.sh     경희대 백업. 백업 없는 런 우선, 작은 것부터
                                     RAW 만 보낸다 (PRD 는 RAW 에서 다시 만든다, §11.14)
                                     마커가 남으므로 끊겨도 이어진다
/Data_ssd/LOG/reprocess-priority.sh  재처리. 같은 순서. --from 0 으로 준다
                                     이미 있는 서브런은 postrun 이 stat 으로 건너뛰고,
                                     서브런 0 은 carry 가 (0,0,0) 이라 §11.68 위험이 없다
                                     nice 15 / ionice -c2 -n7 / --jobs 2
```

**실측 속도 — 서브런당 6~7초.** §11.108 의 13~20초보다 2~3배 빠르다. 그때는
`/scratch` 가 100 Mb 였고 지금은 10 G 다(§11.137). 결손 41,404 서브런 기준
**약 3일**, 산출물 약 6.5 TB (`/scratch` 여유 20 TB).

**★ `git pull` 은 돌고 있는 스크립트에 안전하다 — 실측했다.** git 은 파일을 제자리에
덮어쓰지 않고 **새 inode 로 만든다**(checkout 전후 inode가 달라지는 것을 확인).
그래서 돌던 bash 는 옛 inode 를 그대로 붙들고 §11.42 의 사고가 나지 않는다.
다만 **다음 실행부터** 새 코드가 적용되므로, 지금 도는 작업에는 반영되지 않는다.

#### 11.142 ★★ 여기서 이어받는다 — 2026-09-03 01:00 기준

**세션을 새로 열면 §0.0 다음에 이 절만 읽으면 된다.**

**돌고 있는 것 (건드리지 말 것)**

```
수집       run 4322 · tmux 세션 'daq'                        tmux attach -t daq
후처리     postrun --follow --jobs 3 --lag 3 (run 4322 를 따라간다)
이동       dataflow --follow  (마운트 가드 있음, §11.135)
재처리     /Data_ssd/LOG/reprocess-priority.sh   지금 run 4245 (--from 0 --to 8016)
경희대백업 /Data_ssd/LOG/backup-priority.sh      지금 run 4240 RAW 22,874 개
감시       chainwatch cron 5분 · sheetlog cron 매시 07분
           ★ mailq-send cron 5분 (새로 넣었다, §11.144)
저장소서버 ★ 외장하드 백업이 돌고 있다 (2026-09-03 02:16 시작, pid 77524/77526)
             run 002443 을 8,699 개(1.70 TB)로 잘라 /backup_hdd 에 담는 중. 50 MB/s
             약 10시간 뒤 하드가 차면 메일이 오고 /backup_hdd_2 로 저절로 이어진다
             ssh 와 무관하게 산다 (부모가 init 이다. 실측 확인)
             진행 : ssh store 'tail -c 300 ~/sykim/backup_log/code9.log | tr "\r" "\n" | tail -1' 
```

**상태 보는 법 — 전부 읽기 전용**

```bash
cat /Data/LOG/rcterm.hb                 # 수집
scripts/chainwatch.sh --status          # 후처리 사슬 · 계수율
scripts/runcheck.sh --last 2            # 끝난 런 대조
scripts/mailq-send.sh --status          # 스토리지 백업 메일 큐
tail -2 /Data_ssd/LOG/reprocess-priority.log
tail -2 /Data_ssd/LOG/backup-priority.log
ssh store 'ps -eo pid,lstart,args | grep -E "data_backup|storage-backup" | grep -v grep'
```

**진행 중인 큰 작업 둘**

`4200번대 PRD 결손 재처리 + 경희대 백업` — 백업이 없는 런을 우선으로 돌린다
(§11.139). 둘 다 재개 가능하고 nice/ionice 로 양보한다.

```
완결   4280 · 4241 · 4224 · 4242 · 4243 · 4246
진행   재처리 4245 · 백업 4240
남음   4240(2231) · 4244(15589) · 4219(6035)
불가   4138:00009 — 원본이 손상됐다 (§11.107)
```

**★ 외장하드 백업이 돌고 있다 — 다음에 볼 것은 첫 하드 교체다**

2026-09-03 02:16 에 시작했다. 권한은 사용자가 조치했다 — 마운트 루트는 root 로
두고 **`RENE_data_backup` 만 만들어 소유권을 넘기는 형태**다(§11.148).

```
지금        run 002443 을 8,699 개(1.70 TB)로 잘라 /backup_hdd 에 담는 중, 50 MB/s
약 10시간 뒤  하드가 차면 메일 -> /backup_hdd_2 로 저절로 이어진다
확인        ssh store 'tail -c 300 ~/sykim/backup_log/code9.log | tr "\r" "\n" | tail -1'
            ssh store 'df -h /backup_hdd /backup_hdd_2'
```

**★ 하드가 실제로 차서 넘어가는 순간은 아직 아무도 못 봤다.** 그것이 이 변경의
핵심이므로 첫 교체 메일이 오면 로그를 확인할 것. 원본은 **한 런의 전송과 대조가
다 끝난 뒤에만** 지우므로, 그때까지 `/data/RAW/002443` 은 그대로 있다.

**사람이 해야 하는 것** (전부 root 가 필요해 이 세션에서 못 했다)

| 무엇 | 왜 | 어디에 |
|---|---|---|
| NM 프로파일 주소를 `.71` 로 되돌린다 | **재부팅하면 `.75` 로 떠서 공인망이 끊긴다** | §11.132 |
| fstab 에 `nofail` 복원 | 저장소가 늦게 뜨면 부팅이 멎는다 | §11.133 |
| `enp0s31f6`·`enp1s0` 프로파일의 `.71` 정리 | 셋이 같은 주소를 갖고 있다 | §11.132 |
| `/backup_hdd*` 두 개를 fstab 에 UUID 로 | 지금은 손으로 마운트라 rename 에 무방비 | §11.124 |

**★ 이어받을 때 밟기 쉬운 것**

```
1  ★ 저장소 서버에서 무언가 띄우기 전에 이미 도는 것부터 볼 것 (§11.141)
     /data/RAW 는 우리 /scratch/RAW 와 같은 곳이다. 아카이브가 원본을 지운다
2  pgrep -f 로 프로세스를 찾지 말 것. 세 방향으로 오탐한다 —
     저장소 경로에 'rcterm' 이 들어 있고, $( ) 서브셸이 잡히고,
     ★ 나를 띄운 셸의 argv 까지 잡힌다. pgrep -x 를 쓰거나 계보를 빼라
     (§11.67 · §11.119 · §11.141 · §11.145)
3  운영 디렉터리에서 소스를 고치지 말 것. 별도 클론에서 고치고 git pull (§8)
     git 은 새 inode 로 만들어 돌고 있는 스크립트에 안전하다 (실측, §11.139)
4  0 Hz 이면 보드를 파기 전에 HV 부터 물을 것 (§11.131)
5  bash `local a=$1 b="${a}"` 는 b 가 빈다. 나눠 쓸 것 (§11.139)
6  du -sb 로 두 파일시스템을 대조하지 말 것 — 디렉터리 크기가 다르다 (§11.140)
7  ★ cron 이 도는 메일 큐(/scratch/MAILQ)에 '보내지 않을 파일' 을 두지 말 것.
     넣는 순간 그것은 보낼 메일이다 (§11.146 에서 한 통 잘못 나갔다)
```

### 2026-08-28 — `/backup_hdd` 를 되살리고, 시트 등재를 자동화했다

#### 11.124 ★★ `/backup_hdd` 재발 — 이번엔 이름이 바뀌는 순간을 실측으로 잡았다

§11.123 이 "끊겼기 때문에 이름이 바뀐다"고 적어 둔 그 인과를, 이번에는 **고장 난
상태 그대로** 확인했다. 08-27 저녁 전송이 79% 에서 죽고 그 뒤 2,000개가 연속 EIO.

```
findmnt /backup_hdd   ->  /dev/sdb1   ext4 rw        <- 마운트는 sdb1 을 가리킨다
ls /dev/sd*           ->  sda sda1 sdc sdc1          <- ★ sdb1 이 없다
lsblk                 ->  sdc 1.8T ST2000DM008-2FR102 ZK2060HX  usb
ls /backup_hdd        ->  Input/output error         <- 읽기조차 안 된다
```

**마운트가 유령이 된 것이다.** 디스크가 버스에서 떨어졌다 `sdc` 로 다시 붙었는데
마운트는 사라진 `sdb1` 을 계속 붙들고 있어, 모든 접근이 EIO 가 된다. rsync 가
마지막에 `mkdir PRD` 까지 실패한 것도 전부 이것 하나 때문이다.

**★ 이때 `df` 값을 믿지 말 것.** 죽은 장치의 캐시된 수치를 보여 준다. 이번에는
`266G 사용 / 1.5T 여유` 라고 나왔는데, 마운트를 다시 하니 252G 였다.

**★ 확정된 대처는 여전히 속도 제한 하나뿐이다.**

| 날짜 | 속도 | 결과 |
|---|---|---|
| 08-26 | `--bwlimit=30M` | **31분 52초 무사** |
| 08-27 | 제한 없음 (78.97 MB/s) | 79% 에서 재발 |
| 08-28 | `--bwlimit=50M` | 진행 중. **50M 이 안전한지는 아직 모른다** |

**고칠 것 셋 — 이번에 둘만 했다.**

```
① 마운트를 UUID 로            ✅ 했다.  mount -t ext4 UUID=26f4448e-... /backup_hdd
② fstab 에 등록               ❌ 아직.  /etc/fstab 에 이 디스크 항목이 아예 없다.
                                 손으로 device name 마운트라 rename 에 무방비다
      UUID=26f4448e-dfbb-43ed-ba95-0b2df8f3445f /backup_hdd ext4 defaults,nofail,x-systemd.device-timeout=10 0 2
③ e2fsck                      ❌ 아직.  umount 뒤 바로 마운트했다.
                                 저널이 끊긴 뒤라 전체 검사가 필요하다. 다음 정비 때
```

**★ UUID 가 §11.123 의 기록과 다르다.** 그때 적은 것은
`ad07fc77-ca3d-4763-afcb-8ee541213a34` 인데 지금 `sdc1` 은
`26f4448e-dfbb-43ed-ba95-0b2df8f3445f` 다. 그 사이에 포맷했거나 그때 기록이
틀렸거나 둘 중 하나인데, **마운트가 안 되는 상태에서 확인할 수 없어 확정하지
못했다.** 추측으로 적지 않는다.

**★ 로그 폭주가 증거를 지웠다 — 다음에 밟기 쉬운 함정.**

```
dmesg 전체 8,236 줄  =  전부 같은 EXT4 warning 한 줄 (dx_probe ... error -5)
가장 오래된 항목이 17:59:39   ->  실제 USB 끊김 순간은 링버퍼 밖으로 밀려났다
```

원인 자체는 §11.123 에서 확정했으니 이번엔 지장이 없었지만, **다음엔 그 순간을
못 볼 수 있다.** 이 디스크에 큰 전송을 걸 때는 같이 띄워 둘 것 :

```bash
dmesg -w > /tmp/dmesg-watch.log &
```

#### 11.125 ★★ 구글시트 등재가 8월 24일에 멈춘 이유 — 자동화가 아예 없었다

사용자 지적 : "DAQ 파이프라인 후반부의 시트 작성이 8/24 이후로 안 되고 있다."
**파이프라인의 문제가 아니었다.**

```
crontab -l                    ->  no crontab for frontend
systemd timer                 ->  tmpfiles-clean, grub-boot-success 둘뿐
append_runs.py 를 부르는 코드  ->  저장소 전체에 0 곳
                                  (유일한 언급은 발표자료 생성기 안의 설명 문자열)
```

`postrun` · `dataflow` · `backup-khu` · `monitor-all` 어느 것도 시트를 건드리지
않는다. **세션마다 사람이 손으로 `--commit` 을 돌리는 절차**였고, 그것이
§11.86 · §11.92 · §11.97 · §11.105 에 매번 기록돼 있다. 시트 마지막 행이
Run 4306 이고 그 Start Date 가 정확히 2026-08-24 다 — 그 등재가 마지막 작업이었고,
바로 그날 밤 10G 교체로 전체를 정지한 뒤 세션이 네트워크 → TCB 보드 → `/backup_hdd`
장애로 이어지면서 **수집은 멀쩡한데 등재만 밀렸다.**

**밀린 3개를 등재했다.** 쓰기 전에 개수를 대조해 전부 완결임을 확인했다.

```
4307   FADC 971  = SADC 971  = Merged 971  = PRD 971    16h10m  75.0 / 71.1 GB
4313   FADC 1440 = SADC 1440 = Merged 1440 = PRD 1440   23h59m  109.3 / 103.6 GB
4314   FADC 1440 = SADC 1440 = Merged 1440 = PRD 1440   23h59m  109.5 / 103.8 GB

기록 범위  A310:S312 (3행).  309 -> 312 행
검증       읽어 되대조 -> Run 311개, 중복 0, 정렬 위반 0, 312행 밑 잔여물 없음
           바로 위 309행(4306)이 그대로임을 확인
제외       4308~4312 (onlbit=0, TCB 보드 장애) · 4315 (수집 중)
Data issue 셋 다 비움 — 전부 완결이다
```

**★ 4313 은 `/data` 와 `/scratch` 양쪽에 있었다.** `/scratch` 쪽은 dataflow 가
옮기는 중이라 PRD 가 643개뿐이다. `append_runs.py` 가 `/Data_ssd:/data:/scratch`
순서로 앞을 이기게 고른 덕에(§11.47) 완결본을 썼다. **한 곳만 봤으면 틀린 용량이
들어갔을 것이다.**

#### 11.126 자동화 — `scripts/sheetlog-auto.sh` (사용자 요청)

```
규칙   밀린 런이 5개 이상이면 즉시, 아니면 24시간마다 한 번. 쓸 때마다 메일
검사   cron 이 매시 07분에 부른다. 조건이 맞을 때만 쓴다
상태   scripts/sheetlog-auto.sh --status      (읽기 전용)
로그   /Data_ssd/LOG/sheetlog-auto.log        상태 : .../sheetlog-auto.state
```

**★ 완결 게이트가 이 스크립트의 핵심이다.** 후처리가 덜 끝난 런을 쓰면 PRD 용량이
모자란 채로 박히는데, **시트는 기존 행을 고칠 수 없으므로 영영 틀린 값이 남는다.**
그래서 `FADC 개수 == PRD 개수` 인 런까지만 쓰고 그 뒤는 다음 주기로 미룬다.
`append_runs.py --limit` 으로 잘라 넘긴다. badrun 격리분은 하위 폴더라 최상위
개수에서 빠지므로(§5.9) 이 판정이 그대로 맞는다.

곁들여 `daq-notify.sh` 에 `sheetlog` 사건을 더했다(ON 맵 · params 파서 ·
`notify.params(.example)` 의 `on_sheetlog = mail`). 감시자가 이 파일을 부르고
있으므로 **§11.42 대로 임시 파일에 쓰고 rename** 했다.

**검증 — 시트도 하드웨어도 건드리지 않고 전수**

가짜 `append_runs.py` 로 바꿔치기해 실제 판단 코드를 그대로 돌렸다.

| 시험 | 결과 |
|---|---|
| 6개 밀림 · 전부 완결 · 0시간 | 문턱으로 즉시 등재 (6런) ✅ |
| 2개 밀림 · 전부 완결 · 0시간 | 대기 ✅ |
| 2개 밀림 · 전부 완결 · 30시간 | 일일 등재 (2런) ✅ |
| 6개 밀림 · 2번째가 미완 · 0시간 | 대기 (완결 1개뿐) ✅ |
| 4개 완결 뒤 미완 · 30시간 | **4런만 등재, 4315 부터 미룸** ✅ |
| 완결 게이트 6런 | 4307·4313·4314 통과 / 4315(수집 중)·4308(부팅 실패)·없는 런 차단 ✅ |
| 알림 호출 | 사유 · 등재 런 · 미룬 것 · 기록 범위가 본문에 담긴다 ✅ |
| **cron 환경 (`env -i`)** | 정상. **환경변수가 없어 죽는 것이 cron 의 고전적 함정이다** ✅ |

**★ 상태 파일을 심어 두었다.** 손으로 등재한 시각을 `last_commit` 으로 넣지
않으면 첫 cron 이 "24시간 경과"로 읽고 곧바로 또 쓴다.

#### 11.128 메일 수신자 — 전문가 목록을 6 -> 11 명으로 (사용자 요청, 2026-08-29)

사용자가 8개 주소를 주며 "목록에 없으면 추가"를 요청했다. **그중 3개는 이미
전문가 목록에 있었다**(`cheong112358` · `opercjy` · `gs1706`) — 이 겹침이 어느
목록을 뜻하는지 알려 주는 단서였고, 확인 뒤 전문가 쪽에만 넣었다.

```
새로 넣은 5개  phortion@naver.com · sunkyu131@chonnam.ac.kr · byang@chonnam.ac.kr
               lwj1852@snu.ac.kr · jsjang@gist.ac.kr
```

**★ 어느 목록이냐가 결과를 크게 가른다.** 두 목록은 독립이다.

```
mail_to        (책임자 1명)  restart · stale · recovered · backup_audit · sheetlog
                             -> 일상. 하루 여러 통 간다
mail_to_expert (전문가 11명) recovery_failed · fatal
                             -> 사람이 현장에 가야 할 때만
```

전문가에 넣었으므로 **평소에는 이 11명에게 메일이 가지 않는다.** 일상 알림까지
받게 하려면 `mail_to` 에도 넣어야 하는데, 그건 하루 여러 통이라 별개의 판단이다.

**시험 발송은 하지 않았다.** 남의 메일함으로 실제로 나가는 것이라, 확인은
`send_mail.py --dry-run` 으로 했다(수신자 11명 전원 정확히 해석됨). SMTP 경로
자체는 전날 routine 발송이 `rc=0` 으로 성공해 이미 살아 있음이 확인돼 있고,
전문가 경로는 수신자 목록만 다르고 같은 코드를 탄다.

`config/notify.params` 는 자격증명이 들어 있어 `.gitignore` 대상이다 — **이 변경은
저장소에 남지 않는다.** 새 PC 에서는 §0.0 대로 직접 채워야 한다. 바꾸기 전
사본을 `config/notify.params.bak-<날짜시각>` 으로 남겼다.

### 2026-08-26 — 10G 링크 개통. 그리고 TCB 보드는 전원 재투입으로만 풀렸다

#### 11.115 ★★ 스토리지 링크를 100 Mb 에서 10 Gb 로 — 실측 69~109 배

§11.114 가 "올린 뒤 다시 실측해 문서를 갱신하라"고 지목한 그 작업이다.

```
새 카드   Intel X710-2 for 10GbE SFP+ (i40e), 03:00.0/03:00.1
          enp3s0f1  DAC 직결, 10 Gbps Full, 오류 0        <- 이것만 쓴다
          enp3s0f0  케이블 없음
옛 카드   enp1s0 는 건드리지 않았다. 케이블만 빠졌다
```

**★ 옛 `enp1s0` 은 사실 10G 카드였다.** Aquantia AQC113CS(10GBase-T)인데 100 Mb
로 협상되고 있었다. §11.12 가 "속도 협상/배선 문제"로 의심한 것이 맞았다.

**설정 — 이 PC 쪽은 이것이 전부다.**

```bash
nmcli connection add type ethernet ifname enp3s0f1 con-name storage10g \
      ipv4.method manual ipv4.addresses 10.0.0.11/24 \
      ipv4.never-default yes connection.zone trusted connection.autoconnect yes
nmcli connection modify enp1s0 connection.autoconnect no    # 옛 프로파일
```

- `never-default` — 기본 경로가 이리로 새면 인터넷이 사설 링크로 나간다
- `zone trusted` — 옛 `enp1s0` 이 있던 존과 같게. `public` 은 `enp0s31f6` 전용이다
- **`10.0.0.11` 을 그대로 옮겼다.** 저장소의 스크립트가 이 주소를 하드코딩한 곳이
  하나도 없음을 확인했고(문서에만 나온다), 그래서 fstab 도 코드도 고칠 게 없다

**★ 죽은 인터페이스가 경로를 가로챈다 — 진단을 두 번 헛되게 했다.**

```
10.0.0.0/24 dev enp1s0 ... metric 101 linkdown      <- 캐리어가 없는데 남아 있다
/proc/sys/net/ipv4/conf/all/ignore_routes_with_linkdown = 0
```

`0` 이면 **커널이 캐리어 없는 인터페이스로도 그냥 내보낸다.** 그래서 새 포트에
주소를 붙이고 ping 해도 죽은 `enp1s0` 으로 나갔다. 증거는 NIC 카운터였다 —
`enp3s0f1` 의 `tx_broadcast` 가 **0** 이라 ARP 가 한 번도 안 나갔고, 이웃표에는
`10.0.0.10 dev enp1s0 FAILED` 가 있었다. **옛 프로파일을 내리기 전에는 어떤
테스트도 의미가 없다.**

**★ 상대가 살아 있는지 알아내는 순서 — 이 셋이 값싸고 확실하다.**

```
1  ethtool -S <iface> 의 rx_multicast / rx_broadcast
      조용한 점대점 링크에서 tcpdump 는 몇 분을 봐도 0 이다. 카운터는 부팅 이후
      누적이라 '한 번이라도 왔는가'를 알려준다 (실측 : 8 프레임 586 바이트)
2  ping -6 ff02::1%<iface>   ->   ip -6 neigh show dev <iface>
      IPv4 주소 설정과 무관하게 이웃을 찾는다. 상대 링크로컬과 MAC 이 나온다
3  nmap -6 -Pn -sT --reason  ->  filtered(admin-prohibited) / closed(refused) 구분
      '방화벽이 막는다' 와 '데몬이 없다' 가 갈린다
```

**★ `bash` 의 `/dev/tcp` 는 스코프 붙은 IPv6 주소(`%iface`)를 못 다룬다.**
`부적절한 인수` 로 즉시 실패하는데, 그걸 '포트 닫힘'으로 읽으면 정반대 결론이
난다. 한 번 그렇게 냈다 뒤집었다. IPv6 포트 검사는 `nmap -6` 으로 할 것.

**실측 — 옛 값과 나란히**

| 측정 | 옛 100 Mb | 새 10G | 배수 |
|---|---|---|---|
| `/scratch` 읽기 | — | **838 MB/s** | — |
| `/scratch` 쓰기 (버퍼드 bs=8M) | 7.7 MB/s | **534 MB/s** | **69** |
| `/scratch` 쓰기 (버퍼드 bs=1M) | | 444 MB/s | 58 |
| `/scratch` 쓰기 (`oflag=direct`) | | 62.8 MB/s | ← 처리량이 아니다 |
| RTT | 10.6 ms | **0.31 ms** | 34 |
| (참고) 로컬 `/Data_ssd` 쓰기 | | 2.0 GB/s | |

**★ `oflag=direct` 로 NFS 쓰기를 재지 말 것.** 1 MB 마다 서버 커밋을 기다리는
**왕복 지연 측정**이라 언제나 낮게 나온다. rsync · ROOT 파일 쓰기 · dataflow 는
전부 버퍼드라 실제 값은 444~534 MB/s 다. 처음에 62.8 을 보고 "쓰기가 병목"이라고
읽을 뻔했다.

읽기 838 MB/s = 6.7 Gbps 이므로 **병목은 이제 네트워크가 아니라 서버 스토리지**다.
전송 4.4 GB 동안 `rx_errors`/`tx_errors`/`rx_dropped` 전부 0. MTU 는 1500 그대로다
(jumbo 는 아직 시도하지 않았다 — 양쪽 끝이 같아야 한다).

#### 11.116 fstab 두 가지 — 잘못된 주소, 그리고 `nofail`

작업 도중 fstab 이 **`10.0.0.11:/data`** 로 바뀌어 있었다. 그건 **이 PC 자신**이고
이 PC 의 `/etc/exports` 는 비어 있으므로(§11.100) 영원히 마운트되지 않는다.
`10.0.0.10` 으로 되돌렸다. **저장소 서버가 `.10`, 이 PC 가 `.11` 이다.**

그리고 §11.113 이 남긴 숙제를 함께 처리했다.

```
10.0.0.10:/data  /scratch  nfs  defaults,nofail,x-systemd.mount-timeout=30  0 0
```

`nofail` 이 없어서 이번 부팅에 `/scratch` 가 안 올라온 채 늘어졌다. 백업은
`/etc/fstab.bak-<날짜>`.

#### 11.117 ★ 이 수치가 뒤집는 판단들 — 다시 재야 한다

| 자리 | 옛 결론 | 왜 다시 재야 하나 |
|---|---|---|
| §11.63 | "3단계는 **대조가 전송보다 비싸다**" | 100 Mb 전제다. run 4292 348 GB 기준 전송 10h17m + 대조 28h+ 였던 것이, 산술로는 **전송 약 11분 + 대조 약 7분**이 된다 |
| §6 백로그 | "3단계가 12시간이라 `--drop-merged` 가 유일한 단축 수단" | 그 이유가 사라진다 |
| §5.8 · §11.32 | 후처리가 `/scratch` 에서 13배 느리다 (서브런당 14.58초 대 1.11초) | 링크가 100배가 됐으니 다시 재야 한다 |
| §11.5 | `find -printf` 가 `/scratch` 에서 못 쓸 만큼 느리다 | RTT 가 34배 줄었다. 여전히 `ls -lU` 가 낫겠지만 확인이 필요하다 |
| `backup-trickle` `--bwlimit` | 링크를 굶기지 않으려는 양보 | 대역 자체가 넉넉해졌다. 양보 논리는 유효하되 값은 재검토 |

**★ 위는 전부 산술이지 실측이 아니다.** 실제 dataflow 3단계가 도는 것을 보고
채워야 한다. 지금은 `/data/RAW` 가 비어 있어 볼 기회가 없다.

#### 11.118 저장소 서버에 ssh 가 뚫렸다 — 포트는 22 가 아니라 **7777**

§11.101 이 "그 서버에는 ssh 도 붙지 않는다(`No route to host`)"고 적어 둔 자리다.
**원인이 확정됐다** — `No route to host` 는 방화벽이 ICMP `admin-prohibited` 로
명시적으로 거부할 때 리눅스가 내는 말이다. 배선도 주소도 아니었다.

사용자가 서버 쪽 방화벽을 열고 계정을 만들어 접속이 됐다.

```
호스트     nfs-server   Rocky 9.6 (5.14.0-570.18.1)
/data      /dev/sda1    140 T   114 T 사용   19 T 여유      <- 단일 블록 장치
ssh        10.0.0.10 : 7777   (22 는 닫혀 있다)
별칭       ~/.ssh/config 에 `Host store nfs-server` 추가.  ssh store
키         id_rsa 를 ssh-copy-id 로 넣었다 (무암호 접속)
```

**이로써 §11.101 의 `/scratch/LOG` XFS 점검을 원격에서 할 수 있게 됐다.**
다만 `xfs_repair` 는 마운트를 풀어야 하므로(무수정 `-n` 조차 그렇다) 계획된
정비 시간이 필요하다. **114 TB 에 완전한 백업이 없다는 점**(백업 안 된 옛 런
237개, §11.61)을 먼저 저울질할 것. 급하지도 않다 — §11.103 이후 결손이 0 이다.

#### 11.119 ★★ TCB 보드 장애 — `usbreset` 으로 안 풀린다. 전원 재투입만이 답이었다

재기동하니 **5회 연속 부팅 실패**로 감시자가 포기했다. §11.49 와 같은 계열이나
이번엔 FADC 가 아니라 **TCB** 다.

```
TCB_0043xx.log
  CupGeneralTCB::Open: nkusb_open_device: super speed device opened   <- 보드는 열린다
  CupGeneralTCB::Config: module configuration start
  [ERROR] USB3TCBWrite: write error:LIBUSB_ERROR_TIMEOUT [sid=0]      x 21
  [ERROR] USB3TCBRead:  write error:LIBUSB_ERROR_TIMEOUT [sid=0]      x 22
```

`lsusb` 에는 보드 셋 다 정상 열거된다. `dmesg` 에 disconnect 도 없다.
**태운 런 번호 : 4308 ~ 4312.**

**시도한 순서와 결과 — 이 표가 이 절의 요점이다.**

| 시도 | 결과 |
|---|---|
| `src/usbreset` | **효과 없음.** USB 링크만 다시 맺는다 |
| 그 뒤 확인 런 | 증상이 *바뀌었다* — `CupGeneralTCB::Config: no module linked`. 리셋 전에는 `CheckLinkStatus: TCB[mid=0] found @ 10,13,14,15,26` 으로 모듈을 보고 있었다 |
| `src/NOTICE_CODE_RUN.sh` | **7분간 물림.** 출력 한 줄 없이 매달려 강제 종료 |
| **보드 전원 재투입** | **이것이 풀었다.** device 8·9·10 으로 완전 재열거 |
| 그 뒤 확인 런 | USB 오류 0건. 그런데 **23,527 Hz** (정상의 23배) |
| `src/NOTICE_CODE_RUN.sh` | **7초에 rc=0.** pedestal 3693~3721 정상 |
| `src/usbreset` | 마무리 |
| 확인 런 | **962.3 Hz — 정상** (run 4307 이 1015.7 Hz) |

**★ `usbreset`(USBDEVFS_RESET)은 USB 링크만 다시 맺는다. 보드 안의 FPGA·펌웨어
상태는 그대로다.** 그것이 엉키면 **전원을 끊어야만** 풀린다.

**★ PC 재부팅으로는 안 된다.** NOTICE 보드는 자체 크레이트 전원을 쓰므로 PC 만
껐다 켜도 보드는 계속 켜져 있다. USB 케이블만 뽑았다 꽂는 것도 같다.
**보드 전원 자체를 내리고 10초 이상 기다렸다 올려야 한다.**

**★ 전원 재투입은 트리거 설정을 날린다.** 직후 23,527 Hz 가 그것이다. 잡음
트리거이므로 **`NOTICE_CODE_RUN.sh` 로 보드를 다시 설정해야 한다.** 전원을
내렸으면 이 단계가 선택이 아니라 필수다.

**★ 감시자 없이 `rcterm` 을 직접 돌리면 실패 시 `daq`·`tcb` 가 고아로 남는다.**
부모가 systemd 로 바뀌고 포트 3개를 계속 잡고 있어 다음 시도를 막는다. 오늘
두 번 걸렸다. **§11.50 의 복구 절차에 이 한 줄이 빠져 있었다.**

```bash
scripts/killdaq.sh -b /home/frontend/DAQ/DAQ_cup/install/bin
#   ★ 인자 없이 부르면 ONLDAQ_DIR 이 없어 "bin directory not found : '/bin'" 로 실패한다
```

**고친 복구 절차 (§11.50 을 대체한다)**

```
1  pgrep -x rcsupervisor / rcterm / daq / tcb / merger  +  ss -ltn | grep 7809
   ★ pgrep -f 를 쓰지 말 것 — 저장소 경로에 'rcterm' 이 들어 있어 자기가 잡힌다
2  scripts/killdaq.sh -b <bindir>            고아가 있으면 치운다
3  src/usbreset                              먼저 이것
4  확인 런  rcterm --no-db --run 999999 --max-runs 1 --run-length 0.05 --quiet
      합격 : exit=0, 약 1000 Hz, TCB/FADC/SADC 로그에 LIBUSB 0건
      실패하면 -> 5
5  ★ 보드 전원 재투입 (10초 이상) -> lsusb 로 셋 다 확인
6  src/NOTICE_CODE_RUN.sh                    설정 복원. rc=0 이고 pedestal 이 나와야 한다
7  src/usbreset  ->  확인 런 다시
8  감시자 재기동 (rundesc.txt 를 넘겨서) -> daq-alarm.sh --silence
```

확인 런은 **`--no-db --run 999999`** 로 돌린다. 런 카탈로그를 더럽히지 않는다
(§11.50 은 실제 런 번호를 태웠다). 끝나면 `/Data_ssd/RAW/999999` 를 지운다.

**결과 — run 4313 이 975 Hz 로 수집 중이고 `rundesc` 가 run 4307 과 바이트 일치**
한다(§11.20 대로 한 측정으로 묶인다). 공백 22:25 ~ 01:34, **3시간 9분**.

#### 11.120 ★ `usb-recover.sh` 가 이 고장을 영원히 못 잡는다 (아직 안 고쳤다)

감시자는 포기하기 전에 자동 복구를 불렀고 **`1 = not-usb`** 로 물러났다.
5초 만에 끝났다. 구멍이 둘이고 **둘 다 고쳐야** 다음에 잡는다.

```
① TCB 로그를 아예 안 본다
     scripts/usb-recover.sh:148,152 가 FADCDAQ · SADCDAQ 만 훑는다.
     TCB 는 리셋 대상 목록(BOARDS, 50행)에는 있는데 로그 검사에서 빠져 있다

② 오류 문자열이 하나도 안 겹친다
     찾는 것   LIBUSB_ERROR_IO · USB3Read: read error ·
               USB3ReadReg: read error · error in reading buffer count
     실제      USB3TCBWrite: write error:LIBUSB_ERROR_TIMEOUT
               USB3TCBRead:  write error:LIBUSB_ERROR_TIMEOUT
     함수 이름 · 동사(write/read) · libusb 코드(_TIMEOUT/_IO) 셋 다 다르다

실측 : 그 로그에 오류 43건이 있는데 진단 패턴으로 세면 0 건이다
```

§11.56 에서 이 진단을 만들 때 근거로 삼은 것은 §11.49 의 **FADC + `LIBUSB_ERROR_IO`
한 사례뿐**이었다. 그물이 그 한 사례에 맞춰져 있었다. 스크립트가 "근거 없으면
리셋하지 않는다"를 지킨 것 자체는 옳다 — **원칙이 아니라 그물이 문제다.**

**★ 그리고 진단을 통과했더라도 이번엔 못 고쳤을 것이다.** 답이 `usbreset` 이
아니라 **물리적 전원 재투입**이었기 때문이다. 자동 복구로 닫을 수 없는 고장이
있다는 것을 `usb-recover.sh` 의 실패 메시지가 사람에게 알려야 한다.

#### 11.121 ★★ 경희대 백업 링크 실측 — 10 Gb 로 올릴 값어치가 없다

사용자 질문 : "경희대 백업도 10 Gb 로 개선하면 어떻게 되나. 장점이 크면 하겠다."
**답은 아니다.** 근거는 아래 실측이고, 결론은 **병목이 이 PC 의 랜카드가 아니라
바깥 경로**라는 것이다. 측정 시각 2026-08-26 02:00 경(한산한 시간대).

**실측 — 랜카드는 13%밖에 안 쓰인다**

```
enp0s31f6            1000 Mb/s Full, 오류 0        이론 상한 125 MB/s
돌고 있는 백업        15.5 ~ 16.0 MB/s = 130 Mbps  <- 링크의 13.0%
RTT hep.khu.ac.kr    10.9 ms
경로                 1) 203.230.111.1  사이트 게이트웨이
                     2) 134.75.8.109   KREONET (KISTI 연구망)
                     3) 134.75.5.102   KREONET
                     4~ ICMP 차단
```

**★ 결정적 시험 — 스트림을 늘려도 총량이 안 는다.** 원격 `/dev/null` 로 보내
디스크를 배제하고 쟀다.

| 동시 스트림 | 총 송신 |
|---|---|
| 1 (백업만) | 15.95 MB/s = **130 Mbps** |
| 2 | 16.69 MB/s = 140 Mbps |
| 5 | 17.10 MB/s = **143 Mbps** |
| 받는 방향 | 13.74 MB/s = 115 Mbps |

**스트림을 5배로 늘려도 10% 밖에 안 는다.** 새 스트림은 돌고 있던 백업의 대역을
뺏어갈 뿐이었다. **경로가 약 145 Mbps 에서 단단히 막혀 있다.**

**TCP 상태가 이유를 말해 준다** (`ss -ti`, 84.5 GB 보낸 장기 연결)

```
cwnd 69 세그먼트 (~100 KB)   ssthresh 53   rtt 9.77 ms   cubic
재전송 76.9 MB / 84.5 GB = 0.091%
delivery_rate 73.7 Mbps      pacing_rate 98 Mbps

검산 : 69 x 1448 / 0.0098 s = 10.2 MB/s  <- 실측과 일치
```

**손실이 혼잡창을 눌러 놓고 있다.** 다만 병렬로도 안 뚫리므로 원인은 혼잡이
아니라 **어딘가의 속도 제한(policer/shaper)** 이다. 한산한 새벽 2시에 재도
같은 값이므로 시간대 혼잡도 아니다.

**혼잡 제어를 BBR 로 바꿔 볼 수도 없다** — 이 커널에 `reno cubic` 뿐이다.
있었더라도 하드 캡은 못 뚫는다. 지금 이미 상한의 90%(130/145)를 쓰고 있어
**튜닝으로 얻을 것이 사실상 없다.**

**그래서 10 Gb 로 바꾸면?**

| 무엇을 바꾸나 | 백업 1회 (RAW+PRD 221 GB) | 얻는 것 |
|---|---|---|
| 지금 | 15.7 MB/s → **3.9 시간** | — |
| **랜카드만 10 Gb 로** | 15.7 MB/s → **3.9 시간** | **0. 아무것도 없다** |
| 경로가 1 Gb 를 실제로 내주면 | 약 110 MB/s → **약 33 분** | **7배** |
| 경로까지 10 Gb | 약 600 MB/s → **약 6 분** | 그 위로 5배 더 |

**★ 랜카드를 바꾸는 것은 이미 있는 1 Gb 카드가 13%만 쓰이는 상황에서 아무 뜻이
없다.** 진짜 개선은 **바깥 경로가 지금 이미 꽂혀 있는 1 Gb 를 내주게 하는 것**이고,
그것만으로 7배다. 하드웨어를 하나도 안 사고 얻는다.

**그리고 1 Gb 면 충분하다.** 24시간 런 하나가 221 GB 인데 1 Gb 로는 33분이다 —
**하루의 2.3%.** 10 Gb 로 가면 6분이 되지만 33분도 이미 아무 문제가 없다.
**밀린 옛 런 237개**(§11.61)를 따라잡을 때만 차이가 크다 — 그건 일회성이다.

**★ 추가 실측 (같은 날) — 병목은 경로가 아니라 우리 쪽이다**

사용자가 "회선은 10 Gb 이고 중간 공유기가 떨어뜨리는 것 같다"고 해서 확인했다.
**목적지를 바꿔 재면 갈린다** — 경희대 문제라면 다른 곳은 빨라야 한다.

```
mirror.kakao.com        112 Mbps      경희대와 무관. 10 Gb 급 CDN
mirror.navercorp.com    110 Mbps      역시 무관
경희대 (받기)           115 Mbps
경희대 (보내기)         130~143 Mbps
```

**어디로 보내든 110~145 Mbps 에서 막힌다. 우리 쪽이 원인이다.**
(`ftp.kaist.ac.kr` 은 404 라 무효. URL 이 틀렸다.)

**첫 홉을 확인했다 — 공유기가 아니라 Cisco 다.**

```
203.230.111.1   MAC d4:e8:80:58:6b:7f   OUI D4-E8-80 = Cisco Systems, Inc
관리 포트(22·23·80·443·8080·8443) 전부 닫힘 — 여기서는 기종을 못 좁힌다
이 PC 는 공인 IP(203.230.111.71) 라 NAT 뒤가 아니다. 그 장비는 라우팅만 한다
게이트웨이 ICMP 응답 2.97 ms — 같은 세그먼트 치고 느리다(보통 0.1~0.5).
   다만 제어평면 ICMP 는 원래 후순위라 이것만으로 단정하지 않는다
우리 인터페이스 : 1000 Mb/s Full, 오류·충돌 0 (tx_dropped 14 뿐)
```

**Cisco 는 이 대역을 하드웨어로 처리한다.** 그러므로 145 Mbps 는 성능 한계가
아니라 **설정된 속도 제한일 가능성이 높다.** 재전송 0.091% 는 초과분을 **버리는**
policer 의 특징이다 — 큐에 쌓는 shaper 였다면 손실 없이 지연만 늘었을 것이다.

**★ 다만 후보가 둘 남았고, 여기서는 더 못 가린다.**

```
A  Cisco 에 rate-limit / QoS 정책이 걸려 있다        (수치상 가장 유력)
B  traceroute 에 안 잡히는 L2 장비가 사이에 있다     (브리지 모드 공유기·스위치)
      L2 장비는 홉으로 보이지 않으므로 ARP 로도 구분되지 않는다
```

**가르는 방법 — 같은 세그먼트의 다른 장비와 재면 된다.** 그 경로는 Cisco 를
거치지 않지만 **L2 장비는 거친다.**

```
1 Gb 가 나온다   -> Cisco 정책이 원인 (A)
145 Mbps 가 나온다 -> 사이에 L2 장비가 있다 (B)
```

같은 세그먼트에 장비 6대가 응답한다(`.2 .74 .77 .100 .145 .200`). **그러나 우리가
접속할 수 있는 곳이 하나도 없다**(22 포트가 거부 또는 시간초과). 협조해 줄 호스트가
하나 있으면 5분이면 끝난다. 없으면 **케이블을 눈으로 따라가는 편이 빠르다.**

**사이트에 물어볼 것**

```
1  203.230.111.1 (Cisco) 에 rate-limit / police / service-policy 가 걸려 있는가
2  이 PC 와 그 Cisco 사이에 다른 장비가 끼어 있는가     ★ 사용자가 의심하는 그것
3  영광 사이트의 인터넷 회선 계약 대역이 얼마인가        10 Gb 라고 들었다
4  경희대 쪽 서버의 업링크가 공유·제한되는가
```

**★ 두 번째 측정 — 값이 재현된다 (같은 날 02:20).** 사용자가 중간 장비를 빼기
전에 한 번 더 쟀다. **아직 안 뺀 상태다.**

```
1차 02:0x   5 스트림 총량 143 Mbps        백업이 RAW 를 보내던 중
2차 02:2x   5 스트림 총량 143 Mbps        백업이 PRD 로 넘어간 뒤
            kakao 114 · naver 110 · khu 받기 122
```

시간대도 다르고 백업 구간도 다른데 **상한이 정확히 같다. 혼잡이라면 흔들렸을
값이다.** 이 안정성 자체가 설정된 제한이라는 증거다.

**★ 이 PC 쪽 원인은 전부 배제했다.** 모든 목적지가 똑같이 막히길래 확인했다.

```
tc qdisc     fq_codel (기본값), class·filter 없음   -> 로컬 셰이핑 없음
TCP wmem     최대 4 MB    필요한 BDP = 1 Gb x 10.9 ms = 1.30 MB   -> 버퍼 충분
인터페이스   1000 Mb/s Full, 오류·충돌 0
```

**측정을 도구로 뺐다 — `scripts/netcheck.sh`.** 손으로 치면 매번 조건이 달라져
비교가 안 된다. 기준선이 스크립트 안에 주석으로 박혀 있다.

```bash
scripts/netcheck.sh --local-only    # 대역을 안 쓴다. 이 PC 쪽만 본다
scripts/netcheck.sh                 # 전부. ★ 대역을 실제로 쓴다
```

**판정 기준 하나만 보면 된다 — `5 스트림 총 송신`이 143 Mbps 를 넘는가.**
넘으면 그 장비가 원인이었던 것이고, 그대로면 Cisco 나 그 위쪽 정책이다.

**★ 고친 뒤에는 이 PC 의 1 Gb 카드가 다음 병목이 된다.** 그때는 **X710 의 두 번째
포트(`enp3s0f0`)가 비어 있으므로 랜카드를 사지 않아도 된다** — SFP+ 케이블만 있으면
된다. 다만 1 Gb 만 되어도 24시간 런 백업이 33분(하루의 2.3%)이라 급하지 않다.
차이가 큰 것은 **밀린 옛 런 237개**를 따라잡을 때뿐이다.

**저장소 링크(§11.115)와 성격이 정반대다.** 그쪽은 우리 쪽 카드가 100 Mb 라
바꾸니 69배가 됐다. 이쪽은 우리 쪽이 이미 1 Gb 이고 바깥이 막혔다.
**같은 '10 Gb 로 올리자'가 한쪽에서는 옳고 한쪽에서는 헛돈이다.**

#### 11.123 ★★ `/backup_hdd` rsync 이 끊기는 이유 — 이름이 바뀌는 것은 결과다

사용자 질문 : "rsync 중에 disk name 이 바뀌어 끊기는데 원인이 뭔가."
**답 : 이름이 바뀌어서 끊기는 것이 아니라, 끊겼기 때문에 이름이 바뀐다.**

**★ 이건 이 PC 가 아니라 저장소 서버(`nfs-server`, 10.0.0.10) 이야기다.**
그쪽 `/backup_hdd` 는 사람이 손으로 마운트해 쓰는 **USB 외장 디스크**이고,
우리 파이프라인(`postrun`·`dataflow`·`backup-khu`)과는 무관하다.
`ssh store` 로 붙어 실측했다 (§11.118 덕에 가능해졌다).

**증상**

```
rsync: [generator] recv_generator: failed to stat ".../MERGED_002442.root.08467": Input/output error (5)
rsync: [receiver]  mkstemp ".../.MERGED_002442.root.08026.c5mH6K" failed: Input/output error (5)
143,437,671,969  53%  118.00MB/s   ->  rsync error ... (code 23)

df -h        /dev/sdc1 -> /backup_hdd        마운트돼 있다고 나온다
ls /dev/sd*  sda sda1 sdb sdb1               ★ sdc 가 존재하지 않는다
```

**원인 — dmesg 가 순서대로 담고 있다**

```
16:30:24  Buffer I/O error on dev sdc1 ... lost async page write
16:30:24  Aborting journal on device sdc1-8
16:30:29  device offline error, dev sdc, sector 2048 op WRITE     <- ★ 장치가 사라졌다
16:30:29  EXT4-fs (sdc1): I/O error while writing superblock
16:30:29  EXT4-fs (sdc1): Remounting filesystem read-only
16:30:29  usb 2-2: new SuperSpeed USB device number 6             <- 같은 디스크가 재열거
16:30:30  sd 17:0:0:0: [sdb] Attached SCSI disk                   <- 이번엔 sdb 로 붙었다
16:31:56  EXT4-fs (sdb1): recovery complete                       <- 사람이 재마운트
```

**양쪽 UUID 가 `ad07fc77-ca3d-4763-afcb-8ee541213a34` 로 같다** — 같은 디스크다.

```
인클로저   JMicron JMS551 USB-SATA 브리지 (152d:0551)
디스크     Seagate ST2000DM008  2 TB (3.5인치)
```

**★ 인과의 방향이 중요하다.**

```
USB 인클로저가 쓰기 도중 버스에서 떨어진다
   -> ext4 저널 abort -> 파일시스템 강제 read-only -> 모든 작업이 EIO
   -> rsync 사망
   -> 그 디스크가 다시 붙으며 '다음 빈 이름'을 받는다 (sdc -> sdb)
```

`/dev/sdX` 는 **발견 순서로 붙는 이름**이지 디스크에 새겨진 것이 아니다.
**이름 변경은 장치가 한 번 사라졌다는 흔적**이다. 그래서 UUID 로 바꾸는 것만으로는
끊김이 멎지 않는다 — 그건 '엉뚱한 디스크를 잡는 것'만 막는다.

**브리지 상태가 좋지 않다는 신호도 같이 나온다.**

```
sd 17:0:0:0: [sdb] Sector size 0 reported, assuming 512
sd 17:0:0:0: [sdb] 0-byte physical blocks
sd 17:0:0:0: [sdb] No Caching mode page found
```

**피해 — 확인했다. 잃은 것은 없다**

```
0 바이트 파일     138 개      원본은 지워졌는데 목적지가 비었다
40MB 미만         139 개      정상은 약 80 MB
남은 임시 조각      8 개      .MERGED_002442.root.*.XXXXXX
```

`--remove-source-files` 를 썼기 때문에 생긴 모양이다. **그런데 원본 RAW 가 온전하다.**

```
/data/RAW/002442   FADC 8546 / SADC 8549 / PRD 8548
```

**`Merged` 는 RAW 에서 다시 만들 수 있는 중간 산출물**이다 — 경희대 백업에서
일부러 빼는 것도 같은 이유다(§11.14). 138개 전부 재생성 가능하므로 **영구 손실은
없다.** 운이 좋았던 것이지 절차가 안전했던 것은 아니다.

**★ 문제가 셋이다. 서로 다르니 따로 고쳐야 한다**

| # | 무엇 | 성격 |
|---|---|---|
| A | USB 인클로저가 부하 중에 떨어진다 | **근본 원인.** 하드웨어 |
| B | 디스크가 99% 찼다 (1.8T 중 27G) | 남은 443개 x 80MB = 약 35 GB. **어차피 못 끝난다** |
| C | `--remove-source-files` 로 대조 없이 지웠다 | 절차. §8 위반 |

**조치 순서**

```
1  umount /backup_hdd && e2fsck -f -y /dev/sdb1
     ★ 'recovery complete' 는 저널 재생일 뿐 검사가 아니다.
       저널이 abort 된 뒤에는 전체 검사를 해야 한다
2  find /backup_hdd/.../Merged -maxdepth 1 -name 'MERGED_*' -size 0 -delete
   rm -f /backup_hdd/.../Merged/.MERGED_*
     안 지우면 다음 rsync 이 '이미 있다'고 건너뛴다
3  용량을 해결한다 (더 큰 디스크 또는 분할)
4  UUID 로 마운트한다
     UUID=ad07fc77-ca3d-4763-afcb-8ee541213a34 /backup_hdd ext4 defaults,noauto,nofail 0 0
5  --remove-source-files 를 쓰지 않는다. §8 대로 보내고 -> 대조하고 -> 지운다
     rsync -a --partial-dir=.rsync-partial <원본>/ /backup_hdd/<대상>/
     rsync -c -n -i <원본>/ /backup_hdd/<대상>/      '>f' 줄이 0 이어야 한다
```

**A(떨어지는 것) 를 잡으려면 볼 것**

```
1  3.5인치라 12V 외부 전원이 필요하다. 어댑터 용량이 충분한가
   2베이 독이면 둘이 나눠 쓴다 — 부하가 걸릴 때 모자라기 쉽다
2  USB 케이블을 짧고 좋은 것으로. 허브를 거치지 말고 뒷면 포트에 직결
3  브리지 칩 발열 — 117 MB/s 로 20분 연속 쓰면 뜨거워진다
4  smartctl -d sat -a /dev/sdb
     UDMA_CRC_Error_Count 가 는다  -> 케이블·브리지
     Reallocated / Pending 이 있다 -> 디스크 자체
```

**다음에 같은 증상이 나면 이 한 줄이면 갈린다**

```bash
ssh store 'dmesg -T | grep -iE "device offline|USB disconnect|Aborting journal|Attached SCSI disk|reset" | tail -20'
```

`device offline` + 곧이어 `Attached SCSI disk` 가 보이면 **또 떨어진 것**이다.

