#!/bin/bash
# =====================================================================
#  storage-backup.sh 의 '하드를 순서대로 쓰는' 상태 기계를 시험한다.
#
#  ★ 실제 하드도, 실제 자료도, 실제 메일도 건드리지 않는다.
#    임시 디렉터리에 가짜 런을 만들고, BACKUP_TEST_HOOK 으로 용량·마운트
#    판정만 갈아끼운다. rsync 는 진짜로 돌고 파일도 진짜로 옮겨진다 —
#    그래야 '보내지도 않은 파일을 지우지 않는가' 를 시험할 수 있다.
#
#  돌리는 법 :  tests/storage-backup.test.sh
# =====================================================================
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../scripts/storage-backup.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "기대 '$3' / 실제 '$2'"; fi; }

# ---------------------------------------------------------------------
#  가짜 환경 하나를 차린다.
#     $1 = 런 개수   $2 = 런당 파일 개수   $3.. = 하드 용량[KB] (개수만큼 하드가 생긴다)
# ---------------------------------------------------------------------
setup() {
	local nrun=$1 nfile=$2; shift 2
	T=$(mktemp -d); SRC="$T/RAW"; QUEUE="$T/MAILQ"
	mkdir -p "$SRC" "$QUEUE"
	local r f
	for r in $(seq 1 "$nrun"); do
		local d; d=$(printf '%06d' "$r"); mkdir -p "$SRC/$d/PRD"
		for f in $(seq 1 "$nfile"); do
			#  100 KB 짜리 가짜 서브런. 이름은 실제 규칙을 따른다
			dd if=/dev/zero of="$SRC/$d/FADC_$d.root.$(printf '%05d' "$f")" \
			   bs=1024 count=100 status=none
			dd if=/dev/zero of="$SRC/$d/PRD/PRD_$d.$(printf '%05d' "$f").root" \
			   bs=1024 count=20 status=none
		done
	done
	#  ★ 갓 만든 파일은 mtime 이 지금이라 '사용 중' 으로 걸린다.
	#    시험이 원하는 것은 조용한 런이므로 mtime 을 하루 전으로 돌린다.
	find "$SRC" -exec touch -d '1 day ago' {} + 2>/dev/null

	DISKS=""; local i=0 cap
	for cap in "$@"; do
		i=$((i+1)); local m="$T/hdd$i"
		mkdir -p "$m"; echo "$cap" > "$T/cap.hdd$i"; : > "$T/mounted.hdd$i"
		DISKS="${DISKS:+$DISKS,}$m"
	done

	#  용량·마운트 판정만 갈아끼운다. 나머지 코드는 그대로 돈다.
	HOOK="$T/hook.sh"
	cat > "$HOOK" <<HOOKEOF
disk_is_mounted() { [ -f "$T/mounted.\$(basename "\$1")" ]; }
disk_cap_kb()     { cat "$T/cap.\$(basename "\$1")" 2>/dev/null || echo 0; }
disk_used_kb()    { du -sk "\$1" 2>/dev/null | awk '{print \$1}'; }
disk_avail_kb()   { local c u; c=\$(disk_cap_kb "\$1"); u=\$(disk_used_kb "\$1")
                    echo \$(( c - u < 0 ? 0 : c - u )); }
HOOKEOF
}

teardown() { [ -n "${T:-}" ] && rm -rf "$T"; }

run_sut() {              # 나머지 인자는 그대로 넘어간다
	BACKUP_SOURCE="$SRC" \
	BACKUP_MOUNTS="$DISKS" \
	BACKUP_TEST_HOOK="$HOOK" \
	BACKUP_LOG="$T/backup_log.txt" \
	BACKUP_SIZE_CACHE="$T/size.cache" \
	BACKUP_PARTS_INDEX="$T/parts_index.txt" \
	BACKUP_LOCK="$T/.lock" \
	BACKUP_SKIP_LIST="$T/skip.txt" \
	BACKUP_MAILQ="$QUEUE" \
	BACKUP_SAFETY_MARGIN_KB=64 \
	BACKUP_MIN_USEFUL_KB=32 \
	BACKUP_BWLIMIT= \
	bash "$SUT" "$@" > "$T/out.txt" 2>&1
	RC=$?
}

#  하드에 담긴 파일들을  "<런>/<상대경로> <바이트>"  로
disk_manifest() { local m; for m in $(echo "$DISKS" | tr ',' ' '); do
	[ -d "$m/RENE_data_backup" ] || continue
	( cd "$m/RENE_data_backup" && find . -type f ! -name '.part_manifest.txt' -printf '%P\t%s\n' )
	done | sort; }
src_manifest()  { ( cd "$SRC" && find . -type f -printf '%P\t%s\n' ) | sort; }
n_src_files()   { find "$SRC" -type f 2>/dev/null | wc -l; }
mailq_subjects(){ grep -h '^subject:' "$QUEUE"/*.mail 2>/dev/null | sed 's/^subject: //'; }
mailq_bodies()  { cat "$QUEUE"/*.mail 2>/dev/null; }

echo "=========================================================="
echo "  storage-backup.sh 상태 기계 시험"
echo "=========================================================="

# ---------------------------------------------------------------------
echo ""; echo "[1] 하드1 이 차면 하드2 로 이어져 전부 옮겨진다"
setup 6 4 900 100000
BEFORE=$(src_manifest)
run_sut
chk "종료코드 0" "$RC" "0"
chk "원본이 비었다" "$(n_src_files)" "0"
AFTER=$(disk_manifest)
if [ "$BEFORE" = "$AFTER" ]; then ok "옮겨진 파일이 원본과 이름·크기까지 완전히 같다"
else bad "파일이 어긋났다" "$(diff <(echo "$BEFORE") <(echo "$AFTER") | head -5 | tr '\n' ' ')"; fi
DUP=$(disk_manifest | cut -f1 | sort | uniq -d | wc -l)
chk "두 하드에 같은 파일이 겹쳐 담기지 않았다" "$DUP" "0"
D1=$(find "$T/hdd1/RENE_data_backup" -type f ! -name '.part_manifest.txt' 2>/dev/null | wc -l)
D2=$(find "$T/hdd2/RENE_data_backup" -type f ! -name '.part_manifest.txt' 2>/dev/null | wc -l)
if [ "$D1" -gt 0 ] && [ "$D2" -gt 0 ]; then ok "두 하드가 모두 쓰였다 (하드1 $D1 개 · 하드2 $D2 개)"
else bad "하드가 하나만 쓰였다" "하드1 $D1 개 · 하드2 $D2 개"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[2] 첫 하드에 다 들어가면 둘째 하드는 건드리지도 않는다"
setup 3 3 100000 100000
run_sut
chk "종료코드 0" "$RC" "0"
chk "원본이 비었다" "$(n_src_files)" "0"
chk "하드2 는 비어 있다" "$(find "$T/hdd2" -type f 2>/dev/null | wc -l)" "0"
if grep -q '옮길 것이 더 남아 있지 않습니다' "$T/out.txt"; then ok "완료 메시지"
else bad "완료 메시지가 없다"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[3] 다음 하드가 마운트되어 있지 않다 -> 오류 + 메일 + exit 1"
setup 6 4 900 100000
rm -f "$T/mounted.hdd2"          # 하드2 를 '뽑는다'
run_sut
chk "종료코드 1" "$RC" "1"
if grep -q '마운트되어 있지 않습니다' "$T/out.txt"; then ok "화면에 사유를 남겼다"
else bad "화면 메시지가 없다"; fi
if mailq_subjects | grep -q '마운트되어 있지 않습니다'; then ok "메일 제목에 사유가 있다"
else bad "메일이 없다" "$(mailq_subjects | tr '\n' ' ')"; fi
if mailq_bodies | grep -q 'ls /dev/sd'; then ok "메일 본문에 확인 명령이 있다"
else bad "본문에 확인 명령이 없다"; fi
if [ "$(n_src_files)" -gt 0 ]; then ok "옮기지 못한 원본은 그대로 남아 있다"
else bad "원본이 사라졌다"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[4] 다음 하드에 여유 공간이 없다 -> 오류 + 메일 + exit 1"
setup 6 4 900 80           # 하드2 는 처음부터 가득 : 여유 76 - 마진 64 = 12 < 최소 32
run_sut
chk "종료코드 1" "$RC" "1"
if grep -q '여유 공간이 없습니다' "$T/out.txt"; then ok "화면에 사유를 남겼다"
else bad "화면 메시지가 없다"; fi
if mailq_subjects | grep -q '여유 공간이 없습니다'; then ok "메일 제목에 사유가 있다"
else bad "메일이 없다" "$(mailq_subjects | tr '\n' ' ')"; fi
if [ "$(n_src_files)" -gt 0 ]; then ok "옮기지 못한 원본은 그대로 남아 있다"
else bad "원본이 사라졌다"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[5] 하드를 다 썼는데 아직 남았다 -> exit 3 + 교체 안내"
setup 8 4 900 900
run_sut
chk "종료코드 3" "$RC" "3"
if grep -q '하드를 새 것으로 바꾸고' "$T/out.txt"; then ok "교체 안내를 남겼다"
else bad "교체 안내가 없다"; fi
if mailq_subjects | grep -q '교체가 필요합니다'; then ok "메일 제목에 교체 안내"
else bad "메일이 없다" "$(mailq_subjects | tr '\n' ' ')"; fi
if [ "$(n_src_files)" -gt 0 ]; then ok "남은 원본은 그대로 있다"
else bad "원본이 사라졌다"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[6] ★ 회차 사이에 계획 파일이 새지 않는다 (보내지 않은 것을 지우지 않는다)"
#  하드1 이 아주 작아 여러 런이 하드2·3 으로 넘어간다. 한 파일이라도 새면
#  '보내지 않았는데 지워진' 파일이 생겨 아래 대조가 깨진다.
setup 10 5 800 800 100000
BEFORE=$(src_manifest)
run_sut
chk "종료코드 0" "$RC" "0"
chk "원본이 비었다" "$(n_src_files)" "0"
AFTER=$(disk_manifest)
if [ "$BEFORE" = "$AFTER" ]; then ok "세 하드를 합치면 원본과 한 바이트도 다르지 않다"
else bad "파일이 사라지거나 어긋났다" "$(diff <(echo "$BEFORE") <(echo "$AFTER") | head -5 | tr '\n' ' ')"; fi
chk "중복 없음" "$(disk_manifest | cut -f1 | sort | uniq -d | wc -l)" "0"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[7] 전송이 연속 실패하면 하드를 의심하고 멈춘다 (다음 하드로 넘어가지 않는다)"
setup 6 3 100000 100000
mkdir -p "$T/fakebin"
printf '#!/bin/bash\nexit 12\n' > "$T/fakebin/rsync"; chmod +x "$T/fakebin/rsync"
PATH="$T/fakebin:$PATH" run_sut
chk "종료코드 1" "$RC" "1"
if grep -q '연속 3회 실패' "$T/out.txt"; then ok "연속 실패로 중단했다"
else bad "중단 메시지가 없다"; fi
chk "원본을 하나도 지우지 않았다" "$(n_src_files)" "36"
chk "하드2 로 넘어가지 않았다" "$(find "$T/hdd2" -type f 2>/dev/null | wc -l)" "0"
if mailq_bodies | grep -q 'device offline'; then ok "메일이 dmesg 확인법을 안내한다"
else bad "메일 안내가 없다"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[8] 남은 것이 '사용 중' 런뿐이면 정상 종료한다 (하드를 넘기지 않는다)"
setup 3 3 100000 100000
find "$SRC" -type f -exec touch {} +      # 방금 바뀐 것으로 만든다 = 사용 중
run_sut
chk "종료코드 0" "$RC" "0"
chk "원본을 건드리지 않았다" "$(n_src_files)" "18"
chk "하드1 이 비어 있다" "$(find "$T/hdd1" -type f 2>/dev/null | wc -l)" "0"
if grep -q '쓰는 중이라' "$T/out.txt"; then ok "사용 중이라 건드리지 않았다고 알린다"
else bad "사용 중 안내가 없다"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[9] --dry-run 은 아무것도 옮기거나 지우지 않는다"
setup 4 3 900 100000
run_sut --dry-run
chk "종료코드 0" "$RC" "0"
chk "원본 그대로" "$(n_src_files)" "24"
chk "하드가 비어 있다" "$(find "$T/hdd1" "$T/hdd2" -type f 2>/dev/null | wc -l)" "0"
chk "메일도 큐에 넣지 않는다" "$(ls "$QUEUE"/*.mail 2>/dev/null | wc -l)" "0"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[10] 첫 하드가 이미 가득 차 있으면 오류가 아니라 다음 하드로 넘어간다"
setup 4 3 80 100000        # 하드1 은 처음부터 못 쓴다 (여유 76 - 마진 64 = 12 < 32)
run_sut
chk "종료코드 0" "$RC" "0"
chk "원본이 비었다" "$(n_src_files)" "0"
if grep -q '이미 가득 찼습니다' "$T/out.txt"; then ok "오류가 아니라 안내로 넘어갔다"
else bad "안내가 없다"; fi
chk "하드2 에 담겼다" "$(find "$T/hdd2/RENE_data_backup" -type f 2>/dev/null | wc -l)" "24"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[11] 첫 하드가 마운트되어 있지 않으면 시작하지 못한다"
setup 3 3 100000 100000
rm -f "$T/mounted.hdd1"
run_sut
chk "종료코드 1" "$RC" "1"
if grep -q '첫 하드' "$T/out.txt" || grep -q '마운트되어 있지 않습니다' "$T/out.txt"; then ok "사유를 남겼다"
else bad "메시지가 없다"; fi
chk "원본 그대로" "$(n_src_files)" "18"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[12] 하드가 가득 차 넘어갈 때 '뽑아 가도 된다' 는 메일이 간다"
setup 6 4 900 100000
run_sut
if mailq_subjects | grep -q '가득 참'; then ok "교체 시점 메일이 있다"
else bad "교체 시점 메일이 없다" "$(mailq_subjects | tr '\n' ' ')"; fi
if mailq_bodies | grep -q 'UUID'; then ok "본문에 하드 신원(UUID 항목)이 들어간다"
else bad "본문에 하드 정보가 없다"; fi
if [ "$(mailq_subjects | wc -l)" -ge 2 ]; then ok "하드 교체 메일 + 종합 메일 둘 다 왔다 ($(mailq_subjects | wc -l) 통)"
else bad "메일이 한 통뿐이다"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[13] --no-mail 이면 큐에 넣지 않는다 / 큐를 못 써도 백업은 계속한다"
setup 3 3 100000 100000
run_sut --no-mail
chk "종료코드 0" "$RC" "0"
chk "메일 없음" "$(ls "$QUEUE"/*.mail 2>/dev/null | wc -l)" "0"
chk "백업은 정상" "$(n_src_files)" "0"
teardown

setup 3 3 100000 100000
rm -rf "$QUEUE"; : > "$QUEUE"          # 큐 자리를 '파일' 로 막아 mkdir 을 실패시킨다
run_sut
chk "큐를 못 써도 종료코드 0" "$RC" "0"
chk "큐를 못 써도 백업은 끝났다" "$(n_src_files)" "0"
if grep -q '메일 큐에 쓸 수 없습니다' "$T/out.txt"; then ok "못 썼다는 사실을 알린다"
else bad "조용히 넘어갔다"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[14] cron 환경(env -i)에서도 돈다"
setup 3 3 100000 100000
env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$T" \
	BACKUP_SOURCE="$SRC" BACKUP_MOUNTS="$DISKS" BACKUP_TEST_HOOK="$HOOK" \
	BACKUP_LOG="$T/backup_log.txt" BACKUP_SIZE_CACHE="$T/size.cache" \
	BACKUP_PARTS_INDEX="$T/parts.txt" BACKUP_LOCK="$T/.lock" \
	BACKUP_SKIP_LIST="$T/skip.txt" BACKUP_MAILQ="$QUEUE" \
	BACKUP_SAFETY_MARGIN_KB=64 BACKUP_MIN_USEFUL_KB=32 BACKUP_BWLIMIT= \
	bash "$SUT" > "$T/out.txt" 2>&1
chk "종료코드 0" "$?" "0"
chk "원본이 비었다" "$(n_src_files)" "0"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[15] ★ 런 하나가 어느 하드보다도 크다 — 하드 셋에 걸쳐 전부 담긴다"
#  실제로 겪는 모습이다 : run 002443 은 6.71 TB 인데 하드는 1.8 TB 다.
#  런 하나(파일 40개)를 하드 셋에 나눠 담아야 끝난다.
setup 1 20 900 900 900
BEFORE=$(src_manifest)
NF_SRC=$(n_src_files)
run_sut
chk "종료코드 0" "$RC" "0"
chk "원본이 비었다" "$(n_src_files)" "0"
AFTER=$(disk_manifest)
if [ "$BEFORE" = "$AFTER" ]; then ok "한 런이 하드 셋에 흩어져도 원본과 완전히 같다 ($NF_SRC 개)"
else bad "파일이 사라지거나 어긋났다" "$(diff <(echo "$BEFORE") <(echo "$AFTER") | head -5 | tr '\n' ' ')"; fi
chk "같은 파일이 두 하드에 겹치지 않았다" "$(disk_manifest | cut -f1 | sort | uniq -d | wc -l)" "0"
NDISK=0
for d in 1 2 3; do
	[ "$(find "$T/hdd$d/RENE_data_backup" -type f ! -name '.part_manifest.txt' 2>/dev/null | wc -l)" -gt 0 ] \
		&& NDISK=$((NDISK+1))
done
chk "하드 셋이 모두 쓰였다" "$NDISK" "3"
NMAN=$(find "$T"/hdd*/RENE_data_backup -name '.part_manifest.txt' 2>/dev/null | wc -l)
if [ "$NMAN" -ge 2 ]; then ok "어느 조각이 어느 하드에 있는지 매니페스트가 남았다 ($NMAN 개)"
else bad "매니페스트가 없다" "$NMAN 개"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[16] ★ 마운트는 됐는데 쓸 수 없다 -> 계획을 세우기 전에 멈춘다"
#  2026-09-03 에 실제로 겪은 것이다. 갓 포맷한 하드의 루트가 root:root 755 라
#  RENE_data_backup 을 만들 수 없었는데, 그 mkdir 오류를 삼키고 있어서
#  1,723 개 계획을 다 세운 뒤 첫 rsync 가 엉뚱한 오류로 죽었다.
setup 3 3 100000 100000
chmod 555 "$T/hdd1"
run_sut
chmod 755 "$T/hdd1"
chk "종료코드 1" "$RC" "1"
if grep -q '쓸 수 없습니다' "$T/out.txt"; then ok "쓸 수 없다고 분명히 말한다"
else bad "사유가 없다" "$(tail -3 "$T/out.txt")"; fi
#  ★ 로케일에 따라 'Permission denied' 또는 '허가 거부' 로 나온다.
#    중요한 것은 OS 가 낸 사유를 삼키지 않고 그대로 넘기는 것이다.
if grep -qE 'Permission denied|허가 거부' "$T/out.txt"; then ok "★ 진짜 사유(권한 거부)를 그대로 보여준다"
else bad "사유를 삼켰다" "$(tail -3 "$T/out.txt")"; fi
if grep -q 'chown' "$T/out.txt" || mailq_bodies | grep -q 'chown'; then ok "조치 명령을 알려준다"
else bad "조치 안내가 없다"; fi
if ! grep -q '담을지 계산 중' "$T/out.txt"; then ok "계획을 세우기 전에 멈췄다 (헛수고하지 않는다)"
else bad "계획을 다 세운 뒤에 죽었다"; fi
chk "원본 그대로" "$(n_src_files)" "18"
chk "메일이 큐에 들어갔다 (실제 실행이므로)" "$(ls "$QUEUE"/*.mail 2>/dev/null | wc -l)" "1"
teardown

#  ★ 같은 오류라도 --dry-run 이면 메일이 나가면 안 된다.
#    미리보기가 바깥으로 나가면 '아무것도 바꾸지 않는다'는 약속이 깨진다.
setup 3 3 100000 100000
chmod 555 "$T/hdd1"
run_sut --dry-run
chmod 755 "$T/hdd1"
chk "--dry-run 도 오류는 낸다 (exit 1)" "$RC" "1"
chk "★ 그래도 메일은 큐에 넣지 않는다" "$(ls "$QUEUE"/*.mail 2>/dev/null | wc -l)" "0"
if grep -q '메일을 보내지 않습니다' "$T/out.txt"; then ok "보내지 않았다고 화면에 밝힌다"
else bad "조용히 넘어갔다"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[17] ★ 전송이 실패한 것을 '쪼갤 수 없다'로 오진하지 않는다"
setup 2 3 100000 100000
mkdir -p "$T/fakebin"
printf '#!/bin/bash\nexit 23\n' > "$T/fakebin/rsync"; chmod +x "$T/fakebin/rsync"
PATH="$T/fakebin:$PATH" run_sut
chk "종료코드 1 (3 이 아니다)" "$RC" "1"
if grep -q '전송이 실패해' "$T/out.txt"; then ok "전송 실패라고 말한다"
else bad "오진했다" "$(grep -E '⚠️|❌' "$T/out.txt" | tail -2)"; fi
if ! grep -q 'split' "$T/out.txt"; then ok "★ --split 을 엉뚱하게 지목하지 않는다"
else bad "여전히 --split 을 지목한다" "$(grep split "$T/out.txt" | head -2)"; fi
if mailq_bodies | grep -q 'grep FAIL'; then ok "메일이 사유를 볼 곳을 알려준다"
else bad "메일 안내가 없다"; fi
chk "원본을 하나도 지우지 않았다" "$(n_src_files)" "12"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[18] 시작할 때 하드 상태를 먼저 보여준다"
setup 2 2 100000 100000
run_sut --dry-run
if grep -q '쓸 하드' "$T/out.txt"; then ok "하드 목록을 낸다"
else bad "목록이 없다"; fi
if grep -q '쓰기 가능' "$T/out.txt"; then ok "쓰기 가능 여부를 낸다"
else bad "쓰기 여부가 없다" "$(sed -n '1,20p' "$T/out.txt")"; fi
teardown

#  ★ 마운트 루트는 못 쓰는데 목적지 폴더만 쓸 수 있는 경우.
#    2026-09-03 에 실제로 이렇게 조치했다 — 루트는 root 소유로 두고
#    RENE_data_backup 만 만들어 소유권을 넘긴다. 루트만 보면 멀쩡한 하드를
#    '쓰기 권한 없음' 으로 잘못 낸다.
setup 2 2 100000 100000
mkdir -p "$T/hdd1/RENE_data_backup" "$T/hdd2/RENE_data_backup"
chmod 555 "$T/hdd1" "$T/hdd2"          # 루트는 못 쓰고, 그 안 폴더는 쓸 수 있다
run_sut
RC1=$RC
chmod 755 "$T/hdd1" "$T/hdd2"
chk "정상 종료 (루트를 못 써도 목적지를 쓸 수 있으면 된다)" "$RC1" "0"
if ! grep -q '쓰기 권한 없음' "$T/out.txt"; then ok "★ 멀쩡한 하드를 경고하지 않는다"
else bad "틀린 경고를 낸다" "$(grep -A1 '쓸 하드' "$T/out.txt" | head -3)"; fi
chk "실제로 옮겼다" "$(n_src_files)" "0"
teardown

echo ""
echo "=========================================================="
printf "  통과 %d · 실패 %d\n" "$PASS" "$FAIL"
echo "=========================================================="
[ "$FAIL" -eq 0 ]
