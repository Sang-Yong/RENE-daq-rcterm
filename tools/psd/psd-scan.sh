#!/usr/bin/env bash
# psd-scan.sh - 선원 런/물리 런의 파형 변수를 뽑는다 (PsdScan.C). 읽기 전용 입력.
#   사용 : psd-scan.sh <run> <sub0> <sub1> <pos_mm>     -> $PSD_OUT/psdscan_<run>.root
#   환경 : PSD_OUT (기본 /scratch/RunSummary/psd)
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=${PSD_OUT:-/scratch/RunSummary/psd}
[ $# -ge 1 ] || { sed -n '2,5p' "$0"; exit 1; }
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh
mkdir -p "$OUT"
root -l -b -q "$DIR/PsdScan.C+($1, \"$OUT/\", ${2:-0}, ${3:-99999}, ${4:--1})" 2>&1 | grep -v 'pragma\|^ *\^\|Warning in <TClass\|helper_functions.cc:3'
