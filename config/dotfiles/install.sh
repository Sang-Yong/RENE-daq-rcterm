#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  install.sh - 이 폴더의 터미널/편집기 설정을 홈 디렉터리에 설치한다.
#
#  기존 파일은 덮어쓰기 전에 ~/dotfiles-backup-<날짜>/ 로 옮겨 둔다.
#
#  사용 :
#    config/dotfiles/install.sh              설정 파일만 설치
#    config/dotfiles/install.sh --fonts      폰트도 내려받아 설치 (인터넷 필요)
#    config/dotfiles/install.sh --terminal   gnome-terminal 프로파일도 적용
#    config/dotfiles/install.sh --all
#    config/dotfiles/install.sh --dry-run    무엇을 할지만 출력
# ---------------------------------------------------------------------
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BK=~/dotfiles-backup-$(date +%Y%m%d-%H%M%S)
DO_FONTS=0; DO_TERM=0; DRY=0

for a in "$@"; do
   case "$a" in
      --fonts)    DO_FONTS=1 ;;
      --terminal) DO_TERM=1 ;;
      --all)      DO_FONTS=1; DO_TERM=1 ;;
      --dry-run)  DRY=1 ;;
      -h|--help)  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *)          echo "unknown option : $a"; exit 1 ;;
   esac
done

run() { if [ "$DRY" -eq 1 ]; then echo "  [DRY] $*"; else eval "$@"; fi; }

# src dst 쌍. dst 가 이미 있으면 백업 후 덮어쓴다.
install_one() {          # src dst
   local src=$1 dst=$2
   [ -f "$src" ] || { echo "  건너뜀(원본 없음) : $src"; return; }
   if [ -e "$dst" ]; then
      run "mkdir -p '$BK'"
      run "cp -a '$dst' '$BK/'"
      echo "  백업 : $dst -> $BK/"
   fi
   run "mkdir -p '$(dirname "$dst")'"
   run "cp '$src' '$dst'"
   echo "  설치 : $dst"
}

#  실행 파일은 권한까지 맞춰 준다. cp 가 원본 모드를 따라가긴 하지만
#  umask 나 배포 경로에 따라 떨어질 수 있어 명시적으로 걸어 둔다.
install_exec() {         # src dst
   install_one "$1" "$2"
   [ -f "$1" ] && run "chmod 755 '$2'"
}

echo "== 설정 파일 =="
install_one "$HERE/tmux.conf"              "$HOME/.tmux.conf"
install_one "$HERE/dircolors"              "$HOME/.dircolors"
install_one "$HERE/vimrc"                  "$HOME/.vimrc"
install_one "$HERE/vim/colors/rene.vim"    "$HOME/.vim/colors/rene.vim"
install_one "$HERE/fontconfig/fonts.conf"  "$HOME/.config/fontconfig/fonts.conf"

echo "== 도구 =="
#  claude-transcript : Claude Code 대화를 평범한 텍스트로 뽑는다.
#  TUI 가 마우스 추적을 켜는 탓에 화면을 드래그해 복사하기가 어려운데,
#  화면과 씨름하는 대신 원본을 파일로 받는 편이 확실하다.
install_exec "$HERE/bin/claude-transcript" "$HOME/bin/claude-transcript"

#  Rocky/RHEL 기본 .bashrc 가 ~/bin 을 PATH 에 넣어 주지만, 배포판이 다르면
#  없을 수 있다. 조용히 안 되는 것보다 알려 주는 편이 낫다.
case ":${PATH}:" in
   *":$HOME/bin:"*) : ;;
   *) echo "  주의: ~/bin 이 PATH 에 없다. ~/.bashrc 에 아래를 넣을 것"
      echo "        export PATH=\"\$HOME/bin:\$PATH\"" ;;
esac

# vim 이 스왑/백업/undo 를 여기에 모은다 (데이터 디렉터리 오염 방지)
run "mkdir -p '$HOME/.vim/swap' '$HOME/.vim/backup' '$HOME/.vim/undo'"

# ---- .bashrc 는 통째로 덮지 않는다. 블록이 없을 때만 덧붙인다 ----
echo "== .bashrc =="
if grep -q "터미널/편집기 환경" "$HOME/.bashrc" 2>/dev/null; then
   echo "  이미 적용됨 (블록 존재). 건드리지 않는다"
else
   if [ -e "$HOME/.bashrc" ]; then
      run "mkdir -p '$BK'"; run "cp -a '$HOME/.bashrc' '$BK/'"
      echo "  백업 : ~/.bashrc -> $BK/"
   fi
   run "cat '$HERE/bashrc.snippet' >> '$HOME/.bashrc'"
   echo "  추가 : ~/.bashrc 끝에 블록 덧붙임"
fi

# ---- 폰트 ----
if [ "$DO_FONTS" -eq 1 ]; then
   echo "== 폰트 =="
   FD=$HOME/.local/share/fonts
   run "mkdir -p '$FD/Hack' '$FD/CascadiaCode'"
   TMP=$(mktemp -d)
   if [ ! -f "$FD/Hack/Hack-Bold.ttf" ]; then
      echo "  Hack v3.003 내려받는 중..."
      run "curl -sSL -o '$TMP/hack.zip' https://github.com/source-foundry/Hack/releases/download/v3.003/Hack-v3.003-ttf.zip"
      run "unzip -j -o '$TMP/hack.zip' '*.ttf' -d '$FD/Hack' >/dev/null"
   else echo "  Hack 이미 설치됨"; fi
   if [ ! -f "$FD/CascadiaCode/CascadiaCode-Bold.ttf" ]; then
      echo "  Cascadia Code v2407.24 내려받는 중... (144 MB)"
      run "curl -sSL -o '$TMP/cascadia.zip' https://github.com/microsoft/cascadia-code/releases/download/v2407.24/CascadiaCode-2407.24.zip"
      run "unzip -j -o '$TMP/cascadia.zip' 'ttf/static/CascadiaCode-*.ttf' 'ttf/static/CascadiaMono-*.ttf' -d '$FD/CascadiaCode' >/dev/null"
   else echo "  Cascadia Code 이미 설치됨"; fi
   run "rm -rf '$TMP'"
   run "fc-cache -f >/dev/null 2>&1"
   echo "  폰트 캐시 갱신"
else
   echo "== 폰트 : 건너뜀 (--fonts 로 설치) =="
fi

# ---- gnome-terminal 프로파일 ----
if [ "$DO_TERM" -eq 1 ]; then
   echo "== gnome-terminal 프로파일 =="
   if command -v gsettings >/dev/null 2>&1; then
      run "'$HERE/gnome-terminal-profile.sh'"
   else
      echo "  gsettings 없음. 건너뜀"
   fi
else
   echo "== gnome-terminal : 건너뜀 (--terminal 로 적용) =="
fi

echo
echo "끝. 새 셸을 열거나 다음을 실행하면 바로 반영된다 :"
echo "  source ~/.bashrc"
echo "  tmux source-file ~/.tmux.conf     # tmux 가 떠 있을 때"
[ -d "$BK" ] && echo "백업 : $BK"
