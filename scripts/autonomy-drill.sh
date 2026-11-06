#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  autonomy-drill.sh - 자율 복구 드릴. 일부러 고장을 내고, 시스템이 사람 없이 되살아나는지 본다.
#
#  사용 :
#     autonomy-drill.sh --plan offline-full --confirm-test-run [--with-power] [--continue-online] [--no-mark-db] [--log DIR]
#     autonomy-drill.sh --plan quick        --confirm-test-run [--with-power] [--no-mark-db] [--log DIR]
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
#                 ★ 끊긴 것이 확인되지 않으면 여기서 멈춘다 (주입 0). --continue-online 이면 망이 산 채로 계속
#     3  메일     chainwatch 를 한 번 돌리고, 알림이 /Data_ssd/LOG/MAILQ 에 쌓이는지
#     4  daq 종료 daq 하나에 TERM -> 감시자 restart -> 새 런 running + DRAM 8/8
#     5  stale    rcterm 에 STOP -> 감시자가 heartbeat stale 로 잡아 재시작 -> 새 런 (뒤에 CONT 로 안전 마감)
#     6  postrun  postrun 셸에 TERM -> chainwatch chain_down -> pane 자동 재기동
#     7  SIGUSR1  감시자에 USR1 (SigCgt 로 지원 확인) -> 지금 런 정상 마감 -> 새 런
#     8  전원     기본 : usb-recover.sh --force-power-cycle --dry-run (게이트 확인, 하드웨어 0)
#                 --with-power : 감시자 TERM -> usb-recover --force-power-cycle 실물 1 회 -> 감시자 재기동
#     9  [사람]   바깥 망을 되살린다 -> net=up -> 메일 큐 0 · netsync flush 가 시트·웹을 건너뜀(드릴 중)
#     10 요약     runcatalog 표시(아래) + result.tsv + report.md
#
#  드릴 플래그 (2026-11-06)
#     전제 통과 직후 drill_flag(notify.params, 기본 /Data_ssd/LOG/drill.active)에 pid= start= run= plan= 을 쓰고
#     끝(정상·중단·신호)에 지운다. 그동안 daq-notify 는 책임자에게만 [DRILL] 로 보내고 알람을 울리지 않으며,
#     netsync 는 복귀 flush 에서 시트·웹을 건너뛰고, sheetlog-auto 는 --force 여도 쓰지 않는다. --dry-run 은 만들지 않는다.
#  runcatalog 표시 (기본 켬, --no-mark-db 로 끔)
#     끝날 때 DB 를 <DRILL_DBBAK_DIR>/runcatalog.db.bak-<시각>-drill 로 (sqlite3 .backup) 백업한 뒤
#       첫 주입 런 <= 런 < 끝 런   (주입이 없었으면 시작 런 < 런 < 끝 런)
#     을 onlbit=0, runlog 앞에 'autonomy drill test run (<시작>~<끝>), excluded from sheet' (옛 runlog 는 ' ; ' 뒤에).
#     하한이 첫 주입 런인 것은 2·3 단계 대기 중 자연 로테이션이 오면 플래그 런이 24 h 완주 정상 런이기 때문 (리뷰 M2).
#     끝 런은 heartbeat 가 running 이면 뺀다 -- 정상 설정으로 계속 도는 런이다 (11-05 의 4437 은 9.6 h 돌았다).
#     running 이 아니면 rcterm 이 없고 phase=ended|failed 일 때만 넣는다 -- 살아 있는 rcterm 은 런을 닫으며 onlbit 를
#     다시 쓴다 (리뷰 M1). 최대 120 s 기다리고 그래도 있으면 report.md 에 그 런만의 명령을 남긴다. 표시 뒤 되읽어 대조.
#     바꾼 행은 db-mark.tsv · report.md · drill.log 에 표로.
#
#  안전
#     - 4~8 은 --confirm-test-run 이 있을 때만 (시험 런을 깨뜨린다). 없으면 SKIP
#     - 매 주입 전에 heartbeat 를 다시 읽고 phase=running 이 아니면 남은 주입을 모두 건너뛴다
#     - kill 은 PID 로만 (pgrep -x · ps 계보). pgrep -f 는 쓰지 않는다
#     - 전원은 --with-power 없이는 절대 하지 않는다
#     - 멈춤 파일(chainwatch.hold)을 만들지 않는다 -- 자동 재기동을 시험하는 것이므로.
#       ★ 예외 : 8 단계(--with-power)는 감시자 TERM 전에 자기 표식이 든 hold 를 만들고 감시자 재기동 직전에 지운다 --
#         chainwatch 가 chain_sup_restart_manual=1 로 전원 작업 도중 감시자를 띄우지 않게 (리뷰 2026-11-05)
#       대신 <루트>/RUNNING 표식으로 두 드릴이 겹치지 않게 한다 (드릴 플래그도 살아 있는 남의 것이면 멈춘다)
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
T_SHEET=${DRILL_T_SHEET:-1500}       # netsync flush 는 mailq-send(최대 600 s) 뒤에 sheetlog 줄(드릴 중이면 '건너뜀')을 적는다
PARAMS=${DRILL_PARAMS:-$DIR/config/notify.params}
DBBAK_DIR=${DRILL_DBBAK_DIR:-/Data_ssd/LOG/harness}
# shellcheck source=/dev/null
. "$DIR/scripts/netsync-lib.sh" 2>/dev/null       # drill_flag_param · drill_flag_get · drill_active (DRILL_FLAG 환경변수가 이긴다)
[ -r "$PARAMS" ] && type drill_flag_param >/dev/null 2>&1 && \
   drill_flag_param "$(sed -n 's/^[[:space:]]*drill_flag[[:space:]]*=[[:space:]]*//p' "$PARAMS" 2>/dev/null | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//' | head -1)"
DRILL_FLAG=${DRILL_FLAG:-/Data_ssd/LOG/drill.active}
PROMPT_RE=${DRILL_PROMPT_RE:-'[$#] ?$'}

PLAN=""; DRY=0; CONFIRM=0; POWER=0; LOGDIR=""; MARKDB=1; ONLINE=0
usage() { sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
   case "$1" in
      --plan)             PLAN=${2:-}; shift 2 ;;
      --dry-run)          DRY=1; shift ;;
      --confirm-test-run) CONFIRM=1; shift ;;
      --with-power)       POWER=1; shift ;;
      --no-mark-db)       MARKDB=0; shift ;;
      --continue-online)  ONLINE=1; shift ;;
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
#  ★ 시험(DRILL_TEST_HOOK)인데 플래그·백업 경로를 안 갈아끼웠으면 운영 자리(/Data_ssd/LOG)에 쓰지 않게 ROOT 밑으로 돌린다
if [ -n "${DRILL_TEST_HOOK:-}" ]; then
   [ -n "${DRILL_FLAG_FROM_ENV:-}" ] || DRILL_FLAG=$ROOT/drill.active
   [ -n "${DRILL_DBBAK_DIR:-}" ] || DBBAK_DIR=$ROOT/dbbak
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

HOLD_MINE=0
hold_new() { [ -e "$HOLD" ] && [ "$HOLD_AT_START" = 0 ] && ! grep -qs "autonomy-drill pid=$$" "$HOLD"; }
drill_hold_set() { [ -e "$HOLD" ] && return 0; printf 'autonomy-drill pid=%s %s\n' "$$" "$(date '+%F %T')" > "$HOLD" 2>/dev/null && HOLD_MINE=1; log "멈춤 파일을 만들었다 ($HOLD) -- 전원 단계 동안 chainwatch 가 감시자를 띄우지 않게"; }
drill_hold_rm()  { [ "$HOLD_MINE" = 1 ] || return 0; rm -f "$HOLD"; HOLD_MINE=0; log "멈춤 파일을 지웠다 ($HOLD)"; }
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
   drill_hold_rm
   [ "${POWER_DOWN:-0}" = 1 ] && log "★ 수집 멈춤 (전원 단계 도중 끝났다). 손으로 띄울 것 : tmux daq:1.2 에서 ${POWER_CMD:-bash scripts/daq-tmux.sh --print-cmd supervisor 의 명령}"
   type mark_db >/dev/null 2>&1 && mark_db
   [ "$OWN_MARK" = 1 ] && [ "$REPORTED" = 0 ] && type write_report >/dev/null 2>&1 && write_report
   flag_drop
   [ "$OWN_MARK" = 1 ] && rm -f "$MARK"
   return 0
}
REPORTED=0

# ---- 드릴 플래그 -------------------------------------------------------------
OWN_FLAG=0; F_RUN=""; INJ=0; INJ_RUN=""
#  첫 주입이 때린 런을 기억한다 (리뷰 M2). 단계 2·3 대기 중 자연 로테이션이 오면 F_RUN 은 24 h 를 완주한
#  정상 런이고 주입은 F_RUN+1 에 간다 -- 표시의 하한은 F_RUN 이 아니라 이 런이다
inj_mark() { INJ=$(( INJ + 1 )); [ -n "$INJ_RUN" ] || INJ_RUN=${R0:-$(hb_run)}; }
flag_take() {            # 전제 통과 직후. 살아 있는 남의 플래그면 1
   local op
   if [ -e "$DRILL_FLAG" ]; then
      op=$(sed -n 's/^pid=//p' "$DRILL_FLAG" 2>/dev/null | head -1)
      if [ -n "$op" ] && [ "$op" != "$$" ] && pid_alive "$op"; then
         record 0 드릴플래그 - "다른 드릴 없음" "pid $op 가 $DRILL_FLAG 을 쥐고 있다" FAIL "$DRILL_FLAG"; return 1
      fi
      log "죽은 드릴 플래그를 지운다 (pid ${op:-?} 는 없다) : $DRILL_FLAG"; rm -f "$DRILL_FLAG"
   fi
   F_RUN=$(hb_run)
   #  pstart = 이 셸의 /proc 시작 시각. 읽는 쪽(drill_active)이 pid 재사용을 가린다 (리뷰 R1)
   if ( set -o noclobber; printf 'pid=%s\npstart=%s\nstart=%s\nrun=%s\nplan=%s\nlog=%s\n' "$$" "$(drill_proc_start $$ 2>/dev/null)" "$(now_s)" "$F_RUN" "$PLAN" "$LOGDIR" > "$DRILL_FLAG" ) 2>/dev/null; then
      OWN_FLAG=1; log "드릴 플래그를 만들었다 ($DRILL_FLAG, run $F_RUN) -- 알림은 책임자에게만 [DRILL], 시트 등재는 멈춘다"; return 0
   fi
   record 0 드릴플래그 - "플래그를 만든다" "만들 수 없다 ($DRILL_FLAG)" FAIL ""; return 1
}
flag_drop() { [ "$OWN_FLAG" = 1 ] || return 0; rm -f "$DRILL_FLAG"; OWN_FLAG=0; log "드릴 플래그를 지웠다 ($DRILL_FLAG)"; }

# ---- 끝날 때 : 이번 드릴의 런을 runcatalog 에서 뺀다 ------------------------------
#  ★ rcterm 은 런을 닫을 때 FinalizeRunInDB 가 onlbit = goodRun?1:0 을, MarkFailedRunInDB 가 runlog 를 통째로 쓴다
#    (src/RunControl.cc). 그래서 rcterm 이 아직 쥐고 있는 런(heartbeat 의 마지막 런)을 지금 0 으로 적어도
#    나중에 1 로 되돌아간다 (리뷰 M1 -- STOP 중 INT 뒤 CONT 받은 rcterm 이 정상 마감하는 경로).
#    끝 런은 rcterm 이 없고 phase 가 ended/failed 일 때만 넣는다. 아니면 기다리고, 그래도 아니면 손으로.
T_ENDWAIT=${DRILL_T_ENDWAIT:-120}
MARKED=0; DB_MSG=""; DB_SQL=""; END_RUN=""; END_MODE=""; DB_PEND_SQL=""; DB_VERIFY=""
end_state() {            # END_RUN · END_MODE (running | done | pending) 를 정한다. 최대 T_ENDWAIT 초 기다린다
   local t0 ph; t0=$(now_s)
   while :; do
      END_RUN=$(hb_run); ph=$(hbf phase)
      if hb_running; then END_MODE=running; return 0; fi
      if [ -z "$(pid_of rcterm)" ] && { [ "$ph" = ended ] || [ "$ph" = failed ]; }; then END_MODE=done; return 0; fi
      if [ $(( $(now_s) - t0 )) -ge "$T_ENDWAIT" ]; then END_MODE=pending; return 0; fi
      [ $(( $(now_s) - t0 )) = 0 ] && log "runcatalog : 끝 런 $END_RUN 의 rcterm 이 아직 있거나 phase=${ph:-?} -- 최대 ${T_ENDWAIT} s 기다린다"
      sleep_s "$POLL"
   done
}
db_where() {             # 표시할 런의 조건 DB_COND.  하한 : 주입했으면 첫 주입 런, 아니면 시작 런 다음.  상한 : 끝 런 (done 일 때만 포함)
   local lo hix
   if [ "$INJ" -gt 0 ] && [ -n "$INJ_RUN" ]; then lo=$INJ_RUN; else lo=$(( ${F_RUN:-0} + 1 )); fi
   end_state
   hix=$END_RUN; [ "$END_MODE" = done ] && hix=$(( END_RUN + 1 ))
   DB_LO=$lo; DB_HIX=$hix
   DB_COND="(runnum >= $lo AND runnum < $hix)"
}
db_backup() {            # $1=백업 파일.  sqlite3 .backup (쓰는 도중에도 일관된 사본). 없으면 cp -p (리뷰 R2)
   sqlite3 -cmd '.timeout 10000' "$DBFILE" ".backup '$1'" 2>/dev/null && [ -s "$1" ] && return 0
   cp -p "$DBFILE" "$1" 2>/dev/null
}
mark_db() {
   local tag rows bak n out bad sqlend
   [ "$MARKED" = 1 ] && return 0; MARKED=1
   [ "$OWN_FLAG" = 1 ] || return 0           # dry-run · 전제 실패 : 드릴이 아니었다
   db_where
   tag="autonomy drill test run ($(date -d "@$START" '+%F %H:%M' 2>/dev/null)~$(date -d "@$(now_s)" '+%m-%d %H:%M' 2>/dev/null)), excluded from sheet"
   DB_SQL="UPDATE runcatalog SET onlbit=0, runlog = CASE WHEN runlog LIKE 'autonomy drill test run%' THEN runlog ELSE '$tag' || COALESCE(' ; ' || NULLIF(runlog, ''), '') END WHERE $DB_COND;"
   #  끝 런을 rcterm 이 아직 쥐고 있으면 넣지 않고, 그 런만의 명령을 report 에 남긴다
   if [ "$END_MODE" = pending ] && [ "$END_RUN" -ge "$DB_LO" ]; then
      sqlend=${DB_SQL% WHERE*}" WHERE runnum = $END_RUN;"
      DB_PEND_SQL="sqlite3 $DBFILE \".backup '$DBBAK_DIR/runcatalog.db.bak-\$(date +%Y%m%d%H%M%S)-drill'\" && sqlite3 $DBFILE \"$sqlend\""
      log "★ 끝 런 $END_RUN 은 rcterm 이 아직 있어(phase=$(hbf phase)) 표시하지 않았다 -- rcterm 이 런을 닫으며 onlbit 를 다시 쓴다. 닫힌 뒤 손으로 : $DB_PEND_SQL"
   fi
   if [ "$MARKDB" = 0 ]; then
      DB_MSG="--no-mark-db : runcatalog 를 건드리지 않았다. 시트에서 빼려면 손으로 (백업 먼저)"
      log "$DB_MSG : $DB_SQL"; return 0
   fi
   if [ ! -w "$DBFILE" ]; then DB_MSG="★ $DBFILE 에 쓸 수 없다 -- 표시하지 못했다"; log "$DB_MSG"; return 0; fi
   if [ "$DB_HIX" -le "$DB_LO" ]; then DB_MSG="바꿀 런 없음 (조건 $DB_COND)"; log "runcatalog : $DB_MSG"; return 0; fi
   rows=$(sqlite3 -separator '|' -cmd '.timeout 10000' "$DBFILE" "SELECT runnum, IFNULL(onlbit,'NULL'), IFNULL(substr(runlog,1,80),'') FROM runcatalog WHERE $DB_COND ORDER BY runnum;" 2>&1) \
      || { DB_MSG="★ DB 를 읽지 못했다 : $(clean "$rows")"; log "$DB_MSG"; return 0; }
   if [ -z "$rows" ]; then DB_MSG="바꿀 런 없음 (조건 $DB_COND)"; log "runcatalog : $DB_MSG"; return 0; fi
   mkdir -p "$DBBAK_DIR" 2>/dev/null
   bak="$DBBAK_DIR/runcatalog.db.bak-$(date +%Y%m%d%H%M%S)-drill"
   db_backup "$bak" || { DB_MSG="★ 백업을 만들지 못해 표시하지 않았다 ($bak)"; log "$DB_MSG"; return 0; }
   if ! out=$(sqlite3 -cmd '.timeout 10000' "$DBFILE" "$DB_SQL" 2>&1); then
      DB_MSG="★ UPDATE 실패 : $(clean "$out") (백업 $bak)"; log "$DB_MSG"; return 0
   fi
   { printf 'run\tonlbit_before\tonlbit_after\trunlog_before\n'
     printf '%s\n' "$rows" | awk -F '|' '{ printf "%s\t%s\t0\t%s\n", $1, $2, $3 }'; } > "$LOGDIR/db-mark.tsv"
   n=$(printf '%s\n' "$rows" | grep -c .)
   DB_MSG="런 $n 개를 onlbit=0 으로 (조건 $DB_COND, 백업 $bak)"
   log "runcatalog : $DB_MSG"
   printf '%s\n' "$rows" | awk -F '|' '{ printf "   run %s  onlbit %s -> 0  runlog(전) %s\n", $1, $2, $3 }' | while IFS= read -r l; do log "$l"; done
   #  되읽어 대조 (리뷰 R3)
   bad=$(sqlite3 -separator '|' -cmd '.timeout 10000' "$DBFILE" "SELECT runnum, IFNULL(onlbit,'NULL') FROM runcatalog WHERE $DB_COND AND (onlbit IS NULL OR onlbit != 0) ORDER BY runnum;" 2>&1)
   if [ -n "$bad" ]; then
      DB_VERIFY="★ 되읽기 어긋남 : $(clean "$bad") -- onlbit 가 0 이 아니다"
   else
      DB_VERIFY="되읽기 : $n 개 모두 onlbit=0"
   fi
   log "runcatalog : $DB_VERIFY"
}
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
   banner "★ 사람 차례 : 지금 바깥 망을 끊어라 (root, 콘솔에서).  sudo nmcli connection down enp0s31f6   (★ daq_gateway 아님)
   ★ 케이블을 뽑기보다 nmcli 로 끊는 편이 안전하다 -- 11-06 09:18 케이블을 뽑다 FADC USB 가 빠져 run 4437 이 죽었다.
   (원격 세션은 여기서 끊긴다. 드릴은 혼자 계속 돈다.)  netsync 가 net=down 을 적을 때까지 최대 ${T_NETDOWN} s 기다린다.
   끊긴 것이 확인되지 않으면 $( [ "$ONLINE" = 1 ] && echo '--continue-online 이라 망이 산 채로 계속한다' || echo '드릴은 여기서 멈춘다 (주입 0)')"
   if wait_for "$T_NETDOWN" ns_is_down; then
      NETWENT=1; record 2 망차단 "$t" "netsync net=down" "down (since=$(ns_get since))" PASS "$NSSTATE checked=$(ns_get checked)"
      return
   fi
   record 2 망차단 "$t" "netsync net=down (${T_NETDOWN} s 안)" "net=$(ns_get net) checked=$(ns_get checked)" FAIL "$NSSTATE"
   if [ "$ONLINE" = 1 ] && [ -z "$ABORTED" ]; then
      NETWENT=1   # 사람이 늦게 끊었을 수는 있다. 9 단계 안내는 그대로 한다
      log "--continue-online : 망이 산 채로 주입을 계속한다 (알림은 드릴 플래그로 책임자에게만 [DRILL])"
   else
      [ -n "$ABORTED" ] || ABORTED="망을 끊지 않아 중단 (2 단계, --continue-online 없음)"
      NETWENT=0
      log "★ $ABORTED -- 주입하지 않는다. 늦게 끊었다면 지금 되살려라 : sudo nmcli connection up enp0s31f6"
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
   t=$(ts); log "주입 : daq pid $p 에 TERM (run $R0)"; inj_mark; send_sig TERM "$p"
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
   STOPPED="$STOPPED $p"; inj_mark; send_sig STOP "$p"
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
   inj_mark; send_sig USR1 "$sp"
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
      [ -n "$ABORTED" ] && { record 8 전원 - "-" "중단 : $ABORTED" SKIP ""; return; }
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
   drill_hold_set                        # 전원 작업 도중 chainwatch(chain_sup_restart_manual=1)가 감시자를 띄우지 않게
   inj_mark; send_sig TERM "$sp"
   all_down() { [ -z "$(first_pid rcsupervisor)$(first_pid rcterm)$(first_pid daq)$(first_pid tcb)$(first_pid merger)" ]; }
   if ! wait_for 600 all_down; then
      drill_hold_rm
      record 8 전원 "$t" "감시자·DAQ 정상 마감" "${ABORTED:-아직 살아 있다} -- 전원 단계를 하지 않았다. ★ 수집 멈춤, 손으로 띄울 것 : $cmd" FAIL "$(sup_has 'stop|finished')"
      ABORTED="전원 단계 도중 중단 (수집이 멎어 있다)"; return
   fi
   if hold_new; then
      drill_hold_rm
      record 8 전원 "$t" "전원 단계" "멈춤 파일이 생겨 전원을 건드리지 않았다. ★ 수집 멈춤, 손으로 띄울 것 : $cmd" FAIL "$HOLD"
      ABORTED="멈춤 파일 (수집이 멎어 있다)"; return
   fi
   run_usbrecover --force-power-cycle > "$LOGDIR/usb-recover-power.txt" 2>&1; rc=$?
   log "usb-recover --force-power-cycle rc=$rc"
   drill_hold_rm                         # 여기서부터는 chainwatch 가 감시자를 띄워도 된다 (실패해도 30 분 뒤 되살리는 쪽이 낫다)
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
s9() {
   local t off line q
   t=$(ts)
   off=$(fsize "$NSLOG")
   banner "★ 사람 차례 : 바깥 망을 되살려라 (root).  sudo nmcli connection up enp0s31f6  (★ daq_gateway 를 올리지 말 것 -- .71 충돌)
   드릴 플래그가 있으므로 netsync 의 복귀 flush 는 메일 큐만 내보내고 시트·웹은 건너뛴다.
   이번 드릴의 런은 드릴이 끝날 때 runcatalog 에서 onlbit=0 으로 스스로 뺀다$( [ "$MARKDB" = 0 ] && echo ' (★ --no-mark-db : 손으로 빼야 한다)').
   netsync 가 net=up 을 적고 flush 할 때까지 최대 ${T_NETUP} s 기다린다"
   if ! wait_for "$T_NETUP" ns_is_up; then
      record 9 망복귀 "$t" "netsync net=up" "net=$(ns_get net) checked=$(ns_get checked)" FAIL "$NSSTATE"; return
   fi
   #  netsync 는 up 을 먼저 적고 flush 안에서 mailq-send -> sheetlog(드릴 중이면 '건너뜀') 순으로 돈다.
   #  그래서 큐 0 이 아니라 netsync.log 의 sheetlog 줄(이번 오프셋 이후)을 기다린다.
   flushed() { line=$(since "$NSLOG" "$off" | grep -E 'sheetlog-auto (건너뜀|rc=|--force rc=)' | tail -1); [ -n "$line" ]; }
   if ! wait_for "$T_SHEET" flushed; then
      record 9 망복귀 "$t" "netsync flush 의 sheetlog 줄 (${T_SHEET} s 안)" "net=up 이나 flush 기록 없음" FAIL "$NSLOG"; return
   fi
   q_empty() { [ "$(qcount "$LOCALQ")" = 0 ] && [ "$(qcount "$NFSQ")" = 0 ]; }
   if ! wait_for "$T_FLUSH" q_empty; then
      record 9 망복귀 "$t" "메일 큐 0" "local=$(qcount "$LOCALQ") nfs=$(qcount "$NFSQ") 통 남음" FAIL "mailq-send.sh --status"; return
   fi
   case "$line" in
      *건너뜀*) record 9 망복귀 "$t" "net=up · 큐 0 · 드릴 중이라 시트 건너뜀" "up since=$(ns_get since), 큐 0, 시트 건너뜀" PASS "$line" ;;
      *)        record 9 망복귀 "$t" "드릴 중 flush 는 시트를 건너뛴다" "netsync 가 드릴 중에 sheetlog-auto 를 돌렸다 -- 드릴 플래그($DRILL_FLAG)를 못 봤다 (옛 netsync? drill_flag 경로가 다른가?)" FAIL "$line" ;;
   esac
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
      2) echo "[사람] 망 차단 (nmcli) -> netsync down 대기 ${T_NETDOWN} s. 확인 안 되면 $( [ "$ONLINE" = 1 ] && echo '그래도 계속 (--continue-online)' || echo '여기서 멈춘다 (주입 0)')" ;;
      3) echo "chainwatch 1 회 -> $LOCALQ 적재 대기 ${T_MAILQ} s" ;;
      4) echo "daq TERM -> restart -> 새 런 + DRAM ${DRAM_LINES} (${T_KILL} s)" ;;
      5) sup_timing; echo "rcterm STOP -> stale -> 새 런 (${T_STALE:-$(( SUP_CHECK + SUP_STALE + 900 ))} s, 뒤에 CONT)" ;;
      6) echo "postrun TERM -> chain_down -> pane 재기동 (${T_POSTRUN} s)" ;;
      7) echo "감시자 USR1 (SigCgt 확인) -> 새 런 (${T_USR1} s)" ;;
      8) [ "$POWER" = 1 ] && echo "★ 감시자 TERM -> usb-recover --force-power-cycle 실물 -> 감시자 재기동 (${T_POWER} s)" \
                           || echo "usb-recover --force-power-cycle --dry-run (하드웨어 0)" ;;
      9) echo "[사람] 망 복귀 -> net=up · 큐 0 · flush 가 시트·웹 건너뜀 (${T_NETUP}+${T_FLUSH} s)" ;;
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
   echo
   echo "## runcatalog 표시"
   echo
   if [ "$OWN_FLAG" = 1 ] || [ -n "$DB_MSG" ]; then
      case "$END_MODE" in
         running) em="running -> 뺐다 (정상 런으로 계속 돈다)" ;;
         done)    em="rcterm 이 닫았다 -> 넣었다" ;;
         pending) em="★ rcterm 이 아직 있다 -> 넣지 않았다 (아래 명령으로 손으로)" ;;
         *)       em="-" ;;
      esac
      echo "- 시작 런 ${F_RUN:-?} · 첫 주입 런 ${INJ_RUN:-없음} · 끝 런 ${END_RUN:-$(hb_run)} ($em) · 주입 $INJ 회"
      echo "- ${DB_MSG:-표시하지 않았다}"
      [ -n "$DB_VERIFY" ] && echo "- $DB_VERIFY"
      if [ -n "$DB_PEND_SQL" ]; then
         echo "- ★ 끝 런 $END_RUN 은 rcterm 이 런을 닫으며 onlbit 를 다시 쓴다. rcterm 이 끝난 뒤(phase=ended) 손으로 :"
         echo; echo '```'; echo "$DB_PEND_SQL"; echo '```'
      fi
      if [ -s "$LOGDIR/db-mark.tsv" ]; then
         echo
         echo "| 런 | onlbit 전 | 후 | runlog (전) |"; echo "|---|---|---|---|"
         tail -n +2 "$LOGDIR/db-mark.tsv" | awk -F '\t' '{ printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }'
      elif [ "$MARKDB" = 0 ] && [ -n "$DB_SQL" ]; then
         echo; echo '```'; printf 'sqlite3 %s ".backup %s/runcatalog.db.bak-$(date +%%Y%%m%%d%%H%%M%%S)-drill" && sqlite3 %s "%s"\n' "$DBFILE" "$DBBAK_DIR" "$DBFILE" "$DB_SQL"; echo '```'
      fi
   else
      echo "- 드릴 플래그를 잡지 않았다 (dry-run · 전제 실패) -- runcatalog 무접촉"
   fi
} > "$LOGDIR/report.md"
}
# =====================================================================
#  실행
# =====================================================================
if [ "$DRY" -eq 1 ]; then
   for s in $STEPS; do log "[계획] 단계 $s : $(plan_line "$s")"; done
   s0 >/dev/null; pre=$?; log "[계획] 전제 : $(tail -1 "$RES" | cut -f5,6)"
   [ -e "$DRILL_FLAG" ] && log "[DRY] 드릴 플래그가 이미 있다 ($DRILL_FLAG, pid $(sed -n 's/^pid=//p' "$DRILL_FLAG" 2>/dev/null | head -1)) -- 실제로 돌리면 살아 있는 것이면 멈추고 죽은 것이면 지운다"
   log "[DRY] 주입 0 회. 드릴 플래그·runcatalog 무접촉. 아무것도 하지 않았다."
   [ "$pre" -eq 0 ] && exit 0
   log "[DRY] 전제가 충족되지 않아 지금은 드릴을 돌릴 수 없다 (rc 1)"
   exit 1
fi

PREOK=1
for s in $STEPS; do
   if [ "$s" = 0 ]; then { s0 && flag_take; } || PREOK=0; continue; fi
   if [ "$PREOK" = 0 ]; then
      record "$s" "$(name_of "$s")" - - "전제 실패로 하지 않았다" SKIP ""; continue
   fi
   [ "$s" = 9 ] && [ "$NETWENT" = 0 ] && { record 9 망복귀 - - "2 단계를 안 했다" SKIP ""; continue; }
   "s$s"
done

mark_db
write_report
log "끝 : PASS $(cut -f6 "$RES" | grep -c '^PASS$') · FAIL $NFAIL · SKIP $(cut -f6 "$RES" | grep -c '^SKIP$') -> $LOGDIR/report.md"
[ "$NFAIL" -eq 0 ] && [ -z "$ABORTED" ] && exit 0
exit 1
