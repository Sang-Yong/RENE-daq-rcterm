#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  daq-layout.sh - tmux pane 비율을 정해진 값으로 되돌린다.
#
#      +----------------+---------------------+
#      | monitor   (28) |                     |
#      +----------------+                     |
#      | supervisor (8) |   work space        |
#      +----------------+                     |
#      | postrun    (5) |                     |
#      +----------------+---------------------+
#            46%                  54%
#
#      왼쪽 : 오른쪽 = 46 : 54
#      왼쪽 열 높이   = monitor : supervisor : postrun = 28 : 8 : 5
#      (실제로 쓰면서 맞춘 값이다. 합으로 정규화하므로 비율만 맞으면 된다)
#
#  퍼센트로 지정한 크기는 '그 순간의 창 크기'로 계산되어 열/행 수로 굳는다.
#  그래서 터미널 창 크기나 폰트를 바꾸면 비율이 어긋난다. 그때 이걸 부른다.
#
#  사용 :  scripts/daq-layout.sh [세션이름]      (기본 daq)
#          tmux 안에서는  Ctrl-B 다음 =
#
#  비율을 바꾸려면 환경변수로 :
#          DAQ_LAYOUT_LR=45  DAQ_LAYOUT_H="6 2 2"  scripts/daq-layout.sh
# ---------------------------------------------------------------------
set -u

S=${1:-daq}
LR=${DAQ_LAYOUT_LR:-46}          # 왼쪽 열 너비 [%]
HR=${DAQ_LAYOUT_H:-28 8 5}       # monitor : supervisor : postrun (실사용 배치)

tmux has-session -t "$S" 2>/dev/null || { echo "세션 없음 : $S"; exit 1; }

# 제목의 '앞부분'으로 찾는다. postrun pane 의 제목은
#   "postrun ( production & merging) "
# 처럼 뒤에 설명이 붙으므로 완전일치로 찾으면 놓친다.
pane_by_title() {
   tmux list-panes -s -t "$S" -F "#{pane_id} #{pane_title}" \
   | awk -v t="$1" '{id=$1; $1=""; sub(/^ /,""); if (index($0,t)==1) {print id; exit}}'
}
height_of() {
   tmux list-panes -s -t "$S" -F "#{pane_id} #{pane_height}" | awk -v p="$1" '$1==p{print $2; exit}'
}

MON=$(pane_by_title monitor)
SUP=$(pane_by_title supervisor)
POST=$(pane_by_title postrun)

[ -n "$MON" ] || { echo "monitor pane 을 찾을 수 없다 (pane 제목 확인)"; exit 1; }

# ---- 좌우 ----
tmux resize-pane -t "$MON" -x "${LR}%"

# ---- 왼쪽 열 높이 6 : 2 : 2 ----
#  위에서부터 크기를 확정하면 남은 공간이 아래로 밀린다.
#  마지막 pane(postrun)은 지정하지 않고 나머지를 받게 둔다.
set -- $HR
RM=${1:-6}; RS=${2:-2}; RP=${3:-2}
TOT=$(( RM + RS + RP ))

if [ -n "$SUP" ] && [ -n "$POST" ]; then
   # pane 제목 줄(pane-border-status)이 높이에 섞이므로 한 번에 계산하면 어긋난다.
   # 하나 줄이고 나서 남은 높이를 다시 재는 식으로 자기보정한다.
   LEFTH=$(( $(height_of "$MON") + $(height_of "$SUP") + $(height_of "$POST") ))
   if [ "$LEFTH" -gt 0 ]; then
      # 작은 pane 두 개를 먼저 확정하고 monitor 가 나머지를 흡수하게 한다.
      # 반대로 하면 tmux 가 재분배하면서 반올림 오차가 monitor 로 몰린다.
      SH=$(( (LEFTH * RS + TOT/2) / TOT )); [ "$SH" -lt 3 ] && SH=3
      PH=$(( (LEFTH * RP + TOT/2) / TOT )); [ "$PH" -lt 3 ] && PH=3
      tmux resize-pane -t "$POST" -y "$PH"
      tmux resize-pane -t "$SUP"  -y "$SH"
      # 두 번 적용해 재분배로 밀린 것을 다시 맞춘다
      tmux resize-pane -t "$POST" -y "$PH"
      tmux resize-pane -t "$SUP"  -y "$SH"
   fi
elif [ -n "$SUP" ]; then
   # postrun pane 이 없는 구성(--no-postrun)
   LEFTH=$(( $(height_of "$MON") + $(height_of "$SUP") ))
   [ "$LEFTH" -gt 0 ] && tmux resize-pane -t "$MON" -y $(( LEFTH * RM / (RM + RS) ))
fi

tmux display-message "레이아웃 복원 : 좌우 ${LR}:$((100-LR)) / 왼쪽 ${RM}:${RS}:${RP}"
tmux list-panes -s -t "$S" -F "  #{pane_title}  #{pane_width}x#{pane_height}"
