#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  sheetlog-auto.sh 시험 : 실패 메일은 같은 사유로 한 번만 · 망 단절이면 건너뛴다.
#  ★ 구글 시트 · 실메일 · 운영 로그 무접촉. append_runs.py · daq-notify 를 가짜로 (SHEETLOG_* 환경변수).
#    가짜 도구의 출력은 실물 append_runs.py 의 print 문 형식 그대로 ('추가 대상 : N 런 (a ~ b)', "['4432', ...", '기록함 : …').
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
SUT=$DIR/scripts/sheetlog-auto.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$T/RAW/004432/PRD"
: > "$T/RAW/004432/FADC_004432.root.00000"; : > "$T/RAW/004432/PRD/PRD_004432.00000.root"
cat > "$T/fake_append.py" <<'PY'
import os, sys
with open(os.environ["TCALLS"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
if "--commit" in sys.argv:
    r = os.environ.get("FAKE_COMMIT", "ok")
    if r == "ok":
        print("기록함 : A404:S404  (1행)")
    else:
        print("gspread.exceptions.APIError: " + r)
        sys.exit(1)
else:
    if os.environ.get("FAKE_ZERO"):
        print("건너뜀(0 사건) 5 런 : 4441 4442 4443 4444 4445")   # 실물 append_runs.py 의 print 형식
    print("추가 대상 : 1 런 (4432 ~ 4432)")
    print("['4432', '2026-11-04', '13:07:06']")
PY
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/notify.calls"\nexit 0\n' "$T" > "$T/notify"; chmod +x "$T/notify"
export SHEETLOG_TOOL=$T/fake_append.py SHEETLOG_NOTIFY=$T/notify SHEETLOG_STATE=$T/state SHEETLOG_LOG=$T/log \
       SHEETLOG_LOCK=$T/.lock SHEETLOG_FAILSTATE=$T/failstate SHEETLOG_ROOTS=$T/RAW \
       NETSYNC_STATE=$T/netsync.state TCALLS=$T/tool.calls DRILL_FLAG=$T/drill.active
nmail() { [ -r "$T/notify.calls" ] && grep -c ' sheetlog ' "$T/notify.calls" || echo 0; }
go() { FAKE_COMMIT=$1 bash "$SUT" --force >/dev/null 2>&1; }

echo "[1] 등재 성공 -> 메일 1 · 실패 표식 없음"
go ok
check "메일 1"                    '[ "$(nmail)" = 1 ]'
check "성공 문구"                 'grep -q "시트에 1 런 등재 -- A404:S404" "$T/notify.calls"'
check "failstate 없음"            '[ ! -e "$T/failstate" ]'

echo "[2] 실패 -> 메일 1 (처음)"
go "Range ('Y2026B'!A359:S359) exceeds grid limits. Max rows: 358"
check "메일 2"                    '[ "$(nmail)" = 2 ]'
check "failstate 생김"            '[ -s "$T/failstate" ]'

echo "[3] 같은 사유 (행 번호만 다름) -> 메일 생략"
go "Range ('Y2026B'!A360:S360) exceeds grid limits. Max rows: 358"
check "메일 그대로 2"             '[ "$(nmail)" = 2 ]'
check "로그에 생략"               'grep -q "같은 사유의 실패라 메일은 생략" "$T/log"'

echo "[4] 다른 사유 -> 다시 알린다"
go "invalid_grant: Token has been expired or revoked."
check "메일 3"                    '[ "$(nmail)" = 3 ]'

echo "[5] 성공하면 표식을 지우고, 그 뒤의 실패는 다시 알린다"
go ok
check "메일 4 · failstate 없음"   '[ "$(nmail)" = 4 ] && [ ! -e "$T/failstate" ]'
go "invalid_grant: Token has been expired or revoked."
check "메일 5"                    '[ "$(nmail)" = 5 ]'

echo "[6] netsync 가 망 단절이라고 적어 두었으면 도구를 부르지도 않는다"
: > "$T/tool.calls"; echo "net=down" > "$T/netsync.state"; go ok
check "도구 호출 0"               '[ ! -s "$T/tool.calls" ]'
check "로그에 망 단절"            'grep -q "망 단절 (netsync net=down)" "$T/log"'
out=$(bash "$SUT" --status 2>&1)
check "--status 는 단절 중에도 보인다" 'printf "%s" "$out" | grep -q "밀린 런"'
touch -d '1 hour ago' "$T/netsync.state"; : > "$T/tool.calls"; go ok
check "오래된 down 은 믿지 않고 시도" '[ -s "$T/tool.calls" ]'

echo "[7] cron 환경 (env -i)"
rm -f "$T/netsync.state"
env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$T" SHEETLOG_TOOL=$T/fake_append.py SHEETLOG_NOTIFY=$T/notify \
   SHEETLOG_STATE=$T/state SHEETLOG_LOG=$T/log SHEETLOG_LOCK=$T/.lock SHEETLOG_FAILSTATE=$T/failstate \
   SHEETLOG_ROOTS=$T/RAW NETSYNC_STATE=$T/netsync.state TCALLS=$T/tool.calls FAKE_COMMIT=ok bash "$SUT" --force >/dev/null 2>&1; rc=$?
check "rc 0 (성공)"               '[ "$rc" -eq 0 ]'
check "등재함"                    'grep -q "\[OK\] 등재 1 런" "$T/log"'

pst() { awk '{ sub(/.*\) /, ""); print $20 }' "/proc/$1/stat"; }    # 플래그의 pstart (drill_proc_start 와 같은 값)
echo "[8] 드릴 중이면 --force 여도 쓰지 않는다 ([SKIP] drill)"
rm -f "$T/netsync.state"; printf 'pid=%s\npstart=%s\nrun=4440\nplan=offline-full\n' "$$" "$(pst $$)" > "$T/drill.active"
: > "$T/tool.calls"; n0=$(nmail); FAKE_COMMIT=ok bash "$SUT" --force >/dev/null 2>&1; rc=$?
check "rc 0"                      '[ "$rc" -eq 0 ]'
check "도구 호출 0 · 메일 0"       '[ ! -s "$T/tool.calls" ] && [ "$(nmail)" = "$n0" ]'
check "로그에 [SKIP] drill"       'grep -q "\[SKIP\] drill -- 자율 복구 드릴 중 (pid $$" "$T/log"'
FAKE_COMMIT=ok bash "$SUT" --dry-run >/dev/null 2>&1
check "--dry-run 도 건너뛴다"      '[ ! -s "$T/tool.calls" ]'
out=$(bash "$SUT" --status 2>&1)
check "--status 에 드릴 표시"     'printf "%s" "$out" | grep -q "★ 드릴 중       : pid $$ plan offline-full"'
printf 'pid=999999\n' > "$T/drill.active"; : > "$T/tool.calls"; go ok
check "죽은 플래그면 등재한다"     'grep -q -- "--commit" "$T/tool.calls"'
rm -f "$T/drill.active"

echo "[9] 0 사건 런을 건너뛰면 로그에 남긴다 (2026-11-08 run 4441~4445)"
FAKE_ZERO=1 FAKE_COMMIT=ok bash "$SUT" --force >/dev/null 2>&1; rc=$?
check "rc 0"                      '[ "$rc" -eq 0 ]'
check "로그에 건너뜀(0 사건)"     'grep -q "건너뜀(0 사건) 5 런 : 4441 4442 4443 4444 4445 -- 시트에 싣지 않는다" "$T/log"'
out=$(FAKE_ZERO=1 bash "$SUT" --status 2>&1)
check "--status 에도 보인다"      'printf "%s" "$out" | grep -q "건너뜀(0 사건) 5 런"'

echo; echo "PASS $PASS  FAIL $FAIL"
[ "$FAIL" -eq 0 ]
