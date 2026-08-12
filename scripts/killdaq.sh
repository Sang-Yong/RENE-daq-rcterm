#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  killdaq.sh : 남아있는 CUPDAQ 프로세스(tcb / daq / merger)를 정리한다.
#  DAQRC/killrun.py 에 대원되는 샤 버전.
#
#  usage : killdaq.sh [-b BINDIR] [-9] [-n]
#            -b BINDIR  tcb/daq/merger 가 있는 디렉토리
#                       (기본 : $ONLDAQ_DIR/bin)
#            -9         바로 SIGKILL
#            -n         드라이런 (지우지 않고 보여주기만)
# ---------------------------------------------------------------------
set -uo pipefail

BINDIR="${ONLDAQ_DIR:-}/bin"
HARD=0
DRY=0

while getopts "b:9nh" opt; do
  case "$opt" in
    b) BINDIR="$OPTARG" ;;
    9) HARD=1 ;;
    n) DRY=1 ;;
    h) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "see -h" >&2; exit 1 ;;
  esac
done

if [ -z "${BINDIR//\/bin/}" ] || [ ! -d "$BINDIR" ]; then
  echo "ERROR: bin directory not found : '$BINDIR'" >&2
  echo "       set ONLDAQ_DIR or use -b BINDIR" >&2
  exit 1
fi

echo "bin directory : $BINDIR"
echo "--- current DAQ processes -------------------------------------"
for p in tcb merger daq; do
  pgrep -a -f "$BINDIR/$p" || true
done
echo "--------------------------------------------------------------"

if [ "$DRY" = "1" ]; then
  echo "(dry run : nothing killed)"
  exit 0
fi

# tcb -> merger -> daq 순서로 내린다 (쓰는 족부터 종료)
if [ "$HARD" = "1" ]; then
  for p in tcb merger daq; do pkill -9 -f "$BINDIR/$p" 2>/dev/null || true; done
else
  for p in tcb merger daq; do pkill -f "$BINDIR/$p" 2>/dev/null || true; done
  sleep 3
  for p in tcb merger daq; do pkill -9 -f "$BINDIR/$p" 2>/dev/null || true; done
fi
sleep 1

echo "--- remaining ------------------------------------------------"
left=0
for p in tcb merger daq; do
  if pgrep -a -f "$BINDIR/$p"; then left=1; fi
done
[ "$left" = "0" ] && echo "(none)  -> clean"
exit 0
