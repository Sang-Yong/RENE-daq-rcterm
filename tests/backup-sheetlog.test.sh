#!/usr/bin/env bash
# append_backup_rows.py — 서버 기록 -> back_up_hdd_log 행 변환·중복 제외·순서·되메움. 구글·ssh 무접촉 (--sheet-tsv).
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd); TOOL=$DIR/tools/sheetlog/append_backup_rows.py
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export BACKUP_DISKS_TSV="$T/disks.tsv" BACKUP_DISKS_MD="$T/disks.md"     # 라벨 정본은 임시 파일 (실제 docs/ 를 건드리지 않는다)
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

echo "[7] cron 스크립트 : 세션 pid 가 바뀌면 판(NEW/OLD)을 판정해 로그 + backup_session 알림, 같으면 조용"
#  가짜 ssh : 원격 명령을 흉내 낸다. fuser -> $T/pid 의 값, readlink/ps/grep 조합 -> 판 판정 문구, cat -> 픽스처
cat > "$T/bin/ssh" <<'S'
#!/bin/bash
cmd="${@: -1}"
case "$cmd" in
  *parts_index*)  cat "$FX/index" ;;
  *backup_log.txt*) cat "$FX/log" ;;
  *lsblk*)        cat "$FX/mounts" ;;
  *"ls -1 /data/RAW"*) cat "$FX/srcdirs" ;;
  *fuser*)        cat "$FX/pid" ;;
  *lstart*)       echo "started Sat Sep 13 01:00:00 2026 script /home/x/code9.sh (mtime x) build=$(cat "$FX/build")" ;;
  *) exit 1 ;;
esac
S
cat > "$T/bin/notify.sh" <<'S'
#!/bin/bash
printf '%s\n' "$*" >> "$NOTIFY_CALLS"
S
chmod +x "$T/bin/ssh" "$T/bin/notify.sh"
export FX=$T NOTIFY_CALLS=$T/notify.calls; : > "$NOTIFY_CALLS"
echo 111 > "$T/pid"; echo OLD > "$T/build"
cp "$T/sheet.tsv" "$T/sheet7.tsv"     # 이미 등재된 시트라 새 행 0
runcron() { PATH="$T/bin:$PATH" BACKUP_SHEETLOG_NOTIFY="$T/bin/notify.sh" BACKUP_SHEETLOG_LOG="$T/cron.log" BACKUP_SHEETLOG_LOCK="$T/.cl" \
            BACKUP_SHEETLOG_STATE="$T/cron.state" bash "$DIR/scripts/backup-sheetlog.sh" "$@" > "$T/cron.out" 2>&1; }
#  ★ 도구가 구글에 닿지 않게 : --sheet-tsv 는 cron 스크립트가 안 넘기므로, 자격증명이 없는 환경으로 돌려 [FATAL] 을 유도한다
#    (등재 실패는 '등재 실패 rc' 로만 남고, 세션 판정은 그 전에 끝난다)
runcron; rc=$?
chk "rc=0" "$rc" "0"
grep -q 'session_pid=111' "$T/cron.state" && ok "첫 실행 : 세션 pid 111 기록" || bad "state 없음" "$(cat "$T/cron.state" 2>/dev/null)"
grep -q 'backup_session' "$NOTIFY_CALLS" && ok "첫 발견도 알린다 (build=OLD)" || bad "알림 없음"
grep -q 'build=OLD' "$NOTIFY_CALLS" && ok "  OLD 로 판정" || bad "판정 문구 없음" "$(cat "$NOTIFY_CALLS")"
: > "$NOTIFY_CALLS"; runcron
[ ! -s "$NOTIFY_CALLS" ] && ok "같은 세션이면 조용" || bad "같은 세션인데 알렸다"
echo 222 > "$T/pid"; echo NEW > "$T/build"; runcron
grep -q 'pid 111 -> 222' "$T/cron.log" && ok "세션 교체를 로그에" || bad "로그 없음" "$(tail -2 "$T/cron.log")"
grep -q 'build=NEW' "$NOTIFY_CALLS" && ok "새 세션 NEW 판정 알림" || bad "NEW 알림 없음" "$(cat "$NOTIFY_CALLS")"
: > "$T/pid"; : > "$NOTIFY_CALLS"; runcron
grep -qE '세션 끝남' "$NOTIFY_CALLS" "$T/cron.log" && ok "세션 종료 알림" || bad "종료 알림 없음"
grep -q 'session_pid=$' "$T/cron.state" && ok "state 에 빈 pid" || bad "state" "$(cat "$T/cron.state")"
#  ★ 그 세션 뒤에 code= 줄이 없으면 '종료 기록 없음' 이라고 말한다 (09-12 : 09-10 의 옛 code=3 줄을 인용해 정상 종료처럼 보였다)
grep -q '종료 기록 없음' "$NOTIFY_CALLS" && ok "★ 세션 뒤 code= 줄이 없으면 '종료 기록 없음'" || bad "옛 줄을 인용하거나 침묵" "$(cat "$NOTIFY_CALLS")"
grep -q 'gid=219954027' "$NOTIFY_CALLS" && ok "종료 알림에 기록 시트 링크" || bad "시트 링크 없음"
echo 333 > "$T/pid"; : > "$NOTIFY_CALLS"; runcron
grep -q 'session_start=' "$T/cron.state" && [ -n "$(sed -n 's/^session_start=//p' "$T/cron.state")" ] && ok "세션 시작 시각을 state 에" || bad "session_start 없음" "$(cat "$T/cron.state")"
grep -q 'gid=219954027' "$NOTIFY_CALLS" && ok "시작 알림에도 시트 링크" || bad "시트 링크 없음"
echo "[Sun Sep 13 02:00:00 AM KST 2026] 종료 code=3 : 하드를 다 썼습니다" >> "$T/log"      # 세션(01:00) 뒤의 종료 줄
: > "$T/pid"; : > "$NOTIFY_CALLS"; runcron
grep -q '종료 : \[Sun Sep 13 02:00:00' "$NOTIFY_CALLS" && ok "세션 뒤의 code= 줄은 그대로 인용" || bad "인용 안 함" "$(cat "$NOTIFY_CALLS")"
grep -q 'st -ge \\$mt' "$DIR/scripts/backup-sheetlog.sh" && ok "★ 판 판정은 세션 시작 시각 vs 파일 mtime (내용을 읽지 않는다)" || bad "내용으로 판정한다 (제자리 덮어쓰기에 오판)"
[ ! -e "$T/../backup-sheetlog.state" ] && ok "state 는 환경변수로 준 자리에만 쓴다" || bad "state 가 엉뚱한 곳에"

echo "[L] 라벨 자동 부여 (2026-09-16) : 새 시리얼은 parts_index 의 종류로 다음 번호를 받아 정본에 적히고 Disk Label 열에 실린다"
printf "$H\n" > "$T/sheetL.tsv"
printf 'Z4ZBZE7F\tRENE-RAW-004\tZ4ZBZE7F\tST2000DM006-2DM164\t\tU-7F\t1.8 TB\t2026-09-15 00:20:00\t2026-09-15 10:32:00\t\t\t\t\tseed\n' > "$T/disks.tsv"
cat > "$T/indexL" <<'IDX'
002600	U-3M	2026-09-16 16:20:00	40	3000000000	FADC_002600.root.00000	SADC_002600.root.00019	part	/backup_hdd	ST2000DM006-2DM164	Z4ZBZE3M	1953514584	raw
002600	U-7F	2026-09-15 00:30:00	40	3000000000	FADC_002600.root.00000	SADC_002600.root.00019	part	/backup_hdd	ST2000DM006-2DM164	Z4ZBZE7F	1953514584	raw
002601	U-5Y	2026-09-17 03:00:00	20	1000000000	PNG/a.png	PRD/Run002601_DLY_THR.log	full	/backup_hdd_2	ST2000DM006-2DM164	Z4ZBXG5Y	1953514584	prd
002602	U-OLD	2026-09-14 00:00:00	5	100	FADC_002602.root.00000	SADC_002602.root.00004
IDX
outL=$(python3 "$TOOL" --index "$T/indexL" --sheet-tsv "$T/sheetL.tsv" 2>&1)
printf '%s' "$outL" | grep -q 'Z4ZBZE3M -> RENE-RAW-005' && ok "미리보기 : 새 RAW 하드는 RAW-005 (정본의 RAW-004 다음)" || bad "RAW-005" "$(printf '%s' "$outL" | grep LABEL)"
printf '%s' "$outL" | grep -q 'Z4ZBXG5Y -> RENE-PRD-001' && ok "미리보기 : PRD 하드는 PRD-001 (정본에 PRD 가 없으므로)" || bad "PRD-001" "$(printf '%s' "$outL" | grep LABEL)"
chk "미리보기는 정본을 안 건드린다" "$(wc -l < "$T/disks.tsv")" "1"
python3 "$TOOL" --index "$T/indexL" --sheet-tsv "$T/sheetL.tsv" --commit >/dev/null 2>&1
chk "정본 3 줄 (seed + RAW-005 + PRD-001)" "$(grep -vc '^#' "$T/disks.tsv")" "3"
chk "정본 Z4ZBZE3M 라벨" "$(awk -F'\t' '$1=="Z4ZBZE3M"{print $2}' "$T/disks.tsv")" "RENE-RAW-005"
chk "시트 행의 Disk Label (Z4ZBZE7F = 정본 그대로)" "$(awk -F'\t' '$17=="Z4ZBZE7F"{print $13}' "$T/sheetL.tsv" | sort -u)" "RENE-RAW-004"
chk "시트 행의 Disk Label (Z4ZBXG5Y)" "$(awk -F'\t' '$17=="Z4ZBXG5Y"{print $13}' "$T/sheetL.tsv")" "RENE-PRD-001"
chk "UUID 만 아는 옛 기록에는 새 번호를 주지 않는다" "$(awk -F'\t' '$15=="U-OLD"{print "["$13"]"}' "$T/sheetL.tsv")" "[]"
[ -s "$T/disks.md" ] && grep -q 'RENE-RAW-005' "$T/disks.md" && ok "BACKUP-DISKS.md 재생성" || bad "md"
python3 "$TOOL" --index "$T/indexL" --sheet-tsv "$T/sheetL.tsv" --commit >/dev/null 2>&1
chk "두 번 돌려도 정본 그대로 (번호 불변)" "$(grep -vc '^#' "$T/disks.tsv")" "3"
echo "[M] --fill-labels : 이미 있는 행의 빈 Disk Label 을 정본으로 채운다 (다른 칸은 그대로)"
printf "$H\n" > "$T/sheetM.tsv"
printf '1\t2026-09-15\t00:30:00\t002600\tpart·RAW\t40\t3.0\t\tFADC_002600.root.00000\tSADC_002600.root.00019\t\t\t\t/backup_hdd\tU-7F\tST2000DM006-2DM164\tZ4ZBZE7F\t1.8 TB\t\tcount+bytes\tmoved files only\t\tcode9\tLAB-A\tauto\n' >> "$T/sheetM.tsv"
printf '2\t2026-09-15\t00:40:00\t002600\tpart·RAW\t40\t3.0\t\tFADC_002600.root.00000\tSADC_002600.root.00019\t\t\t\t/backup_hdd\tU-ZZ\tST2000DM006-2DM164\tZZZZZZZZ\t1.8 TB\t\tcount+bytes\tmoved files only\t\tcode9\t\tauto\n' >> "$T/sheetM.tsv"
outM=$(python3 "$TOOL" --index "$T/indexL" --sheet-tsv "$T/sheetM.tsv" --fill-labels --commit 2>&1)
chk "1 행 라벨 채움" "$(col "$T/sheetM.tsv" 2 13)" "RENE-RAW-004"
chk "정본에 없는 시리얼은 비워 둔다" "[$(col "$T/sheetM.tsv" 3 13)]" "[]"
chk "다른 칸(Storage Location)은 그대로" "$(col "$T/sheetM.tsv" 2 24)" "LAB-A"
printf '%s' "$outM" | grep -q 'FILL\] 빈 Disk Label 1 칸' && ok "[FILL] 줄" || bad "[FILL]" "$(printf '%s' "$outM" | grep FILL)"
echo; echo "=========================================================="; printf "  통과 %d · 실패 %d\n" "$PASS" "$FAIL"; echo "=========================================================="; [ "$FAIL" -eq 0 ]
