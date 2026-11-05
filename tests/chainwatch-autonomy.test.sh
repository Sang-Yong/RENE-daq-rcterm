#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  chainwatch 의 자동 대응 시험 (2026-11-05 감사 D-1~D-4)
#     D-1  계수율은 순간 sr= 기준 · rate_high 때 감시자에 SIGUSR1 (런당 한 번, SigCgt 확인)
#     D-2  disk_low (/Data_ssd · /data, 메일 문턱 / 알람 문턱)
#     D-3  supervisor_down (FATAL) + supervisor pane 자동 재기동 (시간당 1 · 하루 상한)
#     D-4  chain_down 때 postrun · dataflow pane 자동 재기동 (/scratch 빠지면 안 함)
#
#  ★ 하드웨어 · 실 tmux · 실 kill · 실 df · 실 메일 무접촉. tmux · pgrep · kill · mountpoint · ps · df ·
#    daq-tmux.sh · daq-notify.sh 를 전부 가짜로 갈아끼운다. 픽스처는 실물 복사 (tests/fixtures).
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
CW=$DIR/scripts/chainwatch.sh
FX=$DIR/tests/fixtures
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$T/bin" "$T/proc" "$T/ssd" "$T/mid"
#  가짜 알림기 : 인자를 적는다
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/notify.calls"\nexit 0\n' "$T" > "$T/bin/notify"
#  가짜 tmux : has-session 은 $T/tmux_has 가 있으면 성공, list-panes 는 panes.txt, send-keys 는 적는다
cat > "$T/bin/tmux" <<TM
#!/bin/bash
case "\$1" in
  has-session) [ -e "$T/tmux_has" ] ;;
  list-panes)  cat "$T/panes.txt" ;;
  send-keys)   shift; case "\$*" in *" C-a C-k") ;; *) printf '%s\n' "\$*" >> "$T/tmux.calls" ;; esac ;;
  capture-pane) cat "$T/capture" 2>/dev/null ;;
  *) exit 1 ;;
esac
TM
#  가짜 pgrep -x <이름> : $T/alive 의 '이름 pid' 줄
cat > "$T/bin/pgrep" <<PG
#!/bin/bash
n=\${2:-}; awk -v n="\$n" '\$1==n{print \$2; f=1} END{exit !f}' "$T/alive" 2>/dev/null
PG
printf '#!/bin/bash\necho "$*" >> "%s/kill.calls"\nexit 0\n' "$T" > "$T/bin/kill"
printf '#!/bin/bash\n[ -e "%s/mounted" ]\n' "$T" > "$T/bin/mountpoint"
#  가짜 daq-tmux.sh --print-cmd <pane>
printf '#!/bin/bash\necho "CMD-$2 --follow"\n' > "$T/bin/daqtmux"
chmod +x "$T"/bin/*
: > "$T/rcterm.params"
#  pane 화면의 마지막 줄 (실물 프롬프트 모양). 사람이 친 글자가 있으면 손대지 않는다
printf 'some output\n[frontend@rocky9 RENE-daq-rcterm]$ \n\n' > "$T/capture"
cat > "$T/panes.txt" <<'PN'
%0 101 DAQ Run Status(monitor)
%2 102 supervisor
%3 103 postrun ( production & merging) 
%1 104 work space
%4 105 dataflow: /Data_ssd(RAW)->/data(PRD)->khu(backup)->scratch(save)
PN
export CHAINWATCH_LOCK=$T/.lock CHAINWATCH_TMUX=$T/bin/tmux CHAINWATCH_PGREP=$T/bin/pgrep \
       CHAINWATCH_KILL=$T/bin/kill CHAINWATCH_MOUNTPOINT=$T/bin/mountpoint CHAINWATCH_PS=$T/ps.txt \
       CHAINWATCH_DF_FILE=$T/df.txt CHAINWATCH_SUPLOG=$T/sup.log CHAINWATCH_PROC=$T/proc \
       CHAINWATCH_DAQTMUX=$T/bin/daqtmux CHAINWATCH_RCTERM_PARAMS=$T/rcterm.params \
       CHAINWATCH_IDLE_PIDS="101 102 103 104 105" CHAINWATCH_HOLD=$T/hold CHAINWATCH_BTIME=0 NETSYNC_STATE=$T/netsync.state NOTIFY_LOG=$T/notify.log
P=$T/cw.params
printf 'chain_ssd_root = %s\nchain_mid_root = %s\nchain_min_rate = 100\n' "$T/ssd" "$T/mid" > "$P"
HB=$T/rcterm.hb; ST=$T/state; LOG=$T/cw.log
#  정상 배경 : postrun·dataflow 살아 있음, /scratch 마운트, 디스크 넉넉, 감시자 살아 있음
normal() {
   printf '%s\n' "90211 bash /home/frontend/DAQ/RENE-daq-rcterm/scripts/postrun.sh --follow --jobs 3 --lag 3" \
                 "90209 bash /home/frontend/DAQ/RENE-daq-rcterm/scripts/dataflow.sh --params x --follow" > "$T/ps.txt"
   touch "$T/mounted" "$T/tmux_has"
   printf '%s 3000\n%s 30000\n' "$T/ssd" "$T/mid" > "$T/df.txt"
   echo "rcsupervisor 4242" > "$T/alive"
   mkdir -p "$T/proc/4242"; printf 'Name:\trcsupervisor\nSigCgt:\t0000000000014202\n' > "$T/proc/4242/status"
   cp "$FX/rcsupervisor_stop_20261105.txt" "$T/sup.log"
}
#  heartbeat : 실물(rcterm_hb_ended_20261105.txt) 형식 그대로, phase·run·daqtime·sr·ar 만 바꾼다
hb() {  # run daqtime sr ar [phase]
   sed -e "s/^time=.*/time=$(date +%s)/" -e "s/^phase=.*/phase=${5:-running}/" -e "s/^run=.*/run=$1/" \
       -e "s/^daqtime=.*/daqtime=$2/" -e "s/ sr=[0-9.]* ar=[0-9.]*/ sr=$3 ar=$4/" "$FX/rcterm_hb_ended_20261105.txt" > "$HB"
}
run() { : > "$T/notify.calls"; : > "$T/tmux.calls"; : > "$T/kill.calls"
        "$CW" --params "$P" --gate on --heartbeat "$HB" --state "$ST" --log "$LOG" --dbfile /nonexistent.db \
              --notify "$T/bin/notify" "$@" >/dev/null 2>&1; }
fresh() { rm -f "$ST" "$LOG"; normal; }

echo "[D1] 계수율은 순간 sr= 기준"
fresh; hb 4423 60000 40000 7600; run
check "ar 7.6 k · sr 40 k -> rate_high"           'grep -q " rate_high --" "$T/notify.calls"'
check "사유에 '순간 sr' 과 40000"                  'grep -q "순간 sr) 최댓값 40000" "$T/notify.calls"'
fresh; hb 4423 60000 7000 40000; run
check "ar 40 k · sr 7 k -> 알림 없음"              '! grep -q " rate_high --" "$T/notify.calls"'
fresh; hb 4423 60000 50 7000; run --consecutive 1
check "sr 50 Hz -> rate_low"                       'grep -q " rate_low --" "$T/notify.calls"'
fresh; sed -e "s/ sr=[0-9.]*//" -e "s/^time=.*/time=$(date +%s)/" -e "s/^phase=.*/phase=running/" -e "s/ ar=[0-9.]*/ ar=35000/" \
       "$FX/rcterm_hb_ended_20261105.txt" > "$HB"; run
check "sr 없는 옛 heartbeat 는 ar 로 물러난다"     'grep -q "평균 ar) 최댓값 35000" "$T/notify.calls"'

echo "[D1b] rate_high -> 감시자에 SIGUSR1 (런당 한 번)"
fresh; hb 4423 60000 40000 7600; run
check "kill -USR1 4242"                            'grep -qx -- "-USR1 4242" "$T/kill.calls"'
check "알림 사유에 마감 요청"                       'grep -q "SIGUSR1 = run 4423 정상 마감" "$T/notify.calls"'
run
check "같은 런 두 번째 회차는 안 보낸다"           '[ ! -s "$T/kill.calls" ]'
hb 4424 600 40000 40000; run
check "다음 런이면 다시 보낸다"                    'grep -qx -- "-USR1 4242" "$T/kill.calls"'
fresh; printf 'Name:\trcsupervisor\nSigCgt:\t0000000000014002\n' > "$T/proc/4242/status"   # 실물 bash 의 값 (USR1 없음)
hb 4423 60000 40000 7600; run
check "SIGUSR1 을 처리하지 않는 감시자에는 안 보낸다" '[ ! -s "$T/kill.calls" ]'
check "사유에 그 사실"                              'grep -q "SIGUSR1 을 처리하지 않는 판" "$T/notify.calls"'
fresh; hb 4423 60000 40000 7600; printf 'chain_rate_stop = 0\n' >> "$P"; run
check "chain_rate_stop = 0 이면 안 보낸다"         '[ ! -s "$T/kill.calls" ]'
sed -i '/chain_rate_stop/d' "$P"
fresh; hb 4423 60000 40000 7600; run --dry-run
check "--dry-run 은 kill·알림 없음"                '[ ! -s "$T/kill.calls" ] && [ ! -s "$T/notify.calls" ]'

echo "[D2] disk_low"
fresh; hb 4432 600 6000 6000; printf '%s 500\n%s 30000\n' "$T/ssd" "$T/mid" > "$T/df.txt"; run
check "/Data_ssd 500 GB -> 메일 (알람 없음)"       'grep " disk_low --" "$T/notify.calls" | grep -v -q -- "--force-alarm"'
run
check "같은 수준은 재알림 간격 안에서 생략"        '! grep -q " disk_low --" "$T/notify.calls"'
printf '%s 13\n%s 30000\n' "$T/ssd" "$T/mid" > "$T/df.txt"; run
check "13 GB 로 떨어지면 즉시 알람+메일"           'grep " disk_low --" "$T/notify.calls" | grep -q -- "--force-alarm"'
check "사유에 경로·여유"                           'grep -q "$T/ssd 여유 13 GB" "$T/notify.calls"'
printf '%s 3000\n%s 2000\n' "$T/ssd" "$T/mid" > "$T/df.txt"; run
check "/Data_ssd 해소 로그"                        'grep -q "disk_low $T/ssd 해소됨" "$LOG"'
check "/data 2000 GB (문턱 3000) -> 메일"          'grep -q "$T/mid 여유 2000 GB" "$T/notify.calls"'
check "/data 는 사건명 mid_disk_low"                'grep " mid_disk_low --" "$T/notify.calls" | grep -q "$T/mid"'
fresh; hb 4432 600 6000 6000; printf '%s 100\n%s 100\n' "$T/ssd" "$T/mid" > "$T/df.txt"; run
check "둘 다 모자라면 두 사건 (disk_low · mid_disk_low)" 'grep -q " disk_low --" "$T/notify.calls" && grep -q " mid_disk_low --" "$T/notify.calls"'

echo "[D3] supervisor_down : 감시자 FATAL -> 알림 + supervisor pane 재기동"
fresh; hb 4427 10 0 0 ended; : > "$T/alive"; cp "$FX/rcsupervisor_fatal_20261103.txt" "$T/sup.log"; run
check "supervisor_down 알림"                       'grep -q " supervisor_down --" "$T/notify.calls"'
check "사유에 FATAL 줄"                            'grep -q "FATAL too many consecutive failures" "$T/notify.calls"'
check "supervisor pane(%2) 에 -l 로 명령"          'grep -qx -- "-t %2 -l CMD-supervisor --follow" "$T/tmux.calls"'
check "Enter 따로"                                 'grep -qx -- "-t %2 Enter" "$T/tmux.calls"'
check "다른 pane 은 안 건드린다"                   '[ "$(grep -c "^-t %2" "$T/tmux.calls")" = "$(wc -l < "$T/tmux.calls")" ]'
run
check "한 시간 안에는 다시 띄우지 않는다"          '[ ! -s "$T/tmux.calls" ]'
check "알림도 재알림 간격 안이라 생략"             '! grep -q " supervisor_down --" "$T/notify.calls"'
fresh; hb 4432 10 0 0 ended; : > "$T/alive"; run
check "'rcsupervisor stop' 으로 끝났으면 조용"     '[ ! -s "$T/notify.calls" ] && [ ! -s "$T/tmux.calls" ]'
fresh; hb 4427 10 0 0 ended; echo "daq 777" > "$T/alive"; cp "$FX/rcsupervisor_fatal_20261103.txt" "$T/sup.log"; run
check "고아 daq 가 있으면 재기동하지 않는다"       '[ ! -s "$T/tmux.calls" ]'
check "사유에 고아"                                'grep -q "daq 가 아직 살아 있다" "$T/notify.calls"'
fresh; hb 4427 10 0 0 ended; : > "$T/alive"; cp "$FX/rcsupervisor_fatal_20261103.txt" "$T/sup.log"; rm -f "$T/rcterm.params"; run
check "rcterm.params 가 없으면 재기동하지 않는다"  '[ ! -s "$T/tmux.calls" ] && grep -q "rcterm.params 가 없다" "$T/notify.calls"'
: > "$T/rcterm.params"
fresh; hb 4427 10 0 0 ended; : > "$T/alive"; cp "$FX/rcsupervisor_fatal_20261103.txt" "$T/sup.log"
CHAINWATCH_IDLE_PIDS="101 103" run
check "pane 에 무언가 돌고 있으면 손대지 않는다"   '[ ! -s "$T/tmux.calls" ] && grep -q "무언가 돌고 있다" "$T/notify.calls"'
fresh; hb 4427 10 0 0 ended; : > "$T/alive"; cp "$FX/rcsupervisor_fatal_20261103.txt" "$T/sup.log"
echo "autorestart_supervisor_day=$(date +%Y%m%d):3" > "$ST"; run
check "하루 상한(3)에 닿으면 안 한다"              '[ ! -s "$T/tmux.calls" ] && grep -q "하루\\|오늘 자동 재기동" "$T/notify.calls"'
fresh; hb 4427 10 0 0 ended; : > "$T/alive"; cp "$FX/rcsupervisor_fatal_20261103.txt" "$T/sup.log"
printf 'chain_sup_autorestart = 0\n' >> "$P"; run; sed -i '/chain_sup_autorestart/d' "$P"
check "chain_sup_autorestart = 0 이면 알림만"      '[ ! -s "$T/tmux.calls" ] && grep -q " supervisor_down --" "$T/notify.calls"'
fresh; hb 4427 10 0 0 ended; : > "$T/alive"; cp "$FX/rcsupervisor_fatal_20261103.txt" "$T/sup.log"; rm -f "$T/tmux_has"; run
check "tmux 세션이 없으면 supervisor_down 아님"    '! grep -q " supervisor_down --" "$T/notify.calls"'

echo "[D4] chain_down -> postrun · dataflow pane 재기동"
fresh; hb 4432 600 6000 6000; : > "$T/ps.txt"; run
check "1 회차 (연속 1/2) : 알림·재기동 없음"       '[ ! -s "$T/tmux.calls" ] && ! grep -q " chain_down --" "$T/notify.calls"'
run
check "2 회차 : postrun pane(%3) 재기동"           'grep -qx -- "-t %3 -l CMD-postrun --follow" "$T/tmux.calls"'
check "2 회차 : dataflow pane(%4) 재기동"          'grep -qx -- "-t %4 -l CMD-dataflow --follow" "$T/tmux.calls"'
check "알림에 재기동 결과"                         'grep " chain_down --" "$T/notify.calls" | grep -q "자동 재기동 : postrun 를 pane(%3)"'
: > "$T/notify.calls"; : > "$T/tmux.calls"
"$CW" --params "$P" --gate on --heartbeat "$HB" --state "$ST" --log "$LOG" --dbfile /nonexistent.db --notify "$T/bin/notify" --realert-min 0 >/dev/null 2>&1
check "한 시간 안에는 다시 띄우지 않는다"          '[ ! -s "$T/tmux.calls" ] && grep -q "시간당 1 회" "$T/notify.calls"'
fresh; hb 4432 600 6000 6000; : > "$T/ps.txt"; rm -f "$T/mounted"; run; run
check "/scratch 가 빠지면 postrun 은 띄우지 않는다" '! grep -q -- "-t %3" "$T/tmux.calls"'
check "사유에 10.0.0.11 프로파일 요청 문구"        'grep " chain_down --" "$T/notify.calls" | grep -q "10.0.0.11 로 잘못 설정된 이더넷"'
fresh; hb 4432 600 6000 6000; echo "90211 bash /x/scripts/postrun.sh --follow" > "$T/ps.txt"; run; run
check "postrun 은 살아 있으면 dataflow 만"         'grep -q -- "-t %4 -l" "$T/tmux.calls" && ! grep -q -- "-t %3" "$T/tmux.calls"'
fresh; hb 4432 600 6000 6000; : > "$T/ps.txt"; run; CHAINWATCH_IDLE_PIDS="" run
check "pane 이 바쁘면 손대지 않는다"               '[ ! -s "$T/tmux.calls" ]'
fresh; hb 4432 600 6000 6000; : > "$T/ps.txt"; run; run --dry-run
check "--dry-run 은 send-keys 없음"                '[ ! -s "$T/tmux.calls" ]'

echo "[S] --status 는 읽기 전용"
fresh; hb 4427 10 0 0 ended; : > "$T/alive"; cp "$FX/rcsupervisor_fatal_20261103.txt" "$T/sup.log"
before=$(cat "$ST" 2>/dev/null | md5sum)
out=$("$CW" --params "$P" --status --heartbeat "$HB" --state "$ST" --log "$LOG" 2>&1)
check "FATAL 을 보인다"                            'printf "%s" "$out" | grep -q "FATAL 로 끝났다"'
check "디스크 줄"                                  'printf "%s" "$out" | grep -q "$T/ssd 여유 3000 GB"'
check "상태 파일 그대로 · send-keys 없음"          '[ "$(cat "$ST" 2>/dev/null | md5sum)" = "$before" ] && [ ! -s "$T/tmux.calls" ]'

echo "[C] cron 환경 (env -i)"
fresh; hb 4432 600 6000 6000; : > "$T/ps.txt"; run
env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$T" CHAINWATCH_LOCK=$T/.lock CHAINWATCH_TMUX=$T/bin/tmux \
   CHAINWATCH_PGREP=$T/bin/pgrep CHAINWATCH_KILL=$T/bin/kill CHAINWATCH_MOUNTPOINT=$T/bin/mountpoint \
   CHAINWATCH_PS=$T/ps.txt CHAINWATCH_DF_FILE=$T/df.txt CHAINWATCH_SUPLOG=$T/sup.log CHAINWATCH_PROC=$T/proc \
   CHAINWATCH_DAQTMUX=$T/bin/daqtmux CHAINWATCH_RCTERM_PARAMS=$T/rcterm.params CHAINWATCH_IDLE_PIDS="103 105" \
   bash "$CW" --params "$P" --gate on --heartbeat "$HB" --state "$ST" --log "$LOG" --dbfile /nonexistent.db \
   --notify "$T/bin/notify" >/dev/null 2>&1; rc=$?
check "rc 0"                                       '[ "$rc" = 0 ]'
check "env -i 에서도 재기동"                       'grep -q -- "-t %3 -l CMD-postrun" "$T/tmux.calls"'

echo "[R1] 사람이 프롬프트에 쳐 둔 글자가 있으면 손대지 않는다 (가짜 화면)"
fresh; hb 4432 600 6000 6000; : > "$T/ps.txt"; printf '[frontend@rocky9 RENE-daq-rcterm]$ ran.txt\n' > "$T/capture"; run; run
check "send-keys 없음"                             '[ ! -s "$T/tmux.calls" ]'
check "사유에 친 글자"                             'grep " chain_down --" "$T/notify.calls" | grep -q "ran.txt"'
printf '[frontend@rocky9 RENE-daq-rcterm]$ \n' > "$T/capture"

echo "[R3a] 멈춤 파일이 있으면 D-3 · D-4 재기동 안 함 (알림은 그대로)"
fresh; hb 4427 10 0 0 ended; : > "$T/alive"; cp "$FX/rcsupervisor_fatal_20261103.txt" "$T/sup.log"; touch "$T/hold"; run
check "D-3 : 재기동 없음 · 알림 있음"              '[ ! -s "$T/tmux.calls" ] && grep -q " supervisor_down --" "$T/notify.calls"'
check "사유에 멈춤 파일"                           'grep -q "멈춤 파일이 있다" "$T/notify.calls"'
fresh; hb 4432 600 6000 6000; : > "$T/ps.txt"; touch "$T/hold"; run; run
check "D-4 : 재기동 없음 · chain_down 알림"         '[ ! -s "$T/tmux.calls" ] && grep -q " chain_down --" "$T/notify.calls"'
out=$("$CW" --params "$P" --status --heartbeat "$HB" --state "$ST" --log "$LOG" 2>&1)
check "--status 에 멈춤 파일"                      'printf "%s" "$out" | grep -q "멈춤 파일"'
rm -f "$T/hold"

echo "[R3b] FATAL 30 분 안에는 다시 띄우지 않는다"
fresh; hb 4427 10 0 0 ended; : > "$T/alive"
printf '%s [SUP] FATAL too many consecutive failures; giving up. please inspect the DAQ logs\n' "$(date -d '-10 min' '+%F %T')" > "$T/sup.log"; run
check "알림은 즉시"                                'grep -q " supervisor_down --" "$T/notify.calls"'
check "재기동 없음 (10 분)"                        '[ ! -s "$T/tmux.calls" ] && grep -q "30분이 지나야" "$T/notify.calls"'
printf '%s [SUP] FATAL too many consecutive failures; giving up. please inspect the DAQ logs\n' "$(date -d '-31 min' '+%F %T')" > "$T/sup.log"; run
check "31 분이면 재기동"                           'grep -qx -- "-t %2 -l CMD-supervisor --follow" "$T/tmux.calls"'

echo "[R3c] stop 줄 없이 사라진 감시자 (OOM · kill -9) 도 같은 규칙으로"
fresh; hb 4372 10 0 0 ended; : > "$T/alive"; head -8 "$FX/rcsupervisor_stop_20261105.txt" > "$T/sup.log"; run
check "supervisor_down 알림 (사라짐)"              'grep " supervisor_down --" "$T/notify.calls" | grep -q "stop. 줄 없이 사라졌다"'
check "재기동 (마지막 줄이 30 분 넘게 지났다)"      'grep -qx -- "-t %2 -l CMD-supervisor --follow" "$T/tmux.calls"'
fresh; hb 4372 10 0 0 ended; : > "$T/alive"; printf '%s [SUP] health OK  run=4372 sub=512 state=Running\n' "$(date -d '-5 min' '+%F %T')" > "$T/sup.log"; run
check "사라진 지 5 분이면 재기동 안 함"            '[ ! -s "$T/tmux.calls" ]'
fresh; hb 4432 10 0 0 ended; : > "$T/alive"; head -9 "$FX/rcsupervisor_stop_20261105.txt" > "$T/sup.log"; run
check "'stop requested' 뒤에 죽었으면 사람이 세운 것 (조용)" '[ ! -s "$T/notify.calls" ] && [ ! -s "$T/tmux.calls" ]'

echo "[R3d] 정전·재부팅 : 감시자가 이번 부팅 전에 끝났으면 알림만 (리뷰어 재현 입력)"
fresh; hb 4416 10 0 0 ended; : > "$T/alive"
printf '2026-11-01 14:39:02 [SUP] health OK  run=4416 sub=789 state=Running totev=17000000\n' > "$T/sup.log"
CHAINWATCH_BTIME=$(date -d '2026-11-02 00:02:07' +%s) run
check "supervisor_down 알림은 간다"                 'grep -q " supervisor_down --" "$T/notify.calls"'
check "재기동 안 함 (맨 프롬프트 · hold 없음인데도)" '[ ! -s "$T/tmux.calls" ] && [ ! -e "$T/hold" ]'
check "사유에 이번 부팅 전"                         'grep -q "이번 부팅(2026-11-02 00:02:07) 전에 끝났다" "$T/notify.calls"'
fresh; hb 4427 10 0 0 ended; : > "$T/alive"; cp "$FX/rcsupervisor_fatal_20261103.txt" "$T/sup.log"
CHAINWATCH_BTIME=$(date -d '2026-11-04 00:00:00' +%s) run
check "FATAL 도 부팅 전이면 재기동 안 함"           '[ ! -s "$T/tmux.calls" ]'
fresh; hb 4427 10 0 0 ended; : > "$T/alive"; cp "$FX/rcsupervisor_fatal_20261103.txt" "$T/sup.log"
CHAINWATCH_BTIME=$(date -d '2026-11-01 00:00:00' +%s) run
check "부팅 뒤에 끝난 FATAL 은 재기동"              'grep -qx -- "-t %2 -l CMD-supervisor --follow" "$T/tmux.calls"'

echo "[R4] 감시자 대기(standby) : <heartbeat>.sup 기준, 없으면 rcterm.hb 의 phase=standby"
fresh; hb 4433 6000 40000 40000; : > "$T/alive"; cp "$FX/rcsupervisor_fatal_20261103.txt" "$T/sup.log"
printf 'time=%s\npid=4242\nphase=standby\nstandby=hardware\nrun=4433\n' "$(date +%s)" > "$HB.sup"; run
check ".sup standby : supervisor_down 아님"        '! grep -q " supervisor_down --" "$T/notify.calls" && [ ! -s "$T/tmux.calls" ]'
check ".sup standby : 계수율 판정 안 함 (sr 40 k 인데 rate_high 없음)" '! grep -q " rate_high --" "$T/notify.calls"'
out=$("$CW" --params "$P" --status --heartbeat "$HB" --state "$ST" --log "$LOG" 2>&1)
check "--status 에 대기 · 사유"                    'printf "%s" "$out" | grep -q "대기 (standby=hardware run=4433"'
printf 'time=%s\npid=4242\nphase=standby\nstandby=rate\nrun=4433\n' "$(( $(date +%s) - 3600 ))" > "$HB.sup"; run
check "오래된 .sup 는 믿지 않는다 -> supervisor_down" 'grep -q " supervisor_down --" "$T/notify.calls"'
rm -f "$HB.sup"; fresh; hb 4433 6000 40000 40000 standby; : > "$T/alive"; cp "$FX/rcsupervisor_fatal_20261103.txt" "$T/sup.log"; run
check ".sup 가 없으면 rcterm.hb phase=standby 를 받는다" '! grep -q " supervisor_down --" "$T/notify.calls" && ! grep -q " rate_high --" "$T/notify.calls"'

echo "[R6] /scratch 가 빠져도 dataflow 는 띄운다 (postrun 은 안 띄운다)"
fresh; hb 4432 600 6000 6000; : > "$T/ps.txt"; rm -f "$T/mounted"; run; run
check "dataflow 재기동"                           'grep -qx -- "-t %4 -l CMD-dataflow --follow" "$T/tmux.calls"'
check "postrun 은 없음"                           '! grep -q -- "-t %3" "$T/tmux.calls"'

echo; echo "PASS $PASS  FAIL $FAIL"
[ "$FAIL" -eq 0 ]
