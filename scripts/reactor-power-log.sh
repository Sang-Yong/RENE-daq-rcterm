#!/usr/bin/env bash
# reactor-power-log.sh -- 한빛 원전 호기별 출력을 시간마다 KHNP 에서 읽어 기록한다. cron 이 매시 47분 + 재부팅 때 부른다 (2026-09-15).
#
#     reactor-power-log.sh                 한 번 기록 (cron 이 이렇게 부른다). 망이 없으면 최대 20 분 기다린다
#     reactor-power-log.sh --dry-run       읽기만, 아무것도 안 쓴다 (메일도 없다)
#     reactor-power-log.sh --status        마지막 기록 · 연속 실패 수 · 마지막 메일 (읽기 전용)
#     reactor-power-log.sh --install-cron  crontab 에 '47 * * * *' 과 '@reboot' 두 줄을 넣는다 (있으면 그대로)
#     reactor-power-log.sh --no-notify     실패해도 메일을 보내지 않는다
#
#   실패 처리 : 연속 2 회 실패하면 책임자에게 메일 (같은 사유는 6 시간에 한 번), 다시 성공하면 '복구' 메일 한 통.
#   정본은 로컬 TSV /Data_ssd/LOG/reactor-power/reactor_power.tsv 다. 시트가 안 되는 동안의 행은 다음 성공 때 도구가 스스로 메운다.
#   시험은 REACTOR_LOG_DIR · REACTOR_PY_ARGS(--fixture/--sheet-tsv) · REACTOR_MAIL(가짜 send_mail) · REACTOR_NET_CHECK=0 으로 갈아끼운다.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
PY=$DIR/tools/reactor/reactor_power_log.py
LOGDIR=${REACTOR_LOG_DIR:-/Data_ssd/LOG/reactor-power}
LOG=$LOGDIR/reactor-power-log.log
STATE=$LOGDIR/reactor-power-log.state
LOCK=${REACTOR_LOCK:-$LOGDIR/.lock}
MAIL=${REACTOR_MAIL:-$DIR/tools/notify/send_mail.py}
PARAMS=$DIR/config/notify.params
NETCHK=${REACTOR_NET_CHECK:-1}
MAIL_EVERY=${REACTOR_MAIL_EVERY:-21600}     # 같은 실패 사유의 메일 간격 [s]
FAIL_AFTER=${REACTOR_FAIL_AFTER:-2}         # 이만큼 연속 실패하면 메일
DRY=0; NONOTIFY=0
mkdir -p "$LOGDIR" 2>/dev/null
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >/dev/null; }
getst() { awk -F= -v k="$1" '$1==k{print $2}' "$STATE" 2>/dev/null; }
setst() {  # setst 키 값 ...
   local tmp="$STATE.tmp.$$"; cp "$STATE" "$tmp" 2>/dev/null || : > "$tmp"
   while [ $# -ge 2 ]; do grep -v "^$1=" "$tmp" > "$tmp.2" 2>/dev/null; printf '%s=%s\n' "$1" "$2" >> "$tmp.2"; mv -f "$tmp.2" "$tmp"; shift 2; done
   mv -f "$tmp" "$STATE"
}

case "${1:-}" in
   --dry-run) DRY=1 ;;
   --no-notify) NONOTIFY=1 ;;
   --status)
      echo "기록 폴더 : $LOGDIR"; python3 "$PY" --status --log-dir "$LOGDIR"
      echo "상태 : fails=$(getst fails) last_ok=$(getst last_ok) last_fail=$(getst last_fail) last_mail=$(getst last_mail) last_reason=$(getst last_reason)"
      crontab -l 2>/dev/null | grep -v '^#' | grep -q 'reactor-power-log.sh' && echo "cron : 등록됨 ($(crontab -l | grep -v '^#' | grep -c 'reactor-power-log.sh') 줄)" || echo "cron : ★ 등록 안 됨 (--install-cron)"
      exit 0 ;;
   --install-cron)
      cur=$(crontab -l 2>/dev/null)
      if printf '%s\n' "$cur" | grep -q 'reactor-power-log.sh'; then echo "이미 등록돼 있다"; exit 0; fi
      cp <(printf '%s\n' "$cur") "$HOME/crontab.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null
      { printf '%s\n' "$cur"; cat <<EOF
# 한빛 원전 호기별 출력 기록 -- 매시 47분 KHNP 에서 읽어 로컬 TSV + 구글 시트 KHNP_daily_power 탭 (CLAUDE.md 11.202)
#   재부팅 뒤에도 한 번 (망이 뜰 때까지 최대 20 분 기다린다). 상태 : scripts/reactor-power-log.sh --status
47 * * * * $DIR/scripts/reactor-power-log.sh >/dev/null 2>&1
@reboot $DIR/scripts/reactor-power-log.sh >/dev/null 2>&1
EOF
      } | crontab - && echo "등록했다 (47 * * * * + @reboot)"; exit $? ;;
   "") ;;
   -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
   *) echo "모르는 옵션 : $1"; exit 1 ;;
esac

exec 9>"$LOCK"; flock -n 9 || { log "[SKIP] 이미 돌고 있다"; exit 0; }

#  망이 뜰 때까지 기다린다 (재부팅 직후 @reboot 용). 20 분 넘게 안 뜨면 이번 회차는 실패로 센다
if [ "$NETCHK" = 1 ]; then
   for i in $(seq 1 40); do
      curl -s -m 15 -o /dev/null -w '%{http_code}' https://npp.khnp.co.kr/ 2>/dev/null | grep -qE '^[23]' && break
      [ "$i" = 40 ] && { log "[FAIL] 20 분 동안 npp.khnp.co.kr 에 닿지 못했다"; }
      sleep 30
   done
fi

#  ---- 기록 ----
# shellcheck disable=SC2086
if [ "$DRY" = 1 ]; then
   python3 "$PY" --log-dir "$LOGDIR" ${REACTOR_PY_ARGS:-} 2>&1 | tee -a "$LOG"; exit "${PIPESTATUS[0]}"
fi
OUT=$(python3 "$PY" --commit --log-dir "$LOGDIR" ${REACTOR_PY_ARGS:-} 2>&1); rc=$?
printf '%s\n' "$OUT" >> "$LOG"
fails=$(getst fails); fails=${fails:-0}
now=$(date +%s)
if [ $rc -eq 0 ]; then
   if [ "$fails" -ge "$FAIL_AFTER" ] && [ "$NONOTIFY" = 0 ]; then
      body="원자로 출력 기록이 다시 됩니다 (연속 실패 $fails 회 뒤 복구, $(date '+%F %T')).
마지막 기록 :
$(printf '%s\n' "$OUT" | tail -4)
정본 TSV : $LOGDIR/reactor_power.tsv   시트 : KHNP_daily_power 탭
상태 : scripts/reactor-power-log.sh --status"
      python3 "$MAIL" --params "$PARAMS" --to routine --subject "원자로 출력 기록 복구 (연속 실패 $fails 회 뒤)" --body-file <(printf '%s\n' "$body") >>"$LOG" 2>&1 \
         && log "[MAIL] 복구 알림" || log "[WARN] 복구 메일 실패"
   fi
   setst fails 0 last_ok "$(date '+%F %T')"
   log "[OK  ] rc=0"
   exit 0
fi
fails=$((fails + 1))
reason=$(printf '%s\n' "$OUT" | grep -E '\[FAIL\]' | tail -1 | sed 's/^\[[^]]*\] //')
setst fails "$fails" last_fail "$(date '+%F %T')" last_reason "${reason:-rc=$rc}"
log "[FAIL] rc=$rc (연속 $fails) : ${reason:-?}"
if [ "$fails" -ge "$FAIL_AFTER" ] && [ "$NONOTIFY" = 0 ]; then
   lastm=$(getst last_mail); lastm=${lastm:-0}
   if [ $((now - lastm)) -ge "$MAIL_EVERY" ]; then
      body="원자로 출력 기록 스크립트가 연속 $fails 회 실패했습니다 ($(date '+%F %T')).
스크립트 : $DIR/scripts/reactor-power-log.sh  (cron 매시 47분 + @reboot)
사유 : ${reason:-rc=$rc}
  rc 2 = KHNP 사이트를 못 읽음(망·사이트 변경)  rc 3 = 구글 시트 쓰기 실패(자격증명·API·탭)  rc 4 = 로컬 TSV 쓰기 실패(디스크)
마지막 출력 :
$(printf '%s\n' "$OUT" | tail -6)
로그 : $LOG
손으로 돌려 보기 : $DIR/scripts/reactor-power-log.sh --dry-run   (매뉴얼 docs/REACTOR-POWER-LOG.md)
정본 TSV 는 $LOGDIR/reactor_power.tsv 이고, 시트는 다음 성공 때 빠진 행을 스스로 메웁니다."
      python3 "$MAIL" --params "$PARAMS" --to routine --subject "원자로 출력 기록 실패 (연속 $fails 회, rc=$rc)" --body-file <(printf '%s\n' "$body") >>"$LOG" 2>&1 \
         && { log "[MAIL] 실패 알림"; setst last_mail "$now"; } || log "[WARN] 실패 메일도 못 보냈다"
   else
      log "[MAIL] 생략 (마지막 메일 $(( (now - lastm) / 60 )) 분 전)"
   fi
fi
exit $rc
