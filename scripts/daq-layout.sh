#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  daq-layout.sh - tmux pane 비율을 정해진 값으로 되돌린다.
#
#      좌우      왼쪽 : 오른쪽 = 5.5 : 4.5
#      오른쪽아래  postrun 높이 = 왼쪽 열 전체 높이의 3/4
#
#  퍼센트로 지정한 크기는 '그 순간의 창 크기'로 계산되어 열/행 수로 굳는다.
#  그래서 터미널 창 크기나 폰트를 바꾸면 비율이 어긋난다. 그때 이걸 부른다.
#
#  사용 :  scripts/daq-layout.sh [세션이름]      (기본 daq)
#          tmux 안에서는  Ctrl-B 다음 =
# ---------------------------------------------------------------------
set -u

S=${1:-daq}
LR=${DAQ_LAYOUT_LR:-55}      # 왼쪽 열 비율 [%]
BR=${DAQ_LAYOUT_BR:-75}      # postrun 높이 = 왼쪽 열 높이의 [%]

tmux has-session -t "$S" 2>/dev/null || { echo "세션 없음 : $S"; exit 1; }

pane_by_title() {            # 제목으로 pane_id 찾기
   tmux list-panes -s -t "$S" -F "#{pane_id} #{pane_title}" | awk -v t="$1" '$2==t{print $1; exit}'
}

MON=$(pane_by_title monitor)
SUP=$(pane_by_title supervisor)
POST=$(pane_by_title postrun)

[ -n "$MON" ] || { echo "monitor pane 을 찾을 수 없다 (pane 제목 확인)"; exit 1; }

# 좌우 : 왼쪽 열을 LR% 로
tmux resize-pane -t "$MON" -x "${LR}%"

# 오른쪽 아래 : 왼쪽 열(monitor+supervisor) 높이의 BR% 로
if [ -n "$POST" ] && [ -n "$SUP" ]; then
   LEFTH=$(tmux list-panes -s -t "$S" -F "#{pane_id} #{pane_height}" \
           | awk -v a="$MON" -v b="$SUP" '$1==a||$1==b{s+=$2} END{print s+0}')
   if [ "$LEFTH" -gt 0 ]; then
      TARGET=$(( LEFTH * BR / 100 ))
      [ "$TARGET" -lt 3 ] && TARGET=3
      tmux resize-pane -t "$POST" -y "$TARGET"
   fi
fi

tmux display-message "레이아웃 복원 : 좌우 ${LR}:$((100-LR)) / postrun 높이 ${BR}%"
tmux list-panes -s -t "$S" -F "  #{pane_title}  #{pane_width}x#{pane_height}"
