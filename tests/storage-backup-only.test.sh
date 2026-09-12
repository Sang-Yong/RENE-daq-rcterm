#!/usr/bin/env bash
# --only raw|prd : RAW 하드와 PRD 하드를 따로 채운다. raw = 최상위 FADC/SADC (PRD·PNG 는 남긴다), prd = PRD·PNG 만.
# 색인 13 열과 매니페스트 머리에 종류가 남고, 잘못된 값은 exit 2. 하드·메일 무접촉 (mktemp + BACKUP_TEST_HOOK). 한/영 두 판본.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✅ $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  ❌ $1"; [ $# -gt 1 ] && echo "       $2"; }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "기대 '$3' / 실제 '$2'"; fi; }

setup() {   # $1=SUT  — 런 하나 : 최상위 FADC/SADC 4+4, PRD 3, PNG 2, Merged 2
   SUT=$1; T=$(mktemp -d); SRC=$T/RAW; QUEUE=$T/MAILQ; r=000001; mkdir -p "$SRC/$r/PRD" "$SRC/$r/PNG" "$SRC/$r/Merged" "$QUEUE"
   for i in 1 2 3 4; do dd if=/dev/zero of="$SRC/$r/FADC_$r.root.0000$i" bs=1024 count=50 status=none; dd if=/dev/zero of="$SRC/$r/SADC_$r.root.0000$i" bs=1024 count=5 status=none; done
   for i in 1 2 3; do dd if=/dev/zero of="$SRC/$r/PRD/PRD_$r.0000$i.root" bs=1024 count=40 status=none; done
   for i in 1 2; do dd if=/dev/zero of="$SRC/$r/PNG/p$i.png" bs=1024 count=2 status=none; dd if=/dev/zero of="$SRC/$r/Merged/M$i.root" bs=1024 count=40 status=none; done
   find "$SRC" -exec touch -d '1 day ago' {} + 2>/dev/null
   DISKS=""; for i in 1 2; do m=$T/hdd$i; mkdir -p "$m"; echo 100000 > "$T/cap.hdd$i"; : > "$T/mounted.hdd$i"; DISKS="${DISKS:+$DISKS,}$m"; done
   HOOK=$T/hook.sh
   cat > "$HOOK" <<HOOKEOF
disk_is_mounted() { [ -f "$T/mounted.\$(basename "\$1")" ]; }
disk_cap_kb()     { cat "$T/cap.\$(basename "\$1")" 2>/dev/null || echo 0; }
disk_used_kb()    { du -sk "\$1" 2>/dev/null | awk '{print \$1}'; }
disk_avail_kb()   { local c u; c=\$(disk_cap_kb "\$1"); u=\$(disk_used_kb "\$1"); echo \$(( c - u < 0 ? 0 : c - u )); }
HOOKEOF
}
run_sut() {
   BACKUP_SOURCE="$SRC" BACKUP_MOUNTS="$DISKS" BACKUP_TEST_HOOK="$HOOK" BACKUP_LOG="$T/backup_log.txt" \
   BACKUP_SIZE_CACHE="$T/size.cache" BACKUP_PARTS_INDEX="$T/parts_index.txt" BACKUP_LOCK="$T/.lock" \
   BACKUP_SKIP_LIST="$T/skip.txt" BACKUP_MAILQ="$QUEUE" BACKUP_SAFETY_MARGIN_KB=64 BACKUP_MIN_USEFUL_KB=32 BACKUP_BWLIMIT= \
   timeout 120 bash "$SUT" "$@" > "$T/out.txt" 2>&1; RC=$?
}
cnt(){ find "$1" -type f ! -name '.part_manifest.txt' 2>/dev/null | wc -l; }

for v in storage-backup.sh storage-backup-en.sh; do
   echo ""; echo "[$v] --only raw : 최상위만 옮기고 PRD·PNG·Merged 는 남긴다"
   setup "$DIR/scripts/$v"; run_sut --only raw --disks "$T/hdd1"
   chk "exit 0" "$RC" "0"
   chk "하드에 8개 (FADC 4 + SADC 4)" "$(cnt "$T/hdd1")" "8"
   chk "  하드에 PRD/PNG/Merged 없음" "$(find "$T/hdd1" -type d \( -name PRD -o -name PNG -o -name Merged \) | wc -l)" "0"
   chk "원본에 PRD 3 · PNG 2 · Merged 2 남음, 최상위 0" "$(cnt "$SRC/000001/PRD")/$(cnt "$SRC/000001/PNG")/$(cnt "$SRC/000001/Merged")/$(find "$SRC/000001" -maxdepth 1 -type f | wc -l)" "3/2/2/0"
   [ -d "$SRC/000001" ] && ok "런 폴더는 남는다 (PRD 하드가 이어 담는다)" || bad "런 폴더가 지워졌다"
   grep -qE '부분백업|partial backup' "$T/backup_log.txt" && ok "로그 : 부분백업" || bad "로그" "$(tail -3 "$T/backup_log.txt")"
   chk "색인 13 열 = raw" "$(tail -1 "$T/parts_index.txt" | cut -f13)" "raw"
   chk "  색인 8 열 = full (담을 부분은 통째로 들어갔다)" "$(tail -1 "$T/parts_index.txt" | cut -f8)" "full"
   grep -qE 'only=raw' "$T/backup_log.txt" && ok "세션 시작 줄에 only=raw" || bad "세션 줄" "$(grep -E '세션 시작|session start' "$T/backup_log.txt")"
   grep -qE 'RAW 만|RAW only' "$T/out.txt" && ok "기동 화면이 종류를 말한다" || bad "기동 화면" "$(grep -iE 'raw' "$T/out.txt" | head -2)"
   #  종료 메일에 '담긴 것' 요약 : 런 · 종류 · 개수 · 서브런 (사용자 지시 2026-09-13) + 시트 링크
   m=$(ls "$QUEUE"/*.mail 2>/dev/null | tail -1)
   [ -n "$m" ] && grep -qE '담긴 것|Contents' "$m" && ok "메일에 '담긴 것' 요약" || bad "요약 없음" "$(grep -E '담긴|Contents' "$m" 2>/dev/null | head -2)"
   [ -n "$m" ] && grep -qE '000001 +full +RAW +8 (개|files)' "$m" && ok "  000001 full RAW 8 개" || bad "  요약 줄" "$(grep -E '000001' "$m" 2>/dev/null | head -2)"
   [ -n "$m" ] && grep -qE '서브런 00001~00004|subruns 00001~00004' "$m" && ok "  서브런 범위" || bad "  서브런 범위" "$(grep -E '000001' "$m" 2>/dev/null | head -2)"
   [ -n "$m" ] && grep -qE 'gid=219954027' "$m" && ok "  시트 링크" || bad "  시트 링크 없음"
   echo "[$v] 이어서 --only prd (다른 하드) : PRD·PNG 만 옮기고 Merged 만 남는다"
   run_sut --only prd --disks "$T/hdd2"
   chk "exit 0" "$RC" "0"
   chk "hdd2 에 5개 (PRD 3 + PNG 2), 경로 유지" "$(cnt "$T/hdd2")/$(cnt "$T/hdd2/RENE_data_backup/000001/PRD")/$(cnt "$T/hdd2/RENE_data_backup/000001/PNG")" "5/3/2"
   chk "원본엔 Merged 2 만" "$(cnt "$SRC/000001")/$(cnt "$SRC/000001/Merged")" "2/2"
   chk "색인 13 열 = prd" "$(tail -1 "$T/parts_index.txt" | cut -f13)" "prd"
   chk "hdd1 은 그대로 8개" "$(cnt "$T/hdd1")" "8"
   echo "[$v] --only prd 를 다시 돌리면 남은 일이 없다 (Merged 뿐)"
   run_sut --only prd --disks "$T/hdd2"
   chk "exit 0" "$RC" "0"
   chk "hdd2 그대로 5개" "$(cnt "$T/hdd2")" "5"
   chk "색인에 새 줄 없음 (2줄)" "$(wc -l < "$T/parts_index.txt")" "2"
   echo "[$v] 기본(--only 없음) 은 예전과 같다 : 색인 13 열 = all, 전부 옮긴다 (Merged 제외)"
   rm -rf "$T"; setup "$DIR/scripts/$v"; run_sut --disks "$T/hdd1"
   chk "exit 0" "$RC" "0"
   chk "하드에 13개 (8 + PRD 3 + PNG 2)" "$(cnt "$T/hdd1")" "13"
   chk "색인 13 열 = all" "$(tail -1 "$T/parts_index.txt" | cut -f13)" "all"
   echo "[$v] --only 값이 틀리면 exit 2"
   run_sut --only merged --disks "$T/hdd1"
   chk "exit 2" "$RC" "2"
   echo "[$v] 쪼개 담을 때(part) 매니페스트 머리에 only= 가 남는다"
   rm -rf "$T"; setup "$DIR/scripts/$v"; echo 150 > "$T/cap.hdd1"; echo 150 > "$T/cap.hdd2"   # RAW 220 KB 는 한 장(여유 134)에 안 들어간다 -> part
   BACKUP_SOURCE="$SRC" BACKUP_MOUNTS="$DISKS" BACKUP_TEST_HOOK="$HOOK" BACKUP_LOG="$T/backup_log.txt" BACKUP_SIZE_CACHE="$T/size.cache" \
   BACKUP_PARTS_INDEX="$T/parts_index.txt" BACKUP_LOCK="$T/.lock" BACKUP_SKIP_LIST="$T/skip.txt" BACKUP_MAILQ="$QUEUE" \
   BACKUP_SAFETY_MARGIN_KB=16 BACKUP_MIN_USEFUL_KB=32 BACKUP_BWLIMIT= timeout 120 bash "$SUT" --only raw > "$T/out.txt" 2>&1; RC=$?
   grep -q 'only=raw' "$T/hdd1/RENE_data_backup/000001/.part_manifest.txt" 2>/dev/null && ok "매니페스트 머리 only=raw" || bad "매니페스트" "$(head -2 "$T/hdd1/RENE_data_backup/000001/.part_manifest.txt" 2>/dev/null; echo rc=$RC; grep -E '❌|⚠️' "$T/out.txt" | head -3)"
   chk "  두 하드에 걸쳐 8개, 원본 최상위 0" "$(( $(cnt "$T/hdd1") + $(cnt "$T/hdd2") ))/$(find "$SRC/000001" -maxdepth 1 -type f 2>/dev/null | wc -l)" "8/0"
   chk "  PRD/PNG/Merged 는 원본에 그대로" "$(cnt "$SRC/000001/PRD")/$(cnt "$SRC/000001/PNG")/$(cnt "$SRC/000001/Merged")" "3/2/2"
   rm -rf "$T"
done
echo; echo "=========================================================="; printf "  통과 %d · 실패 %d\n" "$PASS" "$FAIL"; echo "=========================================================="; [ "$FAIL" -eq 0 ]
