---
name: rene-daq-orchestrator
description: "RENE DAQ 운용 하네스의 오케스트레이터. 상태 점검, 사건 대응(런 중단·USB·DRAM·OOM·chain_down), 문턱값 변경과 재시작, 모니터링 분석·그림·비교표, 외장하드 백업, 저장소 코드 변경(구현+검토), 기록·메일을 전문 에이전트에 나눠 맡기고 결과를 종합한다. '하네스로', '점검해', '사건 처리', '문턱값 바꿔', '그림 그려', '백업', '스크립트 고쳐' 같은 요청과, 그 결과의 수정·재실행·보완·일부만 다시·이전 결과 개선 같은 후속 요청에 쓴다. 한두 줄로 답할 수 있는 단순 질문은 직접 답한다."
---

# RENE DAQ 오케스트레이터

## 실행 모드: 혼합 (기본은 서브에이전트 위임)

| 단계 | 실행 모드 | 이유 |
|---|---|---|
| 점검 · 분석 · 백업 · 기록 | 서브에이전트 위임 (한 번 호출, 결과만) | 결과만 받으면 되고 에이전트끼리 대화할 일이 없다 |
| 사건 대응 · 문턱 변경 | 서브에이전트 위임, 단 `run_in_background: false` | 하드웨어를 건드리는 동안 메인이 다른 일을 겹쳐 하면 안 된다 |
| 코드 변경 | 생성·검증 쌍(`code-engineer` → `code-reviewer`), 최대 2 회전 | 검토 기준이 스킬에 코드로 적혀 있어 주관 협상이 필요 없다. 지속형 대화 없이 커밋 해시만 주고받는다 |

`Workflow` 는 쓰지 않는다. 처리 목록이 미리 정해지는 대량 작업이 이 프로젝트에 없다(런은 하나씩 다룬다).

## 에이전트 구성

| 에이전트 | 모델 | 스킬 | 산출물 |
|---|---|---|---|
| `daq-status-inspector` | sonnet (정형 수집) | `daq-status-check` | 상태 표 |
| `daq-incident-responder` | opus (원인 판단 + 절차) | `daq-incident-playbook` · `recovering-aborted-daq-runs` | `_workspace/<날짜>_incident_<런>.md` |
| `threshold-change-operator` | opus (30 채널 대조 + 재시작 검증) | `veto-threshold-change` | `_workspace/<날짜>_threshold_<런>.md` |
| `monitor-analyst` | opus (물리 해석) | `run-summary-analysis` | 그림 경로 + 수치 표 + 해석 |
| `backup-operator` | sonnet (절차 준수) | `RENE_daq_data_backup_management_skill` | 세션 상태 보고 |
| `code-engineer` / `code-reviewer` | opus / opus (읽기 전용) | `rene-code-change` | 커밋 해시 / 판정 |
| `ops-scribe` | sonnet (형식 옮김) | `ops-record-and-notify` | 절 번호 · 커밋 · 메일 rc |

`_workspace/` 는 `/Data_ssd/LOG/harness/` 다(저장소 안이 아니다 — 운영 디렉터리를 더럽히지 않는다). 파일 이름 `{날짜}_{에이전트}_{내용}.md`.

## 하드웨어 권한 (사용자 결정 2026-10-10)

문서화된 복구 절차(감시자 TERM · killdaq · usbreset · 확인 런 · 재기동)는 에이전트가 자동으로 하고 결과를 보고한다. 보드 전원 재투입 · HV · 설정 변경 · 다른 계정 프로세스 · root 가 필요한 것은 사용자 확인 뒤에만. 에이전트가 멈추고 보고하면 오케스트레이터는 사용자에게 무엇을 왜 해야 하는지 한 번에 묻는다.

## 작업 절차

### 0단계: 요청 분류와 기존 작업 확인

1. 요청을 한 갈래로 분류한다: 점검 / 사건 / 문턱 / 분석 / 백업 / 코드 / 기록·메일 / 복합.
2. `/Data_ssd/LOG/harness/` 에 같은 주제의 산출물이 있으면 후속 요청이다. "일부만 다시" 면 그 에이전트만, "새 입력" 이면 옛 파일은 그대로 두고 새 날짜로.
3. 먼저 `cat /Data/LOG/rcterm.hb` 로 수집이 도는지 본다. 사건 갈래가 아닌데 `phase≠running` 이면 사건 갈래를 먼저 붙인다 — 수집이 서 있는데 그림을 그리는 것은 순서가 틀렸다.

### 1단계: 위임

한 메시지에 독립 호출을 묶는다. 갈래별 기본 묶음:

| 갈래 | 호출 |
|---|---|
| 점검 | `daq-status-inspector` |
| 사건 | `daq-incident-responder`(전면) → 끝나면 `daq-status-inspector`(사후 기준선) + `ops-scribe` |
| 문턱 | `threshold-change-operator`(전면) → `ops-scribe`; 서브런 100 뒤 `monitor-analyst`(비교표) |
| 분석 | `monitor-analyst` (긴 배치면 로그 경로를 받아 Monitor 로 끝을 기다린다) |
| 백업 | `backup-operator` → `ops-scribe` |
| 코드 | `code-engineer` → `code-reviewer` → (지적 있으면) `code-engineer` → `code-reviewer` → `ops-scribe` |
| 복합 | 의존 없는 것은 병렬, 하드웨어를 건드리는 것은 혼자 |

프롬프트에는 반드시: 요청 원문 · 관련 §11.x · 산출물 경로 · "실측만, 추측은 '추정' 표시".

### 2단계: 결과 수집과 판정

- 에이전트 보고의 수치를 그대로 옮기고 오케스트레이터가 새 수치를 만들지 않는다.
- 사건·문턱 갈래는 검증 표(aligned 8 · LIBUSB 0 · 계수율 · DB)가 산출물에 있어야 끝난 것이다. 없으면 돌려보낸다.
- 코드 갈래는 리뷰 판정이 `승인` 또는 `고치면 승인`(반영 뒤) 이어야 pull 한다. 두 회전 뒤에도 `반려` 면 사용자에게 올린다.

### 3단계: 기록

변경·사건·배포가 하나라도 있으면 `ops-scribe` 를 부른다. 점검만 한 경우는 부르지 않는다. 메일은 `ops-scribe` 만 보낸다(이중 발송 방지).

### 4단계: 보고

사용자에게는 결과부터. 표 하나 · 어긋난 것 · 사용자가 할 것(root·전원·승인) · 기록 위치(§11.x · 커밋). 에이전트 이름·내부 단계는 적지 않는다.

## 데이터 전달

| 방법 | 쓰는 곳 |
|---|---|
| 일반 반환값 | 모든 서브에이전트 → 오케스트레이터 |
| 파일 `/Data_ssd/LOG/harness/{날짜}_{에이전트}_{내용}.md` | 사건·문턱·코드 → `ops-scribe` 입력. 사후 검증용으로 남긴다 |
| 프롬프트에 경로 | 리뷰어에게 커밋 해시, 분석자에게 비교 대상 런 |

## 오류 처리

| 상황 | 대응 |
|---|---|
| 에이전트 실패(빈 결과·예외) | 한 번 다시. 또 실패하면 그 갈래를 빼고 보고에 "누락" 명시 |
| 권한 거부(root·sudo·분류기 차단) | 다시 시도하지 않는다. 필요한 명령을 적어 사용자에게 넘긴다 (`! sudo …` 안내) |
| 사용량 한도·인증 만료 | 재시도 없음. 부분 산출물을 직접 열어 어디까지 됐는지 확인하고 보고. 에이전트의 판단은 추측해 채우지 않는다 |
| 하드웨어 절차 중 불합격 | 다음 단계로 넘어가지 않는다. 상태를 남기고 사용자에게 |
| 둘 이상의 에이전트가 수집을 동시에 건드리려 함 | 하드웨어 갈래는 항상 하나만, `run_in_background: false` |
| 서로 다른 수치 | 지우지 않고 출처(에이전트·명령·시각)와 함께 나란히 |

## 테스트 시나리오

### 정상 흐름 — 문턱 변경
1. "run 4067 값의 80 % 로 바꿔 다시 받자" → 문턱 갈래. `threshold-change-operator` 가 30 값 표를 보이고 새 파일 `…_thr4067x80.config` 로 재시작, 새 런 TCB THR 대조 · DRAM 8 · LIBUSB 0 을 산출물에.
2. `ops-scribe` 가 §11.x · threshold-changes.log 사본 · 메모리 갱신 · 커밋/pull · 책임자 메일.
3. 서브런 100 뒤 `monitor-analyst` 가 직전 런과 패널 Hz 표.
예상: 산출물 파일 2 개, 커밋 1 개, 메일 1 통(routine).

### 오류 흐름 — 사건 중 권한 벽
1. run 이 exit 2 로 죽고 dmesg 에 OOM. `daq-incident-responder` 가 원인(다른 계정 프로세스)을 가르고 usbreset 절차로 재개, 새 런 DRAM 8/8.
2. 다른 계정 프로세스 종료는 root 가 필요 → 멈추고 명령을 적어 보고.
3. 오케스트레이터가 사용자에게 `! sudo …` 한 줄을 제시하고, `ops-scribe` 가 §11.x 와 both 메일.
예상: 복구는 끝나 있고, root 조치만 사용자 몫으로 남는다.

### 오류 흐름 — 코드 변경 반려
1. `code-engineer` 가 `pgrep -f` 를 쓴 커밋. `code-reviewer` 반려(금지 2).
2. 돌려보내 `pgrep -x` 로 고친 커밋 → 승인 → pull → `ops-scribe`.
