#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  daq-tmux.sh - DAQ 운용 tmux 화면을 한 번에 구성한다.
#
#      +-------------------+--------------------------+
#      | rcmon.sh (상태) 28|   work space (vi 등)  7  |
#      +-------------------+                          |
#      | rcsupervisor    8 |                          |
#      +-------------------+--------------------------+
#      | postrun.sh      5 |   dataflow            3  |
#      +-------------------+--------------------------+
#              46%                     54%
#
#      왼쪽 = 수집·후처리 3개(위에서부터 28 : 8 : 5)
#      오른쪽 = 작업용 셸 + 데이터 이동/백업 (7 : 3)
#      비율이 어긋나면 scripts/daq-layout.sh (tmux 안에서는 Ctrl-B 다음 =)
#
#  사용 :
#      scripts/daq-tmux.sh              화면만 구성 (DAQ 는 건드리지 않음)
#      scripts/daq-tmux.sh --start      DAQ 가 안 돌고 있으면 같이 기동
#      scripts/daq-tmux.sh --no-postrun 후처리 pane 없이 구성
#      scripts/daq-tmux.sh --no-dataflow 데이터 이동 pane 없이 구성
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

START=0; POSTRUN=1; DATAFLOW=1
DF_PARAMS=$DIR/config/dataflow.params
while [ $# -gt 0 ]; do
case "${1:-}" in
   --start)       START=1; shift ;;
   --no-postrun)  POSTRUN=0; shift ;;
   --no-dataflow) DATAFLOW=0; shift ;;
   --kill-layout) tmux kill-session -t "$SESSION" 2>/dev/null &&
                     echo "세션 '$SESSION' 정리함 (DAQ 프로세스는 그대로)"
                  echo "주의: rcsupervisor 가 이 세션 안에서 돌고 있었다면 같이 죽는다."
                  echo "      먼저 'pgrep -f install/bin/rcsupervisor' 로 확인할 것."
                  exit 0 ;;
   "")            shift ;;
   *)             echo "unknown option : $1"; sed -n '2,28p' "$0"; exit 1 ;;
esac
done

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

# ---- 창 구성 ----
#  왼쪽에 DAQ 관련 3개를 세로로 쌓고, 오른쪽은 작업용 셸 하나만 둔다.
#  -p 는 '새로 생기는 pane' 의 비율이다.
#    오른쪽 54%          -> 왼쪽 46%
#    왼쪽에서 아래 32%   -> monitor 68%
#    그 32% 를 38:62 로  -> supervisor, postrun          (28 : 8 : 5)
#  만든 뒤 daq-layout.sh 로 정규화하므로 여기 값은 대략이면 된다.
# 초기 크기. 클라이언트가 붙으면 그 터미널 크기를 따라가지만, 붙기 전(detached)
# 상태의 기준이 되고 pane 비율 계산도 이 크기에서 시작한다.
# 터미널 자체의 기본 크기는 gnome-terminal 프로파일의 default-size-* 로 맞춰 두었다.
COLS=${DAQ_TMUX_COLS:-157}
ROWS=${DAQ_TMUX_ROWS:-37}
tmux new-session -d -s "$SESSION" -n daq -c "$DIR" -x "$COLS" -y "$ROWS"
TOPLEFT=$(tmux list-panes -t "$SESSION:daq" -F '#{pane_id}' | head -1)
RIGHT=$(tmux split-window   -h -p 54 -P -F '#{pane_id}' -t "$TOPLEFT" -c "$DIR")
BOTLEFT=$(tmux split-window -v -p 32 -P -F '#{pane_id}' -t "$TOPLEFT" -c "$DIR")

POSTPANE=""
if [ "$POSTRUN" -eq 1 ]; then
   POSTPANE=$(tmux split-window -v -p 38 -P -F '#{pane_id}' -t "$BOTLEFT" -c "$DIR")
   tmux select-pane -t "$POSTPANE" -T "postrun ( production & merging) "
fi

# 오른쪽 아래에 데이터 이동/백업. rsync 진행 줄이 길어서 넓은 pane 이 낫다.
FLOWPANE=""
if [ "$DATAFLOW" -eq 1 ]; then
   FLOWPANE=$(tmux split-window -v -p 30 -P -F '#{pane_id}' -t "$RIGHT" -c "$DIR")
   tmux select-pane -t "$FLOWPANE" \
      -T "dataflow: /Data_ssd(RAW)->/data(PRD)->khu(backup)->scratch(save)"
fi

tmux select-pane -t "$TOPLEFT" -T "DAQ Run Status(monitor)"
tmux select-pane -t "$BOTLEFT" -T "supervisor"
tmux select-pane -t "$RIGHT"   -T "work space"

# ---- 좌상 : 상태 화면 ----
tmux send-keys -t "$TOPLEFT" "$DIR/scripts/rcmon.sh '$HB'" C-m

# ---- 좌하 : 감시자 ----
if [ "$SUP_RUNNING" -eq 1 ]; then
   echo "rcsupervisor 가 이미 돌고 있다 -> 새로 띄우지 않고 로그를 따라간다."
   tmux send-keys -t "$BOTLEFT" "tail -n 40 -f '$SUP_LOG'" C-m
else
   CMD="$SUP --params '$SUP_PARAMS'"
   if [ -r "$DESC_FILE" ]; then
      # 주석(#)과 빈 줄은 버리고 첫 줄만 쓴다. 줄 끝 공백은 남긴다 --
      # rcterm 이 뒤에 ', Split T [m] = N' 을 붙이므로 이전 런의 rundesc 와
      # 글자 하나까지 같으려면 그 공백이 있어야 한다.
      DESC=$(grep -v '^[[:space:]]*#' "$DESC_FILE" | grep -m1 '[^[:space:]]')
      [ -n "$DESC" ] && CMD="$CMD -- --desc '$DESC'"
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

# ---- 좌하 : merge + production 추적 ----
#  DAQ 를 방해하지 않도록 nice 를 걸고, 기록 중인 서브런보다 3개(=약 3분) 뒤에서만
#  처리한다. 이미 끝난 서브런은 건너뛰므로 바로 돌려도 안전하다.
#  RAW 가 이미 로컬 NVMe 에 있으므로(rcterm.params 의 rawdatadir) 처리도 그 자리에서
#  한다. --outroot 는 필요 없다. 완료된 런은 scripts/dataflow.sh 가 옮긴다.
POSTRUN_RAW=${POSTRUN_RAWROOT:-/Data_ssd/RAW}
if [ -n "$POSTPANE" ]; then
   tmux send-keys -t "$POSTPANE" \
      "$DIR/scripts/postrun.sh --follow --jobs 3 --lag 3 --rawroot '$POSTRUN_RAW'" C-m
fi

# ---- 우하 : 데이터 이동 + 외부 백업 ----
#  ssd -> data -> 경희대 -> scratch. 명령만 입력해 두지 않고 바로 띄운다 —
#  이것이 멈추면 /Data_ssd 가 차서 DAQ 까지 멈추기 때문이다.
#  읽고 옮기기만 하므로 수집 중에 시작해도 안전하다(수집 중인 런은 건드리지 않는다).
if [ -n "$FLOWPANE" ]; then
   if [ -r "$DF_PARAMS" ]; then
      tmux send-keys -t "$FLOWPANE" \
         "$DIR/scripts/dataflow.sh --params '$DF_PARAMS' --follow" C-m
   else
      tmux send-keys -t "$FLOWPANE" \
         "echo '설정 파일이 없다: $DF_PARAMS  (config/dataflow.params.example 에서 복사할 것)'" C-m
   fi
fi

# split-window -p 의 반올림은 창이 작을수록 크게 어긋난다. 만든 뒤 한 번 정규화한다.
[ -x "$DIR/scripts/daq-layout.sh" ] && "$DIR/scripts/daq-layout.sh" "$SESSION" >/dev/null 2>&1

tmux select-pane -t "$RIGHT"          # 작업용 pane 에서 시작
[ -n "${TMUX:-}" ] && exec tmux switch-client -t "$SESSION"
exec tmux attach -t "$SESSION"
