#!/usr/bin/env bash
# monitor-runclass.test.sh -- gen-runclass.sh 의 분류 규칙(컨트롤러 판정 R9)
# 여섯 가지. sqlite3 CLI 가 있어야 돈다(runcatalog.db 픽스처를 만들고
# 읽어야 하므로 -- CLAUDE.md §0.0 이 sqlite3 를 이 프로젝트의 기존 런타임
# 의존으로 둔다). 없으면 SKIP. 실데이터·실 runcatalog.db(/Data_ssd)는
# 전혀 건드리지 않는다 -- 픽스처는 mktemp -d 안에 만든다.
#
#   ① calibration/physics/test/- 네 갈래 기본 분류
#   ② calibration 이 test 를 이긴다(선원 런이면서 onlbit=0 이어도 calibration)
#   ③ 출력 형식 -- '#' 헤더 + run<TAB>type
#   ④ 대상 런은 run_summary.tsv 에 있는 런 전부다(다른 TSV 에만 있는 런은
#      안 싣는다)
#   ⑤ DB 가 없거나 못 읽으면 src 만으로 "조용히"(stdout/stderr 에 [SAVED]
#      외 아무 줄도 없이) 분류하고 exit 0
#   ⑥ metrics_summary.tsv 가 있으면 pair_summary.tsv 보다 그것을 쓴다
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
SUT="$DIR/tools/monitor/gen-runclass.sh"

command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 없음"; exit 0; }
[ -r "$SUT" ] || { echo "FAIL: $SUT 없음"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R=""

type_of() { awk -F'\t' -v r="$2" '$1==r{print $2}' "$1"; }   # $1=runclass.tsv $2=run

# ================================================================ 픽스처 A ==
#  런 4개 + DB 로 분류 규칙 셋과 '-' 를 함께 본다.
#    4400  pair_summary src=AmBe(진짜 선원) + DB onlbit=0
#          -> calibration 이어야 한다(우선순위 : calibration > test)
#    4401  pair_summary 행 없음        + DB onlbit=1  -> physics
#    4402  pair_summary src=none(선원 아님) + DB onlbit=0 -> test
#    4403  pair_summary 행 없음        + DB 에도 없음 -> '-' (둘 다 모른다)
#  덧붙여 4499 를 pair_summary.tsv 에만 넣는다(run_summary.tsv 에는 없다) --
#  "대상 런은 run_summary.tsv 에 있는 런 전부" 를 검사 ④에서 이것으로 본다.
mkdir -p "$T/a"
cat > "$T/a/run_summary.tsv" <<'EOF'
# schema 2
#run	n_subrun	n_bad	epoch_start	epoch_end	wall_s	span_s	live_s	dead_s	n_type1	n_type2	n_type3	source
4400	10	0	1725000000	1725003600	3600.000	3600.000	3550.000	50.000	1000	200	50	prd
4401	10	0	1725100000	1725103600	3600.000	3600.000	3550.000	50.000	1000	200	50	prd
4402	10	0	1725200000	1725203600	3600.000	3600.000	3550.000	50.000	1000	200	50	prd
4403	10	0	1725300000	1725303600	3600.000	3600.000	3550.000	50.000	1000	200	50	prd
EOF
cat > "$T/a/pair_summary.tsv" <<'EOF'
# schema 2
#run	tag	src	live_s	n_paired	n_paired_acci	n_ibd	n_ibd_acci	dt_min	dt_max	dt_acci	s2_lo	s2_hi	iso_pre	iso_post	n_single	r_ll	n_subrun
4400	_nGd	AmBe	3550.000	50	5	8	1	0.0	100.0	400.0	5.0	12.0	0.0	400.0	12345	1.2300	10
4402	_nGd	none	3550.000	50	5	8	1	0.0	100.0	400.0	5.0	12.0	0.0	400.0	12345	1.2300	10
4499	_nGd	AmBe	3550.000	50	5	8	1	0.0	100.0	400.0	5.0	12.0	0.0	400.0	12345	1.2300	10
EOF

DB="$T/a/runcatalog.db"
sqlite3 "$DB" "CREATE TABLE runcatalog(runnum INTEGER PRIMARY KEY, onlbit INTEGER);
INSERT INTO runcatalog(runnum,onlbit) VALUES (4400,0),(4401,1),(4402,0);"

OUT_A="$T/a/runclass.tsv"
LOGA=$(RUNCLASS_DB="$DB" bash "$SUT" "$T/a" "$OUT_A" 2>&1); RCA=$?

# ① 기본 분류 넷
if [ "$RCA" -eq 0 ] \
   && [ "$(type_of "$OUT_A" 4400)" = "calibration" ] \
   && [ "$(type_of "$OUT_A" 4401)" = "physics" ] \
   && [ "$(type_of "$OUT_A" 4402)" = "test" ] \
   && [ "$(type_of "$OUT_A" 4403)" = "-" ]; then
   R="$R
CHK basic_classification=1"
else
   R="$R
CHK basic_classification=0"
   echo "진단(①) : rc=$RCA"; echo "$LOGA"; cat "$OUT_A" 2>&1
fi

# ② calibration 이 test 를 이긴다
[ "$(type_of "$OUT_A" 4400)" = "calibration" ] && R="$R
CHK calibration_beats_test=1" || R="$R
CHK calibration_beats_test=0"

# ③ '#' 헤더 + run<TAB>type 형식(데이터 줄은 전부 정확히 2열)
if head -1 "$OUT_A" | grep -q '^#' \
   && awk -F'\t' '!/^#/ && $0!=""{ if (NF!=2) exit 1 }' "$OUT_A"; then
   R="$R
CHK output_format=1"
else
   R="$R
CHK output_format=0"
fi

# ④ 대상 런은 run_summary.tsv 에 있는 런 전부다 -- pair_summary.tsv 에만
#    있는 4499(진짜 선원이 있어도)는 실리지 않는다
if ! grep -qE '^4499[[:space:]]' "$OUT_A"; then
   R="$R
CHK runs_scope=1"
else
   R="$R
CHK runs_scope=0"
fi

# ⑤ DB 가 없거나 못 읽으면 -- src 만으로 조용히 분류하고 exit 0.
#    "조용히" 를 stdout/stderr 에 [SAVED] 말고 아무 줄도 없는지로 본다.
OUT_A2="$T/a/runclass_nodb.tsv"
LOGA2=$(RUNCLASS_DB="$T/a/does-not-exist.db" bash "$SUT" "$T/a" "$OUT_A2" 2>&1); RCA2=$?
NOISE=$(printf '%s\n' "$LOGA2" | grep -v '^\[SAVED\]' | grep -c .)
if [ "$RCA2" -eq 0 ] && [ "$NOISE" -eq 0 ] \
   && [ "$(type_of "$OUT_A2" 4400)" = "calibration" ] \
   && [ "$(type_of "$OUT_A2" 4401)" = "-" ] \
   && [ "$(type_of "$OUT_A2" 4402)" = "-" ] \
   && [ "$(type_of "$OUT_A2" 4403)" = "-" ]; then
   R="$R
CHK db_missing_quiet=1"
else
   R="$R
CHK db_missing_quiet=0"
   echo "진단(⑤) : rc=$RCA2 noise=$NOISE"; echo "$LOGA2"
fi

# ================================================================ 픽스처 B ==
#  metrics_summary.tsv 가 있으면 pair_summary.tsv 보다 그것을 쓴다(둘 다
#  같은 런을 다루는 정상 운영 상황 -- websummary.sh 는 두 단계를 늘 함께
#  돌린다, metrics_source 와 무관하게). 같은 런에 서로 다른 src 를 주어
#  어느 쪽이 이기는지 본다.
mkdir -p "$T/b"
cat > "$T/b/run_summary.tsv" <<'EOF'
# schema 2
#run	n_subrun	n_bad	epoch_start	epoch_end	wall_s	span_s	live_s	dead_s	n_type1	n_type2	n_type3	source
4404	10	0	1725000000	1725003600	3600.000	3600.000	3550.000	50.000	1000	200	50	prd
EOF
cat > "$T/b/pair_summary.tsv" <<'EOF'
# schema 2
#run	tag	src	live_s	n_paired	n_paired_acci	n_ibd	n_ibd_acci	dt_min	dt_max	dt_acci	s2_lo	s2_hi	iso_pre	iso_post	n_single	r_ll	n_subrun
4404	_nGd	none	3550.000	50	5	8	1	0.0	100.0	400.0	5.0	12.0	0.0	400.0	12345	1.2300	10
EOF
cat > "$T/b/metrics_summary.tsv" <<'EOF'
# schema 1
#run	tag	src	live_s	n_paired	n_paired_acci	n_ibd	n_ibd_acci	n_single	r_ll	n_subrun	n_mu	n_mu_shower	n_lihe	e_lihe	lihe_stat	n_fn_side	n_fn_side_scaled	n_fn_mutag	dt_min	dt_max	dt_acci	s2_lo	s2_hi	iso_pre	iso_post	mu_shower_npe	fn_e_lo	fn_e_hi	fn_tag_s	lihe_fit_lo	lihe_fit_hi
4404	_nGd	Cs137	3550.000	50	5	8	1	12345	1.2300	10	5000	8	-1	-1	lowstat	20	-1	3	0.0	100.0	400.0	5.0	12.0	0.0	400.0	500	12.0	20.0	2.0	0.0	5.0
EOF

OUT_B="$T/b/runclass.tsv"
LOGB=$(bash "$SUT" "$T/b" "$OUT_B" 2>&1); RCB=$?
if [ "$RCB" -eq 0 ] && [ "$(type_of "$OUT_B" 4404)" = "calibration" ]; then
   R="$R
CHK metrics_over_pair=1"
else
   R="$R
CHK metrics_over_pair=0"
   echo "진단(⑥) : rc=$RCB"; echo "$LOGB"; cat "$OUT_B" 2>&1
fi

FAILED=0
for k in basic_classification calibration_beats_test output_format runs_scope \
         db_missing_quiet metrics_over_pair; do
   if echo "$R" | grep -q "CHK $k=1"; then
      :
   else
      echo "FAIL $k"
      FAILED=1
   fi
done
if [ "$FAILED" -ne 0 ]; then
   echo "-- $OUT_A --"; cat "$OUT_A" 2>&1
   echo "-- $OUT_B --"; cat "$OUT_B" 2>&1
   exit 1
fi
echo "PASS monitor-runclass (6/6)"
