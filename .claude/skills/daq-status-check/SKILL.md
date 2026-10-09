---
name: daq-status-check
description: "RENE DAQ PC 와 저장소 서버의 지금 상태를 읽기 전용으로 모아 한 표로 만든다. 수집(heartbeat·감시자·계수율·DRAM·USB) · 후처리 사슬(postrun·dataflow·/scratch) · cron 감시(chainwatch·sheetlog·websummary·backup-sheetlog·minerwatch·reactor-power) · 외장하드 백업 세션 · 용량(/Data_ssd · /data · /scratch · 경희대) · 보안 징후를 다룬다. '상태', '점검', '이상 없어?', '어디까지 됐어' 같은 현황 질문과, 사건 대응·변경 작업의 전후 기준선을 잡을 때 쓴다. 상태를 바꾸는 작업에는 쓰지 않는다."
---

# DAQ 상태 점검 — 명령 목록과 정상 범위

이 스킬은 `daq-status-inspector` 가 따른다. 명령은 전부 읽기 전용이다. 왜 목록을 고정하나: 매번 다른 명령으로 보면 두 보고를 비교할 수 없고, 자리를 헷갈려(`/Data/LOG` 대 `/Data_ssd/LOG`) "없다" 고 오판한 적이 있다.

## 한 번에 모으기

`scripts/status.sh` 를 돌리면 아래 전 항목을 순서대로 찍는다. 개별 항목만 볼 때는 해당 명령을 쓴다.

```bash
bash .claude/skills/daq-status-check/scripts/status.sh          # 저장소 루트에서
```

## 항목별 명령과 정상 범위

| 항목 | 명령 | 정상 | 어긋나면 |
|---|---|---|---|
| 수집 | `cat /Data/LOG/rcterm.hb` | `phase=running`, `error=0`, `time` 이 60 s 안, `ar` 100~20,000 Hz | phase=failed/ended → §11.208 식 사건. ar<100 → HV 부터(§11.131). >20,000 경고 >30,000 비정상(§11.198) |
| 감시자 | `pgrep -x rcsupervisor`; `tail -3 /Data/LOG/rcsupervisor.log` | pid 1 개, `health OK` 10 분마다 | `restart #n`·`FATAL` → 사건 |
| DRAM·USB | `grep -c 'is aligned' /Data_ssd/LOG/TCB_00<런>.log`; `cat /Data_ssd/LOG/{TCB,FADCDAQ,SADCDAQ}_00<런>.log \| grep -c LIBUSB` | 8 / 0 | aligned≠8 → usbreset 절차(§11.171). LIBUSB>0 → §11.179 |
| 고아·포트 | `pgrep -x rcterm\|daq\|tcb\|merger \| wc -l`; `ss -ltn \| grep -cE ':780[9]\|:781[45]'` | rcterm 1 · daq 2 · tcb 1 · 포트 3 | 감시자 없는데 daq 가 있으면 고아(`killdaq.sh -b`) |
| 후처리 사슬 | `scripts/chainwatch.sh --status` | postrun·dataflow 살아 있고 /scratch 마운트 | chain_down → §11.138 |
| tmux | `tmux list-panes -t daq:1 -F '#{pane_index} #{pane_current_command}'` | 5 pane | 세션 없음 → 재부팅 뒤 (`daq-tmux.sh --start`) |
| 런 완결 | `scripts/runcheck.sh --run <직전 런>` | FADC == PRD | 빈 서브런 → `--fix` (사건 대응자) |
| cron | `crontab -l \| grep -vE '^#' \| grep -c .` ; 각 로그 tail | chainwatch 5 분 · mailq 5 분 · sheetlog :07 · websummary :27 · backup-sheetlog :37 · reactor :47 · minerwatch */10 | 줄이 빠졌거나 로그가 1 시간 넘게 멈춤 |
| 웹 서머리 | `tools/monitor/websummary.sh --status` | last_run = 직전 완결 런 | 막힘 → §11.190 (게이트) |
| 백업 세션 | `ssh store 'fuser ~/sykim/backup_log/.backup.lock; tail -c 300 ~/sykim/backup_log/code9.log \| tr "\r" "\n" \| tail -2'` | 도는 중이면 pid, 아니면 마지막 `code=` | `ssh` 거부 → 방화벽 7777(§11.210) 또는 링크(§11.133) |
| 메일 큐 | `scripts/mailq-send.sh --status` | 대기 0 | 쌓이면 /scratch 또는 SMTP |
| 용량 | `df -h /Data_ssd /data /scratch \| tail -3`; `ssh khu 'df -h /store' 2>/dev/null \| tail -1` | §11.206 의 기준 (경희대 11 T 가 먼저 찬다) | 경희대 정리는 절대 제안만 (§8) |
| 보안 | `scripts/minerwatch.sh --status`; `cat /proc/loadavg`; `ps -eo user,pcpu,rss,comm --sort=-pcpu \| head -5` | '징후 없음', load < 코어 수 | 징후 → 사용자에게 root 조치(§11.210) |
| 메모리 | `free -g \| head -2`; `dmesg -T 2>/dev/null \| grep -c 'Out of memory'` | available > 50 G, OOM 0 | OOM → 어느 계정의 무엇이었는지(§11.208) |
| 원자로 기록 | `scripts/reactor-power-log.sh --status` | fails=0, 마지막 1 시간 안 | 실패 2 회면 이미 메일이 갔다 |

## 보고 템플릿

```
# DAQ 상태  <YYYY-MM-DD HH:MM>  (읽기 전용 점검)
| 항목 | 값 | 판정 |
|---|---|---|
| 수집 | run 4374 · sub 612 · 477 Hz · DRAM 8/8 · LIBUSB 0 | ✅ |
| … | … | … |
## 어긋난 것
- ❌ <항목> : <무엇이 어긋났나 한 줄> — 같은 증상 §11.xxx. 추정 원인: … (추정)
## 다음에 부를 에이전트
- <없음 | daq-incident-responder | backup-operator | …> : 이유 한 줄
```

판정 기호 : ✅ 범위 안 · ⚠️ 범위 밖이지만 수집은 돈다 · ❌ 수집이 서거나 데이터를 잃는 중 · `?` 명령 실패 또는 값이 비어 판단 불가(원격은 붙었는데 autofs·placeholder 로 값이 없는 경우도 `?`).

## 읽을 때 조심할 것 (모의 실행 2026-10-10 에서 나온 것)
- **로그 꼬리는 과거 기록이다.** `code9.log` 같은 로그는 "메일을 큐에 넣었습니다" 처럼 현재형으로 적혀 있지만 이 점검이 한 일이 아니다. 보고에는 "마지막 기록 : …(시각)" 으로 옮긴다.
- **cron 로그는 종류가 둘이다.** 매 주기 한 줄을 남기는 것(backup-sheetlog · reactor · minerwatch)은 "1 시간 넘게 멈춤" 이 어긋남이지만, 사건이 있을 때만 적는 것(chainwatch · sheetlog-auto · websummary 의 일부)은 침묵이 정상이다. 침묵형은 `--status` 출력으로 판정한다.
- **한 값에서 원인을 단정하지 않는다.** 같은 시각대의 두 사건(예: OOM 과 런 중단)은 "시간상 근접(추정)" 으로만 적고, 인과는 사건 대응자가 가른다.

## 하지 않는 것
- 재시작·삭제·kill·마운트·메일. 보고에 "하면 된다" 를 적을 뿐 하지 않는다.
- 다른 계정의 `/proc/<pid>/` 안쪽 읽기 시도. 권한이 없고, 있어도 이 스킬의 일이 아니다.
