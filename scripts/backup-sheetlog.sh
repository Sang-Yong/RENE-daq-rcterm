#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  backup-sheetlog.sh - 저장소 서버의 외장하드 백업 기록을 구글시트 back_up_hdd_log 탭에 자동 등재한다.
#
#  사용 :
#     backup-sheetlog.sh [--dry-run] [--status] [--no-notify]
#
#  어떻게 (2026-09-12, 사용자 지시)
#     저장소 서버에는 인터넷이 없다 (§11.144). 그래서 메일 큐와 같은 방향으로, 이 PC 가
#     ssh store 로 서버의 backup_log/parts_index.txt 와 backup_log.txt 를 받아
#     tools/sheetlog/append_backup_rows.py 로 등재한다. cron 이 매시 37분에 부른다.
#
#     * 시트의 마지막 (날짜, 시각) 뒤의 기록만 뒤에 붙인다. 기존 행은 절대 손대지 않는다.
#     * 쓴 것이 있으면 daq-notify 의 sheetlog 사건으로 책임자에게 메일 한 통.
#     * ssh 가 안 되면 (서버 다운·링크 끊김) 조용히 물러난다. 다음 시각에 다시 한다.
#     * 실패로 죽지 않는다. 종료코드는 언제나 0.
#
#  ★ 이 스크립트의 명령줄과 안의 명령 어디에도 백업 스크립트 이름을 넣지 말 것 —
#    저장소 서버의 other_backup() 이 pgrep -f 로 그 이름을 찾는다 (§11.183).
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
TOOL=$DIR/tools/sheetlog/append_backup_rows.py
NOTIFY=${BACKUP_SHEETLOG_NOTIFY:-$DIR/scripts/daq-notify.sh}   # 시험은 가짜로 갈아끼운다
PARAMS=$DIR/config/notify.params
LOG=${BACKUP_SHEETLOG_LOG:-/Data_ssd/LOG/backup-sheetlog.log}
LOCK=${BACKUP_SHEETLOG_LOCK:-/Data_ssd/LOG/.backup-sheetlog.lock}
STATE=${BACKUP_SHEETLOG_STATE:-/Data_ssd/LOG/backup-sheetlog.state}
STORE=${BACKUP_SHEETLOG_STORE:-store}
REMOTE_DIR=${BACKUP_SHEETLOG_REMOTE_DIR:-'~/sykim/backup_log'}
DRY=0; STATUS=0; NONOTIFY=0
while [ $# -gt 0 ]; do
   case "$1" in
      --dry-run)   DRY=1; shift ;;
      --status)    STATUS=1; shift ;;
      --no-notify) NONOTIFY=1; shift ;;
      -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) echo "모르는 옵션 : $1" >&2; exit 0 ;;
   esac
done
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

if [ "$STATUS" -eq 1 ]; then
   echo "backup-sheetlog 상태  $(date '+%F %T')"
   echo "  마지막 : $(sed -n 's/^last=//p' "$STATE" 2>/dev/null)"
   echo "  세션   : pid $(sed -n 's/^session_pid=//p' "$STATE" 2>/dev/null)"
   echo "  로그   : $(tail -1 "$LOG" 2>/dev/null)"
   exit 0
fi

exec 9>"$LOCK" 2>/dev/null || exec 9>/dev/null
flock -n 9 2>/dev/null || { log "이미 돌고 있다. 건너뛴다"; exit 0; }

T=$(mktemp -d) || exit 0
trap 'rm -rf "$T"' EXIT
#  ★ 원천을 통째로 받아 온다. 서버가 안 잡히면 조용히 물러난다.
if ! ssh -o ConnectTimeout=15 -o BatchMode=yes "$STORE" "cat $REMOTE_DIR/parts_index.txt" > "$T/index" 2>/dev/null; then
   log "저장소 서버에 닿지 않는다. 이번엔 쉰다"; exit 0
fi
ssh -o ConnectTimeout=15 -o BatchMode=yes "$STORE" "cat $REMOTE_DIR/backup_log.txt" > "$T/log" 2>/dev/null || : > "$T/log"
ssh -o ConnectTimeout=15 -o BatchMode=yes "$STORE" "lsblk -no UUID,MOUNTPOINT | awk 'NF==2 && \$2 ~ /backup/ {print \$1\"\t\"\$2}'" > "$T/mounts" 2>/dev/null || : > "$T/mounts"
ssh -o ConnectTimeout=15 -o BatchMode=yes "$STORE" "ls -1 /data/RAW" > "$T/srcdirs" 2>/dev/null || : > "$T/srcdirs"

#  ★ 백업 세션이 바뀌었는가 (2026-09-12, 사용자 지시 "새 세션 시작하면 새 판인지 확인").
#    잠금 파일 보유자(fuser)로 세션 pid 를 잡는다 -- 스크립트 이름을 명령줄에 넣으면 저쪽 other_backup() 에 걸린다(§11.183).
#    pid 가 바뀌면 그 프로세스가 붙든 스크립트에 새 판 표식(disk_alive · SHEET_URL)이 있는지 보고 로그 + 메일 한 통.
SESS_PID=$(ssh -o ConnectTimeout=15 -o BatchMode=yes "$STORE" "fuser $REMOTE_DIR/.backup.lock 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -n | head -1" 2>/dev/null)
PREV_PID=$(sed -n 's/^session_pid=//p' "$STATE" 2>/dev/null)
if [ "${SESS_PID:-}" != "${PREV_PID:-}" ]; then
   if [ -n "$SESS_PID" ]; then
      SESS_INFO=$(ssh -o ConnectTimeout=15 -o BatchMode=yes "$STORE" "f=\$(readlink /proc/$SESS_PID/fd/255); echo \"started \$(ps -o lstart= -p $SESS_PID) script \$f build=\$( [ \$(grep -c 'disk_alive()' \$f) -gt 0 ] && [ \$(grep -c SHEET_URL \$f) -gt 0 ] && echo NEW || echo OLD )\"" 2>/dev/null)
      log "백업 세션 바뀜 : pid ${PREV_PID:-없음} -> $SESS_PID  $SESS_INFO"
      [ "$NONOTIFY" -eq 1 ] || "$NOTIFY" --params "$PARAMS" backup_session --msg "저장소 백업 세션 시작 pid $SESS_PID : $SESS_INFO" >/dev/null 2>&1
   else
      log "백업 세션 끝남 : pid ${PREV_PID:-?} 사라짐. 마지막 : $(grep -E 'code=|backup done' "$T/log" | tail -1 | cut -c1-100)"
      [ "$NONOTIFY" -eq 1 ] || "$NOTIFY" --params "$PARAMS" backup_session --msg "저장소 백업 세션 끝남 (pid ${PREV_PID:-?}) : $(grep -E 'code=' "$T/log" | tail -1 | cut -c1-90)" >/dev/null 2>&1
   fi
   [ "$DRY" -eq 1 ] || { grep -v '^session_pid=' "$STATE" 2>/dev/null > "$STATE.tmp"; echo "session_pid=$SESS_PID" >> "$STATE.tmp"; mv -f "$STATE.tmp" "$STATE"; }
fi

ARGS=(--index "$T/index" --log "$T/log" --mounts "$T/mounts" --source-dirs "$T/srcdirs")
[ "$DRY" -eq 1 ] || ARGS+=(--commit)
out=$(cd "$DIR" && timeout 600 python3 "$TOOL" "${ARGS[@]}" 2>&1); rc=$?
printf '%s\n' "$out" | grep -E '^\[' | while read -r l; do log "$l"; done
n=$(printf '%s\n' "$out" | sed -n 's/.*새 행 \([0-9]*\).*/\1/p' | head -1)
if [ "$rc" -ne 0 ]; then log "등재 실패 rc=$rc"; exit 0; fi
if [ "$DRY" -eq 1 ]; then exit 0; fi
{ grep '^session_pid=' "$STATE" 2>/dev/null; printf 'last=%s rows=%s\n' "$(date '+%F %T')" "${n:-0}"; } > "$STATE.tmp" 2>/dev/null && mv -f "$STATE.tmp" "$STATE"
if [ "${n:-0}" -gt 0 ] && [ "$NONOTIFY" -eq 0 ]; then
   D=$(mktemp /tmp/backup-sheetlog-XXXXXX)
   printf '%s\n' "$out" > "$D"
   "$NOTIFY" --params "$PARAMS" sheetlog --msg "백업 하드 기록 시트에 ${n}행 등재 (back_up_hdd_log)" --detail-file "$D" >/dev/null 2>&1
   rm -f "$D"
fi
exit 0
