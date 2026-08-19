# 알람 · 메일 · 자동 USB 복구

DAQ 가 멈췄을 때 **현장에서 소리로 알리고, 책임자에게 메일을 보내고,
USB 보드 문제라면 스스로 되살리는** 장치다.

2026-08-20 의 장애가 이 문서의 출발점이다 — run 4294 가 24시간을 정상으로
채운 직후 FADC USB 보드가 걸려 뒤따른 다섯 런이 모두 실패했고, 감시자가
포기한 뒤 **두 시간 넘게 아무도 몰랐다.** 사람이 손으로 밟은 복구 절차
(진단 → `usbreset` → 짧은 확인 런)를 그대로 코드로 옮긴 것이 이 장치다.
경위는 `CLAUDE.md` §11.49~11.51.

---

## 1. 무엇이 언제 일어나는가

```
   런 하나 실패
        │
        ├─ 감시자가 새 번호로 재시작            ──► 알림 : restart
        │
   (연속 실패가 max-consec-fail = 5 에 닿으면)
        │
        ▼
   scripts/usb-recover.sh
        │
        ├─ [1] 안전 확인 ─ 수집이 살아 있으면 아무것도 안 한다  (exit 3)
        ├─ [2] 진단     ─ USB 오류의 근거가 없으면 손대지 않는다 (exit 1)
        ├─ [3] usbreset ─ 최대 2회. 매번 보드 재등록 + 3분 확인 런으로 검사
        │        │
        │        ├─ 통과 ──► exit 0 ──► 감시자가 실패 카운터를 0 으로 되돌리고
        │        │                      수집을 이어간다     ──► 알림 : recovered
        │        └─ 실패 ──► exit 2 ──► 알람 + 전문가 메일  ──► 알림 : recovery_failed
        │
        └─ (자동 복구가 꺼져 있으면 바로)                    ──► 알림 : fatal
```

`stale`(런이 쓰기 도중 heartbeat 가 멎음)은 위와 별개로 감지될 때마다 알린다.

---

## 2. 구성 요소

| 파일 | 하는 일 |
|---|---|
| `scripts/daq-alarm.sh` | 소리를 켜고 끈다. 사람이 끌 때까지 반복한다 |
| `scripts/daq-notify.sh` | 사건 하나를 알람과 메일로 내보내는 **단일 진입점** |
| `tools/notify/send_mail.py` | SMTP 발송 |
| `scripts/usb-recover.sh` | 진단 + `usbreset` + 확인 런 |
| `config/notify.params` | 위 넷이 함께 읽는 설정. **`.gitignore` 대상** |

**감시자는 이 넷을 '바깥 프로그램'으로만 다룬다.** 알림이나 복구 로직이
감시자 안에 들어오면 그것이 죽을 때 감시자까지 끌고 내려간다.
`rcsupervisor` 가 `RunControl.cc` 를 링크하지 않는 것과 같은 이유다(§5).

---

## 3. 처음 설정할 때

```bash
cp config/notify.params.example config/notify.params
chmod 600 config/notify.params
vi config/notify.params        # smtp_user / smtp_pass / mail_to / mail_to_expert
```

**Gmail 을 쓴다면 계정 비밀번호가 아니라 '앱 비밀번호'여야 한다.**
2단계 인증을 켠 뒤 Google 계정 > 보안 > 앱 비밀번호에서 발급받는다.
16자 소문자이고 계정 비밀번호와 전혀 다르게 생겼다.

계정 비밀번호를 넣으면 Gmail 이 이렇게 거절한다(2026-08-20 실측) :

```
535 5.7.8 Username and Password not accepted.
https://support.google.com/mail/?p=BadCredentials
```

**메일이 실패해도 알람은 울린다.** 일부러 그렇게 나눠 두었다 —
소리는 소리대로 나야 한다. 실측으로 확인했다.

**값 안에 `#` 을 쓰지 말 것.** 파서가 주석으로 보고 잘라낸다.

확인 :

```bash
scripts/daq-alarm.sh --test                     # 소리가 나는가
scripts/daq-notify.sh --dry-run restart         # 메일 본문이 어떻게 생겼나
python3 tools/notify/send_mail.py --params config/notify.params \
        --to routine --subject '시험' --dry-run
scripts/usb-recover.sh --diagnose               # 지금 USB 문제로 보이는가 (읽기 전용)
```

### PC 스피커는 root 조치가 한 번 필요하다 — ★ `usermod` 로는 안 된다

케이스 내부 비프는 `/dev/input/...` 쓰기 권한이 있어야 한다. 없으면
`daq-alarm.sh` 가 한 줄 알리고 **사운드카드만** 쓴다(동작은 한다).

**`sudo usermod -aG input <계정>` 은 이 상황에서 통하지 않는다.** 알람을
띄우는 것은 감시자이고, 감시자는 tmux 서버에서 뻗어나온다. 이미 떠 있는
tmux 서버는 `usermod` 이전의 보조그룹을 그대로 붙들고 있어서, **재로그인을
해도 tmux 서버를 다시 띄우지 않는 한(= 수집 중단) 적용되지 않는다.**
2026-08-20 에 실측으로 확인했다 — 계정에는 `input` 이 들어갔는데
tmux 서버와 감시자의 `/proc/<pid>/status` 는 여전히 `Groups: 18 1001` 이었다.

**그룹이 아니라 '소유자'를 주면 그 문제가 사라진다.** uid 로 판정되므로
보조그룹과 무관하고, 재로그인도 DAQ 중단도 필요 없으며 재부팅에도 남는다.

**★ 한 줄씩 그대로 복사할 것.** 여러 줄짜리 heredoc 은 터미널에 붙여넣을 때
깨지기 쉽다 — 2026-08-20 에 실제로 깨져서, `tee` 가 규칙 내용을 파일 이름으로
받아 저장소에 root 소유 빈 파일 여섯 개를 만들고 규칙은 생기지 않았다.

```bash
echo 'SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="PC Speaker", OWNER="frontend", GROUP="input", MODE="0660"' | sudo tee /etc/udev/rules.d/99-rene-pcspkr.rules
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=input --action=change
```

확인 — **소유자가 `frontend` 로 바뀌었으면** 된 것이다. `root input` 그대로면
규칙이 안 걸린 것이니 위 첫 줄이 제대로 들어갔는지 다시 볼 것.

```bash
grep -rn 'PC Speaker' /etc/udev/rules.d/     # 규칙이 들어갔나 (파일명은 아무거나 된다)
ls -la $(readlink -f /dev/input/by-path/platform-pcspkr-event-spkr)
scripts/daq-alarm.sh --test        # 이제 '권한 없음' 경고가 안 나와야 한다
```

udev 는 **파일 이름을 따지지 않는다** — `.rules` 로 끝나기만 하면 된다.
이 사이트에는 `99-rene-pscpkr.rules` 로 들어갔고 그대로 잘 돈다.

### 감시자에 붙이기

`config/rcsupervisor.params` 에 세 줄을 넣는다(예시 파일에 이미 들어 있다).

```
notify-cmd    = /home/frontend/DAQ/RENE-daq-rcterm/scripts/daq-notify.sh
notify-params = /home/frontend/DAQ/RENE-daq-rcterm/config/notify.params
recover-cmd   = /home/frontend/DAQ/RENE-daq-rcterm/scripts/usb-recover.sh
```

넣지 않아도 `scripts/daq-tmux.sh --start` 로 띄우면 `config/notify.params` 가
있을 때 자동으로 붙여 준다. **기동 로그에서 실제로 걸렸는지 반드시 확인할 것** —
설정을 안 고쳐 조용히 꺼져 있는 것이 가장 위험한 실패 방식이다.

```
[SUP] notify=/.../daq-notify.sh  recover=/.../usb-recover.sh  (params set)
```

`(off)` 로 나오면 안 걸린 것이다.

---

## 4. 알람이 울렸을 때

```bash
scripts/daq-alarm.sh --status      # 왜 울리는가, 언제부터인가
scripts/daq-alarm.sh --silence     # 끈다. '사람이 인지했다'는 뜻이다
```

상태 화면(`scripts/rcmon.sh`, tmux 좌상단 pane)에도 붉은 배너로 뜬다.
**소리를 끄는 것과 문제를 고치는 것은 다르다.** 끄기 전에 메일 본문이나
`--status` 로 사유를 먼저 볼 것.

---

## 5. 설계에서 신경 쓴 것 ★ 되돌리기 전에 읽을 것

**5.1 안전 게이트를 없애지 말 것.** `usb-recover.sh` 는 맨 처음에
`rcterm`/`daq`/`tcb`/`merger` 프로세스와 7809·7814·7815 포트를 확인하고,
하나라도 살아 있으면 **종료코드 3 으로 즉시 물러난다.** `usbreset` 은 보드를
리셋하므로 진행 중인 런이 그 자리에서 깨진다. 실측으로 확인했다 — 수집 중에
돌리면 `rcterm daq tcb / 열린 포트 3개` 를 잡아내고 아무것도 하지 않는다.

**5.2 진단 없이 리셋하지 않는다.** USB 오류의 근거(`LIBUSB_ERROR_IO` 계열,
또는 보드가 `lsusb` 에서 사라짐)가 없으면 종료코드 1 로 물러난다. 원인이
다른데 보드를 흔들면 문제만 더 어려워진다.

**5.3 최근 로그만 본다.** `recover_log_age_min`(기본 60분) 안에 쓰인 DAQ
로그만 진단에 쓴다. 옛 장애의 로그가 디렉터리에 남아 있으므로 그냥 최신 N개를
보면 지금과 무관한 실패를 근거로 오진한다. 실측 — 08-20 03:20 장애의
`FADCDAQ_004299.log` 가 몇 시간 뒤에도 최신 3개 안에 있었다.

**5.4 계수율은 합이 아니라 ADC 별 최솟값으로 본다.** 한 보드만 죽으면 합도
평균도 멀쩡해 보인다. **이번 장애가 정확히 그 모양이었다** — FADC 만 먹통,
SADC 는 1000 Hz 정상. `heartbeat` 의 `ar=` 값 중 최솟값이 문턱을 넘어야 한다.

**5.5 확인 런 없이 '복구됐다'고 하지 않는다.** 보드가 `lsusb` 에 다시 보이는
것만으로는 부족하다. 걸린 보드도 등록은 된다. 3분짜리 런을 실제로 돌려
① 종료코드 0 ② 그 런의 로그에 USB 오류 0건 ③ FADC 산출이 1 MB 이상
④ ADC 별 계수율 최솟값이 문턱 이상 — 넷을 다 통과해야 복구로 친다.
확인 런은 `--no-db --run 999999` 로 돌아 **런 카탈로그를 더럽히지 않는다.**

**5.6 알림 실패가 감시자를 끌고 내려가면 안 된다.** `Notify()` 는 백그라운드로
던지고 결과를 보지 않는다. 메일이 안 나가는 것보다 수집이 멎는 것이 나쁘다.
반대로 `RunRecover()` 는 결과를 봐야 하므로 동기로 부른다.

**5.7 같은 사건을 두 번 알리지 않는다.** 복구 스크립트가 이미
`recovery_failed` 로 알렸으면 감시자는 `fatal` 을 보내지 않는다. 그쪽 메일이
시도 기록까지 담고 있어 훨씬 쓸모 있다.

**5.8 도배를 막되, 놓치면 안 되는 것은 막지 않는다.** `mail_min_interval`
(기본 5분)로 같은 사건의 반복 발송을 억제하지만 `recovery_failed` 와 `fatal`
은 이 제한을 받지 않는다.

---

## 6. 하드웨어 없이 시험한 것 (2026-08-20)

| 시험 | 결과 |
|---|---|
| 안전 게이트 (수집 중 실행) | `rcterm daq tcb` + 포트 3개 감지, exit 3, 무접촉 ✅ |
| 진단 — 장애 로그가 창 안에 있을 때 | `FADC` 를 정확히 지목 (사람의 판정과 일치) ✅ |
| 진단 — 보드가 정상일 때 | "USB 문제 아님" exit 1 ✅ |
| 알람 켜기/상태/끄기 | 상태 파일·좀비 프로세스 정리까지 확인 ✅ |
| 소리 경로 | `pw-play` OK / `aplay -D default` OK / `plughw:0,0` 실패(대체 경로) ✅ |
| 감시자 A — 복구 성공(0) | 실패 카운터 0 으로 되돌리고 수집 계속, exit 0 ✅ |
| 감시자 B — 복구 실패(2) | 포기, exit 2, `fatal` 중복 알림 없음 ✅ |
| 감시자 C — USB 문제 아님(1) | 위와 동일 ✅ |
| 감시자 D — `--no-auto-recover` | 복구 시도 0회, `fatal` 알림 발송 ✅ |
| 감시자 E — heartbeat 정지 | `stale` 로 런 번호와 사유까지 실어 알림 ✅ |

가짜 `rcterm`/복구 스크립트로 돌렸다. **하드웨어를 전혀 건드리지 않았다.**
`--bindir` 을 비워 두면 감시자의 `pkill` 정리가 통째로 생략되므로, 살아 있는
DAQ 옆에서 시험할 때는 반드시 그렇게 할 것.

**아직 실전에서 확인하지 못한 것** — 실제 보드가 걸린 상태에서의
`usbreset` 자동 복구. 다음에 같은 장애가 나야 확인된다.
