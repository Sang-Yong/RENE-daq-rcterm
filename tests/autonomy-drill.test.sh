#!/usr/bin/env bash
# autonomy-drill.test.sh -- scripts/autonomy-drill.sh 시험.
#   DRILL_TEST_HOOK 으로 시계·sleep·pgrep·kill·ps·crontab·df·chainwatch·usb-recover·tmux 를 가짜로 갈아끼우고,
#   '세계' (heartbeat · 감시자 로그 · chainwatch 로그 · netsync.state · 메일 큐 · TCB 로그) 를 가짜 시계에 맞춰 움직인다.
#   실 프로세스 · tmux daq · 하드웨어 · 메일 · 운영 로그 무접촉.
#   픽스처 모양은 실물에서 : /Data/LOG/rcterm.hb (time= pid= phase= run= ... daq0=FADCDAQ n= sr= ar=),
#   rcsupervisor.log 의 'restart #1 (consecutive failures 1/5)' · 'heartbeat stale : 905 s old (limit 300 s)' ·
#   'SIGUSR1 : ending the current run gracefully' · 'check=600 s  stale=300 s', TCB_00NNNN.log 의 'is aligned' 8 줄,
#   chainwatch.log 의 '자동 재기동 : postrun 를 pane(%3) 에서 다시 띄웠다', netsync.state (net= since= checked=).
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd); D=$DIR/scripts/autonomy-drill.sh
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }; ng() { fail=$((fail+1)); echo "  FAIL $1"; }
chk() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }
TOP=$(mktemp -d)

#  ---- 가짜 세계 (드릴의 셸 안에 source 된다) ----
cat > "$TOP/hook.sh" <<'HOOK'
W=$DRILL_W
FAKE_NOW=${FAKE_NOW:-1793900000}
EVENTS=()
now_s()  { echo "$FAKE_NOW"; }
at()     { EVENTS+=("$(( FAKE_NOW + $1 ))|$2"); }          # $1 초 뒤에 $2 를 실행
sleep_s() {
   FAKE_NOW=$(( FAKE_NOW + $1 ))
   local i e w c keep=()
   for e in "${EVENTS[@]}"; do w=${e%%|*}; c=${e#*|}; if [ "$w" -le "$FAKE_NOW" ]; then eval "$c"; else keep+=("$e"); fi; done
   EVENTS=("${keep[@]}")
   [ -e "$W/hb_live" ] && sed -i "s/^time=.*/time=$FAKE_NOW/" "$DRILL_HB"
   [ -e "$W/ns_live" ] && sed -i "s/^checked=.*/checked=$FAKE_NOW/" "$DRILL_NSSTATE"
   #  netsync 실물 순서 : up 을 먼저 적고, flush 안에서 mailq-send -> sheetlog-auto --force (SC_FLUSH_DELAY 초 뒤 줄이 생긴다)
   [ -n "${SC_NETUP:-}" ] && grep -q '되살려라' "$LOGDIR/drill.log" 2>/dev/null && { set_net up; echo 3 > "$W/sheetleft"
      at 60 "rm -f $DRILL_LOCALQ/*.mail $DRILL_NFSQ/*.mail; echo '2026-11-05 12:00:00   mailq-send rc=0' >> $DRILL_NSLOG"
      at "${SC_FLUSH_DELAY:-300}" "echo '2026-11-05 12:05:00   sheetlog-auto --force rc=${SC_SHEET_RC:-0} 등재 2 런' >> $DRILL_NSLOG; echo 0 > $W/sheetleft"
      SC_NETUP=""; }
   [ -n "${SC_INT_AT:-}" ] && [ "$FAKE_NOW" -ge "$SC_INT_AT" ] && { SC_INT_AT=""; kill -INT $$; }
   return 0
}
proc()   { cat "$W/proc.$1" 2>/dev/null; }
pid_of() { proc "$1"; }
pid_alive() { { cat "$W"/proc.* "$W/alive" 2>/dev/null; awk '{ print $1 }' "$W/ps" 2>/dev/null; } | grep -qx "$1"; }
ps_lines() { cat "$W/ps" 2>/dev/null; }
sigcgt_of() { cat "$W/sigcgt" 2>/dev/null; }
crontab_l() { cat "$W/crontab"; }
df_avail_gb() { cat "$W/df"; }
is_mounted() { [ -e "$W/mounted" ]; }
run_chainwatch() { echo chainwatch >> "$W/calls"; [ "$(ns_get net)" = down ] && touch "$DRILL_LOCALQ/cw-$FAKE_NOW.mail"; return 0; }
run_usbrecover() { echo "usb-recover $*" >> "$W/calls"; return "$(cat "$W/usbrc" 2>/dev/null || echo 3)"; }
run_sheetstatus() { printf '밀린 런        : 0 개  [ ]\n완결돼 쓸 수 있는 것 : %s 개\n' "$(cat "$W/sheetleft" 2>/dev/null || echo 0)"; }
print_cmd() { echo "install/bin/rcsupervisor --params config/rcsupervisor.params"; }
tmux_c() {
   echo "tmux $*" >> "$W/calls"
   case "$1" in
      list-panes) echo "%2 89684 supervisor" ;;
      capture-pane) echo "[frontend@rocky9 RENE-daq-rcterm]\$ " ;;
      send-keys) case "$*" in *Enter*) [ -n "${SC_POWER_NEW:-}" ] && at 120 "new_run $SC_POWER_NEW 8" ;; esac ;;
   esac
   return 0
}
send_sig() {
   echo "$1 $2" >> "$W/sigs"
   case "$1:$2" in
      TERM:$(proc daq))
         [ -n "${SC_DAQ:-}" ] && at 40 "suplog 'restart #1 (consecutive failures 1/5); next run will be new'; new_run $SC_DAQ ${SC_DAQ_DRAM:-8}"
         [ -n "${SC_AFTER4:-}" ] && at 60 "$SC_AFTER4"
         [ -n "${SC_DAQ_HOLD:-}" ] && at 40 "touch $DRILL_HOLD" ;;
      STOP:$(proc rcterm))
         rm -f "$W/hb_live"
         [ -n "${SC_STALE:-}" ] && at 905 "suplog 'UNHEALTHY : heartbeat stale : 905 s old (limit 300 s)'; suplog 'restart #2 (consecutive failures 1/5); next run will be new'; echo 9999 > $W/proc.rcterm; new_run $SC_STALE 8" ;;
      TERM:4200)
         printf '%s\n' "1 1 /usr/lib/systemd/systemd" > "$W/ps"
         [ -n "${SC_PR:-}" ] && at 600 "printf '%s\n' '2026-11-05 10:00:00 자동 재기동 : postrun 를 pane(%3) 에서 다시 띄웠다 : scripts/postrun.sh --follow' >> $DRILL_CWLOG; printf '%s\n' '5555 89690 bash /home/frontend/DAQ/RENE-daq-rcterm/scripts/postrun.sh --follow --jobs 3 --lag 3' >> $W/ps" ;;
      USR1:$(proc rcsupervisor))
         [ -n "${SC_USR1:-}" ] && at 60 "suplog 'SIGUSR1 : ending the current run gracefully; relaunch after 300 s'; new_run $SC_USR1 8" ;;
      TERM:$(proc rcsupervisor))
         [ -n "${SC_SUPDOWN:-}" ] && at 30 "rm -f $W/proc.rcsupervisor $W/proc.rcterm $W/proc.daq $W/proc.tcb $W/proc.merger; set_phase ended" ;;
   esac
   return 0
}
suplog() { printf '2026-11-05 10:00:00 [SUP] %s\n' "$1" >> "$DRILL_SUPLOG"; }
set_phase() { sed -i "s/^phase=.*/phase=$1/" "$DRILL_HB"; }
new_run() {              # $1=런 $2=is aligned 줄 수
   local i; sed -i "s/^run=.*/run=$1/; s/^phase=.*/phase=running/" "$DRILL_HB"; touch "$W/hb_live"
   : > "$(printf '%s/TCB_%06d.log' "$DRILL_DAQLOG" "$1")"
   for i in $(seq 1 "$2"); do echo "[INFO] CupTCB::AlignDRAM: DRAM($((i-1))) is aligned, delay = 5, bitslip = 0" >> "$(printf '%s/TCB_%06d.log' "$DRILL_DAQLOG" "$1")"; done
   echo 4321 > "$W/proc.daq"; echo 1777 > "$W/proc.rcsupervisor"
}
set_net() { printf 'net=%s\nsince=%s\nfails=0\nfirst_fail=\nchecked=%s\ndns=ok\nsmtp=ok\nsheets=ok\nkhu=ok\n' "$1" "$FAKE_NOW" "$FAKE_NOW" > "$DRILL_NSSTATE"; touch "$W/ns_live"; }
set_net_down() { set_net down; touch "$DRILL_LOCALQ/net_down-$FAKE_NOW.mail"; }
HOOK

#  ---- 한 시험의 세계를 새로 만든다 ----
new_world() {
   T=$(mktemp -d "$TOP/w.XXXX"); W=$T/w; mkdir -p "$W" "$T/log/daq" "$T/q" "$T/nq" "$T/root"
   export DRILL_W=$W DRILL_TEST_HOOK=$TOP/hook.sh DRILL_HB=$T/rcterm.hb DRILL_SUPLOG=$T/rcsupervisor.log \
          DRILL_CWLOG=$T/chainwatch.log DRILL_NSSTATE=$T/netsync.state DRILL_HOLD=$T/chainwatch.hold \
          DRILL_LOCALQ=$T/q DRILL_NFSQ=$T/nq DRILL_DAQLOG=$T/log/daq DRILL_ROOT=$T/root DRILL_SSD=$T DRILL_NFS=$T \
          DRILL_NETSYNC=$T/netsync.sh DRILL_NSLOG=$T/netsync.log DRILL_DBFILE=$T/runcatalog.db DRILL_POLL=10 FAKE_NOW=1793900000
   printf 'time=1793900000\npid=3897166\nphase=running\nrun=4440\nsubrun=12\nstate=Running\ndaqtime=720.0\nndaq=2\ndaq0=FADCDAQ n=4600000 sr=6396.74 ar=6400.10\ndaq1=SADCDAQ n=4600000 sr=6277.09 ar=6400.04\n' > "$DRILL_HB"
   touch "$W/hb_live"
   printf '%s\n' "2026-11-05 09:00:00 [SUP] rotation=24.0000 h  check=600 s  stale=300 s  grace=180 s  maxCycles=0" \
                 "2026-11-05 09:00:00 [SUP] cycle 1 launch: rcterm ..." > "$DRILL_SUPLOG"
   : > "$DRILL_CWLOG"; touch "$T/netsync.sh"
   printf '%s\n' "*/5 * * * * /home/frontend/DAQ/RENE-daq-rcterm/scripts/chainwatch.sh >/dev/null 2>&1" \
                 "*/5 * * * * /home/frontend/DAQ/RENE-daq-rcterm/scripts/netsync.sh >/dev/null 2>&1" > "$W/crontab"
   echo 3100 > "$W/df"; touch "$W/mounted"
   echo 1777 > "$W/proc.rcsupervisor"; echo 2001 > "$W/proc.rcterm"; echo 4321 > "$W/proc.daq"; echo 4330 > "$W/proc.tcb"
   echo 0000000180004a07 > "$W/sigcgt"     # 0x200 (USR1) 포함 -- 새 감시자
   printf '%s\n' "1 1 /usr/lib/systemd/systemd" \
      "4200 89690 bash /home/frontend/DAQ/RENE-daq-rcterm/scripts/postrun.sh --follow --jobs 3 --lag 3 --rawroot /Data_ssd/RAW" \
      "4250 4200 bash /home/frontend/DAQ/RENE-daq-rcterm/scripts/postrun.sh --follow --jobs 3 --lag 3 --rawroot /Data_ssd/RAW" \
      "4300 89698 bash /home/frontend/DAQ/RENE-daq-rcterm/scripts/dataflow.sh --follow" > "$W/ps"
   printf '%06d' 4440 >/dev/null
   for i in 1 2 3 4 5 6 7 8; do echo "DRAM($i) is aligned" >> "$T/log/daq/TCB_004440.log"; done
   echo '2026-11-05 08:00:00 검사 : dns=ok' > "$T/netsync.log"
   unset SC_DAQ SC_DAQ_DRAM SC_STALE SC_PR SC_USR1 SC_AFTER4 SC_NETUP SC_POWER_NEW SC_SUPDOWN SC_INT_AT SC_FLUSH_DELAY SC_SHEET_RC SC_DAQ_HOLD
}
nsig() { [ -f "$W/sigs" ] && grep -c . "$W/sigs" || echo 0; }
verdict() { awk -F '\t' -v s="$1" '$1 == s { print $6 }' "$T/out/result.tsv" | tail -1; }
drill() { bash "$D" --log "$T/out" "$@" > "$T/stdout" 2>&1; echo $?; }

echo "[1] --dry-run : 주입 0, 바깥 명령 0, 표식 없음"
new_world; rc=$(drill --plan offline-full --dry-run --confirm-test-run --with-power)
chk "rc 0" "[ $rc = 0 ]"; chk "kill 0 회" "[ $(nsig) = 0 ]"; chk "chainwatch·usb-recover·tmux 0 회" "[ ! -f $W/calls ]"
chk "RUNNING 표식 없음" "[ ! -e $T/root/RUNNING ]"; chk "계획 10 줄" "[ \$(grep -c '\[계획\] 단계' $T/stdout) = 10 ]"
chk "계획에 전원 실물 경고" "grep -q '★ 감시자 TERM -> usb-recover' $T/stdout"; chk "stale 제한 = 600+300+900" "grep -q '1800 s' $T/stdout"
chk "[DRY] 주입 0 회" "grep -q '주입 0 회' $T/stdout"

echo "[2] 전제 실패 (phase=ended) : 주입 0, 나머지 SKIP, rc 1"
new_world; sed -i 's/^phase=.*/phase=ended/' "$DRILL_HB"; rc=$(drill --plan quick --confirm-test-run)
chk "rc 1" "[ $rc = 1 ]"; chk "단계 0 FAIL" "[ \"\$(verdict 0)\" = FAIL ]"; chk "kill 0 회" "[ $(nsig) = 0 ]"
chk "단계 1·4~8 SKIP" "[ \$(awk -F '\t' '\$6==\"SKIP\"' $T/out/result.tsv | grep -c .) = 6 ]"; chk "usb-recover 0 회" "[ ! -f $W/calls ]"
chk "끝나면 표식 지움" "[ ! -e $T/root/RUNNING ]"; chk "report.md" "[ -s $T/out/report.md ]"

echo "[3] 전제 실패 : /Data_ssd 여유 부족 · 멈춤 파일 · netsync cron 없음 · quick 인데 확인 없음"
new_world; echo 120 > "$W/df"; touch "$DRILL_HOLD"; sed -i '/netsync/d' "$W/crontab"; rc=$(drill --plan offline-full)
chk "rc 1" "[ $rc = 1 ]"; chk "사유 : 여유 120 G" "grep -q '120 G < 500 G' $T/out/result.tsv"; chk "사유 : 멈춤 파일" "grep -q '멈춤 파일 있음' $T/out/result.tsv"
chk "사유 : netsync cron" "grep -q 'netsync cron 없음' $T/out/result.tsv"; chk "망 끊으라는 안내도 안 낸다" "! grep -q '망을 끊어라' $T/stdout"
new_world; rc=$(drill --plan quick); chk "quick 무확인 rc 1" "[ $rc = 1 ]"; chk "quick 무확인 kill 0" "[ $(nsig) = 0 ]"

echo "[4] 겹침 : 살아 있는 드릴의 RUNNING 이 있으면 아무것도 안 한다"
new_world; echo "$$" > "$W/alive"; printf 'pid=%s\n' "$$" > "$T/root/RUNNING"; rc=$(drill --plan quick --confirm-test-run)
chk "rc 1" "[ $rc = 1 ]"; chk "kill 0" "[ $(nsig) = 0 ]"; chk "남의 표식은 그대로" "grep -q \"pid=$$\" $T/root/RUNNING"
chk "로그에 '다른 드릴'" "grep -q '다른 드릴' $T/stdout"

echo "[5] quick 정상 : 4·5·6·7 PASS, 8 dry 게이트 PASS (옛 표식은 치운다)"
new_world; printf 'pid=999999\n' > "$T/root/RUNNING"
export SC_DAQ=4441 SC_STALE=4442 SC_PR=1 SC_USR1=4443
rc=$(drill --plan quick --confirm-test-run)
chk "rc 0" "[ $rc = 0 ]"
for s in 0 1 4 5 6 7 8; do chk "단계 $s PASS" "[ \"\$(verdict $s)\" = PASS ]"; done
chk "TERM 은 daq pid 4321 로" "grep -qx 'TERM 4321' $W/sigs"; chk "STOP 은 rcterm 2001 로" "grep -qx 'STOP 2001' $W/sigs"
chk "postrun TERM 은 맨 위 셸 4200 (하위 4250 아님)" "grep -qx 'TERM 4200' $W/sigs && ! grep -q 4250 $W/sigs"
chk "USR1 은 감시자 1777 로" "grep -qx 'USR1 1777' $W/sigs"
chk "usb-recover 는 --dry-run 으로만" "grep -q 'usb-recover --force-power-cycle --dry-run' $W/calls && [ \$(grep -c usb-recover $W/calls) = 1 ]"
chk "tmux 는 안 건드림" "! grep -q tmux $W/calls"; chk "옛 표식 치움 + 끝나면 지움" "[ ! -e $T/root/RUNNING ] && grep -q '옛 표식' $T/stdout"
chk "근거 : restart #1" "grep -q 'restart #1' $T/out/result.tsv"; chk "근거 : heartbeat stale" "grep -q 'heartbeat stale' $T/out/result.tsv"
chk "근거 : 자동 재기동 : postrun" "grep -q '자동 재기동 : postrun' $T/out/result.tsv"; chk "근거 : TCB_004443 is aligned 8" "grep -q 'TCB_004443 is aligned 8 / Fail to align 0' $T/out/result.tsv"
chk "report 에 PASS 7" "grep -q 'PASS 7 · FAIL 0' $T/out/report.md"; chk "baseline 에 run=4440" "grep -qx 'run=4440' $T/out/baseline.txt"

echo "[6] 반응 없음 : 시간 초과로 FAIL, STOP 해 둔 rcterm 에 CONT"
new_world; export DRILL_T_KILL=120 DRILL_T_STALE=200 DRILL_T_POSTRUN=100 DRILL_T_USR1=100
rc=$(drill --plan quick --confirm-test-run)
chk "rc 1" "[ $rc = 1 ]"; chk "단계 4 FAIL" "[ \"\$(verdict 4)\" = FAIL ]"; chk "단계 5 FAIL" "[ \"\$(verdict 5)\" = FAIL ]"
chk "rcterm 2001 에 CONT" "grep -qx 'CONT 2001' $W/sigs"; chk "단계 6 FAIL (postrun 안 돌아옴)" "[ \"\$(verdict 6)\" = FAIL ]"
unset DRILL_T_KILL DRILL_T_STALE DRILL_T_POSTRUN DRILL_T_USR1

echo "[7] 새 런은 떴으나 DRAM 7/8 : PASS 아님"
new_world; export SC_DAQ=4441 SC_DAQ_DRAM=7 DRILL_T_KILL=200
rc=$(drill --plan quick --confirm-test-run); chk "단계 4 FAIL" "[ \"\$(verdict 4)\" = FAIL ]"; chk "관측에 is aligned 7" "grep -q 'is aligned 7' $T/out/result.tsv"
unset DRILL_T_KILL

echo "[8] 옛 감시자 (SigCgt 에 USR1 없음) : USR1 을 보내지 않고 SKIP"
new_world; echo 0000000180004805 > "$W/sigcgt"; export SC_DAQ=4441 SC_STALE=4442 SC_PR=1
rc=$(drill --plan quick --confirm-test-run); chk "단계 7 SKIP" "[ \"\$(verdict 7)\" = SKIP ]"; chk "USR1 0 회" "! grep -q '^USR1' $W/sigs"
chk "SKIP 만이면 rc 0" "[ $rc = 0 ]"

echo "[9] 주입 뒤 phase 가 ended 로 : 남은 주입 중단"
new_world; export SC_DAQ="" SC_AFTER4="set_phase ended; rm -f $W/hb_live" DRILL_T_KILL=100
rc=$(drill --plan quick --confirm-test-run)
chk "단계 5 FAIL (phase)" "[ \"\$(verdict 5)\" = FAIL ] && grep -q 'phase=ended, heartbeat' $T/out/result.tsv"
chk "STOP · postrun TERM · USR1 0 회" "! grep -qE '^(STOP|USR1)|TERM 4200' $W/sigs"; chk "단계 6·7 SKIP 중단" "[ \"\$(verdict 6)\" = SKIP ] && [ \"\$(verdict 7)\" = SKIP ]"
unset DRILL_T_KILL

echo "[10] postrun 뿌리가 둘 : 모호해서 손대지 않는다"
new_world; echo "4400 89691 bash /x/scripts/postrun.sh --follow --jobs 3" >> "$W/ps"; export SC_DAQ=4441 SC_STALE=4442 SC_USR1=4443
rc=$(drill --plan quick --confirm-test-run); chk "단계 6 FAIL" "[ \"\$(verdict 6)\" = FAIL ]"; chk "postrun TERM 0" "! grep -qE 'TERM (4200|4400)' $W/sigs"
new_world; rm -f "$W/mounted"; export SC_DAQ=4441 SC_STALE=4442 SC_USR1=4443
rc=$(drill --plan quick --confirm-test-run); chk "/scratch 없으면 6 SKIP" "[ \"\$(verdict 6)\" = SKIP ] && ! grep -q 'TERM 4200' $W/sigs"

echo "[11] offline-full 정상 : 망 끊김 -> 큐 적재 -> 주입 -> 망 복귀 -> 큐 0 · 시트 0"
new_world; set_net_up() { :; }
printf 'net=up\nsince=1793800000\nchecked=1793900000\n' > "$DRILL_NSSTATE"; touch "$W/ns_live"
export SC_DAQ=4441 SC_STALE=4442 SC_PR=1 SC_USR1=4443 SC_NETUP=1
echo 'set_net_down' > "$W/netdown_cmd"
#  사람이 망을 끊는 것 : 드릴이 '끊어라' 를 낸 뒤 300 s 에 net=down (+ netsync 의 net_down 메일 1 통)
export DRILL_TEST_HOOK2=1
cat > "$TOP/hook2.sh" <<'EOF'
. "$HOOK1"
_orig_sleep=$(declare -f sleep_s | sed '1s/sleep_s/_sleep0/'); eval "$_orig_sleep"
sleep_s() { _sleep0 "$1"; if [ -z "${_DOWNED:-}" ] && grep -q '망을 끊어라' "$LOGDIR/drill.log" 2>/dev/null; then _DOWNED=1; at 300 set_net_down; fi; }
EOF
HOOK1=$TOP/hook.sh DRILL_TEST_HOOK=$TOP/hook2.sh; export HOOK1 DRILL_TEST_HOOK
echo "x" > "$T/nq/old.mail"
rc=$(drill --plan offline-full --confirm-test-run)
chk "rc 0" "[ $rc = 0 ]"
for s in 0 1 2 3 4 5 6 7 8 9; do chk "단계 $s PASS" "[ \"\$(verdict $s)\" = PASS ]"; done
chk "chainwatch 1 회" "[ \$(grep -c '^chainwatch' $W/calls) = 1 ]"
chk "9 근거는 sheetlog --force rc=0 줄" "grep -q 'sheetlog-auto --force rc=0 등재 2 런' $T/out/result.tsv"
chk "망 복귀 전에 onlbit=0 명령 (런 4440~4443, 백업 먼저)" "grep -q 'BETWEEN 4440 AND 4443' $T/stdout && grep -q 'before-drill' $T/stdout"
chk "onlbit 안내가 '되살려라' 보다 먼저" "[ \$(grep -n 'onlbit=0' $T/out/drill.log | head -1 | cut -d: -f1) -lt \$(grep -n '되살려라' $T/out/drill.log | head -1 | cut -d: -f1) ]"
chk "report 에도 onlbit 명령" "grep -q 'BETWEEN 4440 AND' $T/out/report.md"; chk "사람 안내 두 번 (끊어라·되살려라)" "grep -q '끊어라' $T/stdout && grep -q '되살려라' $T/stdout"

echo "[12] offline-full : 망이 안 끊김 -> 2 FAIL, 3 SKIP, 9 는 안내하고 판정"
new_world; printf 'net=up\nsince=1793800000\nchecked=1793900000\n' > "$DRILL_NSSTATE"; touch "$W/ns_live"
export DRILL_TEST_HOOK=$TOP/hook.sh DRILL_T_NETDOWN=300 SC_DAQ=4441 SC_STALE=4442 SC_PR=1 SC_USR1=4443
rc=$(drill --plan offline-full --confirm-test-run)
chk "rc 1" "[ $rc = 1 ]"; chk "2 FAIL" "[ \"\$(verdict 2)\" = FAIL ]"; chk "3 SKIP" "[ \"\$(verdict 3)\" = SKIP ]"
chk "4 는 그대로 진행 (PASS)" "[ \"\$(verdict 4)\" = PASS ]"; chk "9 안내" "grep -q '되살려라' $T/stdout"
unset DRILL_T_NETDOWN

echo "[13] 기다리는 동안 멈춤 파일이 생기면 중단"
new_world; export SC_DAQ="" SC_AFTER4="touch $DRILL_HOLD" DRILL_T_KILL=300
rc=$(drill --plan quick --confirm-test-run)
chk "rc 1" "[ $rc = 1 ]"; chk "로그에 사람이 작업 중" "grep -q '사람이 작업 중' $T/stdout"; chk "STOP 0" "! grep -q '^STOP' $W/sigs"
unset DRILL_T_KILL

echo "[14] --with-power 정상 : 감시자 TERM -> 전원 실물 -> pane 에 감시자 명령 -> 새 런"
new_world; export SC_DAQ=4441 SC_STALE=4442 SC_PR=1 SC_USR1=4443 SC_SUPDOWN=1 SC_POWER_NEW=4444 DRILL_PANE_IDLE=1; echo 0 > "$W/usbrc"
rc=$(drill --plan quick --confirm-test-run --with-power)
chk "rc 0" "[ $rc = 0 ]"; chk "8 PASS" "[ \"\$(verdict 8)\" = PASS ]"
chk "usb-recover 실물 (dry-run 아님)" "grep -qx 'usb-recover --force-power-cycle' $W/calls"
chk "감시자 TERM 이 전원보다 먼저" "grep -qx 'TERM 1777' $W/sigs"
chk "pane 에 감시자 명령" "grep -q 'send-keys -t %2 -l install/bin/rcsupervisor' $W/calls"

echo "[15] --with-power 실패 (usb-recover rc 2) : 감시자 안 띄움, 중단"
new_world; export SC_DAQ=4441 SC_STALE=4442 SC_PR=1 SC_USR1=4443 SC_SUPDOWN=1 DRILL_PANE_IDLE=1; echo 2 > "$W/usbrc"
rc=$(drill --plan quick --confirm-test-run --with-power)
chk "rc 1" "[ $rc = 1 ]"; chk "8 FAIL" "[ \"\$(verdict 8)\" = FAIL ]"; chk "tmux send-keys 0" "! grep -q send-keys $W/calls"
chk "사람이 볼 것" "grep -q '사람이 볼 것' $T/out/result.tsv"
unset DRILL_PANE_IDLE

echo "[16] 중간에 INT : STOP 한 rcterm 에 CONT, 표식 지움, report 남김"
new_world; export SC_DAQ=4441 SC_INT_AT=1793900200
rc=$(drill --plan quick --confirm-test-run)
chk "rc 1" "[ $rc = 1 ]"; chk "CONT 2001" "grep -qx 'CONT 2001' $W/sigs"; chk "표식 지움" "[ ! -e $T/root/RUNNING ]"; chk "report.md" "[ -s $T/out/report.md ]"
unset SC_INT_AT

echo "[17] cron 환경 (env -i) 에서 --dry-run"
new_world
out=$(env -i PATH=/usr/bin:/bin HOME="$HOME" DRILL_TEST_HOOK=$TOP/hook.sh DRILL_W=$W DRILL_HB=$DRILL_HB DRILL_SUPLOG=$DRILL_SUPLOG \
      DRILL_ROOT=$T/root DRILL_SSD=$T DRILL_NSSTATE=$DRILL_NSSTATE DRILL_HOLD=$DRILL_HOLD DRILL_NETSYNC=$T/netsync.sh \
      bash -c "cd / && bash $D --plan quick --dry-run --confirm-test-run --log $T/out" 2>&1); rc=$?
chk "rc 0" "[ $rc = 0 ]"; chk "계획 7 줄" "[ \$(printf '%s\n' \"\$out\" | grep -c '\[계획\] 단계') = 7 ]"

echo "[18] 사용법 오류"
rc=$(bash "$D" --plan nope >/dev/null 2>&1; echo $?); chk "--plan nope rc 2" "[ $rc = 2 ]"
rc=$(bash "$D" --bogus >/dev/null 2>&1; echo $?); chk "--bogus rc 2" "[ $rc = 2 ]"
chk "bash -n" "bash -n $D"; chk "pgrep -f 없음" "! grep -nE 'pgrep[^|]*-f|pkill' $D | grep -v '^[0-9]*:#' | grep -v '금지' | grep -q ."

echo "[19] 리뷰 재현 : 새 런과 멈춤 파일이 같은 회차에 생기면 다음 주입을 하지 않는다"
new_world; export SC_DAQ=4441 SC_DAQ_HOLD=1 SC_STALE=4442 SC_PR=1 SC_USR1=4443
rc=$(drill --plan quick --confirm-test-run)
chk "rc 1" "[ $rc = 1 ]"; chk "STOP 0 (5 단계 주입 안 함)" "! grep -q '^STOP' $W/sigs"
chk "postrun·USR1 0" "! grep -qE '^USR1|TERM 4200' $W/sigs"; chk "5 SKIP" "[ \"\$(verdict 5)\" = SKIP ]"
echo "[19b] 단계 사이에 생긴 멈춤 파일은 guard 가 막는다"
new_world; export SC_DAQ=4441 SC_STALE=4442 SC_PR=1 SC_USR1=4443
#  wait_for 의 hold 검사가 지난 뒤 · 조건을 보는 순간(새 런 4441) 에 멈춤 파일이 생긴다 -> 4 는 PASS, 5 의 guard 가 막아야 한다
cat > "$T/hook4.sh" <<'H4'
. "$HOOK1"
now_s() { grep -q '^run=4441' "$DRILL_HB" 2>/dev/null && touch "$DRILL_HOLD"; echo "$FAKE_NOW"; }
H4
export HOOK1=$TOP/hook.sh DRILL_TEST_HOOK=$T/hook4.sh; rc=$(drill --plan quick --confirm-test-run); export DRILL_TEST_HOOK=$TOP/hook.sh
chk "4 PASS (멈춤 파일 전)" "[ \"\$(verdict 4)\" = PASS ]"; chk "5 SKIP 멈춤 파일" "[ \"\$(verdict 5)\" = SKIP ] && grep -q '멈춤 파일' $T/out/result.tsv"
chk "STOP 0" "! grep -q '^STOP' $W/sigs"

echo "[20] 리뷰 재현 : netsync flush 순서 (up 먼저, sheetlog 줄은 900 s 뒤) -> 거짓 FAIL 이 아니라 기다려 PASS"
nf() { new_world; printf 'net=up\nsince=1793800000\nchecked=1793900000\n' > "$DRILL_NSSTATE"; touch "$W/ns_live"
       export HOOK1=$TOP/hook.sh DRILL_TEST_HOOK=$TOP/hook2.sh SC_DAQ=4441 SC_STALE=4442 SC_PR=1 SC_USR1=4443 SC_NETUP=1; }
nf; export SC_FLUSH_DELAY=900; rc=$(drill --plan offline-full --confirm-test-run)
chk "9 PASS" "[ \"\$(verdict 9)\" = PASS ]"; chk "rc 0" "[ $rc = 0 ]"
nf; export SC_SHEET_RC=1; rc=$(drill --plan offline-full --confirm-test-run)
chk "sheetlog rc 1 이면 9 FAIL" "[ \"\$(verdict 9)\" = FAIL ] && grep -q 'rc=1' $T/out/result.tsv"
nf; export SC_FLUSH_DELAY=99999 DRILL_T_SHEET=300; rc=$(drill --plan offline-full --confirm-test-run)
chk "flush 기록 없으면 9 FAIL" "[ \"\$(verdict 9)\" = FAIL ] && grep -q 'flush 기록 없음' $T/out/result.tsv"
unset DRILL_T_SHEET; export DRILL_TEST_HOOK=$TOP/hook.sh

echo "[21] 후속 : CONT 는 한 번만 · 주석 처리된 cron 은 없는 것 · dry-run 전제 실패 rc 1 · 판정 문구"
new_world; export DRILL_T_KILL=60 DRILL_T_STALE=100 DRILL_T_POSTRUN=60 DRILL_T_USR1=60
rc=$(drill --plan quick --confirm-test-run); chk "CONT 2001 정확히 1 번" "[ \$(grep -cx 'CONT 2001' $W/sigs) = 1 ]"
unset DRILL_T_KILL DRILL_T_STALE DRILL_T_POSTRUN DRILL_T_USR1
new_world; sed -i 's|^\*/5 \(.*chainwatch\)|#*/5 \1|' "$W/crontab"
rc=$(drill --plan quick --dry-run --confirm-test-run); chk "주석 cron -> chainwatch cron 없음, dry-run rc 1" "[ $rc = 1 ] && grep -q 'chainwatch cron 없음' $T/stdout"
chk "그래도 주입 0" "[ $(nsig) = 0 ]"
new_world; export SC_DAQ=4441 DRILL_T_STALE=1000 DRILL_T_POSTRUN=60 DRILL_T_USR1=60
cat > "$T/hook3.sh" <<'H3'
. "$HOOK1"
eval "$(declare -f send_sig | sed '1s/send_sig/_ss0/')"
send_sig() { _ss0 "$@"; [ "$1:$2" = "STOP:2001" ] && at 300 "suplog 'restart #2 notify: stale_config'; echo 9999 > $W/proc.rcterm; new_run 4442 8"; return 0; }
H3
export HOOK1=$TOP/hook.sh DRILL_TEST_HOOK=$T/hook3.sh; rc=$(drill --plan quick --confirm-test-run)
chk "'heartbeat stale' 없이 'stale' 글자만이면 5 FAIL" "[ \"\$(verdict 5)\" = FAIL ]"
unset DRILL_T_STALE DRILL_T_POSTRUN DRILL_T_USR1; export DRILL_TEST_HOOK=$TOP/hook.sh

echo "[22] 후속 : --with-power 에서 all_down 시간 초과 -> 중단 + 손으로 띄울 명령"
new_world; export SC_DAQ=4441 SC_STALE=4442 SC_PR=1 SC_USR1=4443 DRILL_PANE_IDLE=1; echo 0 > "$W/usbrc"
rc=$(drill --plan quick --confirm-test-run --with-power)
chk "8 FAIL" "[ \"\$(verdict 8)\" = FAIL ]"; chk "손으로 띄울 명령" "grep -q '손으로 띄울 것 : install/bin/rcsupervisor' $T/out/result.tsv"
chk "usb-recover 실물 0" "! grep -qx 'usb-recover --force-power-cycle' $W/calls"; chk "send-keys 0" "! grep -q send-keys $W/calls"
unset DRILL_PANE_IDLE

if [ -n "${KEEP:-}" ]; then echo "남김 $TOP"; else rm -rf -- "${TOP:?}"; fi
echo "통과 $pass / 실패 $fail"
[ "$fail" -eq 0 ]
