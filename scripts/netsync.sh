#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  netsync.sh - 바깥 망(구글 메일·시트)이 끊겼다 돌아오는 것을 보고, 돌아온 순간 밀린 것을 내보낸다.
#
#  사용 :
#     netsync.sh                  한 번 점검 (cron 이 5분마다)
#     netsync.sh --status         읽기 전용. 마지막 점검 결과만 보인다 (망에 붙지도 않는다)
#     netsync.sh --dry-run        점검은 하되 상태를 안 바꾸고 아무것도 내보내지 않는다
#     netsync.sh --install-cron   crontab 에 '*/5' 한 줄을 넣는다 (기존 crontab 은 ~/crontab.bak-<시각>)
#
#  왜 (2026-11-05 감사 §7)
#     이 PC 의 바깥 출구는 enp0s31f6 하나다. 끊기면 메일은 큐(/Data_ssd/LOG/MAILQ)에 쌓이고
#     시트 등재·웹 발행·원자로 출력 기록은 실패한다. 각 cron 이 매시 실패 메일을 쏟는 대신,
#     여기서 한 번 '끊겼다' 고 적어 두면 다른 스크립트가 netsync_is_down 으로 읽고 조용히 미룬다.
#
#  점검 (각 5 초 안팎)
#     dns     getent hosts smtp.gmail.com
#     smtp    notify.params 의 smtp_host:smtp_port (기본 smtp.gmail.com:587) 에 TCP 연결 (보내지는 않는다)
#     sheets  sheets.googleapis.com:443 에 TCP 연결
#     khu     ssh -o BatchMode=yes -o ConnectTimeout=10 khu true   (기록만. net 판정에는 안 쓴다.
#             남의 서버라 30 분에 한 번만 붙는다 -- 그 사이는 지난 값을 쓴다, NETSYNC_KHU_EVERY)
#     net=up  <=  dns 와 (smtp 또는 sheets)
#
#  전환
#     up -> down   연속 NETSYNC_DOWN_CONSEC(기본 2) 회 실패해야 down. 일시적 흔들림으로 메일 두 통을 내지 않는다.
#                  로그 + net_down 메일 한 통을 큐에 (망이 돌아오면 그때 나간다). 알람(소리)은 없다
#     down -> up   곧바로 : 메일 큐 비우기(mailq-send) · 시트 원장 flush(sheet_ledger.py --flush, 전 탭 -- 망이 없던 동안
#                  로컬 원장에만 적힌 행을 원장 값으로 시트에, 2026-11-09) · sheetlog-auto (보통 게이트) · backup-sheetlog ·
#                  reactor-power-log · websummary(뒤에서, 자기 잠금이 겹치면 스스로 건너뛴다) ·
#                  복귀 메일 1 통 (단절 시간 · 밀린 메일 수 · 등재 런 수)
#     ★ sheetlog-auto 를 --force 로 부르지 않는다 (2026-11-06). 망 복귀가 등재를 서두를 이유가 없고,
#       --force 는 사람이 검토할 틈을 없앤다 -- 11-06 09:35 복귀 때 드릴 시험 런 4435·4436 이 그 자리에서 실렸다.
#     ★ 자율 복구 드릴 중(drill_flag)이면 sheetlog-auto · websummary 는 아예 건너뛴다 (로그에 사유)
#
#  상태 파일 /Data_ssd/LOG/netsync.state  (net= since= fails= checked= dns= smtp= sheets= khu=)
#  ★ 죽지 않는다. 종료코드는 언제나 0 (감시·알림이 스스로 넘어지면 없느니만 못하다).
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
. "$DIR/scripts/netsync-lib.sh"
type drill_active >/dev/null 2>&1 || { drill_active() { return 1; }; drill_flag_param() { :; }; }
STATE=$NETSYNC_STATE
LOG=${NETSYNC_LOG:-/Data_ssd/LOG/netsync.log}
LOCK=${NETSYNC_LOCK:-/Data_ssd/LOG/.netsync.lock}
DOWN_CONSEC=${NETSYNC_DOWN_CONSEC:-2}
PARAMS=${NETSYNC_PARAMS:-$DIR/config/notify.params}
NOTIFY=${NETSYNC_NOTIFY:-$DIR/scripts/daq-notify.sh}
MAILQ_CMD=${NETSYNC_MAILQ_CMD:-$DIR/scripts/mailq-send.sh}
SHEETLOG_CMD=${NETSYNC_SHEETLOG_CMD:-$DIR/scripts/sheetlog-auto.sh}
BACKUPSHEET_CMD=${NETSYNC_BACKUPSHEET_CMD:-$DIR/scripts/backup-sheetlog.sh}
REACTOR_CMD=${NETSYNC_REACTOR_CMD:-$DIR/scripts/reactor-power-log.sh}
WEBSUMMARY_CMD=${NETSYNC_WEBSUMMARY_CMD:-$DIR/tools/monitor/websummary.sh}
LEDGER_CMD=${NETSYNC_LEDGER_CMD:-$DIR/tools/sheetlog/sheet_ledger.py}
QUEUES=${NETSYNC_QUEUES:-/scratch/MAILQ /Data_ssd/LOG/MAILQ}
PROBE=${NETSYNC_PROBE:-}            # 시험용 : '<스크립트> <검사이름>' 의 종료코드를 결과로 쓴다
BG=${NETSYNC_BG:-1}                 # 1 이면 websummary 를 뒤에서 (시험은 0)
KHU_EVERY=${NETSYNC_KHU_EVERY:-1800}
#  메일 서버는 daq-notify / send_mail.py 가 실제로 쓰는 곳을 잰다 (notify.params). 없으면 Gmail 기본값
pget() { [ -r "$PARAMS" ] && sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PARAMS" 2>/dev/null | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//' | head -1; }
SMTP_HOST=$(pget smtp_host); SMTP_HOST=${SMTP_HOST:-smtp.gmail.com}
SMTP_PORT=$(pget smtp_port); case "$SMTP_PORT" in ''|*[!0-9]*) SMTP_PORT=587 ;; esac
drill_flag_param "$(pget drill_flag)"

MODE=run
case "${1:-}" in
   --status)  MODE=status ;;
   --dry-run) MODE=dry ;;
   "") ;;
   --install-cron)
      cur=$(crontab -l 2>/dev/null)
      printf '%s\n' "$cur" | grep -q 'scripts/netsync\.sh' && { echo "이미 등록돼 있다"; exit 0; }
      printf '%s\n' "$cur" > "$HOME/crontab.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null
      { printf '%s\n' "$cur"
        printf '# 바깥 망 단절·복귀 감시, 복귀 때 밀린 메일·시트를 내보낸다. 상태 : scripts/netsync.sh --status\n'
        printf '*/5 * * * * %s/scripts/netsync.sh >/dev/null 2>&1\n' "$DIR"; } | crontab - && echo "등록했다 (*/5)"
      exit 0 ;;
   -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
   *) echo "모르는 옵션 : $1" >&2; exit 0 ;;
esac

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }
st_get() { [ -r "$STATE" ] && sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -1; }
dur() { local s=$1; printf '%d시간 %02d분' $(( s / 3600 )) $(( s % 3600 / 60 )); }

if [ "$MODE" = status ]; then
   echo "netsync 상태  $(date '+%F %T')"
   if [ ! -r "$STATE" ]; then echo "  상태 파일 없음 ($STATE) -- 아직 한 번도 안 돌았다"; exit 0; fi
   c=$(st_get checked); n=$(st_get net); since=$(st_get since)
   echo "  망        : ${n:-?}  ($( [ -n "$since" ] && date -d @"$since" '+%F %T' ) 부터, $( [ -n "$since" ] && dur $(( $(date +%s) - since )) ))"
   echo "  마지막 점검 : $( [ -n "$c" ] && date -d @"$c" '+%F %T' )  · 연속 실패 $(st_get fails)/$DOWN_CONSEC"
   echo "  검사      : dns=$(st_get dns) smtp=$(st_get smtp) ($(st_get smtp_target)) sheets=$(st_get sheets) khu=$(st_get khu) (khu 는 ${KHU_EVERY}s 에 한 번)"
   netsync_is_down && echo "  ★ 다른 스크립트는 지금 메일·시트를 미루고 있다 (netsync_is_down)"
   drill_active && echo "  ★ 자율 복구 드릴 중 (pid $(drill_flag_get pid), $DRILL_FLAG) -- 복귀해도 시트·웹 발행은 건너뛴다"
   [ -n "$c" ] && [ $(( $(date +%s) - c )) -gt "$NETSYNC_FRESH_SEC" ] && echo "  ★ 상태가 오래됐다 -- cron 이 사는지 볼 것 (crontab -l)"
   for q in $QUEUES; do [ -d "$q" ] && echo "  메일 큐   : $q  대기 $(find "$q" -maxdepth 1 -name '*.mail' 2>/dev/null | wc -l) 통"; done
   [ -x "$LEDGER_CMD" ] && "$LEDGER_CMD" --status 2>/dev/null | sed -n '2,$p' | sed 's/^ */  시트 원장 : /'
   [ -s "$LOG" ] && { echo "  최근 로그 :"; tail -5 "$LOG" | sed 's/^/    /'; }
   exit 0
fi

exec 9>"$LOCK" 2>/dev/null || exec 9>/dev/null
flock -n 9 2>/dev/null || { log "이미 실행 중. 건너뛴다"; exit 0; }

# ---- 검사 -------------------------------------------------------------
probe() {
   if [ -n "$PROBE" ]; then "$PROBE" "$1" "$SMTP_HOST" "$SMTP_PORT" >/dev/null 2>&1; return; fi
   case "$1" in
      dns)    timeout 5 getent hosts "$SMTP_HOST" >/dev/null 2>&1 ;;
      smtp)   timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$SMTP_HOST" "$SMTP_PORT" >/dev/null 2>&1 ;;
      sheets) timeout 5 bash -c 'exec 3<>/dev/tcp/sheets.googleapis.com/443' >/dev/null 2>&1 ;;
      khu)    timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=10 khu true >/dev/null 2>&1 ;;
   esac
}
r() { probe "$1" && echo ok || echo fail; }
DNS=$(r dns); SMTP=fail; SHEETS=fail
if [ "$DNS" = ok ]; then SMTP=$(r smtp); SHEETS=$(r sheets); fi
now=$(date +%s)
khu_at=$(st_get khu_checked); case "$khu_at" in ''|*[!0-9]*) khu_at=0 ;; esac
if [ $(( now - khu_at )) -ge "$KHU_EVERY" ]; then KHU=$(r khu); khu_at=$now
else KHU=$(st_get khu); KHU=${KHU:-?}; fi
NOW_OK=0; [ "$DNS" = ok ] && { [ "$SMTP" = ok ] || [ "$SHEETS" = ok ]; } && NOW_OK=1

prev=$(st_get net); prev=${prev:-up}
since=$(st_get since); since=${since:-$now}
fails=$(st_get fails); case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
first_fail=$(st_get first_fail)

write_state() {          # $1=net $2=since $3=fails $4=first_fail
   local tmp
   [ "$MODE" = dry ] && return 0
   tmp=$(mktemp "${STATE}.XXXXXX" 2>/dev/null) || return 0
   printf 'net=%s\nsince=%s\nfails=%s\nfirst_fail=%s\nchecked=%s\ndns=%s\nsmtp=%s\nsheets=%s\nkhu=%s\nkhu_checked=%s\nsmtp_target=%s:%s\n' \
      "$1" "$2" "$3" "$4" "$now" "$DNS" "$SMTP" "$SHEETS" "$KHU" "$khu_at" "$SMTP_HOST" "$SMTP_PORT" > "$tmp" 2>/dev/null
   mv -f "$tmp" "$STATE" 2>/dev/null || rm -f "$tmp"
}
say() { [ "$MODE" = dry ] && printf '%s\n' "$*"; return 0; }
say "검사 : dns=$DNS smtp=$SMTP sheets=$SHEETS khu=$KHU  -> $( [ $NOW_OK = 1 ] && echo up || echo fail )  (이전 net=$prev, 연속 실패 $fails)"

queued() { local n=0 q; for q in $QUEUES; do n=$(( n + $(find "$q" -maxdepth 1 -name '*.mail' 2>/dev/null | wc -l) )); done; echo $n; }

# ---- 망 복귀 : 밀린 것을 내보낸다 ---------------------------------------
flush() {                # $1 = 단절 시작 epoch
   local down_at=$1 q0 q1 out runs rc sheetmsg DRILLNOW
   q0=$(queued)
   log "망 복귀 -- 밀린 것을 내보낸다 (단절 $(dur $(( now - down_at ))), 메일 큐 $q0 통)"
   timeout 600 "$MAILQ_CMD" >/dev/null 2>&1; log "  mailq-send rc=$?"
   #  ★ 시트 원장 : 망이 없던 동안 원장에만 적힌 행을 먼저 민다 (드릴 중이면 도구가 스스로 건너뛴다)
   ledout=$(timeout 900 "$LEDGER_CMD" --flush 2>&1); lrc=$?
   lsent=$(printf '%s\n' "$ledout" | grep -c '^\[SHEET\].*되대조 통과')
   log "  sheet_ledger --flush rc=$lrc (시트로 보낸 탭 $lsent)"
   printf '%s\n' "$ledout" | grep -E '^\[(SHEET|FAIL|SKIP)\]' | head -8 | sed 's/^/    /' >> "$LOG" 2>/dev/null
   if drill_active; then
      DRILLNOW=1; sheetmsg="시트 등재 건너뜀 (드릴 중)"
      log "  sheetlog-auto 건너뜀 (드릴 중 : $DRILL_FLAG pid $(drill_flag_get pid)) -- 드릴 시험 런을 싣지 않는다"
   else
      DRILLNOW=0
      out=$(timeout 1200 "$SHEETLOG_CMD" 2>&1); rc=$?
      runs=$(printf '%s\n' "$out" | sed -n 's/.*\[OK\] 등재 \([0-9]\+\) 런.*/\1/p' | tail -1)
      log "  sheetlog-auto rc=$rc 등재 ${runs:-0} 런"
      sheetmsg="시트 등재 ${runs:-0} 런 (보통 게이트 : 완결 5 개 또는 24 h)"
   fi
   timeout 900 "$BACKUPSHEET_CMD" >/dev/null 2>&1; log "  backup-sheetlog rc=$?"
   timeout 300 "$REACTOR_CMD" >/dev/null 2>&1;     log "  reactor-power-log rc=$?"
   if [ "$DRILLNOW" = 1 ]; then
      log "  websummary 건너뜀 (드릴 중)"
   elif [ -x "$WEBSUMMARY_CMD" ]; then
      if [ "$BG" = 1 ]; then
         setsid nohup "$WEBSUMMARY_CMD" >/dev/null 2>&1 < /dev/null &
         log "  websummary 를 뒤에서 띄웠다 (자기 잠금이 겹치면 스스로 건너뛴다)"
      else
         "$WEBSUMMARY_CMD" >/dev/null 2>&1; log "  websummary rc=$?"
      fi
   fi
   q1=$(queued)
   "$NOTIFY" --params "$PARAMS" net_restored \
      --msg "바깥 망 복귀 -- 단절 $(dur $(( now - down_at ))) ($(date -d @"$down_at" '+%m-%d %H:%M') ~ $(date -d @"$now" '+%H:%M')) · 밀린 메일 $q0 통 중 $(( q0 - q1 )) 통 보냄 · 시트 원장 flush rc=$lrc · $sheetmsg" \
      >/dev/null 2>&1 || log "WARN 복귀 메일 실패"
}

if [ "$NOW_OK" = 1 ]; then
   if [ "$prev" = down ]; then
      say "전환 : down -> up  (단절 $(dur $(( now - since ))))"
      if [ "$MODE" = dry ]; then if drill_active; then say "[DRY] mailq-send · backup-sheetlog · reactor-power-log · net_restored 메일을 했을 것 (드릴 중 : sheetlog-auto · websummary 건너뜀)"
         else say "[DRY] mailq-send · sheet_ledger --flush · sheetlog-auto · backup-sheetlog · reactor-power-log · websummary · net_restored 메일을 했을 것"; fi
      else
         write_state up "$now" 0 ""          # ★ 먼저 up 으로 적어야 내보내는 쪽들이 netsync_is_down 에 막히지 않는다
         flush "$since"
      fi
   else
      [ "$fails" -gt 0 ] && log "검사 회복 (연속 실패 $fails 회 뒤, down 으로 가기 전)"
      write_state up "$since" 0 ""
   fi
   exit 0
fi

#  이번 검사는 실패
fails=$(( fails + 1 )); [ -n "$first_fail" ] || first_fail=$now
if [ "$prev" = down ]; then
   write_state down "$since" "$fails" "$first_fail"
   exit 0
fi
if [ "$fails" -lt "$DOWN_CONSEC" ]; then
   log "검사 실패 $fails/$DOWN_CONSEC (dns=$DNS smtp=$SMTP sheets=$SHEETS) -- 아직 down 으로 보지 않는다"
   write_state up "$since" "$fails" "$first_fail"
   exit 0
fi
say "전환 : up -> down"
log "망 단절 (dns=$DNS smtp=$SMTP sheets=$SHEETS khu=$KHU, $(date -d @"$first_fail" '+%F %T') 부터)"
write_state down "$first_fail" "$fails" "$first_fail"
if [ "$MODE" = dry ]; then say "[DRY] net_down 메일을 큐에 넣었을 것"
else
   #  state 가 이미 down 이므로 daq-notify 는 보내려 하지 않고 곧바로 큐에 넣는다. 망이 돌아오면 나간다
   "$NOTIFY" --params "$PARAMS" net_down \
      --msg "바깥 망 단절 $(date -d @"$first_fail" '+%F %T') 부터 (dns=$DNS smtp=$SMTP sheets=$SHEETS) -- 이 메일은 복귀 뒤에 나간 것이다" \
      >/dev/null 2>&1 || log "WARN net_down 큐 적재 실패"
fi
exit 0
