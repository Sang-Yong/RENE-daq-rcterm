#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  gen-runclass.sh <tsvdir> <out.tsv>
#
#  런마다 type(physics/calibration/test) 을 매긴다. 분류 규칙은 이 스크립트
#  하나뿐이다(컨트롤러 판정 R9) -- 소비자(gen-summary-html.sh,
#  publish_google.py)는 이 파일을 run 을 키로만 읽는다. 열 위치를 옮기지
#  않는다.
#
#    calibration  그 런의 src (metrics_summary.tsv 가 있으면 그것, 없으면
#                 pair_summary.tsv, 3열) 가 진짜 선원 이름이다
#                 (none/?/-/빈값이 아니면 전부 -- ibd-summary.sh 의 AmBe 등
#                 닫힌 집합과 같은 결론이지만, 그 집합이 나중에 늘어도 이
#                 스크립트는 고칠 필요가 없도록 일부러 부정 판정으로 뒀다.
#                 한 런에 태그(_nGd/_nH)별로 행이 둘이면, 어느 한쪽이라도
#                 진짜 선원이면 calibration -- 둘 다 아니어야 아니다)
#    test         runcatalog.db 가 그 런을 onlbit=0 이라 한다
#    physics      그 밖, onlbit=1 로 아는 경우
#    -            src 도 DB 도 그 런을 모른다
#    우선순위     calibration > test > physics (선원을 넣고 받다가 aborted
#                 된 런도 표를 읽을 때는 여전히 calibration 이다)
#
#  DB 가 없거나 못 읽거나 sqlite3 가 없으면 -- src 만으로 조용히 분류하고
#  exit 0 이다. 이 스크립트가 죽어서 웹 발행 전체를 막으면 안 된다
#  (chainwatch 원칙, CLAUDE.md §11.138). 호출자(websummary.sh)도 이 스크립트
#  실패를 WARN 으로만 다룬다 -- type 열은 그러면 그냥 전부 '-' 로 뜬다.
#
#  출력 : run<TAB>type 줄 + '#' 헤더 두 줄. 대상 런은 run_summary.tsv 에
#  있는 런 전부다(다른 TSV 에 없어도 낸다 -- 모르면 '-').
#
#  환경 : RUNCLASS_DB   runcatalog.db 경로. 기본 /Data_ssd/runcatalog.db
# ---------------------------------------------------------------------
set -u

USAGE='사용법 : gen-runclass.sh <TSV디렉터리> <출력.tsv>'
TSV=${1:?$USAGE}
OUTF=${2:?$USAGE}
DB=${RUNCLASS_DB:-/Data_ssd/runcatalog.db}

RS="$TSV/run_summary.tsv"
[ -r "$RS" ] || { echo "run_summary.tsv 가 없다 : $RS"; exit 1; }

MS="$TSV/metrics_summary.tsv"
PS="$TSV/pair_summary.tsv"
if   [ -r "$MS" ]; then SRCFILE=$MS
elif [ -r "$PS" ]; then SRCFILE=$PS
else SRCFILE=""
fi

mkdir -p "$(dirname "$OUTF")" 2>/dev/null

#  DB : onlbit 을 한 번에 읽는다 (badrun.sh load_db() 와 같은 관용구).
#  없거나 못 읽거나 sqlite3 가 없으면 DBROWS 는 그냥 빈 채로 넘어간다 --
#  여기서 실패를 알리지 않는다. '조용히' 가 요구사항이다.
DBROWS=""
if [ -r "$DB" ] && command -v sqlite3 >/dev/null 2>&1; then
   DBROWS=$(sqlite3 -separator '|' "$DB" \
      "select runnum, coalesce(onlbit,'') from runcatalog;" 2>/dev/null)
fi

AWK_FILES=("$RS")
[ -n "$SRCFILE" ] && AWK_FILES+=("$SRCFILE")

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT

awk -F'\t' -v RSF="$RS" -v SRCFILE="$SRCFILE" -v dbrows="$DBROWS" '
   function is_source(s) {
      return (s != "" && s != "none" && s != "?" && s != "-")
   }
   BEGIN {
      n = split(dbrows, lines, "\n")
      for (i = 1; i <= n; i++) {
         if (lines[i] == "") continue
         split(lines[i], f, "|")
         onl[f[1]] = f[2]
      }
   }
   /^#/ { next }
   NF < 1 { next }
   FILENAME == RSF     { runs[$1] = 1; next }
   FILENAME == SRCFILE { if (is_source($3)) src[$1] = $3; next }
   END {
      PROCINFO["sorted_in"] = "@ind_num_asc"
      for (r in runs) {
         if      (r in src)      t = "calibration"
         else if (onl[r] == "0") t = "test"
         else if (onl[r] == "1") t = "physics"
         else                    t = "-"
         print r "\t" t
      }
   }
' "${AWK_FILES[@]}" > "$TMP"

{
   echo "# schema 1"
   printf '#run\ttype\n'
   cat "$TMP"
} > "$OUTF"

echo "[SAVED] $OUTF ($(wc -l < "$TMP") 행)"
