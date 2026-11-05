#!/usr/bin/env bash
# usb-recover.test.sh -- scripts/usb-recover.sh 시험.
#   하드웨어·수집·실데이터·실메일 무접촉 : usbreset · lsusb · rcterm · pdu-power · NOTICE_CODE_RUN ·
#   killdaq · sleep · pgrep · ss · dmesg 를 USBRECOVER_TEST_HOOK 으로 갈아끼운다.
#   DAQ 로그 픽스처는 실물 (tests/fixtures/usb-recover/README.txt).
set -u
export LC_ALL=C     # 이 PC 의 grep 3.6 은 ko_KR.UTF-8 에서 ".*" 가 한글을 못 건넌다 (시험 grep 용)
REPO=$(cd "$(dirname "$0")/.." && pwd); S=$REPO/scripts/usb-recover.sh
FX=$REPO/tests/fixtures/usb-recover
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$T/bin"
# ---- 가짜 실행 파일 (전부 $T/seq 에 흔적을 남긴다) ----
cat > "$T/bin/usbreset" <<EOF
#!/usr/bin/env bash
echo USBRESET >> "$T/seq"; exit 0
EOF
cat > "$T/bin/killdaq" <<EOF
#!/usr/bin/env bash
echo "KILLDAQ \$*" >> "$T/seq"
[ -f "$T/stuck" ] && exit 0          # 치워지지 않는 고아
: > "$T/busy"; echo 0 > "$T/ports"; exit 0
EOF
cat > "$T/bin/pdu" <<EOF
#!/usr/bin/env bash
echo "PDU \$*" >> "$T/seq"
rc=\$(cat "$T/pdu_rc" 2>/dev/null || echo 0)
[ "\$rc" = 0 ] && [ ! -f "$T/stay_missing" ] && : > "$T/missing"
exit \$rc
EOF
cat > "$T/bin/notice" <<EOF
#!/usr/bin/env bash
echo NOTICE >> "$T/seq"; exit \$(cat "$T/notice_rc" 2>/dev/null || echo 0)
EOF
cat > "$T/bin/notify" <<EOF
#!/usr/bin/env bash
# --params P <event> --msg M --detail-file D
echo "NOTIFY \$3 | \$5" >> "$T/seq"; exit 0
EOF
# 가짜 rcterm : 10 s 더미 런은 흔적만. 확인 런은 $T/scen 의 n 번째 줄대로 로그·파일·heartbeat 를 만든다
#   줄 형식 : rc 로그묶음(d|a|c|none|stale) FADC바이트 ar목록(쉼표, -는 없음) 고아(y|n)
cat > "$T/bin/rcterm" <<EOF
#!/usr/bin/env bash
len=""; hb=""; run=""
while [ \$# -gt 0 ]; do case "\$1" in --run-length) len=\$2; shift;; --heartbeat) hb=\$2; shift;; --run) run=\$2; shift;; esac; shift; done
if [ "\$len" = 0.0028 ]; then echo "RCTERM dummy" >> "$T/seq"; exit 0; fi
n=\$(( \$(cat "$T/rcn" 2>/dev/null || echo 0) + 1 )); echo \$n > "$T/rcn"
line=\$(sed -n "\${n}p" "$T/scen" 2>/dev/null); [ -n "\$line" ] || line="0 d 2000000 650.5,651.2 n"
set -- \$line
echo "RCTERM check \$n (\$2)" >> "$T/seq"
rp=\$(printf '%06d' "\$run")
case "\$2" in
   d|a|c) for k in TCB FADCDAQ SADCDAQ; do cp "$FX/check-\$2-\$k.log" "$T/daqlog/\${k}_\$rp.log"; done ;;
   none)  rm -f "$T/daqlog/"*_"\$rp".log ;;
   stale) : ;;
esac
mkdir -p "$T/raw/RAW/\$rp"; truncate -s "\$3" "$T/raw/RAW/\$rp/FADC_\$rp.root.00000"
: > "\$hb"; i=0
if [ "\$4" != - ]; then for r in \$(echo "\$4" | tr , ' '); do echo "daq\$i=X n=1 sr=1 ar=\$r" >> "\$hb"; i=\$((i+1)); done; fi
[ "\$5" = y ] && { echo "daq tcb" > "$T/busy"; echo 3 > "$T/ports"; }
exit \$1
EOF
chmod +x "$T/bin/"*

cat > "$T/hook" <<EOF
DAQLOG=$T/daqlog; ARCHLOG=$T/arch; LOGDIR=$T/logdir; RAWROOT=$T/raw
RCLOG=$T/logdir/rcterm.log; SUPHB=$T/logdir/rcterm.hb
USBRESET=$T/bin/usbreset; KILLDAQ=$T/bin/killdaq; PDU=$T/bin/pdu; NOTICE=$T/bin/notice
RCTERM=$T/bin/rcterm; NOTIFY=$T/bin/notify; RCPARAMS=$T/rcterm.params; BINDIR=$T/fakebindir
POWER_STATE=$T/power.state
do_sleep()     { echo "SLEEP \$1" >> "$T/seq"; }
proc_alive()   { grep -qw -- "\$1" "$T/busy" 2>/dev/null; }
ports_open()   { cat "$T/ports" 2>/dev/null || echo 0; }
usb_has()      { ! grep -qx -- "\$1" "$T/missing" 2>/dev/null; }
dmesg_recent() { cat "$T/dmesg" 2>/dev/null; return 0; }
EOF

reset() {
   rm -rf "$T/daqlog" "$T/arch" "$T/logdir" "$T/raw"
   mkdir -p "$T/daqlog" "$T/arch/RAW_log" "$T/logdir" "$T/raw/RAW" "$T/raw/CONFIG"
   : > "$T/seq"; : > "$T/busy"; echo 0 > "$T/ports"; : > "$T/missing"; : > "$T/dmesg"; : > "$T/scen"
   rm -f "$T/rcn" "$T/pdu_rc" "$T/notice_rc" "$T/power.state" "$T/stuck" "$T/stay_missing"
   printf 'recover_enable = 1\n' > "$T/params"
}
power_on() { printf 'recover_enable = 1\nrecover_power_cycle = 1\n' > "$T/params"; }
# 실패 런 하나(4424 OVERFLOW)를 RAW_log 에 둔다 = 'USB 문제' 판정
usb_case() { cp "$FX/FADCDAQ_004424.log" "$T/arch/RAW_log/"; }
run() { env USBRECOVER_TEST_HOOK="$T/hook" bash "$S" --params "$T/params" "$@" > "$T/out" 2>&1; echo $? > "$T/rc"; }
rc()  { cat "$T/rc"; }
n_of() { grep -c "^$1" "$T/seq"; }
seqf() { grep -E "$1" "$T/seq" | awk '{ if ($1=="RCTERM") print $1" "$2; else print $1 }' | tr '\n' '|'; }

echo "[1] 진단 : 실패 런의 로그를 옮겨진 자리에서 찾는다 (U-1)"
reset; cp "$FX/FADCDAQ_004424.log" "$T/arch/RAW_log/"; run --diagnose --runs 4424
chk "RAW_log 의 FADCDAQ_004424 에서 OVERFLOW 3 건" 'grep -q "arch/RAW_log/FADCDAQ_004424.log : USB 오류 3 건" "$T/out"'
chk "USB 문제 판정 --diagnose rc 2" '[ "$(rc)" = 2 ] && grep -q "USB 문제로 판정 -> FADC" "$T/out"'
chk "--diagnose 는 usbreset·killdaq·rcterm·알림 0 회" '[ ! -s "$T/seq" ]'
reset; mkdir -p "$T/arch/RAW_log.old001" "$T/arch/RAW_log.old002"; cp "$FX/TCB_004425.log" "$T/arch/RAW_log.old001/"; run --diagnose --runs 4425
chk "RAW_log.old001 에서 TCB DRAM 실패 8 건" '[ "$(rc)" = 2 ] && grep -q "RAW_log.old001/TCB_004425.log : USB 오류 8 건" "$T/out"'
reset; cp "$FX/TCB_004425.log" "$T/daqlog/"; cp "$FX/TCB_004425.log" "$T/arch/RAW_log/"; : > "$T/arch/RAW_log/TCB_004425.log"; run --diagnose --runs 4425
chk "지금 자리(/Data_ssd/LOG)가 먼저" 'grep -q "daqlog/TCB_004425.log : USB 오류 8 건" "$T/out"'
reset; cp "$FX/TCB_004310.log" "$T/arch/RAW_log/"; run --diagnose --runs 4310
chk "TCB TIMEOUT 43 + not linked 2 = 45 건 (11.120 의 사례)" 'grep -q "TCB_004310.log : USB 오류 45 건" "$T/out" && grep -q "판정 -> TCB" "$T/out"'

echo "[2] 진단 패턴 (U-2)"
reset; cp "$FX/FADCDAQ_004427.log" "$FX/SADCDAQ_004427.log" "$T/arch/RAW_log/"; run --diagnose --runs 4427
chk "open falied 를 잡는다" 'grep -q "FADCDAQ_004427.log : USB 오류 1 건" "$T/out" && [ "$(rc)" = 2 ]'
chk "오류 없는 SADC 로그는 안 찍힌다" '! grep -q "SADCDAQ_004427.log : USB" "$T/out"'
reset; cp "$FX/check-d-FADCDAQ.log" "$T/arch/RAW_log/FADCDAQ_004500.log"; run --diagnose --runs 4500
chk "정상 'CupFADCT::Open ... opened' 줄은 오류가 아니다 -> rc 1" '[ "$(rc)" = 1 ] && grep -q "근거가 없다" "$T/out"'
reset; cp "$FX/dmesg.20261103" "$T/dmesg"; run --diagnose --runs 4500
chk "dmesg device descriptor read 만으로도 USB 판정" '[ "$(rc)" = 2 ] && grep -q "descriptor read 오류 3 건" "$T/out"'
reset; echo 0547:1502 > "$T/missing"; run --diagnose --runs 4500
chk "FADC 가 lsusb 에 없으면 USB 판정" '[ "$(rc)" = 2 ] && grep -q "안 보이는 보드 : FADC" "$T/out"'
chk "못 찾은 로그는 '못 찾음' 으로 적는다" 'grep -q "TCB_004500.log : 못 찾음" "$T/out"'

echo "[3] 최근 실패 런 = rcterm.log 'booting run' (최근 60 분) + heartbeat"
reset; NOW=$(date -d '-3 min' '+%F %T'); OLD=$(date -d '-3 hour' '+%F %T')
sed -E "s/^2026-11-03 10:3[0-9]:[0-9]{2}/$NOW/" "$FX/rcterm.log.20261103" > "$T/logdir/rcterm.log"
printf '%s [INFO] ===== cycle 1 : booting run 004300 =====\n' "$OLD" | cat - "$T/logdir/rcterm.log" > "$T/x" && mv "$T/x" "$T/logdir/rcterm.log"
printf 'time=1\nphase=failed\nrun=4423\n' > "$T/logdir/rcterm.hb"
cp "$FX/FADCDAQ_004424.log" "$T/arch/RAW_log/"; run --diagnose
chk "조사할 런 : 4423 4424 4425 4426 4427 (옛 4300 은 빠진다)" 'grep -q "조사할 런 : 4423 4424 4425 4426 4427 *$" "$T/out"'
chk "그 런의 로그를 찾아 판정" '[ "$(rc)" = 2 ] && grep -q "FADCDAQ_004424.log : USB 오류 3 건" "$T/out"'
touch -d '-2 hour' "$T/logdir/rcterm.hb"; run --diagnose
chk "오래된 heartbeat 의 런은 넣지 않는다" 'grep -q "조사할 런 : 4424 4425 4426 4427 *$" "$T/out"'
reset; run --diagnose
chk "rcterm.log 가 없으면 (없음) 으로 알리고 rc 1" '[ "$(rc)" = 1 ] && grep -q "조사할 런 : (없음" "$T/out"'

echo "[4] 안전 게이트"
for p in rcterm daq tcb merger; do
   chk "$p 살아 있으면 exit 3, 아무것도 안 함" "reset; usb_case; echo $p > \"\$T/busy\"; run --runs 4424; [ \"\$(rc)\" = 3 ] && [ ! -s \"\$T/seq\" ]"
done
chk "포트가 열려 있으면 exit 3" 'reset; usb_case; echo 1 > "$T/ports"; run --runs 4424; [ "$(rc)" = 3 ] && [ ! -s "$T/seq" ]'
chk "스크립트에 pgrep -f · pkill 없음" '! grep -qE "pgrep -f|pkill" "$S"'

echo "[5] usbreset 단계 : 시도당 2 회 · 고아 정리 · DRAM 판정 (U-3·U-4·U-5)"
reset; usb_case; printf '0 c 2000000 650,651 y\n0 d 2000000 650,651 n\n' > "$T/scen"; run --runs 4424
chk "1차 DRAM 8/8 실패 -> 2차 합격, rc 0" '[ "$(rc)" = 0 ] && grep -q "is aligned 0 / Fail to align 8" "$T/out"'
chk "순서 USBRESET x2 -> 확인 -> KILLDAQ -> USBRESET x2 -> 확인" '[ "$(seqf "^(USBRESET|KILLDAQ|RCTERM)")" = "USBRESET|USBRESET|RCTERM check|KILLDAQ|USBRESET|USBRESET|RCTERM check|" ]'
chk "killdaq 는 -b BINDIR 로" 'grep -q "^KILLDAQ -b $T/fakebindir" "$T/seq"'
chk "연속 usbreset 사이 5 s · 뒤 15 s" 'grep -A3 "^USBRESET" "$T/seq" | head -4 | tr "\n" " " | grep -q "USBRESET SLEEP 5 USBRESET SLEEP 15"'
chk "recovered 알림 (usbreset 시도 2회)" 'grep -q "^NOTIFY recovered | usbreset 시도 2회" "$T/seq"'
chk "PDU 는 부르지 않았다" '[ "$(n_of PDU)" = 0 ]'
chk "확인 런 자료를 지웠다" '[ ! -e "$T/raw/RAW/999999" ]'
chk "확인 런 로그를 증거로 남겼다" 'ls "$T"/logdir/usb-recover-*.d/check1-TCB.log >/dev/null 2>&1'
reset; usb_case; echo "0 d 2000000 650,651 n" > "$T/scen"; run --runs 4424
chk "고아 없으면 killdaq 를 부르지 않는다" '[ "$(rc)" = 0 ] && [ "$(n_of KILLDAQ)" = 0 ]'
reset; usb_case; echo "1 c 2000000 650,651 y" > "$T/scen"; touch "$T/stuck"; run --runs 4424 --max-try 3
chk "고아가 안 치워지면 시도를 멈춘다 (확인 런 1 번뿐)" '[ "$(rc)" = 2 ] && [ "$(grep -c "RCTERM check" "$T/seq")" = 1 ] && grep -q "고아를 치우지 못했다" "$T/out"'

echo "[6] 확인 런 불합격 기준 (U-5·U-6)"
one() { reset; usb_case; echo "$1" > "$T/scen"; run --runs 4424 --max-try 1; }
chk "마감 SADC TIMEOUT 1 건이면 불합격 (확인 런 a)" 'one "0 a 2000000 650,651 n"; [ "$(rc)" = 2 ] && grep -q "SADCDAQ_999999.log : USB 오류 1 건" "$T/out"'
chk "DRAM Fail 8 이면 불합격 (확인 런 c)" 'one "0 c 2000000 650,651 n"; [ "$(rc)" = 2 ] && grep -q "DRAM 이 다 맞지 않았다" "$T/out"'
chk "계수율 23,527 Hz 는 상한(20000) 초과로 불합격" 'one "0 d 2000000 23527,23500 n"; [ "$(rc)" = 2 ] && grep -q "상한을 넘는다" "$T/out"'
chk "한 ADC 만 0 Hz 면 불합격 (최솟값)" 'one "0 d 2000000 0.0,980 n"; [ "$(rc)" = 2 ] && grep -q "너무 낮다" "$T/out"'
chk "heartbeat 에 계수율이 없으면 불합격" 'one "0 d 2000000 - n"; [ "$(rc)" = 2 ] && grep -q "계수율을 읽지 못했다" "$T/out"'
chk "FADC 8 kB 면 불합격" 'one "0 d 8192 650,651 n"; [ "$(rc)" = 2 ] && grep -q "너무 작다" "$T/out"'
chk "rcterm rc 2 면 불합격" 'one "2 d 2000000 650,651 n"; [ "$(rc)" = 2 ]'
chk "TCB 로그가 없으면 불합격" 'one "0 none 2000000 650,651 n"; [ "$(rc)" = 2 ] && grep -q "TCB 로그가 없다" "$T/out"'
reset; usb_case; for k in TCB FADCDAQ SADCDAQ; do cp "$FX/check-d-$k.log" "$T/daqlog/${k}_999999.log"; touch -d '-1 hour' "$T/daqlog/${k}_999999.log"; done
echo "0 stale 2000000 650,651 n" > "$T/scen"; run --runs 4424 --max-try 1
chk "이번 런보다 오래된 TCB 로그(합격 모양이어도)는 불합격" '[ "$(rc)" = 2 ] && grep -q "오래됐다" "$T/out"'
reset; usb_case; printf 'recover_enable = 1\nrecover_max_rate = 30000\n' > "$T/params"; echo "0 d 2000000 23527,23500 n" > "$T/scen"; run --runs 4424 --max-try 1
chk "recover_max_rate 키로 상한을 바꾼다" '[ "$(rc)" = 0 ]'
reset; usb_case; printf 'recover_enable = 1\nrecover_max_try = 1\n' > "$T/params"; printf '0 c 2000000 650,651 n\n0 d 2000000 650,651 n\n' > "$T/scen"; run --runs 4424 --max-try 2
chk "--max-try 명령줄이 params 를 이긴다" '[ "$(rc)" = 0 ] && [ "$(grep -c "RCTERM check" "$T/seq")" = 2 ]'
reset; usb_case; printf 'recover_enable = 1\nrecover_check_params = %s/day.params\n' "$T" > "$T/params"; run --runs 4424
chk "recover_check_params 로 확인 런 params 를 바꾼다 (U-7)" '[ "$(rc)" = 0 ] && grep -q "params $T/day.params" "$T/out"'
reset; usb_case; run --runs 4424
chk "비우면 rcterm.params" 'grep -q "params $T/rcterm.params" "$T/out"'

echo "[7] 전원 단계 꺼짐 (키 없음 = 기본 0)"
reset; usb_case; printf '0 c 2000000 650,651 n\n0 c 2000000 650,651 n\n0 c 2000000 650,651 n\n' > "$T/scen"; run --runs 4424
chk "usbreset 3 회 실패 -> rc 2" '[ "$(rc)" = 2 ] && [ "$(grep -c "RCTERM check" "$T/seq")" = 3 ] && [ "$(n_of USBRESET)" = 6 ]'
chk "PDU·NOTICE 0 회" '[ "$(n_of PDU)" = 0 ] && [ "$(n_of NOTICE)" = 0 ]'
chk "사유 recover_power_cycle = 0 을 알린다" 'grep -q "^NOTIFY recovery_failed | .*recover_power_cycle = 0" "$T/seq"'
chk "state 파일을 안 만든다" '[ ! -e "$T/power.state" ]'

echo "[8] 전원 단계 (U-8) : 11.224 순서"
reset; usb_case; power_on; printf '0 c 2000000 650,651 n\n0 c 2000000 650,651 n\n0 c 2000000 650,651 n\n0 d 2000000 650,651 n\n' > "$T/scen"; run --runs 4424
chk "rc 0 (전원 뒤 확인 런 합격)" '[ "$(rc)" = 0 ]'
chk "PDU cycle --allow-supervisor 1 회" '[ "$(n_of PDU)" = 1 ] && grep -q "^PDU cycle --allow-supervisor$" "$T/seq"'
chk "순서 PDU -> NOTICE -> USBRESET x2 -> 더미 -> 확인" '[ "$(seqf "^(PDU|NOTICE|USBRESET|RCTERM)" | sed "s/.*RCTERM check|PDU/PDU/")" = "PDU|NOTICE|USBRESET|USBRESET|RCTERM dummy|RCTERM check|" ]'
chk "state 에 1 줄" '[ "$(wc -l < "$T/power.state")" = 1 ]'
chk "recovered 알림에 '전원 재투입'" 'grep -q "^NOTIFY recovered | 보드 전원 재투입(PDU)" "$T/seq"'
reset; usb_case; power_on; printf '0 c 2000000 650,651 n\n0 c 2000000 650,651 n\n0 c 2000000 650,651 n\n0 c 2000000 650,651 n\n0 d 2000000 650,651 n\n' > "$T/scen"; run --runs 4424
chk "전원 뒤 첫 확인 런 실패 -> usbreset 1 회 + 확인 런 -> 합격" '[ "$(rc)" = 0 ] && [ "$(seqf "^(PDU|NOTICE|USBRESET|RCTERM)" | sed "s/.*RCTERM check|PDU/PDU/")" = "PDU|NOTICE|USBRESET|USBRESET|RCTERM dummy|RCTERM check|USBRESET|RCTERM check|" ]'
reset; usb_case; power_on; for i in 1 2 3 4 5 6; do echo "0 c 2000000 650,651 n"; done > "$T/scen"; run --runs 4424
chk "전원 뒤 3 번 모두 실패 -> rc 2, 확인 런 3+3 회" '[ "$(rc)" = 2 ] && [ "$(grep -c "RCTERM check" "$T/seq")" = 6 ] && grep -q "^NOTIFY recovery_failed | .*전원 재투입 실패" "$T/seq"'
chk "전원 단계는 호출당 한 번" '[ "$(n_of PDU)" = 1 ]'

echo "[9] 전원 상한 state (6 h 에 2 회)"
reset; usb_case; power_on; N=$(date +%s); printf '%s a\n%s b\n' $((N-3600)) $((N-7200)) > "$T/power.state"
for i in 1 2 3; do echo "0 c 2000000 650,651 n"; done > "$T/scen"; run --runs 4424
chk "최근 6 h 에 2 회면 하지 않는다" '[ "$(rc)" = 2 ] && [ "$(n_of PDU)" = 0 ] && grep -q "이미 2 회" "$T/out"'
chk "state 를 늘리지 않는다" '[ "$(wc -l < "$T/power.state")" = 2 ]'
reset; usb_case; power_on; N=$(date +%s); printf '%s a\n%s b\n' $((N-7*3600)) $((N-3600)) > "$T/power.state"
for i in 1 2 3; do echo "0 c 2000000 650,651 n"; done > "$T/scen"; run --runs 4424
chk "7 h 전 것은 세지 않는다 -> 전원 단계 진행" '[ "$(n_of PDU)" = 1 ] && [ "$(wc -l < "$T/power.state")" = 3 ]'

echo "[10] 전원 단계의 실패 경로"
reset; usb_case; power_on; echo 124 > "$T/notice_rc"; for i in 1 2 3; do echo "0 c 2000000 650,651 n"; done > "$T/scen"; run --runs 4424
chk "NOTICE timeout(124) -> 중단, rc 2" '[ "$(rc)" = 2 ] && grep -q "120 s 안에 안 끝났다" "$T/out"'
chk "NOTICE 뒤 usbreset·더미·확인 런 없음" '[ "$(seqf "^(NOTICE|USBRESET|RCTERM)" | sed "s/.*NOTICE/NOTICE/")" = "NOTICE|" ]'
reset; usb_case; power_on; echo 3 > "$T/pdu_rc"; for i in 1 2 3; do echo "0 c 2000000 650,651 n"; done > "$T/scen"; run --runs 4424
chk "PDU cycle 실패(rc 3) -> NOTICE 없이 rc 2, 상태 확인 안내" '[ "$(rc)" = 2 ] && [ "$(n_of NOTICE)" = 0 ] && grep -q "pdu-power.sh status" "$T/out"'
chk "실패해도 상한 state 에는 1 회로 센다" '[ "$(wc -l < "$T/power.state")" = 1 ]'
reset; usb_case; power_on; touch "$T/stay_missing"; echo 0547:1502 > "$T/missing"; run --runs 4424
chk "전원 뒤 보드가 90 s 안에 안 보이면 rc 2, NOTICE 없음" '[ "$(rc)" = 2 ] && [ "$(n_of NOTICE)" = 0 ] && grep -q "90 s 기다려도" "$T/out"'
chk "보드 대기는 5 s 씩 최대 90 s" '[ "$(sed -n "/^PDU/,\$p" "$T/seq" | grep -c "^SLEEP 5$")" = 19 ]'
chk "FADC 가 안 보이면 usbreset 단계는 확인 런을 띄우지 않는다" '[ "$(grep -c "RCTERM check" "$T/seq")" = 0 ]'

echo "[11] --force-power-cycle"
reset; echo "0 d 2000000 650,651 n" > "$T/scen"; run --runs 4500 --force-power-cycle
chk "USB 근거 없어도 진행, recover_power_cycle = 0 이어도 진행" '[ "$(rc)" = 0 ] && [ "$(n_of PDU)" = 1 ]'
chk "usbreset 단계 없이 곧장 PDU (첫 USBRESET 은 NOTICE 뒤)" '[ "$(seqf "^(PDU|NOTICE|USBRESET)" | cut -d"|" -f1-3)" = "PDU|NOTICE|USBRESET" ]'
reset; N=$(date +%s); printf '%s a\n%s b\n' $((N-60)) $((N-120)) > "$T/power.state"; run --runs 4500 --force-power-cycle
chk "--force-power-cycle 도 6 h 상한은 지킨다" '[ "$(rc)" = 2 ] && [ "$(n_of PDU)" = 0 ]'
chk "--force-power-cycle 도 안전 게이트를 지킨다" 'reset; echo tcb > "$T/busy"; run --force-power-cycle; [ "$(rc)" = 3 ] && [ ! -s "$T/seq" ]'

echo "[12] --dry-run 은 무접촉"
for a in "" "--force-power-cycle"; do
   chk "dry-run $a : usbreset·PDU·NOTICE·rcterm·killdaq·알림 0 회, rc 0" "reset; usb_case; power_on; run --runs 4424 --dry-run $a; [ \"\$(rc)\" = 0 ] && ! grep -qE '^(USBRESET|PDU|NOTICE|RCTERM|KILLDAQ|NOTIFY)' \"\$T/seq\""
done
reset; usb_case; power_on; run --runs 4424 --dry-run
chk "dry-run 이 전원 단계 계획과 사용량을 찍는다" 'grep -q "\[DRY\] \[4/5\] 전원 단계 : killdaq" "$T/out" && grep -q "사용량 0/2" "$T/out"'
chk "dry-run 은 state 를 안 만든다" '[ ! -e "$T/power.state" ]'
reset; usb_case; run --runs 4424 --dry-run
chk "dry-run (꺼짐) : 하지 않는다 + 사유" 'grep -q "전원 단계 : 하지 않는다 (recover_power_cycle = 0)" "$T/out"'

echo "[13] 그 밖"
chk "recover_enable = 0 이면 rc 1, 아무것도 안 함" 'reset; usb_case; printf "recover_enable = 0\n" > "$T/params"; run --runs 4424; [ "$(rc)" = 1 ] && [ ! -s "$T/seq" ]'
chk "USB 근거 없음 -> rc 1, recovery_failed 알림 1 통" 'reset; run --runs 4500; [ "$(rc)" = 1 ] && [ "$(n_of NOTIFY)" = 1 ] && [ "$(n_of USBRESET)" = 0 ]'
chk "--no-notify 면 알림 0" 'reset; usb_case; run --runs 4424 --no-notify; [ "$(n_of NOTIFY)" = 0 ]'
chk "--help" 'bash "$S" --help | grep -q -- "--force-power-cycle"'
chk "bash -n" 'bash -n "$S"'
chk "hook 파일이 없으면 아무것도 안 하고 rc 1 (안전하게 --diagnose 로 시험)" 'reset; usb_case; env USBRECOVER_TEST_HOOK="$T/nohook" bash "$S" --params "$T/params" --diagnose --runs 4424 > "$T/out" 2>&1; [ $? = 1 ] && [ ! -s "$T/seq" ] && grep -q "읽을 수 없다" "$T/out"'
reset; usb_case
( cd / && env -i PATH=/usr/bin:/bin HOME="$HOME" USBRECOVER_TEST_HOOK="$T/hook" bash "$S" --params "$T/params" --diagnose --runs 4424 > "$T/out" 2>&1; echo $? > "$T/rc" )
chk "cd / + env -i 에서 --diagnose" '[ "$(rc)" = 2 ] && grep -q "USB 오류 3 건" "$T/out"'

echo "통과 $PASS / 실패 $FAIL"
[ "$FAIL" = 0 ]
