#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  daily.sh - 날짜 기준 신호 계산 + 스펙트럼 (BuildDaily.C). 런별 파이프라인과 별개의 단계 (2026-09-14, 사용자 지시).
#
#   사용 : daily.sh [--dry-run]
#   환경 : RUNSUM_OUT   (기본 /scratch/RunSummary)   MONITORCUTS (기본 <저장소>/config/monitorcuts.params)
#
#   입력은 run_summary.tsv · runtype.tsv · dst/DST_<run>.root (dst-build.sh 가 만든 것 전부). 매번 전 런을 다시 센다 —
#   날짜 하나가 여러 런에 걸치고 런이 여러 날에 걸치므로 증분이 뜻이 없다. 실측 : 40 여 런에 10 분대.
#   출력 : daily_summary.tsv · daily_spectra.root · 32..52_*.png  (32 라이브타임 · 33/34 후보/일 · 35/36 rate · 37~40 스펙트럼 전/후
#          · 41~44 배경 성분별 스펙트럼 · 45~48 신호창 분해 · 49/50 prompt PSD · 51/52 샤워링 뮤온 뒤 dt + Li/He 적합)
#   컷은 metrics.sh 와 같은 monitorcuts.params 키를 읽는다 (mu_shower_npe · lihe_* · fn_e_*_mev). 이 단계만의 키 :
#      daily_psd_nsig   (기본 -1 = 끔)  prompt 의 p_psd 가 이 값을 넘는 쌍을 버린다 (on/off 같이)
#      fn_norm_mode     (기본 0)        0 = fast-n 을 사이드밴드 0차 외삽으로 · 1 = 신호창 고에너지 꼬리 [fn_norm_lo_mev, S1 상한] 로 규격화
#      fn_norm_lo_mev   (기본 8.5)
#      mu_veto_us       (기본 0 = 끔)   prompt 가 어느 veto 뮤온이든 그 뒤 이 µs 안이면 버린다 (DST 의 150 µs 를 늘리는 것. 라이브타임 보정)
#      shower_veto_ms   (기본 0 = 끔)   샤워링 뮤온 뒤 이 ms 안이면 버린다 (Li/He 직접 제거. 적합 창 아래끝을 그 값으로 올린다)
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd)
OUT=${RUNSUM_OUT:-/scratch/RunSummary}
CUTS=${MONITORCUTS:-$REPO/config/monitorcuts.params}
DRY=0
while [ $# -gt 0 ]; do
   case "${1:-}" in
      --dry-run) DRY=1; shift ;;
      -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
      *) echo "모르는 옵션 : $1"; exit 1 ;;
   esac
done
getp() {          # getp <키> <기본값>   (metrics.sh 와 같은 규칙)
   local k=$1 d=$2
   [ -r "$CUTS" ] || { printf '%s\n' "$d"; return; }
   awk -F= -v k="$k" '$1 ~ "^[ \t]*"k"[ \t]*$" { sub(/^[ \t]+/, "", $2); sub(/[ \t#].*$/, "", $2); if ($2 != "") { v = $2; f = 1 } }
      END { if (f) print v; else exit 1 }' "$CUTS" 2>/dev/null || printf '%s\n' "$d"
}
MU=$(getp mu_shower_npe 20000); LLO=$(getp lihe_fit_lo_s 0.002); LHI=$(getp lihe_fit_hi_s 10.0); LMIN=$(getp lihe_min_cand 50)
FLO=$(getp fn_e_lo_mev 12.0); FHI=$(getp fn_e_hi_mev 50.0); LFR=$(getp lihe_li_frac 1.0)
PSDC=$(getp daily_psd_nsig -1); FNM=$(getp fn_norm_mode 0); FNLO=$(getp fn_norm_lo_mev 8.5)
MUV=$(getp mu_veto_us 0); SHV=$(getp shower_veto_ms 0)
[ -d "$OUT" ] || { echo "출력 디렉터리가 없다 : $OUT (/scratch 마운트 확인)"; exit 1; }
[ -r "$OUT/run_summary.tsv" ] || { echo "run_summary.tsv 가 없다 (run-summary.sh 먼저)"; exit 1; }
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh
command -v root >/dev/null 2>&1 || { echo "ROOT 를 찾을 수 없다"; exit 1; }
ARGS="\"$OUT/\", $MU, $LLO, $LHI, $LMIN, $FLO, $FHI, $LFR, $PSDC, $FNM, $FNLO, $MUV, $SHV"
echo "날짜별 : $OUT/daily_summary.tsv · daily_spectra.root · 32..52_*.png   (컷 $CUTS · psd_nsig $PSDC · fn_norm $FNM/$FNLO · mu_veto ${MUV}us · shower_veto ${SHV}ms)"
if [ "$DRY" = 1 ]; then echo "(dry-run) root -l -b -q '$DIR/BuildDaily.C+($ARGS)'"; exit 0; fi
root -l -b -q "$DIR/BuildDaily.C+($ARGS)"
