#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  run-summary.sh - production 을 마친 런을 찾아 run_summary 에 이어붙인다.
#
#  입력은 **production 산출물**이다 -- <RAW>/<런번호>/PRD/PRD_<런>.<서브런>.root
#  BuildRunSummary.C 를 부르는 얇은 껍데기다. 하는 일은 셋뿐이다.
#    1) ROOT 환경을 잡는다
#    2) PRD 가 실제로 있는 런을 찾는다 (없는 런을 넘기면 그냥 낭비다)
#    3) 이미 요약에 든 런은 빼고 나머지만 넘긴다
#
#  사용 :
#      tools/monitor/run-summary.sh                  새로 끝난 런을 전부
#      tools/monitor/run-summary.sh 4237 4240        범위를 지정해서
#      tools/monitor/run-summary.sh --list 4237,4239 목록으로
#      tools/monitor/run-summary.sh --force 4240     이미 있어도 다시 계산
#      tools/monitor/run-summary.sh --newest 5       아직 안 한 것 중 최신 5개만
#      tools/monitor/run-summary.sh --show           만들지 않고 결과만 본다
#      tools/monitor/run-summary.sh --allow-acquiring   수집 중인 런도 포함(권하지 않는다)
#      tools/monitor/run-summary.sh --dry-run        무엇을 할지만 보여준다
#
#  런 하나가 서브런 수에 비례해 걸린다(실측 약 1.3 s/서브런, /scratch 100 Mb).
#  61 서브런 런 = 약 80초, 24시간 런(1440) = 약 30분, 12,720 서브런 = 몇 시간.
#  그래서 자동화에서는 --newest 로 끊어서 조금씩 따라잡는 편이 낫다.
#
#  경로는 환경변수로 바꾼다.
#      RUNSUM_OUT  기본 /scratch/RunSummary
#      RUNSUM_RAW  기본 /Data_ssd/RAW:/data/RAW:/scratch/RAW
#                  production 산출물이 있는 곳. ':' 로 여럿을 준다.
#                  dataflow 가 런을 /Data_ssd -> /data -> /scratch 로
#                  흘려보내므로 한 곳만 보면 옮겨진 런을 놓친다.
#                  앞에 오는 것이 이긴다 -- 앞쪽이 빠른 디스크다.
#
#  주의 : RAW 트리는 읽기만 한다. 쓰는 곳은 RUNSUM_OUT 뿐이다.
#         /scratch 는 100 Mb 링크라(CLAUDE.md §11.12) 런 하나에 몇 분 걸린다.
#         이미 요약에 든 런은 건너뛰므로 두 번째부터는 빠르다.
# ---------------------------------------------------------------------
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
MACRO=$DIR/BuildRunSummary.C
OUT=${RUNSUM_OUT:-/scratch/RunSummary}
RAW=${RUNSUM_RAW:-/Data_ssd/RAW:/data/RAW:/scratch/RAW}
ALLOW_ACQ=0; FORCE=0; DRY=0; LIST=""; LO=""; HI=""; NEWEST=0

while [ $# -gt 0 ]; do
   case "${1:-}" in
      --force)   FORCE=1; shift ;;
      --allow-acquiring) ALLOW_ACQ=1; shift ;;
      --dry-run) DRY=1; shift ;;
      --list)    LIST=${2:-}; shift 2 ;;
      --newest)  NEWEST=${2:-0}; shift 2 ;;
      --show)
         [ -r "$OUT/run_summary.txt" ] || { echo "아직 없다 : $OUT/run_summary.txt"; exit 1; }
         exec cat "$OUT/run_summary.txt" ;;
      -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
      -*)        echo "모르는 옵션 : $1"; sed -n '2,30p' "$0"; exit 1 ;;
      *)         if [ -z "$LO" ]; then LO=$1; else HI=$1; fi; shift ;;
   esac
done

[ -r "$MACRO" ] || { echo "매크로가 없다 : $MACRO"; exit 1; }

# ---- ROOT ----
if ! command -v root >/dev/null 2>&1; then
   # shellcheck disable=SC1091
   [ -r /usr/local/bin/thisroot.sh ] && . /usr/local/bin/thisroot.sh
fi
command -v root >/dev/null 2>&1 || { echo "ROOT 를 찾을 수 없다. thisroot.sh 를 source 할 것"; exit 1; }

mkdir -p "$OUT" 2>/dev/null
[ -w "$OUT" ] || { echo "출력 디렉터리에 쓸 수 없다 : $OUT"; exit 1; }

# ---- 대상 런 고르기 ----
#  PRD 디렉터리가 있는 런을 모은다. 디렉터리 존재만 본다 --
#  안에 파일이 있는지까지 확인하면 NFS 왕복이 배로 든다. 비어 있는 런은
#  매크로가 열어 보고 곱게 건너뛴다.
#
#  실측(2026-08-18) : 런 디렉터리 1,735 개 중 PRD 가 있는 것 1,406 개,
#  이 한 줄에 약 42초. /scratch 가 100 Mb 링크라 그렇다(CLAUDE.md §11.12).
#  범위나 --list 를 주면 이 훑기를 건너뛴다.
have_runs() {
   local r
   printf '%s' "$RAW" | tr ':' '\n' | awk 'NF' | while read -r r; do
      ls -dU "${r%/}"/[0-9][0-9][0-9][0-9][0-9][0-9]/PRD 2>/dev/null
   done | sed -n 's|.*/0*\([0-9][0-9]*\)/PRD$|\1|p' | sort -n -u
}
already() {
   [ -r "$OUT/run_summary.tsv" ] || return 0
   grep -v '^#' "$OUT/run_summary.tsv" 2>/dev/null | awk 'NF{print $1}' | sort -n -u
}

# ---- 지금 수집 중인 런은 건드리지 않는다 ★ ----
#  이것이 없으면 자동화(--newest)가 **가장 먼저 진행 중인 런을 집는다.** 그러면
#  미완성 런이 표에 박히고, 그 뒤로는 '이미 있다'고 건너뛰므로 영원히 반쪽짜리
#  행으로 남는다. dataflow.sh 의 is_acquiring 과 같은 규칙이다 --
#  heartbeat 의 run 이 그 런이고 heartbeat 가 120초 안에 갱신됐으면 수집 중.
HB=${RUNSUM_HB:-/Data/LOG/rcterm.hb}
acquiring_run() {
   [ "$ALLOW_ACQ" -eq 1 ] && return 0
   [ -r "$HB" ] || return 0
   local now hbt age r
   now=$(date +%s)
   hbt=$(awk -F= '$1=="time"{print $2; exit}' "$HB" 2>/dev/null)
   [ -n "$hbt" ] || return 0
   age=$(( now - hbt ))
   [ "$age" -lt 120 ] || return 0
   r=$(awk -F= '$1=="run"{print $2; exit}' "$HB" 2>/dev/null)
   [ -n "$r" ] && printf '%s\n' "$r"
}

# ---- PRD 가 아직 쓰이고 있으면 다음 주기로 미룬다 ★ ----
#  수집 중 가드(위)만으로는 부족하다. 로테이션 직후에는 런이 끝났어도
#  postrun 이 마지막 서브런들을 아직 만들고 있다. 그때 집으면 반쪽짜리 행이
#  박히고 다시 계산되지 않는다.
#  판정은 **가장 최근 PRD 파일의 mtime** 으로 한다 -- 개수 대조(FADC 대 PRD)로
#  하면 예전에 일부만 처리된 옛 런이 영영 제외된다. 시간으로 보면 그런 런은
#  mtime 이 오래됐으므로 통과한다.
PRD_QUIET=${RUNSUM_PRD_QUIET:-600}     # 초. 이 시간 안에 쓰인 PRD 가 있으면 미룬다
prd_is_settling() {                     # run
   local rp r d newest age
   rp=$(printf '%06d' "$1")
   for r in $(printf '%s' "$RAW" | tr ':' '\n' | awk 'NF'); do
      d="${r%/}/$rp/PRD"
      [ -d "$d" ] || continue
      newest=$(find "$d" -maxdepth 1 -name '*.root' -printf '%T@\n' 2>/dev/null |
               sort -n | tail -1 | cut -d. -f1)
      [ -n "$newest" ] || continue
      age=$(( $(date +%s) - newest ))
      [ "$age" -lt "$PRD_QUIET" ] && return 0
      return 1
   done
   return 1
}
drop_settling() {                       # 목록을 stdin 으로, 남길 것을 stdout 으로
   local n
   while read -r n; do
      [ -n "$n" ] || continue
      if prd_is_settling "$n"; then
         echo "후처리: run $n 은 PRD 가 아직 쓰이고 있다. 다음 주기로 미룬다" >&2
      else
         echo "$n"
      fi
   done
}

if [ -n "$LIST" ]; then
   TARGET=$(printf '%s' "$LIST" | tr ',' '\n' | awk 'NF')
elif [ -n "$LO" ]; then
   [ -n "$HI" ] || HI=$LO
   TARGET=$(have_runs | awk -v a="$LO" -v b="$HI" '$1>=a && $1<=b')
   [ -n "$TARGET" ] || { echo "$LO..$HI 범위에 PRD 가 있는 런이 없다"; exit 0; }
else
   TARGET=$(have_runs)
   [ -n "$TARGET" ] || { echo "PRD 를 하나도 찾지 못했다 : $RAW"; exit 0; }
fi

if [ "$FORCE" -eq 0 ]; then
   HAVE=$(already)
   if [ -n "$HAVE" ]; then
      NEW=$(comm -23 <(printf '%s\n' "$TARGET" | sort -n -u) <(printf '%s\n' "$HAVE"))
   else
      NEW=$TARGET
   fi
else
   NEW=$TARGET
fi


ACQ=$(acquiring_run)
if [ -n "${ACQ:-}" ]; then
   if printf '%s\n' "$NEW" | awk 'NF' | grep -qx "$ACQ"; then
      echo "수집  : run $ACQ 은 지금 수집 중이라 뺀다 (--allow-acquiring 으로 강제)"
      NEW=$(printf '%s\n' "$NEW" | awk 'NF' | grep -vx "$ACQ")
   fi
fi

#  자동화에서 한 번에 다 하려 들면 며칠 물린다. 최신 것부터 조금씩 따라잡는다.
if [ "$NEWEST" -gt 0 ]; then
   NEW=$(printf '%s\n' "$NEW" | awk 'NF' | sort -n | tail -n "$NEWEST")
fi

NEW=$(printf '%s\n' "$NEW" | awk 'NF' | drop_settling)

if [ -z "${NEW//[[:space:]]/}" ]; then
   echo "새로 더할 런이 없다. 요약에 이미 $(already | wc -l) 개 런이 들어 있다."
   echo "다시 계산하려면 --force, 결과를 보려면 --show."
   exit 0
fi

CSV=$(printf '%s\n' "$NEW" | awk 'NF' | paste -sd, -)
NCNT=$(printf '%s\n' "$NEW" | awk 'NF' | wc -l)
# 런이 수백 개면 목록을 통째로 찍는 순간 화면이 못 쓰게 된다. 요약만 보인다.
if [ "$NCNT" -le 12 ]; then
   SHOWN=$CSV
else
   SHOWN="$(printf '%s\n' "$NEW" | awk 'NF' | head -5 | paste -sd, -) ... $(printf '%s\n' "$NEW" | awk 'NF' | tail -3 | paste -sd, -)"
fi
echo "출력  : $OUT"
echo "입력  : <root>/<run>/PRD  (읽기 전용)  root = $RAW"
echo "대상  : $NCNT 개 런 -> $SHOWN"

if [ "$DRY" -eq 1 ]; then
   echo "[DRY] root -l -b -q '$MACRO+(\"<위 $NCNT 개>\", $([ "$FORCE" -eq 1 ] && echo true || echo false), \"$OUT/\", \"$RAW\")'"
   exit 0
fi

root -l -b -q "$MACRO+(\"$CSV\", $([ "$FORCE" -eq 1 ] && echo true || echo false), \"$OUT/\", \"$RAW\")"
rc=$?
[ $rc -eq 0 ] && echo "결과를 보려면 : $0 --show"
exit $rc
