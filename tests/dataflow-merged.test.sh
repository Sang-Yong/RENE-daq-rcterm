#!/bin/bash
# =====================================================================
#  dataflow.sh 의 Merged 청소(M단계) 시험.
#
#  ★ 실데이터도 실디스크도 건드리지 않는다. 임시 디렉터리에 가짜 런을
#    만들고 --ssd/--mid/--nfs 를 그리로 돌린다. 잠금도 갈아끼우므로
#    운영 중인 dataflow 와 부딪히지 않는다.
#
#  돌리는 법 :  tests/dataflow-merged.test.sh
# =====================================================================
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../scripts/dataflow.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "기대 '$3' / 실제 '$2'"; fi; }

setup() {
	T=$(mktemp -d); SSD="$T/ssd"; MID="$T/mid"; NFS="$T/nfs"
	mkdir -p "$SSD/RAW" "$MID/RAW" "$NFS/RAW"
	HB="$T/rcterm.hb"
	{ echo "time=$(date +%s)"; echo "run=999999"; echo "phase=running"; } > "$HB"
}
teardown() { [ -n "${T:-}" ] && rm -rf "$T"; }

#  가짜 런 하나.  mkrun <뿌리> <런> <FADC수> <PRD수> <Merged수> [빈PRD수]
mkrun() {
	local root=$1 rp=$2 nf=$3 np=$4 nm=$5 nz=${6:-0} i d
	d="$root/RAW/$rp"; mkdir -p "$d/PRD" "$d/Merged"
	for i in $(seq 1 "$nf"); do echo x > "$d/FADC_$rp.root.$(printf '%05d' "$i")"; done
	for i in $(seq 1 "$np"); do echo x > "$d/PRD/PRD_$rp.$(printf '%05d' "$i").root"; done
	for i in $(seq 1 "$nm"); do echo x > "$d/Merged/MERGED_$rp.root.$(printf '%05d' "$i")"; done
	for i in $(seq 1 "$nz"); do : > "$d/PRD/PRD_$rp.$(printf '%05d' "$((900+i))").root"; done
}

run_sut() {
	DATAFLOW_ALLOW_UNMOUNTED=1 DATAFLOW_LOCK="$T/.lock" \
	"$SUT" --ssd "$SSD" --mid "$MID" --nfs "$NFS" --heartbeat "$HB" \
	       --no-backup --once "$@" > "$T/out.txt" 2>&1
	RC=$?
}
has_merged()  { [ -d "$1/Merged" ] && echo yes || echo no; }
n_merged()    { find "$T" -type d -name Merged 2>/dev/null | wc -l; }

echo "=========================================================="
echo "  dataflow.sh — Merged 청소 시험"
echo "=========================================================="

# ---------------------------------------------------------------------
echo ""; echo "[1] 보관 창 : 최근 N 개만 남기고 나머지를 지운다"
setup
for r in 000001 000002 000003 000004 000005 000006 000007; do mkrun "$NFS" "$r" 3 3 3; done
run_sut --stage M --merged-keep 5
chk "종료코드 0" "$RC" "0"
chk "가장 오래된 000001 은 지워졌다" "$(has_merged "$NFS/RAW/000001")" "no"
chk "000002 도 지워졌다"             "$(has_merged "$NFS/RAW/000002")" "no"
chk "000003 은 남았다 (창 안)"       "$(has_merged "$NFS/RAW/000003")" "yes"
chk "최신 000007 은 남았다"          "$(has_merged "$NFS/RAW/000007")" "yes"
chk "남은 Merged 폴더 5 개"          "$(n_merged)" "5"
chk "★ PRD 는 하나도 안 건드렸다"    "$(find "$NFS/RAW/000001/PRD" -type f | wc -l)" "3"
chk "★ FADC 도 그대로"               "$(find "$NFS/RAW/000001" -maxdepth 1 -name 'FADC_*' | wc -l)" "3"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[2] ★ 보관 창은 세 뿌리를 합쳐서 센다 (뿌리마다 세면 3배가 남는다)"
setup
mkrun "$NFS" 000001 3 3 3; mkrun "$NFS" 000002 3 3 3
mkrun "$MID" 000003 3 3 3; mkrun "$MID" 000004 3 3 3
mkrun "$SSD" 000005 3 3 3; mkrun "$SSD" 000006 3 3 3
run_sut --stage M --merged-keep 2
chk "합쳐서 최신 2 개만 남는다" "$(n_merged)" "2"
chk "000005 (ssd) 남음" "$(has_merged "$SSD/RAW/000005")" "yes"
chk "000006 (ssd) 남음" "$(has_merged "$SSD/RAW/000006")" "yes"
chk "000004 (mid) 지워짐" "$(has_merged "$MID/RAW/000004")" "no"
chk "000001 (nfs) 지워짐" "$(has_merged "$NFS/RAW/000001")" "no"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[3] ★ 후처리가 덜 끝난 런은 손대지 않는다"
setup
mkrun "$NFS" 000001 10 7 10        # PRD 7 / FADC 10 -> 미완료
mkrun "$NFS" 000002 3 3 3
run_sut --stage M --merged-keep 1
chk "미완료 런의 Merged 는 남는다" "$(has_merged "$NFS/RAW/000001")" "yes"
if grep -q '후처리미완료' "$T/out.txt"; then ok "사유를 밝힌다 (후처리미완료)"
else bad "사유가 없다" "$(grep -i merged "$T/out.txt" | head -2)"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[4] ★ PRD 에 0 바이트 파일이 있으면 손대지 않는다"
setup
mkrun "$NFS" 000001 3 3 3 2        # 0바이트 PRD 2 개를 섞는다
mkrun "$NFS" 000002 3 3 3
run_sut --stage M --merged-keep 1
chk "반쪽 PRD 위에서는 안 지운다" "$(has_merged "$NFS/RAW/000001")" "yes"
if grep -q 'PRD빈파일' "$T/out.txt"; then ok "빈 파일 개수를 밝힌다"
else bad "사유가 없다" "$(grep -i merged "$T/out.txt" | head -2)"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[5] ★ 아카이브된 런 (RAW 없음 + PRD 있음) 은 지운다"
#  이 갈래가 없으면 용량을 가장 많이 먹는 옛 런이 영영 청소되지 않는다.
setup
mkrun "$NFS" 000001 0 5 4          # FADC 0 개 = 외장하드로 아카이브됨
mkrun "$NFS" 000002 3 3 3
run_sut --stage M --merged-keep 1
chk "아카이브된 런의 Merged 는 지운다" "$(has_merged "$NFS/RAW/000001")" "no"
if grep -q '아카이브됨' "$T/out.txt"; then ok "아카이브됨으로 판정했다"
else bad "판정이 다르다" "$(grep -i merged "$T/out.txt" | head -2)"; fi
chk "PRD 는 그대로" "$(find "$NFS/RAW/000001/PRD" -type f | wc -l)" "5"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[6] PRD 가 아예 없으면 손대지 않는다"
setup
mkrun "$NFS" 000001 3 0 3
mkrun "$NFS" 000002 3 3 3
run_sut --stage M --merged-keep 1
chk "PRD 없는 런은 남는다" "$(has_merged "$NFS/RAW/000001")" "yes"
if grep -q 'PRD없음' "$T/out.txt"; then ok "사유를 밝힌다"; else bad "사유가 없다"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[7] 수집 중인 런은 손대지 않는다"
setup
mkrun "$NFS" 004322 3 3 3
mkrun "$NFS" 004323 3 3 3
{ echo "time=$(date +%s)"; echo "run=4322"; echo "phase=running"; } > "$HB"
run_sut --stage M --merged-keep 1
chk "수집 중인 4322 는 남는다" "$(has_merged "$NFS/RAW/004322")" "yes"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[8] 심볼릭 링크인 Merged 는 손대지 않는다 (옛 --outroot 구성)"
setup
mkrun "$NFS" 000002 3 3 3
mkdir -p "$NFS/RAW/000001/PRD" "$T/elsewhere"
echo x > "$NFS/RAW/000001/PRD/PRD_000001.00001.root"
echo x > "$NFS/RAW/000001/FADC_000001.root.00001"
echo x > "$T/elsewhere/MERGED_000001.root.00001"
ln -s "$T/elsewhere" "$NFS/RAW/000001/Merged"
run_sut --stage M --merged-keep 1
chk "링크가 그대로 있다" "$([ -L "$NFS/RAW/000001/Merged" ] && echo yes || echo no)" "yes"
chk "링크가 가리키던 실체도 그대로" "$(find "$T/elsewhere" -type f | wc -l)" "1"
if grep -q '심볼릭링크' "$T/out.txt"; then ok "사유를 밝힌다"; else bad "사유가 없다"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[9] 기본값은 꺼짐 — --merged-keep 없이는 아무것도 안 지운다"
setup
for r in 000001 000002 000003; do mkrun "$NFS" "$r" 3 3 3; done
run_sut --stage M
chk "종료코드 0" "$RC" "0"
chk "Merged 3 개 전부 남는다" "$(n_merged)" "3"
if grep -q 'KEEP_MERGED=0' "$T/out.txt"; then ok "꺼져 있다고 알린다"
else bad "안내가 없다" "$(tail -2 "$T/out.txt")"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[10] --dry-run 은 지우지 않고 무엇이 지워질지만 보여준다"
setup
for r in 000001 000002 000003; do mkrun "$NFS" "$r" 3 3 3; done
run_sut --stage M --merged-keep 1 --dry-run
chk "하나도 안 지웠다" "$(n_merged)" "3"
if grep -q '\[DRY\]' "$T/out.txt"; then ok "지울 대상을 보여준다"
else bad "미리보기가 없다" "$(tail -3 "$T/out.txt")"; fi
if grep -q '지우지 않았다' "$T/out.txt"; then ok "합계에 dry-run 이라고 밝힌다"
else bad "합계 안내가 없다"; fi
teardown

# ---------------------------------------------------------------------
echo ""; echo "[11] 전체 주기에도 M 단계가 붙는다 (--stage 없이)"
setup
for r in 000001 000002; do mkrun "$NFS" "$r" 3 3 3; done
run_sut --merged-keep 1
chk "종료코드 0" "$RC" "0"
chk "오래된 것이 지워졌다" "$(has_merged "$NFS/RAW/000001")" "no"
chk "최신은 남았다"       "$(has_merged "$NFS/RAW/000002")" "yes"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[12] cron 환경(env -i)에서도 돈다"
setup
for r in 000001 000002; do mkrun "$NFS" "$r" 3 3 3; done
env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$T" \
	DATAFLOW_ALLOW_UNMOUNTED=1 DATAFLOW_LOCK="$T/.lock" \
	"$SUT" --ssd "$SSD" --mid "$MID" --nfs "$NFS" --heartbeat "$HB" \
	       --no-backup --once --stage M --merged-keep 1 > "$T/out.txt" 2>&1
chk "종료코드 0" "$?" "0"
chk "정상 동작" "$(has_merged "$NFS/RAW/000001")" "no"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[13] ★ 회차당 상한 — 넘어서면 멈추고 다음 주기로 미룬다"
setup
for r in 000001 000002 000003 000004 000005; do mkrun "$NFS" "$r" 3 3 4; done
mkrun "$NFS" 000006 3 3 3     # 보관 창
run_sut --stage M --merged-keep 1 --merged-max 6
chk "종료코드 0" "$RC" "0"
#  런당 Merged 4 개.  상한 6 이면 : 1번(0->4) 시작, 2번(4->8) 시작, 3번은 8>=6 이라 멈춤
chk "두 런만 지웠다" "$(n_merged)" "4"
if grep -q '상한 6 개에 닿았다' "$T/out.txt"; then ok "상한에서 멈췄다고 알린다"
else bad "상한 안내가 없다" "$(grep -i 상한 "$T/out.txt" | head -2)"; fi
if grep -q '상한에서 멈췄다' "$T/out.txt"; then ok "합계에도 밝힌다"
else bad "합계 안내가 없다"; fi
teardown

echo ""; echo "[14] ★ 상한보다 큰 런도 결국 지워진다 (시작한 런은 끝까지)"
#  상한을 '지우는 중' 에 보면 이런 런은 영영 남는다.
setup
mkrun "$NFS" 000001 3 3 50    # 상한(5)보다 훨씬 큰 런
mkrun "$NFS" 000002 3 3 3
run_sut --stage M --merged-keep 1 --merged-max 5
chk "큰 런도 지워졌다" "$(has_merged "$NFS/RAW/000001")" "no"
teardown

echo ""; echo "[15] --merged-max 0 이면 상한 없이 전부 지운다"
setup
for r in 000001 000002 000003 000004; do mkrun "$NFS" "$r" 3 3 10; done
mkrun "$NFS" 000005 3 3 3
run_sut --stage M --merged-keep 1 --merged-max 0
chk "보관 창 1 개만 남는다" "$(n_merged)" "1"
if ! grep -q '상한' "$T/out.txt"; then ok "상한을 말하지 않는다"
else bad "상한이 걸렸다" "$(grep -i 상한 "$T/out.txt" | head -1)"; fi
teardown

echo ""; echo "[16] 다음 주기에 이어서 지운다 (두 번 돌리면 마저 끝난다)"
setup
for r in 000001 000002 000003 000004; do mkrun "$NFS" "$r" 3 3 4; done
mkrun "$NFS" 000005 3 3 3
run_sut --stage M --merged-keep 1 --merged-max 6
n1=$(n_merged)
run_sut --stage M --merged-keep 1 --merged-max 6
n2=$(n_merged)
chk "1회차 뒤 남은 Merged 3 개" "$n1" "3"
chk "2회차 뒤 남은 Merged 1 개 (보관 창)" "$n2" "1"
teardown

echo ""
echo "=========================================================="
printf "  통과 %d · 실패 %d\n" "$PASS" "$FAIL"
echo "=========================================================="
[ "$FAIL" -eq 0 ]
