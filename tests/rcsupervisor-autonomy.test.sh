#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  rcsupervisor 자율 복구 시험 (2026-11-05)
#
#  가짜 rcterm · 가짜 recover · 가짜 notify 로만 돈다.
#  ★ 하드웨어·포트·운영 heartbeat(/Data/LOG/rcterm.hb)·DB·메일 무접촉.
#    --no-db · --no-socket-check · 별도 heartbeat · 별도 로그 디렉터리.
#
#  사용 : tests/rcsupervisor-autonomy.test.sh [rcsupervisor 경로]
#         (기본 : <저장소>/install/bin/rcsupervisor)
# ---------------------------------------------------------------------
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
SUP=${1:-$REPO/install/bin/rcsupervisor}
[ -x "$SUP" ] || { echo "rcsupervisor 없음 : $SUP (./build.sh 먼저)"; exit 1; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
chk()  { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

ROOT=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$ROOT"' EXIT

# ---- 가짜 rcterm ----------------------------------------------------
#  계획 파일 $FAKE_DIR/plan/<run> (셸 변수) :
#    EXIT=<n> LIFE=<s>   LIFE 초 뒤 스스로 exit n (EXIT 없으면 TERM 까지 산다)
#    ALIGNED=8 FAIL=0    TCB 로그의 DRAM 줄
#    USB=1               FADCDAQ 로그에 LIBUSB_ERROR_IO
#    SR=100              heartbeat 의 순간 계수율
#    CLOSE_TIMEOUT=1     TERM 받을 때 FADCDAQ 로그에 LIBUSB_ERROR_TIMEOUT
#    REAL_TCB=<파일>     TCB 로그를 실물 사본으로 (tests/fixtures/supervisor-logs)
#    REAL_FADC=<파일>    FADCDAQ 로그를 실물 사본으로
#    NOHB=1              heartbeat 도 로그도 쓰지 않고 곧바로 EXIT (실물 rcterm 의 Init 단계 exit 1)
#    ZERO=1              사건 0 (totev=0 · n=0 · daqtime=0) -- 2026-11-08 run 4441~4445 의 heartbeat 그대로
#    ZERO_FOR=<s>        처음 s 초 동안만 사건 0, 그 뒤 정상
#    FREEZE_AFTER=<s>    s 초 뒤 사건 수가 굳는다 (사건이 있던 런의 stall)
cat > "$ROOT/fake_rcterm.sh" <<'FAKE'
#!/usr/bin/env bash
HB=""; RUN=0; DRY=0
while [ $# -gt 0 ]; do
   case "$1" in
      --heartbeat) HB=$2; shift ;;
      --run)       RUN=$2; shift ;;
      --dry-run)   DRY=1 ;;
   esac
   shift
done
D=$FAKE_DIR
if [ "$DRY" = 1 ]; then
   echo "$RUN" >> "$D/dryruns"
   exit "$(cat "$D/dryrun_rc" 2>/dev/null || echo 0)"
fi
echo "$RUN" >> "$D/launches"
EXIT=""; LIFE=0; ALIGNED=8; FAIL=0; USB=0; SR=100; CLOSE_TIMEOUT=0; REAL_TCB=""; REAL_FADC=""; ZERO=0; ZERO_FOR=0; FREEZE_AFTER=0
[ -r "$D/plan/$RUN" ] && . "$D/plan/$RUN"
[ "${NOHB:-0}" = 1 ] && exit "${EXIT:-1}"
R6=$(printf '%06d' "$RUN")
L=$D/daqlog
{ for i in $(seq 0 $((ALIGNED-1))); do echo "DRAM($i) is aligned, delay = 5, bitslip = 0"; done
  for i in $(seq 1 "$FAIL"); do echo "Fail to align DRAM($i)!"; done; } > "$L/TCB_$R6.log"
echo "FADCDAQ run $RUN" > "$L/FADCDAQ_$R6.log"
echo "SADCDAQ run $RUN" > "$L/SADCDAQ_$R6.log"
[ "$USB" = 1 ] && echo "[ERROR] USB3Read: read error:LIBUSB_ERROR_IO [sid=3]" >> "$L/FADCDAQ_$R6.log"
[ -n "$REAL_TCB" ]  && cp "$REAL_TCB"  "$L/TCB_$R6.log"
[ -n "$REAL_FADC" ] && cp "$REAL_FADC" "$L/FADCDAQ_$R6.log"
N=0; T0=$(date +%s)
hb() {
   local z=$ZERO
   [ "$ZERO_FOR" -gt 0 ] && [ $(( $(date +%s) - T0 )) -lt "$ZERO_FOR" ] && z=1
   if [ "$z" = 1 ]; then
      cat > "$HB.tmp" <<H
time=$(date +%s)
pid=$$
phase=$1
run=$RUN
subrun=0
state=Running
statebit=3
error=0
status=8
daqtime=0
totev=0
ndaq=2
daq0=FADCDAQ n=0 sr=0 ar=0
daq1=SADCDAQ n=0 sr=0 ar=0
H
      mv -f "$HB.tmp" "$HB"; return
   fi
   if [ "$FREEZE_AFTER" -eq 0 ] || [ $(( $(date +%s) - T0 )) -lt "$FREEZE_AFTER" ]; then N=$((N+100)); fi
   cat > "$HB.tmp" <<H
time=$(date +%s)
pid=$$
phase=$1
run=$RUN
subrun=0
state=Running
statebit=3
error=0
status=8
daqtime=$(( $(date +%s) - T0 ))
totev=$((N*2))
ndaq=2
daq0=FADCDAQ n=$N sr=$SR ar=$SR
daq1=SADCDAQ n=$N sr=50.0 ar=50.0
H
   mv -f "$HB.tmp" "$HB"
}
onterm() {
   [ "$CLOSE_TIMEOUT" = 1 ] && echo "[ERROR] USB3Read: read error:LIBUSB_ERROR_TIMEOUT [sid=3]" >> "$L/FADCDAQ_$R6.log"
   hb ended; exit 0
}
trap onterm TERM
hb booting
while :; do
   hb running
   if [ -n "$EXIT" ] && [ $(( $(date +%s) - T0 )) -ge "$LIFE" ]; then exit "$EXIT"; fi
   sleep 0.5 & wait $!
done
FAKE
cat > "$ROOT/fake_recover.sh" <<'REC'
#!/usr/bin/env bash
echo "$(date +%s) $*" >> "$FAKE_DIR/recover.calls"
exit "$(cat "$FAKE_DIR/recover_rc" 2>/dev/null || echo 0)"
REC
cat > "$ROOT/fake_notify.sh" <<'NOT'
#!/usr/bin/env bash
[ "${1:-}" = "--params" ] && shift 2      # 줄을 사건 이름으로 시작하게
echo "$*" >> "$FAKE_DIR/notify.log"
exit 0
NOT
chmod +x "$ROOT"/fake_*.sh

# 한 시험의 샌드박스를 만들고 감시자를 띄운다.  $1 = 이름, 나머지 = 추가 인자
SPID=""
start() {
   local name=$1; shift
   D=$ROOT/$name; mkdir -p "$D/plan" "$D/daqlog" "$D/bin"
   export FAKE_DIR=$D
   : > "$D/notify.log"; : > "$D/sup.log"; : > "$D/hb"
   "$SUP" --rcterm "$ROOT/fake_rcterm.sh" --no-db --run 100 \
      --heartbeat "$D/hb" --log "$D/sup.log" --bindir "$D/bin" \
      --no-socket-check ${STALLOPT:---no-stall-check} \
      --check-period 2 --boot-grace 2 --stale-limit 30 --grace 5 \
      --settle 0 --backoff 0 --margin 0 \
      --rate-poll 1 --rate-cooldown 2 --standby-retry-min 0.05 \
      --daq-logdir "$D/daqlog" --daq-logdir-old "$D/nonexistent" \
      --notify-cmd "$ROOT/fake_notify.sh" --notify-params "$D/np" \
      --recover-cmd "$ROOT/fake_recover.sh" "$@" > "$D/stdout" 2>&1 &
   SPID=$!
}
# 조건이 참이 될 때까지 최대 $1 초
waitfor() { local t=$1; shift; local i=0; while [ $i -lt $((t*5)) ]; do eval "$@" && return 0; sleep 0.2; i=$((i+1)); done; return 1; }
stop_sup() { kill -TERM "$SPID" 2>/dev/null; local i=0; while kill -0 "$SPID" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done; wait "$SPID" 2>/dev/null; RC=$?; }
nlaunch() { [ -r "$D/launches" ] && wc -l < "$D/launches" || echo 0; }
ncalls()  { [ -r "$D/recover.calls" ] && wc -l < "$D/recover.calls" || echo 0; }

echo "== [1] rcterm exit 1 (Init, hb 안 씀) -> 재시작 없음 + standby(config) -> rcterm.hb 무접촉 -> 재개 -> SIGTERM exit 0"
start s1 --run-length 1
# 직전 런 4432 가 1 시간 전에 정상으로 끝나 남긴 heartbeat (실물 모양)
OLD=$(( $(date +%s) - 3600 ))
printf 'time=%s\npid=11111\nphase=ended\nrun=4432\nsubrun=1372\nstate=RunEnd\nstatebit=5\nerror=0\n' $OLD > "$D/hb"
HBSUM=$(md5sum < "$D/hb")
echo "EXIT=1 NOHB=1" > "$D/plan/100"
echo 1 > "$D/dryrun_rc"
waitfor 10 'grep -q "STANDBY (config)" "$D/sup.log"'
chk "exit 1 에서 standby(config)" 'grep -q "STANDBY (config)" "$D/sup.log"'
chk "fatal 알림 'config error, restart pointless'" 'grep -q "^fatal .*config error, restart pointless" "$D/notify.log"'
chk "restart 알림 없음" '! grep -q "^restart" "$D/notify.log"'
waitfor 5 '[ -s "$D/hb.sup" ]'
chk "대기 상태는 hb.sup : phase=standby" 'grep -q "^phase=standby$" "$D/hb.sup"'
chk "hb.sup pid = 감시자 pid" 'grep -q "^pid=$SPID$" "$D/hb.sup"'
chk "hb.sup standby=config" 'grep -q "^standby=config$" "$D/hb.sup"'
sleep 2
chk "★ rcterm.hb 는 한 바이트도 안 바뀜 (time 1 h 전 그대로)" '[ "$(md5sum < "$D/hb")" = "$HBSUM" ]'
( HB=$D/hb; eval "$(sed -n '/^hb_field()/p;/^hb_age()/p' "$REPO/scripts/dataflow.sh")"
  eval "$(sed -n '/^is_acquiring()/,/^}/p' "$REPO/scripts/dataflow.sh")"
  ! is_acquiring 004432 ) && ok "dataflow is_acquiring : run 4432 은 수집 중이 아니다 (리뷰 R4b)" || bad "dataflow 가 4432 를 수집 중으로 본다"
waitfor 8 '[ -r "$D/dryruns" ]'
chk "대기 중 dry-run 으로 확인" '[ -r "$D/dryruns" ]'
chk "dry-run 실패 동안 런 1 개만" '[ "$(nlaunch)" = 1 ]'
echo 0 > "$D/dryrun_rc"
waitfor 10 '[ "$(nlaunch)" -ge 2 ]'
chk "dry-run 통과 -> 재개 (run 101)" 'grep -qx 101 "$D/launches"'
chk "재개하면 hb.sup 를 지운다" '[ ! -e "$D/hb.sup" ]'
waitfor 10 'grep -q "^recovered" "$D/notify.log"'
chk "recovered 는 확인 런의 부팅·DRAM 점검 뒤" 'grep -q "^recovered" "$D/notify.log" && [ "$(grep -n "DRAM check run=101" "$D/sup.log" | cut -d: -f1)" -lt "$(grep -n "notify: recovered" "$D/sup.log" | cut -d: -f1)" ]'
chk "standby_retry 알림" 'grep -q "^standby_retry" "$D/notify.log"'
stop_sup
chk "SIGTERM -> exit 0" '[ "$RC" = 0 ]'

echo "== [2] USB 서명 -> 첫 실패에서 즉시 recover"
start s2 --run-length 1
echo "EXIT=2 LIFE=1 USB=1" > "$D/plan/100"
echo 0 > "$D/recover_rc"
waitfor 15 '[ "$(nlaunch)" -ge 2 ]'
chk "recover 1 회 (한도 5 를 기다리지 않음)" '[ "$(ncalls)" = 1 ]'
chk "로그에 USB signature" 'grep -q "USB signature in run 100 logs (FADCDAQ 1)" "$D/sup.log"'
chk "복구 뒤 run 101" 'grep -qx 101 "$D/launches"'
stop_sup

echo "== [3] USB 서명 없음 -> 즉시 recover 안 함"
start s3 --run-length 1 --max-consec-fail 5
echo "EXIT=2 LIFE=1" > "$D/plan/100"
waitfor 15 '[ "$(nlaunch)" -ge 2 ]'
chk "recover 호출 없음" '[ "$(ncalls)" = 0 ]'
stop_sup

echo "== [4] DRAM 7/8 -> 런 마감 + recover -> 재개"
start s4 --run-length 1
echo "ALIGNED=7" > "$D/plan/100"
echo 0 > "$D/recover_rc"
waitfor 20 '[ "$(nlaunch)" -ge 2 ]'
chk "DRAM not aligned 판정" 'grep -q "UNHEALTHY : DRAM not aligned (is aligned 7/8, Fail to align 0)" "$D/sup.log"'
chk "recover 1 회" '[ "$(ncalls)" = 1 ]'
chk "run 101 재개" 'grep -qx 101 "$D/launches"'
waitfor 10 'grep -q "DRAM check run=101 : is aligned 8 / 8" "$D/sup.log"'
chk "run 101 은 8/8 로 통과" 'grep -q "DRAM check run=101 : is aligned 8 / 8, Fail to align 0" "$D/sup.log"'
stop_sup

echo "== [5] Fail to align 1 건 (8 줄이어도) -> 이상"
start s5 --run-length 1
echo "ALIGNED=8 FAIL=1" > "$D/plan/100"
waitfor 20 'grep -q "DRAM not aligned" "$D/sup.log"'
chk "Fail to align 1 -> DRAM not aligned" 'grep -q "DRAM not aligned (is aligned 8/8, Fail to align 1)" "$D/sup.log"'
stop_sup

echo "== [6] sr 폭주 3 회 -> 마감 -> rate_high -> cooldown -> 재기동 (마감 TIMEOUT -> recover)"
start s6 --run-length 1
echo "SR=50000 CLOSE_TIMEOUT=1" > "$D/plan/100"
echo 0 > "$D/recover_rc"
waitfor 20 '[ "$(nlaunch)" -ge 2 ]'
chk "연속 3 회 rate high" 'grep -q "max sr 50000 Hz >= 30000 (3/3)" "$D/sup.log"'
chk "rate_high 알림" 'grep -q "^rate_high --run 100" "$D/notify.log"'
chk "cooldown 기록" 'grep -q "cooldown 2 s before relaunch" "$D/sup.log"'
chk "마감 TIMEOUT -> recover 1 회" '[ "$(ncalls)" = 1 ]'
chk "run 101 재기동" 'grep -qx 101 "$D/launches"'
chk "restart 알림 없음 (실패로 세지 않음)" '! grep -q "^restart" "$D/notify.log"'
stop_sup

echo "== [7] 2 h 안에 3 회 -> standby(rate) -> probe 재개"
start s7 --run-length 1 --rate-stop-limit 3 --rate-window 7200
for r in 100 101 102; do echo "SR=50000" > "$D/plan/$r"; done
waitfor 40 'grep -q "STANDBY (rate)" "$D/sup.log"'
chk "세 번째 마감에서 standby(rate)" 'grep -q "3 rate stops within 7200 s; entering standby" "$D/sup.log"'
chk "fatal 알림 1 회" '[ "$(grep -c "^fatal" "$D/notify.log")" = 1 ]'
chk "hb.sup standby=rate" 'grep -q "^standby=rate$" "$D/hb.sup"'
waitfor 10 'grep -qx 103 "$D/launches"'
chk "retry 뒤 run 103 재개" 'grep -qx 103 "$D/launches"'
waitfor 10 'grep -q "^recovered" "$D/notify.log"'
chk "recovered 는 run 103 의 DRAM 점검 뒤" '[ "$(grep -n "DRAM check run=103" "$D/sup.log" | cut -d: -f1)" -lt "$(grep -n "notify: recovered" "$D/sup.log" | cut -d: -f1)" ]'
stop_sup

echo "== [7b] (리뷰 R3) 확인 런도 폭주 -> 첫 마감에서 바로 standby, fatal 은 한 번"
start s7b --run-length 1 --rate-stop-limit 3 --rate-window 7200
for r in $(seq 100 110); do echo "SR=50000" > "$D/plan/$r"; done
waitfor 60 '[ "$(grep -c "STANDBY (rate)" "$D/sup.log")" -ge 2 ]'
chk "standby 두 번 사이 확인 런 1 개 (launches 4)" '[ "$(nlaunch)" = 4 ]'
chk "fatal 은 한 번" '[ "$(grep -c "^fatal" "$D/notify.log")" = 1 ]'
chk "recovered 없음 (확인 런이 통과하지 못함)" '! grep -q "^recovered" "$D/notify.log"'
stop_sup

echo "== [8] 연속 실패 한도 + recover 실패 -> standby(hardware) -> recover 성공 -> 재개"
start s8 --run-length 1 --max-consec-fail 2
for r in 100 101; do echo "EXIT=2 LIFE=1" > "$D/plan/$r"; done
echo 2 > "$D/recover_rc"
waitfor 20 'grep -q "STANDBY (hardware)" "$D/sup.log"'
chk "한도에서 standby(hardware)" 'grep -q "STANDBY (hardware)" "$D/sup.log"'
chk "감시자가 살아 있다 (FATAL 로 안 끝남)" 'kill -0 $SPID'
chk "recover 가 recovery_failed 를 이미 알렸으니 fatal 생략" '! grep -q "^fatal" "$D/notify.log"'
echo 0 > "$D/recover_rc"
waitfor 10 'grep -qx 102 "$D/launches"'
chk "recover 성공 뒤 run 102" 'grep -qx 102 "$D/launches"'
chk "standby 중 recover 재호출" '[ "$(ncalls)" -ge 2 ]'
chk "standby_retry 알림" 'grep -q "^standby_retry" "$D/notify.log"'
chk "recover 가 알린 recovered 와 중복 없음" '! grep -q "^recovered" "$D/notify.log"'
stop_sup

echo "== [9] standby 재개 뒤 첫 실패는 바로 standby 로 (런 번호를 태우지 않음)"
start s9 --run-length 1 --max-consec-fail 3
for r in 100 101 102 103; do echo "EXIT=2 LIFE=1" > "$D/plan/$r"; done
echo 1 > "$D/recover_rc"        # not-usb -> probe 재개
waitfor 30 '[ "$(grep -c "STANDBY (hardware)" "$D/sup.log")" -ge 2 ]'
chk "probe 1 런 뒤 다시 standby" '[ "$(grep -c "STANDBY (hardware)" "$D/sup.log")" -ge 2 ] && [ "$(nlaunch)" = 4 ]'
chk "recover 는 한도 1 + 대기 1 = 2 (확인 런 실패에 또 안 부름)" '[ "$(ncalls)" = 2 ]'
stop_sup

echo "== [9b] (리뷰 R5) 대기 recover 1 + 확인 런마다 USB 서명 -> 재시도당 recover 1 회"
start s9b --run-length 1 --max-consec-fail 2 --standby-retry-min 0.05
for r in $(seq 100 110); do echo "EXIT=2 LIFE=1 USB=1" > "$D/plan/$r"; done
echo 1 > "$D/recover_rc"
waitfor 40 '[ "$(grep -c "STANDBY (hardware)" "$D/sup.log")" -ge 3 ]'
kill -STOP "$SPID"; N3=$(ncalls); L3=$(nlaunch); kill -CONT "$SPID"
chk "STANDBY 3 번에 recover 4 (조기 1 + 한도 1 + 재시도 2), 런 4" '[ "$N3" = 4 ] && [ "$L3" = 4 ]'
chk "recover 가 이미 알렸으므로 fatal 없음" '! grep -q "^fatal" "$D/notify.log"'
stop_sup

echo "== [10] SIGUSR1 -> 정상 마감 -> cooldown -> 재기동"
start s10 --run-length 1
waitfor 10 'grep -q "^phase=running" "$D/hb"'
sleep 1
kill -USR1 "$SPID"
waitfor 15 '[ "$(nlaunch)" -ge 2 ]'
chk "SIGUSR1 기록" 'grep -q "SIGUSR1 : ending the current run gracefully" "$D/sup.log"'
chk "run 100 exit 0 (SIGUSR1)" 'grep -q "cycle 1 finished : exit=code 0  (SIGUSR1)" "$D/sup.log"'
chk "run 101 재기동" 'grep -qx 101 "$D/launches"'
chk "rate_high 알림 없음 (보낸 쪽이 알린다)" '! grep -q "^rate_high" "$D/notify.log"'
stop_sup

echo "== [10b] (리뷰 R1) SIGUSR1 3 번 -> standby 아님, fatal 없음"
start s10b --run-length 1
for i in 1 2 3; do
   waitfor 15 '[ "$(nlaunch)" -ge '$i' ] && grep -q "^phase=running" "$D/hb" && grep -q "^run=$((99+i))$" "$D/hb"'
   sleep 1.5; kill -USR1 "$SPID"
done
waitfor 15 '[ "$(nlaunch)" -ge 4 ]'
chk "런 4 개 (100~103), standby 없음" '[ "$(nlaunch)" = 4 ] && ! grep -q STANDBY "$D/sup.log"'
chk "fatal 없음" '! grep -q "^fatal" "$D/notify.log"'
stop_sup

echo "== [10c] cooldown 중 온 SIGUSR1 은 다음 런을 죽이지 않는다"
start s10c --run-length 1 --rate-cooldown 3
waitfor 10 'grep -q "^phase=running" "$D/hb"'
sleep 1; kill -USR1 "$SPID"
waitfor 10 'grep -q "cooldown 3 s" "$D/sup.log"'
sleep 1; kill -USR1 "$SPID"            # cooldown 중
waitfor 10 '[ "$(nlaunch)" -ge 2 ]'
sleep 4
chk "run 101 이 4 초 넘게 산다 (SIGUSR1 마감 1 번뿐)" '[ "$(grep -c "(SIGUSR1)" "$D/sup.log")" = 1 ] && [ "$(nlaunch)" = 2 ]'
stop_sup

echo "== [11] 정상 로테이션 회귀 (테스트 H 상당)"
start s11 --run-length 0.0015 --max-cycles 2
wait "$SPID"; RC=$?
chk "exit 0" '[ "$RC" = 0 ]'
chk "런 2 개 (100, 101)" '[ "$(tr "\n" " " < "$D/launches")" = "100 101 " ]'
chk "둘 다 rotation" '[ "$(grep -c "(rotation)" "$D/sup.log")" = 2 ]'
chk "알림 없음" '[ ! -s "$D/notify.log" ]'
chk "recover 없음" '[ "$(ncalls)" = 0 ]'

echo "== [12] --no-standby : exit 1 -> 감시자 exit 1 / 한도 -> exit 2 (옛 동작)"
start s12a --run-length 1 --no-standby
echo "EXIT=1 LIFE=0" > "$D/plan/100"
wait "$SPID"; RC=$?
chk "설정 오류 -> exit 1, 재시작 없음" '[ "$RC" = 1 ] && [ "$(nlaunch)" = 1 ]'
start s12b --run-length 1 --no-standby --max-consec-fail 2
for r in 100 101; do echo "EXIT=2 LIFE=1" > "$D/plan/$r"; done
echo 2 > "$D/recover_rc"
wait "$SPID"; RC=$?
chk "연속 실패 한도 -> exit 2" '[ "$RC" = 2 ]'

echo "== [13] TCB 로그가 없으면 DRAM 검사는 건너뛴다 (런을 죽이지 않음)"
start s13 --run-length 1 --daq-logdir "$ROOT/none-at-all"
waitfor 10 'grep -q "DRAM check skipped" "$D/sup.log"'
chk "WARN DRAM check skipped" 'grep -q "WARN DRAM check skipped" "$D/sup.log"'
sleep 2
chk "런 1 개 그대로" '[ "$(nlaunch)" = 1 ]'
stop_sup

FX=$REPO/tests/fixtures/supervisor-logs
echo "== [14] 실물 로그 : TCB_004373 (DRAM 0/8, Fail 8) -> 마감 + recover / TCB_004432 머리 (8/8) -> 통과"
start s14 --run-length 1
echo "REAL_TCB=$FX/TCB_004373_dram_fail.txt" > "$D/plan/100"
echo "REAL_TCB=$FX/TCB_004432_ok_head.txt"   > "$D/plan/101"
echo 0 > "$D/recover_rc"
waitfor 20 'grep -q "DRAM check run=101" "$D/sup.log"'
chk "4373 실물 -> is aligned 0/8, Fail 8" 'grep -q "DRAM not aligned (is aligned 0/8, Fail to align 8)" "$D/sup.log"'
chk "recover 1 회" '[ "$(ncalls)" = 1 ]'
chk "4432 실물 머리 -> 8/8 통과" 'grep -q "DRAM check run=101 : is aligned 8 / 8, Fail to align 0" "$D/sup.log"'
stop_sup

echo "== [15] 실물 로그 : FADCDAQ_004424 (LIBUSB_ERROR_OVERFLOW) 로 부팅 실패 -> 즉시 recover"
start s15 --run-length 1
echo "EXIT=2 LIFE=1 REAL_FADC=$FX/FADCDAQ_004424_usb_overflow.txt" > "$D/plan/100"
echo 0 > "$D/recover_rc"
waitfor 15 '[ "$(nlaunch)" -ge 2 ]'
chk "USB signature (FADCDAQ 2) 로 즉시 recover" 'grep -q "USB signature in run 100 logs (FADCDAQ 2)" "$D/sup.log" && [ "$(ncalls)" = 1 ]'
stop_sup

echo "== [16] 옛 자리(logrotate 가 옮긴 RAW_log)의 로그도 찾는다"
mkdir -p "$ROOT/s16-empty"
# 가짜는 $D/daqlog 에 쓰므로 그 자리를 옛 자리로 준다
start s16 --run-length 1 --daq-logdir "$ROOT/s16-empty" --daq-logdir-old "$ROOT/s16/daqlog"
echo "ALIGNED=7" > "$D/plan/100"
waitfor 15 'grep -q "DRAM not aligned" "$D/sup.log"'
chk "옛 자리 TCB 로그로 DRAM 판정" 'grep -q "DRAM check run=100 : is aligned 7 / 8.*s16/daqlog/TCB_000100.log" "$D/sup.log"'
stop_sup

echo "== [18] 사건 0 런 2 개 -> no_events + recover --no-events (전원까지는 usb-recover 몫) -> 성공하면 재개 (2026-11-08)"
STALLOPT="--stall-grace 3" start s18 --run-length 1 --max-consec-fail 5
for r in 100 101; do echo "ZERO=1" > "$D/plan/$r"; done
echo 0 > "$D/recover_rc"
waitfor 40 '[ "$(nlaunch)" -ge 3 ]'
chk "두 번째 사건 0 런에서 no_events" 'grep -q "2 runs in a row never saw an event (totev stuck at 0); no_events" "$D/sup.log"'
chk "no_events 알림 1 회" '[ "$(grep -c "^no_events" "$D/notify.log")" = 1 ]'
chk "recover 1 회, 인자에 --no-events" '[ "$(ncalls)" = 1 ] && grep -q -- "--no-events" "$D/recover.calls"'
chk "5 런을 태우지 않고 run 102 로 재개" 'grep -qx 102 "$D/launches" && [ "$(nlaunch)" = 3 ]'
chk "fatal 없음" '! grep -q "^fatal" "$D/notify.log"'
stop_sup

echo "== [18b] recover 도 못 풀면 standby(hardware) -> 대기 중 recover 도 --no-events -> 확인 런이 또 0 이면 곧바로 대기, recovered 없음"
STALLOPT="--stall-grace 3" start s18b --run-length 1 --max-consec-fail 5
for r in 100 101 102 103; do echo "ZERO=1" > "$D/plan/$r"; done
echo 2 > "$D/recover_rc"
waitfor 40 'grep -q "STANDBY (hardware)" "$D/sup.log"'
chk "standby(hardware)" 'grep -q "still no events; entering standby (hardware)" "$D/sup.log"'
chk "recover 가 recovery_failed 를 알렸으니 fatal 생략" '! grep -q "^fatal" "$D/notify.log"'
waitfor 5 '[ -s "$D/hb.sup" ]'
chk "hb.sup standby=hardware" 'grep -q "^standby=hardware$" "$D/hb.sup"'
waitfor 15 '[ "$(ncalls)" -ge 2 ]'
chk "대기 중 recover 도 --no-events" '[ "$(grep -c -- "--no-events" "$D/recover.calls")" -ge 2 ]'
echo 1 > "$D/recover_rc"            # not-usb -> 확인 런 1 개
waitfor 30 'grep -qx 102 "$D/launches"'
waitfor 30 '[ "$(grep -c "STANDBY (hardware)" "$D/sup.log")" -ge 2 ]'
chk "확인 런 102 도 사건 0 -> 곧바로 다시 대기 (런 1 개)" '[ "$(grep -c "STANDBY (hardware)" "$D/sup.log")" -ge 2 ] && [ "$(nlaunch)" = 3 ]'
chk "그 확인 런 실패에 recover 를 또 부르지 않았다" 'grep -q "recover not repeated" "$D/sup.log"'
chk "★ 사건 0 확인 런에는 recovered 를 보내지 않는다" '! grep -q "^recovered" "$D/notify.log"'
chk "no_events 는 한 연쇄에 1 회" '[ "$(grep -c "^no_events" "$D/notify.log")" = 1 ]'
stop_sup
chk "SIGTERM -> exit 0" '[ "$RC" = 0 ]'

echo "== [19] 대기 -> 확인 런에 사건이 들어온 뒤에야 recovered (부팅·DRAM 만으로는 아니다)"
STALLOPT="--stall-grace 3" start s19 --run-length 1 --no-events-limit 1
echo "ZERO=1" > "$D/plan/100"
echo "ZERO_FOR=3" > "$D/plan/101"
echo 2 > "$D/recover_rc"
waitfor 30 'grep -q "STANDBY (hardware)" "$D/sup.log"'
chk "--no-events-limit 1 : 첫 사건 0 런에서 no_events" 'grep -q "1 runs in a row never saw an event" "$D/sup.log" && [ "$(nlaunch)" = 1 ]'
echo 1 > "$D/recover_rc"
waitfor 30 'grep -q "^recovered" "$D/notify.log"'
chk "확인 런 101 에서 recovered" 'grep -q "^recovered" "$D/notify.log" && grep -qx 101 "$D/launches"'
chk "recovered 는 totev>0 이 된 뒤 (DRAM 점검보다 늦게)" '[ "$(grep -n "DRAM check run=101" "$D/sup.log" | cut -d: -f1)" -lt "$(grep -n "notify: recovered" "$D/sup.log" | cut -d: -f1)" ]'
chk "본문 : 사건이 들어온다" 'grep "^recovered" "$D/notify.log" | grep -q "사건이 들어온다"'
stop_sup

echo "== [20] 사건이 있던 런의 stall 은 no_events 가 아니다 (기존 restart 경로)"
STALLOPT="--stall-grace 3" start s20 --run-length 1 --max-consec-fail 9
#  사건이 들어오다가 멈춘 런 : 정상 heartbeat 를 몇 번 쓴 뒤 같은 totev 로 굳힌다
echo "FREEZE_AFTER=2" > "$D/plan/100"
waitfor 30 'grep -q "UNHEALTHY : no new events" "$D/sup.log"'
chk "stall 은 잡힌다" 'grep -q "UNHEALTHY : no new events" "$D/sup.log"'
chk "no_events 로 가지 않는다" '! grep -q "no_events" "$D/sup.log" && ! grep -q "^no_events" "$D/notify.log"'
waitfor 20 'grep -q "^restart" "$D/notify.log"'
chk "restart 알림" 'grep -q "^restart" "$D/notify.log"'
stop_sup

echo "== [21] 대기 recover(not-usb) -> 확인 런에 사건 -> 다음 사건 0 연쇄에서 recover 를 다시 부른다 (리뷰 참고 1)"
STALLOPT="--stall-grace 3" start s21 --run-length 1 --no-events-limit 1
echo "ZERO=1" > "$D/plan/100"
echo "EXIT=0 LIFE=5" > "$D/plan/101"
echo "ZERO=1" > "$D/plan/102"
echo 2 > "$D/recover_rc"
waitfor 30 'grep -q "STANDBY (hardware)" "$D/sup.log"'
echo 1 > "$D/recover_rc"            # 대기 중 recover : not-usb -> 확인 런 1 개 (how 3)
waitfor 30 'grep -qx 101 "$D/launches"'
echo 0 > "$D/recover_rc"
waitfor 30 'grep -q "^recovered" "$D/notify.log"'
chk "확인 런 101 에 사건 -> recovered" 'grep -q "^recovered" "$D/notify.log"'
waitfor 40 '[ "$(grep -c -- "--no-events" "$D/recover.calls" 2>/dev/null)" -ge 3 ] || grep -q "recover not repeated" "$D/sup.log"'
chk "★ run 102 의 사건 0 에서 recover --no-events 를 다시 부른다 (3 회째)" '[ "$(grep -c -- "--no-events" "$D/recover.calls")" -ge 3 ]'
chk "★ 'recover not repeated' 로 건너뛰지 않는다" '! grep -q "recover not repeated" "$D/sup.log"'
chk "★ fatal '자동 복구로 안 풀림' 없음" '! grep -q "^fatal" "$D/notify.log"'
stop_sup

echo "== [17] --help 에 새 옵션"
chk "--help 에 --max-rate · SIGUSR1 · --standby-retry-min" '"$SUP" --help | grep -q -- "--max-rate" && "$SUP" --help | grep -q SIGUSR1 && "$SUP" --help | grep -q -- "--standby-retry-min"'
chk "--help 에 --no-events-limit" '"$SUP" --help | grep -q -- "--no-events-limit"'

echo
echo "결과 : 통과 $PASS / 실패 $FAIL"
[ "$FAIL" = 0 ]
