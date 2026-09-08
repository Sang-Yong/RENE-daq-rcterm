#!/usr/bin/env bash
# monitor-publish.test.sh -- publish_google.py 의 --dry-run 경로만 시험한다
# (task-8-brief.md Step 2). 실 시트/드라이브 API 호출은 Task 10 통합에서
# 사용자 승인 후에 한다. 여기서 보는 것 다섯 가지:
#   ① --dry-run 이 네트워크를 전혀 건드리지 않고 rc=0 로 끝나는가
#      -- "이 환경에 네트워크가 없어서 우연히 통과"가 아니라, socket 의
#      연결·이름풀이 원시함수를 그 자리에서 예외로 바꿔친 채 실제로 돌려
#      "어떤 네트워크 호출을 하나라도 시도하면 그 자리에서 잡힌다"로 확인한다
#   ② 표에 실릴 런 목록이 start_run 필터 + join 규칙과 맞는가
#   ③ (dry) drive update 줄 수 == map_file 의 항목 수
#   ④ params 에 sheet_id 가 비면 --dry-run 이라도 명확한 [FATAL] 로 죽는가
#      (그 검사는 build_rows 보다 먼저라 dry-run 여부와 무관하다)
#   ⑤ --dry-run --init 도 ①과 같은 소켓 차단 하네스로 네트워크를 전혀
#      건드리지 않고 rc=0 로 끝나며, webroot 의 픽스처 png 들을 이름+크기로
#      찍는가 (컨트롤러 판정 R6 -- dry-run 은 --init 과 같이 있어도
#      find_creds/urllib/gspread 를 절대 건드리면 안 된다)
# 실데이터·실API·실디스크(/scratch, /Data_ssd)는 전혀 건드리지 않는다.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
SUT="$DIR/tools/monitor/publish_google.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 없음"; exit 0; }
[ -r "$SUT" ] || { echo "FAIL: $SUT 없음"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tsv" "$T/web" "$T/fake-home"

# ---------------------------------------------------------------- 픽스처 ----
#  run_summary.tsv (schema 2, 13열). 열 순서는 BuildRunSummary.C::WriteTsv
#  실측 그대로(task-7 픽스처와 같은 관례) : run n_subrun n_bad epoch_start
#  epoch_end wall_s span_s live_s dead_s n_type1 n_type2 n_type3 source.
#  4279 는 start_run(아래 params 의 4280) 미만이라 걸러져야 한다.
cat > "$T/tsv/run_summary.tsv" <<'EOF'
# schema 2
#run	n_subrun	n_bad	epoch_start	epoch_end	wall_s	span_s	live_s	dead_s	n_type1	n_type2	n_type3	source
4279	10	0	1725000000	1725003600	3600.000	3600.000	3550.000	50.000	1000	200	50	prd
4280	1440	0	1725100000	1725186400	86400.000	86400.000	82800.000	3600.000	900000	15000	450000	prd
4281	1440	1	1725200000	1725286400	86400.000	86400.000	86000.000	400.000	950000	16000	470000	prd
4282	100	0	1725300000	1725303600	3600.000	3600.000	3550.000	50.000	100000	2000	50000	prd
EOF

#  pair_summary.tsv (schema 2, 18열, metrics_source=legacy 조인용). 4282 는
#  일부러 짝이 되는 행이 없다 -- IBD/acci/R_LL/선원 이 '-' 로 내려가는
#  경로를 시험한다(monitor-html.test.sh 의 4308 과 같은 관례). 4279 는
#  애초에 필터로 빠지므로 행을 두지 않는다.
cat > "$T/tsv/pair_summary.tsv" <<'EOF'
# schema 2
#run	tag	src	live_s	n_paired	n_paired_acci	n_ibd	n_ibd_acci	dt_min	dt_max	dt_acci	s2_lo	s2_hi	iso_pre	iso_post	n_single	r_ll	n_subrun
4280	_nGd	none	82800.000	500	50	82	8	0.0	100.0	400.0	5.0	12.0	0.0	400.0	123456	12.3400	1440
4280	_nH	none	82800.000	900	90	620	60	0.0	800.0	3200.0	1.5	5.5	0.0	3200.0	654321	45.6700	1440
4281	_nGd	AmBe	86000.000	520	45	90	7	0.0	100.0	400.0	5.0	12.0	0.0	400.0	130000	13.1000	1440
4281	_nH	AmBe	86000.000	950	88	640	55	0.0	800.0	3200.0	1.5	5.5	0.0	3200.0	660000	46.2000	1440
EOF

#  드라이브 매핑 -- 가짜 fileId 3개. dry-run 은 실제로 파일을 열어보지
#  않으므로 이름·fileId 값 자체는 아무 뜻이 없어도 된다.
cat > "$T/websummary.map" <<'EOF'
rate_trend_candidates	FAKE_ID_1
rate_trend_rll	FAKE_ID_2
rate_trend_cumulative	FAKE_ID_3
EOF

#  webroot 에는 map 보다 하나 더 많은 png 를 둔다 -- 3개는 map 과 이름이
#  같고 하나('orphan')는 map 에 없다. '그림 M/K' 표시가 map 개수(M)와
#  디스크 개수(K)를 실제로 따로 세는지까지 함께 본다. dry-run 은 내용을
#  읽지 않으므로 빈 파일로 충분하다.
for n in rate_trend_candidates rate_trend_rll rate_trend_cumulative orphan; do
   : > "$T/web/$n.png"
done

#  params -- sheet_id/drive_folder_id 는 dry-run 이 네트워크에 쓰지 않는
#  가짜 값으로 둔다. read_params 가 채우기만 하면 된다.
cat > "$T/websummary.params" <<EOF
sheet_id      = FAKE_SHEET_ID_FOR_TEST
sheet_gid     = 0
drive_folder_id = FAKE_FOLDER_ID
map_file      = $T/websummary.map
metrics_source = legacy
refresh_s     = 600
webroot       = $T/web
tsv_dir       = $T/tsv
publish       = 1
start_run     = 4280
EOF

#  ④용 변형 -- sheet_id 만 비운다.
sed 's/^sheet_id.*/sheet_id      =/' "$T/websummary.params" > "$T/websummary-nosheet.params"

# ----------------------------------------------------------- 네트워크 차단 ----
#  socket 의 연결·이름풀이 원시함수를 그 자리에서 예외로 바꿔치기한 채로
#  publish_google.py 를 실제 __main__ 으로 돌린다. 정적으로 코드만 읽고
#  "안전할 것 같다"고 판단하는 대신, 실행해서 확인한다 -- 네트워크를
#  하나라도 건드리면 RuntimeError 가 그 자리에서 나 rc!=0 이 되고 그
#  메시지가 stderr 에 고스란히 남는다.
cat > "$T/offline_run.py" <<'PYEOF'
import sys, socket, runpy
script = sys.argv[1]
sys.argv = [script] + sys.argv[2:]

def _blocked(*a, **k):
    raise RuntimeError("NETWORK ACCESS ATTEMPTED IN DRY-RUN")

socket.socket.connect = _blocked
socket.socket.connect_ex = _blocked
socket.create_connection = _blocked
socket.getaddrinfo = _blocked

try:
    runpy.run_path(script, run_name="__main__")
except SystemExit as e:
    code = e.code
    if code is None:
        sys.exit(0)
    if isinstance(code, int):
        sys.exit(code)
    print(code, file=sys.stderr)   # 실제 인터프리터가 sys.exit("문자열") 을 다루는 방식과 같다
    sys.exit(1)
PYEOF

run_offline() {   # $1=params파일  나머지=publish_google.py 에 넘길 인자
   local params="$1"; shift
   env -i PATH="$PATH" HOME="$T/fake-home" \
      python3 "$T/offline_run.py" "$SUT" --params "$params" "$@"
}

OUT1=$(run_offline "$T/websummary.params" --dry-run 2>"$T/err1.txt")
RC1=$?

R=""

# ① rc=0, 네트워크 시도 흔적이 stderr 에 전혀 없다
if [ "$RC1" -eq 0 ] && ! grep -q "NETWORK ACCESS ATTEMPTED" "$T/err1.txt"; then
   R="$R
CHK offline_dry_run=1"
else
   R="$R
CHK offline_dry_run=0"
   echo "진단(①) : rc=$RC1"
fi

# ② 표에 실릴 런 목록 -- build_rows 는 run 오름차순으로 반환하고 dry-run
#    은 그 마지막 3개만 찍는다(rows[-3:]). start_run=4280 필터로 4279 가
#    빠지면 남는 게 정확히 3개(4280,4281,4282) 라 전부 찍혀야 한다.
RUNS_SEEN=$(printf '%s\n' "$OUT1" \
   | sed -n 's/^  (dry) sheet row: \[\([0-9]*\).*/\1/p' | tr '\n' ' ' | sed 's/ *$//')
if [ "$RUNS_SEEN" = "4280 4281 4282" ] && \
   printf '%s\n' "$OUT1" | grep -qxF '[INFO] 표 행 : 3 (출처 legacy)'; then
   R="$R
CHK row_listing=1"
else
   R="$R
CHK row_listing=0"
   echo "진단(②) : runs_seen='$RUNS_SEEN' (기대 '4280 4281 4282')"
fi

# ③ (dry) drive update 줄 수 == map_file 의 항목 수(3), 그리고 요약 줄의
#    분자(map 항목 수)/분모(웹루트 png 개수=4) 도 서로 다르게(3 vs 4) 맞아야
#    한다 -- 두 셈이 실제로 다른 것을 센다는 것을 함께 확인한다.
NDRIVE=$(printf '%s\n' "$OUT1" | grep -c '^  (dry) drive update ')
MAPLINES=$(wc -l < "$T/websummary.map")
if [ "$NDRIVE" -eq "$MAPLINES" ] && [ "$NDRIVE" -eq 3 ] && \
   printf '%s\n' "$OUT1" | grep -qxF '[DRY] 시트 3 행 후보, 그림 3/4 개 교체 예정'; then
   R="$R
CHK drive_update_count=1"
else
   R="$R
CHK drive_update_count=0"
   echo "진단(③) : ndrive=$NDRIVE maplines=$MAPLINES"
fi

# ④ sheet_id 가 비면 --dry-run 이라도 [FATAL] 로 죽는다 (그 검사가
#    build_rows/dry-run 분기보다 앞이라 dry-run 여부와 무관하게 걸린다).
OUT4=$(run_offline "$T/websummary-nosheet.params" --dry-run 2>"$T/err4.txt")
RC4=$?
if [ "$RC4" -ne 0 ] && grep -q '\[FATAL\].*sheet_id' "$T/err4.txt"; then
   R="$R
CHK missing_sheet_id_fatal=1"
else
   R="$R
CHK missing_sheet_id_fatal=0"
   echo "진단(④) : rc=$RC4"
fi

# ⑤ --dry-run --init -- find_creds/urllib/gspread 를 전혀 건드리지 않고
#    (①과 같은 소켓 차단 하네스로 돈다) webroot 의 픽스처 png 4개를
#    이름+크기로 나열하고, 갈 폴더·쓰일 map_file 을 찍고 rc=0 로 끝난다.
#    map_file 은 이미 존재하는 픽스처(위 ③에서도 쓴 파일)인데, dry-run
#    이므로 내용이 바뀌면 안 된다 -- 실행 전후 내용을 대조해 그것도 본다.
MAP_BEFORE=$(cat "$T/websummary.map")
OUT5=$(run_offline "$T/websummary.params" --dry-run --init 2>"$T/err5.txt")
RC5=$?
MAP_AFTER=$(cat "$T/websummary.map")
NCREATE=$(printf '%s\n' "$OUT5" | grep -c '^  (dry) drive create ')
ALL4=1
for n in rate_trend_candidates rate_trend_rll rate_trend_cumulative orphan; do
   printf '%s\n' "$OUT5" | grep -qF "drive create ${n}.png (" || ALL4=0
done
if [ "$RC5" -eq 0 ] && ! grep -q "NETWORK ACCESS ATTEMPTED" "$T/err5.txt" && \
   [ "$NCREATE" -eq 4 ] && [ "$ALL4" -eq 1 ] && \
   [ "$MAP_BEFORE" = "$MAP_AFTER" ] && \
   printf '%s\n' "$OUT5" | grep -qF "폴더 FAKE_FOLDER_ID" && \
   printf '%s\n' "$OUT5" | grep -qF "$T/websummary.map 에 4줄을 쓸 예정"; then
   R="$R
CHK dry_run_init=1"
else
   R="$R
CHK dry_run_init=0"
   echo "진단(⑤) : rc=$RC5 ncreate=$NCREATE all4=$ALL4 map_changed=$([ "$MAP_BEFORE" = "$MAP_AFTER" ] && echo no || echo YES)"
fi

FAILED=0
for k in offline_dry_run row_listing drive_update_count missing_sheet_id_fatal dry_run_init; do
   if echo "$R" | grep -q "CHK $k=1"; then
      :
   else
      echo "FAIL $k"
      FAILED=1
   fi
done
if [ "$FAILED" -ne 0 ]; then
   echo "-- run1(정상 params) stdout --"; echo "$OUT1"
   echo "-- run1 stderr --"; cat "$T/err1.txt"
   echo "-- run4(sheet_id 빈 params) stdout --"; echo "$OUT4"
   echo "-- run4 stderr --"; cat "$T/err4.txt"
   echo "-- run5(--dry-run --init) stdout --"; echo "$OUT5"
   echo "-- run5 stderr --"; cat "$T/err5.txt"
   exit 1
fi
echo "PASS monitor-publish (5/5)"
