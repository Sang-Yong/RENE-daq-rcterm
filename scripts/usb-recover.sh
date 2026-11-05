#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  usb-recover.sh - 연속 실패가 USB 보드 때문인지 판정하고, 맞으면
#                   usbreset -> (그래도 안 되면) PDU 전원 재투입으로 자동 복구한다.
#
#  2026-08-20 의 장애(FADC 보드가 걸려 런 5개가 연속 실패)에서 사람이 손으로
#  밟은 절차를 코드로 옮긴 것이다 (CLAUDE.md 11.49~11.51). 2026-11-05 에
#  11.119 · 11.130 · 11.171 · 11.208 · 11.223~11.225 의 실측 절차로 다시 짰다.
#
#  사용 :
#     usb-recover.sh [--params <파일>] [--max-try N] [--runs 4424,4425] [--dry-run] [--no-notify]
#     usb-recover.sh --diagnose          진단만 하고 끝낸다 (읽기 전용, 수집 중에도 안전)
#     usb-recover.sh --force-power-cycle usbreset 단계를 건너뛰고 바로 전원 단계 (사람·시험 입구)
#
#  단계
#     [1] 안전 게이트  rcterm·daq·tcb·merger 가 하나라도 살아 있거나 포트가 열려 있으면 exit 3
#     [2] 진단         최근 실패 런(rcterm.log 의 'booting run' + 감시자 heartbeat)의
#                      TCB/FADCDAQ/SADCDAQ 로그를 /Data_ssd/LOG -> /scratch/DAQ_LOG/RAW_log{,.old*}
#                      에서 찾아 USB 오류를 센다. 보드가 lsusb 에 없거나 dmesg 에
#                      'device descriptor read' 가 있어도 USB 문제다
#     [3] usbreset     시도마다 고아 정리(killdaq) -> usbreset 2 회 연속 -> 확인 런. 최대 recover_max_try 회
#     [4] 전원 재투입  (recover_power_cycle = 1 일 때, 6 h 에 2 회까지)
#                      killdaq -> pdu-power.sh cycle --allow-supervisor -> 보드 3 종 대기(90 s)
#                      -> NOTICE_CODE_RUN.sh (120 s 제한) -> usbreset 2 회 -> 10 s 더미 런
#                      -> 확인 런 (실패하면 usbreset 1 회 + 확인 런을 2 회 더)
#     확인 런 합격 = rcterm exit 0 · TCB 로그 'is aligned' 8 줄 · 'Fail to align' 0 ·
#                    TCB/FADCDAQ/SADCDAQ 의 LIBUSB·TIMEOUT·OVERFLOW 0 (마감 포함) ·
#                    FADC 파일 1 MB 이상 · ADC 별 계수율 recover_min_rate 이상 recover_max_rate 이하
#
#  종료코드 (감시자가 이 값으로 다음 행동을 정한다)
#     0  복구했다. 수집을 이어도 된다   (--dry-run 도 0)
#     1  USB 문제가 아니다. 다른 원인이므로 손대지 않았다
#     2  USB 문제인데 복구하지 못했다. ★ 사람이 현장에 가야 한다
#     3  안전 조건이 아니라 아무것도 하지 않았다 (수집이 돌고 있다 등)
#
#  ★★ usbreset 과 전원 재투입은 진행 중인 런을 깨뜨린다. 그래서 맨 처음에
#     '아무것도 돌고 있지 않다'를 확인하고, 하나라도 살아 있으면 exit 3.
#     이 게이트를 없애지 말 것. 감시자(rcsupervisor)는 결과를 기다리는 중이라 예외다.
#  시험 : USBRECOVER_TEST_HOOK 에 적은 파일을 source 해 usbreset·lsusb·rcterm·
#         pdu-power·NOTICE·killdaq·sleep 을 갈아끼운다 (tests/usb-recover.test.sh)
# ---------------------------------------------------------------------
set -u

DIR=$(cd "$(dirname "$0")/.." && pwd)
PARAMS=$DIR/config/notify.params
NOTIFY=$DIR/scripts/daq-notify.sh
USBRESET=$DIR/src/usbreset
NOTICE=$DIR/src/NOTICE_CODE_RUN.sh
PDU=$DIR/scripts/pdu-power.sh
KILLDAQ=$DIR/scripts/killdaq.sh
RCTERM=$DIR/install/bin/rcterm
RCPARAMS=$DIR/config/rcterm.params
CHECKPARAMS=""           # 확인 런에 쓸 rcterm params. 비우면 RCPARAMS

BINDIR=/home/frontend/DAQ/DAQ_cup/install/bin
RAWROOT=/Data_ssd
DAQLOG=/Data_ssd/LOG                  # 지금 쓰이는 DAQ 로그
ARCHLOG=/scratch/DAQ_LOG              # logrotate 가 옮긴 자리 (RAW_log/ · RAW_log.old*/)
LOGDIR=/Data/LOG
RCLOG=$LOGDIR/rcterm.log              # 'booting run 00NNNN' 줄에서 실패 런 번호를 읽는다
SUPHB=$LOGDIR/rcterm.hb               # 감시자 쪽 heartbeat (마지막으로 돌던 런)
TCBPORT=7809; FADCPORT=7814; SADCPORT=7815

DIAGNOSE=0               # 1 이면 읽기만 하고 판정만 낸다
MAXTRY=3                 # usbreset 단계 시도 수 (시도마다 usbreset 2 회)
RESETS=2                 # 시도당 usbreset 횟수. 2~3 회째에 DRAM 이 맞았다 (11.130·171·224·225)
RESETGAP=5               # 연속 usbreset 사이 [s]
SETTLE=15
CHECKLEN=0.05            # 확인 런 길이 [시간] = 3분
CHECKRUN=999999
MINRATE=500
MAXRATE=20000            # 설정 소실(23,527 Hz, 11.119)·포화(42 kHz, 11.227) 를 합격시키지 않는다
MINBYTES=1000000
DRAMN=8                  # 확인 런 TCB 로그에 'is aligned' 가 이만큼 있어야 한다
KEEPDATA=0
LOGAGEMIN=60             # 이 시간[분] 안의 'booting run' 줄과 dmesg 만 본다
SCANRUNS=6               # 최근 실패 런을 몇 개까지 볼까 (감시자 한계 5 + 그 전 런)
RECOVER_ENABLE=1
POWER_ENABLE=0           # ★ 키가 없으면 꺼짐. git pull 만으로 전원을 내리기 시작하면 안 된다
POWER_MAX=2              # POWER_WINDOW_H 시간에 전원 재투입 최대 횟수 (무한 순환 방지)
POWER_WINDOW_H=6
POWER_STATE=/Data_ssd/LOG/usb-recover.power.state
POWER_USB_WAIT=90        # 전원을 올린 뒤 보드 3 종이 lsusb 에 보일 때까지 [s]
NOTICE_TIMEOUT=120       # NOTICE_CODE_RUN.sh 제한 [s]. TCB 가 멈췄으면 출력 없이 매달린다 (11.119)
DUMMYLEN=0.0028          # 더미 런 길이 [시간] = 10 s (11.224)
POWER_EXTRA=2            # 전원 뒤 확인 런이 떨어지면 usbreset 1 회 + 확인 런을 몇 번 더
FORCE_POWER=0
RUNS_ARG=""
DRY=0; NOTIFY_ON=1
CLI_MAXTRY=""

# NOTICE 보드 셋. usbreset 은 이 VID 를 전부 리셋한다 (개별 지정 불가)
BOARDS="FADC:0547:1502 TCB:0547:1501 SADC:0547:1503"

load_params() {
   local f=$1 line k v
   [ -r "$f" ] || return 0
   while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      case "$line" in *=*) ;; *) continue ;; esac
      k=${line%%=*}; v=${line#*=}
      k=$(printf '%s' "$k" | tr -d ' \t' | tr 'A-Z-' 'a-z_')
      v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      case "$k" in
         recover_enable)          RECOVER_ENABLE=$v ;;
         recover_max_try)         MAXTRY=$v ;;
         recover_resets_per_try)  RESETS=$v ;;
         recover_settle_sec)      SETTLE=$v ;;
         recover_check_min)       CHECKLEN=$v ;;
         recover_check_run)       CHECKRUN=$v ;;
         recover_check_params)    CHECKPARAMS=$v ;;
         recover_min_rate)        MINRATE=$v ;;
         recover_max_rate)        MAXRATE=$v ;;
         recover_log_age_min)     LOGAGEMIN=$v ;;
         recover_scan_runs)       SCANRUNS=$v ;;
         recover_keep_data)       KEEPDATA=$v ;;
         recover_log_archive)     ARCHLOG=$v ;;
         recover_power_cycle)     POWER_ENABLE=$v ;;
         recover_power_max)       POWER_MAX=$v ;;
         recover_power_window_h)  POWER_WINDOW_H=$v ;;
         recover_power_state)     POWER_STATE=$v ;;
         recover_notice_timeout)  NOTICE_TIMEOUT=$v ;;
         *) : ;;
      esac
   done < "$f"
}

while [ $# -gt 0 ]; do
   case "$1" in
      --params)     PARAMS=$2; shift 2 ;;
      --max-try)    CLI_MAXTRY=$2; shift 2 ;;
      --bindir)     BINDIR=$2; shift 2 ;;
      --rcterm)     RCTERM=$2; shift 2 ;;
      --runs)       RUNS_ARG=$2; shift 2 ;;
      --dry-run)    DRY=1; shift ;;
      --diagnose)   DIAGNOSE=1; NOTIFY_ON=0; shift ;;
      --force-power-cycle) FORCE_POWER=1; shift ;;
      --no-notify)  NOTIFY_ON=0; shift ;;
      -h|--help)    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *)            echo "모르는 인자 : $1" >&2; exit 1 ;;
   esac
done
load_params "$PARAMS"
[ -n "$CLI_MAXTRY" ] && MAXTRY=$CLI_MAXTRY        # 명령줄이 params 를 이긴다

# ---- 바깥과 닿는 동작은 전부 이 함수들을 거친다 (시험이 갈아끼운다) ----
do_sleep()     { sleep "$1"; }
proc_alive()   { pgrep -x "$1" >/dev/null 2>&1; }        # ★ -x 만 쓴다 (저장소 경로에 rcterm 이 들어 있어 -f 는 자기 셸을 잡는다)
ports_open()   { ss -ltn 2>/dev/null | grep -cE ":($TCBPORT|$FADCPORT|$SADCPORT)\b"; return 0; }
usb_has()      { lsusb -d "$1" >/dev/null 2>&1; }
dmesg_recent() { dmesg --since "-${LOGAGEMIN}min" 2>/dev/null; return 0; }
run_usbreset() { "$USBRESET"; }
run_rcterm()   { "$RCTERM" "$@"; }
run_killdaq()  { "$KILLDAQ" -b "$BINDIR"; }
run_pdu_cycle(){ "$PDU" cycle --allow-supervisor; }
run_notice()   { timeout "$NOTICE_TIMEOUT" "$NOTICE"; }
now_epoch()    { date +%s; }

if [ -n "${USBRECOVER_TEST_HOOK:-}" ]; then
   #  ★ 못 읽으면 멈춘다. 그대로 가면 시험이 진짜 usbreset·PDU 를 부른다
   [ -r "$USBRECOVER_TEST_HOOK" ] || { echo "USBRECOVER_TEST_HOOK 을 읽을 수 없다 : $USBRECOVER_TEST_HOOK" >&2; exit 1; }
   # shellcheck disable=SC1090
   . "$USBRECOVER_TEST_HOOK" || { echo "USBRECOVER_TEST_HOOK 실패" >&2; exit 1; }
fi
[ -n "$CHECKPARAMS" ] || CHECKPARAMS=$RCPARAMS

STAMP=$(date '+%Y%m%d-%H%M%S')
mkdir -p "$LOGDIR" 2>/dev/null || true
DETAIL=$LOGDIR/usb-recover-$STAMP.log
EVID=$LOGDIR/usb-recover-$STAMP.d     # 확인 런마다 DAQ 로그 세 개를 남긴다

say()  { printf '%s %s\n' "$(date '+%F %T')" "$*"; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$DETAIL" 2>/dev/null; }
note() { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$DETAIL" 2>/dev/null; }
notify() {   # 알림이 실패해도 흐름을 막지 않는다
   [ "$NOTIFY_ON" -eq 1 ] || return 0
   "$NOTIFY" --params "$PARAMS" "$1" --msg "$2" --detail-file "$DETAIL" >/dev/null 2>&1
   return 0
}

note "=============================================================="
note " usb-recover  $(date '+%F %T')   호스트 $(hostname)"
note "=============================================================="

if [ "$RECOVER_ENABLE" != "1" ] && [ "$FORCE_POWER" -eq 0 ]; then
   say "recover_enable = 0 이라 자동 복구를 하지 않는다."
   exit 1
fi

# =====================================================================
#  1단계 — 안전 게이트.  하나라도 살아 있으면 절대 리셋하지 않는다
# =====================================================================
busy_now() {              # 살아 있는 것을 찍는다. 없으면 빈 문자열
   local p s=""
   for p in rcterm daq tcb merger; do proc_alive "$p" && s="$s $p"; done
   local n; n=$(ports_open); n=${n:-0}
   [ "$n" -gt 0 ] && s="$s 포트${n}개"
   printf '%s' "$s"
}
if [ "$DIAGNOSE" -eq 1 ]; then
   say "[1/5] 안전 확인 — 건너뜀 (--diagnose : 읽기만 한다)"
else
   say "[1/5] 안전 확인 — 지금 아무것도 돌고 있지 않아야 한다"
   ALIVE=$(busy_now)
   if [ -n "$ALIVE" ]; then
      say "★ 수집이 살아 있다 (${ALIVE# })."
      say "  보드를 리셋하면 진행 중인 런이 깨진다. 아무것도 하지 않고 물러난다."
      exit 3
   fi
   note "  프로세스 없음, 포트 $TCBPORT/$FADCPORT/$SADCPORT 비어 있음 -> 진행해도 된다"
fi

# =====================================================================
#  2단계 — 진단. 정말 USB 문제인가?
# =====================================================================
say "[2/5] 진단 — 최근 실패가 USB 때문인가"

#  주의: grep -c 는 0건일 때도 '0' 을 찍으면서 종료코드 1 을 낸다.
#        여기에 '|| echo 0' 을 붙이면 '0' 이 두 줄 나와 뒤의 산술이 깨진다.
#  그물 (11.120 · 11.169 · 11.227 의 실물 로그로 넓혔다)
#      LIBUSB_ERROR_              TIMEOUT · IO · OVERFLOW · NO_DEVICE 전부
#      Fail to align DRAM         FADC 이벤트 버퍼가 안 올라온다. 설정은 '성공' 으로 끝난다
#      no module linked · is enabled but not linked     TCB 가 모듈을 못 본다
#      open falied                'CupFADCT::Open: ... open falied, check connection and power'
#                                 ★ 'CupFADCT::Open' 만으로는 안 된다 -- 정상 로그에도
#                                   'CupFADCT::Open: FADCT [sid=3]: opened' 가 있다 (실물 FADCDAQ_004424)
USB_RE='LIBUSB_ERROR_\|USB3Read: read error\|USB3ReadReg: read error\|error in reading buffer count\|Fail to align DRAM\|no module linked\|is enabled but not linked\|open falied'
usb_err_count() {         # 로그 파일 하나의 USB 오류 건수
   [ -r "$1" ] || { echo 0; return 0; }
   grep -c "$USB_RE" "$1" 2>/dev/null
   return 0
}

#  로그 찾기 -- postrun.sh 의 find_tcblog 와 같은 규칙 (지금 자리 -> RAW_log -> RAW_log.old* 최신부터 -> 평면)
#  ★ 실패 런의 로그는 postrun 의 logrotate 가 몇 분 안에 RAW_log/ 로 옮긴다.
#    /Data_ssd/LOG 만 보면 그것을 못 본다 (11.169 에서 그렇게 놓쳤다)
find_daqlog() {           # kind run_pad -> 경로. 못 찾으면 rc 1
   local kind=$1
   local base="${kind}_${2}.log" d
   [ -r "$DAQLOG/$base" ]             && { echo "$DAQLOG/$base"; return 0; }
   [ -r "$ARCHLOG/RAW_log/$base" ]    && { echo "$ARCHLOG/RAW_log/$base"; return 0; }
   for d in $(ls -dU "$ARCHLOG/RAW_log".old* 2>/dev/null | sort -r); do
      [ -r "$d/$base" ] && { echo "$d/$base"; return 0; }
   done
   [ -r "$ARCHLOG/$base" ]            && { echo "$ARCHLOG/$base"; return 0; }
   return 1
}

#  최근 실패 런 = rcterm.log 의 최근 'booting run' 줄 (LOGAGEMIN 분 안) + 감시자 heartbeat 의 run
#  ★ 옛 장애의 로그가 남아 있으므로 '최신 파일 N 개' 로 보면 지금과 무관한 실패로 오진한다.
#    런 번호로 고르면 그 런의 로그가 어디로 옮겨졌든 찾는다.
recent_runs() {
   if [ -n "$RUNS_ARG" ]; then printf '%s\n' "$RUNS_ARG" | tr ', ' '\n\n' | grep -E '^[0-9]+$'; return 0; fi
   local cut; cut=$(date -d "-${LOGAGEMIN} min" '+%F %T' 2>/dev/null)
   {
      if [ -r "$RCLOG" ]; then
         tail -n 20000 "$RCLOG" 2>/dev/null \
         | awk -v c="$cut" '/booting run [0-9]+/ { t=$1" "$2; if (t >= c) { for (i=1;i<=NF;i++) if ($i=="run") print $(i+1)+0 } }' \
         | tail -n "$SCANRUNS"
      fi
      if [ -r "$SUPHB" ] && [ -n "$(find "$SUPHB" -mmin "-$LOGAGEMIN" 2>/dev/null)" ]; then
         sed -n 's/^run=\([0-9][0-9]*\).*/\1/p' "$SUPHB" | head -1
      fi
   } | awk 'NF && !s[$1]++' | sort -n
}

RUNS=$(recent_runs | tr '\n' ' ')
note "  조사할 런 : ${RUNS:-(없음 — rcterm.log 에 최근 ${LOGAGEMIN}분의 'booting run' 이 없다)}"
FADC_ERR=0; SADC_ERR=0; TCB_ERR=0; SUSPECT=""
for r in $RUNS; do
   rp=$(printf '%06d' "$r")
   for kind in FADCDAQ SADCDAQ TCB; do
      f=$(find_daqlog "$kind" "$rp") || { note "  ${kind}_${rp}.log : 못 찾음"; continue; }
      n=$(usb_err_count "$f"); n=${n:-0}
      [ "$n" -gt 0 ] || continue
      note "  $f : USB 오류 $n 건"
      case $kind in FADCDAQ) FADC_ERR=$((FADC_ERR+n)) ;; SADCDAQ) SADC_ERR=$((SADC_ERR+n)) ;; TCB) TCB_ERR=$((TCB_ERR+n)) ;; esac
   done
done
[ "$FADC_ERR" -gt 0 ] && SUSPECT="$SUSPECT FADC"
[ "$SADC_ERR" -gt 0 ] && SUSPECT="$SUSPECT SADC"
[ "$TCB_ERR"  -gt 0 ] && SUSPECT="$SUSPECT TCB"

# 커널이 장치를 못 읽는다 (11.169 · 11.227 : 'device descriptor read/8, error -110')
DM=$(dmesg_recent | grep -c 'device descriptor read\|device not accepting address')
DM=${DM:-0}
if [ "$DM" -gt 0 ]; then note "  dmesg 최근 ${LOGAGEMIN}분 : device descriptor read 오류 $DM 건"; SUSPECT="$SUSPECT dmesg"; fi

# 보드가 아예 USB 에서 사라졌는가? 그것도 USB 문제다 (걸린 것보다 더 나쁘다).
missing_boards() { local b nm vid m=""; for b in $BOARDS; do nm=${b%%:*}; vid=${b#*:}; usb_has "$vid" || m="$m $nm"; done; printf '%s' "$m"; }
MISSING=$(missing_boards)
if [ -n "$MISSING" ]; then
   note "  ★ USB 에서 안 보이는 보드 :$MISSING"
   SUSPECT="$SUSPECT$MISSING"
else
   note "  NOTICE 보드 셋 다 USB 에 보인다"
fi

if [ -z "$SUSPECT" ] && [ "$FORCE_POWER" -eq 0 ]; then
   say "USB 오류의 근거가 없다. 다른 원인이므로 usbreset 을 돌리지 않는다."
   say "  (조사한 런의 TCB · FADCDAQ · SADCDAQ 로그와 dmesg 에 USB 오류가 없고 보드 셋 다 보인다)"
   say "  ★ 계수가 0 인데 여기까지 왔다면 검출기 쪽을 볼 것 — PMT HV 가 먼저다 (11.131)"
   notify recovery_failed "연속 실패했으나 USB 문제는 아니다 - 사람이 원인을 봐야 한다"
   exit 1
fi
if [ -n "$SUSPECT" ]; then
   say "USB 문제로 판정 ->${SUSPECT}."
else
   say "USB 근거는 없으나 --force-power-cycle 이라 전원 단계로 간다."
fi

if [ "$DIAGNOSE" -eq 1 ]; then
   say "(--diagnose 라 여기서 끝낸다. 실제로 복구하려면 이 옵션 없이 돌릴 것)"
   exit 2
fi

# =====================================================================
#  공통 동작
# =====================================================================
boards_present() {
   local m; m=$(missing_boards)
   [ -z "$m" ] && return 0
   note "  아직 안 보이는 보드 :$m"
   return 1
}

wait_boards() {           # $1 초 안에 보드 셋이 보이면 0
   local t=0
   while [ "$t" -le "$1" ]; do
      [ -z "$(missing_boards)" ] && { note "  NOTICE 보드 셋 다 보인다 (${t} s)"; return 0; }
      do_sleep 5; t=$((t+5))
   done
   note "  ★ ${1} s 기다려도 보드가 다 안 보인다 :$(missing_boards)"
   return 1
}

#  확인 런·실패 런이 남긴 고아 daq/tcb 를 치우고 포트가 비었는지 본다.
#  ★ 이것이 없으면 첫 확인 런이 실패한 뒤의 시도는 전부 포트 가드에 걸려 헛돈다 (U-3)
orphans_clear() {
   local s t
   s=$(busy_now)
   if [ -n "$s" ]; then
      note "  고아 정리 : ${s# } -> killdaq.sh -b $BINDIR"
      run_killdaq >> "$DETAIL" 2>&1
   fi
   for t in 1 2 3 4 5; do
      s=$(busy_now)
      [ -z "$s" ] && return 0
      do_sleep 2
   done
   note "  ★ 고아를 치우지 못했다 : ${s# }"
   return 1
}

usbreset_n() {            # $1 회 연속 usbreset -> SETTLE 대기
   local i rc
   if [ ! -x "$USBRESET" ]; then
      note "  ★ usbreset 이 없거나 실행할 수 없다 : $USBRESET"
      return 1
   fi
   for (( i=1; i<=$1; i++ )); do
      run_usbreset >> "$DETAIL" 2>&1; rc=$?
      note "  usbreset $i/$1 종료코드 : $rc"
      [ "$i" -lt "$1" ] && do_sleep "$RESETGAP"
   done
   note "  보드가 다시 잡힐 때까지 ${SETTLE}초 대기"
   do_sleep "$SETTLE"
   return 0
}

CHK_N=0
check_run() {             # $1 = 시험 이름 (증거 폴더용). 합격이면 0
   local hb=$LOGDIR/usb-recover-check.hb
   local rp; rp=$(printf '%06d' "$CHECKRUN")
   local rawdir=$RAWROOT/RAW/$rp
   CHK_N=$((CHK_N+1))
   rm -rf "$rawdir" 2>/dev/null
   rm -f "$hb" 2>/dev/null

   note "  확인 런 #$CHK_N ($1) : run $CHECKRUN, ${CHECKLEN} 시간, params $CHECKPARAMS"
   local t0; t0=$(now_epoch)
   run_rcterm --params "$CHECKPARAMS" --no-db --run "$CHECKRUN" \
              --max-runs 1 --run-length "$CHECKLEN" --quiet \
              --heartbeat "$hb" \
              --desc "usb-recover board check" >> "$DETAIL" 2>&1
   local rc=$?
   note "  rcterm 종료코드 : $rc"

   # 증거 : 이 확인 런의 DAQ 로그 세 개를 남긴다 (다음 런이 같은 이름을 덮어쓴다)
   local k f
   mkdir -p "$EVID" 2>/dev/null
   for k in TCB FADCDAQ SADCDAQ; do
      f=$DAQLOG/${k}_$rp.log
      [ -r "$f" ] && cp -p "$f" "$EVID/check${CHK_N}-${k}.log" 2>/dev/null
   done
   [ "$rc" -ne 0 ] && return 1

   # (a) DRAM 정렬. 계수가 나와도 DRAM 이 안 맞았을 수 있다 (11.171 · 11.208)
   local tl=$DAQLOG/TCB_$rp.log al fa
   if [ ! -r "$tl" ]; then note "  ★ TCB 로그가 없다 : $tl"; return 1; fi
   if [ "$(stat -c %Y "$tl" 2>/dev/null || echo 0)" -lt "$t0" ]; then
      note "  ★ TCB 로그가 이번 확인 런보다 오래됐다 (옛 로그) : $tl"; return 1
   fi
   al=$(grep -c 'is aligned' "$tl" 2>/dev/null); al=${al:-0}
   fa=$(grep -c 'Fail to align' "$tl" 2>/dev/null); fa=${fa:-0}
   note "  DRAM : is aligned $al / Fail to align $fa (합격 $DRAMN / 0)"
   if [ "$al" -lt "$DRAMN" ] || [ "$fa" -gt 0 ]; then note "  ★ DRAM 이 다 맞지 않았다"; return 1; fi

   # (b) 세 로그 모두 USB 오류 0. 마감 읽기의 TIMEOUT 도 실패다 -- 다음 부팅이 OVERFLOW 로 죽는다 (11.223)
   local ce=0 n
   for k in TCB FADCDAQ SADCDAQ; do
      f=$DAQLOG/${k}_$rp.log
      [ -r "$f" ] || { note "  ★ ${k} 로그가 없다"; return 1; }
      n=$(grep -c "$USB_RE\|TIMEOUT\|OVERFLOW" "$f" 2>/dev/null); n=${n:-0}
      [ "$n" -gt 0 ] && note "  ${k}_$rp.log : USB 오류 $n 건"
      ce=$((ce+n))
   done
   note "  확인 런의 USB 오류 : $ce 건"
   [ "$ce" -gt 0 ] && return 1

   # (c) 실제로 자료가 쌓였는가. 걸린 보드는 8 kB 짜리 빈 껍데기만 남긴다
   local bytes
   bytes=$(find "$rawdir" -maxdepth 1 -name 'FADC_*.root.*' -printf '%s\n' 2>/dev/null \
           | awk '{s+=$1} END {print s+0}')
   note "  FADC 산출 : ${bytes:-0} bytes"
   [ "${bytes:-0}" -lt "$MINBYTES" ] && { note "  ★ 너무 작다. 이벤트가 들어오지 않았다"; return 1; }

   # (d) 계수율. heartbeat 의 daqN= 줄의 ar= (ADC 별 평균).
   #  ★ 최솟값과 최댓값을 따로 본다 -- 한 보드만 죽으면 합·평균은 멀쩡해 보이고,
   #    설정이 날아가면 모든 ADC 가 20 배가 된다
   local mm
   mm=$(sed -n 's/.* ar=\([0-9.]*\).*/\1/p' "$hb" 2>/dev/null \
        | awk 'NR==1{lo=$1;hi=$1} $1<lo{lo=$1} $1>hi{hi=$1} END{ if (NR) printf "%.1f %.1f", lo, hi }')
   if [ -z "$mm" ]; then
      note "  ★ heartbeat 에서 계수율을 읽지 못했다 ($hb) -- 상한을 볼 수 없으니 불합격으로 본다"
      return 1
   fi
   note "  ADC 별 계수율 : 최소 ${mm% *} Hz · 최대 ${mm#* } Hz (범위 ${MINRATE} ~ ${MAXRATE} Hz)"
   awk -v r="${mm% *}" -v m="$MINRATE" 'BEGIN{ exit !(r+0 >= m+0) }' || { note "  ★ 어느 ADC 의 계수율이 너무 낮다"; return 1; }
   awk -v r="${mm#* }" -v m="$MAXRATE" 'BEGIN{ exit !(r+0 <= m+0) }' || {
      note "  ★ 계수율이 상한을 넘는다 -- 트리거 설정이 날아갔거나(NOTICE_CODE_RUN.sh) 포화다"; return 1; }
   return 0
}

cleanup_check() {
   rm -f "$LOGDIR/usb-recover-check.hb" 2>/dev/null
   [ "$KEEPDATA" = "1" ] && { note "  확인 런 자료를 남긴다 (recover_keep_data = 1)"; return 0; }
   rm -rf "$RAWROOT/RAW/$(printf '%06d' "$CHECKRUN")" 2>/dev/null
   rm -f "$RAWROOT/CONFIG/$(printf '%06d' "$CHECKRUN").config" 2>/dev/null
   note "  확인 런 자료를 지웠다"
}

power_used() {            # 최근 POWER_WINDOW_H 시간의 전원 재투입 횟수
   local now; now=$(now_epoch)
   [ -r "$POWER_STATE" ] || { echo 0; return 0; }
   awk -v c=$((now - POWER_WINDOW_H*3600)) '$1+0 >= c { n++ } END { print n+0 }' "$POWER_STATE" 2>/dev/null
}

power_allowed() {         # 허용이면 0. 아니면 사유를 POWER_WHY 에
   POWER_WHY=""
   if [ "$POWER_ENABLE" != "1" ] && [ "$FORCE_POWER" -eq 0 ]; then POWER_WHY="recover_power_cycle = 0"; return 1; fi
   local u; u=$(power_used)
   if [ "${u:-0}" -ge "$POWER_MAX" ]; then
      POWER_WHY="최근 ${POWER_WINDOW_H} h 에 이미 ${u} 회 ($POWER_STATE, 상한 $POWER_MAX)"; return 1
   fi
   return 0
}

# =====================================================================
#  --dry-run : 계획만 찍는다. usbreset·PDU·NOTICE·rcterm·killdaq 0 회, state 무변경
# =====================================================================
if [ "$DRY" -eq 1 ]; then
   if [ "$FORCE_POWER" -eq 0 ]; then
      say "[DRY] [3/5] usbreset 단계 : ${MAXTRY} 회 x (killdaq -> usbreset ${RESETS} 회 -> ${SETTLE} s -> 확인 런 $CHECKLEN h)"
   else
      say "[DRY] [3/5] usbreset 단계 : 건너뜀 (--force-power-cycle)"
   fi
   if power_allowed; then
      say "[DRY] [4/5] 전원 단계 : killdaq -> $PDU cycle --allow-supervisor (TCB 먼저, 30 s 뒤 FADC·SADC)"
      say "[DRY]       -> 보드 3 종 ${POWER_USB_WAIT} s 대기 -> timeout ${NOTICE_TIMEOUT} NOTICE_CODE_RUN.sh -> usbreset 2 회"
      say "[DRY]       -> 더미 런 ${DUMMYLEN} h -> 확인 런 (실패 시 usbreset 1 회 + 확인 런 ${POWER_EXTRA} 회 더)"
      say "[DRY]       전원 재투입 사용량 $(power_used)/${POWER_MAX} (최근 ${POWER_WINDOW_H} h)"
   else
      say "[DRY] [4/5] 전원 단계 : 하지 않는다 ($POWER_WHY)"
   fi
   say "[DRY] 아무것도 하지 않았다."
   exit 0
fi

# =====================================================================
#  3단계 — usbreset + 확인 런.  최대 MAXTRY 회, 시도마다 usbreset RESETS 회
# =====================================================================
TRY=0; OK=0; HOW=""
if [ "$FORCE_POWER" -eq 1 ]; then
   say "[3/5] usbreset 단계 — 건너뜀 (--force-power-cycle)"
else
   say "[3/5] usbreset — 최대 ${MAXTRY} 회 (시도마다 ${RESETS} 회 연속)"
   while [ "$TRY" -lt "$MAXTRY" ]; do
      TRY=$((TRY+1))
      say "  --- 시도 $TRY/$MAXTRY ---"
      orphans_clear || { say "  고아가 남아 확인 런을 띄울 수 없다. usbreset 단계를 그만둔다."; break; }
      usbreset_n "$RESETS" || break
      if ! boards_present; then
         say "  보드가 아직 USB 에 다 보이지 않는다. 다음 시도로 넘어간다."
         continue
      fi
      if check_run "usbreset-$TRY"; then
         say "  ✓ 확인 런 통과. 복구됐다."
         cleanup_check
         OK=1; HOW="usbreset 시도 ${TRY}회 (시도당 ${RESETS}회)"
         break
      fi
      say "  확인 런 실패. 다음 시도로 넘어간다."
      cleanup_check
   done
fi

# =====================================================================
#  4단계 — 전원 재투입 (11.224 의 순서). 복구 호출당 1 회, 6 h 에 2 회까지
# =====================================================================
power_stage() {
   say "[4/5] 보드 전원 재투입 (PDU)"
   orphans_clear || { POWER_FAIL="고아를 치우지 못해 전원을 내리지 않았다"; return 1; }
   # 먼저 적는다 -- cycle 이 도중에 실패해도 한 번 쓴 것으로 센다 (무한 순환 방지)
   mkdir -p "$(dirname "$POWER_STATE")" 2>/dev/null
   printf '%s %s\n' "$(now_epoch)" "$STAMP" >> "$POWER_STATE" 2>/dev/null \
      || note "  [WARN] 상한 기록을 남기지 못했다 : $POWER_STATE"
   run_pdu_cycle >> "$DETAIL" 2>&1
   local rc=$?
   note "  pdu-power.sh cycle 종료코드 : $rc"
   if [ "$rc" -ne 0 ]; then
      POWER_FAIL="PDU cycle rc=$rc -- 보드 전원이 꺼져 있을 수 있다. scripts/pdu-power.sh status 로 볼 것"
      return 1
   fi
   wait_boards "$POWER_USB_WAIT" || { POWER_FAIL="전원을 올렸으나 보드가 USB 에 다 안 잡힌다"; return 1; }
   note "  NOTICE_CODE_RUN.sh (제한 ${NOTICE_TIMEOUT} s) -- 전원을 내리면 트리거 설정이 날아간다"
   run_notice >> "$DETAIL" 2>&1
   rc=$?
   note "  NOTICE_CODE_RUN.sh 종료코드 : $rc"
   if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 124 ]; then
         POWER_FAIL="NOTICE_CODE_RUN.sh 가 ${NOTICE_TIMEOUT} s 안에 안 끝났다 (TCB 가 응답하지 않는다, 11.225)"
      else
         POWER_FAIL="NOTICE_CODE_RUN.sh rc=$rc"
      fi
      return 1
   fi
   usbreset_n 2 || { POWER_FAIL="usbreset 을 실행할 수 없다"; return 1; }
   note "  10 s 더미 런 (첫 런은 DRAM 이 안 맞는 일이 많다, 11.224)"
   run_rcterm --params "$CHECKPARAMS" --no-db --run "$CHECKRUN" --max-runs 1 \
              --run-length "$DUMMYLEN" --quiet --heartbeat "$LOGDIR/usb-recover-check.hb" \
              --desc "usb-recover dummy run" >> "$DETAIL" 2>&1
   note "  더미 런 종료코드 : $? (판정에 쓰지 않는다)"
   cleanup_check
   local k
   for (( k=0; k<=POWER_EXTRA; k++ )); do
      if [ "$k" -gt 0 ]; then
         note "  --- 전원 뒤 추가 시도 $k/$POWER_EXTRA : usbreset 1 회 + 확인 런 ---"
         usbreset_n 1 || break
      fi
      orphans_clear || { POWER_FAIL="고아를 치우지 못했다"; return 1; }
      boards_present || continue
      if check_run "power-$k"; then cleanup_check; POWER_TRIES=$k; return 0; fi
      cleanup_check
   done
   POWER_FAIL="전원 재투입 뒤 확인 런이 $((POWER_EXTRA+1)) 번 모두 불합격"
   return 1
}

POWER_FAIL=""; POWER_TRIES=0; POWER_DONE=0; POWER_WHY=""
if [ "$OK" -eq 0 ]; then
   if power_allowed; then
      POWER_DONE=1
      if power_stage; then
         OK=1; HOW="보드 전원 재투입(PDU) + NOTICE_CODE_RUN + usbreset (추가 시도 ${POWER_TRIES}회)"
         say "  ✓ 전원 재투입 뒤 확인 런 통과. 복구됐다."
      else
         say "  ★ 전원 재투입으로도 복구하지 못했다 : $POWER_FAIL"
      fi
   else
      say "[4/5] 전원 재투입 — 하지 않는다 ($POWER_WHY)"
   fi
fi

# =====================================================================
#  5단계 — 결과를 알린다
# =====================================================================
say "[5/5] 결과"
if [ "$OK" -eq 1 ]; then
   say "복구 성공 : $HOW. 수집을 이어도 된다."
   say "  기록 : $DETAIL"
   notify recovered "${HOW}로 복구 (${SUSPECT# })"
   exit 0
fi

if [ "$POWER_DONE" -eq 1 ]; then
   say "★ usbreset 과 전원 재투입 모두 실패했다. 사람이 현장에 가야 한다."
   MSG="usbreset ${TRY}회 + 전원 재투입 실패 : $POWER_FAIL (${SUSPECT# })"
else
   say "★ usbreset ${TRY}회 시도했으나 복구하지 못했다. 사람이 현장에 가야 한다."
   say "  ★ 다음은 보드 크레이트 전원 재투입이다 (scripts/pdu-power.sh cycle). usbreset 으로는 FPGA 상태가 안 풀린다."
   say "     전원을 내리면 트리거 설정이 날아가므로 src/NOTICE_CODE_RUN.sh 로 반드시 다시 설정할 것."
   say "     (안 하면 계수율이 정상의 20배가 넘는다 - 실측 23,527 Hz)"
   MSG="usbreset ${TRY}회 실패, 전원 재투입 안 함 ($POWER_WHY) (${SUSPECT# })"
fi
say "  기록 : $DETAIL"
notify recovery_failed "$MSG"
exit 2
