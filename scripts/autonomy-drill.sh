#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  autonomy-drill.sh - 자율 복구 드릴. 일부러 고장을 내고, 시스템이 사람 없이 되살아나는지 본다.
#
#  사용 :
#     autonomy-drill.sh --plan offline-full --confirm-test-run [--with-power] [--log DIR]
#     autonomy-drill.sh --plan quick        --confirm-test-run [--with-power] [--log DIR]
#     autonomy-drill.sh --plan <이름> --dry-run      계획과 전제 점검만. 주입 0 회
#
#  왜 (2026-11-05 사용자 요청, 감사 §8 의 주입 표)
#     "점검이 끝나면 실제로 네트워크를 끄고 에러를 일으켜 제대로 복구하고 정상 수집하는지 시험".
#     바깥 망을 끊으면 Claude 세션도 끊긴다. 그래서 드릴은 이 PC 에서 혼자 돌며 결과를
#     로컬(/Data_ssd/LOG/autonomy-drill/<시각>/) 에 남기고, 망이 돌아온 뒤 사람·Claude 가 읽는다.
#     절차와 기대값은 docs/AUTONOMY-DRILL.md.
#
#  단계 (offline-full ; quick 은 2·3·9 를 뺀다)
#     0  전제     수집 중(phase=running, heartbeat 신선) · 감시자 · chainwatch cron · netsync ·
#                 멈춤 파일 없음 · /Data_ssd 여유 >= 500 G · 다른 드릴 없음.  하나라도 아니면 주입 0 으로 끝
#     1  기준선   런 · 서브런 · 계수율 · 감시자 pid · 로그 위치 · 메일 큐 수
#     2  [사람]   바깥 망을 끊는다 -> netsync 가 net=down 을 적을 때까지 (기본 15 분)
#     3  메일     chainwatch 를 한 번 돌리고, 알림이 /Data_ssd/LOG/MAILQ 에 쌓이는지
#     4  daq 종료 daq 하나에 TERM -> 감시자 restart -> 새 런 running + DRAM 8/8
#     5  stale    rcterm 에 STOP -> 감시자가 heartbeat stale 로 잡아 재시작 -> 새 런 (뒤에 CONT 로 안전 마감)
#     6  postrun  postrun 셸에 TERM -> chainwatch chain_down -> pane 자동 재기동
#     7  SIGUSR1  감시자에 USR1 (SigCgt 로 지원 확인) -> 지금 런 정상 마감 -> 새 런
#     8  전원     기본 : usb-recover.sh --force-power-cycle --dry-run (게이트 확인, 하드웨어 0)
#                 --with-power : 감시자 TERM -> usb-recover --force-power-cycle 실물 1 회 -> 감시자 재기동
#     9  [사람]   바깥 망을 되살린다 -> net=up -> 메일 큐 0 · 시트 밀린 완결 런 0
#     10 요약     result.tsv + report.md
#
#  안전
#     - 4~8 은 --confirm-test-run 이 있을 때만 (시험 런을 깨뜨린다). 없으면 SKIP
#     - 매 주입 전에 heartbeat 를 다시 읽고 phase=running 이 아니면 남은 주입을 모두 건너뛴다
#     - kill 은 PID 로만 (pgrep -x · ps 계보). pgrep -f 는 쓰지 않는다
#     - 전원은 --with-power 없이는 절대 하지 않는다
#     - 멈춤 파일(chainwatch.hold)을 만들지 않는다 -- 자동 재기동을 시험하는 것이므로.
#       대신 <루트>/RUNNING 표식으로 두 드릴이 겹치지 않게 한다
#     - STOP 을 건 프로세스는 끝날 때(정상·중단 모두) CONT 를 보낸다
#     - --dry-run 은 kill · tmux · chainwatch · usb-recover 를 하나도 부르지 않는다
#
#  종료코드  0 전부 PASS/SKIP   1 FAIL 이나 중단이 있었다   2 사용법 오류
#  시험      DRILL_TEST_HOOK 에 적은 파일을 source 해 바깥 명령을 갈아끼운다 (tests/autonomy-drill.test.sh)
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)

HB=${DRILL_HB:-/Data/LOG/rcterm.hb}
SUPLOG=${DRILL_SUPLOG:-/Data/LOG/rcsupervisor.log}
CWLOG=${DRILL_CWLOG:-/Data_ssd/LOG/chainwatch.log}
NSSTATE=${DRILL_NSSTATE:-/Data_ssd/LOG/netsync.state}
NSLOG=${DRILL_NSLOG:-/Data_ssd/LOG/netsync.log}
DBFILE=${DRILL_DBFILE:-/Data_ssd/runcatalog.db}
HOLD=${DRILL_HOLD:-/Data_ssd/LOG/chainwatch.hold}
LOCALQ=${DRILL_LOCALQ:-/Data_ssd/LOG/MAILQ}
NFSQ=${DRILL_NFSQ:-/scratch/MAILQ}
DAQLOG=${DRILL_DAQLOG:-/Data_ssd/LOG}
ROOT=${DRILL_ROOT:-/Data_ssd/LOG/autonomy-drill}
SSD=${DRILL_SSD:-/Data_ssd}
NFS=${DRILL_NFS:-/scratch}
CHAINWATCH=${DRILL_CHAINWATCH:-$DIR/scripts/chainwatch.sh}
NETSYNC=${DRILL_NETSYNC:-$DIR/scripts/netsync.sh}
USBRECOVER=${DRILL_USBRECOVER:-$DIR/scripts/usb-recover.sh}
SHEETLOG=${DRILL_SHEETLOG:-$DIR/scripts/sheetlog-auto.sh}
DAQTMUX=${DRILL_DAQTMUX:-$DIR/scripts/daq-tmux.sh}
SESSION=${DRILL_SESSION:-daq}
MINFREE_GB=${DRILL_MINFREE_GB:-500}
HB_FRESH=${DRILL_HB_FRESH:-120}
NS_FRESH=${DRILL_NS_FRESH:-900}
DRAM_LINES=${DRILL_DRAM_LINES:-8}
POLL=${DRILL_POLL:-10}
T_NETDOWN=${DRILL_T_NETDOWN:-900}
T_MAILQ=${DRILL_T_MAILQ:-600}
T_KILL=${DRILL_T_KILL:-900}
T_STALE=${DRILL_T_STALE:-}          # 비우면 감시자 로그의 check+stale+900
T_POSTRUN=${DRILL_T_POSTRUN:-1500}
T_POSTRUN_EXIT=${DRILL_T_POSTRUN_EXIT:-300}
T_USR1=${DRILL_T_USR1:-900}
T_POWER=${DRILL_T_POWER:-2400}
T_NETUP=${DRILL_T_NETUP:-1800}
T_FLUSH=${DRILL_T_FLUSH:-900}
T_SHEET=${DRILL_T_SHEET:-1500}       # netsync flush 의 sheetlog-auto --force 는 최대 1200 s
PROMPT_RE=${DRILL_PROMPT_RE:-'[$#] ?$'}

PLAN=""; DRY=0; CONFIRM=0; POWER=0; LOGDIR=""
usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
   case "$1" in
      --plan)             PLAN=${2:-}; shift 2 ;;
      --dry-run)          DRY=1; shift ;;
      --confirm-test-run) CONFIRM=1; shift ;;
      --with-power)       POWER=1; shift ;;
      --log)              LOGDIR=${2:-}; shift 2 ;;
      -h|--help)          usage; exit 0 ;;
      *) echo "모르는 인자 : $1" >&2; exit 2 ;;
   esac
done
case "$PLAN" in
   offline-full) STEPS="0 1 2 3 4 5 6 7 8 9" ;;
   quick)        STEPS="0 1 4 5 6 7 8" ;;
   *) echo "--plan offline-full | quick 이 필요하다" >&2; exit 2 ;;
esac

# ---- 바깥 세상과 닿는 곳. 시험은 DRILL_TEST_HOOK 으로 전부 갈아끼운다 ----
now_s()      { date +%s; }
sleep_s()    { sleep "$1"; }
pid_of()     { pgrep -x "$1" 2>/dev/null; }                   # ★ -x 만. -f 금지
ps_lines()   { ps -eo pid=,ppid=,args= 2>/dev/null; }
send_sig()   { kill -s "$1" "$2" 2>/dev/null; }
pid_alive()  { kill -0 "$1" 2>/dev/null; }
sigcgt_of()  { sed -n 's/^SigCgt:[[:space:]]*//p' "/proc/$1/status" 2>/dev/null; }
crontab_l()  { crontab -l 2>/dev/null; }
df_avail_gb(){ df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }
is_mounted() { mountpoint -q "$1" 2>/dev/null; }
run_chainwatch() { bash "$CHAINWATCH" >/dev/null 2>&1; }
run_usbrecover() { bash "$USBRECOVER" "$@"; }
run_sheetstatus(){ bash "$SHEETLOG" --status 2>/dev/null; }
print_cmd()      { bash "$DAQTMUX" --print-cmd "$1" 2>/dev/null; }
tmux_c()         { tmux "$@"; }
if [ -n "${DRILL_TEST_HOOK:-}" ]; then
   [ -r "$DRILL_TEST_HOOK" ] || { echo "DRILL_TEST_HOOK 을 읽을 수 없다 : $DRILL_TEST_HOOK" >&2; exit 2; }
   # shellcheck source=/dev/null
   . "$DRILL_TEST_HOOK"
fi

# ---- 기록 ----------------------------------------------------------------
START=$(now_s)
[ -n "$LOGDIR" ] || LOGDIR="$ROOT/$(date -d "@$START" +%Y%m%d-%H%M%S 2>/dev/null || date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR" 2>/dev/null || { echo "로그 폴더를 만들 수 없다 : $LOGDIR" >&2; exit 2; }
DLOG=$LOGDIR/drill.log; RES=$LOGDIR/result.tsv
printf 'step\tname\tinjected\texpected\tobserved\tverdict\tevidence\n' > "$RES"
ts()   { date -d "@$(now_s)" '+%F %T' 2>/dev/null || date '+%F %T'; }
log()  { printf '%s %s\n' "$(ts)" "$*" | tee -a "$DLOG"; }
clean(){ printf '%s' "$*" | tr '\t\n' '  ' | cut -c1-300; }
NFAIL=0; ABORTED=""
record() {               # $1=단계 $2=이름 $3=주입시각 $4=기대 $5=관측 $6=판정 $7=근거
   printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(clean "$4")" "$(clean "$5")" "$6" "$(clean "$7")" >> "$RES"
   [ "$6" = FAIL ] && NFAIL=$(( NFAIL + 1 ))
   log "[$6] 단계 $1 $2 -- $5"
}
banner() { log "=================================================================="; log "$*"; log "=================================================================="; }

# ---- 읽기 도우미 -----------------------------------------------------------
hbf()     { sed -n "s/^$1=//p" "$HB" 2>/dev/null | head -1; }
hb_fresh(){ local t; t=$(hbf time); case "$t" in ''|*[!0-9]*) return 1 ;; esac; [ $(( $(now_s) - t )) -le "$HB_FRESH" ]; }
hb_running() { [ "$(hbf phase)" = running ] && hb_fresh; }
hb_run()  { local r; r=$(hbf run); case "$r" in ''|*[!0-9]*) echo 0 ;; *) echo "$r" ;; esac; }
first_pid() { pid_of "$1" | head -1; }
fsize()   { stat -c %s "$1" 2>/dev/null || echo 0; }
since()   { local f=$1 off=$2; [ -r "$f" ] && tail -c +$(( off + 1 )) "$f" 2>/dev/null; }
qcount()  { local n=0 f; for f in "$1"/*.mail; do [ -e "$f" ] && n=$(( n + 1 )); done; echo "$n"; }
ns_get()  { sed -n "s/^$1=//p" "$NSSTATE" 2>/dev/null | head -1; }
ns_net()  {              # 신선한 net= 값. 오래됐거나 없으면 빈 문자열
   local c; c=$(ns_get checked); case "$c" in ''|*[!0-9]*) return 0 ;; esac
   [ $(( $(now_s) - c )) -le "$NS_FRESH" ] && ns_get net
}
dram_ok() {              # $1=런 -> 'is aligned N / Fail M' 을 찍고, N >= 기대 이고 M = 0 이면 0
   local f a b; f=$(printf '%s/TCB_%06d.log' "$DAQLOG" "$1")
   [ -r "$f" ] || { echo "TCB 로그 없음 ($f)"; return 1; }
   a=$(grep -c 'is aligned' "$f" 2>/dev/null); b=$(grep -c 'Fail to align' "$f" 2>/dev/null)
   echo "TCB_$(printf '%06d' "$1") is aligned ${a:-0} / Fail to align ${b:-0}"
   [ "${a:-0}" -ge "$DRAM_LINES" ] && [ "${b:-0}" -eq 0 ]
}
#  postrun --follow 의 맨 위 셸. 같은 인자를 가진 하위 셸(병렬 잡)은 부모도 postrun 이라 뺀다.
postrun_pid() {
   ps_lines | awk -v me="$$" '
      { pid[NR] = $1; pp[NR] = $2; $1 = ""; $2 = ""; a[NR] = $0 }
      END {
         for (i = 1; i <= NR; i++) if (a[i] ~ /scripts\/postrun\.sh/ && a[i] ~ /--follow/ && pid[i] != me) m[pid[i]] = 1
         for (i = 1; i <= NR; i++) if ((pid[i] in m) && !(pp[i] in m)) print pid[i]
      }'
}
sup_timing() {           # 감시자 기동 머리줄의 check · stale 초
   local l; l=$(grep -E 'check=[0-9]+ s +stale=[0-9]+ s' "$SUPLOG" 2>/dev/null | tail -1)
   SUP_CHECK=$(printf '%s' "$l" | sed -n 's/.*check=\([0-9]*\) s.*/\1/p'); SUP_CHECK=${SUP_CHECK:-600}
   SUP_STALE=$(printf '%s' "$l" | sed -n 's/.*stale=\([0-9]*\) s.*/\1/p'); SUP_STALE=${SUP_STALE:-300}
}

hold_new() { [ -e "$HOLD" ] && [ "$HOLD_AT_START" = 0 ]; }
#  조건을 기다린다. $1=초  나머지=조건 명령. 참이면 0, 시간이 다 되면 1
wait_for() {
   local lim=$1 t0; shift; t0=$(now_s)
   while :; do
      #  ★ 멈춤 파일을 조건보다 먼저 본다. 새 런과 멈춤 파일이 같은 회차에 생기면 다음 주입이 나가던 것 (리뷰 재현)
      hold_new && { log "★ 멈춤 파일이 생겼다 ($HOLD) -- 사람이 작업 중. 기다림을 멈춘다"; ABORTED="멈춤 파일"; return 1; }
      "$@" && return 0
      [ $(( $(now_s) - t0 )) -ge "$lim" ] && return 1
      sleep_s "$POLL"
   done
}

# ---- 겹침 방지 · 끝날 때 정리 ----------------------------------------------
MARK=$ROOT/RUNNING; OWN_MARK=0; STOPPED=""
cleanup() {
   local p
   for p in $STOPPED; do pid_alive "$p" && { send_sig CONT "$p"; log "정리 : pid $p 에 CONT (STOP 해 둔 것)"; }; done
   STOPPED=""
   [ "${POWER_DOWN:-0}" = 1 ] && log "★ 수집 멈춤 (전원 단계 도중 끝났다). 손으로 띄울 것 : tmux daq:1.2 에서 ${POWER_CMD:-bash scripts/daq-tmux.sh --print-cmd supervisor 의 명령}"
   [ "$OWN_MARK" = 1 ] && [ "$REPORTED" = 0 ] && type write_report >/dev/null 2>&1 && write_report
   [ "$OWN_MARK" = 1 ] && rm -f "$MARK"
   return 0
}
REPORTED=0
trap cleanup EXIT
trap 'ABORTED="신호를 받았다"; log "★ 드릴이 신호로 중단됐다"; exit 1' INT TERM
if [ "$DRY" -eq 0 ]; then
   mkdir -p "$ROOT" 2>/dev/null
   if [ -e "$MARK" ]; then
      op=$(sed -n 's/^pid=//p' "$MARK" 2>/dev/null | head -1)
      if [ -n "$op" ] && pid_alive "$op"; then
         log "★ 다른 드릴이 돌고 있다 (pid $op, $MARK). 아무것도 하지 않는다"
         record 0 겹침 - "다른 드릴 없음" "pid $op 가 RUNNING 을 쥐고 있다" FAIL "$MARK"; exit 1
      fi
      log "옛 표식을 지운다 (pid ${op:-?} 는 이미 없다) : $MARK"; rm -f "$MARK"
   fi
   if ( set -o noclobber; printf 'pid=%s\nstart=%s\nplan=%s\nlog=%s\n' "$$" "$START" "$PLAN" "$LOGDIR" > "$MARK" ) 2>/dev/null; then
      OWN_MARK=1
   else
      log "★ 표식을 만들 수 없다 ($MARK) -- 겹침을 막을 수 없으니 시작하지 않는다"; exit 1
   fi
fi
HOLD_AT_START=0; [ -e "$HOLD" ] && HOLD_AT_START=1

banner "자율 복구 드릴  plan=$PLAN  dry-run=$DRY  시험런확인=$CONFIRM  전원=$POWER  로그=$LOGDIR"

# =====================================================================
#  0 — 전제
# =====================================================================
s0() {
   local why="" sp av ct
   hb_running || why="$why; heartbeat phase=$(hbf phase) (running 이고 ${HB_FRESH} s 안이어야)"
   sp=$(first_pid rcsupervisor); [ -n "$sp" ] || why="$why; 감시자(rcsupervisor) 없음"
   ct=$(crontab_l)
   printf '%s\n' "$ct" | grep -q '^[^#]*scripts/chainwatch\.sh' || why="$why; chainwatch cron 없음"
   if [ "$PLAN" = offline-full ]; then
      [ -r "$NETSYNC" ] || why="$why; netsync.sh 없음 ($NETSYNC)"
      printf '%s\n' "$ct" | grep -q '^[^#]*scripts/netsync\.sh' || why="$why; netsync cron 없음"
   fi
   [ "$HOLD_AT_START" = 0 ] || why="$why; 멈춤 파일 있음 ($HOLD)"
   av=$(df_avail_gb "$SSD"); av=${av:-0}
   [ "$av" -ge "$MINFREE_GB" ] || why="$why; $SSD 여유 ${av} G < ${MINFREE_GB} G"
   [ "$CONFIRM" = 1 ] || [ "$PLAN" = offline-full ] || why="$why; quick 은 --confirm-test-run 이 있어야 할 일이 있다"
   PRE="run=$(hb_run) phase=$(hbf phase) 감시자=${sp:-없음} $SSD 여유=${av}G"
   if [ -n "$why" ]; then record 0 전제 - "전부 충족" "${why#; }" FAIL "$PRE"; return 1; fi
   record 0 전제 - "전부 충족" "충족" PASS "$PRE"; return 0
}

# =====================================================================
#  1 — 기준선
# =====================================================================
s1() {
   B_RUN=$(hb_run); B_SUB=$(hbf subrun); B_SUP=$(first_pid rcsupervisor)
   B_SUPOFF=$(fsize "$SUPLOG"); B_CWOFF=$(fsize "$CWLOG")
   B_LQ=$(qcount "$LOCALQ"); B_NQ=$(qcount "$NFSQ")
   B_RATES=$(grep '^daq[0-9]*=' "$HB" 2>/dev/null | tr '\n' ' ')
   { echo "start=$START"; echo "run=$B_RUN"; echo "subrun=$B_SUB"; echo "supervisor=$B_SUP"
     echo "suplog_off=$B_SUPOFF"; echo "cwlog_off=$B_CWOFF"; echo "localq=$B_LQ"; echo "nfsq=$B_NQ"
     echo "net=$(ns_get net)"; echo "rates=$B_RATES"; } > "$LOGDIR/baseline.txt"
   record 1 기준선 - "읽힘" "run $B_RUN sub ${B_SUB:-?} 큐 local=$B_LQ nfs=$B_NQ net=$(ns_get net)" PASS "$LOGDIR/baseline.txt"
}

# =====================================================================
#  2 — [사람] 바깥 망 차단
# =====================================================================
NETWENT=0
s2() {
   local t; t=$(ts)
   banner "★ 사람 차례 : 지금 바깥 망을 끊어라 (root, 콘솔에서).  예) sudo nmcli connection down enp0s31f6  또는 벽 쪽 랜 케이블(enp0s31f6)을 뽑는다 (★ daq_gateway 아님)
   (원격 세션은 여기서 끊긴다. 드릴은 혼자 계속 돈다.)  netsync 가 net=down 을 적을 때까지 최대 ${T_NETDOWN} s 기다린다"
   if wait_for "$T_NETDOWN" ns_is_down; then
      NETWENT=1; record 2 망차단 "$t" "netsync net=down" "down (since=$(ns_get since))" PASS "$NSSTATE checked=$(ns_get checked)"
   else
      NETWENT=1   # 사람이 끊었을 수는 있다. 9 단계 안내는 그대로 한다
      record 2 망차단 "$t" "netsync net=down (${T_NETDOWN} s 안)" "net=$(ns_get net) checked=$(ns_get checked)" FAIL "$NSSTATE"
   fi
}
ns_is_down() { [ "$(ns_net)" = down ]; }
ns_is_up()   { [ "$(ns_net)" = up ]; }

# =====================================================================
#  3 — 메일이 로컬 큐에 쌓인다
# =====================================================================
s3() {
   local t; t=$(ts)
   if [ "$(ns_net)" != down ]; then record 3 메일큐 - "net=down 에서 로컬 큐 적재" "망이 down 이 아니다" SKIP "2 단계 결과를 볼 것"; return; fi
   run_chainwatch
   q_grew() { [ "$(qcount "$LOCALQ")" -gt "$B_LQ" ]; }
   if wait_for "$T_MAILQ" q_grew; then
      record 3 메일큐 "$t" "$LOCALQ 에 새 .mail" "$B_LQ -> $(qcount "$LOCALQ") 통" PASS "$(ls -1t "$LOCALQ"/*.mail 2>/dev/null | head -1)"
   else
      record 3 메일큐 "$t" "$LOCALQ 에 새 .mail (${T_MAILQ} s 안)" "그대로 $(qcount "$LOCALQ") 통" FAIL "daq-notify.log · netsync.log 를 볼 것"
   fi
}

# ---- 4~8 공통 : 주입 전 점검 ------------------------------------------------
guard() {                # $1=단계 $2=이름.  주입해도 되면 0
   if [ "$CONFIRM" != 1 ]; then record "$1" "$2" - "시험 런에서만" "--confirm-test-run 없음" SKIP ""; return 1; fi
   if [ -n "$ABORTED" ]; then record "$1" "$2" - "-" "중단 : $ABORTED" SKIP ""; return 1; fi
   if [ "$DRY" -eq 1 ]; then return 1; fi
   if hold_new; then
      ABORTED="멈춤 파일 ($HOLD) -- 사람이 작업 중"
      record "$1" "$2" - "-" "중단 : $ABORTED" SKIP "$HOLD"; return 1
   fi
   if ! hb_running; then
      ABORTED="주입 전 phase=$(hbf phase), heartbeat 나이 $(( $(now_s) - $(hbf time | tr -dc 0-9 | grep . || echo 0) )) s (running 이고 ${HB_FRESH} s 안이어야)"
      record "$1" "$2" - "주입 전 phase=running" "$ABORTED" FAIL "$HB"; return 1
   fi
   return 0
}
new_run_up() {           # 기준 런($R0) 보다 큰 런이 running 이고 DRAM 이 맞았는가
   local r; r=$(hb_run)
   [ "$r" -gt "$R0" ] && hb_running || return 1
   DRAM_MSG=$(dram_ok "$r") || return 1
   NEWRUN=$r; return 0
}
sup_has() { since "$SUPLOG" "$SOFF" | grep -E "$1" | head -1; }

# =====================================================================
#  4 — daq 하나에 TERM
# =====================================================================
s4() {
   local t p ev
   guard 4 daq종료 || return
   R0=$(hb_run); SOFF=$(fsize "$SUPLOG"); p=$(first_pid daq)
   [ -n "$p" ] || { record 4 daq종료 - "daq 프로세스" "pgrep -x daq 가 없다" FAIL ""; return; }
   t=$(ts); log "주입 : daq pid $p 에 TERM (run $R0)"; send_sig TERM "$p"
   if wait_for "$T_KILL" new_run_up; then
      ev=$(sup_has 'restart #')
      if [ -n "$ev" ]; then record 4 daq종료 "$t" "restart -> 새 런 running + DRAM ${DRAM_LINES}" "run $R0 -> $NEWRUN, $DRAM_MSG" PASS "$ev"
      else record 4 daq종료 "$t" "감시자 로그 'restart #'" "새 런 $NEWRUN 은 떴으나 restart 줄이 없다" FAIL "$SUPLOG"; fi
   else
      record 4 daq종료 "$t" "새 런 running + DRAM (${T_KILL} s 안)" "run=$(hb_run) phase=$(hbf phase) ${DRAM_MSG:-}" FAIL "$(sup_has 'restart #|UNHEALTHY|standby|FATAL')"
   fi
}

# =====================================================================
#  5 — rcterm 에 STOP (heartbeat 가 멎는다)
# =====================================================================
s5() {
   local t p ev lim
   guard 5 stale || return
   sup_timing; lim=${T_STALE:-$(( SUP_CHECK + SUP_STALE + 900 ))}
   R0=$(hb_run); SOFF=$(fsize "$SUPLOG"); p=$(first_pid rcterm)
   [ -n "$p" ] || { record 5 stale - "rcterm 프로세스" "pgrep -x rcterm 가 없다" FAIL ""; return; }
   t=$(ts); log "주입 : rcterm pid $p 에 STOP (run $R0). 감시자 check=${SUP_CHECK} s stale=${SUP_STALE} s -> 최대 ${lim} s 기다린다"
   STOPPED="$STOPPED $p"; send_sig STOP "$p"
   if wait_for "$lim" new_run_up; then
      ev=$(sup_has 'heartbeat stale')
      if [ -n "$ev" ]; then record 5 stale "$t" "heartbeat stale -> 재시작 -> 새 런" "run $R0 -> $NEWRUN, $DRAM_MSG" PASS "$ev"
      else record 5 stale "$t" "감시자 로그 'stale'" "새 런 $NEWRUN 은 떴으나 stale 줄이 없다" FAIL "$(sup_has 'restart #')"; fi
   else
      record 5 stale "$t" "새 런 (${lim} s 안)" "run=$(hb_run) phase=$(hbf phase)" FAIL "$(sup_has 'heartbeat stale|restart #|standby|FATAL')"
   fi
   pid_alive "$p" && { send_sig CONT "$p"; log "rcterm pid $p 가 아직 있어 CONT 를 보냈다"; }
   STOPPED=$(printf '%s\n' $STOPPED | grep -vx "$p" | tr '\n' ' ')
}

# =====================================================================
#  6 — postrun 셸에 TERM
# =====================================================================
s6() {
   local t p n ev pid2
   guard 6 postrun || return
   if ! is_mounted "$NFS"; then record 6 postrun - "chain_down -> pane 재기동" "$NFS 미마운트 (chainwatch 가 postrun 을 안 띄운다)" SKIP ""; return; fi
   p=$(postrun_pid); n=$(printf '%s\n' "$p" | grep -c .)
   [ "$n" = 1 ] || { record 6 postrun - "postrun --follow 하나" "${n} 개 (${p//$'\n'/ })" FAIL "ps"; return; }
   COFF=$(fsize "$CWLOG"); t=$(ts); log "주입 : postrun 셸 pid $p 에 TERM (진행 중인 merge 를 끝내고 빠진다)"
   send_sig TERM "$p"
   pr_gone() { ! pid_alive "$p"; }
   if ! wait_for "$T_POSTRUN_EXIT" pr_gone; then record 6 postrun "$t" "postrun 종료 (${T_POSTRUN_EXIT} s 안)" "pid $p 가 남아 있다" FAIL ""; return; fi
   pr_back() { pid2=$(postrun_pid | head -1); [ -n "$pid2" ] && [ "$pid2" != "$p" ]; }
   if wait_for "$T_POSTRUN" pr_back; then
      ev=$(since "$CWLOG" "$COFF" | grep '자동 재기동 : postrun' | head -1)
      if [ -n "$ev" ]; then record 6 postrun "$t" "chain_down -> chainwatch 가 pane 재기동" "pid $p -> $pid2" PASS "$ev"
      else record 6 postrun "$t" "chainwatch 의 '자동 재기동 : postrun'" "postrun 은 돌아왔으나(pid $pid2) chainwatch 기록이 없다 -- 사람이 띄웠나?" FAIL "$CWLOG"; fi
   else
      record 6 postrun "$t" "postrun 다시 뜸 (${T_POSTRUN} s 안)" "없음" FAIL "$(since "$CWLOG" "$COFF" | grep -E 'chain_down|postrun' | tail -1)"
   fi
}

# =====================================================================
#  7 — 감시자에 SIGUSR1
# =====================================================================
s7() {
   local t sp m ev
   guard 7 SIGUSR1 || return
   sp=$(first_pid rcsupervisor)
   m=$(sigcgt_of "$sp"); case "$m" in ''|*[!0-9a-fA-F]*) m=0 ;; esac
   if [ $(( 0x$m & 0x200 )) -eq 0 ]; then
      record 7 SIGUSR1 - "감시자가 USR1 을 받는다" "SigCgt=$m -- 옛 감시자(USR1 이면 죽는다). 보내지 않았다" SKIP "/proc/$sp/status"; return
   fi
   R0=$(hb_run); SOFF=$(fsize "$SUPLOG"); t=$(ts); log "주입 : 감시자 pid $sp 에 USR1 (run $R0)"
   send_sig USR1 "$sp"
   if wait_for "$T_USR1" new_run_up; then
      ev=$(sup_has 'SIGUSR1 : ending')
      if [ -n "$ev" ]; then record 7 SIGUSR1 "$t" "정상 마감 -> 새 런" "run $R0 -> $NEWRUN, $DRAM_MSG" PASS "$ev"
      else record 7 SIGUSR1 "$t" "감시자 로그 'SIGUSR1'" "새 런 $NEWRUN 은 떴으나 SIGUSR1 줄이 없다" FAIL "$SUPLOG"; fi
   else
      record 7 SIGUSR1 "$t" "새 런 (${T_USR1} s 안)" "run=$(hb_run) phase=$(hbf phase)" FAIL "$(sup_has 'SIGUSR1|standby|FATAL')"
   fi
}

# =====================================================================
#  8 — 전원 단계
# =====================================================================
type_in_pane() {         # $1=pane 제목 열쇠말 $2=명령.  chainwatch 의 revive_pane 과 같은 조심
   local pp id pid tg last
   pp=$(tmux_c list-panes -s -t "$SESSION" -F '#{pane_id} #{pane_pid} #{pane_title}' 2>/dev/null \
        | awk -v k="$1" 'index(substr($0, length($1) + length($2) + 3), k) { print $1, $2; exit }')
   [ -n "$pp" ] || { PANE_MSG="$1 pane 이 tmux $SESSION 에 없다"; return 1; }
   id=${pp% *}; pid=${pp#* }
   tg=$(ps -o tpgid= -p "$pid" 2>/dev/null | tr -d ' ')
   [ "${DRILL_PANE_IDLE:-}" = 1 ] || [ "$tg" = "$pid" ] || { PANE_MSG="$1 pane($id) 에 무언가 돌고 있다"; return 1; }
   last=$(tmux_c capture-pane -p -t "$id" 2>/dev/null | sed 's/[[:space:]]*$//' | grep -v '^$' | tail -1)
   printf '%s\n' "$last" | grep -Eq "$PROMPT_RE" || { PANE_MSG="$1 pane($id) 마지막 줄이 맨 프롬프트가 아니다"; return 1; }
   tmux_c send-keys -t "$id" C-a C-k && tmux_c send-keys -t "$id" -l "$2" && tmux_c send-keys -t "$id" Enter \
      || { PANE_MSG="send-keys 실패"; return 1; }
   PANE_MSG="$1 pane($id) 에 쳤다"; return 0
}
s8() {
   local t sp rc cmd
   if [ "$POWER" != 1 ]; then
      [ "$DRY" -eq 1 ] && return
      t=$(ts); run_usbrecover --force-power-cycle --dry-run > "$LOGDIR/usb-recover-dry.txt" 2>&1; rc=$?
      case $rc in
         3) record 8 전원 "$t" "dry-run : 수집 중이면 안전 게이트가 막는다(3)" "rc=3 게이트가 막았다 (하드웨어 0)" PASS "$LOGDIR/usb-recover-dry.txt" ;;
         0) record 8 전원 "$t" "dry-run : 계획만(0)" "rc=0 계획만 찍었다 (하드웨어 0)" PASS "$LOGDIR/usb-recover-dry.txt" ;;
         *) record 8 전원 "$t" "dry-run rc 0 또는 3" "rc=$rc" FAIL "$LOGDIR/usb-recover-dry.txt" ;;
      esac
      return
   fi
   guard 8 전원 || return
   sp=$(first_pid rcsupervisor); R0=$(hb_run); SOFF=$(fsize "$SUPLOG")
   cmd=$(print_cmd supervisor)
   [ -n "$cmd" ] || { record 8 전원 - "감시자 재기동 명령" "daq-tmux.sh --print-cmd supervisor 가 없다 -- 전원 단계를 하지 않았다" FAIL "$DAQTMUX"; return; }
   t=$(ts); log "주입 : 감시자 pid $sp 에 TERM (run $R0 정상 마감) -> 전원 단계"
   POWER_CMD=$cmd; POWER_DOWN=1          # 여기부터 감시자 재기동까지 수집이 멎는다. 신호로 끝나도 안내가 남게
   send_sig TERM "$sp"
   all_down() { [ -z "$(first_pid rcsupervisor)$(first_pid rcterm)$(first_pid daq)$(first_pid tcb)$(first_pid merger)" ]; }
   if ! wait_for 600 all_down; then
      record 8 전원 "$t" "감시자·DAQ 정상 마감" "${ABORTED:-아직 살아 있다} -- 전원 단계를 하지 않았다. ★ 수집 멈춤, 손으로 띄울 것 : $cmd" FAIL "$(sup_has 'stop|finished')"
      ABORTED="전원 단계 도중 중단 (수집이 멎어 있다)"; return
   fi
   if hold_new; then
      record 8 전원 "$t" "전원 단계" "멈춤 파일이 생겨 전원을 건드리지 않았다. ★ 수집 멈춤, 손으로 띄울 것 : $cmd" FAIL "$HOLD"
      ABORTED="멈춤 파일 (수집이 멎어 있다)"; return
   fi
   run_usbrecover --force-power-cycle > "$LOGDIR/usb-recover-power.txt" 2>&1; rc=$?
   log "usb-recover --force-power-cycle rc=$rc"
   if [ "$rc" != 0 ]; then
      record 8 전원 "$t" "usb-recover rc=0 (확인 런 합격)" "rc=$rc -- 감시자를 다시 띄우지 않았다. ★ 사람이 볼 것. ★ 수집 멈춤, 손으로 띄울 것 : $cmd" FAIL "$LOGDIR/usb-recover-power.txt"
      ABORTED="전원 단계 실패 (수집이 멎어 있다)"; return
   fi
   if ! type_in_pane supervisor "$cmd"; then
      record 8 전원 "$t" "감시자 재기동" "전원 합격, 그러나 $PANE_MSG -- ★ 손으로 띄울 것 : $cmd" FAIL ""
      ABORTED="감시자 재기동 실패 (수집이 멎어 있다)"; return
   fi
   POWER_DOWN=0
   if wait_for "$T_POWER" new_run_up; then
      record 8 전원 "$t" "전원 재투입 -> 확인 런 합격 -> 새 런 + DRAM" "run $R0 -> $NEWRUN, $DRAM_MSG" PASS "$LOGDIR/usb-recover-power.txt"
   else
      record 8 전원 "$t" "새 런 (${T_POWER} s 안)" "run=$(hb_run) phase=$(hbf phase)" FAIL "$PANE_MSG"
   fi
}

# =====================================================================
#  9 — [사람] 바깥 망 복귀
# =====================================================================
drill_runs_cmd() {       # 이번 드릴의 런 범위를 onlbit=0 으로 빼는 명령 (백업 먼저). 드릴은 DB 를 건드리지 않는다
   local lo=${B_RUN:-0} hi; hi=$(hb_run)
   [ "$hi" -ge "$lo" ] || hi=$lo
   printf "cp -p %s /Data_ssd/LOG/harness/runcatalog.db.bak-\$(date +%%Y%%m%%d%%H%%M)-before-drill && sqlite3 %s \"UPDATE runcatalog SET onlbit=0, runlog='autonomy drill test run, excluded from sheet' || COALESCE(' ; ' || runlog, '') WHERE runnum BETWEEN %s AND %s;\"" \
      "$DBFILE" "$DBFILE" "$lo" "$hi"
}
s9() {
   local t off line rc runs
   t=$(ts)
   DRILL_DB_CMD=$(drill_runs_cmd)
   banner "★ 사람 차례 1 : 망을 되살리기 *전에* 이번 드릴의 런($B_RUN ~ $(hb_run))을 시트에서 뺀다.
   망이 돌아오는 순간 netsync 가 sheetlog-auto --force 로 onlbit=1 런을 GoodRuns 에 싣는다. 먼저 이것을 친다 (백업 먼저) :
   $DRILL_DB_CMD"
   off=$(fsize "$NSLOG")
   banner "★ 사람 차례 2 : 그다음 바깥 망을 되살려라 (root).  예) sudo nmcli connection up enp0s31f6  또는 뽑은 케이블을 다시 꽂는다 (★ daq_gateway 를 올리지 말 것 -- .71 충돌)
   netsync 가 net=up 을 적고 밀린 메일·시트를 내보낼 때까지 최대 ${T_NETUP} s 기다린다"
   if ! wait_for "$T_NETUP" ns_is_up; then
      record 9 망복귀 "$t" "netsync net=up" "net=$(ns_get net) checked=$(ns_get checked)" FAIL "$NSSTATE"; return
   fi
   #  netsync 는 up 을 먼저 적고 flush 안에서 mailq-send -> sheetlog-auto --force (최대 1200 s) 순으로 돈다.
   #  그래서 큐 0 이나 --status 가 아니라 netsync.log 의 'sheetlog-auto --force rc=' 줄(이번 오프셋 이후)을 기다린다.
   flushed() { line=$(since "$NSLOG" "$off" | grep 'sheetlog-auto --force rc=' | tail -1); [ -n "$line" ]; }
   if ! wait_for "$T_SHEET" flushed; then
      record 9 망복귀 "$t" "netsync flush 의 sheetlog-auto --force 결과 (${T_SHEET} s 안)" "net=up 이나 flush 기록 없음" FAIL "$NSLOG"; return
   fi
   rc=$(printf '%s' "$line" | sed -n 's/.*--force rc=\([0-9]*\).*/\1/p'); runs=$(printf '%s' "$line" | sed -n 's/.*등재 \([0-9]*\) 런.*/\1/p')
   q_empty() { [ "$(qcount "$LOCALQ")" = 0 ] && [ "$(qcount "$NFSQ")" = 0 ]; }
   if ! wait_for "$T_FLUSH" q_empty; then
      record 9 망복귀 "$t" "메일 큐 0" "local=$(qcount "$LOCALQ") nfs=$(qcount "$NFSQ") 통 남음 (sheetlog rc=${rc:-?})" FAIL "mailq-send.sh --status"; return
   fi
   #  flush 뒤에 완결된 런(7·8 단계의 꼬리, 드릴 런)은 다음 cron 몫이라 판정에 넣지 않는다 -- rc 와 등재 수로만
   if [ "${rc:-x}" = 0 ]; then
      record 9 망복귀 "$t" "net=up · sheetlog --force rc 0 · 큐 0" "up since=$(ns_get since), 시트 등재 ${runs:-0} 런, 큐 0" PASS "$line"
   else
      record 9 망복귀 "$t" "sheetlog-auto --force rc 0" "rc=${rc:-?} 등재 ${runs:-?} 런" FAIL "$line"
   fi
}

name_of() {
   case $1 in 0) echo 전제 ;; 1) echo 기준선 ;; 2) echo 망차단 ;; 3) echo 메일큐 ;; 4) echo daq종료 ;;
              5) echo stale ;; 6) echo postrun ;; 7) echo SIGUSR1 ;; 8) echo 전원 ;; 9) echo 망복귀 ;; esac
}

# =====================================================================
#  계획만 (--dry-run)
# =====================================================================
plan_line() {
   case $1 in
      0) echo "전제 점검 (읽기)" ;;
      1) echo "기준선 기록 (읽기)" ;;
      2) echo "[사람] 망 차단 -> netsync down 대기 ${T_NETDOWN} s" ;;
      3) echo "chainwatch 1 회 -> $LOCALQ 적재 대기 ${T_MAILQ} s" ;;
      4) echo "daq TERM -> restart -> 새 런 + DRAM ${DRAM_LINES} (${T_KILL} s)" ;;
      5) sup_timing; echo "rcterm STOP -> stale -> 새 런 (${T_STALE:-$(( SUP_CHECK + SUP_STALE + 900 ))} s, 뒤에 CONT)" ;;
      6) echo "postrun TERM -> chain_down -> pane 재기동 (${T_POSTRUN} s)" ;;
      7) echo "감시자 USR1 (SigCgt 확인) -> 새 런 (${T_USR1} s)" ;;
      8) [ "$POWER" = 1 ] && echo "★ 감시자 TERM -> usb-recover --force-power-cycle 실물 -> 감시자 재기동 (${T_POWER} s)" \
                           || echo "usb-recover --force-power-cycle --dry-run (하드웨어 0)" ;;
      9) echo "[사람] 망 복귀 -> net=up · 큐 0 · 시트 0 (${T_NETUP}+${T_FLUSH} s)" ;;
   esac
}

# =====================================================================
#  10 — 요약
# =====================================================================
write_report() {
REPORTED=1
{
   echo "# 자율 복구 드릴 결과 — $PLAN"
   echo
   echo "- 시작 $(date -d "@$START" '+%F %T' 2>/dev/null) · 끝 $(ts) · 로그 \`$LOGDIR\`"
   echo "- 옵션 : 시험런확인=$CONFIRM 전원=$POWER  ·  중단 : ${ABORTED:-없음}"
   echo
   echo "| 단계 | 이름 | 주입 | 판정 | 관측 | 근거 |"
   echo "|---|---|---|---|---|---|"
   tail -n +2 "$RES" | awk -F '\t' '{ printf "| %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $6, $5, $7 }'
   echo
   echo "PASS $(cut -f6 "$RES" | grep -c '^PASS$') · FAIL $(cut -f6 "$RES" | grep -c '^FAIL$') · SKIP $(cut -f6 "$RES" | grep -c '^SKIP$')"
   echo
   echo "FAIL 이 있으면 docs/AUTONOMY-DRILL.md 의 '실패했을 때' 표를 볼 것."
   if [ -n "${B_RUN:-}" ] && [ "$CONFIRM" = 1 ]; then
      echo
      echo "★ 이번 드릴의 런($B_RUN ~ $(hb_run))을 시트에서 뺄 것 (아직 안 했으면, 백업 먼저) :"
      echo
      echo '```'; drill_runs_cmd; echo; echo '```'
   fi
} > "$LOGDIR/report.md"
}
# =====================================================================
#  실행
# =====================================================================
if [ "$DRY" -eq 1 ]; then
   for s in $STEPS; do log "[계획] 단계 $s : $(plan_line "$s")"; done
   s0 >/dev/null; pre=$?; log "[계획] 전제 : $(tail -1 "$RES" | cut -f5,6)"
   log "[DRY] 주입 0 회. 아무것도 하지 않았다."
   [ "$pre" -eq 0 ] && exit 0
   log "[DRY] 전제가 충족되지 않아 지금은 드릴을 돌릴 수 없다 (rc 1)"
   exit 1
fi

PREOK=1
for s in $STEPS; do
   if [ "$s" = 0 ]; then s0 || PREOK=0; continue; fi
   if [ "$PREOK" = 0 ]; then
      record "$s" "$(name_of "$s")" - - "전제 실패로 하지 않았다" SKIP ""; continue
   fi
   [ "$s" = 9 ] && [ "$NETWENT" = 0 ] && { record 9 망복귀 - - "2 단계를 안 했다" SKIP ""; continue; }
   "s$s"
done

write_report
log "끝 : PASS $(cut -f6 "$RES" | grep -c '^PASS$') · FAIL $NFAIL · SKIP $(cut -f6 "$RES" | grep -c '^SKIP$') -> $LOGDIR/report.md"
[ "$NFAIL" -eq 0 ] && [ -z "$ABORTED" ] && exit 0
exit 1
