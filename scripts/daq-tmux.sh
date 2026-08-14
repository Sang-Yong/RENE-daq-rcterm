#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  daq-tmux.sh - DAQ 운용 tmux 화면을 한 번에 구성한다.
#
#      +---------------------------+---------------------------+
#      |  rcmon.sh (상태 화면)     |                           |
#      +---------------------------+   작업용 셸 (vi 등)       |
#      |  rcsupervisor / 감시자로그|                           |
#      +---------------------------+---------------------------+
#
#  사용 :
#      scripts/daq-tmux.sh              화면만 구성 (DAQ 는 건드리지 않음)
#      scripts/daq-tmux.sh --start      DAQ 가 안 돌고 있으면 같이 기동
#      scripts/daq-tmux.sh --kill-layout   화면만 정리 (DAQ 는 그대로 둔다)
#
#  안전 규칙 :
#   * 이미 rcsupervisor 가 돌고 있으면 **절대 다시 띄우지 않는다.**
#     그 경우 좌하단 pane 은 감시자 로그를 tail 한다.
#     (돌아가는 자식 프로세스의 출력을 새 pane 으로 옮길 수는 없다)
#   * 세션이 이미 있으면 재구성하지 않고 그냥 붙는다. 살아있는 런을
#     실수로 흔들지 않기 위해서다. 다시 짜려면 --kill-layout 후 실행.
#   * --start 없이는 어떤 하드웨어도 건드리지 않는다.
# ---------------------------------------------------------------------
set -u

DIR=$(cd "$(dirname "$0")/.." && pwd)
SESSION=${DAQ_TMUX_SESSION:-daq}
SUP=$DIR/install/bin/rcsupervisor
SUP_PARAMS=$DIR/config/rcsupervisor.params
SUP_LOG=${DAQ_SUP_LOG:-/Data/LOG/rcsupervisor.log}
HB=${DAQ_HEARTBEAT:-/Data/LOG/rcterm.hb}
DESC_FILE=$DIR/config/rundesc.txt      # 있으면 --desc 로 넘긴다

START=0
case "${1:-}" in
   --start)       START=1 ;;
   --kill-layout) tmux kill-session -t "$SESSION" 2>/dev/null &&
                     echo "세션 '$SESSION' 정리함 (DAQ 프로세스는 그대로)"
                  echo "주의: rcsupervisor 가 이 세션 안에서 돌고 있었다면 같이 죽는다."
                  echo "      먼저 'pgrep -f install/bin/rcsupervisor' 로 확인할 것."
                  exit 0 ;;
   "")            ;;
   *)             echo "unknown option : $1"; sed -n '2,25p' "$0"; exit 1 ;;
esac

command -v tmux >/dev/null || { echo "tmux 가 없다"; exit 1; }

# 이미 세션이 있으면 그냥 붙는다 (살아있는 런 보호)
if tmux has-session -t "$SESSION" 2>/dev/null; then
   echo "세션 '$SESSION' 이 이미 있다. 재구성하지 않고 붙는다."
   echo "다시 짜려면 : $0 --kill-layout   (단, 그 안의 rcsupervisor 도 같이 죽는다)"
   [ -n "${TMUX:-}" ] && exec tmux switch-client -t "$SESSION"
   exec tmux attach -t "$SESSION"
fi

# 프로세스 '이름'으로 찾는다. 경로로 찾으면 상대경로로 띄운 감시자를 놓치고
# (실측: 'install/bin/rcsupervisor --params ...'), 게다가 검사하는 셸 자신의
# 명령줄에 경로 문자열이 들어 있어 자기 자신을 잡는 오탐까지 난다.
SUP_RUNNING=0
pgrep -x rcsupervisor >/dev/null 2>&1 && SUP_RUNNING=1

# ---- 창 구성 : 좌우로 반 가르고, 왼쪽을 위아래로 나눈다 ----
tmux new-session -d -s "$SESSION" -n daq -c "$DIR"
TOPLEFT=$(tmux list-panes -t "$SESSION:daq" -F '#{pane_id}' | head -1)
#  좌하단(감시자 로그)은 전체 높이의 1/4 만 쓴다. 좌상단 rcmon.sh 가
#  전체 화면 형식(약 20행)을 그대로 그려야 하므로 위쪽에 자리를 몰아준다.
RIGHT=$(tmux split-window   -h -p 50 -P -F '#{pane_id}' -t "$TOPLEFT" -c "$DIR")
BOTLEFT=$(tmux split-window -v -p 25 -P -F '#{pane_id}' -t "$TOPLEFT" -c "$DIR")

tmux select-pane -t "$TOPLEFT" -T "monitor"
tmux select-pane -t "$BOTLEFT" -T "supervisor"
tmux select-pane -t "$RIGHT"   -T "work"

# ---- 좌상 : 상태 화면 ----
tmux send-keys -t "$TOPLEFT" "$DIR/scripts/rcmon.sh '$HB'" C-m

# ---- 좌하 : 감시자 ----
if [ "$SUP_RUNNING" -eq 1 ]; then
   echo "rcsupervisor 가 이미 돌고 있다 -> 새로 띄우지 않고 로그를 따라간다."
   tmux send-keys -t "$BOTLEFT" "tail -n 40 -f '$SUP_LOG'" C-m
else
   CMD="$SUP --params '$SUP_PARAMS'"
   if [ -r "$DESC_FILE" ]; then
      CMD="$CMD -- --desc '$(cat "$DESC_FILE")'"
   fi
   if [ "$START" -eq 1 ]; then
      tmux send-keys -t "$BOTLEFT" "$CMD" C-m
   else
      # 명령만 입력해 두고 실행하지 않는다. Enter 는 사람이 친다.
      tmux send-keys -t "$BOTLEFT" "$CMD"
      tmux send-keys -t "$BOTLEFT" ""   # 커서만 남김
      echo "DAQ 는 기동하지 않았다. 좌하단 pane 에 명령을 입력만 해 두었으니"
      echo "확인 후 Enter 를 치거나, 다음부터 --start 로 실행할 것."
   fi
fi

tmux select-pane -t "$RIGHT"          # 작업용 pane 에서 시작
[ -n "${TMUX:-}" ] && exec tmux switch-client -t "$SESSION"
exec tmux attach -t "$SESSION"
