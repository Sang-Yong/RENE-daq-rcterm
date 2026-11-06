#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  daq-notify.sh 의 메일 실패 -> 로컬 큐 적재, 도배 방지 표식 순서, --force-alarm 시험.
#  ★ 실제 메일·알람은 하나도 나가지 않는다 (NOTIFY_MAILER · NOTIFY_ALARM 을 가짜로).
#    운영 로그 /Data/LOG/daq-notify.log 와 /Data_ssd/LOG/MAILQ 도 건드리지 않는다.
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
NT=$DIR/scripts/daq-notify.sh
MQ=$DIR/scripts/mailq-send.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

cat > "$T/fake_mail.py" <<'PY'
import os, sys
with open(os.environ["CALLS"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
sys.exit(int(os.environ.get("FAKE_RC", "0")))
PY
printf '#!/bin/bash\necho "$*" >> "%s/alarm.calls"\nexit 0\n' "$T" > "$T/fake_alarm.sh"; chmod +x "$T/fake_alarm.sh"
export CALLS=$T/calls NOTIFY_LOG=$T/notify.log NOTIFY_MAILQ=$T/MAILQ NOTIFY_MAILER=$T/fake_mail.py \
       NOTIFY_ALARM=$T/fake_alarm.sh NETSYNC_STATE=$T/netsync.state DRILL_FLAG=$T/drill.active
P=$T/notify.params
cat > "$P" <<EOF2
heartbeat = $T/none.hb
alarm_state = $T/daq-alarm.state
mail_to = boss@example.org
mail_to_expert = a@example.org
mail_expert_events = restart chain_down resumed supervisor_down
mail_min_interval = 300
EOF2
nq()   { find "$T/MAILQ" -maxdepth 1 -name '*.mail' 2>/dev/null | wc -l; }
ncall(){ [ -r "$CALLS" ] && wc -l < "$CALLS" || echo 0; }
pst() { awk '{ sub(/.*\) /, ""); print $20 }' "/proc/$1/stat"; }    # 플래그의 pstart (drill_proc_start 와 같은 값)
reset(){ rm -rf "$T/MAILQ" "$CALLS" "$T/alarm.calls" "$T"/.notify-*.last "$T/netsync.state" "$T/drill.active"; }

echo "[1] 보내면 큐는 비어 있고 도배 방지 표식이 생긴다"
reset; FAKE_RC=0 "$NT" --params "$P" chain_down --msg "시험 1" >/dev/null 2>&1
check "메일기 1 회"          '[ "$(ncall)" = 1 ]'
check "큐 0"                 '[ "$(nq)" = 0 ]'
check "표식 있음"            '[ -r "$T/.notify-chain_down.last" ]'
FAKE_RC=0 "$NT" --params "$P" chain_down --msg "시험 1b" >/dev/null 2>&1
check "300 초 안에 같은 사건은 생략" '[ "$(ncall)" = 1 ]'

echo "[2] 망 실패(rc 5) -> 큐에 쌓고 표식 (메일은 큐가 대신 낸다)"
reset; FAKE_RC=5 "$NT" --params "$P" chain_down --run 4432 --msg "망 끊김" >/dev/null 2>&1
check "큐 1"                 '[ "$(nq)" = 1 ]'
f=$(ls "$T"/MAILQ/*.mail 2>/dev/null | head -1)
check "1 행 subject:"        'head -1 "$f" | grep -q "^subject: chain_down run 4432 - 망 끊김$"'
check "2 행 to: both (전문가 사건)" '[ "$(sed -n 2p "$f")" = "to: both" ]'
check "3 행 body:"           '[ "$(sed -n 3p "$f")" = "body:" ]'
check "본문에 사건"          'grep -q "사건      : chain_down" "$f"'
check ".tmp 가 남지 않았다"  '[ -z "$(ls "$T"/MAILQ/*.tmp 2>/dev/null)" ]'
check "표식 있음 (큐에 쌓은 것도 보낸 것으로 친다)" '[ -r "$T/.notify-chain_down.last" ]'
check "로그에 queued"        'grep -q "mail queued (rc=5)" "$NOTIFY_LOG"'

echo "[3] 설정 오류(rc 2·3)는 쌓지 않고 표식도 남기지 않는다 (다음 호출이 다시 시도)"
reset; FAKE_RC=3 "$NT" --params "$P" chain_down --msg "설정" >/dev/null 2>&1
check "큐 0"                 '[ "$(nq)" = 0 ]'
check "표식 없음"            '[ ! -e "$T/.notify-chain_down.last" ]'
FAKE_RC=0 "$NT" --params "$P" chain_down --msg "설정 2" >/dev/null 2>&1
check "다음 호출은 다시 보냈다" '[ "$(ncall)" = 2 ]'

echo "[4] 인증 실패(rc 4)는 쌓는다"
reset; FAKE_RC=4 "$NT" --params "$P" rotate --msg "인증" >/dev/null 2>&1
check "큐 1"                 '[ "$(nq)" = 1 ]'
check "to: routine (책임자 사건)" '[ "$(sed -n 2p "$(ls "$T"/MAILQ/*.mail | head -1)")" = "to: routine" ]'

echo "[5] netsync 가 망 단절이라고 적어 두었으면 메일기를 부르지 않고 곧바로 쌓는다"
reset; echo "net=down" > "$T/netsync.state"
FAKE_RC=0 "$NT" --params "$P" resumed --msg "단절 중" >/dev/null 2>&1
check "메일기 0"             '[ "$(ncall)" = 0 ]'
check "큐 1"                 '[ "$(nq)" = 1 ]'
touch -d '1 hour ago' "$T/netsync.state"
FAKE_RC=0 "$NT" --params "$P" restart --msg "오래된 상태" >/dev/null 2>&1
check "오래된 down 은 믿지 않고 보냈다" '[ "$(ncall)" = 1 ]'

echo "[6] --dry-run 은 큐·표식·메일기 무접촉"
reset; FAKE_RC=5 "$NT" --params "$P" chain_down --msg "dry" --dry-run >/dev/null 2>&1
check "메일기 0"             '[ "$(ncall)" = 0 ]'
check "큐 0"                 '[ "$(nq)" = 0 ]'
check "표식 없음"            '[ ! -e "$T/.notify-chain_down.last" ]'

echo "[7] 알람은 메일과 무관하게 먼저 (rate_high, 메일 망 실패)"
reset; FAKE_RC=5 "$NT" --params "$P" rate_high --msg "40 kHz" >/dev/null 2>&1
check "알람 호출"            'grep -q -- "--raise rate_high : 40 kHz" "$T/alarm.calls"'
check "메일은 큐로"          '[ "$(nq)" = 1 ]'

echo "[8] --force-alarm : on_disk_low=mail 이어도 알람까지"
reset; FAKE_RC=0 "$NT" --params "$P" disk_low --msg "/Data_ssd 여유 13 GB" >/dev/null 2>&1
check "알람 없음 (기본)"     '[ ! -s "$T/alarm.calls" ]'
rm -f "$T"/.notify-*.last
FAKE_RC=0 "$NT" --params "$P" disk_low --msg "/Data_ssd 여유 13 GB" --force-alarm >/dev/null 2>&1
check "알람 호출"            'grep -q "disk_low" "$T/alarm.calls"'
check "메일도"               '[ "$(ncall)" = 2 ]'

echo "[9] supervisor_down 은 기본이 알람 + 메일, 전문가 사건이면 both"
reset; out=$("$NT" --params "$P" supervisor_down --msg "FATAL" --dry-run 2>&1)
check "알람"                 'printf "%s" "$out" | grep -q "\[DRY\] 알람 : supervisor_down"'
check "메일 -> both"         'printf "%s" "$out" | grep -q "메일 -> both"'

echo "[9b] standby_retry : 기본은 로그만 (메일·알람·큐 없음), on_standby_retry = mail 이면 메일"
reset; FAKE_RC=0 "$NT" --params "$P" standby_retry --run 4433 --msg "재시도 3" >/dev/null 2>&1
check "메일기 0 · 큐 0 · 알람 0"  '[ "$(ncall)" = 0 ] && [ "$(nq)" = 0 ] && [ ! -s "$T/alarm.calls" ]'
check "로그에는 남는다 (act=none)" 'grep -q "event=standby_retry run=4433 act=none" "$NOTIFY_LOG"'
cp "$P" "$P.sr"; echo "on_standby_retry = mail" >> "$P.sr"
FAKE_RC=0 "$NT" --params "$P.sr" standby_retry --run 4433 --msg "재시도 4" >/dev/null 2>&1
check "켜면 메일 1"              '[ "$(ncall)" = 1 ]'

echo "[10] 쌓인 메일을 mailq-send 가 그대로 내보낸다 (형식 호환)"
reset; FAKE_RC=5 "$NT" --params "$P" chain_down --run 7 --msg "통합" >/dev/null 2>&1
cat > "$T/fake_send.sh" <<'S'
#!/bin/bash
echo "SEND $*" >> "$CALLS"; exit 0
S
chmod +x "$T/fake_send.sh"; : > "$T/mq.params"
MAILQ_DIR=$T/MAILQ MAILQ_PARAMS=$T/mq.params MAILQ_SENDER=$T/fake_send.sh MAILQ_LOG=$T/mq.log MAILQ_LOCK=$T/.mq.lock bash "$MQ" >/dev/null 2>&1
check "보냈다 (sent/)"       '[ "$(find "$T/MAILQ/sent" -name "*.mail" | wc -l)" = 1 ]'
check "수신자 both · 제목 그대로" 'grep -q "^SEND .*--to both --subject chain_down run 7 - 통합" "$CALLS"'

echo "[11] 종료코드는 언제나 0 (큐 디렉터리를 못 만들어도)"
reset; NOTIFY_MAILQ=/proc/no/such FAKE_RC=5 "$NT" --params "$P" chain_down --msg "x" >/dev/null 2>&1; rc=$?
check "rc 0"                 '[ "$rc" -eq 0 ]'
check "로그에 WARN"          'grep -q "큐에도 못 쌓았다" "$NOTIFY_LOG"'

echo "[12] 드릴 중 (플래그를 산 pid 가 쥐고 있다) : 책임자에게만 · [DRILL] · 알람 없음"
reset; printf 'pid=%s\npstart=%s\nstart=%s\nrun=4440\nplan=offline-full\n' "$$" "$(pst $$)" "$(date +%s)" > "$T/drill.active"
out=$("$NT" --params "$P" chain_down --run 4441 --msg "드릴" --dry-run 2>&1)
check "dry : 전문가 사건인데 routine"    'printf "%s" "$out" | grep -q "메일 -> routine : \[DRILL\] chain_down run 4441 - 드릴"'
check "dry : 본문 머리에 드릴 중 발생"   'printf "%s" "$out" | sed -n "/--- 본문 ---/{n;p}" | grep -q "자율 복구 드릴 중 발생 (pid $$ · plan offline-full"'
FAKE_RC=0 "$NT" --params "$P" restart --run 4441 --msg "드릴 2" >/dev/null 2>&1
check "메일기 --to routine · 제목 [DRILL]" 'grep -q -- "--to routine --subject \[DRILL\] restart run 4441 - 드릴 2" "$CALLS"'
check "로그에 drill=1"                  'grep -q "event=restart run=4441 act=mail drill=1" "$NOTIFY_LOG"'
FAKE_RC=0 "$NT" --params "$P" rate_high --msg "40 kHz" >/dev/null 2>&1
FAKE_RC=0 "$NT" --params "$P" supervisor_down --msg "FATAL" --force-alarm >/dev/null 2>&1
FAKE_RC=0 "$NT" --params "$P" recovery_failed --msg "x" >/dev/null 2>&1
check "알람 0 (rate_high · --force-alarm · recovery_failed)" '[ ! -s "$T/alarm.calls" ]'
check "recovery_failed 도 routine"     'grep -q -- "--to routine --subject \[DRILL\] recovery_failed" "$CALLS"'
check "전문가(expert·both) 수신 0 회"  '! grep -qE -- "--to (expert|both)" "$CALLS"'
reset; printf 'pid=%s\npstart=%s\n' "$$" "$(pst $$)" > "$T/drill.active"; echo "net=down" > "$T/netsync.state"
FAKE_RC=0 "$NT" --params "$P" chain_down --msg "큐" >/dev/null 2>&1
f=$(ls "$T"/MAILQ/*.mail 2>/dev/null | head -1)
check "망 단절 큐에도 routine · [DRILL]" '[ "$(sed -n 2p "$f")" = "to: routine" ] && head -1 "$f" | grep -q "^subject: \[DRILL\] chain_down"'

echo "[13] 죽은 플래그 · 오래된 플래그 · 깨진 플래그는 드릴이 아니다 (전문가 메일을 막지 않는다)"
reset; printf 'pid=999999\n' > "$T/drill.active"
out=$("$NT" --params "$P" chain_down --msg "죽은" --dry-run 2>&1)
check "죽은 pid -> both · 접두어 없음"  'printf "%s" "$out" | grep -q "메일 -> both : chain_down - 죽은"'
printf 'pid=%s\npstart=%s\n' "$$" "$(pst $$)" > "$T/drill.active"; touch -d '2 days ago' "$T/drill.active"
out=$("$NT" --params "$P" chain_down --msg "오래된" --dry-run 2>&1)
check "24 h 넘은 플래그 -> both"         'printf "%s" "$out" | grep -q "메일 -> both : chain_down - 오래된"'
printf 'pid=%s\npstart=1\n' "$$" > "$T/drill.active"
out=$("$NT" --params "$P" chain_down --msg "재사용" --dry-run 2>&1)
check "pid 는 살았으나 pstart 가 다르다 (pid 재사용) -> both" 'printf "%s" "$out" | grep -q "메일 -> both : chain_down - 재사용"'
printf 'pid=%s\n' "$$" > "$T/drill.active"
out=$("$NT" --params "$P" chain_down --msg "옛서식" --dry-run 2>&1)
check "pstart 없고 그 pid 가 autonomy-drill 이 아니다 -> both" 'printf "%s" "$out" | grep -q "메일 -> both : chain_down - 옛서식"'
printf 'garbage\n' > "$T/drill.active"
out=$("$NT" --params "$P" rate_high --msg "깨진" --dry-run 2>&1)
check "pid 없는 플래그 -> 알람 그대로"   'printf "%s" "$out" | grep -q "\[DRY\] 알람 : rate_high"'

echo "[14] params 의 drill_flag 를 읽는다 (환경변수 DRILL_FLAG 가 없을 때)"
reset; printf 'pid=%s\npstart=%s\n' "$$" "$(pst $$)" > "$T/other.flag"; cp "$P" "$P.df"; echo "drill_flag = $T/other.flag   # 주석" >> "$P.df"
out=$(env -u DRILL_FLAG "$NT" --params "$P.df" chain_down --msg "키" --dry-run 2>&1)
check "params 경로의 플래그로 드릴 판정" 'printf "%s" "$out" | grep -q "메일 -> routine : \[DRILL\] chain_down - 키"'
out=$("$NT" --params "$P.df" chain_down --msg "환경" --dry-run 2>&1)
check "환경변수가 이긴다 (없는 파일 -> 드릴 아님)" 'printf "%s" "$out" | grep -q "메일 -> both : chain_down - 환경"'

echo; echo "PASS $PASS  FAIL $FAIL"
[ "$FAIL" -eq 0 ]
