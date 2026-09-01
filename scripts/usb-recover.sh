#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  usb-recover.sh - 연속 실패가 USB 보드 때문인지 판정하고, 맞으면
#                   usbreset 으로 자동 복구를 시도한다.
#
#  2026-08-20 의 장애(FADC 보드가 걸려 런 5개가 연속 실패)에서 사람이 손으로
#  밟은 절차를 그대로 코드로 옮긴 것이다. 자세한 경위는 CLAUDE.md 11.49~11.51.
#
#  사용 :
#     usb-recover.sh [--params <파일>] [--max-try N] [--dry-run] [--no-notify]
#     usb-recover.sh --diagnose      진단만 하고 끝낸다 (읽기 전용, 수집 중에도 안전)
#
#  종료코드 (감시자가 이 값으로 다음 행동을 정한다)
#     0  복구했다. 수집을 이어도 된다
#     1  USB 문제가 아니다. 다른 원인이므로 손대지 않았다
#     2  USB 문제인데 복구하지 못했다. ★ 사람이 현장에 가야 한다
#     3  안전 조건이 아니라 아무것도 하지 않았다 (수집이 돌고 있다 등)
#
#  ★★ 이 스크립트는 usbreset 을 돌린다. 보드가 리셋되면 진행 중인 런이
#     깨진다. 그래서 맨 처음에 '아무것도 돌고 있지 않다'를 확인하고, 하나라도
#     살아 있으면 종료코드 3 으로 즉시 빠져나온다. 이 게이트를 없애지 말 것.
# ---------------------------------------------------------------------
set -u

DIR=$(cd "$(dirname "$0")/.." && pwd)
PARAMS=$DIR/config/notify.params
NOTIFY=$DIR/scripts/daq-notify.sh
USBRESET=$DIR/src/usbreset
RCTERM=$DIR/install/bin/rcterm
RCPARAMS=$DIR/config/rcterm.params

BINDIR=/home/frontend/DAQ/DAQ_cup/install/bin
RAWROOT=/Data_ssd
DAQLOG=/Data_ssd/LOG
LOGDIR=/Data/LOG
TCBPORT=7809; FADCPORT=7814; SADCPORT=7815

DIAGNOSE=0               # 1 이면 읽기만 하고 판정만 낸다
MAXTRY=2                 # 사용자 지침: 최소 2회
SETTLE=15
CHECKLEN=0.05            # 확인 런 길이 [시간] = 3분
CHECKRUN=999999
MINRATE=500
KEEPDATA=0
LOGAGEMIN=60             # 이 시간[분] 안에 쓰인 DAQ 로그만 본다
RECOVER_ENABLE=1
DRY=0; NOTIFY_ON=1

# NOTICE 보드 셋. usbreset 은 이 VID 를 전부 리셋한다 (개별 지정 불가)
BOARDS="FADC:0547:1502 TCB:0547:1501 SADC:0547:1503"

STAMP=$(date '+%Y%m%d-%H%M%S')
DETAIL=$LOGDIR/usb-recover-$STAMP.log

say()  { printf '%s %s\n' "$(date '+%F %T')" "$*"; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$DETAIL" 2>/dev/null; }
note() { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$DETAIL" 2>/dev/null; }

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
         recover_enable)     RECOVER_ENABLE=$v ;;
         recover_max_try)    MAXTRY=$v ;;
         recover_settle_sec) SETTLE=$v ;;
         recover_check_min)  CHECKLEN=$v ;;
         recover_check_run)  CHECKRUN=$v ;;
         recover_min_rate)   MINRATE=$v ;;
         recover_log_age_min) LOGAGEMIN=$v ;;
         recover_keep_data)  KEEPDATA=$v ;;
         *) : ;;
      esac
   done < "$f"
}

while [ $# -gt 0 ]; do
   case "$1" in
      --params)     PARAMS=$2; shift 2 ;;
      --max-try)    MAXTRY=$2; shift 2 ;;
      --bindir)     BINDIR=$2; shift 2 ;;
      --rcterm)     RCTERM=$2; shift 2 ;;
      --dry-run)    DRY=1; shift ;;
      --diagnose)   DIAGNOSE=1; NOTIFY_ON=0; shift ;;
      --no-notify)  NOTIFY_ON=0; shift ;;
      -h|--help)    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *)            echo "모르는 인자 : $1" >&2; exit 1 ;;
   esac
done
load_params "$PARAMS"
mkdir -p "$LOGDIR" 2>/dev/null || true

note "=============================================================="
note " usb-recover  $(date '+%F %T')   호스트 $(hostname)"
note "=============================================================="

if [ "$RECOVER_ENABLE" != "1" ]; then
   say "recover_enable = 0 이라 자동 복구를 하지 않는다."
   exit 1
fi

# =====================================================================
#  1단계 — 안전 게이트.  하나라도 살아 있으면 절대 리셋하지 않는다
# =====================================================================
if [ "$DIAGNOSE" -eq 1 ]; then
   say "[1/4] 안전 확인 — 건너뜀 (--diagnose : 읽기만 한다)"
else
say "[1/4] 안전 확인 — 지금 아무것도 돌고 있지 않아야 한다"
ALIVE=""
pgrep -x rcterm >/dev/null 2>&1 && ALIVE="$ALIVE rcterm"
for b in daq tcb merger; do
   pgrep -f "$BINDIR/$b" >/dev/null 2>&1 && ALIVE="$ALIVE $b"
done
PORTS=$(ss -ltn 2>/dev/null | grep -cE ":($TCBPORT|$FADCPORT|$SADCPORT)\b")
if [ -n "$ALIVE" ] || [ "${PORTS:-0}" -gt 0 ]; then
   say "★ 수집이 살아 있다 (프로세스:${ALIVE:- 없음} / 열린 포트 ${PORTS:-0}개)."
   say "  보드를 리셋하면 진행 중인 런이 깨진다. 아무것도 하지 않고 물러난다."
   exit 3
fi
note "  프로세스 없음, 포트 $TCBPORT/$FADCPORT/$SADCPORT 비어 있음 -> 진행해도 된다"
fi

# =====================================================================
#  2단계 — 진단. 정말 USB 문제인가?
# =====================================================================
say "[2/4] 진단 — 최근 실패가 USB 때문인가"

#  주의: grep -c 는 0건일 때도 '0' 을 찍으면서 종료코드 1 을 낸다.
#        여기에 '|| echo 0' 을 붙이면 '0' 이 두 줄 나와 뒤의 산술이 깨진다.
#  ★ 2026-09-01 에 그물을 넓혔다. 그 전에는 이 함수가 TCB 고장을 0 건으로 셌다.
#    근거로 삼았던 것이 §11.49 의 'FADC + LIBUSB_ERROR_IO' 한 사례뿐이라
#    그 한 사례에 맞춰진 그물이었다 (§11.120).
#
#      전  LIBUSB_ERROR_IO            <- 코드를 IO 하나로 못박고 있었다
#      후  LIBUSB_ERROR_              <- TIMEOUT · NO_DEVICE 계열까지 잡는다
#          Fail to align DRAM         <- FADC 이벤트 버퍼가 안 올라온다.
#                                        설정은 '성공'으로 끝나 조용히 0 Hz 가 된다.
#                                        2026-09-01 에 usbreset 두 번째로 풀렸다
#          no module linked           <- TCB 가 모듈을 못 본다
#          is enabled but not linked  <- 같은 계열
usb_err_count() {         # 로그 파일 하나의 USB 오류 건수
   [ -r "$1" ] || { echo 0; return 0; }
   grep -c 'LIBUSB_ERROR_\|USB3Read: read error\|USB3ReadReg: read error\|error in reading buffer count\|Fail to align DRAM\|no module linked\|is enabled but not linked' "$1" 2>/dev/null
   return 0
}

#  ★ '최근에 쓰인' 로그만 본다. 옛 장애의 로그가 디렉터리에 남아 있으므로
#    그냥 최신 N개를 보면 지금과 무관한 실패를 근거로 오진한다.
#    (실측: 08-20 03:20 장애의 FADCDAQ_004299.log 가 몇 시간 뒤에도 최신 3개 안에 있었다)
note "  최근 ${LOGAGEMIN}분 안에 쓰인 DAQ 로그만 본다"
FADC_ERR=0; SADC_ERR=0; TCB_ERR=0; SUSPECT=""
recent_logs() {           # 종류 하나의 최근 로그 목록
   find "$DAQLOG" -maxdepth 1 -name "$1_*.log" -mmin "-$LOGAGEMIN" 2>/dev/null | sort
}
for f in $(recent_logs FADCDAQ); do
   n=$(usb_err_count "$f"); n=${n:-0}
   [ "$n" -gt 0 ] && { FADC_ERR=$((FADC_ERR+n)); note "  $(basename "$f") : USB 오류 $n 건"; }
done
for f in $(recent_logs SADCDAQ); do
   n=$(usb_err_count "$f"); n=${n:-0}
   [ "$n" -gt 0 ] && { SADC_ERR=$((SADC_ERR+n)); note "  $(basename "$f") : USB 오류 $n 건"; }
done
#  ★ TCB 로그도 본다. 2026-09-01 전에는 이 세 줄이 없어서, 오류 43건짜리
#    TCB 로그를 두고도 '0 건' 으로 세고 물러났다 (§11.120).
#    TCB 는 BOARDS 목록(리셋 대상)에는 처음부터 있었는데 진단에서만 빠져 있었다.
for f in $(recent_logs TCB); do
   n=$(usb_err_count "$f"); n=${n:-0}
   [ "$n" -gt 0 ] && { TCB_ERR=$((TCB_ERR+n)); note "  $(basename "$f") : USB 오류 $n 건"; }
done
[ "$FADC_ERR" -gt 0 ] && SUSPECT="$SUSPECT FADC"
[ "$SADC_ERR" -gt 0 ] && SUSPECT="$SUSPECT SADC"
[ "$TCB_ERR"  -gt 0 ] && SUSPECT="$SUSPECT TCB"

# 보드가 아예 USB 에서 사라졌는가? 그것도 USB 문제다 (걸린 것보다 더 나쁘다).
MISSING=""
for b in $BOARDS; do
   nm=${b%%:*}; vid=${b#*:}
   if ! lsusb -d "$vid" >/dev/null 2>&1; then MISSING="$MISSING $nm"; fi
done
if [ -n "$MISSING" ]; then
   note "  ★ USB 에서 안 보이는 보드 :$MISSING"
   SUSPECT="$SUSPECT$MISSING"
else
   note "  NOTICE 보드 셋 다 USB 에 보인다"
fi

if [ -z "$SUSPECT" ]; then
   say "USB 오류의 근거가 없다. 다른 원인이므로 usbreset 을 돌리지 않는다."
   say "  (FADCDAQ · SADCDAQ · TCB 로그에 USB 오류가 없고 보드 셋 다 보인다)"
   say "  ★ 계수가 0 인데 여기까지 왔다면 검출기 쪽을 볼 것 — PMT HV 가 먼저다 (11.131)"
   [ "$NOTIFY_ON" -eq 1 ] && "$NOTIFY" --params "$PARAMS" recovery_failed \
        --msg "연속 실패했으나 USB 문제는 아니다 - 사람이 원인을 봐야 한다" \
        --detail-file "$DETAIL" >/dev/null 2>&1
   exit 1
fi
say "USB 문제로 판정 ->${SUSPECT}. usbreset 이 불가피하다."

if [ "$DIAGNOSE" -eq 1 ]; then
   say "(--diagnose 라 여기서 끝낸다. 실제로 복구하려면 이 옵션 없이 돌릴 것)"
   exit 2
fi

# =====================================================================
#  3단계 — usbreset + 확인 런.  최대 MAXTRY 회
# =====================================================================
boards_present() {
   local b nm vid miss=""
   for b in $BOARDS; do
      nm=${b%%:*}; vid=${b#*:}
      lsusb -d "$vid" >/dev/null 2>&1 || miss="$miss $nm"
   done
   [ -z "$miss" ] && return 0
   note "  아직 안 보이는 보드 :$miss"
   return 1
}

check_run() {             # 짧은 런으로 실제 데이터가 들어오는지 본다
   local hb=$LOGDIR/usb-recover-check.hb
   local rawdir=$RAWROOT/RAW/$(printf '%06d' "$CHECKRUN")
   rm -rf "$rawdir" 2>/dev/null
   rm -f "$hb" 2>/dev/null

   note "  확인 런 : run $CHECKRUN, ${CHECKLEN} 시간"
   "$RCTERM" --params "$RCPARAMS" --no-db --run "$CHECKRUN" \
             --max-runs 1 --run-length "$CHECKLEN" --quiet \
             --heartbeat "$hb" \
             --desc "usb-recover board check" >> "$DETAIL" 2>&1
   local rc=$?
   note "  rcterm 종료코드 : $rc"
   [ "$rc" -ne 0 ] && return 1

   # (a) 확인 런 자체의 로그에 USB 오류가 없어야 한다
   local ce=0 f
   for f in "$DAQLOG"/FADCDAQ_$(printf '%06d' "$CHECKRUN").log \
            "$DAQLOG"/SADCDAQ_$(printf '%06d' "$CHECKRUN").log; do
      [ -r "$f" ] || continue
      local n; n=$(usb_err_count "$f"); ce=$((ce + ${n:-0}))
   done
   note "  확인 런의 USB 오류 : $ce 건"
   [ "$ce" -gt 0 ] && return 1

   # (b) 실제로 자료가 쌓였는가. 걸린 보드는 8 kB 짜리 빈 껍데기만 남긴다
   local bytes
   bytes=$(find "$rawdir" -maxdepth 1 -name 'FADC_*.root.*' -printf '%s\n' 2>/dev/null \
           | awk '{s+=$1} END {print s+0}')
   note "  FADC 산출 : ${bytes:-0} bytes"
   [ "${bytes:-0}" -lt 1000000 ] && { note "  ★ 너무 작다. 이벤트가 들어오지 않았다"; return 1; }

   # (c) 계수율이 정상 범위인가.
   #  heartbeat 의 daqN= 줄에 rcterm 이 ADC 별 평균 계수율(ar=)을 이미 적어 둔다.
   #  ★ 합이나 평균이 아니라 '최솟값' 을 본다 -- 한 보드만 죽으면 다른 보드가
   #    정상이라 합·평균은 멀쩡해 보인다. 이번 장애가 바로 그 모양이었다
   #    (FADC 만 먹통, SADC 는 정상).
   local minrate
   minrate=$(sed -n 's/.* ar=\([0-9.]*\).*/\1/p' "$hb" 2>/dev/null \
             | awk 'NR==1||$1<m{m=$1} END{ if (NR) printf "%.1f", m; }')
   if [ -n "${minrate:-}" ]; then
      note "  ADC 별 계수율 최솟값 : ${minrate} Hz (문턱 ${MINRATE} Hz)"
      awk -v r="$minrate" -v m="$MINRATE" 'BEGIN{ exit !(r+0 >= m+0) }' || {
         note "  ★ 어느 ADC 의 계수율이 너무 낮다"; return 1; }
   else
      note "  (heartbeat 에서 계수율을 읽지 못했다 - 크기 검사만으로 판정한다)"
   fi
   return 0
}

cleanup_check() {
   [ "$KEEPDATA" = "1" ] && { note "  확인 런 자료를 남긴다 (recover_keep_data = 1)"; return 0; }
   rm -rf "$RAWROOT/RAW/$(printf '%06d' "$CHECKRUN")" 2>/dev/null
   rm -f "$RAWROOT/CONFIG/$(printf '%06d' "$CHECKRUN").config" 2>/dev/null
   rm -f "$LOGDIR/usb-recover-check.hb" 2>/dev/null
   note "  확인 런 자료를 지웠다"
}

say "[3/4] usbreset — 최대 ${MAXTRY} 회"
if [ "$DRY" -eq 1 ]; then
   say "[DRY] 여기서 $USBRESET 을 돌리고 확인 런을 했을 것이다. 아무것도 하지 않았다."
   exit 0
fi

TRY=0; OK=0
while [ "$TRY" -lt "$MAXTRY" ]; do
   TRY=$((TRY+1))
   say "  --- 시도 $TRY/$MAXTRY ---"

   if [ ! -x "$USBRESET" ]; then
      say "  ★ usbreset 이 없거나 실행할 수 없다 : $USBRESET"
      break
   fi
   "$USBRESET" >> "$DETAIL" 2>&1
   note "  usbreset 종료코드 : $?"

   note "  보드가 다시 잡힐 때까지 ${SETTLE}초 대기"
   sleep "$SETTLE"

   if ! boards_present; then
      say "  보드가 아직 USB 에 다 보이지 않는다. 다음 시도로 넘어간다."
      continue
   fi
   note "  NOTICE 보드 셋 다 보인다"

   if check_run; then
      say "  ✓ 확인 런 통과. 복구됐다."
      cleanup_check
      OK=1
      break
   fi
   say "  확인 런 실패. 다음 시도로 넘어간다."
   cleanup_check
done

# =====================================================================
#  4단계 — 결과를 알린다
# =====================================================================
say "[4/4] 결과"
if [ "$OK" -eq 1 ]; then
   say "복구 성공 (시도 $TRY/$MAXTRY). 수집을 이어도 된다."
   if [ "$NOTIFY_ON" -eq 1 ]; then
      "$NOTIFY" --params "$PARAMS" recovered \
         --msg "usbreset ${TRY}회로 복구 (${SUSPECT# })" \
         --detail-file "$DETAIL" >/dev/null 2>&1
   fi
   exit 0
fi

say "★ ${MAXTRY}회 시도했으나 복구하지 못했다. 사람이 현장에 가야 한다."
#  ★ usbreset(USBDEVFS_RESET)은 USB 링크만 다시 맺는다. 보드 안의 FPGA·펌웨어
#    상태가 엉키면 전원을 끊어야만 풀린다. PC 재부팅으로는 안 된다 -- 보드가
#    자체 크레이트 전원을 쓴다 (§11.119).
say "  ★ 다음은 보드 크레이트 전원 재투입이다. usbreset 으로는 FPGA 상태가 안 풀린다."
say "     전원을 내리면 트리거 설정이 날아가므로 src/NOTICE_CODE_RUN.sh 로 반드시 다시 설정할 것."
say "     (안 하면 계수율이 정상의 20배가 넘는다 - 실측 23,527 Hz)"
say "  기록 : $DETAIL"
if [ "$NOTIFY_ON" -eq 1 ]; then
   "$NOTIFY" --params "$PARAMS" recovery_failed \
      --msg "usbreset ${MAXTRY}회 실패 (${SUSPECT# })" \
      --detail-file "$DETAIL" >/dev/null 2>&1
fi
exit 2
