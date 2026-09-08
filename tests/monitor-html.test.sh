#!/usr/bin/env bash
# monitor-html.test.sh -- gen-summary-html.sh 가 스펙 §5 의 15열 표를
# 정확히 만드는지. bash/awk 만 있으면 되므로 ROOT 없이도 언제나 돈다.
# 실데이터·실디스크는 건드리지 않는다 -- 픽스처는 mktemp -d 안에 만든다.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
SUT="$DIR/tools/monitor/gen-summary-html.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# ---- 픽스처 : 런 3개. 파일 안 순서는 일부러 흩어 정렬을 실제로 시험한다 ----
#   4312  최신. src='none'(보통의 물리 런 -- 선원 없음. 실데이터로 실측한
#         관례다, BuildPairSummary.C:92 "AmBe | Cs137 | ... | none | ?").
#         dst 값이 둘 다 정상(lihe_stat=ok, n_fn_side_scaled>=0)
#         -> dst 모드에서 fast-n·Li/He 에 '(예비)' 가 붙고, 'none' 은
#            강조(.src)되지 않아야 한다
#   4310  AmBe 선원(진짜 강조 대상). dst 는 lowstat/fn<0
#         -> legacy·dst 모두 fast-n·Li/He 는 '—'
#   4308  run_summary 행만 있고 pair_summary/metrics_summary 행이 아예 없다
#         -> IBD/acci/R_LL/선원 이 '-' 로 내려가야 한다(열이 밀리면 안 된다)
cat > "$T/run_summary.tsv" <<'EOF'
# schema 2
#run	n_subrun	n_bad	epoch_start	epoch_end	wall_s	span_s	live_s	dead_s	n_type1	n_type2	n_type3	source
4310	1440	1	1725100000	1725186400	86400.000	86400.000	82800.000	3600.000	900000	15000	450000	prd
4308	100	0	1725000000	1725003600	3600.000	3600.000	3550.000	50.000	100000	2000	50000	prd
4312	1440	0	1725300000	1725386400	86400.000	86400.000	86000.000	400.000	950000	16000	470000	prd
EOF

cat > "$T/pair_summary.tsv" <<'EOF'
# schema 2
#run	tag	src	live_s	n_paired	n_paired_acci	n_ibd	n_ibd_acci	dt_min	dt_max	dt_acci	s2_lo	s2_hi	iso_pre	iso_post	n_single	r_ll	n_subrun
4310	_nGd	AmBe	82800.000	500	50	82	8	0.0	100.0	400.0	5.0	12.0	0.0	400.0	123456	12.3400	1440
4310	_nH	AmBe	82800.000	900	90	620	60	0.0	800.0	3200.0	1.5	5.5	0.0	3200.0	654321	45.6700	1440
4312	_nGd	none	86000.000	520	45	90	7	0.0	100.0	400.0	5.0	12.0	0.0	400.0	130000	13.1000	1440
4312	_nH	none	86000.000	950	88	640	55	0.0	800.0	3200.0	1.5	5.5	0.0	3200.0	660000	46.2000	1440
EOF

cat > "$T/metrics_summary.tsv" <<'EOF'
# schema 1
#run	tag	src	live_s	n_paired	n_paired_acci	n_ibd	n_ibd_acci	n_single	r_ll	n_subrun	n_mu	n_mu_shower	n_lihe	e_lihe	lihe_stat	n_fn_side	n_fn_side_scaled	n_fn_mutag	dt_min	dt_max	dt_acci	s2_lo	s2_hi	iso_pre	iso_post	mu_shower_npe	fn_e_lo	fn_e_hi	fn_tag_s	lihe_fit_lo	lihe_fit_hi
4310	_nGd	AmBe	82800.000	500	50	82	8	123456	12.3400	1440	50000	80	-1	-1	lowstat	200	-1	30	0.0	100.0	400.0	5.0	12.0	0.0	400.0	5000	12.0	20.0	2.0	0.0	5.0
4310	_nH	AmBe	82800.000	900	90	620	60	654321	45.6700	1440	50000	80	-1	-1	lowstat	350	-1	55	0.0	800.0	3200.0	1.5	5.5	0.0	3200.0	5000	12.0	20.0	2.0	0.0	5.0
4312	_nGd	none	86000.000	520	45	90	7	130000	13.1000	1440	52000	95	800.5	40.2	ok	210	38.4	33	0.0	100.0	400.0	5.0	12.0	0.0	400.0	5000	12.0	20.0	2.0	0.0	5.0
4312	_nH	none	86000.000	950	88	640	55	660000	46.2000	1440	52000	95	1234.5	55.0	ok	360	42.7	58	0.0	800.0	3200.0	1.5	5.5	0.0	3200.0	5000	12.0	20.0	2.0	0.0	5.0
EOF

LEGACY="$T/legacy.html"
DST="$T/dst.html"
LOUT=$(bash "$SUT" "$T" "$LEGACY" legacy 111 2>&1); LRC=$?
DOUT=$(bash "$SUT" "$T" "$DST"    dst    222 2>&1); DRC=$?
if [ "$LRC" -ne 0 ] || [ "$DRC" -ne 0 ]; then
   echo "FAIL setup : legacy rc=$LRC dst rc=$DRC"
   echo "$LOUT"; echo "$DOUT"
   exit 1
fi

row_of() { grep -o "<tr><td>$2</td>.*</tr>" "$1"; }   # $1=html파일 $2=run

R=""

# ① 행 수 == 런 수(3)+1(헤더), 데이터 행은 모두 15열, 미기록 런(4308)은
#    IBD/acci/R_LL/선원 다섯 칸이 '-' 로 내려간다(열이 밀리지 않는다)
n_tr=$(grep -c '<tr>' "$LEGACY")
bad_td=0
while IFS= read -r line; do
   n=$(printf '%s' "$line" | grep -o '<td>' | wc -l)
   [ "$n" -eq 15 ] || bad_td=$((bad_td + 1))
done < <(grep -o '<tr>.*</tr>' "$LEGACY")
r4308=$(row_of "$LEGACY" 4308)
ndash4308=$(printf '%s' "$r4308" | grep -o '<td>-</td>' | wc -l)
if [ "$n_tr" -eq 4 ] && [ "$bad_td" -eq 0 ] && [ "$ndash4308" -eq 6 ]; then
   R="$R
CHK rows_and_dash=1"
else
   R="$R
CHK rows_and_dash=0"
fi

# ② 첫 데이터 행이 가장 큰 런(4312) -- 픽스처 파일 안 순서(4310,4308,4312)와
#    다르므로 실제로 정렬됐을 때만 통과한다
first_run=$(grep -o '<tr><td>[0-9]*</td>' "$LEGACY" | sed -n '1p' | grep -o '[0-9]\+')
[ "$first_run" = "4312" ] && R="$R
CHK order_desc=1" || R="$R
CHK order_desc=0"

# ③ legacy 모드 : em dash('—')가 있고 '(예비)' 는 전혀 없다(캡션 포함 전체)
ndash_all=$(grep -o '—' "$LEGACY" | wc -l)
npre_legacy=$(grep -c '(예비)' "$LEGACY")
if [ "$ndash_all" -ge 1 ] && [ "$npre_legacy" -eq 0 ]; then
   R="$R
CHK legacy_dash_no_pre=1"
else
   R="$R
CHK legacy_dash_no_pre=0"
fi

# ④ dst 모드 : lihe_stat=ok/fn>=0 인 run 4312 는 '(예비)' 가 2번(fast-n·Li/He)
#    나오고, lowstat/fn<0 인 run 4310 은 dst 여도 하나도 나오지 않는다
r4312d=$(row_of "$DST" 4312)
r4310d=$(row_of "$DST" 4310)
n4312=$(printf '%s' "$r4312d" | grep -o '(예비)' | wc -l)
n4310=$(printf '%s' "$r4310d" | grep -o '(예비)' | wc -l)
if [ "$n4312" -eq 2 ] && [ "$n4310" -eq 0 ]; then
   R="$R
CHK dst_preliminary=1"
else
   R="$R
CHK dst_preliminary=0"
fi

# ⑤ 선원(AmBe) 런은 .src 로 강조되고, 'none'(보통의 물리 런, run 4312) 은
#    강조되지 않는다 -- 강조를 다 걸면 안전장치가 무뎌진다(실데이터
#    /scratch/RunSummary 로 실측한 관례 -- 거의 모든 런이 'none' 이다)
r4310l=$(row_of "$LEGACY" 4310)
r4312l=$(row_of "$LEGACY" 4312)
ok5=1
printf '%s' "$r4310l" | grep -q '<span class="src">AmBe</span>' || ok5=0
printf '%s' "$r4312l" | grep -q 'class="src"' && ok5=0
[ "$ok5" -eq 1 ] && R="$R
CHK src_flag=1" || R="$R
CHK src_flag=0"

# ⑥ refresh 메타가 넘긴 값(4번째 인자)과 같다 -- 모드별로 다른 값을 줘서
#    한 쪽이 굳어 있는(hardcode) 경우를 잡는다
if grep -q '<meta http-equiv="refresh" content="111">' "$LEGACY" &&
   grep -q '<meta http-equiv="refresh" content="222">' "$DST"; then
   R="$R
CHK refresh_meta=1"
else
   R="$R
CHK refresh_meta=0"
fi

# ⑦ legacy 모드는 metrics_summary.tsv 가 디렉터리에 아예 없어도 죽지 않는다.
#    브리프 원안의 ${MS:+"$MS"} 식(변수가 항상 비어있지 않은 경로 문자열이라
#    실제로는 아무것도 걸러내지 못한다)으로 되돌아가면 awk 가 없는 파일을
#    열려다 그 자리에서 죽는다 -- 이 회귀를 잡는 것이 이 시험의 목적이다.
#    run_summary.tsv/pair_summary.tsv 만 있는 별도 디렉터리로 돈다.
NM_DIR="$T/nometrics"; mkdir -p "$NM_DIR"
cp "$T/run_summary.tsv" "$T/pair_summary.tsv" "$NM_DIR/"
NOMETRICS="$T/legacy_nometrics.html"
NMOUT=$(bash "$SUT" "$NM_DIR" "$NOMETRICS" legacy 111 2>&1); NMRC=$?
nm_tr=0; nm_bad_td=0
if [ -r "$NOMETRICS" ]; then
   nm_tr=$(grep -c '<tr>' "$NOMETRICS")
   while IFS= read -r line; do
      n=$(printf '%s' "$line" | grep -o '<td>' | wc -l)
      [ "$n" -eq 15 ] || nm_bad_td=$((nm_bad_td + 1))
   done < <(grep -o '<tr>.*</tr>' "$NOMETRICS")
fi
if [ "$NMRC" -eq 0 ] && [ "$nm_tr" -eq 4 ] && [ "$nm_bad_td" -eq 0 ]; then
   R="$R
CHK legacy_no_metrics=1"
else
   R="$R
CHK legacy_no_metrics=0"
   echo "legacy_no_metrics 진단 : rc=$NMRC tr=$nm_tr bad_td=$nm_bad_td"
   echo "$NMOUT"
fi

FAILED=0
for k in rows_and_dash order_desc legacy_dash_no_pre dst_preliminary src_flag refresh_meta legacy_no_metrics; do
   if echo "$R" | grep -q "CHK $k=1"; then
      :
   else
      echo "FAIL $k"
      FAILED=1
   fi
done
if [ "$FAILED" -ne 0 ]; then
   echo "-- legacy.html --"; cat "$LEGACY"
   echo "-- dst.html --"; cat "$DST"
   exit 1
fi
echo "PASS monitor-html (7/7)"
