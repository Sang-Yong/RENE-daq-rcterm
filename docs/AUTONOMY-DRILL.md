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

## 드릴 플래그와 runcatalog 표시 (2026-11-06)

★ **배포 : 드릴 · netsync · daq-notify · sheetlog-auto 는 같은 판으로 배포한다** (운영 디렉터리 `git pull` 뒤에 드릴). 넷이 `scripts/netsync-lib.sh` 의 `drill_active` 를 함께 쓰고, 단계 9 판정이 netsync 로그의 `sheetlog-auto 건너뜀 (드릴 중` 문구에 묶여 있다 — 옛 netsync 면 9 가 FAIL 이다.

11-05 드릴에서 둘이 어긋났다 : ① 2 단계 망 차단이 확인되지 않았는데 주입을 계속해, 망이 산 채로 전문가 목록 13 명에게
2 시간 동안 메일 10 통이 나갔다. ② 드릴 런을 onlbit=0 으로 빼는 일이 사람 몫이었는데 안 됐고, 11-06 09:35 망 복귀 때
netsync 가 `sheetlog-auto --force` 를 불러 시험 런 4435·4436 이 GoodRuns 에 그 자리에서 실렸다. 그래서 :

| 무엇 | 어떻게 |
|---|---|
| 드릴 플래그 | 전제(0) 통과 직후 `drill_flag` (notify.params, 기본 `/Data_ssd/LOG/drill.active`) 에 `pid= pstart= start= run= plan=` 을 쓰고, 끝(정상 · 중단 · 신호)에 지운다. `--dry-run` 은 안 만든다. 남의 살아 있는 플래그면 단계 0 FAIL, 죽은 것이면 지우고 진행 |
| 플래그가 있는 동안 | `daq-notify` : 모든 사건을 **책임자에게만**, 제목 `[DRILL]`, 본문 머리 '드릴 중 발생', **알람 없음**, 로그 `drill=1`. `netsync` 복귀 flush : 메일 큐만 내보내고 `sheetlog-auto` · `websummary` 는 건너뜀. `sheetlog-auto` : `--force` 여도 `[SKIP] drill` |
| 죽은 플래그 | pid 가 없거나, 그 pid 의 `/proc` 시작 시각이 플래그의 `pstart` 와 다르거나(pid 재사용 — pid_max 4.19 M 이 이미 한 바퀴 돈다), `pstart` 가 없는데 그 pid 의 명령줄에 `autonomy-drill` 이 없거나, 24 h 를 넘긴 플래그는 '드릴 아님' — 전문가 메일을 영영 막지 않는다 |
| runcatalog 표시 (기본 켬, `--no-mark-db` 로 끔) | 끝날 때 DB 를 `sqlite3 .backup` 으로 `/Data_ssd/LOG/harness/runcatalog.db.bak-<시각>-drill` 에 백업한 뒤 **첫 주입 런 ≤ 런 < 끝 런** (주입이 없었으면 시작 런 < 런 < 끝 런) 을 `onlbit=0`, runlog 앞에 `autonomy drill test run (<시작>~<끝>), excluded from sheet` (옛 runlog 는 ` ; ` 뒤에 보존). 하한이 '플래그를 만든 런' 이 아니라 '첫 주입이 때린 런' 인 것은 2·3 단계 대기(최대 ~25 분) 중 자연 로테이션이 오면 24 h 를 완주한 정상 런을 빼지 않기 위해서다. **끝 런은 heartbeat 가 running 이면 뺀다** — 정상 설정으로 계속 도는 런이다 (11-05 의 4437 은 9.6 h 돌았다). running 이 아니면 **rcterm 이 없고 phase 가 ended/failed 일 때만** 넣는다 — rcterm 은 런을 닫을 때 `FinalizeRunInDB` 가 onlbit 를, `MarkFailedRunInDB` 가 runlog 를 다시 쓰므로(src/RunControl.cc) 살아 있는 rcterm 의 런을 0 으로 적어도 1 로 되돌아간다. 최대 120 s(`DRILL_T_ENDWAIT`) 기다리고, 그래도 rcterm 이 있으면 표시하지 않고 report.md 에 그 런만의 백업 + UPDATE 명령을 남긴다 (rcterm 이 끝난 뒤 손으로). 표시 뒤 onlbit 를 되읽어 report 에 적는다. 바꾼 행은 `db-mark.tsv` · `report.md` · `drill.log` 에 표로 |
| 2 단계 멈춤 | 망 차단이 확인되지 않으면(FAIL) **기본은 거기서 멈춘다** — 4~8 주입 0, report 에 '망을 끊지 않아 중단'. 망이 산 채로 돌리려면 `--continue-online` (그래도 알림은 플래그로 책임자에게만) |

## 사용자가 밟을 순서

```bash
cd /home/frontend/DAQ/RENE-daq-rcterm

# 0) 계획과 전제를 먼저 본다 (주입 0, 바깥 0)
scripts/autonomy-drill.sh --plan offline-full --dry-run --confirm-test-run

# 1) 시험 런을 띄운다 (설정은 평소대로. rundesc 에 '드릴 시험 런' 이라고 적어 두면 나중에 가르기 쉽다)
#    tmux daq:1.2 에서 평소 감시자 명령

# 2) 드릴 동안의 restart · stale · chain_down 메일은 드릴 플래그 때문에 책임자에게만 [DRILL] 로 간다
#    (망이 끊긴 동안은 큐에 쌓였다가 망이 돌아오면 나간다). 전문가 목록에 따로 알릴 필요는 없다

# 3) 콘솔(현장 키보드)에서 드릴을 띄운다. 원격 세션은 2 단계에서 끊긴다
#    ★ 콘솔 셸에서 직접(전경으로) 띄우지 말 것 — 터미널이 닫히면 드릴도 죽는다. 반드시 setsid nohup
mkdir -p /Data_ssd/LOG/autonomy-drill
setsid nohup scripts/autonomy-drill.sh --plan offline-full --confirm-test-run \
      > /Data_ssd/LOG/autonomy-drill/console.log 2>&1 &
tail -f /Data_ssd/LOG/autonomy-drill/console.log

# 4) '★ 사람 차례 : 지금 바깥 망을 끊어라' 가 나오면 (root)
sudo nmcli connection down enp0s31f6
#    ★ 케이블을 뽑기보다 nmcli 로 끊을 것 — 11-06 09:18 케이블을 뽑다 FADC USB 가 빠져 run 4437 이 죽었다
#    ★ 15 분 안에 net=down 이 확인되지 않으면 드릴은 거기서 멈춘다 (주입 0). 망이 산 채로 돌리려면 --continue-online
#    ★ daq_gateway 가 아니다 — 그 프로파일은 케이블 없는 enp3s0f0 에 묶여 비활성이라 down 해도 아무것도 안 끊긴다
#      (실측 11-05 : 활성 프로파일 enp0s31f6 = 장치 enp0s31f6, 203.230.111.71)
#    netsync 가 net=down 을 적을 때까지 최대 15 분. 드릴이 혼자 3~8 단계를 진행한다 (1~2 시간)

# 5) '★ 사람 차례 : 바깥 망을 되살려라' 가 나오면 (root). 드릴 런의 onlbit=0 은 드릴이 끝날 때 스스로 한다
#    (드릴이 도는 동안은 플래그 때문에 netsync 가 시트를 건너뛴다)
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
| 9 [사람] 망 복귀 | 망 복귀 안내 (2 단계에서 멈췄으면 SKIP) | `net=up` → `netsync.log` 의 `sheetlog-auto 건너뜀 (드릴 중` (이번 오프셋 이후) → 두 메일 큐 0. `sheetlog-auto rc=` 줄이 오면 FAIL (드릴 중에 시트를 돌렸다 — 옛 netsync 이거나 플래그 경로가 다르다) | 1800 + 1500 + 900 s |
| 10 runcatalog | 드릴 런을 onlbit=0 (위 표). `--no-mark-db` 면 report 에 손으로 칠 명령만 | 바꾼 행 표 | — |

매 주입(4~8) 전에 멈춤 파일과 heartbeat 를 다시 읽는다. 멈춤 파일이 새로 생겼으면 남은 주입을 모두 건너뛴다. `phase=running` 이 아니거나 heartbeat 가 오래됐으면
그 단계를 FAIL 로 적고 **남은 주입을 모두 건너뛴다.** 기다리는 동안 멈춤 파일이 생겨도 같다
(사람이 작업 중이라고 본다). 망 복귀 안내(9)는 중단돼도 그대로 한다 — 단 2 단계에서 망이 끊기지 않아 멈춘 경우는 SKIP.

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
   db-mark.tsv          runcatalog 에서 onlbit=0 으로 바꾼 런 (전 값 · 옛 runlog)
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

드릴이 낸 시험 런은 드릴이 끝날 때 스스로 `onlbit=0` 으로 뺀다 (위 'runcatalog 표시'). 무엇을 바꿨는지는 `db-mark.tsv`,
되돌리려면 그 백업(`/Data_ssd/LOG/harness/runcatalog.db.bak-<시각>-drill`)을 본다. `--no-mark-db` 로 돌렸으면 report.md 끝의
명령(백업 + UPDATE 한 줄)을 **매시 07 분 cron 전에** 친다. 이미 시트에 실렸으면 우리 행이라 고칠 수 있다 (CLAUDE.md 11.5).

## 시험

`tests/autonomy-drill.test.sh` — `DRILL_TEST_HOOK` 으로 시계 · sleep · pgrep · kill · ps · crontab · df ·
chainwatch · usb-recover · tmux 를 가짜로 갈아끼우고 heartbeat · 감시자 로그 · netsync.state · 큐 · TCB 로그를
가짜 시계에 맞춰 움직인다. 실 프로세스 · tmux · 하드웨어 · 메일 무접촉.
