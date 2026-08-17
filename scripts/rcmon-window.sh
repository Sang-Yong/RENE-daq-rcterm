#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  rcmon-window.sh - 상태 화면(rcmon.sh)을 큰 글꼴 창으로 따로 띄운다.
#
#  왜 별도 창인가
#    tmux 는 pane 마다 글꼴 크기를 다르게 할 수 없다. 글꼴은 터미널
#    에뮬레이터가 '창' 단위로 갖는 속성이고 tmux 에는 폰트 옵션 자체가 없다.
#    그래서 한 화면만 크게 보려면 창을 따로 여는 수밖에 없다.
#
#    다행히 rcmon.sh 는 heartbeat 파일을 읽기만 하는 뷰어라 몇 개를 띄워도
#    DAQ 에 아무 영향이 없다. tmux 안의 monitor pane 은 그대로 두고
#    이 창을 함께 쓰면 된다.
#
#  처음 실행하면 'RENE monitor' 라는 gnome-terminal 프로파일을 만든다.
#  색은 기본 프로파일에서 그대로 가져오고 글꼴 크기만 키운다.
#
#  사용 :
#     scripts/rcmon-window.sh              글꼴 12 로 띄운다
#     scripts/rcmon-window.sh 14           크기 지정
#     scripts/rcmon-window.sh --remove     만든 프로파일을 지운다
# ---------------------------------------------------------------------
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
HB=${DAQ_HEARTBEAT:-/Data/LOG/rcterm.hb}
NAME="RENE monitor"
LIST=org.gnome.Terminal.ProfilesList
BASE=org.gnome.Terminal.Legacy.Profile
PPATH=/org/gnome/terminal/legacy/profiles:

command -v gsettings >/dev/null || { echo "gsettings 가 없다 (GNOME 환경이 아님)"; exit 1; }

prof() { echo "${BASE}:${PPATH}/:$1/"; }

# 이름으로 프로파일 찾기
find_profile() {
   local u
   for u in $(gsettings get $LIST list | tr -d "[]',"); do
      [ "$(gsettings get "$(prof "$u")" visible-name 2>/dev/null)" = "'$NAME'" ] && { echo "$u"; return; }
   done
}

if [ "${1:-}" = "--remove" ]; then
   U=$(find_profile)
   [ -z "$U" ] && { echo "'$NAME' 프로파일이 없다"; exit 0; }
   NEW=$(gsettings get $LIST list | sed "s/'$U', *//; s/, *'$U'//; s/'$U'//")
   gsettings set $LIST list "$NEW"
   dconf reset -f "${PPATH}/:$U/" 2>/dev/null
   echo "'$NAME' 프로파일 삭제함"
   exit 0
fi

SIZE=${1:-12}
case "$SIZE" in *[!0-9]*) echo "글꼴 크기는 숫자로 : $0 12"; exit 1 ;; esac

DEF=$(gsettings get $LIST default | tr -d "'")
DEFP=$(prof "$DEF")
U=$(find_profile)

if [ -z "$U" ]; then
   U=$(cat /proc/sys/kernel/random/uuid)
   # 목록에 추가
   CUR=$(gsettings get $LIST list)
   if [ "$CUR" = "@as []" ] || [ "$CUR" = "[]" ]; then
      gsettings set $LIST list "['$U']"
   else
      gsettings set $LIST list "$(echo "$CUR" | sed "s/\]$/, '$U']/")"
   fi
   # 기본 프로파일의 모양을 그대로 가져온다. 글꼴만 나중에 덮는다.
   P=$(prof "$U")
   gsettings set "$P" visible-name "$NAME"
   for k in use-theme-colors background-color foreground-color palette \
            bold-color-same-as-fg bold-is-bright cursor-shape audible-bell \
            cell-height-scale cell-width-scale scrollback-lines; do
      v=$(gsettings get "$DEFP" "$k" 2>/dev/null) && gsettings set "$P" "$k" "$v" 2>/dev/null
   done
   gsettings set "$P" use-system-font false
   echo "'$NAME' 프로파일 생성 ($U)"
fi

P=$(prof "$U")
# 기본 프로파일의 글꼴에서 이름만 떼어내 크기를 바꾼다 (예: 'Hack Bold 10' -> 'Hack Bold 12')
FAM=$(gsettings get "$DEFP" font | tr -d "'" | sed 's/ [0-9]\+$//')
gsettings set "$P" font "$FAM $SIZE"
gsettings set "$P" default-size-columns 74
gsettings set "$P" default-size-rows 22
echo "글꼴 : $FAM $SIZE"

exec gnome-terminal --window --profile="$NAME" --title="RENE monitor" \
     -- bash -lc "'$DIR/rcmon.sh' '$HB'"
