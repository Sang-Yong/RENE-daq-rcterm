#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  netsync.sh 시험 : up -> down (연속 2 회) · down -> up 때 밀린 것 내보내기 · 상태 읽기 · dry-run.
#  ★ 망에 붙지 않는다 (NETSYNC_PROBE 가짜). 내보내는 쪽(mailq-send · sheetlog-auto · backup-sheetlog ·
#    reactor-power-log · websummary · daq-notify)도 전부 가짜. 진짜 메일·시트·crontab 무접촉.
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
SUT=$DIR/scripts/netsync.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

#  가짜 검사 : $T/net 이 있으면 dns·smtp·sheets 성공. khu 는 $T/khu 가 있으면
cat > "$T/probe" <<P
#!/bin/bash
case "\$1" in khu) [ -e "$T/khu" ] ;; *) [ -e "$T/net" ] ;; esac
P
chmod +x "$T/probe"
mk() { printf '#!/bin/bash\necho "%s $*" >> "%s/actions"\n%s\nexit 0\n' "$1" "$T" "${2:-}" > "$T/$1"; chmod +x "$T/$1"; }
mk mailq      'rm -f '"$T"'/Q/*.mail'
mk sheetlog   'echo "2026-11-05 16:07:04 [OK] 등재 3 런 -> A404:S406  (3행)  (--force)"'
mk backupsheet; mk reactor; mk websummary
#  가짜 daq-notify : 사건을 적고, netsync-lib 로 망 단절이면 '큐' 라고 적는다 (진짜 daq-notify 의 동작을 흉내)
cat > "$T/notify" <<N
#!/bin/bash
. "$DIR/scripts/netsync-lib.sh"
ev=\$3; netsync_is_down && how=queued || how=sent
echo "\$ev \$how \$*" >> "$T/notify.calls"
N
chmod +x "$T/notify"; mkdir -p "$T/Q"
export NETSYNC_PROBE=$T/probe NETSYNC_STATE=$T/state NETSYNC_LOG=$T/log NETSYNC_LOCK=$T/.lock \
       NETSYNC_NOTIFY=$T/notify NETSYNC_MAILQ_CMD=$T/mailq NETSYNC_SHEETLOG_CMD=$T/sheetlog \
       NETSYNC_BACKUPSHEET_CMD=$T/backupsheet NETSYNC_REACTOR_CMD=$T/reactor NETSYNC_WEBSUMMARY_CMD=$T/websummary \
       NETSYNC_QUEUES=$T/Q NETSYNC_BG=0
run() { bash "$SUT" "$@" >"$T/out" 2>&1; }
net() { sed -n 's/^net=//p' "$T/state"; }

echo "[1] 처음 · 망 정상 -> net=up, 아무것도 안 한다"
touch "$T/net" "$T/khu"; run
check "net=up"                   '[ "$(net)" = up ]'
check "내보내기 없음 · 메일 없음" '[ ! -e "$T/actions" ] && [ ! -e "$T/notify.calls" ]'
check "검사 결과 기록"           'grep -q "^khu=ok" "$T/state" && grep -q "^smtp=ok" "$T/state"'

echo "[2] 한 번 실패는 아직 up (흔들림)"
rm -f "$T/net"; run
check "net=up · fails=1"         '[ "$(net)" = up ] && grep -q "^fails=1" "$T/state"'
check "메일 없음"                '[ ! -e "$T/notify.calls" ]'

echo "[3] 두 번 연속 실패 -> down, net_down 은 큐로"
run
check "net=down"                 '[ "$(net)" = down ]'
check "net_down 한 통 (큐)"      '[ "$(grep -c "^net_down queued" "$T/notify.calls")" = 1 ]'
. "$DIR/scripts/netsync-lib.sh"
check "netsync_is_down 참"       'netsync_is_down'
run
check "계속 down 이어도 메일은 더 없다" '[ "$(wc -l < "$T/notify.calls")" = 1 ]'

echo "[4] down -> up : 밀린 것을 내보내고 복귀 메일 한 통"
touch "$T/Q/a.mail" "$T/Q/b.mail"
sed -i "s/^since=.*/since=$(( $(date +%s) - 5400 ))/" "$T/state"
touch "$T/net"; run
check "net=up"                   '[ "$(net)" = up ]'
check "mailq-send 불림"          'grep -q "^mailq" "$T/actions"'
check "sheetlog-auto --force"    'grep -q "^sheetlog --force" "$T/actions"'
check "backup-sheetlog · reactor · websummary" 'grep -q "^backupsheet" "$T/actions" && grep -q "^reactor" "$T/actions" && grep -q "^websummary" "$T/actions"'
check "순서 : 메일 큐가 먼저"    '[ "$(head -1 "$T/actions" | cut -d" " -f1)" = mailq ]'
check "복귀 메일은 바로 (큐 아님)" 'grep -q "^net_restored sent" "$T/notify.calls"'
check "본문 : 단절 1시간 30분"   'grep "^net_restored" "$T/notify.calls" | grep -q "단절 1시간 30분"'
check "본문 : 밀린 메일 2 통 중 2 통" 'grep "^net_restored" "$T/notify.calls" | grep -q "밀린 메일 2 통 중 2 통 보냄"'
check "본문 : 시트 등재 3 런"    'grep "^net_restored" "$T/notify.calls" | grep -q "시트 등재 3 런"'
check "netsync_is_down 거짓"     '! netsync_is_down'
: > "$T/actions"; run
check "계속 up 이면 내보내기 없음" '[ ! -s "$T/actions" ]'

echo "[5] --dry-run 은 상태를 안 바꾸고 내보내지 않는다"
cp "$T/state" "$T/state.before"; rm -f "$T/net"; run --dry-run; run --dry-run
check "상태 그대로"              'cmp -s "$T/state" "$T/state.before"'
check "메일 더 없음"             '[ "$(grep -c . "$T/notify.calls")" = 2 ]'
check "미리보기를 보인다"        'grep -q "검사 : dns=fail" "$T/out"'

echo "[6] --status 는 읽기 전용, 망에 붙지 않는다"
printf '#!/bin/bash\necho PROBED >> "%s/probed"\nexit 0\n' "$T" > "$T/probe2"; chmod +x "$T/probe2"
NETSYNC_PROBE=$T/probe2 run --status
check "검사하지 않았다"          '[ ! -e "$T/probed" ]'
check "상태 그대로"              'cmp -s "$T/state" "$T/state.before"'
check "망 줄"                    'grep -q "망        : up" "$T/out"'

echo "[7] 오래된 down 상태는 netsync_is_down 이 믿지 않는다 (cron 이 죽었을 때)"
printf 'net=down\n' > "$T/old.state"; touch -d '2 hours ago' "$T/old.state"
check "오래된 down -> 거짓"      '! NETSYNC_STATE=$T/old.state netsync_is_down'

echo "[8] 겹쳐 돌지 않는다"
exec 8>"$T/.lock"; flock -n 8; cp "$T/state" "$T/s2"; run
check "잠금이 있으면 아무것도 안 바꾼다" 'cmp -s "$T/state" "$T/s2"'
exec 8>&-

echo "[9] cron 환경 (env -i), 종료코드 0"
env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$T" NETSYNC_PROBE=$T/probe NETSYNC_STATE=$T/state NETSYNC_LOG=$T/log \
   NETSYNC_LOCK=$T/.lock NETSYNC_NOTIFY=$T/notify NETSYNC_MAILQ_CMD=$T/mailq NETSYNC_SHEETLOG_CMD=$T/sheetlog \
   NETSYNC_BACKUPSHEET_CMD=$T/backupsheet NETSYNC_REACTOR_CMD=$T/reactor NETSYNC_WEBSUMMARY_CMD=$T/websummary \
   NETSYNC_QUEUES=$T/Q NETSYNC_BG=0 bash "$SUT" >/dev/null 2>&1; rc=$?
check "rc 0"                     '[ "$rc" = 0 ]'
check "점검 시각이 갱신됐다"     '[ "$(sed -n s/^checked=//p "$T/state")" -ge "$(( $(date +%s) - 10 ))" ]'

echo; echo "PASS $PASS  FAIL $FAIL"
[ "$FAIL" -eq 0 ]
