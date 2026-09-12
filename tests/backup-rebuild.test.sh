#!/usr/bin/env bash
# rebuild_backup_sheet.py — 스캔 + 서버 기록 + 옛 시트 -> (런, 시각) 정렬 · 라벨 · 소실 표시 · 손 열 보존. 구글·ssh 무접촉.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd); TOOL=$DIR/tools/sheetlog/rebuild_backup_sheet.py
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✅ $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  ❌ $1"; [ $# -gt 1 ] && echo "       $2"; }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "기대 '$3' / 실제 '$2'"; fi; }
col(){ awk -F'\t' -v r="$2" -v c="$3" 'NR==r{print $c}' "$1"; }
rowof(){ awk -F'\t' -v run="$2" -v u="$3" 'NR>1 && $4==run && substr($15,1,4)==u {print NR; exit}' "$1"; }   # run + uuid 앞 4자 -> 행 번호

H=$(python3 -c "import sys; sys.path.insert(0,'$DIR/tools/sheetlog'); from append_backup_rows import HEADER; print('\t'.join(HEADER))")
# 옛 시트 : 손으로 쓴 3행 (하나는 어느 기록에도 없는 옛 하드 U-OLD, 하나는 U-A 의 002443 에 KHU·메모, 하나는 U-D 의 full 에 개수)
printf '%s\n' "$H" > "$T/sheet.tsv"
printf '1\t2026-09-01\t06:27:19\t002442\tfull\t\t\t\t\t\t\t\t\t/backup_hdd\tU-OLD\t\t\t\t\t\t\tyes (RAW 17098)\tcode7\tcabinet 1\tDisk detached. serial unknown\n' >> "$T/sheet.tsv"
printf '2\t2026-09-03\t12:12:21\t002443\tpart\t8696\t1865.7\t\t\t\t\t\t\t/backup_hdd\tU-A\tST2000DM008\tSN-C\t1.8 TB\t\tcount+bytes\tmoved\tyes (RAW 21286)\tcode9\t\tDisk reformatted 2026-09-04\n' >> "$T/sheet.tsv"
printf '3\t2026-09-05\t09:32:26\t002443\tpart\t15700\t1232.7\t\t\t\t\t\t\t/backup_hdd_2\tU-D\tST2000DM008\tSN-D\t1.8 TB\t\tcount+bytes\tY\tyes\tcode9\t\tDisk 2 of 2 for run 002443\n' >> "$T/sheet.tsv"
cp "$T/sheet.tsv" "$T/sheet.orig"
# 서버 기록
cat > "$T/index" <<'EOF2'
002443	U-A	2026-09-03 12:11:13	8696	1865661898304	FADC_002443.root.00000	PRD/x.log
002443	U-C	2026-09-04 18:01:53	12683	461779137936	FADC_002443.root.10536	SADC_002443.root.12000
002456	U-K	2026-09-12 04:26:28	1681	48492477653	FADC_002456.root.00000	SADC_002456.root.01528	part	/backup_hdd	ST2000DM008-2FR102	ZK206014	1953514584
EOF2
cat > "$T/log" <<'EOF2'
[Thu Sep  3 12:51:16 AM KST 2026] === 하드 /backup_hdd /dev/sdb1 UUID=U-A 회차 시작 ===
[Sat Sep  5 02:29:17 AM KST 2026] === 하드 /backup_hdd_2 /dev/sdc1 UUID=U-D 회차 시작 ===
[Sat Sep  5 09:32:26 AM KST 2026] 002443 완료 및 서버에서 제거됨.
[Fri Sep 11 11:39:45 PM KST 2026] === 하드 /backup_hdd /dev/sdc1 UUID=U-K 회차 시작 ===
[Sat Sep 12 09:50:03 AM KST 2026] 002457 완료 및 서버에서 제거됨.
EOF2
printf 'U-A\tU-C\t2026-09-04 00:12\t002443 part 1 lost by reformat\n' > "$T/aliases"
printf 'U-C\tSN-C\tST2000DM008-2FR102\t\ttest\nU-D\tSN-D\tST2000DM008-2FR102\t\ttest\n' > "$T/known"
# 스캔 : 옛 하드 U-OLD1 (기록 없음 : 자료 런 2 + 로그만 있는 런 1) · U-K (기록 있는 002456 + 기록 없는 full 002499)
mkdir -p "$T/inv"
cat > "$T/inv/SN-OLD1_U-OLD1.tsv" <<'EOF2'
#disk	/backup_hdd	/dev/sdb1	U-OLD1	ST2000DM006-2DM164	SN-OLD1	0x5000	1967846088704	1495838314496	2026-04-15 19:03:39	2026-09-12 23:31:12
#cols	run	files	bytes	sub_lo	sub_hi	first_file	last_file	copied_from	copied_to	manifest_lines	n_fadc	n_sadc	n_prd	n_merged	n_png	n_other
000938	1	1102					PRD/Run000938_DLY_THR.log	2026-04-17 17:31:24	2026-04-17 17:31:24	0	0	0	1	0	0	0
001077	6463	169720221370	02169	05399	FADC_001077.root.02169	SADC_001077.root.05399	2026-04-17 20:25:00	2026-04-18 05:27:45	0	3231	3231	1	0	0	0
001093	3088	690694977603	00000	01543	FADC_001093.root.00000	SADC_001093.root.01543	2026-04-18 06:00:00	2026-04-19 10:00:00	0	1544	1544	0	0	0	0
EOF2
cat > "$T/inv/ZK206014_U-K.tsv" <<'EOF2'
#disk	/backup_hdd	/dev/sdc1	U-K	ST2000DM008-2FR102	ZK206014	0x5000c500c8b28f6e	1967846088704	500000000000	2026-09-11 20:00:00	2026-09-12 23:40:00
#cols	run	files	bytes	sub_lo	sub_hi	first_file	last_file	copied_from	copied_to	manifest_lines	n_fadc	n_sadc	n_prd	n_merged	n_png	n_other
002456	3196	538000000000	00000	02000	FADC_002456.root.00000	SADC_002456.root.02000	2026-09-12 04:10:00	2026-09-12 07:03:00	3198	1600	1596	0	0	0	0
002499	40	3000000000	00000	00019	FADC_002499.root.00000	SADC_002499.root.00019	2026-09-12 08:00:00	2026-09-12 08:30:00	0	20	20	0	0	0	0
EOF2
printf 'U-K\t/backup_hdd\n' > "$T/mounts"; printf '002456\n002500\n' > "$T/srcdirs"
run(){ python3 "$TOOL" --inventory "$T/inv" --index "$T/index" --log "$T/log" --mounts "$T/mounts" --source-dirs "$T/srcdirs" \
        --aliases "$T/aliases" --known-serials "$T/known" --disks-tsv "$T/disks.tsv" --disks-md "$T/disks.md" \
        --sheet-tsv "$T/sheet.tsv" --backup-dir "$T/bak" "$@"; }

echo "[1] 미리보기 : 시트 그대로, 결과는 --out-tsv 로"
out=$(run --out-tsv "$T/prev.tsv" 2>&1); rc=$?
chk "rc=0" "$rc" "0"
cmp -s "$T/sheet.tsv" "$T/sheet.orig" && ok "시트를 안 건드렸다" || bad "미리보기가 썼다"
[ ! -e "$T/disks.tsv" ] && ok "라벨 정본도 미리보기에선 안 쓴다" || bad "disks.tsv 가 생겼다"
P=$T/prev.tsv
# 행 : 000938(log-only) 001077 001093 002442(옮김) 002443×3(U-A wiped · U-C · U-D full) 002456(U-K) 002457(U-K log full) 002499(U-K scan) = 10
chk "행 수 10" "$(($(wc -l < "$P")-1))" "10"
chk "정렬 (런, 시각)" "$(awk -F'\t' 'NR>1{print $4}' "$P" | tr '\n' ' ')" "000938 001077 001093 002442 002443 002443 002443 002456 002457 002499 "
chk "No 가 1..10" "$(awk -F'\t' 'NR>1{print $1}' "$P" | tr '\n' ' ')" "1 2 3 4 5 6 7 8 9 10 "
chk "모든 행이 25 열" "$(awk -F'\t' 'NR>1{print NF}' "$P" | sort -u | tr '\n' ' ')" "25 "

echo "[2] 스캔에만 있는 옛 하드 : 시각은 복사 ctime, 로그만 있는 런은 log-only, 시작 서브런이 0 이 아니면 메모"
r=$(rowof "$P" 000938 U-OL)
chk "000938 Type=log-only" "$(col "$P" $r 5)" "log-only"
r=$(rowof "$P" 001077 U-OL)
chk "001077 날짜/시각 = copied_to" "$(col "$P" $r 2) $(col "$P" $r 3)" "2026-04-18 05:27:45"
chk "  서브런 범위 02169~05399" "$(col "$P" $r 8)" "02169~05399"
chk "  시리얼·모델 (스캔에서)" "$(col "$P" $r 17)/$(col "$P" $r 16)" "SN-OLD1/ST2000DM006-2DM164"
chk "  Status : U-OLD1 은 지금 안 붙어 있다 + 스캔 검증" "$(col "$P" $r 12)" "on disk (not attached) · verified by scan"
col "$P" $r 25 | grep -q 'starts at subrun 02169' && ok "  앞 서브런이 없다는 메모" || bad "메모 없음" "$(col "$P" $r 25)"
chk "  Source Deleted : 서버에 없다" "$(col "$P" $r 21)" "Y (not on server)"
chk "  Script = pre-code9" "$(col "$P" $r 23)" "pre-code9"

echo "[3] 라벨 : 처음 담은 날짜. 같은 날 둘이면 -A/-B, 한 장이면 접미사 없음"
chk "U-OLD1 -> RENE-BK-20260417 (그 하드의 첫 복사 시각 — log-only 행도 센다)" "$(col "$P" $(rowof "$P" 001077 U-OL) 13)" "RENE-BK-20260417"
chk "U-K (ZK206014) -> RENE-BK-20260912" "$(col "$P" $(rowof "$P" 002456 U-K) 13)" "RENE-BK-20260912"
# U-A(09-03, wiped -> U-C, SN-C) 와 U-D(09-05) 는 날짜가 다르다
chk "SN-C 라벨 = 20260903 (별칭 U-A 의 09-03 이 처음)" "$(col "$P" $(rowof "$P" 002443 U-C) 13)" "RENE-BK-20260903"
chk "  U-A 행도 같은 라벨 (같은 물리 하드)" "$(col "$P" $(rowof "$P" 002443 U-A) 13)" "RENE-BK-20260903"
chk "SN-D 라벨 = 20260905" "$(col "$P" $(rowof "$P" 002443 U-D) 13)" "RENE-BK-20260905"

echo "[4] 재포맷으로 소실된 기록 : WIPED 표시 + 별칭 메모 + 손 메모 보존"
r=$(rowof "$P" 002443 U-A)
chk "Status WIPED" "$(col "$P" $r 12)" "WIPED — disk reformatted 2026-09-04 00:12"
chk "Source Deleted" "$(col "$P" $r 21)" "Y (and backup wiped)"
col "$P" $r 25 | grep -q 'lost by reformat' && ok "별칭 메모" || bad "별칭 메모 없음"
col "$P" $r 25 | grep -q 'hand: Disk reformatted' && ok "손 메모 보존 (hand:)" || bad "손 메모 사라짐" "$(col "$P" $r 25)"
chk "  손으로 적은 KHU 열 보존" "$(col "$P" $r 22)" "yes (RAW 21286)"
chk "  시리얼은 별칭 대상(U-C) 의 것" "$(col "$P" $r 17)" "SN-C"

echo "[5] 로그에만 있는 full (U-D 002443) : 손 행의 개수·용량을 가져온다"
r=$(rowof "$P" 002443 U-D)
chk "Files/GB 손 행에서" "$(col "$P" $r 6)/$(col "$P" $r 7)" "15700/1232.7"
chk "  시리얼 known 에서" "$(col "$P" $r 17)" "SN-D"

echo "[6] 어느 갈래에도 없는 옛 행(U-OLD 002442) 은 그대로 옮긴다"
r=$(rowof "$P" 002442 U-OL)
[ -n "$r" ] && ok "행이 남아 있다" || bad "행이 사라졌다"
chk "  Storage Location 그대로" "$(col "$P" $r 24)" "cabinet 1"
col "$P" $r 25 | grep -q 'carried from previous sheet' && ok "  옮겼다는 표시" || bad "표시 없음"
chk "  라벨 (UUID 기준, 09-01)" "$(col "$P" $r 13)" "RENE-BK-20260901"

echo "[7] 기록 + 스캔이 둘 다 있는 하드 (U-K) : 기록 행에 스캔 대조를 덧붙인다"
r=$(rowof "$P" 002456 U-K)
chk "Status attached + scan" "$(col "$P" $r 12)" "on disk (attached) · verified by scan"
chk "Verified" "$(col "$P" $r 20)" "count+bytes + scan 2026-09-12"
col "$P" $r 25 | grep -q 'scan 2026-09-12: 3196 files' && ok "스캔 총량 메모" || bad "스캔 메모 없음" "$(col "$P" $r 25)"
r=$(rowof "$P" 002457 U-K)
col "$P" $r 25 | grep -q 'run NOT found on disk' && ok "★ 로그엔 있는데 하드에 없는 런은 경고" || bad "경고 없음" "$(col "$P" $r 25)"
r=$(rowof "$P" 002499 U-K)
chk "스캔에만 있는 런(002499) 도 실린다 : full, 서버에 없음" "$(col "$P" $r 5)/$(col "$P" $r 21)" "full/Y (not on server)"

echo "[8] --commit : 시트 교체 + 백업 + 라벨 정본 + 문서. 다시 돌리면 라벨이 그대로 (안정)"
run --commit >/dev/null 2>&1; rc=$?
chk "rc=0" "$rc" "0"
chk "시트 행 수 10" "$(($(wc -l < "$T/sheet.tsv")-1))" "10"
ls "$T/bak"/sheet-before-rebuild-*.tsv >/dev/null 2>&1 && ok "쓰기 전 백업" || bad "백업 없음"
chk "백업 = 옛 시트" "$(md5sum < "$T/bak"/sheet-before-rebuild-*.tsv | cut -c1-8)" "$(md5sum < "$T/sheet.orig" | cut -c1-8)"
grep -q $'^SN-OLD1\tRENE-BK-20260417' "$T/disks.tsv" && ok "라벨 정본 disks.tsv" || bad "disks.tsv" "$(cat "$T/disks.tsv")"
grep -q 'RENE-BK-20260903' "$T/disks.md" && ok "문서 BACKUP-DISKS.md" || bad "md 없음"
grep -q '시리얼 미확인' "$T/disks.tsv" && ok "시리얼 모르는 하드는 '미확인' 표시" || bad "표시 없음"
# 라벨 안정성 : 정본에서 U-OLD1 의 라벨을 손으로 바꾼 뒤 다시 돌려도 그 라벨이 유지된다
sed -i 's/^SN-OLD1\tRENE-BK-20260417/SN-OLD1\tRENE-BK-KEEP/' "$T/disks.tsv"
run --commit >/dev/null 2>&1
chk "정본의 라벨이 이긴다" "$(col "$T/sheet.tsv" $(rowof "$T/sheet.tsv" 001077 U-OL) 13)" "RENE-BK-KEEP"
chk "재실행해도 행 수 같다 (멱등)" "$(($(wc -l < "$T/sheet.tsv")-1))" "10"

echo "[9] 헤더가 다르면 아무것도 안 쓴다"
printf 'A\tB\tC\n1\t2\t3\n' > "$T/bad.tsv"
python3 "$TOOL" --inventory "$T/inv" --index "$T/index" --sheet-tsv "$T/bad.tsv" --disks-tsv "$T/d2.tsv" --disks-md "$T/d2.md" --backup-dir "$T/bak" --commit >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "rc≠0" || bad "헤더 검사 없음"
chk "안 썼다" "$(wc -l < "$T/bad.tsv")" "2"

echo "[10] 다시 붙이기(append_backup_rows.py) 가 재작성된 표 위에 그대로 붙는다 (마지막 시각 = 최대 시각)"
printf '002460\tU-K\t2026-09-13 01:00:00\t10\t1000000000\tFADC_002460.root.00000\tSADC_002460.root.00009\tpart\t/backup_hdd\tST2000DM008-2FR102\tZK206014\t1953514584\n' >> "$T/index"
out=$(python3 "$DIR/tools/sheetlog/append_backup_rows.py" --index "$T/index" --sheet-tsv "$T/sheet.tsv" --commit 2>&1)
printf '%s' "$out" | grep -q '새 행 1' && ok "새 행 1" || bad "append 결과" "$out"
chk "  No 11 로 이어진다" "$(tail -1 "$T/sheet.tsv" | cut -f1,4)" "$(printf '11\t002460')"

echo; echo "=========================================================="; printf "  통과 %d · 실패 %d\n" "$PASS" "$FAIL"; echo "=========================================================="; [ "$FAIL" -eq 0 ]
