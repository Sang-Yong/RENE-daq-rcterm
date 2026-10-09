---
name: daq-incident-playbook
description: "RENE DAQ 사건의 증상→원인→복구 절차 분기표. 런 중단(exit 2 · aborted), 감시자 restart/FATAL, FADC·TCB LIBUSB_ERROR, DRAM 정렬 실패(Fail to align), 계수율 0 또는 비정상(20 k 이상), OOM, /scratch 마운트 빠짐, postrun·dataflow 죽음(chain_down), rate_low, 보드 전원 재투입 뒤 설정 소실(23 kHz) 을 다룬다. 런 파일 복구(ZOMBIE·PRD 결손)는 recovering-aborted-daq-runs 와 같이 쓴다. 정상 로테이션·정상 상태 점검에는 쓰지 않는다."
---

# DAQ 사건 플레이북 — 먼저 볼 것, 그 다음 할 것

이 스킬은 `daq-incident-responder` 가 따른다. 2026-08~10 의 사건 기록(CLAUDE.md §11.49 · 11.119 · 11.130 · 11.131 · 11.169 · 11.171 · 11.179 · 11.208)에서 뽑았다. 왜 분기표인가: 같은 증상(계수 0, exit 2)이 서로 다른 원인에서 나고, 보드를 파기 전에 HV 를 봤어야 한 날이 있었다(30 분 손실).

## 0. 사건을 받으면 먼저 (5 분, 읽기 전용)

```bash
cat /Data/LOG/rcterm.hb                                   # phase · run · error · ar
tail -40 /Data/LOG/rcsupervisor.log                       # restart / FATAL / exit 코드
R=<런>; for f in TCB FADCDAQ SADCDAQ; do grep -cE 'LIBUSB|TIMEOUT|OVERFLOW|falied|Fail to align' /Data_ssd/LOG/${f}_00$R.log; done
dmesg -T | grep -iE 'usb disconnect|Out of memory|oom-kill|device offline' | tail -5
pgrep -x rcsupervisor; pgrep -x rcterm; pgrep -x daq | wc -l; pgrep -x tcb; ss -ltn | grep -E ':780[9]|:781[45]'
```
로그가 `/Data_ssd/LOG` 에 없으면 postrun 이 `/scratch/DAQ_LOG/RAW_log/` 로 옮긴 것이다. 거기서 찾는다.

## 1. 분기표

| 증상 | 먼저 볼 것 | 원인 후보 (순서대로) | 절차 |
|---|---|---|---|
| 계수율 0, 전자계 로그 깨끗 | PMT HV | ① HV 꺼짐 ② DRAM 미정렬 ③ 신호 케이블 | HV 는 사용자 확인. DRAM 은 §3 |
| 계수율 20,000 이상 | 직전에 전원 작업이 있었나 | 보드 트리거 설정 소실 | `src/NOTICE_CODE_RUN.sh` 로 재설정(수집 중 금지) → usbreset → 확인 런 |
| 런 exit 2, DAQ 로그 USB 오류 0 | `dmesg` 의 OOM / 스왑 | 다른 계정 프로세스의 메모리 고갈 → rcterm 이 소켓을 잃음 | §4 뒷정리 + 새 런 DRAM 검사(감시자 pkill 뒤 보드가 비정상으로 남는다) |
| 새 런 `Fail to align DRAM` 8/8, 계수는 나옴 | TCB 로그 `is aligned` 개수 | pkill 복구 또는 전원 재투입 뒤 보드 상태 | §3 (usbreset 1~2 회) |
| FADC `LIBUSB_ERROR_TIMEOUT → OVERFLOW/IO`, 로테이션 직후 | lsusb 에 NKFADC500 이 있나 | USB 링크 꼬임(보통) / 보드 떨어짐(가끔) | 있으면 §3. 없으면 보드 전원 재투입(사용자) → NOTICE_CODE_RUN → usbreset ×2 |
| TCB `USB3TCBWrite LIBUSB_ERROR_TIMEOUT` ×N, 부팅 5 회 실패 | — | 보드 내부 상태 (usbreset 으로 안 풀림) | 보드 전원 재투입(사용자) → NOTICE_CODE_RUN → usbreset ×2 → 확인 런 |
| chainwatch `chain_down` | `mountpoint /scratch`, pane 의 postrun·dataflow | /scratch 빠짐 / 스크립트 죽음 | 마운트는 root(사용자). 스크립트는 pane 에서 재기동 |
| `rate_low` (100 Hz 미만) | HV, 문턱 변경 이력 | HV / 문턱을 너무 올림 | HV 사용자. 문턱은 `threshold-change-operator` |
| postrun `ZOMBIE FILE` / `Producing FAILED (0초)` | merge 로그 끝 3 줄, `/scratch/LOG` 쓰기 시험 | 잘린 SADC / 깨진 로그 dirent | `recovering-aborted-daq-runs` 스킬 |

## 2. 하드웨어 조치의 권한 (사용자 결정, 2026-10-10)

- **자동으로 한다**: 감시자 TERM 정상 종료, `killdaq.sh -b <bindir>` 로 고아 정리, `src/usbreset`, 확인 런, 감시자 재기동. 전부 §11.119 에 문서화된 절차다.
- **사용자 확인 뒤에만**: 보드 크레이트 전원 재투입, HV 조작, `NOTICE_CODE_RUN.sh`(보드를 재설정하므로 수집 중이면 런이 깨진다), 설정 파일 변경, 다른 계정 프로세스 종료, root 가 필요한 모든 것.

## 3. 표준 복구 절차 (usbreset 경로)

```bash
# 1 감시자 정상 종료 — 런이 exit 0 으로 닫히고 DB 가 마감된다. TERM 한 번. 두 번째 TERM 은 즉시 탈출이다
kill -TERM $(pgrep -x rcsupervisor); until ! pgrep -x rcsupervisor >/dev/null; do sleep 3; done
grep -E 'phase=|run=' /Data/LOG/rcterm.hb; pgrep -x rcterm; pgrep -x daq; pgrep -x tcb; ss -ltn | grep -cE ':780[9]|:781[45]'
# 2 고아가 있으면 (daq·tcb 가 남고 포트가 잡혀 있으면)
scripts/killdaq.sh -b /home/frontend/DAQ/DAQ_cup/install/bin
# 3 usbreset → 확인 런 3 분 (DB 안 쓴다). 옛 999999 로그는 .old-<시각> 으로 비켜 둔다
src/usbreset; sleep 5; lsusb | grep -c Anchor          # 3 이어야 한다
install/bin/rcterm --params config/rcterm.params --no-db --run 999999 --max-runs 1 --run-length 0.05 --quiet
L=/Data_ssd/LOG/TCB_999999.log; grep -c 'is aligned' $L; grep -c 'Fail to align' $L; cat /Data_ssd/LOG/{TCB,FADCDAQ,SADCDAQ}_999999.log | grep -c LIBUSB
grep '\[STAT\]' /Data_ssd/LOG/FADCDAQ_999999.log | tail -1      # 계수율
# 합격 : exit 0 · aligned 8 · fail 0 · LIBUSB 0 · 계수율이 직전 정상 런의 ±20 %
# 불합격(aligned<8) : usbreset 한 번 더 → 확인 런 다시. 두 번째도 불합격이면 전원 재투입 — 사용자에게
# 4 감시자 재기동 (tmux pane daq:1.2, daq-tmux.sh 가 만드는 것과 같은 명령. notify/recover 는 params 에 있다)
rm -rf /Data_ssd/RAW/999999
DESC=$(grep -v '^[[:space:]]*#' config/rundesc.txt | grep -m1 '[^[:space:]]')
tmux send-keys -t daq:1.2 "/home/frontend/DAQ/RENE-daq-rcterm/install/bin/rcsupervisor --params '/home/frontend/DAQ/RENE-daq-rcterm/config/rcsupervisor.params' -- --desc '$DESC'" C-m
# 5 검증 (45 초 뒤) : 새 런 번호 · aligned 8 · LIBUSB 0 · ar · DB config 열 · notify= 줄이 (off) 가 아닌지
```

## 4. 죽은 런의 뒷정리

1. `scripts/badrun.sh --scan --run <런>` (읽기 전용) → `truncated_tail` 이면 `--quarantine --update-list` 로 마지막 서브런 짝을 `badrun/` 으로.
2. `scripts/runcheck.sh --run <런>` → 빈 PRD 가 있으면 `--fix`. carry 를 못 읽으면 건너뛰므로 결과 줄을 읽는다.
3. `FADC == PRD` 가 되면 dataflow 가 옮긴다. 안 되면 `recovering-aborted-daq-runs` 로.
4. 물리 자료가 아닌 짧은 런(DRAM 미정렬 2 서브런 등)은 DB 의 `onlbit=0` 과 `runlog` 에 사유를 적어 시트 등재에서 뺀다.

## 5. 산출물 (오케스트레이터 → ops-scribe)

`_workspace/<YYYYMMDD>_incident_<런>.md` 에 타임라인(실측 시각) · 원인(근거 로그 줄) · 절차와 단계별 결과 · 검증 표 · 남은 것 · 메일 요약 5 줄. 메일 수신은 문제·복구 → 전문가 목록 + 책임자.

## 밟았던 함정
- `kill -TERM` 뒤 감시자가 바로 안 빠지면 backoff 중이거나 자식이 rsync 류를 기다리는 것이다. 두 번째 TERM 은 즉시 탈출이니 상태를 먼저 본다.
- 확인 런의 DRAM 실패를 계수가 나온다고 넘긴 날이 있다. 로그를 센다.
- restart 메일은 감시자가 자동으로 보낸다. 같은 사건을 손으로 또 보내지 않는다 — 원인·조치가 든 후속 메일 한 통이면 된다.
