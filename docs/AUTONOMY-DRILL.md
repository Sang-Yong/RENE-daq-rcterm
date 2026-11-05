# 자율 복구 드릴 (`scripts/autonomy-drill.sh`)

일부러 고장을 내고, 시스템이 **사람 없이** 되살아나 정상 수집으로 돌아오는지 본다.
바깥 망을 끊으면 Claude 세션도 끊기므로 드릴은 이 PC 에서 혼자 돌고, 결과를 로컬에 남긴다.
망이 돌아온 뒤 사람이나 Claude 가 결과를 읽는다. 주입 목록의 근거는 감사 보고서
`/Data_ssd/LOG/harness/20261105_code-reviewer_autonomy-audit.md` §8 이다.

## 무엇이 필요한가

| 전제 | 왜 |
|---|---|
| 시험 런이 돌고 있다 (`phase=running`, heartbeat 120 s 안) | 드릴은 그 런을 일부러 깨뜨린다. **물리 런에서 돌리지 말 것** |
| 새 감시자 (`rcsupervisor` 의 standby · SIGUSR1 판, work-auto-sup 갈래) | 옛 감시자는 SIGUSR1 을 받으면 죽는다. 드릴은 `SigCgt` 를 보고 옛 감시자면 7 단계를 건너뛴다 |
| `chainwatch.sh` cron (5 분) — pane 자동 재기동 판 (work-auto-watch 갈래) | 6 단계는 chainwatch 가 postrun 을 되살리는지 본다 |
| `netsync.sh` + cron (5 분) — offline-full 만 | 2·9 단계는 netsync 의 `net=down/up` 을 기다린다 |
| 멈춤 파일 `/Data_ssd/LOG/chainwatch.hold` **없음** | 자동 재기동을 시험하는 것이므로 |
| `/Data_ssd` 여유 500 G 이상 | 망이 끊긴 동안 경희대·`/scratch` 로 못 옮긴다 |
| 다른 드릴이 돌고 있지 않다 (`/Data_ssd/LOG/autonomy-drill/RUNNING`) | 겹치면 판정이 섞인다 |

하나라도 아니면 드릴은 **아무것도 주입하지 않고** 단계 0 FAIL 로 끝난다.

## 사용자가 밟을 순서

```bash
cd /home/frontend/DAQ/RENE-daq-rcterm

# 0) 계획과 전제를 먼저 본다 (주입 0, 바깥 0)
scripts/autonomy-drill.sh --plan offline-full --dry-run --confirm-test-run

# 1) 시험 런을 띄운다 (설정은 평소대로. rundesc 에 '드릴 시험 런' 이라고 적어 두면 나중에 가르기 쉽다)
#    tmux daq:1.2 에서 평소 감시자 명령

# 2) 전문가 목록에 미리 알린다 — 드릴 동안 restart · stale · chain_down 메일이 진짜로 나간다
#    (망이 끊긴 동안은 큐에 쌓였다가 망이 돌아오면 한꺼번에 나간다)

# 3) 콘솔(현장 키보드)에서 드릴을 띄운다. 원격 세션은 2 단계에서 끊긴다
mkdir -p /Data_ssd/LOG/autonomy-drill
setsid nohup scripts/autonomy-drill.sh --plan offline-full --confirm-test-run \
      > /Data_ssd/LOG/autonomy-drill/console.log 2>&1 &
tail -f /Data_ssd/LOG/autonomy-drill/console.log

# 4) '★ 사람 차례 : 지금 바깥 망을 끊어라' 가 나오면 (root)
sudo nmcli connection down enp0s31f6
#    또는 (더 실전에 가깝다) 벽 쪽 랜 케이블(enp0s31f6 포트)을 뽑는다. 둘 중 하나만
#    ★ daq_gateway 가 아니다 — 그 프로파일은 케이블 없는 enp3s0f0 에 묶여 비활성이라 down 해도 아무것도 안 끊긴다
#      (실측 11-05 : 활성 프로파일 enp0s31f6 = 장치 enp0s31f6, 203.230.111.71)
#    netsync 가 net=down 을 적을 때까지 최대 15 분. 드릴이 혼자 3~8 단계를 진행한다 (1~2 시간)

# 5) '★ 사람 차례 : 바깥 망을 되살려라' 가 나오면 (root)
sudo nmcli connection up enp0s31f6      # 케이블을 뽑았으면 다시 꽂는다
#    ★ daq_gateway 를 up 하지 말 것 — .71 을 다른 포트에 올리려 해 충돌한다 (CLAUDE.md 11.132)

# 6) 결과
cat /Data_ssd/LOG/autonomy-drill/<시각>/report.md
```

망을 끊지 않는 짧은 판은 `--plan quick --confirm-test-run` (4~8 단계만, 원격에서도 된다).
전원 재투입까지 실물로 보려면 `--with-power` 를 더한다 (아래 8 단계).

## 단계와 기대값

| 단계 | 하는 것 | PASS 기준 | 기본 제한 |
|---|---|---|---|
| 0 전제 | 위 표 | 전부 충족 | — |
| 1 기준선 | 런 · 서브런 · 계수율 · 로그 위치 · 큐 수 → `baseline.txt` | 읽힘 | — |
| 2 [사람] 망 차단 | 안내만. 드릴은 망을 건드리지 않는다 (root) | `netsync.state` 의 `net=down` (신선) | 900 s |
| 3 메일 큐 | chainwatch 1 회 | `/Data_ssd/LOG/MAILQ` 에 새 `.mail` (netsync 의 net_down 포함) | 600 s |
| 4 daq 종료 | `daq` 하나(pgrep -x 첫 pid)에 TERM | 감시자 로그 `restart #` + 새 런 `running` + `TCB_<런>.log` 의 `is aligned` 8 · `Fail to align` 0 | 900 s |
| 5 stale | `rcterm` 에 STOP | 감시자 로그 `heartbeat stale` + 새 런 + DRAM 8. 끝나면 남은 pid 에 CONT | check + stale + 900 s (감시자 머리줄에서 읽는다, 기본 1800 s) |
| 6 postrun | postrun `--follow` 맨 위 셸에 TERM (진행 중 merge 를 끝내고 빠진다) | chainwatch 로그 `자동 재기동 : postrun` + 새 postrun pid | 종료 300 s + 재기동 1500 s |
| 7 SIGUSR1 | 감시자에 USR1 (`/proc/<pid>/status` SigCgt 에 0x200 이 있을 때만) | 감시자 로그 `SIGUSR1 : ending` + 새 런 + DRAM 8 | 900 s |
| 8 전원 (기본) | `usb-recover.sh --force-power-cycle --dry-run` | rc 3 (수집 중이라 게이트가 막음) 또는 0 — 하드웨어 0 | — |
| 8 전원 (`--with-power`) | 감시자 TERM → DAQ 전부 내려감 확인 → `usb-recover --force-power-cycle` 실물 → supervisor pane 에 `daq-tmux.sh --print-cmd supervisor` 명령 | usb-recover rc 0 + 새 런 + DRAM 8 | 2400 s |
| 9 [사람] 망 복귀 | 안내만 | `net=up` → 두 메일 큐 0 → `sheetlog-auto --status` 의 '완결돼 쓸 수 있는 것' 0 | 1800 + 900 s |

매 주입(4~8) 전에 heartbeat 를 다시 읽는다. `phase=running` 이 아니거나 heartbeat 가 오래됐으면
그 단계를 FAIL 로 적고 **남은 주입을 모두 건너뛴다.** 기다리는 동안 멈춤 파일이 생겨도 같다
(사람이 작업 중이라고 본다). 망 복귀 안내(9)는 중단돼도 그대로 한다.

`--confirm-test-run` 이 없으면 4~8 의 실물 주입은 SKIP 이다 (8 의 dry-run 만 돈다).
제한 시간은 `DRILL_T_KILL` · `DRILL_T_STALE` · `DRILL_T_POSTRUN` · `DRILL_T_USR1` · `DRILL_T_POWER` ·
`DRILL_T_NETDOWN` · `DRILL_T_NETUP` · `DRILL_T_FLUSH` 로 바꾼다. 조사 주기는 `DRILL_POLL` (10 s).

## 결과 읽기

```
/Data_ssd/LOG/autonomy-drill/<YYYYmmdd-HHMMSS>/
   drill.log            시간순 전부 (화면에 나온 것과 같다)
   result.tsv           step · name · injected · expected · observed · verdict(PASS/FAIL/SKIP) · evidence(근거 로그 줄)
   report.md            사람이 읽는 표 + PASS/FAIL/SKIP 수
   baseline.txt         1 단계 기준선
   usb-recover-*.txt    8 단계 출력
```

종료코드 0 = 전부 PASS/SKIP, 1 = FAIL 이나 중단이 있었다, 2 = 사용법 오류.
신호(Ctrl-C · TERM)로 끊어도 STOP 해 둔 rcterm 에 CONT 를 보내고 `RUNNING` 을 지우고 report 를 남긴다.

## 실패했을 때

| 단계 | 먼저 볼 것 | 복구 명령 |
|---|---|---|
| 0 | report 의 사유 | 사유를 고친 뒤 다시. `RUNNING` 이 남았으면 그 pid 가 살아 있는지(`kill -0`) 보고, 죽었으면 드릴이 스스로 치운다 |
| 2 | `cat /Data_ssd/LOG/netsync.state` · `crontab -l | grep netsync` | netsync cron 이 있는지. 망이 실제로 끊겼는지 (`ping 8.8.8.8`) |
| 3 | `/Data/LOG/daq-notify.log` · `/Data_ssd/LOG/netsync.log` | daq-notify 가 새 판(로컬 큐)인지 |
| 4·5·7 | `tail -50 /Data/LOG/rcsupervisor.log` · `cat /Data/LOG/rcterm.hb` · `grep -c 'is aligned' /Data_ssd/LOG/TCB_00<런>.log` | 감시자가 standby 면 `<hb>.sup` 을 본다. DRAM 이 안 맞으면 `CLAUDE.md` §11.171 (usbreset 2 회 → 확인 런) |
| 5 | rcterm 이 STOP 인 채 남았나 (`ps -o stat= -p <pid>` 가 T) | `kill -CONT <pid>` (드릴이 끝날 때 보내지만 확인) |
| 6 | `tail /Data_ssd/LOG/chainwatch.log` · `scripts/chainwatch.sh --status` | 손으로 : tmux daq:1.3 에서 `bash scripts/daq-tmux.sh --print-cmd postrun` 의 명령 |
| 8 (`--with-power`) | `usb-recover-power.txt` · `scripts/pdu-power.sh status` | 수집이 멎어 있다. §11.224 순서 (PDU → NOTICE → usbreset 2 회 → 더미 런 → 확인 런) 뒤 tmux daq:1.2 에서 감시자 |
| 9 | `scripts/mailq-send.sh --status` · `scripts/sheetlog-auto.sh --status` · `scripts/netsync.sh --status` | `scripts/mailq-send.sh` · `scripts/sheetlog-auto.sh --force` 를 손으로 |

드릴이 낸 시험 런(시험 런과 4~8 에서 생긴 런들)은 DB 에서 `onlbit=0` + runlog `autonomy drill` 로 표시해
시트 등재에서 빼는 것을 잊지 말 것 (드릴은 DB 를 건드리지 않는다). 런 번호는 `result.tsv` 의 관측 열(`run A -> B`)과
`baseline.txt` 의 `run=` 에 있다. 백업 먼저, 그다음 한 줄 (예 : 4440 ~ 4445) :

```bash
cp -p /Data_ssd/runcatalog.db /Data_ssd/LOG/harness/runcatalog.db.bak-$(date +%Y%m%d%H%M)-before-drill && \
sqlite3 /Data_ssd/runcatalog.db "UPDATE runcatalog SET onlbit=0, runlog='autonomy drill test run, excluded from sheet' || COALESCE(' ; ' || runlog, '') WHERE runnum BETWEEN 4440 AND 4445;"
```

`sheetlog-auto.sh` 가 07 분에 등재하므로 망이 돌아오기 전(또는 9 단계 직후)에 할 것. 이미 시트에 실렸으면 우리 행이라
고칠 수 있다 (CLAUDE.md 11.5).

## 시험

`tests/autonomy-drill.test.sh` — `DRILL_TEST_HOOK` 으로 시계 · sleep · pgrep · kill · ps · crontab · df ·
chainwatch · usb-recover · tmux 를 가짜로 갈아끼우고 heartbeat · 감시자 로그 · netsync.state · 큐 · TCB 로그를
가짜 시계에 맞춰 움직인다. 실 프로세스 · tmux · 하드웨어 · 메일 무접촉.
