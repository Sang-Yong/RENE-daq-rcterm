#!/usr/bin/env bash
#
#  backup-trickle.sh — 밀린 옛 런을 '가장 낮은 우선순위로, 천천히' 백업한다.
#
#  왜 따로 있나 — backup-khu.sh 를 그냥 여러 런에 돌리면 포화된 100 Mb
#  링크(CLAUDE.md §11.12)를 독차지해서 수집 추적·후처리·진행 중인 백업을
#  전부 굶긴다. 이 스크립트는 세 가지로 양보한다.
#
#    1) 더 급한 작업이 돌고 있으면 아예 멈춰 서서 기다린다 (가장 중요하다)
#    2) rsync --bwlimit 으로 링크의 일부만 쓴다. 병목이 네트워크라
#       nice/ionice 만으로는 양보가 되지 않는다
#    3) nice 19 + ionice -c2 -n7 로 CPU·로컬 디스크도 뒤로 물러난다
#       (-c3(유휴)까지 내리면 굶어서 진행이 멈춘다 — §11.11 실측)
#
#  런 하나씩, 최신 것부터. 사이사이 다시 양보 여부를 본다.
#  진행은 backup-khu.sh 의 .backup_done 마커에 남으므로 언제 끊어도 이어진다.
#
#  사용
#     scripts/backup-trickle.sh --dry-run
#     scripts/backup-trickle.sh --from 4200 --to 4290
#     scripts/backup-trickle.sh --from 4200 --to 4290 --only RAW,PRD,PNG
#     scripts/backup-trickle.sh --bwlimit 4000        (더 빠르게)
#
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)

FROM=4200
TO=4290
MID=${DATAFLOW_MID_ROOT:-/scratch}
ONLY=RAW                 # 기본은 RAW 만. PRD/PNG 는 양이 훨씬 크다
BWLIMIT=2000             # KB/s. 링크 실측 7.7 MB/s 의 약 1/4
PARAMS=$REPO/config/dataflow.params
DRYRUN=0
ORDER=newest
POLL=120                 # 양보 대기 확인 주기 [초]

C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'; C_C='\033[1;36m'; C_0='\033[0m'
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %b\n' "$(ts)" "$*"; }
die() { printf '[%s] %b\n' "$(ts)" "${C_R}[FATAL] $*${C_0}"; exit 1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; cat <<EOF

옵션
  --from N --to N   런 범위                      (${FROM} ~ ${TO})
  --only A,B        카테고리                     (${ONLY})
  --bwlimit KB/s    rsync 대역 상한. 0 = 무제한  (${BWLIMIT})
  --mid DIR         원본 최상위                  (${MID})
  --params FILE     dataflow.params              (${PARAMS})
  --oldest-first    오래된 것부터 (기본은 최신부터)
  --poll SEC        양보 대기 확인 주기          (${POLL})
  --dry-run         무엇을 할지만 출력
EOF
}

while [ $# -gt 0 ]; do
   case "$1" in
      --from)         FROM=$2; shift 2 ;;
      --to)           TO=$2; shift 2 ;;
      --only)         ONLY=$2; shift 2 ;;
      --bwlimit)      BWLIMIT=$2; shift 2 ;;
      --mid)          MID=$2; shift 2 ;;
      --params)       PARAMS=$2; shift 2 ;;
      --oldest-first) ORDER=oldest; shift ;;
      --poll)         POLL=$2; shift 2 ;;
      --dry-run|-n)   DRYRUN=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      *)              usage; die "모르는 옵션 : $1" ;;
   esac
done

BK=$REPO/scripts/backup-khu.sh
[ -x "$BK" ] || die "실행할 수 없다 : $BK"

# ---- 양보 판단 ------------------------------------------------------
#  우리가 띄운 자식 말고 다른 백업/이동 작업이 돌고 있으면 기다린다.
#  $$ 를 빼는 것만으로는 부족해서, 우리 자식 트리를 통째로 제외한다.
busy_reason() {
   local p cmd
   #  더 급한 큐 스크립트들
   for p in backup-queue-4288-4289.sh finish-4290-4291.sh; do
      pgrep -f "$p" >/dev/null 2>&1 && { echo "$p"; return 0; }
   done
   #  우리 자식이 아닌 backup-khu.sh (dataflow 가 띄운 것 포함)
   for p in $(pgrep -f 'backup-khu\.sh' 2>/dev/null); do
      [ "$p" = "${CHILD_PID:-0}" ] && continue
      #  우리 자식 트리인지 본다
      if [ "$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" = "${CHILD_PID:-0}" ]; then continue; fi
      cmd=$(ps -o args= -p "$p" 2>/dev/null)
      case "$cmd" in *"$MARKER_TAG"*) continue ;; esac
      echo "backup-khu.sh (pid $p)"; return 0
   done
   #  dataflow 가 실제로 파일을 옮기는 중이면 기다린다
   pgrep -f 'rsync.*--remove-source-files' >/dev/null 2>&1 && { echo "dataflow 이동"; return 0; }
   #  relocate 중이면 기다린다
   pgrep -f 'relocate-run\.sh' >/dev/null 2>&1 && { echo "relocate-run.sh"; return 0; }
   return 1
}

yield_wait() {
   local why shown=0
   while why=$(busy_reason); do
      [ "$shown" -eq 0 ] && { log "${C_Y}  양보 : $why 이(가) 끝나기를 기다린다${C_0}"; shown=1; }
      sleep "$POLL"
   done
   [ "$shown" -eq 1 ] && log "${C_G}  재개${C_0}"
   return 0
}

# ---- 대상 목록 ------------------------------------------------------
runs=$(ls -1 "$MID/RAW" 2>/dev/null | grep -E '^[0-9]{6}$' \
       | awk -v a="$FROM" -v b="$TO" '$1+0>=a && $1+0<=b')
[ -n "$runs" ] || die "$MID/RAW 에 $FROM~$TO 범위의 런이 없다"
if [ "$ORDER" = newest ]; then runs=$(echo "$runs" | sort -rn); else runs=$(echo "$runs" | sort -n); fi

n_total=$(echo "$runs" | wc -l)
log "${C_C}=== 저우선순위 백업 : $FROM~$TO, $n_total 개 런, 카테고리 [$ONLY] ===${C_0}"
log "    대역 상한 ${BWLIMIT} KB/s · $( [ "$ORDER" = newest ] && echo 최신 || echo 오래된 )것부터 · 양보 확인 ${POLL}초"

if [ "$DRYRUN" -eq 1 ]; then
   log "  [DRY] 처리 순서 :"; echo "$runs" | tr '\n' ' ' | fold -w 100 | sed 's/^/      /'
   log "  [DRY] 각 런마다 : $BK --params $PARAMS --mid $MID --run <N> --only $ONLY --bwlimit $BWLIMIT"
   exit 0
fi

MARKER_TAG="TRICKLE_$$"
i=0; ok=0; fail=0
for r in $runs; do
   i=$((i+1))
   yield_wait
   log "${C_C}[$i/$n_total] run $r${C_0}"
   TRICKLE_MARK=$MARKER_TAG nice -n 19 ionice -c2 -n7 \
      "$BK" --params "$PARAMS" --mid "$MID" --run "$((10#$r))" \
            --only "$ONLY" --bwlimit "$BWLIMIT" &
   CHILD_PID=$!
   wait "$CHILD_PID"; rc=$?
   CHILD_PID=0
   if [ "$rc" -eq 0 ]; then ok=$((ok+1)); else fail=$((fail+1))
      log "${C_Y}  run $r 미완료 (rc=$rc). 다음에 다시 시도하면 이어진다${C_0}"; fi
done
log "${C_G}=== 종료 : 완료 $ok / 미완료 $fail / 전체 $n_total ===${C_0}"
exit 0
