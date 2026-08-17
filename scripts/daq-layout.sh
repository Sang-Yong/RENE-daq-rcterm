#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  daq-layout.sh - tmux pane 비율을 정해진 값으로 되돌린다.
#
#      +--------------------------+---------------------+
#      | DAQ Run Status(monitor)  |   work space    (7) |
#      |                     (28) |                     |
#      +--------------------------+                     |
#      | supervisor           (8) |                     |
#      +--------------------------+---------------------+
#      | postrun              (5) |   dataflow:     (3) |
#      +--------------------------+---------------------+
#            46%                            54%
#
#      왼쪽 : 오른쪽 = 46 : 54
#      왼쪽 열 높이   = monitor : supervisor : postrun = 28 : 8 : 5
#      오른쪽 열 높이 = work space : dataflow          = 7 : 3
#      (실제로 쓰면서 맞춘 값이다. 합으로 정규화하므로 비율만 맞으면 된다)
#
#      pane 은 제목 안의 열쇠말로 찾는다(아래 pane_by_title). 제목 전체가
#      아니라 'monitor' 처럼 한 낱말만 들어 있으면 된다.
#
#  퍼센트로 지정한 크기는 '그 순간의 창 크기'로 계산되어 열/행 수로 굳는다.
#  그래서 터미널 창 크기나 폰트를 바꾸면 비율이 어긋난다. 그때 이걸 부른다.
#
#  사용 :  scripts/daq-layout.sh [세션이름]      (기본 daq)
#          tmux 안에서는  Ctrl-B 다음 =
#
#  비율을 바꾸려면 환경변수로 :
#          DAQ_LAYOUT_LR=45  DAQ_LAYOUT_H="6 2 2"  DAQ_LAYOUT_R="7 3"  \
#             scripts/daq-layout.sh
# ---------------------------------------------------------------------
set -u

S=${1:-daq}
LR=${DAQ_LAYOUT_LR:-46}          # 왼쪽 열 너비 [%]
HR=${DAQ_LAYOUT_H:-28 8 5}       # monitor : supervisor : postrun (실사용 배치)
RR=${DAQ_LAYOUT_R:-7 3}          # work space : dataflow

tmux has-session -t "$S" 2>/dev/null || { echo "세션 없음 : $S"; exit 1; }

# 제목 '안에 들어 있으면' 찾은 것으로 본다. pane 제목은 사람이 읽으라고
# 붙이는 것이라 앞뒤로 말이 붙는다 --
#   "DAQ Run Status(monitor)"  "postrun ( production & merging) "
#   "dataflow: /Data_ssd(RAW)->/data(PRD)->khu(backup)->scratch(save)"
# 완전일치는 물론이고 앞부분 일치로 찾아도 놓친다(실제로 한 번 깨졌다).
# 아래 다섯 열쇠말은 서로 다른 제목에 겹쳐 나오지 않는다.
pane_by_title() {
   tmux list-panes -s -t "$S" -F "#{pane_id} #{pane_title}" \
   | awk -v t="$1" '{id=$1; $1=""; sub(/^ /,""); if (index($0,t)>0) {print id; exit}}'
}
height_of() {
   tmux list-panes -s -t "$S" -F "#{pane_id} #{pane_height}" | awk -v p="$1" '$1==p{print $2; exit}'
}

MON=$(pane_by_title monitor)
SUP=$(pane_by_title supervisor)
POST=$(pane_by_title postrun)
WORK=$(pane_by_title "work space")
FLOW=$(pane_by_title dataflow)

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
   # pane 제목 줄(pane-border-status)이 높이에 섞이므로 현재 높이의 합에서 나눈다.
   LEFTH=$(( $(height_of "$MON") + $(height_of "$SUP") + $(height_of "$POST") ))
   if [ "$LEFTH" -gt 0 ]; then
      # **위에서 아래로** 확정하고 마지막 pane 이 나머지를 받게 한다.
      # tmux 의 resize-pane -y 는 그 pane 의 '아래쪽' 경계를 움직인다. 그래서
      # 아래부터 잡으면 위엣것을 맞추는 순간 아래엣것을 도로 빼앗는다 --
      # postrun 을 4행으로 만든 뒤 supervisor 를 7행으로 만들면 postrun 이
      # 1행으로 찌그러진다(실측). 그래서 monitor -> supervisor 순으로 잡는다.
      MH=$(( (LEFTH * RM + TOT/2) / TOT )); [ "$MH" -lt 3 ] && MH=3
      SH=$(( (LEFTH * RS + TOT/2) / TOT )); [ "$SH" -lt 3 ] && SH=3
      # postrun 에게 최소 3행은 남겨 둔다
      [ $(( MH + SH + 3 )) -gt "$LEFTH" ] && MH=$(( LEFTH - SH - 3 ))
      [ "$MH" -lt 3 ] && MH=3
      tmux resize-pane -t "$MON" -y "$MH"
      tmux resize-pane -t "$SUP" -y "$SH"
   fi
elif [ -n "$SUP" ]; then
   # postrun pane 이 없는 구성(--no-postrun)
   LEFTH=$(( $(height_of "$MON") + $(height_of "$SUP") ))
   [ "$LEFTH" -gt 0 ] && tmux resize-pane -t "$MON" -y $(( LEFTH * RM / (RM + RS) ))
fi

# ---- 오른쪽 열 높이 (work space : dataflow) ----
#  dataflow pane 이 없는 구성(--no-dataflow)이면 아무것도 하지 않는다.
if [ -n "$WORK" ] && [ -n "$FLOW" ]; then
   set -- $RR
   RW=${1:-7}; RF=${2:-3}
   RIGHTH=$(( $(height_of "$WORK") + $(height_of "$FLOW") ))
   if [ "$RIGHTH" -gt 0 ]; then
      FH=$(( (RIGHTH * RF + (RW+RF)/2) / (RW + RF) )); [ "$FH" -lt 3 ] && FH=3
      tmux resize-pane -t "$FLOW" -y "$FH"
      tmux resize-pane -t "$FLOW" -y "$FH"
   fi
fi

tmux display-message "레이아웃 복원 : 좌우 ${LR}:$((100-LR)) / 왼쪽 ${RM}:${RS}:${RP}"
tmux list-panes -s -t "$S" -F "  #{pane_title}  #{pane_width}x#{pane_height}"
