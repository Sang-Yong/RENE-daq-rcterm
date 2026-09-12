#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  backup-disk-inventory.sh - 저장소 서버에 꽂힌 백업 하드를 훑어 하드마다 목록 파일을 남긴다.
#
#  사용 :  scripts/backup-disk-inventory.sh [--out DIR] [--store HOST] [MOUNT ...]
#           기본 마운트 = /backup_hdd /backup_hdd_2,  기본 DIR = /Data_ssd/LOG/backup-inventory
#
#  하드마다  DIR/<시리얼>_<UUID 앞 8>.tsv  (tools/sheetlog/disk-inventory-remote.sh 의 출력 그대로).
#  같은 하드를 다시 훑으면 덮어쓴다 (최신 스캔이 정본). 옛 것은 .prev 로 남긴다.
#  ★ 읽기 전용 (서버·하드를 바꾸지 않는다). 시트 재작성은 tools/sheetlog/rebuild_backup_sheet.py 가 한다.
#  ★ 명령줄에 백업 스크립트 이름을 넣지 말 것 — 저쪽 other_backup() 이 pgrep -f 로 잡는다 (§11.183).
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
REMOTE=$DIR/tools/sheetlog/disk-inventory-remote.sh
OUT=${BACKUP_INVENTORY_DIR:-/Data_ssd/LOG/backup-inventory}; STORE=${BACKUP_SHEETLOG_STORE:-store}; MOUNTS=()
while [ $# -gt 0 ]; do
   case "$1" in
      --out) OUT=$2; shift 2 ;;
      --store) STORE=$2; shift 2 ;;
      -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) MOUNTS+=("$1"); shift ;;
   esac
done
[ ${#MOUNTS[@]} -eq 0 ] && MOUNTS=(/backup_hdd /backup_hdd_2)
mkdir -p "$OUT" || exit 1
T=$(mktemp) || exit 1; trap 'rm -f "$T"' EXIT
if ! ssh -o ConnectTimeout=15 -o BatchMode=yes "$STORE" bash -s -- "${MOUNTS[@]}" < "$REMOTE" > "$T"; then
   echo "[FAIL] 저장소 서버 스캔 실패" >&2; exit 1
fi
#  하드 블록마다 파일로 나눈다 (#disk 줄이 경계)
awk -v out="$OUT" -F'\t' '
   /^#skip/ { print "[SKIP] " $2 " : " $3 " " $4 > "/dev/stderr"; f=""; next }
   /^#disk/ { serial=$6; uuid=substr($4,1,8); if(serial=="") serial="noserial"; f=out "/" serial "_" uuid ".tsv"
              if((getline l < f) >= 0) { close(f); system("mv -f \"" f "\" \"" f ".prev\"") }
              print "[DISK] " $2 " " $3 " serial=" $6 " uuid=" $4 " -> " f > "/dev/stderr" }
   f != "" { print >> f }
   END { }' "$T"
for f in "$OUT"/*.tsv; do [ -f "$f" ] || continue; n=$(grep -cvE '^#' "$f"); echo "$(basename "$f")  런 $n 개  $(awk -F'\t' '/^#disk/{print $2, $5, "cap", int($8/1e9) "GB used", int($9/1e9) "GB"}' "$f")"; done
exit 0
