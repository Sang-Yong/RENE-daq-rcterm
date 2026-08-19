#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  daq-alarm.sh - 현장에서 귀로 듣는 알람을 켜고 끈다.
#
#  사용 :
#     daq-alarm.sh --raise '<사유>'      알람을 켠다 (이미 켜져 있으면 사유만 갱신)
#     daq-alarm.sh --silence             끈다. 사람이 상황을 인지했다는 뜻이다
#     daq-alarm.sh --status              울리는 중인가? (울리면 exit 0)
#     daq-alarm.sh --test                한 번만 소리를 내 본다 (상태를 남기지 않는다)
#     daq-alarm.sh --params <파일>       설정. 없으면 config/notify.params
#
#  소리는 두 갈래로 낸다. 한쪽이 죽어도 다른 쪽이 남게 하려는 것이다.
#     사운드카드  aplay 로 경보음 WAV 를 반복 재생 (외부 스피커)
#     PC 스피커   /dev/input/... 에 EV_SND 를 써서 케이스 내부 비프
#
#  ★ PC 스피커는 'input' 그룹 권한이 필요하다. 없으면 조용히 건너뛰지 않고
#    한 줄 알린 뒤 사운드카드만 쓴다. 한 번만 해 두면 되는 조치 :
#         sudo usermod -aG input $USER      (다시 로그인해야 적용된다)
#
#  이 스크립트는 하드웨어(DAQ)를 건드리지 않는다. 소리만 낸다.
# ---------------------------------------------------------------------
set -u

DIR=$(cd "$(dirname "$0")/.." && pwd)
PARAMS=$DIR/config/notify.params

ALARM_SOUND=both
ALARM_UNTIL_ACK=1
ALARM_PERIOD=20
ALARM_MAX_SEC=600
ALARM_DEVICE=default
ALARM_VOLUME=90
ALARM_STATE=/Data/LOG/daq-alarm.state

die()  { echo "daq-alarm: $*" >&2; exit 1; }
warn() { echo "daq-alarm: $*" >&2; }

load_params() {
   local f=$1 line k v
   [ -r "$f" ] || return 0
   while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      case "$line" in *=*) ;; *) continue ;; esac
      k=${line%%=*}; v=${line#*=}
      k=$(printf '%s' "$k" | tr -d ' \t' | tr 'a-z-' 'A-Z_')
      v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      case "$k" in
         ALARM_SOUND)      ALARM_SOUND=$v ;;
         ALARM_UNTIL_ACK)  ALARM_UNTIL_ACK=$v ;;
         ALARM_PERIOD)     ALARM_PERIOD=$v ;;
         ALARM_MAX_SEC)    ALARM_MAX_SEC=$v ;;
         ALARM_DEVICE)     ALARM_DEVICE=$v ;;
         ALARM_VOLUME)     ALARM_VOLUME=$v ;;
         ALARM_STATE)      ALARM_STATE=$v ;;
         *) : ;;
      esac
   done < "$f"
}

# ---- 경보음 WAV 를 한 번 만들어 둔다 --------------------------------
#  외부 도구(sox 등)에 기대지 않는다. 사이트에 없을 수 있다.
TONE=/tmp/.daq-alarm-tone.wav
make_tone() {
   [ -s "$TONE" ] && return 0
   python3 - "$TONE" <<'PY' 2>/dev/null
import math, struct, sys, wave
# 800Hz <-> 1000Hz 를 오가는 2초짜리 경보음. 사이렌처럼 들려야 배경음과 구분된다.
rate = 22050
with wave.open(sys.argv[1], 'w') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
    frames = bytearray()
    for seg in range(4):                       # 0.5초씩 네 토막
        f = 1000.0 if seg % 2 == 0 else 800.0
        n = rate // 2
        for i in range(n):
            # 토막 경계에서 딸깍 소리가 나지 않도록 양끝을 부드럽게 깎는다
            env = min(1.0, i / 400.0, (n - i) / 400.0)
            s = int(24000 * env * math.sin(2 * math.pi * f * i / rate))
            frames += struct.pack('<h', s)
    w.writeframes(bytes(frames))
PY
   [ -s "$TONE" ]
}

have_pcspkr() {
   local d=/dev/input/by-path/platform-pcspkr-event-spkr
   [ -w "$d" ] && return 0
   return 1
}

beep_pcspkr() {           # 케이스 내부 비프. 권한이 없으면 아무것도 하지 않는다
   local d=/dev/input/by-path/platform-pcspkr-event-spkr
   [ -w "$d" ] || return 1
   python3 - "$d" <<'PY' 2>/dev/null
import os, struct, sys, time
# EV_SND=0x12, SND_TONE=0x02.  input_event = (sec, usec, type, code, value)
FMT = 'llHHi'
fd = os.open(sys.argv[1], os.O_WRONLY)
def tone(hz):
    os.write(fd, struct.pack(FMT, 0, 0, 0x12, 0x02, hz))
try:
    for _ in range(4):
        tone(1000); time.sleep(0.25)
        tone(800);  time.sleep(0.25)
finally:
    tone(0)                      # 반드시 꺼 둔다. 안 그러면 계속 삑 소리가 난다
    os.close(fd)
PY
}

play_card() {             # 사운드카드로 경보음 한 번
   make_tone || return 1
   if [ "$ALARM_VOLUME" -gt 0 ] 2>/dev/null; then
      amixer -q -c 0 sset Master "${ALARM_VOLUME}%" unmute >/dev/null 2>&1 || true
   fi
   # pipewire 가 물고 있을 수 있으므로 순서대로 시도한다
   if command -v pw-play >/dev/null 2>&1 && pw-play "$TONE" >/dev/null 2>&1; then return 0; fi
   aplay -q -D "$ALARM_DEVICE" "$TONE" >/dev/null 2>&1 && return 0
   aplay -q -D plughw:0,0      "$TONE" >/dev/null 2>&1 && return 0
   return 1
}

sound_once() {
   local ok=1
   case "$ALARM_SOUND" in
      both)   play_card && ok=0; beep_pcspkr && ok=0 ;;
      card)   play_card && ok=0 ;;
      pcspkr) beep_pcspkr && ok=0 ;;
      none)   ok=0 ;;
   esac
   return $ok
}

# ---- 알람 루프 (자식으로 떨어져 나가 혼자 돈다) ---------------------
alarm_loop() {
   local started=$SECONDS
   while [ -f "$ALARM_STATE" ]; do
      sound_once
      if [ "$ALARM_UNTIL_ACK" != "1" ]; then
         [ $(( SECONDS - started )) -ge "$ALARM_MAX_SEC" ] && break
      fi
      sleep "$ALARM_PERIOD"
   done
   rm -f "$ALARM_STATE"
}

# ---- 인자 ------------------------------------------------------------
ACTION=""; MSG=""
while [ $# -gt 0 ]; do
   case "$1" in
      --params)  PARAMS=$2; shift 2 ;;
      --raise)   ACTION=raise; MSG=${2:-"(사유 없음)"}; shift 2 ;;
      --silence) ACTION=silence; shift ;;
      --status)  ACTION=status; shift ;;
      --test)    ACTION=test; shift ;;
      --loop)    ACTION=loop; shift ;;          # 내부용. 사람이 직접 쓰지 않는다
      -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) die "모르는 인자 : $1" ;;
   esac
done
[ -n "$ACTION" ] || { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
load_params "$PARAMS"

mkdir -p "$(dirname "$ALARM_STATE")" 2>/dev/null || true

case "$ACTION" in
   status)
      if [ -f "$ALARM_STATE" ]; then cat "$ALARM_STATE"; exit 0; else echo "알람 없음"; exit 1; fi ;;

   silence)
      if [ -f "$ALARM_STATE" ]; then
         local_pid=$(sed -n 's/^pid=//p' "$ALARM_STATE" 2>/dev/null | head -1)
         rm -f "$ALARM_STATE"
         [ -n "${local_pid:-}" ] && kill "$local_pid" 2>/dev/null
         # 비프가 켜진 채로 남지 않게 확실히 꺼 둔다
         d=/dev/input/by-path/platform-pcspkr-event-spkr
         [ -w "$d" ] && python3 -c "
import os,struct,sys
fd=os.open(sys.argv[1],os.O_WRONLY)
os.write(fd,struct.pack('llHHi',0,0,0x12,0x02,0)); os.close(fd)" "$d" 2>/dev/null
         echo "알람을 껐다."
      else
         echo "울리는 알람이 없다."
      fi
      exit 0 ;;

   test)
      echo "소리 시험 (설정: alarm_sound = $ALARM_SOUND)"
      have_pcspkr || echo "  주의: PC 스피커 권한 없음 -> 사운드카드만 쓴다. 'sudo usermod -aG input $USER' 후 재로그인"
      if sound_once; then echo "  소리를 냈다."; else echo "  ★ 어느 경로로도 소리를 내지 못했다."; exit 1; fi
      exit 0 ;;

   loop)
      alarm_loop
      exit 0 ;;

   raise)
      if [ -f "$ALARM_STATE" ]; then
         # 이미 울리는 중이면 루프를 새로 띄우지 않는다. 사유만 덧붙인다.
         printf 'also=%s %s\n' "$(date '+%F %T')" "$MSG" >> "$ALARM_STATE"
         echo "이미 알람이 울리는 중이다. 사유를 덧붙였다."
         exit 0
      fi
      have_pcspkr || warn "PC 스피커 권한 없음 -> 사운드카드만 쓴다 (sudo usermod -aG input $USER 후 재로그인)"
      {
         printf 'since=%s\n' "$(date '+%F %T')"
         printf 'reason=%s\n' "$MSG"
      } > "$ALARM_STATE"
      setsid "$0" --params "$PARAMS" --loop >/dev/null 2>&1 &
      printf 'pid=%s\n' "$!" >> "$ALARM_STATE"
      echo "알람을 켰다 : $MSG"
      echo "끄려면 : $0 --silence"
      exit 0 ;;
esac
