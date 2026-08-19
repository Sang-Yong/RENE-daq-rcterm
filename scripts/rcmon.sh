#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  rcmon.sh - heartbeat 파일을 읽어 rcterm 의 상태 화면을 보여준다.
#
#  rcsupervisor 는 rcterm 에 --quiet 를 강제로 붙인다(rcsupervisor.cc:138).
#  PrintScreen() 이 매 갱신마다 화면을 지워서 감시자의 [SUP] 로그를 덮어버리기
#  때문이다. 그래서 감시자 밑에서는 한 줄짜리 로그만 보인다.
#  이 스크립트는 DAQ 를 전혀 건드리지 않고(읽기 전용) 같은 정보를 보여준다.
#
#  사용 :  scripts/rcmon.sh [heartbeat파일] [갱신주기초]
#          기본값 /Data/LOG/rcterm.hb , 1 초
#          종료는 Ctrl-C (DAQ 에는 아무 영향 없다)
#
#  출력은 rcterm 의 PrintScreen() 과 같은 전체 화면 형식이다. 약 20행을
#  쓰므로 pane 높이를 그만큼 확보할 것 (scripts/daq-tmux.sh 가 그렇게 짠다).
#  RCMON_STALE 로 stale 경고 기준(초)을 바꿀 수 있다.
# ---------------------------------------------------------------------
set -u

HB=${1:-/Data/LOG/rcterm.hb}
PERIOD=${2:-1}
STALE=${RCMON_STALE:-300}
#  알람이 울리는 중이면 화면 맨 위에 띄운다. 소리를 못 듣는 자리에서도
#  화면만 보면 알 수 있어야 한다. scripts/daq-alarm.sh 가 이 파일을 만든다.
ALARM_STATE=${RCMON_ALARM_STATE:-/Data/LOG/daq-alarm.state}

cleanup() { printf '\033[?25h\n'; exit 0; }   # 커서 복구
trap cleanup INT TERM
printf '\033[?25l'                            # 커서 숨김

hms() { printf '%02d:%02d:%02d' $(($1/3600)) $(($1%3600/60)) $(($1%60)); }

while true; do
   now=$(date +%s)

   if [ ! -r "$HB" ]; then
      printf '\033[H\033[2J'
      echo "  heartbeat 파일을 읽을 수 없다 : $HB"
      echo "  rcterm 이 아직 안 떴거나 경로가 다르다."
      echo "  config/rcterm.params 의 'heartbeat' 값을 확인할 것."
      sleep "$PERIOD"
      continue
   fi

   hb_time=; hb_pid=; phase=; run=; subrun=; state=; error=0; status=
   daqtime=0; totev=; daqs=()
   while IFS= read -r line; do
      case "$line" in
         time=*)    hb_time=${line#time=} ;;
         pid=*)     hb_pid=${line#pid=} ;;
         phase=*)   phase=${line#phase=} ;;
         run=*)     run=${line#run=} ;;
         subrun=*)  subrun=${line#subrun=} ;;
         state=*)   state=${line#state=} ;;
         error=*)   error=${line#error=} ;;
         status=*)  status=${line#status=} ;;
         daqtime=*) daqtime=${line#daqtime=} ;;
         totev=*)   totev=${line#totev=} ;;
         daq[0-9]*) daqs+=("${line#*=}") ;;
      esac
   done < "$HB"

   age=$(( now - ${hb_time:-0} ))
   dt=$(hms "${daqtime%%.*}")

   # heartbeat 가 멎으면 rcterm 이 죽었거나 멎은 것이다. 가장 중요한 신호.
   if [ "$age" -gt "$STALE" ]; then
      hbtxt="hb ${age}s  *** STALE >${STALE}s : rcterm 확인 ***"
   else
      hbtxt="hb ${age}s"
   fi
   [ "${error:-0}" != "0" ] && state="$state  *** ERROR ***"

   printf '\033[H\033[2J'

   #  ---- 알람 배너 ----  깜빡이지 않고 계속 붉게 둔다. 깜빡이면 오히려
   #  터미널에 따라 안 보이거나 눈에 덜 띈다.
   if [ -f "$ALARM_STATE" ]; then
      a_since=$(sed -n 's/^since=//p' "$ALARM_STATE" 2>/dev/null | head -1)
      a_why=$(sed -n 's/^reason=//p'  "$ALARM_STATE" 2>/dev/null | head -1)
      #  오른쪽 테두리를 두지 않는다. printf 의 %-Ns 는 '바이트' 로 채우는데
      #  한글은 3바이트에 2칸이라 사유가 한글이면 테두리가 어긋난다.
      printf '\033[1;37;41m'
      echo "######################################################################"
      echo "##  ALARM  ${a_why:-DAQ 이상}"
      echo "##  since  ${a_since:-?}"
      echo "##  끄려면 : scripts/daq-alarm.sh --silence"
      echo "######################################################################"
      printf '\033[0m'
   fi

   echo "======================================================================"
   echo "  RENE / CUPDAQ   Run Monitor   (heartbeat viewer, read-only)"
   echo "======================================================================"
   echo "        Current Time : $(date '+%Y-%m-%d %H:%M:%S')"
   echo
   printf '          Run Number : %s / %s\n' "${run:--}" "${subrun:--}"
   printf '           DAQ State : %s   (phase=%s status=%s)\n' \
          "${state:--}" "${phase:--}" "${status:--}"
   printf '            DAQ Time : %s\n' "$dt"
   printf '        Total Events : %s\n' "${totev:--}"
   printf '        rcterm  PID  : %s\n' "${hb_pid:--}"
   echo
   echo "  ------------------------------------------------------------------"
   echo "        DAQ          Events       Rate[Hz]     Average[Hz]"
   echo "  ------------------------------------------------------------------"
   if [ "${#daqs[@]}" -eq 0 ]; then
      echo "        (보고 중인 DAQ 없음)"
   else
      for d in "${daqs[@]}"; do
         set -- $d
         printf '  %12s  %13s  %12.1f  %14.1f\n' "$1" "${2#n=}" "${3#sr=}" "${4#ar=}"
      done
   fi
   echo "  ------------------------------------------------------------------"
   printf '  %s\n' "$hbtxt"
   echo "  Ctrl-C : 이 화면만 종료 (DAQ 는 계속 돈다)"

   sleep "$PERIOD"
done
