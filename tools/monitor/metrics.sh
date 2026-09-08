#!/usr/bin/env bash
# metrics.sh - DST 에서 metrics_summary.tsv 를 만든다 (3차 프로덕션 단계).
#   사용 : metrics.sh --list 4237,4240 [--force] [--verify] [--dry-run]
#          metrics.sh --verify                     빌드 없이 대조만
#   환경 : RUNSUM_OUT (기본 /scratch/RunSummary)
#
#   --verify : metrics_summary.tsv 와 pair_summary.tsv 의 공통 (run,tag) 행에서
#   n_ibd·n_ibd_acci 를 대조한다. 다르면 exit 1 (dst 전환 게이트의 실행형).
#   --list 와 함께 주면 먼저 만들고 나서 대조한다.
#
#   Li/He·fast-n 인자(아래 상수)는 이번 버전에서 계산에 쓰이지 않는다
#   (metrics_summary.tsv 에 -1/off 로만 남는다) -- Task 5 가
#   config/monitorcuts.params 에서 읽어 실제로 채운다. 여기 박아 둔 값은
#   그 문서가 적어 둔 기본값과 같아서, Task 5 가 손잡이를 연결해도 이
#   숫자들 자체는 바뀌지 않는다.
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=${RUNSUM_OUT:-/scratch/RunSummary}
LIST=""; FORCE=false; DRY=0; DO_VERIFY=0
MU_SHOWER_NPE=3000
LIHE_FIT_LO_S=0.002
LIHE_FIT_HI_S=10.0
LIHE_MIN_CAND=100
FN_E_LO_MEV=12.0
FN_E_HI_MEV=50.0
FN_TAG_S=0.1

while [ $# -gt 0 ]; do
   case "${1:-}" in
      --list)    LIST=${2:-}; shift 2 ;;
      --force)   FORCE=true; shift ;;
      --verify)  DO_VERIFY=1; shift ;;
      --dry-run) DRY=1; shift ;;
      -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
      *) echo "모르는 옵션 : $1"; exit 1 ;;
   esac
done

verify() {
   local mfile pfile
   mfile="$OUT/metrics_summary.tsv"
   pfile="$OUT/pair_summary.tsv"
   [ -r "$mfile" ] && [ -r "$pfile" ] || { echo "[VERIFY] 두 표가 다 있어야 한다"; return 1; }
   awk -F'\t' -v M="$mfile" '
      /^#/ { next }
      FILENAME==M { ibd[$1 $2]=$7; acc[$1 $2]=$8; next }
      ($1 $2) in ibd {
         n++
         if (ibd[$1 $2] != $7 || acc[$1 $2] != $8) {
            bad++
            printf "  [DIFF] run %s%s : metrics ibd=%s acci=%s / legacy ibd=%s acci=%s\n",
                   $1, $2, ibd[$1 $2], acc[$1 $2], $7, $8 }
      }
      END {
         printf "[VERIFY] 공통 %d 행, 불일치 %d\n", n, bad
         exit (n>0 && bad==0) ? 0 : 1
      }' "$mfile" "$pfile"
}

[ -n "$LIST" ] || [ "$DO_VERIFY" -eq 1 ] || { echo "--list 또는 --verify 가 필요하다"; exit 1; }

if [ -n "$LIST" ]; then
   [ -d "$OUT" ] || { echo "출력 디렉터리가 없다 : $OUT (/scratch 마운트 확인)"; exit 1; }
   command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh
   command -v root >/dev/null 2>&1 || { echo "ROOT 를 찾을 수 없다"; exit 1; }
   echo "지표  : $OUT/metrics_summary.tsv   런 : $LIST"
   ARGS="\"$LIST\", \"$OUT/\", $MU_SHOWER_NPE, $LIHE_FIT_LO_S, $LIHE_FIT_HI_S, $LIHE_MIN_CAND, $FN_E_LO_MEV, $FN_E_HI_MEV, $FN_TAG_S, $FORCE"
   if [ "$DRY" = 1 ]; then
      echo "(dry-run) root -l -b -q '$DIR/BuildMetrics.C+($ARGS)'"
   else
      root -l -b -q "$DIR/BuildMetrics.C+($ARGS)"
      rc=$?
      [ $rc -eq 0 ] || exit $rc
   fi
fi

if [ "$DO_VERIFY" -eq 1 ]; then
   if [ "$DRY" = 1 ]; then
      echo "(dry-run) --verify 는 건너뛴다"
      exit 0
   fi
   verify
   exit $?
fi
exit 0
