#!/usr/bin/env bash
# append_backup_rows.py — 서버 기록 -> back_up_hdd_log 행 변환·중복 제외·순서·되메움. 구글·ssh 무접촉 (--sheet-tsv).
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd); TOOL=$DIR/tools/sheetlog/append_backup_rows.py
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✅ $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  ❌ $1"; [ $# -gt 1 ] && echo "       $2"; }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "기대 '$3' / 실제 '$2'"; fi; }
col(){ awk -F'\t' -v r="$2" -v c="$3" 'NR==r{print $c}' "$1"; }

# 기존 시트 : 헤더 + 손으로 쓴 2 행 (마지막 2026-09-05 12:25:14)
H='No\tBackup Date\tBackup Time\tRun\tType\tFiles\tSize (GB)\tSubrun Range\tFirst File\tLast File\tFiles Left in Source\tStatus\tDisk Label\tDisk Mount\tDisk UUID\tDisk Model\tDisk Serial\tDisk Capacity\tDest Path\tVerified\tSource Deleted\tAlso at KHU\tScript\tStorage Location\tNotes'
printf "$H\n" > "$T/sheet.tsv"
printf '34\t2026-09-05\t09:32:26\t002443\tpart\t15700\t1232.7\t\t\t\t\t\t\t/backup_hdd_2\tU-D\t\t\t\t\t\t\t\tcode9\t\thand\n' >> "$T/sheet.tsv"
printf '35\t2026-09-05\t12:25:14\t002444\tpart\t2929\t504.8\t00000~02380\tFADC_002444.root.00000\tPRD/Run002444_DLY_THR.log\t21729\t\t\t/backup_hdd_2\tU-D\t\t\t\t\t\t\t\tcode9\t\thand\n' >> "$T/sheet.tsv"
cp "$T/sheet.tsv" "$T/sheet.orig"

# 서버 색인 : 옛 7열 (시트에 이미 있는 것 + 하나 더) · 새 12열 (part / full)
cat > "$T/index" <<'EOF'
002444	U-D	2026-09-05 12:25:14	2929	504800000000	FADC_002444.root.00000	PRD/Run002444_DLY_THR.log
002444	U-E	2026-09-06 16:37:00	14258	1865000000000	FADC_002444.root.02381	SADC_002444.root.01277
002456	U-C	2026-09-12 04:26:28	1681	48492477653	FADC_002456.root.00000	SADC_002456.root.01528	part	/backup_hdd	ST2000DM008-2FR102	ZK206014	1953514584
002457	U-C	2026-09-12 08:00:00	40	3000000000	FADC_002457.root.00000	SADC_002457.root.00019	full	/backup_hdd	ST2000DM008-2FR102	ZK206014	1953514584
EOF
# 서버 로그 : 회차 시작(UUID->마운트) + 옛 full 완료(색인에 없음, 되메움 대상) + 새 full 완료(색인에 있음, 되메움 대상 아님)
cat > "$T/log" <<'EOF'
[Sat Sep  6 04:00:00 PM KST 2026] === 하드 /backup_hdd_2 /dev/sdc1 UUID=U-E 회차 시작 ===
[Sun Sep  7 09:00:00 AM KST 2026] 002447 완료 및 서버에서 제거됨.
[Fri Sep 11 11:39:45 PM KST 2026] === 하드 /backup_hdd /dev/sdc1 UUID=U-C 회차 시작 ===
[Sat Sep 12 08:00:00 AM KST 2026] 002457 완료 및 서버에서 제거됨.
[Sat Sep 12 09:00:00 AM KST 2026] 002458 완료 및 서버에서 제거됨.
EOF
printf 'U-C\t/backup_hdd\nU-F\t/backup_hdd_2\n' > "$T/mounts"
printf '002444\n002456\n' > "$T/srcdirs"

echo "[1] 미리보기 : 새 행 5 (색인 3 + 되메움 2 : 옛 full 002447, 색인에 없는 새 full 002458), 시트는 그대로"
out=$(python3 "$TOOL" --index "$T/index" --log "$T/log" --mounts "$T/mounts" --source-dirs "$T/srcdirs" --sheet-tsv "$T/sheet.tsv" 2>&1); rc=$?
chk "rc=0" "$rc" "0"
printf '%s' "$out" | grep -q '새 행 5' && ok "새 행 5" || bad "새 행 수" "$(printf '%s' "$out" | head -2)"
cmp -s "$T/sheet.tsv" "$T/sheet.orig" && ok "미리보기는 쓰지 않는다" || bad "미리보기가 썼다"

echo "[2] --commit : 시간순으로 뒤에 붙고 번호가 이어진다"
python3 "$TOOL" --index "$T/index" --log "$T/log" --mounts "$T/mounts" --source-dirs "$T/srcdirs" --sheet-tsv "$T/sheet.tsv" --commit >/dev/null 2>&1
chk "행 수 3+5" "$(wc -l < "$T/sheet.tsv")" "8"
chk "기존 행 그대로" "$(head -3 "$T/sheet.tsv" | md5sum | cut -c1-8)" "$(md5sum < "$T/sheet.orig" | cut -c1-8)"
chk "4행 No=36 run 002444 (U-E part)" "$(col "$T/sheet.tsv" 4 1)/$(col "$T/sheet.tsv" 4 4)/$(col "$T/sheet.tsv" 4 15)" "36/002444/U-E"
chk "  뒤집힌 first/last 도 범위는 최소~최대" "$(col "$T/sheet.tsv" 4 8)" "01277~02381"
chk "5행 = 되메운 옛 full 002447" "$(col "$T/sheet.tsv" 5 4)/$(col "$T/sheet.tsv" 5 5)/$(col "$T/sheet.tsv" 5 2) $(col "$T/sheet.tsv" 5 3)" "002447/full/2026-09-07 09:00:00"
chk "  되메운 full 의 마운트는 로그의 회차에서" "$(col "$T/sheet.tsv" 5 14)" "/backup_hdd_2"
chk "  되메운 full 은 Files 비고 Notes 에 사유" "$(col "$T/sheet.tsv" 5 6)|$(col "$T/sheet.tsv" 5 25 | grep -c 'not in index')" "|1"
chk "6행 002456 part : 서브런 범위" "$(col "$T/sheet.tsv" 6 8)" "00000~01528"
chk "  GB 환산 (48.5)" "$(col "$T/sheet.tsv" 6 7)" "48.5"
chk "  모델·시리얼·용량" "$(col "$T/sheet.tsv" 6 16)/$(col "$T/sheet.tsv" 6 17)/$(col "$T/sheet.tsv" 6 18)" "ST2000DM008-2FR102/ZK206014/1.8 TB"
chk "  Status : U-C 는 붙어 있다" "$(col "$T/sheet.tsv" 6 12)" "on disk (attached)"
chk "  part 이고 원본이 남아 있다 -> moved files only / (still on server)" "$(col "$T/sheet.tsv" 6 21)|$(col "$T/sheet.tsv" 6 11)" "moved files only|(still on server)"
chk "  Dest Path" "$(col "$T/sheet.tsv" 6 19)" "/backup_hdd/RENE_data_backup/002456"
chk "7행 002457 full (색인에서) : Source Deleted=Y, Files Left=0" "$(col "$T/sheet.tsv" 7 5)/$(col "$T/sheet.tsv" 7 21)/$(col "$T/sheet.tsv" 7 11)" "full/Y/0"
chk "  U-E 는 안 붙어 있다" "$(col "$T/sheet.tsv" 4 12)" "on disk (not attached)"
chk "  색인에 있는 full(002457) 은 로그로 되메우지 않는다 (중복 없음)" "$(grep -c '002457' "$T/sheet.tsv")" "1"
chk "8행 = 색인에 없는 새 full 002458 을 로그에서 되메움" "$(col "$T/sheet.tsv" 8 4)/$(col "$T/sheet.tsv" 8 5)/$(col "$T/sheet.tsv" 8 14)" "002458/full//backup_hdd"
chk "모든 새 행이 25 열" "$(tail -5 "$T/sheet.tsv" | awk -F'\t' '{print NF}' | sort -u | tr '\n' ' ')" "25 "

echo "[3] 다시 돌리면 새 행 0 (멱등)"
out=$(python3 "$TOOL" --index "$T/index" --log "$T/log" --mounts "$T/mounts" --source-dirs "$T/srcdirs" --sheet-tsv "$T/sheet.tsv" --commit 2>&1)
printf '%s' "$out" | grep -q '새 행 0' && ok "새 행 0" || bad "멱등 아님" "$(printf '%s' "$out" | head -1)"
chk "행 수 그대로" "$(wc -l < "$T/sheet.tsv")" "8"

echo "[4] 헤더가 다르면 아무것도 안 쓰고 멈춘다"
printf 'A\tB\tC\n1\t2\t3\n' > "$T/bad.tsv"
python3 "$TOOL" --index "$T/index" --sheet-tsv "$T/bad.tsv" --commit >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "rc≠0" || bad "헤더 검사 없음"
chk "안 썼다" "$(wc -l < "$T/bad.tsv")" "2"

echo "[5] 보조 파일 없이도 돈다 (Status·Files Left 비움)"
cp "$T/sheet.orig" "$T/s2.tsv"
python3 "$TOOL" --index "$T/index" --sheet-tsv "$T/s2.tsv" --commit >/dev/null 2>&1; rc=$?
chk "rc=0" "$rc" "0"
chk "Status 빈칸" "$(col "$T/s2.tsv" 4 12)" ""

echo "[6] cron 스크립트 : --status 는 읽기 전용, ssh 가 안 되면 조용히 물러난다"
mkdir -p "$T/bin"; printf '#!/bin/sh\nexit 255\n' > "$T/bin/ssh"; chmod +x "$T/bin/ssh"
out=$(PATH="$T/bin:$PATH" BACKUP_SHEETLOG_STORE=nowhere bash "$DIR/scripts/backup-sheetlog.sh" 2>&1); rc=$?
chk "rc=0" "$rc" "0"
printf '%s' "$out" | grep -q '닿지 않는다' && ok "물러났다" || bad "물러나지 않음" "$out"

echo; echo "=========================================================="; printf "  통과 %d · 실패 %d\n" "$PASS" "$FAIL"; echo "=========================================================="; [ "$FAIL" -eq 0 ]
