#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  monitor-all.sh - 세 단계를 순서대로 돌린다. 자동화는 이것을 쓴다.
#
#      1) run-summary.sh   livetime, 종류별 이벤트 수
#      2) ibd-summary.sh   IBD 후보 수 (채널별)
#      3) rate-trend.sh    효율 보정 + 시간축 추이 그림
#
#  각 단계는 이미 처리한 런을 건너뛴다. 그래서 몇 번을 돌려도 안전하고,
#  돌릴 때마다 새로 끝난 런의 점이 그림 오른쪽 끝에 붙는다.
#
#  사용 :
#      tools/monitor/monitor-all.sh              한 번 돌린다
#      tools/monitor/monitor-all.sh --follow     주기적으로 계속 (기본 1시간)
#      tools/monitor/monitor-all.sh --follow --poll 1800
#      tools/monitor/monitor-all.sh --quiet      요약만 출력
#      tools/monitor/monitor-all.sh --newest 3   한 바퀴에 새 런 3개까지만
#
#  1단계는 PRD 를 통째로 읽으므로 런당 몇 분~몇 시간이다(서브런 수에 비례).
#  그래서 한 바퀴에 처리할 런 수를 --newest 로 끊는다. 기본 2 개다 --
#  끊지 않으면 첫 실행이 며칠 물린다(지금 PRD 가 있는 런이 1,400 개가 넘는다).
#
#  tmux pane 에 붙이려면 (화면 배치는 건드리지 않는다) :
#      tmux new-window -t daq -n monitor \
#         'tools/monitor/monitor-all.sh --follow'
#  cron 으로 돌리려면 ROOT 환경이 필요하므로 :
#      0 * * * * . /usr/local/bin/thisroot.sh; \
#                /home/frontend/DAQ/RENE-daq-rcterm/tools/monitor/monitor-all.sh --quiet
#
#  주의 : 분석 산출물(SampleFiles)은 ojk 계정 소유다. 여기서는 읽기만 하고
#         쓰는 곳은 RUNSUM_OUT 뿐이다. 페어링 자체는 돌리지 않는다 --
#         빠진 런은 ibd-summary.sh --missing 이 알려 준다.
# ---------------------------------------------------------------------
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
OUT=${RUNSUM_OUT:-/scratch/RunSummary}
FOLLOW=0; POLL=3600; QUIET=0; EPSE=""; NEWEST=2

while [ $# -gt 0 ]; do
   case "${1:-}" in
      --follow) FOLLOW=1; shift ;;
      --poll)   POLL=${2:-3600}; shift 2 ;;
      --quiet)  QUIET=1; shift ;;
      --eps-e)  EPSE=${2:-}; shift 2 ;;
      --newest) NEWEST=${2:-2}; shift 2 ;;
      -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
      *) echo "모르는 옵션 : $1"; sed -n '2,30p' "$0"; exit 1 ;;
   esac
done

# ROOT 는 여기서 한 번만 잡는다. 자식 스크립트가 물려받는다.
if ! command -v root >/dev/null 2>&1; then
   # shellcheck disable=SC1091
   [ -r /usr/local/bin/thisroot.sh ] && . /usr/local/bin/thisroot.sh
fi

say() { [ "$QUIET" -eq 1 ] || echo "$@"; }
stamp() { date '+%Y-%m-%d %H:%M:%S'; }

one_pass() {
   local rc=0
   say ""
   say "===== $(stamp) ====="

   say "-- 1/3 livetime --"
   local r1=(--newest "$NEWEST")
   [ "$NEWEST" -le 0 ] && r1=()
   if [ "$QUIET" -eq 1 ]; then "$DIR/run-summary.sh" "${r1[@]}" >/dev/null 2>&1 || rc=1
   else "$DIR/run-summary.sh" "${r1[@]}" 2>&1 | tail -4 || rc=1; fi

   say "-- 2/3 IBD 후보 --"
   if [ "$QUIET" -eq 1 ]; then "$DIR/ibd-summary.sh" >/dev/null 2>&1 || rc=1
   else "$DIR/ibd-summary.sh" 2>&1 | tail -4 || rc=1; fi

   say "-- 3/3 효율 보정과 그림 --"
   local args=()
   [ -n "$EPSE" ] && args+=(--eps-e "$EPSE")
   if [ "$QUIET" -eq 1 ]; then "$DIR/rate-trend.sh" "${args[@]}" >/dev/null 2>&1 || rc=1
   else "$DIR/rate-trend.sh" "${args[@]}" 2>&1 | grep -E 'SAVED|NOTE|추이|FATAL|WARN' || rc=1; fi

   # 마지막 점을 한 줄로 알려 준다. 이것만 봐도 수집이 정상인지 감이 온다.
   if [ -r "$OUT/rate_trend.tsv" ]; then
      say "-- 가장 최근 점 --"
      awk -F'\t' '!/^#/ && NF>12 {last[$2]=$0}
                  END { for (t in last) { split(last[t], f, "\t");
                        printf "   %s  run %s  cand %.1f  rate %.1f/day  corr %.1f/day\n",
                               f[2], f[1], f[5], f[11], f[13] } }' \
          "$OUT/rate_trend.tsv" | sort
   fi
   return $rc
}

if [ "$FOLLOW" -eq 0 ]; then
   one_pass
   exit $?
fi

echo "추이 갱신을 ${POLL}초마다 반복한다. Ctrl-C 로 멈춘다."
echo "출력 : $OUT"
trap 'echo; echo "멈춘다 ($(stamp))"; exit 0' INT TERM
while :; do
   one_pass || echo "[WARN] $(stamp) 한 단계가 실패했다. 다음 주기에 다시 해 본다."
   sleep "$POLL"
done
