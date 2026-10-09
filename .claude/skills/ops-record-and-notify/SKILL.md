---
name: ops-record-and-notify
description: "RENE DAQ 작업의 기록과 통보 형식. CLAUDE.md §11.x 절(번호·위치·구성), §11.142 이어받기 절의 갱신, 메모리 파일(한 사실 한 파일 + MEMORY.md 한 줄), append-only 로그(threshold-changes.log · incident.log · badrun_list), work-web 커밋과 운영 pull, 메일 정책(문제·복구 → 전문가 목록+책임자, 정상 교체 → 책임자만, 보안 → 책임자)과 본문 구성, 기록 페이지(아티팩트) 갱신 조건을 다룬다. 변경이 있는 모든 작업의 마지막에 쓴다. 코드 변경 자체에는 rene-code-change 를 쓴다."
---

# 기록과 통보 — 실측만, 같은 자리에, 정책대로

`ops-scribe` 가 따른다. 왜 따로 두나: 기록이 빠지면 다음 PC·다음 세션에서 맥락이 끊긴다(CLAUDE.md §0.0 의 "작업을 마칠 때마다"). 그리고 메일 수신자를 잘못 고르면 전문가 11 명에게 오보가 간다(§11.177).

## 1. CLAUDE.md §11.x 절

- 번호는 지금 가장 큰 §11.x + 1. `grep -n '^#### 11\.' CLAUDE.md | head -3` 으로 확인.
- 위치: 날짜 블록 `### 2026-…` 바로 아래, 기존 최상위 절 **앞**에 넣는다(큰 번호가 위). 그리고 §11.142 의 "최근에 크게 바뀐 것" 목록 **맨 위**에 `§11.xxx  ★ 한 줄` 을 더한다.
- 제목: `#### 11.xxx ★ <무엇을 왜> (사용자 지시|질문|사고, MM-DD HH:xx)`. 별은 중요도(★~★★★).
- 본문 구성: 사용자 문장(인용) → 한 것(명령·시각·결과를 코드 블록으로) → 확인한 것(실측 수치 표) → 밟은 것/교훈 → 남은 것. 수치는 산출물의 실측만. "확인 못 함" 은 그대로.
- 긴 절은 90 줄 안쪽. 표·코드 블록을 쓰고 문장은 짧게.

## 2. 메모리 (`~/.claude/projects/-home-frontend-DAQ-RENE-daq-rcterm/memory/`)

- 저장할 것: 영구 지침(feedback), 코드·git 에서 못 읽는 프로젝트 사실(project), 반복 함정. 저장하지 않을 것: 코드 구조, 이번 대화에만 뜻 있는 것.
- 형식: frontmatter(`name` · `description` 한 줄 · `type`) + 본문 + `**Why:**` + `**How to apply:**` + `관련: [[다른 메모리]]`.
- 이미 있는 파일이 같은 주제면 갱신한다(새 파일 금지). `MEMORY.md` 에 `- [제목](파일) — 훅` 한 줄. 내용은 넣지 않는다.

## 3. append-only 로그와 생성물

| 무엇 | 정본 | 사본(저장소) |
|---|---|---|
| 문턱 변경 | `/Data_ssd/LOG/threshold-changes.log` | `docs/threshold-changes.log` (`git add -f`, `*.log` 무시 규칙) |
| 보안 사건 | `/Data_ssd/LOG/security-<날짜>/incident.log` | 없음(경로만 §11.x 에) |
| 문제 런 | `/Data_ssd/LOG/badrun_list.txt` | `docs/BADRUNS.md` (도구가 만든다) |
| 하드 라벨 | `docs/backup-disks/disks.tsv` (운영에서 도구가 갱신) | work-web 에 복사 후 커밋, 운영은 `git checkout --` |

## 4. 커밋과 pull

`docs:` 영문 명령형 + 세션 서명 두 줄. work-web 에서 커밋 → 운영 `git pull --ff-only`. GitHub push 는 자격증명 캐시가 살아 있을 때만 된다 — 안 되면 "사용자가 push 할 것" 을 보고에 적는다.

## 5. 메일 정책 (2026-09-09 영구 지침)

| 사건 | 수신 | `--to` |
|---|---|---|
| 수집 문제 발생 · 문제 뒤 재가동 | 전문가 목록 + 책임자 | `both` |
| 정상 런 교체 · 문턱 변경(정상) · 백업 회차 · 시트 등재 | 책임자만 | `routine` |
| 보안 · 다른 계정 문제 · 시스템 관리 요청 | 책임자만 | `routine` |

```bash
python3 tools/notify/send_mail.py --params config/notify.params --to both|routine --subject "<제목>" --body-file <파일>
```
제목 접두어 `[RENE DAQ]` 는 스크립트가 붙인다. 본문은 `[상황] [원인] [조치] [현재] [남은 것/부탁]`. 보내기 전에 `/Data/LOG/daq-notify.log` 와 세션 기록으로 같은 사건의 자동 메일이 이미 갔는지 본다 — 갔으면 원인·조치가 든 후속 한 통만.

## 6. 기록 페이지(아티팩트)

주소는 CLAUDE.md §0.0 의 것 하나. Claude 세션에서만 갱신되며 `url` 을 넘겨야 같은 페이지다. 큰 구조 변화(새 단계·새 하네스)가 있을 때만 갱신하고, 런 단위 사건은 §11.x 로 충분하다.

## 7. 보고 형식 (오케스트레이터에 돌려줄 것)

```
절: §11.xxx (CLAUDE.md L<줄>)   커밋: <해시> (work-web) → 운영 pull OK|막힘(<파일>)
메모리: <파일명 | 없음>   로그: <경로 | 없음>
메일: <both|routine|없음> rc=<n> 제목 "<…>"
push: <됨 | 사용자가 할 것>
```
