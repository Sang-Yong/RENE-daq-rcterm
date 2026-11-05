#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  chainwatch 의 pane 재기동을 진짜 tmux 로 (별도 서버 'tmux -L <임시>' -- 운영 tmux 'daq' 무접촉).
#  리뷰 재현 : 프롬프트에 사람이 쳐 둔 글자(ran.txt)가 있을 때 그 뒤에 명령을 이어 붙였다.
#  기대 : 그런 pane 은 손대지 않는다. 맨 프롬프트인 pane 은 줄을 비우고 친다.
#  ★ pane_idle · capture-pane · send-keys 가 진짜로 돈다. 다른 바깥 명령(ps 목록·pgrep·df·알림)은 가짜.
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
CW=$DIR/scripts/chainwatch.sh
FX=$DIR/tests/fixtures
command -v tmux >/dev/null || { echo "tmux 없음 -- 건너뜀"; exit 0; }
T=$(mktemp -d); SOCK="cwtest$$"
trap 'tmux -L "$SOCK" kill-server 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$T/bin"
printf '#!/bin/bash\nexec tmux -L %s "$@"\n' "$SOCK" > "$T/bin/tmux"
printf '#!/bin/bash\nexit 1\n' > "$T/bin/pgrep"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/mountpoint"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/notify.calls"\n' "$T" > "$T/bin/notify"
#  다시 띄울 '명령' 은 파일 하나를 만드는 것. 실제로 실행됐는지를 그 파일로 본다
printf '#!/bin/bash\necho "echo RUN-$2 > %s/ran-$2.txt"\n' "$T" > "$T/bin/daqtmux"
chmod +x "$T"/bin/*
: > "$T/ps.txt"; : > "$T/df.txt"; : > "$T/sup.log"
sed -e "s/^time=.*/time=$(date +%s)/" -e "s/^phase=.*/phase=running/" -e "s/^daqtime=.*/daqtime=600/" \
    "$FX/rcterm_hb_ended_20261105.txt" > "$T/hb"

SH="env -i PATH=/usr/bin:/bin HOME=$T TERM=xterm PS1='\$ ' bash --norc --noprofile -i"
tmux -L "$SOCK" new-session -d -s daq -x 120 -y 30 "$SH"
P1=$(tmux -L "$SOCK" list-panes -t daq -F '#{pane_id}' | head -1)
P2=$(tmux -L "$SOCK" split-window -t "$P1" -P -F '#{pane_id}' "$SH")
tmux -L "$SOCK" select-pane -t "$P1" -T "postrun ( production & merging) "
tmux -L "$SOCK" select-pane -t "$P2" -T "dataflow: /Data_ssd(RAW)->/data(PRD)"
sleep 1
#  postrun pane 에 사람이 글자를 쳐 두고 Enter 는 안 쳤다
tmux -L "$SOCK" send-keys -t "$P1" -l "ran.txt"
sleep 0.5

run() { CHAINWATCH_LOCK=$T/.lock CHAINWATCH_TMUX=$T/bin/tmux CHAINWATCH_PGREP=$T/bin/pgrep CHAINWATCH_KILL=/bin/false \
        CHAINWATCH_MOUNTPOINT=$T/bin/mountpoint CHAINWATCH_PS=$T/ps.txt CHAINWATCH_DF_FILE=$T/df.txt \
        CHAINWATCH_SUPLOG=$T/sup.log CHAINWATCH_PROC=$T/proc CHAINWATCH_DAQTMUX=$T/bin/daqtmux \
        CHAINWATCH_RCTERM_PARAMS=/dev/null CHAINWATCH_HOLD=$T/hold NETSYNC_STATE=$T/ns \
        "$CW" --params /nonexistent --gate on --heartbeat "$T/hb" --state "$T/state" --log "$T/log" \
              --dbfile /nonexistent.db --notify "$T/bin/notify" >/dev/null 2>&1; }

echo "[1] 사람이 친 글자가 있는 pane 은 손대지 않고, 맨 프롬프트 pane 은 다시 띄운다"
run; run; sleep 1
check "dataflow pane 은 명령을 실행했다"           '[ -e "$T/ran-dataflow.txt" ]'
check "postrun pane 은 실행하지 않았다"            '[ ! -e "$T/ran-postrun.txt" ]'
L1=$(tmux -L "$SOCK" capture-pane -p -t "$P1" | sed "s/[[:space:]]*\$//" | grep -v "^\$" | tail -1)
check "postrun pane 의 줄은 사람이 친 그대로 ('\$ ran.txt')" '[ "$L1" = "\$ ran.txt" ]'
check "이어 붙인 흔적 없음"                        '! tmux -L "$SOCK" capture-pane -p -t "$P1" | grep -q "ran.txtecho"'
check "알림에 사유"                                'grep -q "맨 프롬프트가 아니다" "$T/notify.calls"'

echo "[2] 사람이 줄을 비운 뒤에는 다시 띄운다 (한 시간 상한을 지운 뒤)"
tmux -L "$SOCK" send-keys -t "$P1" C-u; sleep 0.5
grep -v '^autorestart_' "$T/state" > "$T/state.2"; mv "$T/state.2" "$T/state"
run; sleep 1
check "postrun pane 이 명령을 실행했다"            '[ -e "$T/ran-postrun.txt" ]'
check "그 줄은 명령 그대로 (앞에 붙은 것 없음)"    'tmux -L "$SOCK" capture-pane -p -t "$P1" | grep -qx "\$ echo RUN-postrun > $T/ran-postrun.txt"'

echo "[3] pane 에 무언가 돌고 있으면 (sleep) 손대지 않는다"
rm -f "$T/ran-dataflow.txt"; tmux -L "$SOCK" send-keys -t "$P2" -l "sleep 30"; tmux -L "$SOCK" send-keys -t "$P2" Enter; sleep 1
grep -v '^autorestart_' "$T/state" > "$T/state.2"; mv "$T/state.2" "$T/state"
run; sleep 1
check "dataflow 를 다시 치지 않았다"               '[ ! -e "$T/ran-dataflow.txt" ]'

echo; echo "PASS $PASS  FAIL $FAIL"
[ "$FAIL" -eq 0 ]
