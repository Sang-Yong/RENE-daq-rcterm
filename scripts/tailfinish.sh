#!/usr/bin/env bash
# =====================================================================
#  tailfinish.sh - 비정상으로 끝난 런의 꼬리를 사람 없이 마감한다.
#
#  왜 필요한가
#    런이 비정상 종료(kill -9 · exit 2 · USB 이탈 · 정전)하면 postrun --follow 는
#    heartbeat 의 새 런으로 넘어가 버리고, 직전 런의 꼬리(lag 3 개 + 잘린 마지막
#    파일)는 아무도 처리하지 않는다. 그 런은 PRD 개수 != FADC 개수 로 남아
#       - dataflow 의 is_processed() 를 영영 통과하지 못하고 /Data_ssd 에 붙박이
#       - websummary 게이트가 '후처리 미완' 으로 그 뒤 런까지 전부 막는다
#    (2026-11-06 run 4434 : FADC 13 / PRD 3 인 채 10 시간 정지).
#    지금까지는 사람이 postrun --from/--to · runcheck --fix · badrun --quarantine 을
#    손으로 했다 (CLAUDE.md 11.220 · 11.225 · 11.227). 그것을 대신한다.
#
#  대상 런 (전부 읽기 전용으로 판정한다)
#    a) 지금 수집 중이 아니다 -- heartbeat 의 run 이 아니거나, phase=ended 이거나,
#       heartbeat 가 오래됐다(정전·kill -9 뒤의 붙박이 heartbeat)
#    b) 최상위 FADC 개수 > PRD 개수, FADC >= 2   (부팅 실패 잔재는 dataflow 가 옮긴다)
#    c) 최근 quiet 초(기본 600) 안에 FADC·SADC·Merged·PRD 어느 것도 바뀌지 않았다
#       -- postrun --follow 가 '런 전환 -> 이전 런 마무리' 를 하는 중일 수 있다
#    d) 런당 시도 상한(기본 2 회)과 재시도 간격(기본 60 분)
#    e) 멈춤 파일(chainwatch.hold)이 없다
#    f) 그 런을 손으로 처리하는 postrun · runcheck · badrun · merge 가 없다 (ps 로 본다)
#
#  하는 일 (런 하나)
#    1) badrun.sh --quarantine --run R   ROOT 로 안 열리는 원시 파일과, 꼬리 서브런의
#                                        '열리지만 사건 0' 짝(run 4392)을 badrun/ 으로
#    2) carry 확보      첫 결손 서브런의 직전 merge 로그에 carry 가 없으면, carry 가 있는
#                       곳까지 거슬러 올라가 merge 를 임시 디렉터리에서 다시 돌려 carry 를
#                       뽑아 merge 로그로 남긴다 (CLAUDE.md 11.136 · 매크로는 결정적, 11.64).
#                       ★ 임시 디렉터리에는 원시 파일의 심볼릭 링크만 둔다 -- 이미 있는
#                         Merged/PRD 를 덮지 않는다. 다 쓰면 지운다
#                       ★ carry 를 끝내 못 구하면 postrun 을 부르지 않는다. 0 으로 시작하면
#                         개수는 맞는데 내용이 조용히 부족할 수 있다 (11.68)
#    3) postrun.sh R --from <첫 결손> --to <마지막 FADC> --heartbeat /dev/null
#    4) runcheck.sh --run R --heartbeat /dev/null --fix
#    5) FADC == PRD 면 tail_finish (책임자), 상한까지 못 채우면 tail_finish_failed 1 회
#
#  사용
#    tailfinish.sh --status               읽기 전용. 대상 런과 시도 상태
#    tailfinish.sh --dry-run [--run R]     아무것도 안 바꾸고 대상과 명령만
#    tailfinish.sh [--params F]            대상이 있으면 뒤에서 처리를 띄우고 곧 돌아온다
#                                          (chainwatch 가 5 분마다 부른다, chain_tailfinish = 1)
#    tailfinish.sh --run R --foreground   한 런만 지금 이 자리에서
#    --force                              시도 상한·재시도 간격을 무시 (quiet·수집 중 판정은 그대로)
#
#  ★ 알림이 실패해도, 대상이 없어도 종료코드 0. 감시 사슬이 이것 때문에 넘어지면 안 된다.
# =====================================================================
set -u

DIR=$(cd "$(dirname "$0")/.." && pwd)
SELF=$DIR/scripts/tailfinish.sh
PARAMS=$DIR/config/notify.params

#  바깥 명령 -- 시험은 전부 가짜로 갈아끼운다
POSTRUN=${TAILFINISH_POSTRUN:-$DIR/scripts/postrun.sh}
RUNCHECK=${TAILFINISH_RUNCHECK:-$DIR/scripts/runcheck.sh}
BADRUN=${TAILFINISH_BADRUN:-$DIR/scripts/badrun.sh}
NOTIFY=${TAILFINISH_NOTIFY:-$DIR/scripts/daq-notify.sh}
MERGE_CMD=${TAILFINISH_MERGE:-}          # 비면 ROOT 로 진짜 merge 매크로. 시험은 가짜
PS_FILE=${TAILFINISH_PS:-}               # 'pid args' 줄. 비면 진짜 ps

STATE=${TAILFINISH_STATE:-/Data_ssd/LOG/tailfinish.state}
LOG=${TAILFINISH_LOG:-/Data_ssd/LOG/tailfinish.log}
RUNLOGDIR=${TAILFINISH_RUNLOGDIR:-/Data_ssd/LOG/tailfinish}
TMPROOT=${TAILFINISH_TMPROOT:-/Data_ssd/LOG/tailfinish.tmp}
LOCKDIR=${TAILFINISH_LOCKDIR:-/tmp}

RAWROOT=/Data_ssd/RAW
HB=/Data/LOG/rcterm.hb
HOLD=/Data_ssd/LOG/chainwatch.hold
PRODDIR=/home/frontend/DAQ/DAQ_cup/production
LOGFALLBACK=/scratch/LOG
QUIET=600            # 최근 이만큼[초] 안에 바뀐 파일이 있으면 손대지 않는다
MAXTRY=2             # 런당 시도 상한
RETRY_MIN=60         # 시도 사이 간격 [분]
JOBS=2               # postrun production 병렬
HB_MAX_AGE=120       # heartbeat 가 이보다 오래되면 '수집 중이 아니다'
CARRY_BACK=30        # carry 를 찾으러 거슬러 올라갈 서브런 상한
MERGE_MACRO=merge_FADC_SADC_v3_5v.cc

load_params() {
   local f=$1 line k v
   [ -r "$f" ] || return 0
   while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      case "$line" in *=*) ;; *) continue ;; esac
      k=${line%%=*}; v=${line#*=}
      k=$(printf '%s' "$k" | tr -d ' \t' | tr 'A-Z-' 'a-z_')
      v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      case "$k" in
         heartbeat)            HB=$v ;;
         chain_hold_file)      HOLD=$v ;;
         chain_hb_max_age)     HB_MAX_AGE=$v ;;
         tail_rawroot)         RAWROOT=$v ;;
         tail_quiet_sec)       QUIET=$v ;;
         tail_max_try)         MAXTRY=$v ;;
         tail_retry_min)       RETRY_MIN=$v ;;
         tail_jobs)            JOBS=$v ;;
         tail_log_fallback)    LOGFALLBACK=$v ;;
         tail_prod_dir)        PRODDIR=$v ;;
         tail_carry_back)      CARRY_BACK=$v ;;
      esac
   done < "$f"
}

#  params 를 먼저 읽고 CLI 가 덮어쓴다 (chainwatch 와 같은 규칙)
for i in $(seq 1 $#); do
   eval "a=\${$i}"
   if [ "$a" = "--params" ]; then j=$(( i + 1 )); eval "PARAMS=\${$j:-$PARAMS}"; fi
done
load_params "$PARAMS"
#  시험용 : params 보다 이긴다
[ -n "${TAILFINISH_RAWROOT:-}" ]  && RAWROOT=$TAILFINISH_RAWROOT
[ -n "${TAILFINISH_HB:-}" ]       && HB=$TAILFINISH_HB
[ -n "${TAILFINISH_HOLD:-}" ]     && HOLD=$TAILFINISH_HOLD
[ -n "${TAILFINISH_PRODDIR:-}" ]  && PRODDIR=$TAILFINISH_PRODDIR

MODE=launch; ONLYRUN=""; FORCE=0; DRY=0
while [ $# -gt 0 ]; do
   case "$1" in
      --params)     shift 2 ;;
      --status)     MODE=status; shift ;;
      --dry-run)    DRY=1; shift ;;
      --foreground) MODE=work; shift ;;
      --run)        ONLYRUN=$((10#$2)); shift 2 ;;
      --force)      FORCE=1; shift ;;
      --quiet-sec)  QUIET=$2; shift 2 ;;
      -h|--help)    sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) echo "모르는 옵션 : $1" >&2; exit 0 ;;
   esac
done

LOGDIR=$PRODDIR/LOG
MERGEDIR=$LOGDIR/Merge_log
CODEDIR=$PRODDIR/Code

ts()  { date '+%F %T'; }
log() { [ "$DRY" -eq 1 ] && return 0; printf '%s %s\n' "$(ts)" "$*" >> "$LOG" 2>/dev/null; return 0; }
say() { printf '%s\n' "$*"; }

st_get() { [ -r "$STATE" ] && sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -1; }
st_set() {
   [ "$DRY" -eq 1 ] && return 0
   local k=$1 v=$2 tmp
   tmp=$(mktemp "${STATE}.XXXXXX" 2>/dev/null) || return 0
   { [ -r "$STATE" ] && grep -v "^$k=" "$STATE" 2>/dev/null; echo "$k=$v"; } > "$tmp" 2>/dev/null
   mv -f "$tmp" "$STATE" 2>/dev/null || rm -f "$tmp"
   return 0
}

# ---- 수집 중인 런 -----------------------------------------------------
hb_field() { sed -n "s/^$1=//p" "$HB" 2>/dev/null | head -1; }
acquiring_run() {        # 지금 수집 중인 런 번호를 찍는다. 없으면 아무것도 안 찍는다
   [ -r "$HB" ] || return 0
   local r ph t age
   r=$(hb_field run); ph=$(hb_field phase); t=$(hb_field time)
   [ -n "$t" ] || t=$(stat -c %Y "$HB" 2>/dev/null || echo 0)
   age=$(( $(date +%s) - ${t:-0} ))
   [ -n "$r" ] || return 0
   [ "$ph" = ended ] && return 0
   [ "$age" -gt "$HB_MAX_AGE" ] && return 0
   echo $((10#$r))
}

# ---- 그 런을 손으로 처리하는 것이 있는가 ----------------------------------
#  ★ pgrep -f 를 쓰지 않는다 (CLAUDE.md 10). ps 의 args 에서 나와 조상을 빼고 본다.
ps_lines() { if [ -n "$PS_FILE" ]; then cat "$PS_FILE" 2>/dev/null; else ps -eo pid=,args= 2>/dev/null; fi; }
someone_on_run() {       # run_num
   local rn=$1 rp mine=" $$ $PPID " p=$PPID i
   rp=$(printf '%06d' "$rn")
   for i in 1 2 3 4 5 6 7 8; do
      p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
      { [ -n "$p" ] && [ "$p" != 0 ]; } || break
      mine="$mine$p "
   done
   ps_lines | while read -r pid args; do
      case "$mine" in *" $pid "*) continue ;; esac
      printf '%s\n' "$args"
   done | grep -Eq "(postrun|runcheck|badrun)\.sh( .*)? (--run[= ]?)?0*${rn}( |,|$)|merge_FADC_SADC[^ ]*\.cc\(${rn},|production_from_merged[^ ]*\(${rn},|production_from_merged[^ ]*\.sh ${rp} "
}

# ---- 개수 ---------------------------------------------------------------
n_fadc() { ls -U "$1" 2>/dev/null | grep -c "^FADC_$2\.root\.[0-9]*$"; }
n_prd()  { ls -U "$1/PRD" 2>/dev/null | grep -c "^PRD_$2\.[0-9]*\.root$"; }
max_fadc() { ls -U "$1" 2>/dev/null | sed -n "s/^FADC_$2\.root\.\([0-9]*\)$/\1/p" | sort -n | tail -1; }
sub_done() {             # dd rp sub(10진)  -- postrun 의 subrun_done 과 같은 뜻
   local s; s=$(printf '%05d' "$3")
   [ -s "$1/Merged/MERGED_$2.root.$s" ] && [ -s "$1/PRD/PRD_$2.$s.root" ]
}
recent_change() {        # dd  -> 최근 QUIET 초 안에 바뀐 것이 있으면 0
   local dd=$1 m
   m=$(( (QUIET + 59) / 60 ))
   [ -n "$(find "$dd" "$dd/Merged" "$dd/PRD" -maxdepth 1 -type f -mmin "-$m" -print -quit 2>/dev/null)" ]
}

# ---- 대상 판정 ---------------------------------------------------------
#  결과 : 'run<TAB>사유' 줄. 대상이면 사유가 TARGET, 아니면 건너뛴 사유
WHY=""
judge() {                # run_num  -> 0 대상 / 1 아님 (WHY 에 사유)
   local rn=$1 rp dd nf np cur t last
   rp=$(printf '%06d' "$rn"); dd="$RAWROOT/$rp"
   [ -d "$dd" ] || { WHY="런 디렉터리 없음"; return 1; }
   cur=$(acquiring_run)
   [ -n "$cur" ] && [ "$cur" -eq "$rn" ] && { WHY="수집 중 (heartbeat)"; return 1; }
   nf=$(n_fadc "$dd" "$rp"); np=$(n_prd "$dd" "$rp")
   [ "$nf" -ge 2 ] || { WHY="FADC $nf 개 (부팅 실패 잔재는 dataflow 몫)"; return 1; }
   [ "$nf" -gt "$np" ] || { WHY="완결 (FADC $nf = PRD $np)"; return 1; }
   if [ "$FORCE" -eq 0 ]; then
      if [ -n "$(st_get "gaveup_$rn")" ]; then WHY="포기함 (시도 상한, 실패 알림 보냄) -- --force 로 다시"; return 1; fi
      t=$(st_get "try_$rn"); t=${t:-0}
      [ "$t" -ge "$MAXTRY" ] && { WHY="시도 상한 $t/$MAXTRY"; return 1; }
      last=$(st_get "last_$rn"); last=${last:-0}
      if [ "$t" -gt 0 ] && [ $(( $(date +%s) - last )) -lt $(( RETRY_MIN * 60 )) ]; then
         WHY="재시도 대기 (시도 $t/$MAXTRY, ${RETRY_MIN}분 간격)"; return 1
      fi
   fi
   recent_change "$dd" && { WHY="최근 ${QUIET}초 안에 바뀐 파일이 있다 (postrun 이 마무리 중일 수 있다)"; return 1; }
   someone_on_run "$rn" && { WHY="이 런을 처리하는 프로세스가 있다 (손 작업?)"; return 1; }
   WHY="대상 : FADC $nf / PRD $np"
   return 0
}

list_runs() {
   if [ -n "$ONLYRUN" ]; then echo "$ONLYRUN"; return 0; fi
   ls -1U "$RAWROOT" 2>/dev/null | grep -E '^[0-9]{6}$' | sed 's/^0*//' | sort -n
}

# ---- carry ---------------------------------------------------------------
#  postrun 의 find_prevlog 와 같은 자리를 같은 순서로 본다
find_mlog() {            # run_num subrun -> 경로
   local base f d
   for base in "log_merge_FADC_SADC_v3_5v_run${1}_subrun${2}.txt" "log_merge_FADC_SADC_run${1}_subrun${2}.txt"; do
      f="$MERGEDIR/$base"; [ -f "$f" ] && { echo "$f"; return 0; }
      for d in $(ls -dU "$MERGEDIR".old* 2>/dev/null | sort -r); do
         [ -f "$d/$base" ] && { echo "$d/$base"; return 0; }
      done
      f="$LOGDIR/$base"; [ -f "$f" ] && { echo "$f"; return 0; }
      [ -n "$LOGFALLBACK" ] && [ -f "$LOGFALLBACK/$base" ] && { echo "$LOGFALLBACK/$base"; return 0; }
   done
   return 1
}
C_S=""; C_E=""; C_T=""
read_carry() {           # 파일 -> C_S C_E C_T, 셋 다 있으면 0
   C_S=$(grep -m1 "final SADC "              "$1" 2>/dev/null | awk '{print $4}')
   C_E=$(grep -m1 "final SADC_evt"           "$1" 2>/dev/null | awk '{print $4}')
   C_T=$(grep -m1 "final before_SADC_trgnum" "$1" 2>/dev/null | awk '{print $4}')
   [ -n "$C_S" ] && [ -n "$C_E" ] && [ -n "$C_T" ]
}
has_carry() { local f; f=$(find_mlog "$1" "$2") && read_carry "$f"; }

run_merge() {            # rn maxarg sub S E T datadir  (출력은 stdout)
   if [ -n "$MERGE_CMD" ]; then "$MERGE_CMD" "$@"; return $?; fi
   ( cd "$CODEDIR" && nice -n 15 root -l -b -q "$MERGE_MACRO($1,$2,$3,$4,$5,$6,\"$7\")" )
}

#  서브런 m 의 merge 에 쓸 carry(= m-1 의 merge 로그) 가 없으면 만든다
ensure_carry() {         # rn rp dd m maxarg   -> 0 이면 m-1 의 로그에 carry 가 있다
   local rn=$1 rp=$2 dd=$3 m=$4 maxarg=$5 j start s e t tdir f out base dst
   [ "$m" -le 0 ] && return 0
   has_carry "$rn" "$(( m - 1 ))" && return 0
   #  거슬러 올라가 출발점 j 를 찾는다 : j == 0 이거나 j-1 의 로그에 carry 가 있다
   start=""
   for (( j = m - 1; j >= 0 && j >= m - CARRY_BACK; j-- )); do
      if [ "$j" -eq 0 ]; then start=0; s=0; e=0; t=0; break; fi
      if has_carry "$rn" "$(( j - 1 ))"; then start=$j; s=$C_S; e=$C_E; t=$C_T; break; fi
   done
   if [ -z "$start" ]; then
      say "  carry : 서브런 $((m-1)) 부터 ${CARRY_BACK} 개 거슬러 올라가도 carry 가 있는 로그가 없다 -- 손대지 않는다 (11.68)"
      return 1
   fi
   say "  carry : 서브런 $((m-1)) 의 merge 로그에 carry 가 없다 -> 서브런 $start (carry $s,$e,$t) 부터 $((m-1)) 까지 임시 디렉터리에서 merge 를 다시 돌린다"
   [ "$DRY" -eq 1 ] && return 0
   mkdir -p "$TMPROOT" 2>/dev/null
   tdir=$(mktemp -d "$TMPROOT/$rp.XXXXXX" 2>/dev/null) || { say "  carry : 임시 디렉터리를 못 만든다 ($TMPROOT)"; return 1; }
   mkdir -p "$tdir/Merged"
   for f in "$dd"/FADC_"$rp".root.* "$dd"/SADC_"$rp".root.*; do [ -f "$f" ] && ln -s "$f" "$tdir/"; done
   out="$tdir/merge.out"
   for (( j = start; j <= m - 1; j++ )); do
      : > "$out"
      if ! run_merge "$rn" "$maxarg" "$j" "$s" "$e" "$t" "$tdir" > "$out" 2>&1 || ! read_carry "$out"; then
         say "  carry : 서브런 $j 의 merge 를 다시 돌렸으나 carry 가 안 나온다"
         tail -5 "$out" 2>/dev/null | sed 's/^/      /'
         rm -rf "$tdir"; return 1
      fi
      s=$C_S; e=$C_E; t=$C_T
      rm -f "$tdir"/Merged/* 2>/dev/null          # 80~440 MB 짜리라 하나씩 지운다
   done
   base="log_merge_FADC_SADC_v3_5v_run${rn}_subrun$(( m - 1 )).txt"
   dst="$MERGEDIR/$base"
   mkdir -p "$MERGEDIR" 2>/dev/null
   #  carry 없는 로그가 그 자리에 있으면 옆으로 비킨다 (같은 파일시스템 rename). carry 있는 로그는 절대 안 건드린다
   if [ -f "$dst" ] && ! read_carry "$dst"; then mv -f "$dst" "$dst.nocarry.$(date +%Y%m%d%H%M%S)" 2>/dev/null; fi
   if { printf '# tailfinish.sh 가 서브런 %s..%s 를 다시 merge 해 남긴 carry (%s)\n' "$start" "$((m-1))" "$(ts)"; cat "$out"; } > "$dst" 2>/dev/null \
      && read_carry "$dst"; then
      say "  carry : $dst 에 남겼다 ($C_S,$C_E,$C_T)"
      rm -rf "$tdir"; return 0
   fi
   say "  carry : merge 로그를 쓰지 못했다 ($dst)"
   rm -rf "$tdir"; return 1
}

# ---- 런 하나 마감 --------------------------------------------------------
notify() {               # 사건 런 사유 [상세파일]
   local ev=$1 rn=$2 msg=$3 det=${4:-}
   if [ "$DRY" -eq 1 ]; then say "  [DRY] $NOTIFY $ev --run $rn --msg '$msg'"; return 0; fi
   if [ -n "$det" ] && [ -r "$det" ]; then
      "$NOTIFY" --params "$PARAMS" "$ev" --run "$rn" --msg "$msg" --detail-file "$det" >/dev/null 2>&1 || log "WARN 알림을 보내지 못했다 ($ev run $rn)"
   else
      "$NOTIFY" --params "$PARAMS" "$ev" --run "$rn" --msg "$msg" >/dev/null 2>&1 || log "WARN 알림을 보내지 못했다 ($ev run $rn)"
   fi
   return 0
}

finish_run() {           # run_num  (대상 판정을 통과한 뒤)
   local rn=$1 rp dd nf0 np0 nf np mx first n try rlog rc1 rc2 why=""
   rp=$(printf '%06d' "$rn"); dd="$RAWROOT/$rp"
   nf0=$(n_fadc "$dd" "$rp"); np0=$(n_prd "$dd" "$rp")
   try=$(st_get "try_$rn"); try=$(( ${try:-0} + 1 ))

   if [ "$DRY" -eq 1 ]; then
      say "run $rn : FADC $nf0 / PRD $np0 -- 시도 $try/$MAXTRY 가 될 것"
      say "  1) BADRUN_HB=/dev/null $BADRUN --quarantine --run $rn --dry-run :"
      BADRUN_HB=/dev/null BADRUN_ROOTS="$RAWROOT" "$BADRUN" --quarantine --run "$rn" --dry-run 2>&1 | sed 's/^/     /'
   else
      #  시도는 시작 전에 센다 -- 처리 도중 죽어도 상한이 먹는다
      st_set "try_$rn" "$try"; st_set "last_$rn" "$(date +%s)"
      mkdir -p "$RUNLOGDIR" 2>/dev/null
      rlog="$RUNLOGDIR/$rp-$(date +%Y%m%d%H%M%S).log"
      exec 3>&1 4>&2
      exec >> "$rlog" 2>&1
      say "== $(ts) tailfinish run $rn 시도 $try/$MAXTRY : FADC $nf0 / PRD $np0 =="
      log "run $rn 시작 (시도 $try/$MAXTRY, FADC $nf0 / PRD $np0) -> $rlog"
      say "-- 1) badrun 격리 --"
      BADRUN_HB=/dev/null BADRUN_ROOTS="$RAWROOT" "$BADRUN" --quarantine --run "$rn"
   fi

   nf=$(n_fadc "$dd" "$rp"); mx=$(max_fadc "$dd" "$rp")
   if [ -z "$mx" ]; then why="격리 뒤 FADC 가 남지 않았다"; fi
   first=""
   if [ -z "$why" ]; then
      mx=$((10#$mx))
      for (( n = 0; n <= mx; n++ )); do
         [ -f "$dd/FADC_$rp.root.$(printf '%05d' "$n")" ] || continue
         sub_done "$dd" "$rp" "$n" || { first=$n; break; }
      done
   fi

   if [ -z "$why" ] && [ -n "$first" ]; then
      say "-- 2) carry (첫 결손 서브런 $first) --"
      #  첫 결손 뒤에 '끝난 서브런 -> 결손' 경계가 또 있으면 그 경계마다 carry 가 필요하다
      local m prev_done=0 cok=1
      for (( m = first; m <= mx; m++ )); do
         [ -f "$dd/FADC_$rp.root.$(printf '%05d' "$m")" ] || { prev_done=0; continue; }
         if sub_done "$dd" "$rp" "$m"; then prev_done=1; continue; fi
         if [ "$m" -eq "$first" ] || [ "$prev_done" -eq 1 ]; then
            ensure_carry "$rn" "$rp" "$dd" "$m" "$mx" || { cok=0; break; }
         fi
         prev_done=0
      done
      if [ "$cok" -eq 0 ]; then
         why="carry 를 구하지 못했다 (merge 로그 없음). postrun 을 부르지 않았다 -- carry 0 으로 시작하면 내용이 조용히 부족해진다 (CLAUDE.md 11.68)"
      elif [ "$DRY" -eq 1 ]; then
         say "  3) $POSTRUN $rn --from $first --to $mx --heartbeat /dev/null --rawroot $RAWROOT --log-fallback $LOGFALLBACK --jobs $JOBS"
         say "  4) $RUNCHECK --run $rn --heartbeat /dev/null --fix --roots $RAWROOT --log-fallback $LOGFALLBACK"
      else
         say "-- 3) postrun --from $first --to $mx --"
         "$POSTRUN" "$rn" --from "$first" --to "$mx" --heartbeat /dev/null --rawroot "$RAWROOT" \
            --log-fallback "$LOGFALLBACK" --jobs "$JOBS" --prod-dir "$PRODDIR"; rc1=$?
         say "   postrun rc=$rc1"
         say "-- 4) runcheck --fix --"
         "$RUNCHECK" --run "$rn" --heartbeat /dev/null --fix --roots "$RAWROOT" --log-fallback "$LOGFALLBACK" --prod-dir "$PRODDIR"; rc2=$?
         say "   runcheck rc=$rc2"
      fi
   fi
   if [ "$DRY" -eq 1 ]; then
      [ -n "$why" ] && say "  ★ $why"
      [ -z "$why" ] && [ -z "$first" ] && say "  (결손 서브런 없음 -- 격리만으로 완결될 것, postrun 불필요)"
      return 0
   fi

   nf=$(n_fadc "$dd" "$rp"); np=$(n_prd "$dd" "$rp")
   say "-- 결과 : FADC $nf / PRD $np --"
   exec 1>&3 2>&4 3>&- 4>&-
   #  메일 본문에 실을 상세 : 마지막 60 줄, 색 코드 뺀 것
   local det="$rlog.mail"
   tail -60 "$rlog" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' > "$det" 2>/dev/null || det=""
   if [ -z "$why" ] && [ "$nf" -gt 0 ] && [ "$nf" -eq "$np" ]; then
      st_set "done_$rn" "$(date +%s)"
      log "run $rn 완결 (FADC $nf = PRD $np, 처음 FADC $nf0 / PRD $np0)"
      notify tail_finish "$rn" "꼬리 자동 마감 : FADC $nf = PRD $np (처음 FADC $nf0 / PRD $np0, 시도 $try)" "$det"
      rm -f "$det"
      return 0
   fi
   [ -n "$why" ] || why="FADC $nf / PRD $np 로 아직 비었다 (로그 $rlog)"
   log "run $rn 미완 (시도 $try/$MAXTRY) : $why"
   if [ "$try" -ge "$MAXTRY" ]; then
      st_set "gaveup_$rn" "$(date +%s)"
      notify tail_finish_failed "$rn" "꼬리 자동 마감 실패 (시도 $try/$MAXTRY) : $why" "$det"
   fi
   rm -f "$det"
   return 0
}

# ---- 상태 -----------------------------------------------------------------
if [ "$MODE" = status ]; then
   DRY=1
   echo "tailfinish 상태  $(ts)"
   echo "  문턱 : quiet ${QUIET}s · 시도 상한 $MAXTRY · 재시도 ${RETRY_MIN}분 · rawroot $RAWROOT"
   [ -e "$HOLD" ] && echo "  ★ 멈춤 파일 : $HOLD -- 아무것도 처리하지 않는다"
   cur=$(acquiring_run); echo "  수집 중 : ${cur:-없음}"
   [ -d "$LOGDIR" ] || echo "  ★ 로그 루트 없음 : $LOGDIR (/scratch 빠짐?) -- 처리하지 않는다"
   for r in $(list_runs); do
      rp=$(printf '%06d' "$r"); dd="$RAWROOT/$rp"
      nf=$(n_fadc "$dd" "$rp"); np=$(n_prd "$dd" "$rp")
      [ "$nf" -gt "$np" ] || [ -n "$ONLYRUN" ] || continue
      judge "$r"; j=$?
      printf '  run %-6s FADC %-5s PRD %-5s 시도 %s  %s%s\n' "$r" "$nf" "$np" "$(st_get "try_$r" | grep . || echo 0)" \
         "$([ $j -eq 0 ] && echo '★ ')" "$WHY"
   done
   exit 0
fi

# ---- 공통 가드 ----------------------------------------------------------------
if [ -e "$HOLD" ]; then
   [ "$DRY" -eq 1 ] && say "멈춤 파일이 있다 ($HOLD) -- 처리하지 않는다"
   exit 0
fi
if [ ! -d "$LOGDIR" ]; then
   #  postrun 은 로그 루트가 없으면 곧바로 죽는다 (/scratch 가 빠지면 그렇다). 시도를 세지 않고 다음 회차로
   say "로그 루트가 없다 ($LOGDIR) -- /scratch 가 빠졌나? 처리하지 않는다"
   exit 0
fi

GLOCK="$LOCKDIR/.tailfinish.lock"

if [ "$MODE" = launch ] && [ "$DRY" -eq 0 ]; then
   #  일꾼이 이미 돌고 있으면 아무것도 안 한다
   exec 8>"$GLOCK" 2>/dev/null || exit 0
   flock -n 8 2>/dev/null || exit 0
   found=""
   for r in $(list_runs); do judge "$r" && { found=$r; break; }; done
   flock -u 8 2>/dev/null; exec 8>&-
   [ -n "$found" ] || exit 0
   log "대상 run $found 발견 -- 뒤에서 처리를 띄운다"
   args=(--params "$PARAMS" --foreground)
   [ -n "$ONLYRUN" ] && args+=(--run "$ONLYRUN")
   [ "$FORCE" -eq 1 ] && args+=(--force)
   #  부른 쪽의 잠금(chainwatch fd 9 등)을 일꾼에 물려주지 않는다 (CLAUDE.md 11.228 의 고아 잠금)
   setsid nohup bash "$SELF" "${args[@]}" >> "$LOG" 2>&1 < /dev/null 9>&- 8>&- 7>&- &
   exit 0
fi

#  일꾼 (또는 --dry-run)
if [ "$DRY" -eq 0 ]; then
   exec 8>"$GLOCK" 2>/dev/null || exit 0
   flock -n 8 2>/dev/null || { log "다른 일꾼이 돌고 있다. 건너뛴다"; exit 0; }
fi
#  ROOT 환경 (cron 에는 없다 -- CLAUDE.md 10). postrun 은 스스로 잡지만 badrun · runcheck 는 아니다.
#  --dry-run 의 badrun --dry-run 도 ROOT 로 파일을 열어 봐야 무엇을 격리할지 보인다 (읽기만 한다)
if ! command -v root >/dev/null 2>&1; then
   [ -f /usr/local/bin/thisroot.sh ] && . /usr/local/bin/thisroot.sh >/dev/null 2>&1
fi
if [ -z "${ONLDAQ_DIR:-}" ] && [ -f /home/frontend/DAQ/DAQ_cup/cupdaq_env.sh ]; then
   . /home/frontend/DAQ/DAQ_cup/cupdaq_env.sh >/dev/null 2>&1
fi

any=0
for r in $(list_runs); do
   if judge "$r"; then
      any=1
      [ "$DRY" -eq 1 ] && say "run $r : $WHY"
      exec 7>"$LOCKDIR/.tailfinish.$(printf '%06d' "$r").lock" 2>/dev/null || continue
      if flock -n 7 2>/dev/null; then
         finish_run "$r"
         flock -u 7 2>/dev/null
      else
         say "run $r : 다른 tailfinish 가 잡고 있다"
      fi
      exec 7>&-
      [ -e "$HOLD" ] && { log "멈춤 파일이 생겼다 -- 남은 런은 다음 회차로"; break; }
   elif [ "$DRY" -eq 1 ] && [ -n "$ONLYRUN" ]; then
      say "run $r : 대상 아님 -- $WHY"
   fi
done
[ "$DRY" -eq 1 ] && [ "$any" -eq 0 ] && say "대상 런 없음"
exit 0
