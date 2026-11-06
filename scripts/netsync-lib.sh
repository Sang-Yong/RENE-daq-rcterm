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

# ---- 자율 복구 드릴 중인가 (2026-11-06) ------------------------------------
#  autonomy-drill.sh 가 전제 통과 직후 플래그(pid= pstart= start= run= plan=)를 만들고 끝에 지운다.
#  daq-notify(수신자 책임자만 · [DRILL] · 알람 없음) · netsync(시트·웹 건너뜀) · sheetlog-auto(쓰지 않음) 가 읽는다.
#  경로 : 환경변수 DRILL_FLAG > notify.params 의 drill_flag > /Data_ssd/LOG/drill.active
#  ★ 플래그를 쥔 pid 가 없거나(드릴이 SIGKILL 로 죽었다) 그 pid 가 남의 것이 됐거나 24 h 를 넘겼으면 '드릴 아님' 으로 본다.
#    죽은 플래그를 믿고 전문가 메일을 영영 막으면 알림이 조용히 꺼진 것과 같다.
DRILL_FLAG_FROM_ENV=${DRILL_FLAG:+1}
DRILL_FLAG=${DRILL_FLAG:-/Data_ssd/LOG/drill.active}
DRILL_FLAG_MAX_AGE=${DRILL_FLAG_MAX_AGE:-86400}
drill_flag_param() {     # $1 = params 의 drill_flag 값. 환경변수가 이긴다
   [ -z "${DRILL_FLAG_FROM_ENV:-}" ] && [ -n "${1:-}" ] && DRILL_FLAG=$1
   return 0
}
drill_flag_get() { sed -n "s/^$1=//p" "$DRILL_FLAG" 2>/dev/null | head -1; }
#  /proc/<pid>/stat 의 22 번째 필드(부팅 뒤 시작 시각, clock tick). comm 에 공백·괄호가 있어도 마지막 ') ' 뒤에서 센다
drill_proc_start() { local s; s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1; s=${s##*) }; set -- $s; [ -n "${20:-}" ] && echo "${20}"; }
drill_active() {
   local p t ps
   [ -r "$DRILL_FLAG" ] || return 1
   p=$(drill_flag_get pid); case "$p" in ''|*[!0-9]*) return 1 ;; esac
   [ -d "/proc/$p" ] || return 1
   #  ★ pid 는 한 바퀴 돈다 (pid_max 4.19 M, 2026-11 실측 3.6 M). SIGKILL 된 드릴의 pid 를 남이 물려받으면
   #    전문가 메일·시트가 조용히 꺼진다. 플래그의 pstart(그 pid 의 시작 시각)가 지금 그 pid 의 것과 같아야 드릴이다.
   #    pstart 가 없는 플래그(옛 판·손으로 쓴 것)는 그 pid 의 명령줄에 autonomy-drill 이 있어야 한다
   ps=$(drill_flag_get pstart)
   if [ -n "$ps" ]; then
      [ "$(drill_proc_start "$p")" = "$ps" ] || return 1
   else
      tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'autonomy-drill' || return 1
   fi
   t=$(stat -c %Y "$DRILL_FLAG" 2>/dev/null) || return 1
   [ $(( $(date +%s) - t )) -le "$DRILL_FLAG_MAX_AGE" ]
}
