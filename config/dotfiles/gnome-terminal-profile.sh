#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  gnome-terminal-profile.sh
#    gnome-terminal 프로파일(색·폰트·크기)을 이 저장소 기준으로 맞춘다.
#
#  프로파일 UUID 는 PC 마다 다르다. 인자로 주지 않으면 기본 프로파일을 쓴다.
#    사용 :  config/dotfiles/gnome-terminal-profile.sh [UUID]
#
#  되돌리려면 실행 전에 현재 값을 먼저 저장해 둘 것 :
#    for k in font use-theme-colors background-color foreground-color palette; do
#      echo "$k = $(gsettings get "$S" $k)"; done
# ---------------------------------------------------------------------
set -eu

UUID=${1:-$(gsettings get org.gnome.Terminal.ProfilesList default | tr -d "'")}
S="org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${UUID}/"
echo "프로파일 : $UUID"

gsettings set "$S" font                   \'Hack\ Bold\ 10\'
gsettings set "$S" use-system-font        false
gsettings set "$S" use-theme-colors       false
gsettings set "$S" background-color       \'#1e2127\'
gsettings set "$S" foreground-color       \'#e3e8ef\'
gsettings set "$S" bold-color-same-as-fg  true
gsettings set "$S" bold-is-bright         true
gsettings set "$S" palette                \[\'#2a2f38\'\,\ \'#ff7b86\'\,\ \'#b6e3a0\'\,\ \'#f0d399\'\,\ \'#8cc7ff\'\,\ \'#dda5ee\'\,\ \'#7fd3de\'\,\ \'#e8edf3\'\,\ \'#6b7280\'\,\ \'#ffa0a8\'\,\ \'#ccf0b8\'\,\ \'#ffe6b3\'\,\ \'#b3daff\'\,\ \'#eec4f7\'\,\ \'#a5e5ee\'\,\ \'#ffffff\'\]
gsettings set "$S" cursor-shape           \'ibeam\'
gsettings set "$S" audible-bell           false
gsettings set "$S" cell-height-scale      1.1000000000000001
gsettings set "$S" cell-width-scale       1.0
gsettings set "$S" default-size-columns   157
gsettings set "$S" default-size-rows      37

echo "적용 완료. 이미 열려 있는 창은 폰트 목록을 캐싱했을 수 있으니"
echo "바뀌지 않으면 창을 닫았다 다시 열 것 (tmux 세션은 영향 없음)."
