#!/usr/bin/env bash
# websummary.test.sh -- websummary.sh 오케스트레이터 8항목.
#
# bash/awk/flock 만 있으면 되므로 언제나 돈다 -- ROOT 도, 실 RAW 데이터도
# 필요 없다. 검사 ①~⑥은 WEBSUMMARY_STAGES_DISABLED=1 로 다섯 단계
# 스크립트(run-summary/dst-build/metrics/ibd-summary/rate-trend) + html
# 생성 + webroot 복사 + 발행을 통째로 건너뛰고 게이트/상태/잠금/마운트/
# dry-run 로직만 본다. 검사 ⑦·⑧은 반대로 그 다섯 + gen-summary-html.sh +
# publish_google.py 를 WEBSUMMARY_MON_DIR 로 전부 가짜(호출만 기록하고
# 즉시 종료)로 갈아끼워 publish=1 경로(성공/실패, R2 복사와의 순서)를
# 실제로 실행해서 본다 -- 둘 다 ROOT·구글 자격증명이 필요 없다
# (task-9-brief 의 결정 + 리뷰 Finding 2).
#
# 실데이터·실디스크·운영 잠금/상태 파일은 절대 건드리지 않는다 --
# WEBSUMMARY_ROOTS/LOCK/STATE/LOG/MON_DIR 를 검사마다 새 mktemp -d
# 픽스처로 갈아끼운다(dataflow.sh 의 DATAFLOW_LOCK 과 같은 이유,
# CLAUDE.md §11.150). ⑦·⑧의 가짜 mountpoint 는 실 /scratch 마운트
# 여부에 기대지 않으려는 것이다 -- 검사 ⑥은 실 마운트에 기댄 채로
# 남겨 두었다(범위 밖: 이번 라운드는 Finding 1·2 만).
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
SUT="$DIR/tools/monitor/websummary.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

R=""   # CHK 이름=1/0 누적 (monitor-html.test.sh 와 같은 관용구)

# ---- 픽스처 헬퍼 ---------------------------------------------------------
#  mkrun <RAW루트> <6자리런> <FADC개수> <PRD개수>
#  badrun/ 안에 FADC_*.root.* 처럼 보이는 미끼 파일을 하나 심어 둔다 --
#  run_complete()(ls -U, 최상위만)가 이것까지 세면 완결 판정이 어긋나므로
#  §5.9 의 'badrun-safe' 를 이 픽스처 하나로 같이 확인한다.
mkrun() {
   local root=$1 rr=$2 nf=$3 np=$4 i
   mkdir -p "$root/$rr/PRD" "$root/$rr/badrun"
   for i in $(seq 1 "$nf"); do : > "$root/$rr/FADC_${rr}.root.$(printf '%05d' $((i-1)))"; done
   for i in $(seq 1 "$np"); do : > "$root/$rr/PRD/PRD_${rr}.$(printf '%05d' $((i-1))).root"; done
   : > "$root/$rr/badrun/FADC_${rr}.root.09999"
}
#  mkparams <파일> <tsv_dir> <start_run> [publish=0]
mkparams() {
   local pub=${4:-0}
   cat > "$1" <<EOF
tsv_dir        = $2
webroot        = $2/web
publish        = $pub
start_run      = $3
metrics_source = legacy
refresh_s      = 600
EOF
}

#  mk_fake_mon <몬디렉터리>
#  다섯 단계 스크립트 + gen-summary-html.sh + publish_google.py 를 전부
#  '호출을 기록하고 즉시 성공(또는 지정된 코드로) 종료'하는 가짜로 채운다.
#  파일은 한 번만 만들어 검사 ⑦·⑧이 공유한다 -- 동작은 매 실행마다 환경
#  변수로만 바뀐다 :
#    WS_TEST_CALLS      호출 기록을 남길 파일 (필수. 없으면 /dev/null)
#    WS_TEST_WEBROOT    publish_google.py 가짜가 summary.html 이 이미
#                        있는지 스스로 확인해 남길 webroot 경로
#                        (R2 rsync 복사가 발행보다 먼저 끝났는지를
#                        가짜 자신이 목격하게 하는 것 -- 시각차보다
#                        확실한 인과 증거다)
#    WS_TEST_PUBLISH_RC publish_google.py 가짜의 종료코드 (기본 0)
mk_fake_mon() {
   local mon=$1 s
   mkdir -p "$mon"
   for s in run-summary.sh dst-build.sh metrics.sh ibd-summary.sh rate-trend.sh; do
      cat > "$mon/$s" <<'FAKE'
#!/usr/bin/env bash
printf '%s %s %s\n' "$(date '+%s.%N')" "$(basename "$0")" "$*" >> "${WS_TEST_CALLS:-/dev/null}"
exit 0
FAKE
      chmod +x "$mon/$s"
   done
   #  gen-summary-html.sh <tsvdir> <out.html> <src> <refresh> -- out.html 을 실제로 만든다.
   #  뒤의 R2 rsync 는 가짜로 바꾸지 않는다 -- 진짜 rsync 가 이 파일과
   #  seed_pngs() 가 심은 png 를 옮기는 것까지 실측한다.
   cat > "$mon/gen-summary-html.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s %s %s\n' "$(date '+%s.%N')" "gen-summary-html.sh" "$*" >> "${WS_TEST_CALLS:-/dev/null}"
echo '<html></html>' > "$2"
exit 0
FAKE
   chmod +x "$mon/gen-summary-html.sh"
   cat > "$mon/publish_google.py" <<'FAKE'
#!/usr/bin/env bash
printf '%s %s %s\n' "$(date '+%s.%N')" "publish_google.py" "$*" >> "${WS_TEST_CALLS:-/dev/null}"
if [ -n "${WS_TEST_WEBROOT:-}" ] && [ -r "$WS_TEST_WEBROOT/summary.html" ]; then
   echo "webroot-ready" >> "${WS_TEST_CALLS:-/dev/null}"
else
   echo "webroot-NOT-ready" >> "${WS_TEST_CALLS:-/dev/null}"
fi
exit "${WS_TEST_PUBLISH_RC:-0}"
FAKE
   chmod +x "$mon/publish_google.py"
}

#  seed_pngs <tsv_dir> -- R2 rsync 가 옮길 실 파일을 몇 개 심는다.
#  전부 mktemp 트리 안이라 /scratch 에는 닿지 않는다.
seed_pngs() {
   local d=$1 n
   mkdir -p "$d"
   for n in candidates rate_raw rate_corrected; do
      : > "$d/rate_trend_${n}.png"
   done
}

# ==== [1] 완결 게이트 -- FADC==PRD 만 통과, 첫 미완결에서 연속을 멈춘다 ===
mkdir -p "$T/1/tsv"
mkrun "$T/1/RAW" 004280 3 3      # 완결          -- NEWLIST 에 들어가야 한다
mkrun "$T/1/RAW" 004281 3 2      # 미완결        -- 여기서 막혀야 한다
mkrun "$T/1/RAW" 004282 3 3      # 완결이지만 4281 에 막혀 오면 안 된다
mkparams "$T/1/params" "$T/1/tsv" 4280

OUT1=$(WEBSUMMARY_ROOTS="$T/1/RAW" WEBSUMMARY_LOCK="$T/1/.lock" \
       WEBSUMMARY_STATE="$T/1/state" WEBSUMMARY_LOG="$T/1/log" \
       WEBSUMMARY_STAGES_DISABLED=1 \
       "$SUT" --params "$T/1/params" 2>&1)
RC1=$?
SLR1=$(awk -F= '$1=="last_run"{print $2}' "$T/1/state" 2>/dev/null)
if [ "$RC1" -eq 0 ] && [ "$SLR1" = "4280" ]; then
   R="$R
CHK gate=1"
else
   R="$R
CHK gate=0"
   echo "[1] 진단 : rc=$RC1 last_run=[$SLR1] (기대 4280 -- 4281 미완결에 막혀야 함)"
   echo "$OUT1"; cat "$T/1/log" 2>&1
fi

# ==== [2] 새 완결 런이 없다 -- 조용히 exit 0 (로그 한 줄도 안 남긴다) ====
mkdir -p "$T/2/RAW" "$T/2/tsv"          # RAW 루트는 있지만 런 디렉터리가 없다
mkparams "$T/2/params" "$T/2/tsv" 4280
echo "이전 회차 흔적" > "$T/2/log"       # 이 줄이 늘지 않아야 '조용히' 다.

OUT2=$(WEBSUMMARY_ROOTS="$T/2/RAW" WEBSUMMARY_LOCK="$T/2/.lock" \
       WEBSUMMARY_STATE="$T/2/state" WEBSUMMARY_LOG="$T/2/log" \
       WEBSUMMARY_STAGES_DISABLED=1 \
       "$SUT" --params "$T/2/params" 2>&1)
RC2=$?
LOGLINES2=$(wc -l < "$T/2/log")
if [ "$RC2" -eq 0 ] && [ -z "$OUT2" ] && [ "$LOGLINES2" -eq 1 ] && [ ! -e "$T/2/state" ]; then
   R="$R
CHK no_new_quiet=1"
else
   R="$R
CHK no_new_quiet=0"
   echo "[2] 진단 : rc=$RC2 stdout=[$OUT2] loglines=$LOGLINES2 state있음=$([ -e "$T/2/state" ] && echo yes || echo no)"
   cat "$T/2/log" 2>&1
fi

# ==== [3] --dry-run 은 아무것도 바꾸지 않는다 (STAGES_DISABLED 없이) ====
#     실제 --dry-run 자체가 단계를 안 부르는지까지 보려고 시험 훅을 안 쓴다.
#     RUNSUM_OUT 이 픽스처를 가리키므로 설사 새는 경로가 있어도 실 운영
#     데이터에는 닿지 않는다.
mkdir -p "$T/3/tsv"
mkrun "$T/3/RAW" 004290 2 2
mkparams "$T/3/params" "$T/3/tsv" 4290

OUT3=$(WEBSUMMARY_ROOTS="$T/3/RAW" WEBSUMMARY_LOCK="$T/3/.lock" \
       WEBSUMMARY_STATE="$T/3/state" WEBSUMMARY_LOG="$T/3/log" \
       "$SUT" --params "$T/3/params" --dry-run 2>&1)
RC3=$?
if [ "$RC3" -eq 0 ] && [ ! -e "$T/3/state" ] && [ ! -e "$T/3/tsv/summary.html" ] \
   && printf '%s' "$OUT3" | grep -q '4290'; then
   R="$R
CHK dry_run_noop=1"
else
   R="$R
CHK dry_run_noop=0"
   echo "[3] 진단 : rc=$RC3"; echo "$OUT3"; ls -la "$T/3" 2>&1
fi

# ==== [4] /scratch 가 없으면 조용히 물러난다 (가짜 mountpoint, PATH 로) ==
mkdir -p "$T/4/bin" "$T/4/tsv"
cat > "$T/4/bin/mountpoint" <<'FAKE'
#!/bin/bash
exit 1
FAKE
chmod +x "$T/4/bin/mountpoint"
mkrun "$T/4/RAW" 004291 1 1
mkparams "$T/4/params" "$T/4/tsv" 4291

OUT4=$(PATH="$T/4/bin:$PATH" \
       WEBSUMMARY_ROOTS="$T/4/RAW" WEBSUMMARY_LOCK="$T/4/.lock" \
       WEBSUMMARY_STATE="$T/4/state" WEBSUMMARY_LOG="$T/4/log" \
       WEBSUMMARY_STAGES_DISABLED=1 \
       "$SUT" --params "$T/4/params" 2>&1)
RC4=$?
LOGLINES4=$(wc -l < "$T/4/log" 2>/dev/null || echo 0)
if [ "$RC4" -eq 0 ] && [ "$LOGLINES4" -eq 1 ] && grep -q 'scratch' "$T/4/log" 2>/dev/null \
   && [ ! -e "$T/4/state" ]; then
   R="$R
CHK mount_missing=1"
else
   R="$R
CHK mount_missing=0"
   echo "[4] 진단 : rc=$RC4 loglines=$LOGLINES4"; echo "$OUT4"; cat "$T/4/log" 2>&1
fi

# ==== [5] 잠금 겹침 -- 둘째가 즉시 물러난다 ==============================
mkdir -p "$T/5/tsv"
mkrun "$T/5/RAW" 004292 1 1
mkparams "$T/5/params" "$T/5/tsv" 4292

( flock "$T/5/.lock" sleep 2 ) &
HOLDER=$!
sleep 0.3   # 첫 인스턴스가 잠금을 잡을 시간을 준다

T0=$(date +%s.%N)
OUT5=$(WEBSUMMARY_ROOTS="$T/5/RAW" WEBSUMMARY_LOCK="$T/5/.lock" \
       WEBSUMMARY_STATE="$T/5/state" WEBSUMMARY_LOG="$T/5/log" \
       WEBSUMMARY_STAGES_DISABLED=1 \
       "$SUT" --params "$T/5/params" 2>&1)
RC5=$?
T1=$(date +%s.%N)
wait "$HOLDER" 2>/dev/null
ELAPSED=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.0f", (b-a)*1000}')

if [ "$RC5" -eq 0 ] && [ ! -e "$T/5/state" ] && grep -q '이미 돌고 있다' "$T/5/log" 2>/dev/null \
   && [ "$ELAPSED" -lt 1500 ]; then
   R="$R
CHK lock_contend=1"
else
   R="$R
CHK lock_contend=0"
   echo "[5] 진단 : rc=$RC5 elapsed=${ELAPSED}ms"; echo "$OUT5"; cat "$T/5/log" 2>&1
fi

# ==== [6] cron 환경(env -i) 에서도 처음부터 끝까지 돈다 ===================
mkdir -p "$T/6/tsv"
mkrun "$T/6/RAW" 004293 2 2
mkparams "$T/6/params" "$T/6/tsv" 4293

OUT6=$(env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$T/6" \
       WEBSUMMARY_ROOTS="$T/6/RAW" WEBSUMMARY_LOCK="$T/6/.lock" \
       WEBSUMMARY_STATE="$T/6/state" WEBSUMMARY_LOG="$T/6/log" \
       WEBSUMMARY_STAGES_DISABLED=1 \
       bash "$SUT" --params "$T/6/params" 2>&1)
RC6=$?
SLR6=$(awk -F= '$1=="last_run"{print $2}' "$T/6/state" 2>/dev/null)
if [ "$RC6" -eq 0 ] && [ "$SLR6" = "4293" ]; then
   R="$R
CHK cron_env=1"
else
   R="$R
CHK cron_env=0"
   echo "[6] 진단 : rc=$RC6 last_run=[$SLR6]"; echo "$OUT6"
fi

# ==== [7] publish=1 + 발행 실패 -- exit 1, 상태 전진 안 함, 발행이 불렸다 ==
#     WEBSUMMARY_MON_DIR 로 다섯 단계 + html + 발행을 전부 가짜로 갈아끼워
#     publish=1 경로를 ROOT·구글 자격증명 없이 실제로 실행해서 본다
#     (리뷰 Finding 2). 가짜 mountpoint 도 같이 써서 이 두 검사가 실
#     /scratch 마운트 여부에 기대지 않게 한다.
mkdir -p "$T/mon" "$T/78bin"
mk_fake_mon "$T/mon"
cat > "$T/78bin/mountpoint" <<'FAKE'
#!/bin/bash
exit 0
FAKE
chmod +x "$T/78bin/mountpoint"

mkdir -p "$T/7/tsv"
mkrun "$T/7/RAW" 004300 2 2
seed_pngs "$T/7/tsv"
mkparams "$T/7/params" "$T/7/tsv" 4300 1

OUT7=$(PATH="$T/78bin:$PATH" \
       WEBSUMMARY_ROOTS="$T/7/RAW" WEBSUMMARY_LOCK="$T/7/.lock" \
       WEBSUMMARY_STATE="$T/7/state" WEBSUMMARY_LOG="$T/7/log" \
       WEBSUMMARY_MON_DIR="$T/mon" \
       WS_TEST_CALLS="$T/7/calls" WS_TEST_WEBROOT="$T/7/tsv/web" WS_TEST_PUBLISH_RC=1 \
       "$SUT" --params "$T/7/params" 2>&1)
RC7=$?
if [ "$RC7" -eq 1 ] && [ ! -e "$T/7/state" ] \
   && grep -q 'publish_google.py'    "$T/7/calls" 2>/dev/null \
   && grep -q 'run-summary.sh'       "$T/7/calls" 2>/dev/null \
   && grep -q 'gen-summary-html.sh'  "$T/7/calls" 2>/dev/null; then
   R="$R
CHK publish_fail=1"
else
   R="$R
CHK publish_fail=0"
   echo "[7] 진단 : rc=$RC7"; echo "$OUT7"
   echo "-- calls --"; cat "$T/7/calls" 2>&1
   echo "-- log --";   cat "$T/7/log" 2>&1
fi

# ==== [8] publish=1 + 발행 성공 -- exit 0, 상태 전진, R2 복사가 발행보다 먼저 ====
#     같은 가짜 MON(공유)·가짜 mountpoint 를 다시 쓴다. WS_TEST_PUBLISH_RC=0
#     이라 이번엔 성공. publish_google.py 가짜가 자기가 불릴 때 이미
#     webroot/summary.html 이 있는지 스스로 확인해 남기므로, R2 rsync 복사가
#     정말로 발행보다 먼저 끝났는지를 실제 인과로 본다(타임스탬프 비교가
#     아니라 발행 가짜 자신의 목격 -- 시계 해상도 경합이 없다).
mkdir -p "$T/8/tsv"
mkrun "$T/8/RAW" 004301 2 2
seed_pngs "$T/8/tsv"
mkparams "$T/8/params" "$T/8/tsv" 4301 1

OUT8=$(PATH="$T/78bin:$PATH" \
       WEBSUMMARY_ROOTS="$T/8/RAW" WEBSUMMARY_LOCK="$T/8/.lock" \
       WEBSUMMARY_STATE="$T/8/state" WEBSUMMARY_LOG="$T/8/log" \
       WEBSUMMARY_MON_DIR="$T/mon" \
       WS_TEST_CALLS="$T/8/calls" WS_TEST_WEBROOT="$T/8/tsv/web" WS_TEST_PUBLISH_RC=0 \
       "$SUT" --params "$T/8/params" 2>&1)
RC8=$?
SLR8=$(awk -F= '$1=="last_run"{print $2}' "$T/8/state" 2>/dev/null)
if [ "$RC8" -eq 0 ] && [ "$SLR8" = "4301" ] \
   && grep -q 'webroot-ready' "$T/8/calls" 2>/dev/null \
   && ! grep -q 'webroot-NOT-ready' "$T/8/calls" 2>/dev/null; then
   R="$R
CHK publish_order=1"
else
   R="$R
CHK publish_order=0"
   echo "[8] 진단 : rc=$RC8 last_run=[$SLR8]"; echo "$OUT8"
   echo "-- calls --"; cat "$T/8/calls" 2>&1
fi

# ---- 판정 -----------------------------------------------------------------
FAILED=0
for k in gate no_new_quiet dry_run_noop mount_missing lock_contend cron_env \
         publish_fail publish_order; do
   if echo "$R" | grep -q "CHK $k=1"; then
      :
   else
      echo "FAIL $k"
      FAILED=1
   fi
done
[ "$FAILED" -ne 0 ] && exit 1
echo "PASS websummary (8/8)"
