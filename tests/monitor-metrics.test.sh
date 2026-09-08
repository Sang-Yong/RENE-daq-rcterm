#!/usr/bin/env bash
# monitor-metrics.test.sh -- BuildMetrics.C(DST 입력)의 n_ibd/n_ibd_acci 가
# legacy(BuildPairSummary.C 가 PRD 에서 만든 pair_summary.tsv)와 같은지
# 대조한다 (metrics.sh --verify = dst 전환 게이트의 실행형). 실데이터는
# 읽기만 하고, metrics_summary.tsv 는 임시 디렉터리에만 쓴다 -- 실제
# /scratch/RunSummary 는 건드리지 않는다.
#
# ★ 런 번호를 하드코딩하지 않는다 (task-4-brief.md 의 Step 3~4 는 run 4237 을
#   기준 런으로 썼지만, 컨트롤러 판단 R4 로 대체됐다). /scratch/RunSummary/dst/
#   DST_<run>.root 와 pair_summary.tsv 의 (run,_nGd) 행을 **둘 다** 가진 런
#   중 가장 최신(런 번호가 가장 큰) 것을 스스로 고른다. 이 시험을 작성하는
#   시점에 run 4237 의 DST 는 몇 시간짜리 배경 작업(BuildMonitorDst.C)이
#   아직 만드는 중이라 여기서 기다리지 않는다 -- run 4305 는 이미 있다.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
OUT_REAL=${RUNSUM_OUT:-/scratch/RunSummary}

# ---- 런 자동 선택 ----
pick_run() {
   local dstdir pfile
   dstdir="$OUT_REAL/dst"
   pfile="$OUT_REAL/pair_summary.tsv"
   [ -d "$dstdir" ] && [ -r "$pfile" ] || return 1
   local dst_runs have_runs
   #  /scratch 에서는 find -printf 대신 ls -1 (CLAUDE.md §11.5 의 실측 이유와
   #  같다 -- 여기는 파일 몇 개뿐이라 costs 는 미미하지만 관용구를 통일한다).
   dst_runs=$(ls -1 "$dstdir" 2>/dev/null |
              sed -n 's/^DST_0*\([0-9][0-9]*\)\.root$/\1/p' | sort -n)
   [ -n "$dst_runs" ] || return 1
   have_runs=$(awk -F'\t' '!/^#/ && $2=="_nGd"{print $1}' "$pfile" 2>/dev/null | sort -n -u)
   [ -n "$have_runs" ] || return 1
   comm -12 <(printf '%s\n' "$dst_runs") <(printf '%s\n' "$have_runs") | tail -1
}

RUN=$(pick_run)
[ -n "$RUN" ] || { echo "SKIP: DST 와 pair_summary(_nGd 행)를 동시에 가진 런이 없다"; exit 0; }

command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh 2>/dev/null
command -v root >/dev/null 2>&1 || { echo "SKIP: ROOT 없음"; exit 0; }

RUNS=$(printf '%06d' "$RUN")
DSTFILE="$OUT_REAL/dst/DST_${RUNS}.root"
[ -r "$DSTFILE" ] || { echo "SKIP: $DSTFILE 를 읽을 수 없다"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/out/dst"
#  실제 트리(/scratch/RunSummary)는 건드리지 않는다 -- DST 는 수백 MB 라
#  심볼릭 링크만 걸고(복사하지 않는다), pair_summary/runtype 은 작은 tsv 라
#  그대로 복사한다.
ln -s "$DSTFILE" "$T/out/dst/DST_${RUNS}.root"
cp "$OUT_REAL/pair_summary.tsv" "$T/out/pair_summary.tsv"
[ -r "$OUT_REAL/runtype.tsv" ] && cp "$OUT_REAL/runtype.tsv" "$T/out/runtype.tsv"

# 1) 빌드 -- metrics_summary.tsv 는 $T/out 에만 생긴다
RUNSUM_OUT="$T/out" "$DIR/tools/monitor/metrics.sh" --list "$RUN" > "$T/log1" 2>&1 \
   || { echo "FAIL build"; tail -30 "$T/log1"; exit 1; }
[ -s "$T/out/metrics_summary.tsv" ] || { echo "FAIL: metrics_summary.tsv 없음"; cat "$T/log1"; exit 1; }

# 2) 두 태그(행)가 다 있어야 한다 -- BuildPairSummary.C 는 항상 nGd/nH 를
#    함께 쓰므로, pair_summary 에 이 런이 있으면 두 행이 나와야 정상이다.
NROWS=$(awk -F'\t' -v r="$RUN" '!/^#/ && $1==r' "$T/out/metrics_summary.tsv" | wc -l)
[ "$NROWS" -eq 2 ] || { echo "FAIL: run $RUN 행 수 = $NROWS (기대 2)"; cat "$T/out/metrics_summary.tsv"; exit 1; }

# 3) --verify -- 공통 (run,tag) 행에서 ibd/acci 가 legacy 와 같아야 한다
#    (이것이 dst 전환 게이트다. metrics_summary.tsv 는 이 run 하나뿐이므로
#    "공통 행" 은 항상 이 런의 두 태그로 정확히 정해진다).
VOUT=$(RUNSUM_OUT="$T/out" "$DIR/tools/monitor/metrics.sh" --verify 2>&1)
VRC=$?
echo "$VOUT" | grep -q '불일치 0' || { echo "FAIL: verify 출력에 '불일치 0' 없음"; echo "$VOUT"; exit 1; }
[ "$VRC" -eq 0 ] || { echo "FAIL: verify exit=$VRC"; echo "$VOUT"; exit 1; }

echo "$VOUT"
echo "PASS monitor-metrics (run $RUN)"
