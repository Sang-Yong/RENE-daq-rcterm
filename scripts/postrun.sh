#!/usr/bin/env bash
# =====================================================================
#  postrun.sh - DAQ 수집 뒤에 붙는 merge + production 파이프라인 드라이버
#
#  DAQ_cup/production 의 merge_FADC_SADC_v3_5v.cc 와
#  production_from_merged_v3_5v.cc 를 그대로 호출한다.
#  물리 코드는 한 줄도 복제하지 않는다. 이 스크립트가 하는 일은 세 가지다:
#    1) 어떤 서브런을 처리해도 안전한지 판단하고 (수집 중인 파일은 건드리지 않음)
#    2) merge 를 직렬로 돌리며 SADC 위치 상태를 다음 서브런에 넘기고
#    3) production 을 병렬로 돌린다
#
#  왜 이렇게 나누는가 (실측 33,357 서브런, run 4238/4239/4240):
#      merge      28초  <- SADC 위치를 다음 서브런에 넘기므로 직렬일 수밖에 없다
#      production 15초  <- 서브런마다 완전 독립. 병렬 가능
#      합계       43초  <- 서브런 1개가 60초 분량이니 여유 28%
#  production 을 병렬로 빼면 임계경로가 merge 28초로 내려가 여유가 2.1배가 된다.
#  경합이 생기면 43초가 86초까지 늘어지는 것을 실측했으므로(run 4287),
#  이 여유는 선택이 아니라 필수다.
#
#  사용 :
#    postrun.sh --follow              수집을 뒤따라가며 계속 처리 (기본)
#    postrun.sh 4288                  run 4288 을 한 번만 처리
#    postrun.sh 4288 --from 100 --to 200
#    postrun.sh --follow --jobs 4 --lag 3
#
#  기존 로그 파일명을 그대로 쓰므로 production/Shell/audit_run.sh 가
#  이 스크립트의 결과에도 그대로 동작한다.
# =====================================================================
set -u

# ---- 기본값 ---------------------------------------------------------
PRODDIR=${POSTRUN_PRODDIR:-/home/frontend/DAQ/DAQ_cup/production}
RAWROOT=${POSTRUN_RAWROOT:-/scratch/RAW}
# 산출물(Merged/PRD)을 RAW 와 다른 저장소에 두고 싶을 때. 비우면 RAW 안에 만든다.
#  병목이 NFS I/O 이므로 로컬 디스크를 지정하면 눈에 띄게 빨라진다(실측 41초 -> 28초).
#  RAW 쪽에는 심볼릭 링크를 걸어 두므로 매크로와 기존 도구는 경로를 그대로 쓴다.
OUTROOT=${POSTRUN_OUTROOT:-}
HB=${POSTRUN_HEARTBEAT:-/Data/LOG/rcterm.hb}
JOBS=3                 # production 동시 실행 개수
# 기록 중인 서브런에서 몇 개 뒤까지만 손대는가.
#  3 = 실시간 수집보다 약 3분 뒤에서 따라간다(서브런 1개 = 1분).
#  이 여유가 필요한 이유:
#   - heartbeat 의 subrun 은 '지금 기록 중인' 파일이다. 그 파일은 아직 안 닫혔다.
#   - NFS 서버 시계가 로컬보다 약 28초 앞선다(실측). mtime 만으로는 완료를 못 믿는다.
#   - merger/DAQ 가 파일을 닫고 flush 하는 시간이 필요하다.
LAG=3
POLL=20                # --follow 에서 heartbeat 확인 주기 [초]
NICE=10                # 수집을 방해하지 않도록 낮은 우선순위
MAXRETRY=2             # 좀비 파일 재시도 (원본은 5회 x 60초 = 5분 낭비)
RETRY_WAIT=10
RUNARG=""; FOLLOW=0; FROM=-1; TO=-1; DRYRUN=0; ONCE=0

usage() {
   cat <<EOF
postrun.sh - DAQ 수집 뒤에 붙는 merge + production 파이프라인 드라이버

  DAQ_cup/production 의 merge_FADC_SADC_v3_5v.cc 와
  production_from_merged_v3_5v.cc 를 그대로 호출한다. 물리 코드는 복제하지 않는다.
  merge 는 직렬(SADC 위치를 다음 서브런에 넘겨야 한다), production 은 병렬.

사용
  postrun.sh --follow                 수집을 뒤따라가며 계속 처리
  postrun.sh 4288                     run 4288 을 한 번만 처리
  postrun.sh 4288 --from 100 --to 200
  postrun.sh --once --dry-run         지금 무엇을 처리할지만 확인

옵션
  --follow            heartbeat 를 읽어 수집을 뒤따라가며 계속 처리
  --once              --follow 없이 한 바퀴만 (추적 모드의 1회 실행)
  --jobs N            production 병렬 개수                (${JOBS})
  --lag N             기록 중인 서브런에서 N 개 뒤까지만  (${LAG})
                      3 이면 실시간 수집보다 약 3분 뒤를 따라간다
  --poll SEC          heartbeat 확인 주기                 (${POLL})
  --nice N            처리 프로세스 nice 값               (${NICE})
  --from N --to N     서브런 범위 지정 (일회 처리용)
  --max-retry N       좀비 파일 재시도 횟수               (${MAXRETRY})
  --prod-dir DIR      production 트리                     (${PRODDIR})
  --rawroot DIR       RAW 상위 디렉터리                   (${RAWROOT})
  --outroot DIR       Merged/PRD 를 여기에 두고 RAW 에는 심볼릭 링크를 건다.
                      병목이 NFS 이므로 로컬 디스크를 주면 빨라진다
                      (예: --outroot /Data_ssd/RAW)
  --heartbeat FILE    rcterm heartbeat                    (${HB})
  --dry-run           무엇을 할지만 출력
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
   case "$1" in
      --follow)     FOLLOW=1; shift ;;
      --once)       ONCE=1; shift ;;
      --jobs)       JOBS=$2; shift 2 ;;
      --lag)        LAG=$2; shift 2 ;;
      --poll)       POLL=$2; shift 2 ;;
      --nice)       NICE=$2; shift 2 ;;
      --from)       FROM=$2; shift 2 ;;
      --to)         TO=$2; shift 2 ;;
      --max-retry)  MAXRETRY=$2; shift 2 ;;
      --prod-dir)   PRODDIR=$2; shift 2 ;;
      --rawroot)    RAWROOT=$2; shift 2 ;;
      --outroot)    OUTROOT=$2; shift 2 ;;
      --heartbeat)  HB=$2; shift 2 ;;
      --dry-run)    DRYRUN=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      -*)           echo "unknown option : $1" >&2; usage; exit 1 ;;
      *)            RUNARG=$1; shift ;;
   esac
done

CODEDIR=$PRODDIR/Code
SHELLDIR=$PRODDIR/Shell
LOGDIR=$PRODDIR/LOG
MERGE_MACRO=merge_FADC_SADC_v3_5v.cc
PROD_SCRIPT=production_from_merged_v3_5v.sh

C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_C='\033[1;36m'; C_0='\033[0m'
log()  { printf '%s %b\n' "$(date '+%m-%d %H:%M:%S')" "$*"; }
die()  { log "${C_R}[FATAL]${C_0} $*"; exit 1; }

# ---- 사전 점검 ------------------------------------------------------
[ -d "$CODEDIR" ]  || die "Code 디렉터리 없음 : $CODEDIR"
[ -d "$SHELLDIR" ] || die "Shell 디렉터리 없음 : $SHELLDIR"
[ -f "$CODEDIR/$MERGE_MACRO" ]   || die "매크로 없음 : $CODEDIR/$MERGE_MACRO"
[ -x "$SHELLDIR/$PROD_SCRIPT" ]  || die "production 스크립트 없음 : $SHELLDIR/$PROD_SCRIPT"
mkdir -p "$LOGDIR" 2>/dev/null || true
[ -d "$LOGDIR" ] || die "LOG 디렉터리 없음 : $LOGDIR"

# ROOT 환경. 이미 잡혀 있으면 건드리지 않는다.
if ! command -v root >/dev/null 2>&1; then
   [ -f /usr/local/bin/thisroot.sh ] && . /usr/local/bin/thisroot.sh
fi
if [ -z "${ONLDAQ_DIR:-}" ] && [ -f /home/frontend/DAQ/DAQ_cup/cupdaq_env.sh ]; then
   . /home/frontend/DAQ/DAQ_cup/cupdaq_env.sh
fi
command -v root >/dev/null 2>&1 || die "root 를 찾을 수 없다. thisroot.sh 를 source 할 것"

# ---- heartbeat ------------------------------------------------------
hb_field() { [ -r "$HB" ] && grep -m1 "^$1=" "$HB" 2>/dev/null | cut -d= -f2- ; }
hb_age()   { local t; t=$(hb_field time); [ -n "$t" ] && echo $(( $(date +%s) - t )) || echo 999999; }

# ---- 서브런 상태 ----------------------------------------------------
pad6() { printf '%06d' "$1"; }
pad5() { printf '%05d' "$1"; }

# 원본 스크립트와 동일한 2PC 판정. audit_run.sh 호환을 위해 파일명도 동일하게 쓴다.
subrun_done() {          # run_num subrun
   local rn=$1 n=$2
   local ml="$LOGDIR/log_merge_FADC_SADC_v3_5v_run${rn}_subrun${n}.txt"
   local pl="$LOGDIR/log_production_v3_5v_run${rn}_subrun${n}.txt"
   [ -f "$ml" ] && grep -q "final before_SADC_trgnum" "$ml" 2>/dev/null || return 1
   [ -f "$pl" ] && grep -q "SUCCESS"                  "$pl" 2>/dev/null || return 1
   return 0
}

# merge 매크로가 다음 서브런에 넘기라고 찍어 주는 SADC 위치
ST_SADC=0; ST_EVT=0; ST_TRG=0
NEXT_RUN=""; NEXT_SUB=-1        # 추적 모드에서 재스캔을 피하기 위한 진행 지점
load_state() {           # merge 로그 파일
   local f=$1 a b c
   a=$(grep -m1 "final SADC "              "$f" 2>/dev/null | awk '{print $4}')
   b=$(grep -m1 "final SADC_evt"           "$f" 2>/dev/null | awk '{print $4}')
   c=$(grep -m1 "final before_SADC_trgnum" "$f" 2>/dev/null | awk '{print $4}')
   [ -n "$a" ] && ST_SADC=$a; [ -n "$b" ] && ST_EVT=$b; [ -n "$c" ] && ST_TRG=$c
}

# 현재 파일 개수 기준 마지막 서브런 번호
max_file_index() {       # run_pad
   local d="$RAWROOT/$1" last
   last=$(find "$d" -maxdepth 1 -name 'FADC_*.root.*' -printf '%f\n' 2>/dev/null \
          | sed 's/.*\.//' | sort -n | tail -1)
   [ -n "$last" ] && echo $((10#$last)) || echo -1
}

# 산출물 디렉터리 준비.
#  --outroot 가 있으면 거기에 만들고 RAW 쪽에는 심볼릭 링크를 건다.
#  매크로는 "$DataDir/Merged/..." 를 그대로 쓰므로 코드를 고칠 필요가 없고,
#  audit_run.sh 같은 기존 도구도 경로가 그대로다.
ensure_outdirs() {       # data_dir run_pad
   local dd=$1 rp=$2 sub
   mkdir -p "$dd/PNG" 2>/dev/null
   for sub in Merged PRD; do
      if [ -z "$OUTROOT" ]; then
         mkdir -p "$dd/$sub" 2>/dev/null
         continue
      fi
      mkdir -p "$OUTROOT/$rp/$sub" 2>/dev/null
      if [ -L "$dd/$sub" ]; then
         :                                    # 이미 링크. 그대로 둔다
      elif [ -d "$dd/$sub" ]; then
         # 실제 디렉터리가 이미 있다. 데이터를 임의로 옮기지 않고 알리기만 한다.
         log "${C_Y}[WARN]${C_0} $dd/$sub 이 실제 디렉터리다. --outroot 를 적용하려면"
         log "        먼저 mv 로 옮기고 심볼릭 링크를 걸 것 (docs/POSTRUN.md 참조)"
      else
         ln -s "$OUTROOT/$rp/$sub" "$dd/$sub" && \
            log "  $sub -> $OUTROOT/$rp/$sub (심볼릭 링크 생성)"
      fi
   done
}

# ---- production 병렬 풀 ---------------------------------------------
NRUNNING=0
prod_launch() {          # run_pad subrun data_dir
   local rp=$1 n=$2 dd=$3
   while [ "$NRUNNING" -ge "$JOBS" ]; do wait -n 2>/dev/null || break; NRUNNING=$((NRUNNING-1)); done
   ( cd "$SHELLDIR" && nice -n "$NICE" ./"$PROD_SCRIPT" "$rp" "$n" "$dd" >/dev/null 2>&1 ) &
   NRUNNING=$((NRUNNING+1))
}
prod_drain() { while [ "$NRUNNING" -gt 0 ]; do wait -n 2>/dev/null || break; NRUNNING=$((NRUNNING-1)); done; }

# =====================================================================
#  한 서브런 처리
# =====================================================================
do_subrun() {            # run_pad run_num subrun maxarg data_dir
   local rp=$1 rn=$2 n=$3 maxarg=$4 dd=$5
   local ml="$LOGDIR/log_merge_FADC_SADC_v3_5v_run${rn}_subrun${n}.txt"
   local rl="$LOGDIR/log_merge_prod_v3_5v_run${rn}_subrun${n}.txt"

   if [ "$DRYRUN" -eq 1 ]; then
      log "${C_C}[DRY]${C_0} merge run=$rn sub=$n max=$maxarg state=($ST_SADC,$ST_EVT,$ST_TRG)"
      return 0
   fi

   date > "$rl"; date > "$ml"

   local try=0 rc=1
   while [ $try -le "$MAXRETRY" ]; do
      ( cd "$CODEDIR" && nice -n "$NICE" root -l -b -q \
          "$MERGE_MACRO($rn,$maxarg,$n,$ST_SADC,$ST_EVT,$ST_TRG,\"$dd\")" ) >> "$ml" 2>&1
      rc=$?
      [ $rc -eq 0 ] && break
      try=$((try+1))
      [ $try -le "$MAXRETRY" ] && { log "${C_Y}[RETRY]${C_0} sub=$n merge 실패(rc=$rc) ${try}/${MAXRETRY}"; sleep "$RETRY_WAIT"; }
   done

   if [ $rc -ne 0 ]; then
      log "${C_R}[ZOMBIE]${C_0} sub=$n merge 실패. 건너뛴다"
      echo " Skipped subrun $n due to corruption." >> "$rl"
      # 상태를 이 서브런 기준으로 리셋한다. 원본이 비연속 점프에서 하는 것과 같다.
      ST_SADC=$((n+1)); ST_EVT=0; ST_TRG=0
      return 1
   fi

   # merge 가 남긴 SADC 위치를 다음 서브런으로 넘긴다
   load_state "$ml"
   echo " Merging Done : Run${rn}.${n}" >> "$rl"

   prod_launch "$rp" "$n" "$dd"
   return 0
}

# =====================================================================
#  한 런의 [from..to] 구간 처리
# =====================================================================
process_range() {        # run_pad run_num from to maxarg
   local rp=$1 rn=$2 from=$3 to=$4 maxarg=$5
   local dd="$RAWROOT/$rp"
   local n done_cnt=0 skip_cnt=0 fail_cnt=0 t0 el

   [ "$from" -gt "$to" ] && return 0

   ensure_outdirs "$dd" "$rp"

   # [경쟁 상태 수정] production_from_merged_v3_5v.sh 는
   #   if [ ! -f "$UseLog" ]; then cat TCBLOG | grep WJ > $UseLog; fi
   # 을 하는데, 병렬로 돌리면 여러 프로세스가 동시에 이 파일을 쓴다.
   # 미리 한 번만 만들어 두면 그 창이 사라진다.
   local uselog="$dd/PRD/Run${rp}_DLY_THR.log"
   local tcblog="$RAWROOT/../LOG/TCB_${rp}.log"
   if [ ! -s "$uselog" ] && [ -r "$tcblog" ] && [ "$DRYRUN" -eq 0 ]; then
      grep WJ "$tcblog" > "$uselog" 2>/dev/null && log "  DLY_THR 로그 생성 : $(basename "$uselog")"
   fi

   t0=$(date +%s)
   for (( n=from; n<=to; n++ )); do
      if subrun_done "$rn" "$n"; then
         # 이미 끝난 것. 상태만 이어받고 넘어간다.
         load_state "$LOGDIR/log_merge_FADC_SADC_v3_5v_run${rn}_subrun${n}.txt"
         skip_cnt=$((skip_cnt+1))
         continue
      fi
      if do_subrun "$rp" "$rn" "$n" "$maxarg" "$dd"; then
         done_cnt=$((done_cnt+1))
         log "${C_G}[OK]${C_0} run=$rn sub=$n  (다음 SADC 위치 $ST_SADC/$ST_EVT)"
      else
         fail_cnt=$((fail_cnt+1))
      fi
   done
   el=$(( $(date +%s) - t0 ))

   # 다음 주기에 처음부터 다시 훑지 않도록 진행 지점을 기억한다.
   NEXT_RUN=$rn; NEXT_SUB=$((to+1))

   [ $((done_cnt+fail_cnt)) -gt 0 ] && \
      log "구간 종료 run=$rn [$from..$to] 처리 $done_cnt / 건너뜀 $skip_cnt / 실패 $fail_cnt  (${el}초)"
   return 0
}

# 재개 지점 : 앞에서부터 훑어 아직 안 끝난 첫 서브런을 찾는다.
#  원본은 이진 탐색을 쓰는데, 중간에 실패한 서브런이 있으면 단조성이 깨져
#  엉뚱한 지점에서 재개한다. 여기서는 선형으로 훑는다(파일 stat 뿐이라 충분히 빠르다).
resume_point() {         # run_num upto  -> 첫 미완료 서브런
   local rn=$1 upto=$2 n
   for (( n=0; n<=upto; n++ )); do
      subrun_done "$rn" "$n" || { echo "$n"; return; }
   done
   echo $((upto+1))
}

# =====================================================================
#  일회 처리
# =====================================================================
run_once() {             # run_num
   local rn=$1
   local rp; rp=$(pad6 "$rn")
   local dd="$RAWROOT/$rp"
   [ -d "$dd" ] || die "데이터 디렉터리 없음 : $dd"

   local nf ns maxidx
   nf=$(find "$dd" -maxdepth 1 -name 'FADC_*.root.*' | wc -l)
   ns=$(find "$dd" -maxdepth 1 -name 'SADC_*.root.*' | wc -l)
   maxidx=$(max_file_index "$rp")
   [ "$maxidx" -lt 0 ] && die "FADC 파일이 없다 : $dd"
   [ "$nf" -ne "$ns" ] && log "${C_Y}[WARN]${C_0} FADC($nf) 와 SADC($ns) 개수가 다르다"

   # 이 런이 지금 수집 중인가?
   local hbrun hbsub age active=0 lastc targetmax
   hbrun=$(hb_field run); hbsub=$(hb_field subrun); age=$(hb_age)
   if [ -n "$hbrun" ] && [ "$hbrun" = "$rn" ] && [ "$age" -lt 120 ]; then
      active=1
      # heartbeat 의 subrun 은 '지금 기록 중인' 파일 번호다(실측 확인).
      #   완료된 마지막 서브런  lastc     = subrun - 1
      #   손대도 되는 마지막    targetmax = subrun - LAG
      # LAG=3 이면 기록 중인 것보다 3개(=약 3분) 뒤까지만 처리한다.
      lastc=$(( hbsub - 1 ))
      targetmax=$(( lastc - LAG + 1 ))
   else
      lastc=$maxidx
      targetmax=$maxidx
   fi
   [ "$targetmax" -gt "$maxidx" ] && targetmax=$maxidx
   [ "$lastc" -gt "$maxidx" ] && lastc=$maxidx

   # 재개 지점. 추적 모드에서 매 주기마다 전체를 다시 훑으면 NFS 에 수천 번
   # grep 하게 되므로, 같은 런을 계속 보는 동안에는 진행 지점을 이어 쓴다.
   local from to
   if   [ "$FROM" -ge 0 ]; then from=$FROM
   elif [ "$NEXT_RUN" = "$rn" ] && [ "$NEXT_SUB" -ge 0 ]; then from=$NEXT_SUB
   else from=$(resume_point "$rn" "$targetmax")
        log "  재개 지점 탐색 완료 -> subrun $from"
   fi
   if [ "$TO"   -ge 0 ]; then to=$TO;     else to=$targetmax; fi
   [ "$to" -gt "$targetmax" ] && to=$targetmax

   if [ "$from" -gt "$to" ]; then
      [ "$active" -eq 1 ] || log "run=$rn : 처리할 서브런 없음 (모두 완료)"
      return 0
   fi

   log "${C_C}run=$rn${C_0} 파일 $nf 개(최대 #$maxidx) / $([ $active -eq 1 ] && echo '수집 중' || echo '수집 종료')"
   log "  처리 구간 [$from .. $to]   maxsubrun 인자=$lastc   jobs=$JOBS"

   # 재개일 때는 직전 서브런의 상태를 이어받는다
   if [ "$from" -gt 0 ]; then
      local prev="$LOGDIR/log_merge_FADC_SADC_v3_5v_run${rn}_subrun$(( from - 1 )).txt"
      if [ -f "$prev" ]; then load_state "$prev"
      else ST_SADC=$from; ST_EVT=0; ST_TRG=0
           log "  ${C_Y}직전 로그 없음 -> SADC 상태를 $from 부터 새로 시작${C_0}"
      fi
   else
      ST_SADC=0; ST_EVT=0; ST_TRG=0
   fi

   process_range "$rp" "$rn" "$from" "$to" "$lastc"
}

# =====================================================================
#  추적 모드
# =====================================================================
follow_loop() {
   local cur=""
   log "${C_C}추적 모드 시작${C_0}  heartbeat=$HB  lag=$LAG  jobs=$JOBS  poll=${POLL}초"
   while true; do
      local hbrun age
      hbrun=$(hb_field run); age=$(hb_age)

      if [ -z "$hbrun" ] || [ "$age" -ge 120 ]; then
         # DAQ 가 안 돌고 있다. 마지막으로 보던 런의 남은 것만 마저 끝낸다.
         if [ -n "$cur" ]; then
            log "heartbeat 정지(age=${age}s). run=$cur 잔여분 마무리"
            FROM=-1; TO=-1; run_once "$cur"; prod_drain; cur=""
         fi
         sleep "$POLL"; continue
      fi

      if [ -n "$cur" ] && [ "$cur" != "$hbrun" ]; then
         # 런이 넘어갔다. 이전 런은 이제 전부 완료된 상태이므로 끝까지 처리한다.
         log "${C_Y}런 전환 $cur -> $hbrun${C_0}. 이전 런 마무리"
         FROM=-1; TO=-1; run_once "$cur"; prod_drain
      fi
      cur=$hbrun

      FROM=-1; TO=-1
      run_once "$hbrun"
      sleep "$POLL"
   done
}

# =====================================================================
trap 'echo; log "중단 요청. 진행 중인 production 을 기다린다..."; prod_drain; exit 130' INT TERM

if [ -n "$RUNARG" ]; then
   case "$RUNARG" in
      *[!0-9]*) die "run 번호가 숫자가 아니다 : $RUNARG" ;;
   esac
   run_once "$((10#$RUNARG))"      # 004288 / 4288 둘 다 받는다
   prod_drain
   log "완료"
elif [ "$ONCE" -eq 1 ]; then
   r=$(hb_field run); [ -n "$r" ] || die "heartbeat 에서 run 을 읽을 수 없다 : $HB"
   run_once "$r"; prod_drain; log "완료"
else
   FOLLOW=1
   follow_loop
fi
