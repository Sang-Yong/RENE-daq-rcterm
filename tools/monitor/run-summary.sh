#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  run-summary.sh - production 을 마친 런을 찾아 run_summary 에 이어붙인다.
#
#  BuildRunSummary.C 를 부르는 얇은 껍데기다. 하는 일은 셋뿐이다.
#    1) ROOT 환경을 잡는다
#    2) 분석 산출물이 실제로 있는 런을 찾는다 (없는 런을 넘기면 그냥 낭비다)
#    3) 이미 요약에 든 런은 빼고 나머지만 넘긴다
#
#  사용 :
#      tools/monitor/run-summary.sh                  새로 끝난 런을 전부
#      tools/monitor/run-summary.sh 4237 4240        범위를 지정해서
#      tools/monitor/run-summary.sh --list 4237,4239 목록으로
#      tools/monitor/run-summary.sh --force 4240     이미 있어도 다시 계산
#      tools/monitor/run-summary.sh --show           만들지 않고 결과만 본다
#      tools/monitor/run-summary.sh --dry-run        무엇을 할지만 보여준다
#
#  경로는 환경변수로 바꾼다.
#      RUNSUM_OUT     기본 /scratch/RunSummary
#      RUNSUM_SAMPLE  기본 /scratch/junkyo/SampleFiles
#
#  주의 : 분석 산출물(SampleFiles)은 ojk 계정 소유다. 이 스크립트는 그것을
#         읽기만 하고, 쓰는 곳은 RUNSUM_OUT 뿐이다.
# ---------------------------------------------------------------------
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
MACRO=$DIR/BuildRunSummary.C
OUT=${RUNSUM_OUT:-/scratch/RunSummary}
SAMPLE=${RUNSUM_SAMPLE:-/scratch/junkyo/SampleFiles}
FORCE=0; DRY=0; LIST=""; LO=""; HI=""

while [ $# -gt 0 ]; do
   case "${1:-}" in
      --force)   FORCE=1; shift ;;
      --dry-run) DRY=1; shift ;;
      --list)    LIST=${2:-}; shift 2 ;;
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
#  분석 산출물이 있는 런만 고른다. Monitor 가 1순위, 없으면 Step1.
have_runs() {
   {
      ls "$SAMPLE"/Monitor/monitor_Run*.root 2>/dev/null |
         sed -n 's|.*/monitor_Run0*\([0-9][0-9]*\)\.root|\1|p'
      ls "$SAMPLE"/Step1/step1_Run*.root 2>/dev/null |
         sed -n 's|.*/step1_Run0*\([0-9][0-9]*\)\.root|\1|p'
   } | sort -n -u
}
already() {
   [ -r "$OUT/run_summary.tsv" ] || return 0
   grep -v '^#' "$OUT/run_summary.tsv" 2>/dev/null | awk 'NF{print $1}' | sort -n -u
}

if [ -n "$LIST" ]; then
   TARGET=$(printf '%s' "$LIST" | tr ',' '\n' | awk 'NF')
elif [ -n "$LO" ]; then
   [ -n "$HI" ] || HI=$LO
   TARGET=$(have_runs | awk -v a="$LO" -v b="$HI" '$1>=a && $1<=b')
   [ -n "$TARGET" ] || { echo "$LO..$HI 범위에 분석 산출물이 있는 런이 없다"; exit 0; }
else
   TARGET=$(have_runs)
   [ -n "$TARGET" ] || { echo "분석 산출물을 하나도 찾지 못했다 : $SAMPLE"; exit 0; }
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
echo "입력  : $SAMPLE  (읽기 전용)"
echo "대상  : $NCNT 개 런 -> $SHOWN"

if [ "$DRY" -eq 1 ]; then
   echo "[DRY] root -l -b -q '$MACRO+(\"<위 $NCNT 개>\", $([ "$FORCE" -eq 1 ] && echo true || echo false), \"$OUT/\", \"$SAMPLE/\")'"
   exit 0
fi

root -l -b -q "$MACRO+(\"$CSV\", $([ "$FORCE" -eq 1 ] && echo true || echo false), \"$OUT/\", \"$SAMPLE/\")"
rc=$?
[ $rc -eq 0 ] && echo "결과를 보려면 : $0 --show"
exit $rc
