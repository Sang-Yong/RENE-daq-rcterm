#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  netsync-lib.sh - 바깥 망(구글 메일·시트) 상태를 다른 스크립트가 묻는 작은 함수.
#
#  사용 :  . <저장소>/scripts/netsync-lib.sh ;  netsync_is_down && { 건너뛴다 ; }
#
#  netsync.sh(cron 5분)가 /Data_ssd/LOG/netsync.state 에 net=up|down 을 적는다.
#  여기서는 그것을 읽기만 한다.
#
#  ★ 상태 파일이 오래됐으면(기본 15분) '모른다' 로 보고 down 이 아니라고 답한다.
#    netsync 의 cron 이 죽었는데 옛 'down' 을 믿고 메일·시트를 영영 미루면,
#    알림이 조용히 꺼진 것과 같다. 모를 때는 시도하는 쪽이 낫다.
# ---------------------------------------------------------------------
NETSYNC_STATE=${NETSYNC_STATE:-/Data_ssd/LOG/netsync.state}
NETSYNC_FRESH_SEC=${NETSYNC_FRESH_SEC:-900}

netsync_is_down() {
   local t now v
   [ -r "$NETSYNC_STATE" ] || return 1
   v=$(sed -n 's/^net=//p' "$NETSYNC_STATE" 2>/dev/null | head -1)
   [ "$v" = down ] || return 1
   t=$(stat -c %Y "$NETSYNC_STATE" 2>/dev/null) || return 1
   now=$(date +%s)
   [ $(( now - t )) -le "$NETSYNC_FRESH_SEC" ]
}
