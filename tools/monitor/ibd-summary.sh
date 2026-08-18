#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  ibd-summary.sh - production 을 마친 런에서 neutrino candidate 수를 세어
#                   pair_summary 에 이어붙인다.
#
#  ★ 2026-08-18 에 입력이 바뀌었다. 예전에는 /scratch/junkyo/SampleFiles 의
#    Step3/Step4 (분석 쪽 페어링 산출물)를 읽었다. 그러면 저쪽이 그 런을
#    아직 안 돌렸을 때 이 표가 멈춘다 -- 실제로 1단계가 run 4291 까지 갔는데
#    2단계는 4240 에서 멎어 있었다. 이제 **1단계와 똑같이 PRD 를 읽고
#    페어링까지 여기서 한다.**
#
#  run-summary.sh 와 짝이다. 순서가 있다 --
#      1) run-summary.sh   livetime 을 만든다
#      2) ibd-summary.sh   candidate 를 세고 /day 를 낸다
#  거꾸로 돌려도 죽지 않는다. 두 단계가 각자 PRD 에서 livetime 을 재기 때문에
#  이제 서로를 기다리지 않는다.
#
#  사용 :
#      tools/monitor/ibd-summary.sh                  PRD 가 있는 런을 전부
#      tools/monitor/ibd-summary.sh 4237 4240        범위를 지정해서
#      tools/monitor/ibd-summary.sh --list 4237,4239 목록으로
#      tools/monitor/ibd-summary.sh --newest 2       아직 안 한 것 중 최신 2개만
#      tools/monitor/ibd-summary.sh --force 4240     이미 있어도 다시 계산
#      tools/monitor/ibd-summary.sh --max-subrun 200 서브런 200 까지만 (맛보기)
#      tools/monitor/ibd-summary.sh --show           결과만 본다
#      tools/monitor/ibd-summary.sh --dry-run        무엇을 할지만 본다
#      tools/monitor/ibd-summary.sh --missing        아직 안 센 런을 알려준다
#
#  ---- 비용 ----
#  파형을 읽어 에너지를 재구성하므로 1단계보다 훨씬 비싸다. 실측 --
#      로컬 NVMe(/Data_ssd)  약 1.1 s/서브런   24h 런(1440) = 약 27분
#      /scratch (100 Mb 링크) 약 14.6 s/서브런  24h 런        = 약 5.8시간
#  그래서 **런이 /Data_ssd 에 있을 때 돌리는 것이 압도적으로 유리하다.**
#  서브런마다 결과를 캐시(<OUT>/cache/singles)하므로 중간에 끊겨도 한 것은
#  남고, 두 번째 실행부터는 파형을 다시 읽지 않는다.
#  자동화에서는 --newest 로 끊어 조금씩 따라잡는 편이 낫다.
#
#  경로 (환경변수)
#      RUNSUM_OUT     기본 /scratch/RunSummary
#      RUNSUM_RAW     기본 /Data_ssd/RAW:/data/RAW:/scratch/RAW
#                     ':' 로 여럿. 앞에 오는 것이 이긴다(= 빠른 디스크 먼저)
#      RUNSUM_SAMPLE  기본 /scratch/junkyo/SampleFiles
#                     **대조용으로만** 쓴다. 분석 쪽 Step4 가 있는 런에서는
#                     수를 맞춰 보고 갈라졌는지 알려준다. 없어도 무방하다.
#      RENE_COND      기본 /home/ojk/analysis3/essential/AnalysisCondition.h
#                     컷 상수의 정본. 복제하지 않고 이것을 읽는다
# ---------------------------------------------------------------------
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
MACRO=$DIR/BuildPairSummary.C
OUT=${RUNSUM_OUT:-/scratch/RunSummary}
RAW=${RUNSUM_RAW:-/Data_ssd/RAW:/data/RAW:/scratch/RAW}
SAMPLE=${RUNSUM_SAMPLE:-/scratch/junkyo/SampleFiles}
COND=${RENE_COND:-/home/ojk/analysis3/essential/AnalysisCondition.h}
FORCE=0; DRY=0; MISSING=0; LIST=""; LO=""; HI=""; NEWEST=0; MAXSUB=-1

while [ $# -gt 0 ]; do
   case "${1:-}" in
      --force)   FORCE=1; shift ;;
      --dry-run) DRY=1; shift ;;
      --missing) MISSING=1; shift ;;
      --list)    LIST=${2:-}; shift 2 ;;
      --newest)  NEWEST=${2:-0}; shift 2 ;;
      --max-subrun) MAXSUB=${2:--1}; shift 2 ;;
      --show)
         [ -r "$OUT/pair_summary.txt" ] || { echo "아직 없다 : $OUT/pair_summary.txt"; exit 1; }
         exec cat "$OUT/pair_summary.txt" ;;
      -h|--help) sed -n '2,47p' "$0"; exit 0 ;;
      -*)        echo "모르는 옵션 : $1"; sed -n '2,47p' "$0"; exit 1 ;;
      *)         if [ -z "$LO" ]; then LO=$1; else HI=$1; fi; shift ;;
   esac
done

[ -r "$MACRO" ] || { echo "매크로가 없다 : $MACRO"; exit 1; }
if [ ! -r "$COND" ]; then
   echo "컷 상수 헤더를 읽을 수 없다 : $COND"
   echo "이 값이 없으면 dt 창을 몰라 우발을 뺄 수 없다. RENE_COND 로 경로를 줄 것."
   exit 1
fi

# PRD 가 있는 런. run-summary.sh 의 have_runs 와 같은 규칙이다.
have_runs() {
   local r
   printf '%s' "$RAW" | tr ':' '\n' | awk 'NF' | while read -r r; do
      ls -dU "${r%/}"/[0-9][0-9][0-9][0-9][0-9][0-9]/PRD 2>/dev/null
   done | sed -n 's|.*/0*\([0-9][0-9]*\)/PRD$|\1|p' | sort -n -u
}
already() {
   [ -r "$OUT/pair_summary.tsv" ] || return 0
   grep -v '^#' "$OUT/pair_summary.tsv" 2>/dev/null | awk 'NF{print $1}' | sort -n -u
}

if [ "$MISSING" -eq 1 ]; then
   A=$(have_runs); P=$(already)
   if [ -z "$A" ]; then echo "PRD 가 있는 런을 찾지 못했다 : $RAW"; exit 1; fi
   M=$(comm -23 <(printf '%s\n' "$A") <(printf '%s\n' "${P:-}"))
   if [ -z "${M//[[:space:]]/}" ]; then echo "빠진 런은 없다."; exit 0; fi
   echo "아직 후보를 세지 않은 런 ($(printf '%s\n' "$M" | awk 'NF' | wc -l) 개) :"
   printf '%s\n' "$M" | awk 'NF' | paste -sd, - | fold -s -w 76 | sed 's/^/  /'
   echo "  -> $0 --newest 2   처럼 조금씩 따라잡는 것이 낫다"
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

#  한 번에 다 하려 들면 며칠 물린다. 최신 것부터 조금씩 따라잡는다.
if [ "$NEWEST" -gt 0 ]; then
   NEW=$(printf '%s\n' "$NEW" | awk 'NF' | sort -n | tail -n "$NEWEST")
fi

# 새 런이 없어도 한 번은 돌린다 -- runtype.tsv 가 그 사이 생겼으면
# 기존 행의 선원 칸을 채워야 하기 때문이다.
if [ -z "${NEW//[[:space:]]/}" ]; then
   if [ -r "$OUT/pair_summary.tsv" ]; then
      echo "새로 더할 런은 없다. 선원 정보 보충만 시도한다."
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

#  대조는 있으면 하고 없으면 만다. 없다고 실패시키지 않는다.
CHK=$SAMPLE
[ -d "$SAMPLE/Step3" ] || CHK=""

echo "출력  : $OUT   (캐시 $OUT/cache/singles)"
echo "입력  : <root>/<run>/PRD  (읽기 전용)  root = $RAW"
echo "컷    : $COND"
[ -n "$CHK" ] && echo "대조  : $CHK/Step3  (분석 Step4 가 있는 런만)" \
              || echo "대조  : 없음 ($SAMPLE/Step3 를 읽을 수 없다)"
echo "대상  : $NCNT 개 런 -> $SHOWN"

FLAG=$([ "$FORCE" -eq 1 ] && echo true || echo false)
ARGS="\"$CSV\", $FLAG, \"$OUT/\", \"$RAW\", 150.0, $MAXSUB, \"$CHK\""
if [ "$DRY" -eq 1 ]; then
   echo "[DRY] root -l -b -q '$MACRO+(\"<위 $NCNT 개>\", $FLAG, \"$OUT/\", \"$RAW\", 150.0, $MAXSUB, \"$CHK\")'"
   exit 0
fi

root -l -b -q "$MACRO+($ARGS)"
rc=$?
[ $rc -eq 0 ] && echo "결과를 보려면 : $0 --show"
exit $rc
