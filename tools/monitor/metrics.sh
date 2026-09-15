#!/usr/bin/env bash
# metrics.sh - DST 에서 metrics_summary.tsv 를 만든다 (3차 프로덕션 단계).
#   사용 : metrics.sh --list 4237,4240 [--force] [--verify] [--dry-run]
#          metrics.sh --verify                     빌드 없이 대조만
#   환경 : RUNSUM_OUT   (기본 /scratch/RunSummary)
#          MONITORCUTS  (기본 <저장소>/config/monitorcuts.params)
#
#   --verify : metrics_summary.tsv 와 pair_summary.tsv 의 공통 (run,tag) 행에서
#   n_ibd·n_ibd_acci 를 대조한다. 다르면 exit 1 (dst 전환 게이트의 실행형).
#   --list 와 함께 주면 먼저 만들고 나서 대조한다.
#
#   ---- 컷은 config/monitorcuts.params 에서 온다 ----
#   배경 레시피 v2 의 ★예비 컷(mu_shower_npe / lihe_fit_lo_s / lihe_fit_hi_s /
#   lihe_min_cand / fn_e_lo_mev / fn_e_hi_mev / lihe_li_frac / psd_nsig)을 읽어
#   매크로 인자로 넘긴다. 파일이 없으면 아래 getp 의 기본값을 쓰며, 그 값은
#   config/monitorcuts.params.example 에 적힌 것과 같다. 옛 키 fn_tag_s 는
#   더 이상 쓰지 않는다 (있으면 경고만 하고 무시한다).
#
#   IBD 컷 오버라이드 10종(s1_lo_npe s1_hi_npe s2_lo_mev s2_hi_mev dt_min_us
#   dt_max_us dt_acci_us iso_pre_us iso_post_us lower_npe)은 params 에서
#   **주석을 푼 것만** 모아 "k=v,k=v" 로 넘긴다. 하나라도 있으면
#   AnalysisCondition.h 와 컷이 달라지므로 **--verify 를 그 자리에서 거부한다** --
#   legacy 와 다른 컷으로 낸 수를 대조해 봐야 뜻이 없고, 게이트를 통과한 척하게
#   둘 수는 더욱 없다.
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$DIR/../.." && pwd)
OUT=${RUNSUM_OUT:-/scratch/RunSummary}
CUTS=${MONITORCUTS:-$REPO/config/monitorcuts.params}
LIST=""; FORCE=false; DRY=0; DO_VERIFY=0; VERIFY_RUNS=""

while [ $# -gt 0 ]; do
   case "${1:-}" in
      --list)    LIST=${2:-}; shift 2 ;;
      --force)   FORCE=true; shift ;;
      --verify)  DO_VERIFY=1; shift ;;
      --verify-runs) DO_VERIFY=1; VERIFY_RUNS=$2; shift 2 ;;     # 이 런들만 대조 (쉼표). 발행 게이트는 새 런에만 건다
      --dry-run) DRY=1; shift ;;
      -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
      *) echo "모르는 옵션 : $1"; exit 1 ;;
   esac
done

#  'key = value' 한 줄을 읽는다 (dataflow.sh 의 load_params 와 같은 규칙 --
#  '#' 뒤는 주석, 앞뒤 공백은 버리고, 같은 키가 여러 번이면 나중 것이 이긴다).
#  없으면 기본값을 낸다.
#  ★ 앞 공백을 **먼저** 떼야 한다. 'k = 3000' 의 값 쪽은 " 3000   # ..." 이라
#    공백/'#' 부터 통째로 자르면 값까지 사라진다.
getp() {          # getp <키> <기본값>
   local k=$1
   local d=$2
   [ -r "$CUTS" ] || { printf '%s\n' "$d"; return; }
   awk -F= -v k="$k" '
      $1 ~ "^[ \t]*"k"[ \t]*$" {
         sub(/^[ \t]+/, "", $2); sub(/[ \t#].*$/, "", $2)
         if ($2 != "") { v = $2; f = 1 }
      }
      END { if (f) print v; else exit 1 }' "$CUTS" 2>/dev/null || printf '%s\n' "$d"
}

MU_SHOWER_NPE=$(getp mu_shower_npe 20000)
LIHE_FIT_LO_S=$(getp lihe_fit_lo_s 0.002)
LIHE_FIT_HI_S=$(getp lihe_fit_hi_s 10.0)
LIHE_MIN_CAND=$(getp lihe_min_cand 50)
FN_E_LO_MEV=$(getp fn_e_lo_mev 12.0)
FN_E_HI_MEV=$(getp fn_e_hi_mev 50.0)
LIHE_LI_FRAC=$(getp lihe_li_frac 1.0)
PSD_NSIG=$(getp psd_nsig 3.0)
METRICS_DSTSUB=$(getp metrics_dst_subdir dst)   # 런별 지표가 읽을 DST 폴더. dst = 패널 AND veto(legacy 와 같다) · dst_m2 = 강한 veto (2026-09-15)
[ -n "$(getp fn_tag_s "")" ] && echo "[WARN] fn_tag_s 는 v2 에서 쓰지 않는다. 무시한다 ($CUTS)"

#  IBD 컷 오버라이드 : 기본값이 없다. params 에 있는 것만 모은다
#  (없으면 AnalysisCondition.h 값을 그대로 쓴다는 뜻이다).
IBD_OVR=""
for k in s1_lo_npe s1_hi_npe s2_lo_mev s2_hi_mev dt_min_us dt_max_us \
         dt_acci_us iso_pre_us iso_post_us lower_npe; do
   v=$(getp "$k" "")
   [ -n "$v" ] || continue
   IBD_OVR="${IBD_OVR}${IBD_OVR:+,}$k=$v"
done

[ -n "$IBD_OVR" ] && [ "$DO_VERIFY" = 1 ] && {
   echo "[VERIFY] IBD 오버라이드($IBD_OVR)가 있어 legacy 대조가 무의미하다. 거부한다."
   exit 1; }

verify() {
   if [ "$METRICS_DSTSUB" != dst ]; then
      echo "[VERIFY] metrics_dst_subdir=$METRICS_DSTSUB : legacy(pair_summary) 는 패널 AND veto 라 대조가 뜻이 없다 -- 건너뛴다 (불일치 0 으로 본다)"
      return 0
   fi
   local mfile pfile
   mfile="$OUT/metrics_summary.tsv"
   pfile="$OUT/pair_summary.tsv"
   [ -r "$mfile" ] && [ -r "$pfile" ] || { echo "[VERIFY] 두 표가 다 있어야 한다"; return 1; }
   #  --verify-runs 가 있으면 그 런만 본다. DIFF 줄에 livetime 을 함께 찍는다 — 한쪽이 런이 덜 끝났을 때 계산된 것이면
   #  (DST 가 낡음, 2026-09-11 의 run 4341 : 83339 s 대 86380 s) 그 값이 바로 갈라 준다.
   awk -F'\t' -v M="$mfile" -v only="$VERIFY_RUNS" '
      BEGIN { nsel = split(only, a, ","); for (i = 1; i <= nsel; i++) if (a[i] != "") sel[a[i]] = 1 }
      /^#/ { next }
      FILENAME==M { ibd[$1 $2]=$7; acc[$1 $2]=$8; live[$1 $2]=$4; next }
      ($1 $2) in ibd {
         if (nsel > 0 && !($1 in sel)) next
         n++
         if (ibd[$1 $2] != $7 || acc[$1 $2] != $8) {
            bad++
            printf "  [DIFF] run %s%s : metrics ibd=%s acci=%s live=%s / legacy ibd=%s acci=%s live=%s%s\n",
                   $1, $2, ibd[$1 $2], acc[$1 $2], live[$1 $2], $7, $8, $4,
                   (live[$1 $2]+0 < $4+0) ? "   <- DST 쪽 livetime 이 짧다 : DST 가 런이 덜 끝났을 때 만들어졌다. dst-build --force" :
                   (live[$1 $2]+0 > $4+0) ? "   <- legacy 쪽 livetime 이 짧다 : ibd-summary --force" : "" }
      }
      END {
         printf "[VERIFY] 공통 %d 행, 불일치 %d%s%s\n", n, bad, (nsel > 0) ? "  (대상 런 " only ")" : "",
                (nsel > 0 && n == 0) ? "  -- 대조할 행이 없다 (legacy 쪽이 아직 없다). 막지 않는다" : ""
         #  런을 지정했는데 공통 행이 없으면 아직 대조할 수 없는 것이지 불일치가 아니다 -> 0  (awk 안 주석에 작은따옴표 금지)
         exit (bad == 0 && (n > 0 || nsel > 0)) ? 0 : 1
      }' "$mfile" "$pfile"
}

[ -n "$LIST" ] || [ "$DO_VERIFY" -eq 1 ] || { echo "--list 또는 --verify 가 필요하다"; exit 1; }

if [ -n "$LIST" ]; then
   [ -d "$OUT" ] || { echo "출력 디렉터리가 없다 : $OUT (/scratch 마운트 확인)"; exit 1; }
   command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh
   command -v root >/dev/null 2>&1 || { echo "ROOT 를 찾을 수 없다"; exit 1; }
   echo "지표  : $OUT/metrics_summary.tsv   런 : $LIST   DST : $OUT/$METRICS_DSTSUB/"
   if [ -r "$CUTS" ]; then echo "컷    : $CUTS"; else echo "컷    : 기본값 ($CUTS 없음)"; fi
   [ -n "$IBD_OVR" ] && echo "★ IBD 오버라이드 : $IBD_OVR  (--verify 는 거부된다)"
   ARGS="\"$LIST\", \"$OUT/\", $MU_SHOWER_NPE, $LIHE_FIT_LO_S, $LIHE_FIT_HI_S, $LIHE_MIN_CAND, $FN_E_LO_MEV, $FN_E_HI_MEV, $LIHE_LI_FRAC, $PSD_NSIG, $FORCE, \"$IBD_OVR\", \"$METRICS_DSTSUB\""
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
