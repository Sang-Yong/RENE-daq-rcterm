# 런 서머리 웹 모니터링 — 설계 스펙 (2026-09-08 승인)

JSNS2 SCM (https://research.kek.jp/group/mlfnu/jsns2/scm.html) 스타일의
런 서머리 페이지를 만든다. **런당 1줄 표 + 항목별로 런마다 점이 쌓이는 추이
그림 + 자동 갱신 웹 게시.** 기존 DAQ log sheet (GoodRuns) 와는 별개다.

사용자 결정 (2026-09-08):
- 호스팅은 **구글사이트** — DAQ 머신에 포트를 여는 자체 서버안은 분리가
  안전하다고 판단해 보류. 발행부는 모듈로 분리해 나중에 갈아끼울 수 있게 한다.
- 물리량(IBD·accidental·fast-n·Li/He)은 기존 코드 재사용에 머물지 않고
  **개선 + 신설**한다. 이를 위해 **2차 프로덕션(DST) 단계**를 정식으로 둔다.
- 페이지 공개 범위는 미정 — 우선 잠가 두거나 링크 비공개로 시작.

---

## 1. 지금 있는 것 / 없는 것 (탐색으로 확정)

있는 것 — `tools/monitor/` 3단계가 이미 만든다:
- `run_summary.tsv` schema 2 : run, n_subrun, n_bad, epoch_start/end,
  wall/span/live/dead, **n_type1(target only) / n_type2(veto only) /
  n_type3(both)**. EventType 의미는 실측으로 확정돼 있다 (README §1).
- `pair_summary.tsv` schema 2 : run, tag(_nGd/_nH), src, live_s,
  n_ibd, n_ibd_acci, 컷 창, n_single, r_ll.
- 추이 PNG 7종 (`rate_trend_*.png`), x축은 날짜.

없는 것:
- **fast neutron bg, Li/He bg — 계산 자체가 없다** (README 에 명시).
- 컷이 `AnalysisCondition.h` 에 박혀 있어 바꾸면 PRD 전체 재독이 필요하다.
- **자동 실행이 없다** — cron 미등록, 산출물이 2026-08-25 에 멈춰 있었다.
- 웹 게시가 없다.

참고 페이지(JSNS2)의 실체: 정적 HTML + `<meta refresh 60s>` + 같은 폴더
PNG 나열 + basic auth. 서버 작업이 PNG 를 덮어쓰면 끝나는 구조.

## 2. 파이프라인 (개편 후)

```
PRD (완결 런만: FADC==PRD 게이트, sheetlog 와 같은 판정)
 ├─ 1단계(기존)  run-summary.sh     → run_summary.tsv
 ├─ 2단계(신설)  dst-build.sh       → dst/DST_<런>.root      ★ 2차 프로덕션
 ├─ 3단계(신설)  metrics.sh         → metrics_summary.tsv    (DST 에서 계산)
 ├─ (과도기)     ibd-summary.sh     → pair_summary.tsv       (기존, 교차검증용)
 ├─ 4단계(개편)  rate-trend.sh      → 추이 PNG 11+종
 └─ 5단계(신설)  websummary.sh      → 표·그림 생성 + 발행 (publish 모듈 호출)
```

실행: cron 매시 **27분** (07분 sheetlog 와 분리). 새 완결 런이 없으면
아무것도 안 한다(상태 파일). `--dry-run` 제공. `/scratch` 부재 시 조용히
물러난다 (chainwatch 원칙 — 감시·발행이 스스로 죽어 사고가 되지 않게).
nice/ionice 로 수집·후처리를 방해하지 않는다.

## 3. 2차 프로덕션 — DST (`BuildMonitorDst.C`)

**왜.** fast-n 과 Li/He 는 둘 다 "각 후보가 직전 (샤워링) 뮤온에서 얼마나
떨어져 있나"를 요구한다. PRD 전체를 훑어야만 나오는 값이므로 지금 DST 에
넣어 두면, 레시피가 몇 번을 바뀌어도 PRD 재독 없이 DST 에서 초 단위로
재계산된다. IBD·acci 도 같은 이득을 받는다 (컷 변경 = DST 재계산).

**내용.** 런당 ROOT 파일 1개, 트리 2개:
- `muons`  : 모든 뮤온의 t_us, NPE, 종류(target: FADC 고에너지/포화,
  veto: 위+아래 패널 동시 — `RenePrdSingles.h` 기존 판정. target 뮤온 문턱은 monitorcuts.params 값)
- `singles`: 클린 싱글(기존 Step1+Step2)의 t_us, NPE, 타입 플래그,
  서브런 번호, **dt_prev_muon** (직전 뮤온까지 시간 — 서브런 경계를
  넘겨 carry, livetime carry 와 같은 방식)

페어링은 저장하지 않는다 — `RenePairing.h` 로 singles 에서 그때그때
재계산한다 (컷이 params 로 움직이므로 저장하면 오히려 낡는다).

**위치·성격.** `/scratch/RunSummary/dst/DST_<런>.root`. **Merged 처럼
재생 가능 캐시다** — 백업·dataflow 대상에서 제외하고 문서에 명시한다.
크기 추정 런당 1–2 GB (구현 때 실측해 문서를 채운다). 서브런 단위 증분
빌드 + 캐시로 완결 런만 1회 처리한다.

**의존.** `RenePrdSingles.h` 를 재사용하므로 분석 트리 의존(§0.0 의
RENE_ANA_HELPERS / RENE_COND)을 그대로 물려받는다.

## 4. 메트릭 (`BuildMetrics.C` → `metrics_summary.tsv`)

컷 상수를 `config/monitorcuts.params(.example)` 로 뺀다 (에너지 창,
dt 창, iso 창, 샤워링 뮤온 NPE 문턱, fast-n 사이드밴드, Li/He 적합 창).

- **IBD·accidental** : 기존 로직을 DST 입력으로 이식. **전환 게이트** —
  기준 런(4237 — 기존 비트 단위 검증에 쓴 런 — 과 최근 완결 런 1개)에서 DST 경로의 n_ibd·n_ibd_acci 가 기존 `BuildPairSummary.C`
  와 일치함을 확인한 뒤에만 웹의 출처를 DST 로 바꾼다. 그 전까지 웹은
  legacy 를 읽는다 (`metrics_source = legacy|dst` 파라미터).
- **Li/He (신설)** : 후보의 dt_prev_muon 분포를 ⁹Li(τ=257 ms) +
  ⁸He(τ=172 ms) 지수 붕괴로 적합 → 런당 N_LiHe.
- **fast-n (신설)** : prompt 고에너지 사이드밴드 외삽 + veto-동반쌍 계수.

★ Li/He·fast-n 의 첫 레시피는 **미검증**이다. 문턱·창을 전부 params 로
두고, 분석팀 검증 전까지 웹에 '예비값' 표기를 단다. 검증되지 않은 수를
확정처럼 싣지 않는다.

## 5. 표 (런당 1줄, 최신이 위)

| Run | 시작시각 | 수집시간(live/wall) | 전체 이벤트 | Target only | VETO only | V+T | IBD nGd | acci nGd | IBD nH | acci nH | R_LL | fast-n | Li/He | 선원 |

- fast-n·Li/He 는 검증 전까지 '(예비)' 표기, 레시피 확정 전엔 '—'.
- `선원` 열: AmBe 등 선원 런의 후보 수가 중성미자가 아님을 표에서 바로
  보이게 하는 안전장치 (pair_summary 의 src).
- 수집 중·미완결 런은 싣지 않는다 (완결 게이트).

## 6. 그림 (런마다 점 하나, x축 날짜)

기존 7종 재사용 + `BuildRateTrend.C` 확장 4종: **전체 rate · Target only
rate · VETO only rate · V+T rate** (단위 Hz — 런 길이에 무관하게 비교).
Li/He·fast-n 추이는 검증 후 2종 추가.

## 7. 발행 — 구글사이트 (publish 모듈, 갈아끼움 가능)

```
그림  드라이브에 그림당 파일 1개(ID 고정) → 매 갱신 같은 ID 에 내용만 교체
      (Drive REST files.update + google-auth 토큰. 새 pip 의존 없음)
      사이트에는 '삽입→퍼가기(URL)' 로 썸네일 주소를 1회 등록
      → 캐시 수 분~30분 지연. 런 주기가 하루라 실용상 충분
표    새 스프레드시트에 런당 1줄 append (gspread, 기존 자격증명)
      사이트에 시트 임베드 → 즉시 반영. 시트 차트를 끼우면 즉석 그림도 덤
```

파일 ID ↔ 그림 이름 맵과 시트 ID 는 `config/websummary.params` 에 둔다
(자격증명은 아니지만 사이트 전용 값 — 기존 관례대로 params 는 gitignore, example 만 저장소에).

**사용자 1회성 작업 4개** (클릭 작업):
1. GCP 콘솔에서 Drive API 사용 설정 (프로젝트 rene-daq-rundata-log-sheet)
2. 드라이브 폴더 생성 + 서비스 계정(claude-json@...)에 편집자 공유
3. 새 스프레드시트 생성 + 같은 계정에 편집자 공유
4. sites.google.com/new 페이지 생성 + 퍼가기 URL·시트 배치 (이후 전자동)

**시트 쓰기 규칙은 §11.5 를 따른다** — 다만 이 시트는 전부 '우리 것'이므로
남의 행 문제는 없다. 그래도 백업 후 쓰기·되대조는 같은 코드를 쓴다.

## 8. 손대는 파일

```
tools/monitor/BuildMonitorDst.C      신설  PRD → DST
tools/monitor/BuildMetrics.C         신설  DST → metrics_summary.tsv
tools/monitor/dst-build.sh           신설  래퍼 (기존 단계 스크립트 패턴)
tools/monitor/metrics.sh             신설  래퍼
tools/monitor/websummary.sh          신설  표·그림 생성 + 발행 오케스트레이션
tools/monitor/publish_google.py      신설  Drive 교체 + 시트 append
tools/monitor/BuildRateTrend.C       확장  타입별 rate 4그림
tools/monitor/README.md              갱신
config/monitorcuts.params.example    신설
config/websummary.params.example     신설
crontab                              1줄 추가 (매시 27분)
```

§8 작업 규칙 준수: 별도 클론(~/DAQ/work-web)에서 수정·커밋, 운영 디렉터리는
git pull 만.

## 9. 검증 계획

- 가짜 TSV/PRD 픽스처로: 완결 게이트, 미완결 런 제외, 상태 파일, --dry-run,
  /scratch 부재 시 조용한 후퇴, cron 환경(env -i).
- DST: 기준 런에서 n_ibd·n_ibd_acci 가 legacy 와 일치 (전환 게이트).
  dt_prev_muon 의 서브런 경계 carry 를 경계 걸친 표본으로 확인.
- 발행: --dry-run 은 드라이브·시트를 건드리지 않는다. 실발행 1회 후
  사이트에서 눈으로 확인. 시트는 쓰기 전 백업 + 쓰기 후 되대조.
- 하드웨어·수집·실데이터 무접촉. DAQ 포트·방화벽 변경 없음.

## 10. 리스크·한계 (알고 시작하는 것)

- Drive 썸네일 캐시 지연(수 분~30분)은 실측으로 확인할 항목.
- 서비스 계정 Drive API 가 꺼져 있으면 그림 발행이 안 된다 (사용자 작업 1).
- fast-n·Li/He 첫 수치는 예비값 — 분석팀 검증까지 표기 유지.
- DST 재계산 비용: 완결 런당 1회, 기존 2단계와 같은 규모 (10G 링크 실측
  기준 부담 없음. 구현 때 실측치로 문서를 채운다).
- 구글사이트 페이지 자체는 API 가 없어 첫 배치가 수동이다 — 그림을 더할
  때마다 사이트에 퍼가기 1회가 필요하다 (자주 있는 일은 아니다).
