#!/usr/bin/env bash
# muon-spec.sh -- 타겟 뮤온 NPE 스펙트럼을 veto 태그 유무 · 기간(전체/월/주/런) 별로 그린다 (2026-09-18).
#     muon-spec.sh [--dst dst|dst_m2] [--from 4237] [--to 4348]      → $RUNSUM_OUT/muspec/<dst>/muspec_*.png + muspec_summary.tsv + muspec.root
set -u
DIR=$(cd "$(dirname "$0")" && pwd); OUT=${RUNSUM_OUT:-/scratch/RunSummary}; DST=dst; FROM=4237; TO=4348
while [ $# -gt 0 ]; do case "$1" in --dst) DST=$2; shift 2 ;; --from) FROM=$2; shift 2 ;; --to) TO=$2; shift 2 ;; -h|--help) sed -n '2,4p' "$0"; exit 0 ;; *) echo "모르는 옵션 : $1"; exit 1 ;; esac; done
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh
[ -d "$OUT/$DST" ] || { echo "DST 폴더가 없다 : $OUT/$DST"; exit 1; }
root -l -b -q "$DIR/MuonSpec.C+(\"$OUT/\", \"$DST\", $FROM, $TO)"
