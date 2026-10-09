---
name: rene-code-change
description: "RENE-daq-rcterm 저장소의 코드(bash 스크립트 · ROOT 매크로 · python 도구 · 시험)를 고치고 배포하는 순서와 금지 목록. 작업 클론 work-web 에서 고치기, 시험 먼저 돌리기, 픽스처는 실물 출력으로, 커밋 서식, 운영 디렉터리 pull, 저장소 서버 .new+mv 배포, 감시자가 부르는 파일의 배포 시점을 다룬다. '스크립트 고쳐', '기능 추가', '테스트', '배포' 에 쓴다. code-reviewer 의 검토 기준도 여기 있다."
---

# 코드 변경 — 어디서, 어떤 순서로, 무엇을 금지하나

`code-engineer` 와 `code-reviewer` 가 같이 따른다. 왜 이런 규칙인가: 운영 디렉터리에서 수집이 돌고 있고, cron 과 감시자가 그 파일을 매 분 읽는다. 돌고 있는 파일을 제자리에서 바꾸면 bash 가 어긋난 바이트를 읽어 죽는다(§11.185 · 11.186). 그래서 "다른 곳에서 고치고 새 inode 로 바꿔 끼운다" 가 전부다.

## 1. 작업 순서

```bash
cd /home/frontend/DAQ/work-web && git status --short && git log --oneline -1      # 깨끗한지, 운영과 같은 커밋인지
bash tests/<관련>.test.sh | tail -2          # 기준선. 없으면 새 시험을 만든다
# 고친다 (한 커밋에 한 가지)
bash -n <스크립트>; bash tests/<관련>.test.sh | tail -2
git add <파일>; git commit -m "<type>: <imperative English summary>

<why, one or two lines>

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: <session url>"
cd /home/frontend/DAQ/RENE-daq-rcterm && git pull -q --ff-only /home/frontend/DAQ/work-web main && git log --oneline -1
```
`type` 은 `fix` `feat` `docs` `test` `refactor`. 운영 쪽에 미커밋 변경이 있어 pull 이 막히면 그 파일이 생성물(docs 사본·disks.tsv)인지 보고 work-web 에 복사한 뒤 `git checkout --`.

## 2. 배포 규칙

| 대상 | 방법 | 왜 |
|---|---|---|
| 운영 디렉터리 | `git pull --ff-only` | git 은 새 inode 로 만든다. 도는 bash 는 옛 파일을 붙든다 |
| 저장소 서버 (code9/code10) | `scp … .new` → `ssh store 'chmod +x … && mv -f …'` | `scp` 제자리 덮어쓰기는 같은 inode |
| 감시자가 부르는 `daq-notify.sh` `usb-recover.sh` | 알람이 울리지 않을 때 pull | 사건 순간과 겹치면 반쪽을 읽는다 |
| cron 이 부르는 스크립트 | pull 뒤 `cd / && env -i … <스크립트> --status` 로 한 번 | 환경변수·상대 경로 함정 |
| 도는 배치 | 다음 실행부터 적용된다. 지금 도는 것에는 반영 안 됨 | — |

## 3. 금지 목록 (리뷰어의 반려 기준)

1. 운영 디렉터리에서 소스 편집.
2. `pgrep -f` / `pkill -f`. 저장소 경로의 `rcterm`, `$( )` 서브셸, 조상 argv, 감시 명령줄의 대상 이름까지 다섯 가지로 오탐한다. `pgrep -x`, PID, 잠금 보유자(`fuser`)로.
3. `--dry-run` 이 메일·시트·하드·하드웨어에 닿는 것. 미리보기는 바깥에 흔적을 남기지 않는다.
4. 알림·감시 스크립트가 실패로 종료코드≠0 을 내는 것. 감시가 스스로 넘어지면 없느니만 못하다.
5. `mv` 로 파일시스템을 넘는 이동. rsync → `rsync -c -n -i` 대조 → 삭제. 같은 파일시스템의 `mv -T` 만 예외.
6. awk 프로그램 안 주석의 따옴표(한글 주석도 코드다). `local a=$1 b="${a}"` (b 가 빈다). `NR==FNR` 에 빈 첫 파일. `printf "$var"` (`%` 가 서식이 된다 → `printf '%s'`/`'%b'`).
7. 시험 픽스처를 추측으로 쓰는 것. 실제 명령 출력을 복사한다(`ss` 는 state 필터를 주면 열이 하나 줄고, runcatalog 시각은 텍스트, 수집 중 런은 stime NULL).
8. `--status` 가 상태 파일을 바꾸거나 큐를 소비하는 것.
9. 시트의 남의 행 수정, 경희대 서버 삭제, 자격증명을 저장소에 넣기.
10. 시험 스위트를 병렬로 돌리는 것(서버 쪽 `other_backup()` 이 서로 잡는다), heredoc 명령줄에 감시 대상 이름.
11. 방화벽·cron 제거·프로세스 종료·마운트처럼 **자기 코드 밖에 영향을 주는 규칙을 우리 의존 목록과 대조하지 않고 넣는 것.** 왜: 2026-10-09 에 채굴 풀 포트 목록에 7777 을 넣어 저장소 서버 ssh(10.0.0.10:7777)가 끊겼다. 대조할 목록 — ssh store 7777 · 이 PC sshd 50022 · NFS 2049/111/892 · DAQ 7809/7814/7815 · SMTP 465/587 · 경희대 ssh · 구글 API 443. 목록에 없는 값이라도 "지금 맺힌 연결(`ss -tn`)에 그 포트가 있는가" 를 한 번 본다.

## 4. 리뷰 산출물

```
판정: 승인 | 고치면 승인 | 반려
- <파일>:<줄> <문제> — 재현: <명령/입력> — 방향: <한 줄>
시험: <스위트> <통과/전체> (직접 돌림)
```

## 5. 시험 작성 요령

- `mktemp -d` 샌드박스, 실데이터·실메일·구글·하드웨어 무접촉. 외부 명령은 환경변수로 갈아끼운다(`*_PS` `*_SS` `*_MAIL` 같은 식).
- `env -i PATH=… HOME=…` 로 cron 환경 한 번.
- 깨졌을 때 왜인지 한 줄을 시험 이름에 담는다(`"C 3333 연결 x2"`).
