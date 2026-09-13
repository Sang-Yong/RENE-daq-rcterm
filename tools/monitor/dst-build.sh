#!/usr/bin/env bash
# dst-build.sh - PRD 에서 런당 DST 하나를 만든다 (2차 프로덕션 단계).
#   사용 : dst-build.sh --list 4237,4240 [--force] [--dry-run] [--max-subrun N] [--muon-mode 0|1|2 [--adc-cut 50]]
#          --muon-mode 1 = veto PMT 하나라도 트리거되면 뮤온 · 2 = 1 또는 S_ADC > adc-cut (강한 veto, 2026-09-14). 산출은 dst_m<N>/
#   환경 : RUNSUM_OUT (기본 /scratch/RunSummary)
#          RENE_RAW_ROOTS (기본 /Data_ssd/RAW:/data/RAW:/scratch/RAW)
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=${RUNSUM_OUT:-/scratch/RunSummary}
ROOTS=${RENE_RAW_ROOTS:-/Data_ssd/RAW:/data/RAW:/scratch/RAW}
LIST=""; FORCE=false; DRY=0; MAXSUB=-1; MUMODE=0; ADCCUT=50
while [ $# -gt 0 ]; do
   case "${1:-}" in
      --list)    LIST=${2:-}; shift 2 ;;
      --force)   FORCE=true; shift ;;
      --dry-run) DRY=1; shift ;;
      --max-subrun) MAXSUB=${2:--1}; shift 2 ;;
      --muon-mode) MUMODE=${2:-0}; shift 2 ;;      # 0 패널 AND(기본) · 1 PMT 하나라도 트리거 · 2 + S_ADC > --adc-cut. 1·2 는 dst_m<N>/ 에
      --adc-cut)   ADCCUT=${2:-50}; shift 2 ;;
      -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
      *) echo "모르는 옵션 : $1"; exit 1 ;;
   esac
done
[ -n "$LIST" ] || { echo "--list 가 필요하다"; exit 1; }
[ -d "$OUT" ]  || { echo "출력 디렉터리가 없다 : $OUT (/scratch 마운트 확인)"; exit 1; }
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh
command -v root >/dev/null 2>&1 || { echo "ROOT 를 찾을 수 없다"; exit 1; }
DSTDIR=dst; [ "$MUMODE" != 0 ] && DSTDIR=dst_m$MUMODE
echo "DST   : $OUT/$DSTDIR/   런 : $LIST   (muon-mode $MUMODE, adc-cut $ADCCUT)"
[ "$DRY" = 1 ] && { echo "(dry-run) 여기서 멈춘다"; exit 0; }
root -l -b -q "$DIR/BuildMonitorDst.C+(\"$LIST\", \"$OUT/\", \"$ROOTS\", 150.0, $FORCE, $MAXSUB, $MUMODE, $ADCCUT)"
