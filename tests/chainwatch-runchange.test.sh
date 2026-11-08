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
#  ★ 바깥 명령을 전부 가짜로. 진짜 tmux send-keys · kill · df 가 나가지 않게, 운영 cron 과 잠금이 겹치지 않게
#    (잠금이 겹치면 회차가 '이미 실행 중' 으로 빠져 시험이 들쭉날쭉 깨졌다 -- 2026-11-05 실측 4/41)
mkdir -p "$T/bin"
printf '#!/bin/bash\nexit 1\n' > "$T/bin/false"; chmod +x "$T/bin/false"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/true";  chmod +x "$T/bin/true"
: > "$T/ps.txt"; : > "$T/df.txt"
export CHAINWATCH_LOCK=$T/.lock CHAINWATCH_TMUX=$T/bin/false CHAINWATCH_PGREP=$T/bin/false \
       CHAINWATCH_KILL=$T/bin/false CHAINWATCH_MOUNTPOINT=$T/bin/true CHAINWATCH_PS=$T/ps.txt \
       CHAINWATCH_DF_FILE=$T/df.txt CHAINWATCH_SUPLOG=$T/sup.log CHAINWATCH_PROC=$T/proc \
       NETSYNC_STATE=$T/netsync.state

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

echo "[R] 계수율 비정상 기준 30,000 Hz (2026-09-14) — 20,000 이상 경고만 · 30,000 이상 즉시 알림"
hbr() {  # run daqtime ar
   { echo "time=$(date +%s)"; echo "pid=1"; echo "phase=running"; echo "run=$1"; echo "subrun=3"
     echo "state=Running"; echo "daqtime=$2"; echo "totev=100"; echo "ndaq=2"
     echo "daq0=FADCDAQ n=1000 sr=$3 ar=$3"; echo "daq1=SADCDAQ n=1000 sr=$3 ar=$3"; } > "$HB"
}
rm -f "$ST"; hbr 4350 400 300; run --min-rate 100
check "300 Hz : 알림 없음"                   '[ ! -s "$CALLS" ]'
check "300 Hz : 경고 문구 없음"              '! grep -q "계수율이 높습니다" "$LOG"'
hbr 4350 460 25000; run --min-rate 100
check "25,000 Hz : 알림 없음 (경고만)"       '[ ! -s "$CALLS" ]'
check "25,000 Hz : 한글 경고 문구가 로그에"  'grep -q "경고 : 계수율이 높습니다 — ADC 별(순간 sr) 최댓값 25000 Hz" "$LOG"'
check "25,000 Hz : --status 에 경고"         '"$CW" --params /nonexistent --status --heartbeat "$HB" --state "$ST" --log "$LOG" --dbfile "$DB" 2>/dev/null | grep -q "★ 경고"'
hbr 4350 520 35000; run --min-rate 100
check "35,000 Hz : rate_high 즉시 알림 (연속 조건 없이)" 'grep -q " rate_high --msg" "$CALLS"'
check "35,000 Hz : 사유가 한글"              'grep -q "계수율 비정상 : ADC 별 계수율(순간 sr) 최댓값 35000 Hz 가 알람 기준 30000 Hz 이상" "$CALLS"'
hbr 4350 580 35000; run --min-rate 100
check "이어지면 재알림 간격 안에는 생략"     '[ ! -s "$CALLS" ]'
hbr 4350 640 400; run --min-rate 100
check "돌아오면 해소 기록"                   'grep -q "rate_high 해소됨" "$LOG"'
#  도배 방지 표식이 alarm_state 옆에 남으므로 (dry-run 도 남긴다) 운영 디렉터리를 더럽히지 않게 임시 params 를 준다
printf 'alarm_state = %s/daq-alarm.state\non_rate_high = both\nmail_to = boss@example.org\n' "$T" > "$T/nt.params"
out=$("$NT" --params "$T/nt.params" rate_high --msg "시험" --dry-run 2>&1)
check "daq-notify rate_high : 알람 (기본 both)"   'printf "%s" "$out" | grep -q "\[DRY\] 알람 : rate_high"'
check "daq-notify rate_high : 책임자 메일"        'printf "%s" "$out" | grep -qE "routine|책임자"'

echo "[Z] 사건 0 인 런 (2026-11-08 run 4441~4445) — daqtime=0 이어도 벽시계 warmup 뒤 판정한다"
#  ★ 픽스처는 실물 heartbeat 를 그대로 옮긴 것이다 (/Data/LOG/rcterm.hb, 11-08 14:50 run 4445)
hbz() {  # run
   { echo "time=$(date +%s)"; echo "pid=3167942"; echo "phase=running"; echo "run=$1"; echo "subrun=12"
     echo "state=Running"; echo "statebit=3"; echo "error=0"; echo "status=8"; echo "daqtime=0"; echo "totev=0"; echo "ndaq=2"
     echo "daq0=FADCDAQ n=0 sr=0 ar=0"; echo "daq1=SADCDAQ n=0 sr=0 ar=0"; } > "$HB"
}
rm -f "$ST"; now=$(date +%s)
sqlite3 "$DB" "insert or replace into runcatalog values(4439,1,'$(ts $((now-86800)))','$(ts $((now-430)))',560000000,86400.0,'desc A');
               insert or replace into runcatalog values(4440,NULL,NULL,NULL,NULL,NULL,'desc A');"
printf 'last_run=4439\n' > "$ST"
hbz 4440; run --min-rate 100 --consecutive 1
check "처음 본 회차 : rate_low 없음 (warmup)"  '! grep -q " rate_low " "$CALLS"'
check "run_first_seen 에 4440 이 남는다"        'grep -q "^run_first_seen=4440 [0-9]" "$ST"'
check "last_run 은 아직 4439"                   '[ "$(sed -n s/^last_run=//p "$ST")" = 4439 ]'
#  4 분이 지난 것으로 만든다 (5 분 cron 의 다음 회차)
sed -i "s/^run_first_seen=.*/run_first_seen=4440 $((now-400))/" "$ST"
hbz 4440; run --min-rate 100 --consecutive 1
check "벽시계 warmup 뒤 rate_low 가 나간다"     'grep -q " rate_low --msg" "$CALLS"'
check "사유에 모두 0 Hz -> HV 부터"            'grep -q "모두 0 Hz" "$CALLS" && grep -q "PMT HV" "$CALLS"'
check "런 교체 판정도 돈다 (last_run=4440)"     '[ "$(sed -n s/^last_run=//p "$ST")" = 4440 ]'
check "시작 시각 = 처음 본 시각 -> rotate"      'grep -Eq "(^| )rotate " "$CALLS"'
check "run_first_seen 은 그대로 (다시 안 씀)"   'grep -q "^run_first_seen=4440 $((now-400))$" "$ST"'
#  daqtime 이 0 이 아닌 정상 런은 여전히 daqtime 으로 판정된다 (처음 본 회차라도)
rm -f "$ST"; printf 'last_run=4440\n' > "$ST"; hbr 4450 400 50; run --min-rate 100 --consecutive 1
check "정상 heartbeat 는 daqtime 으로 곧바로 판정" 'grep -q " rate_low --msg" "$CALLS"'
check "정상 계수율 0 이 아니면 HV 문구는 없다"   '! grep -q "모두 0 Hz" "$CALLS"'
printf 'alarm_state = %s/daq-alarm.state\non_rate_low = mail\nmail_to = boss@example.org\n' "$T" > "$T/nt2.params"
out=$("$NT" --params "$T/nt2.params" rate_low --msg "시험" --dry-run 2>&1)
check "daq-notify rate_low 본문에 '둘 다 0 이면 HV'" 'printf "%s" "$out" | grep -q "둘 다 0" && printf "%s" "$out" | grep -q "GECO"'

echo; echo "PASS $PASS  FAIL $FAIL"
[ "$FAIL" -eq 0 ]
