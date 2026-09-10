#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  chainwatch 의 런 교체 감지 + daq-notify 의 수신자 규칙 + send_mail --to both
#
#  하드웨어 · 실제 heartbeat · 실제 DB · 실제 메일을 전혀 건드리지 않는다.
#  가짜 heartbeat / 가짜 runcatalog.db / 가짜 notify 를 mktemp 안에 만든다.
#
#  규칙 (2026-09-09 사용자 지시)
#     정상 런 교체            -> rotate   -> 책임자만
#     문제 뒤 다시 정상 가동  -> resumed  -> 전문가 목록 + 책임자
#     문제 (restart 등)       ->             전문가 목록 + 책임자
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
CW=$DIR/scripts/chainwatch.sh
NT=$DIR/scripts/daq-notify.sh
SM=$DIR/tools/notify/send_mail.py
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

HB=$T/rcterm.hb; ST=$T/state; LOG=$T/log; DB=$T/runcatalog.db; CALLS=$T/calls
cat > "$T/notify.sh" <<'N'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
if [ -n "${DETAIL_COPY:-}" ]; then for a in "$@"; do :; done; fi
# --detail-file 의 내용을 보관한다
while [ $# -gt 0 ]; do case "$1" in --detail-file) cat "$2" > "$CALLS.detail"; shift 2 ;; *) shift ;; esac; done
exit 0
N
chmod +x "$T/notify.sh"; export CALLS; export NOTIFY_LOG=$T/notify.log

sqlite3 "$DB" "create table runcatalog(runnum integer primary key, onlbit integer, stime integer, etime integer, nfadc integer, tfadc real, rundesc text);"
hb() {  # run daqtime [phase]
   { echo "time=$(date +%s)"; echo "pid=1"; echo "phase=${3:-running}"; echo "run=$1"; echo "subrun=3"
     echo "state=Running"; echo "daqtime=$2"; echo "totev=100"; echo "ndaq=2"
     echo "daq0=FADCDAQ n=1000 sr=700.0 ar=712.0"; echo "daq1=SADCDAQ n=1000 sr=700.0 ar=711.5"; } > "$HB"
}
run() { : > "$CALLS"; "$CW" --params /nonexistent --gate on --consecutive 99 --heartbeat "$HB" \
          --state "$ST" --log "$LOG" --dbfile "$DB" --notify "$T/notify.sh" --warmup 180 --rotate-gap 600 "$@" >/dev/null 2>&1; }

echo "[1] 처음 보는 런은 조용히 기록만 한다"
hb 4340 300; run
check "알림 없음"        '[ ! -s "$CALLS" ]'
check "last_run=4340"    '[ "$(sed -n s/^last_run=//p "$ST")" = 4340 ]'

echo "[2] 같은 런이 계속 돌면 아무 일도 없다"
hb 4340 9000; run
check "알림 없음"        '[ ! -s "$CALLS" ]'

echo "[3] warmup 전에는 판정을 미룬다 (last_run 도 그대로)"
hb 4341 30; run
check "알림 없음"        '[ ! -s "$CALLS" ]'
check "last_run 그대로"  '[ "$(sed -n s/^last_run=//p "$ST")" = 4340 ]'

echo "[4] 정상 로테이션 : 이전 런 onlbit=1, 간격 30초 -> rotate"
now=$(date +%s)
#  ★ 실제 runcatalog 은 stime/etime 이 'YYYY-MM-DD HH:MM:SS' 텍스트이고, 수집 중인 런은 stime 도 NULL 이다
#    (rcterm 이 마감 때 채운다). 첫 판 픽스처는 epoch 정수라 이 차이를 못 잡아 실전에서 오판했다.
ts() { date -d "@$1" '+%F %T'; }
sqlite3 "$DB" "insert into runcatalog values(4340,1,'$(ts $((now-86400)))','$(ts $((now-330)))',82000000,86000.0,'desc A');
               insert into runcatalog values(4341,NULL,NULL,NULL,NULL,NULL,'desc A');"
hb 4341 300; run       # 새 런 시작 = hb time - daqtime = now-300 -> 간격 30초
check "rotate 호출"      'grep -Eq "(^| )rotate " "$CALLS"'
check "--run 4341"       'grep -q -- "--run 4341" "$CALLS"'
check "resumed 아님"     '! grep -Eq "(^| )resumed( |$)" "$CALLS"'
check "상세에 이전 런"   'grep -q "4340" "$CALLS.detail"'
check "상세에 계수율"    'grep -q "712" "$CALLS.detail"'
check "간격이 계산됨(30초)" 'grep -q "간격 *: 30 초" "$CALLS.detail"'
check "last_run=4341"    '[ "$(sed -n s/^last_run=//p "$ST")" = 4341 ]'

echo "[5] 이전 런이 실패(onlbit=0) -> resumed"
sqlite3 "$DB" "update runcatalog set onlbit=1, stime='$(ts $((now-300)))', etime='$(ts $((now-320)))' where runnum=4341;
               insert into runcatalog values(4342,0,'$(ts $((now-310)))',NULL,NULL,NULL,'desc A');
               insert into runcatalog values(4343,NULL,NULL,NULL,NULL,NULL,'desc A');"
hb 4343 300; run
check "resumed 호출"     'grep -Eq "(^| )resumed " "$CALLS"'
check "rotate 아님"      '! grep -Eq "(^| )rotate( |$)" "$CALLS"'

echo "[6] 이전 런은 정상 마감했지만 간격이 크다(사람이 세웠다 올림) -> resumed"
sqlite3 "$DB" "update runcatalog set onlbit=1, stime='$(ts $((now-7500)))', etime='$(ts $((now-7200)))' where runnum=4343;
               insert into runcatalog values(4344,NULL,NULL,NULL,NULL,NULL,'desc A');"
hb 4344 300; run
check "resumed 호출"     'grep -Eq "(^| )resumed " "$CALLS"'

echo "[7] DB 를 못 읽으면 전문가에게 오보를 내지 않는다 -> rotate (사유 명시)"
hb 4345 300; : > "$CALLS"
"$CW" --params /nonexistent --gate on --consecutive 99 --heartbeat "$HB" --state "$ST" --log "$LOG" \
      --dbfile /nonexistent.db --notify "$T/notify.sh" >/dev/null 2>&1
check "rotate 호출"      'grep -Eq "(^| )rotate " "$CALLS"'
check "사유에 DB"        'grep -qi "db" "$CALLS.detail"'

echo "[8] --dry-run 은 알리지 않고 last_run 도 바꾸지 않는다"
hb 4346 300; run --dry-run
check "알림 없음"        '[ ! -s "$CALLS" ]'
check "last_run 그대로"  '[ "$(sed -n s/^last_run=//p "$ST")" = 4345 ]'

echo "[9] --status 에 last_run 이 보인다"
out=$("$CW" --gate on --heartbeat "$HB" --state "$ST" --dbfile "$DB" --status 2>/dev/null)
check "status 출력"      'printf "%s" "$out" | grep -q "4345"'

echo "[10] daq-notify 수신자 규칙 (params 의 mail_expert_events)"
P=$T/notify.params
cat > "$P" <<EOF2
heartbeat = $HB
alarm_state = $T/alarm.state
smtp_host = x
smtp_user = x
smtp_pass = x
mail_to = boss@example.org
mail_to_expert = a@example.org, b@example.org
mail_expert_events = restart stale recovered recovery_failed fatal chain_down rate_low resumed
on_rotate = mail
on_resumed = mail
EOF2
for ev in rotate; do
   out=$("$NT" --params "$P" $ev --run 4341 --msg 'x' --dry-run 2>/dev/null)
   check "$ev -> routine"   'printf "%s" "$out" | grep -q "메일 -> routine"'
done
for ev in restart resumed recovery_failed chain_down; do
   out=$("$NT" --params "$P" $ev --run 4341 --msg 'x' --dry-run 2>/dev/null)
   check "$ev -> both"      'printf "%s" "$out" | grep -q "메일 -> both"'
done
echo "[11] 기본값(params 에 목록 없음)은 예전과 같다 : recovery_failed·fatal 만 전문가"
rm -f "$T"/.notify-*.last     # [10] 이 남긴 도배 방지 표식(300초)을 지운다
grep -v '^mail_expert_events' "$P" > "$P.2"
out=$("$NT" --params "$P.2" restart --run 1 --dry-run 2>/dev/null)
check "restart -> routine (기본)" 'printf "%s" "$out" | grep -q "메일 -> routine"'
out=$("$NT" --params "$P.2" fatal --run 1 --dry-run 2>/dev/null)
check "fatal -> expert (기본)"    'printf "%s" "$out" | grep -q "메일 -> expert"'

echo "[12] send_mail --to both = 책임자 + 전문가, 중복 제거"
cat > "$T/sm.params" <<EOF3
smtp_host = x
smtp_user = x
smtp_pass = x
mail_to = boss@example.org
mail_to_expert = a@example.org, boss@example.org, b@example.org
EOF3
out=$(python3 "$SM" --params "$T/sm.params" --to both --subject s --dry-run 2>&1)
check "셋 다 있다"       'printf "%s" "$out" | grep -q "boss@example.org, a@example.org, b@example.org"'
check "중복 없음"        '[ "$(printf "%s" "$out" | grep -o "boss@example.org" | wc -l)" = 1 ]'
out=$(python3 "$SM" --params "$T/sm.params" --to routine --subject s --dry-run 2>&1)
check "routine 은 책임자만" '! printf "%s" "$out" | grep -q "a@example.org"'

echo; echo "PASS $PASS  FAIL $FAIL"
[ "$FAIL" -eq 0 ]
