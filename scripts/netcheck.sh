#!/bin/bash
# ---------------------------------------------------------------------
#  netcheck.sh — 바깥으로 나가는 링크가 실제로 얼마를 내는지 잰다
#
#  왜 있나 : 2026-08-26 에 경희대 백업이 143 Mbps 에서 막히는 것을 발견했다.
#            1 Gb 랜카드의 13% 다. 중간 장비를 빼거나 정책을 고친 뒤
#            "정말 나아졌는가" 를 같은 방법으로 재야 비교가 된다.
#            손으로 치면 매번 조건이 달라져 비교가 안 된다. 그래서 도구로 뺐다.
#
#  읽기만 한다. 하드웨어도 데이터도 건드리지 않는다.
#  ★ 다만 대역을 실제로 쓴다. 백업이 돌고 있으면 그만큼 나눠 쓴다
#    (그래서 '총 송신'을 재지 스트림 하나만 재지 않는다).
#
#  기준선 (2026-08-26 02:00 · 02:20, 두 번 같은 값)
#      5 스트림 총 송신   143 Mbps      <- 핵심 지표
#      백업 1 스트림      122~130 Mbps
#      kakao 받기         112~114 Mbps
#      naver 받기         110 Mbps
#      khu 받기           115~122 Mbps
#  근거와 판단은 CLAUDE.md §11.121
# ---------------------------------------------------------------------
set -uo pipefail

IFACE=${NETCHECK_IFACE:-enp0s31f6}
HOST=${NETCHECK_HOST:-khu}
STREAMS=${NETCHECK_STREAMS:-4}
MB=${NETCHECK_MB:-250}
DO_EXT=1; DO_KHU=1; DO_LOCAL=1

usage() {
   cat <<U
사용법 : scripts/netcheck.sh [옵션]

  --khu-only        경희대만 (보내기·받기)
  --ext-only        외부 미러 받기만
  --local-only      인터페이스·셰이핑·TCP 설정만 (대역을 안 쓴다)
  --streams N       동시 스트림 수 (기본 $STREAMS)
  --mb N            스트림당 보낼 MB (기본 $MB)
  -h, --help

  환경변수 : NETCHECK_IFACE(=$IFACE) NETCHECK_HOST(=$HOST)

  ★ 대역을 실제로 쓴다. 수집에는 영향이 없다 (DAQ 는 이 랜카드를 안 쓴다).
U
}
while [ $# -gt 0 ]; do
   case "$1" in
      --khu-only)   DO_EXT=0; DO_LOCAL=0 ;;
      --ext-only)   DO_KHU=0; DO_LOCAL=0 ;;
      --local-only) DO_KHU=0; DO_EXT=0 ;;
      --streams) STREAMS=$2; shift ;;
      --mb)      MB=$2; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "모르는 옵션 : $1" >&2; usage >&2; exit 2 ;;
   esac
   shift
done

TXF=/sys/class/net/$IFACE/statistics/tx_bytes
RXF=/sys/class/net/$IFACE/statistics/rx_bytes
[ -r "$TXF" ] || { echo "[FATAL] $IFACE 를 찾을 수 없다" >&2; exit 1; }

hr(){ printf '%s\n' "-----------------------------------------------------------"; }
mbps(){ awk -v b="$1" -v s="$2" 'BEGIN{printf "%6.1f MB/s = %4.0f Mbps", b/s/1048576, b/s*8/1e6}'; }

echo "==========================================================="
echo " netcheck  $(date '+%Y-%m-%d %H:%M:%S')   호스트 $(hostname)"
echo " 인터페이스 $IFACE   원격 $HOST"
echo "==========================================================="

if [ $DO_LOCAL -eq 1 ]; then
   hr; echo "[1] 이 PC 쪽 — 여기에 원인이 있는지부터 배제한다"
   ethtool "$IFACE" 2>/dev/null | grep -E 'Speed|Duplex|Link detected' | sed 's/^/    /'
   q=$(tc qdisc show dev "$IFACE" 2>/dev/null | head -1)
   echo "    qdisc : $q"
   if tc class show dev "$IFACE" 2>/dev/null | grep -q .; then
      echo "    ★ class 가 있다 — 속도 제한이 걸려 있을 수 있다"
      tc class show dev "$IFACE" | sed 's/^/      /'
   else
      echo "    class : 없음 (속도 제한 없음)"
   fi
   e=$(ethtool -S "$IFACE" 2>/dev/null | grep -iE 'error|collision' | grep -v ': 0$' | tr -d ' ' | paste -sd' ')
   echo "    오류  : ${e:-없음}"
   echo "    wmem  : $(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | tr '\t' ' ')"
   echo "    혼잡  : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
fi

# 지금 이 링크를 쓰고 있는 것 (기준선 해석에 필요)
busy=$(pgrep -f 'backup-khu|backup-trickle' 2>/dev/null | wc -l)

if [ $DO_KHU -eq 1 ]; then
   hr; echo "[2] $HOST 로 보내기  — ★ 총 송신이 핵심이다"
   [ "$busy" -gt 0 ] && echo "    (백업이 돌고 있다. 총량에 그것이 포함된다)"

   a=$(cat "$TXF"); sleep 10; b=$(cat "$TXF")
   echo "    기준선(10초)        : $(mbps $((b-a)) 10)"

   a=$(cat "$TXF"); s=$(date +%s%N)
   for _ in $(seq 1 "$STREAMS"); do
      dd if=/dev/zero bs=1M count="$MB" status=none 2>/dev/null \
         | timeout 180 ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" 'cat > /dev/null' &
   done
   wait
   e=$(date +%s%N); b=$(cat "$TXF")
   d=$(awk -v x="$s" -v y="$e" 'BEGIN{printf "%.3f", (y-x)/1e9}')
   echo "    + $STREAMS 스트림 총 송신 : $(mbps $((b-a)) "$d")   (${d}초)"
   echo "      ^ 기준선보다 크게 안 늘면 경로가 막혀 있다는 뜻이다"

   hr; echo "[3] $HOST 에서 받기"
   a=$(cat "$RXF"); s=$(date +%s%N)
   timeout 120 ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" \
        "dd if=/dev/zero bs=1M count=$((MB*2)) status=none" > /dev/null 2>&1
   e=$(date +%s%N); b=$(cat "$RXF")
   d=$(awk -v x="$s" -v y="$e" 'BEGIN{printf "%.3f", (y-x)/1e9}')
   echo "    받기                : $(mbps $((b-a)) "$d")"
fi

if [ $DO_EXT -eq 1 ]; then
   hr; echo "[4] 무관한 목적지에서 받기 — 경로 문제인지 우리 쪽 문제인지 가른다"
   for u in http://mirror.kakao.com/ubuntu-releases/24.04/ubuntu-24.04.3-live-server-amd64.iso \
            http://mirror.navercorp.com/ubuntu-releases/24.04/ubuntu-24.04.3-live-server-amd64.iso; do
      h=$(echo "$u" | awk -F/ '{print $3}')
      r=$(timeout 45 curl -s -o /dev/null --max-time 25 -w '%{speed_download} %{http_code}' "$u" 2>/dev/null)
      echo "$r" | awk -v h="$h" '{ if ($2=="200") printf "    %-22s %6.1f MB/s = %4.0f Mbps\n", h, $1/1048576, $1*8/1e6;
                                   else printf "    %-22s 실패 (http %s) — URL 을 확인할 것\n", h, $2 }'
   done
   echo "      ^ 여기도 같은 값이면 경희대 경로가 아니라 우리 쪽이 원인이다"
fi

hr
cat <<'T'
기준선 (2026-08-26, 중간 장비를 빼기 전. 두 번 재서 같은 값)
    5 스트림 총 송신  143 Mbps        <- 이 값이 올라가야 개선된 것이다
    받기              110~122 Mbps
근거와 판단 : CLAUDE.md §11.121
T
