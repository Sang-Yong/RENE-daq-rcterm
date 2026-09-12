#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  backup-sheet-rebuild.sh - 외장하드 백업 기록 시트(back_up_hdd_log)를 통째로 다시 쓴다.
#
#  사용 :  scripts/backup-sheet-rebuild.sh [--scan] [--commit] [--out-tsv FILE]
#     --scan     먼저 지금 꽂힌 하드를 훑어 목록 파일을 갱신한다 (scripts/backup-disk-inventory.sh)
#     --commit   시트를 실제로 다시 쓴다. 없으면 미리보기(무접촉)
#
#  순서 : (--scan) → 서버 기록(parts_index · backup_log · 붙은 UUID · /data/RAW 목록)을 ssh 로 받아 →
#         tools/sheetlog/rebuild_backup_sheet.py. 정렬은 (런, 시각). 라벨 정본은 docs/backup-disks/disks.tsv.
#  하드를 새로 꽂을 때마다 :  scripts/backup-sheet-rebuild.sh --scan --commit
#  ★ 명령줄에 백업 스크립트 이름을 넣지 말 것 — 저쪽 other_backup() 이 pgrep -f 로 잡는다 (§11.183).
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
STORE=${BACKUP_SHEETLOG_STORE:-store}; REMOTE_DIR=${BACKUP_SHEETLOG_REMOTE_DIR:-'~/sykim/backup_log'}
INV=${BACKUP_INVENTORY_DIR:-/Data_ssd/LOG/backup-inventory}
SCAN=0; ARGS=()
while [ $# -gt 0 ]; do
   case "$1" in
      --scan) SCAN=1; shift ;;
      -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) ARGS+=("$1"); shift ;;
   esac
done
if [ "$SCAN" -eq 1 ]; then
   "$DIR/scripts/backup-disk-inventory.sh" --out "$INV" --store "$STORE" || { echo "[FAIL] 스캔 실패"; exit 1; }
fi
T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT
S="ssh -o ConnectTimeout=15 -o BatchMode=yes $STORE"
$S "cat $REMOTE_DIR/parts_index.txt" > "$T/index" 2>/dev/null || { echo "[FAIL] 저장소 서버에 닿지 않는다"; exit 1; }
$S "cat $REMOTE_DIR/backup_log.txt" > "$T/log" 2>/dev/null || : > "$T/log"
$S "lsblk -no UUID,MOUNTPOINT | awk 'NF==2 && \$2 ~ /backup/ {print \$1\"\t\"\$2}'" > "$T/mounts" 2>/dev/null || : > "$T/mounts"
$S "ls -1 /data/RAW" > "$T/srcdirs" 2>/dev/null || : > "$T/srcdirs"
cd "$DIR" && exec python3 tools/sheetlog/rebuild_backup_sheet.py --inventory "$INV" --index "$T/index" --log "$T/log" \
        --mounts "$T/mounts" --source-dirs "$T/srcdirs" "${ARGS[@]}"
