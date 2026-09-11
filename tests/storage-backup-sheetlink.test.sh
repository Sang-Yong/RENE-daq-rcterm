#!/usr/bin/env bash
# 백업 메일 본문마다 기록 시트 링크 + 서버 기록 경로가 들어가는지 (한/영). 하드·메일 무접촉.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd); PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✅ $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  ❌ $1"; }
for v in storage-backup.sh storage-backup-en.sh; do
  T=$(mktemp -d); SRC=$T/RAW; Q=$T/MAILQ; mkdir -p "$SRC/000001/PRD" "$Q" "$T/hdd1"
  dd if=/dev/zero of="$SRC/000001/FADC_000001.root.00001" bs=1024 count=100 status=none; find "$SRC" -exec touch -d '1 day ago' {} +
  echo 100000 > "$T/cap.hdd1"; : > "$T/mounted.hdd1"; : > "$T/alive.hdd1"
  cat > "$T/hook.sh" <<H
disk_is_mounted() { [ -f "$T/mounted.\$(basename "\$1")" ]; }
disk_alive()      { [ -f "$T/alive.\$(basename "\$1")" ]; }
disk_cap_kb()     { cat "$T/cap.\$(basename "\$1")"; }
disk_used_kb()    { du -sk "\$1" | awk '{print \$1}'; }
disk_avail_kb()   { local c u; c=\$(disk_cap_kb "\$1"); u=\$(disk_used_kb "\$1"); echo \$(( c - u < 0 ? 0 : c - u )); }
H
  BACKUP_SOURCE="$SRC" BACKUP_MOUNTS="$T/hdd1" BACKUP_TEST_HOOK="$T/hook.sh" BACKUP_LOG="$T/log.txt" BACKUP_SIZE_CACHE="$T/sz" \
  BACKUP_PARTS_INDEX="$T/parts" BACKUP_LOCK="$T/.lock" BACKUP_SKIP_LIST="$T/skip" BACKUP_MAILQ="$Q" BACKUP_SAFETY_MARGIN_KB=64 \
  BACKUP_MIN_USEFUL_KB=32 BACKUP_BWLIMIT= BACKUP_ALIVE_POLL=1 BACKUP_SHEET_URL="https://example.test/SHEET?gid=42" \
  timeout 120 bash "$DIR/scripts/$v" > "$T/out.txt" 2>&1
  echo "[$v]"
  m=$(ls "$Q"/*.mail 2>/dev/null | head -1)
  [ -n "$m" ] && ok "완료 메일 1통" || bad "메일 없음"
  grep -q 'https://example.test/SHEET?gid=42' "$m" 2>/dev/null && ok "시트 링크 (BACKUP_SHEET_URL) 가 본문에" || bad "링크 없음"
  grep -q "$T/parts" "$m" 2>/dev/null && ok "parts_index 경로" || bad "parts 경로 없음"
  grep -q "$T/log.txt" "$m" 2>/dev/null && ok "backup_log 경로" || bad "log 경로 없음"
  # 기본값이 GoodRuns 문서의 back_up_hdd_log 탭(gid 219954027)인가
  grep -q 'gid=219954027' "$DIR/scripts/$v" && ok "기본 링크가 back_up_hdd_log 탭" || bad "기본 gid 틀림"
  rm -rf "$T"
done
echo; echo "PASS $PASS  FAIL $FAIL"; [ $FAIL = 0 ]
