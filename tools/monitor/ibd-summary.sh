#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  ibd-summary.sh - 페어링이 끝난 런에서 neutrino candidate 수를 뽑아
#                   pair_summary 에 이어붙인다.
#
#  run-summary.sh 와 짝이다. 순서가 있다 --
#      1) run-summary.sh   livetime 을 만든다
#      2) ibd-summary.sh   candidate 를 세고, 위 livetime 을 붙여 /day 를 낸다
#  거꾸로 돌려도 죽지는 않는다. cand/day 칸만 비고, 나중에 다시 돌리면 채워진다.
#
#  사용 :
#      tools/monitor/ibd-summary.sh                  페어링된 런을 전부
#      tools/monitor/ibd-summary.sh 4237 4240        범위를 지정해서
#      tools/monitor/ibd-summary.sh --list 4237,4239 목록으로
#      tools/monitor/ibd-summary.sh --force 4240     이미 있어도 다시 계산
#      tools/monitor/ibd-summary.sh --show           결과만 본다
#      tools/monitor/ibd-summary.sh --dry-run        무엇을 할지만 본다
#      tools/monitor/ibd-summary.sh --missing        페어링이 안 된 런을 찾아준다
#
#  경로 (환경변수)
#      RUNSUM_OUT     기본 /scratch/RunSummary
#      RUNSUM_SAMPLE  기본 /scratch/junkyo/SampleFiles
#      RENE_COND      기본 /home/ojk/analysis3/essential/AnalysisCondition.h
#                     컷 상수의 정본. 복제하지 않고 이것을 읽는다
# ---------------------------------------------------------------------
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
MACRO=$DIR/BuildPairSummary.C
OUT=${RUNSUM_OUT:-/scratch/RunSummary}
SAMPLE=${RUNSUM_SAMPLE:-/scratch/junkyo/SampleFiles}
COND=${RENE_COND:-/home/ojk/analysis3/essential/AnalysisCondition.h}
FORCE=0; DRY=0; MISSING=0; LIST=""; LO=""; HI=""

while [ $# -gt 0 ]; do
   case "${1:-}" in
      --force)   FORCE=1; shift ;;
      --dry-run) DRY=1; shift ;;
      --missing) MISSING=1; shift ;;
      --list)    LIST=${2:-}; shift 2 ;;
      --show)
         [ -r "$OUT/pair_summary.txt" ] || { echo "아직 없다 : $OUT/pair_summary.txt"; exit 1; }
         exec cat "$OUT/pair_summary.txt" ;;
      -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
      -*)        echo "모르는 옵션 : $1"; sed -n '2,28p' "$0"; exit 1 ;;
      *)         if [ -z "$LO" ]; then LO=$1; else HI=$1; fi; shift ;;
   esac
done

[ -r "$MACRO" ] || { echo "매크로가 없다 : $MACRO"; exit 1; }
if [ ! -r "$COND" ]; then
   echo "컷 상수 헤더를 읽을 수 없다 : $COND"
   echo "이 값이 없으면 dt 창을 몰라 우발을 뺄 수 없다. RENE_COND 로 경로를 줄 것."
   exit 1
fi

# 페어링이 끝난 런 = step4 파일이 있는 런 (채널 태그는 뭐든)
paired_runs() {
   ls "$SAMPLE"/Step3/step4_Run*.root 2>/dev/null |
      sed -n 's|.*/step4_Run0*\([0-9][0-9]*\)_n.*\.root|\1|p' | sort -n -u
}
# run_summary 에는 있는데 아직 페어링이 안 된 런
analysed_runs() {
   [ -r "$OUT/run_summary.tsv" ] || return 0
   grep -v '^#' "$OUT/run_summary.tsv" 2>/dev/null | awk 'NF{print $1}' | sort -n -u
}
already() {
   [ -r "$OUT/pair_summary.tsv" ] || return 0
   grep -v '^#' "$OUT/pair_summary.tsv" 2>/dev/null | awk 'NF{print $1}' | sort -n -u
}

if [ "$MISSING" -eq 1 ]; then
   A=$(analysed_runs); P=$(paired_runs)
   if [ -z "$A" ]; then echo "run_summary.tsv 가 없다. run-summary.sh 를 먼저 돌릴 것."; exit 1; fi
   M=$(comm -23 <(printf '%s\n' "$A") <(printf '%s\n' "${P:-}"))
   if [ -z "${M//[[:space:]]/}" ]; then echo "페어링이 빠진 런은 없다."; exit 0; fi
   echo "페어링이 아직 안 된 런 ($(printf '%s\n' "$M" | awk 'NF' | wc -l) 개) :"
   printf '%s\n' "$M" | awk 'NF{printf "  root -l -b -q '\''RunBothChannels.C(%s)'\''\n", $1}'
   echo "위는 /home/ojk/analysis3 에서 돌려야 한다 (그 계정의 코드다)."
   exit 0
fi

# ---- ROOT ----
if ! command -v root >/dev/null 2>&1; then
   # shellcheck disable=SC1091
   [ -r /usr/local/bin/thisroot.sh ] && . /usr/local/bin/thisroot.sh
fi
command -v root >/dev/null 2>&1 || { echo "ROOT 를 찾을 수 없다. thisroot.sh 를 source 할 것"; exit 1; }

mkdir -p "$OUT" 2>/dev/null
[ -w "$OUT" ] || { echo "출력 디렉터리에 쓸 수 없다 : $OUT"; exit 1; }

# ---- 선원 정보 ----
#  AmBe 같은 교정 런의 후보 수는 neutrino 가 아니다. 표에서 구분하지 않으면
#  선원이 만든 중성자가 그대로 후보에 섞인다(4221·4224 가 실제로 그렇다).
#  런카탈로그의 rundesc 에서 선원 이름을 뽑아 둔다.
DB=${RUNSUM_DB:-/Data_ssd/runcatalog.db}
if command -v sqlite3 >/dev/null 2>&1 && [ -r "$DB" ]; then
   {
      echo "# run<TAB>src  -- runcatalog.db 의 rundesc 에서 뽑았다"
      sqlite3 -separator '|' "$DB" \
         "select runnum, replace(replace(ifnull(rundesc,''),char(10),' '),char(9),' ') from runcatalog;" |
      awk -F'|' '{
         d = $2; s = "?";
         if (d ~ /[Nn]o [Ss]ource/)       s = "none";
         if (d ~ /AmBe/)                  s = "AmBe";
         else if (d ~ /Cs-?137/)          s = "Cs137";
         else if (d ~ /Co-?60/)           s = "Co60";
         else if (d ~ /Na-?22/)           s = "Na22";
         else if (d ~ /Zn-?65/)           s = "Zn65";
         else if (d ~ /Cf-?252/)          s = "Cf252";
         if (s != "?") printf "%s\t%s\n", $1, s;
      }'
   } > "$OUT/runtype.tsv.tmp" && mv -f "$OUT/runtype.tsv.tmp" "$OUT/runtype.tsv"
   echo "선원  : $(grep -vc '^#' "$OUT/runtype.tsv" 2>/dev/null) 개 런을 런카탈로그에서 확인"
else
   echo "선원  : 런카탈로그를 읽을 수 없다 ($DB). 선원 런을 구분하지 못한다"
   echo "        -> 합계에서 전부 제외되므로 숫자가 비어 보일 수 있다"
fi

if [ -n "$LIST" ]; then
   TARGET=$(printf '%s' "$LIST" | tr ',' '\n' | awk 'NF')
elif [ -n "$LO" ]; then
   [ -n "$HI" ] || HI=$LO
   TARGET=$(paired_runs | awk -v a="$LO" -v b="$HI" '$1>=a && $1<=b')
   [ -n "$TARGET" ] || { echo "$LO..$HI 범위에 페어링된 런이 없다 (--missing 으로 확인)"; exit 0; }
else
   TARGET=$(paired_runs)
   [ -n "$TARGET" ] || { echo "페어링 산출물을 찾지 못했다 : $SAMPLE/Step3"; exit 0; }
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

# 새 런이 없어도 한 번은 돌린다 -- run_summary 가 그 사이 생겼으면
# 기존 행의 livetime 칸을 채워야 하기 때문이다.
if [ -z "${NEW//[[:space:]]/}" ]; then
   if [ -r "$OUT/run_summary.tsv" ] && [ -r "$OUT/pair_summary.tsv" ]; then
      echo "새로 더할 런은 없다. livetime 보충만 시도한다."
      NEW=$(already | head -1)
      [ -n "$NEW" ] || { echo "표가 비어 있다."; exit 0; }
   else
      echo "새로 더할 런이 없다. 결과를 보려면 --show."
      exit 0
   fi
fi

CSV=$(printf '%s\n' "$NEW" | awk 'NF' | paste -sd, -)
NCNT=$(printf '%s\n' "$NEW" | awk 'NF' | wc -l)
if [ "$NCNT" -le 12 ]; then SHOWN=$CSV
else SHOWN="$(printf '%s\n' "$NEW" | awk 'NF' | head -5 | paste -sd, -) ... $(printf '%s\n' "$NEW" | awk 'NF' | tail -3 | paste -sd, -)"; fi

echo "출력  : $OUT"
echo "입력  : $SAMPLE/Step3  (읽기 전용)"
echo "컷    : $COND"
echo "대상  : $NCNT 개 런 -> $SHOWN"

FLAG=$([ "$FORCE" -eq 1 ] && echo true || echo false)
if [ "$DRY" -eq 1 ]; then
   echo "[DRY] root -l -b -q '$MACRO+(\"<위 $NCNT 개>\", $FLAG, \"$OUT/\", \"$SAMPLE/\")'"
   exit 0
fi

root -l -b -q "$MACRO+(\"$CSV\", $FLAG, \"$OUT/\", \"$SAMPLE/\")"
rc=$?
[ $rc -eq 0 ] && echo "결과를 보려면 : $0 --show"
exit $rc
