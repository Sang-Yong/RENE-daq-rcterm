#!/bin/bash
# =====================================================================
#  한글판(code9) 과 영어판(code10) 이 '같은 일' 을 하는가.
#
#  ★ 코드를 눈으로 비교하지 않는다. 같은 입력을 양쪽에 주고 결과가 같은지 본다.
#    문구는 달라도 되지만, 종료코드 · 하드에 담긴 것 · 원본에 남은 것 ·
#    메일 통수 · 조각 기록은 한 글자도 달라선 안 된다.
#
#  실하드도 실데이터도 실메일도 건드리지 않는다.
#  돌리는 법 :  tests/parity.test.sh
# =====================================================================
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
KO="$HERE/../scripts/storage-backup.sh"
EN="$HERE/../scripts/storage-backup-en.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }

#  가짜 환경 하나를 만든다.  $1 = 뿌리, 나머지는 build_env 안에서 쓴다
build_env() {            # 뿌리  런수  런당파일수  Merged수  하드용량...
	local T=$1 nrun=$2 nfile=$3 nmg=$4; shift 4
	mkdir -p "$T/RAW" "$T/MAILQ"
	local r f d i
	for r in $(seq 1 "$nrun"); do
		d=$(printf '%06d' "$r"); mkdir -p "$T/RAW/$d/PRD"
		for f in $(seq 1 "$nfile"); do
			dd if=/dev/zero of="$T/RAW/$d/FADC_$d.root.$(printf '%05d' "$f")" bs=1024 count=100 status=none
			dd if=/dev/zero of="$T/RAW/$d/PRD/PRD_$d.$(printf '%05d' "$f").root" bs=1024 count=20 status=none
		done
		if [ "$nmg" -gt 0 ]; then mkdir -p "$T/RAW/$d/Merged"
			for i in $(seq 1 "$nmg"); do
				dd if=/dev/zero of="$T/RAW/$d/Merged/MERGED_$d.root.$(printf '%05d' "$i")" bs=1024 count=200 status=none
			done
		fi
	done
	find "$T/RAW" -exec touch -d '1 day ago' {} + 2>/dev/null
	local i=0 cap
	for cap in "$@"; do
		i=$((i+1)); mkdir -p "$T/hdd$i"; echo "$cap" > "$T/cap.hdd$i"; : > "$T/mounted.hdd$i"
	done
	cat > "$T/hook.sh" <<HK
disk_is_mounted() { [ -f "$T/mounted.\$(basename "\$1")" ]; }
disk_cap_kb()     { cat "$T/cap.\$(basename "\$1")" 2>/dev/null || echo 0; }
disk_used_kb()    { du -sk "\$1" 2>/dev/null | awk '{print \$1}'; }
disk_avail_kb()   { local c u; c=\$(disk_cap_kb "\$1"); u=\$(disk_used_kb "\$1"); echo \$(( c - u < 0 ? 0 : c - u )); }
HK
	{ echo "time=$(date +%s)"; echo "run=999999"; echo "phase=running"; } > "$T/hb"
}

run_one() {              # 스크립트  뿌리  하드목록  나머지인자...
	local sut=$1 T=$2 disks=$3; shift 3
	BACKUP_SOURCE="$T/RAW" BACKUP_MOUNTS="$disks" BACKUP_TEST_HOOK="$T/hook.sh" \
	BACKUP_LOG="$T/log.txt" BACKUP_SIZE_CACHE="$T/sz" BACKUP_PARTS_INDEX="$T/parts" \
	BACKUP_LOCK="$T/.lk" BACKUP_SKIP_LIST="$T/skip" BACKUP_MAILQ="$T/MAILQ" \
	BACKUP_SAFETY_MARGIN_KB=64 BACKUP_MIN_USEFUL_KB=32 BACKUP_BWLIMIT= \
	bash "$sut" "$@" > "$T/out.txt" 2>&1
	echo $?
}

#  결과를 언어와 무관한 형태로 뽑는다
snapshot() {             # 뿌리
	local T=$1 d
	echo "### 하드에 담긴 것"
	for d in "$T"/hdd*; do
		[ -d "$d/RENE_data_backup" ] || continue
		echo "--- $(basename "$d")"
		( cd "$d/RENE_data_backup" && find . -type f ! -name '.part_manifest.txt' -printf '%P\t%s\n' | sort )
	done
	echo "### 원본에 남은 것"
	( cd "$T/RAW" && find . -type f -printf '%P\t%s\n' | sort )
	echo "### 메일 통수"
	ls -1 "$T/MAILQ"/*.mail 2>/dev/null | wc -l
	echo "### 조각 기록 (시각·UUID 제외)"
	cut -f1,4,5,6,7 "$T/parts" 2>/dev/null | sort
}

#  한 시나리오를 양쪽에 돌리고 비교한다
compare() {              # 이름  런수 파일수 Merged수  '하드용량들'  '추가인자'
	local name=$1 nrun=$2 nfile=$3 nmg=$4 caps=$5 extra=${6:-}
	local A B da db rca rcb
	A=$(mktemp -d); B=$(mktemp -d)
	build_env "$A" "$nrun" "$nfile" "$nmg" $caps
	build_env "$B" "$nrun" "$nfile" "$nmg" $caps
	da=""; db=""
	local i=0 c
	for c in $caps; do i=$((i+1)); da="${da:+$da,}$A/hdd$i"; db="${db:+$db,}$B/hdd$i"; done
	# shellcheck disable=SC2086
	rca=$(run_one "$KO" "$A" "$da" $extra)
	# shellcheck disable=SC2086
	rcb=$(run_one "$EN" "$B" "$db" $extra)
	echo ""; echo "[$name]"
	if [ "$rca" = "$rcb" ]; then ok "종료코드가 같다 ($rca)"
	else bad "종료코드가 다르다" "한글 $rca / 영어 $rcb"; fi
	snapshot "$A" | sed "s#$A#ROOT#g" > "$A/snap"
	snapshot "$B" | sed "s#$B#ROOT#g" > "$B/snap"
	if diff -q "$A/snap" "$B/snap" >/dev/null; then ok "결과가 완전히 같다 (담긴 것·남은 것·메일·조각)"
	else bad "결과가 다르다" "$(diff "$A/snap" "$B/snap" | head -6 | tr '\n' ' ')"; fi
	#  문구는 달라야 정상이다 (같으면 번역이 안 된 것)
	if ! diff -q "$A/out.txt" "$B/out.txt" >/dev/null; then ok "화면 문구는 서로 다르다 (번역됨)"
	else bad "문구까지 같다 — 번역이 안 됐다"; fi
	rm -rf "$A" "$B"
}

echo "=========================================================="
echo "  code9(한글) vs code10(영어) — 같은 일을 하는가"
echo "=========================================================="

compare "하드1 이 차면 하드2 로 이어진다"        6 4 0 "900 100000"
compare "한 런이 어느 하드보다도 크다 (3개에 분산)" 1 20 0 "900 900 900"
compare "Merged 는 담지 않는다 (기본)"           3 3 5 "100000 100000"
compare "--no-skip 이면 Merged 도 담는다"        2 3 3 "100000 100000" "--no-skip"
compare "★ 다회차 — 자리가 남으면 다시 계획"     8 2 5 "3000 100000"
compare "다음 하드가 가득 -> 오류로 멈춘다"      6 4 0 "900 80"
compare "하드를 다 썼는데 남았다 -> exit 3"      8 4 0 "900 900"
compare "--dry-run 은 아무것도 바꾸지 않는다"    4 3 0 "900 100000" "--dry-run"
compare "사용 중인 런만 남으면 정상 종료"        2 2 0 "100000 100000"

echo ""
echo "=========================================================="
printf "  통과 %d · 실패 %d\n" "$PASS" "$FAIL"
echo "=========================================================="
[ "$FAIL" -eq 0 ]
