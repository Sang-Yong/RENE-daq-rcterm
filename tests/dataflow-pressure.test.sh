#!/bin/bash
# =====================================================================
#  dataflow.sh 의 압박 모드 · 부팅 실패 잔재 · 조용함 관문 · 2단계 분리 시험.
#
#  ★ 실데이터·실디스크·경희대·하드웨어를 건드리지 않는다. 임시 디렉터리에 가짜
#    런을 만들고 --ssd/--mid/--nfs 를 그리로 돌린다. 잠금(DATAFLOW_LOCK)·2단계
#    스크립트(DATAFLOW_BACKUP_SH)·/Data_ssd 여유(DATAFLOW_TEST_SSD_FREE_CMD)를
#    전부 갈아끼우므로 운영 중인 dataflow 와 부딪히지 않는다.
#
#  돌리는 법 :  tests/dataflow-pressure.test.sh
# =====================================================================
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../scripts/dataflow.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "기대 '$3' / 실제 '$2'"; fi; }
has() { if grep -q -- "$2" "$T/out.txt"; then ok "$1"; else bad "$1" "'$2' 없음 : $(tail -3 "$T/out.txt" | tr '\n' '|')"; fi; }
hasnt() { if ! grep -q -- "$2" "$T/out.txt"; then ok "$1"; else bad "$1" "'$2' 가 있다"; fi; }

#  ★ 런 번호는 00000x · 99xxxx 만 쓴다. backup_reading() 은 시스템 전체의 rsync/ssh 명령줄을
#    보므로, 실제 런 번호(예 004431)를 쓰면 운영에서 그 런을 옮기는 rsync 에 걸린다 (실측).
setup() {
	T=$(mktemp -d); SSD="$T/ssd"; MID="$T/mid"; NFS="$T/nfs"
	mkdir -p "$SSD/RAW" "$MID/RAW" "$NFS/RAW"
	HB="$T/rcterm.hb"
	{ echo "time=$(date +%s)"; echo "run=999999"; echo "phase=running"; } > "$HB"
	FREE=5000                                  # 기본은 넉넉하다
	export FAKE_DIR="$T"
	#  가짜 2단계 : PID 와 인자를 남기고 FAKE_SLEEP 초 잔다
	cat > "$T/fake-backup.sh" <<'EOF'
#!/bin/bash
echo "$$" > "$FAKE_DIR/bk.pid"
echo "$*" >> "$FAKE_DIR/bk.args"
exec sleep "${FAKE_SLEEP:-0}"
exit 0
EOF
	chmod +x "$T/fake-backup.sh"
}
teardown() {
	[ -f "$T/bk.pid" ] && kill "$(cat "$T/bk.pid")" 2>/dev/null
	[ -n "${T:-}" ] && rm -rf "$T"
}

#  mkrun <뿌리> <런> <FADC수> <PRD수>
mkrun() {
	local root=$1 rp=$2 nf=$3 np=$4 i d
	d="$root/RAW/$rp"; mkdir -p "$d/PRD"
	for i in $(seq 1 "$nf"); do echo x > "$d/FADC_$rp.root.$(printf '%05d' "$i")"; done
	for i in $(seq 1 "$np"); do echo x > "$d/PRD/PRD_$rp.$(printf '%05d' "$i").root"; done
	return 0
}
on_ssd() { [ -d "$SSD/RAW/$1" ] && echo ssd || { [ -d "$MID/RAW/$1" ] && echo mid || echo none; }; }

#  run_sut [옵션...]   — 기본 : 백업 끔, 조용함 관문 끔, 여유 $FREE
run_sut() {
	DATAFLOW_ALLOW_UNMOUNTED=1 DATAFLOW_LOCK="$T/.lock" \
	DATAFLOW_TEST_SSD_FREE_CMD="${FREECMD:-echo $FREE}" \
	"$SUT" --ssd "$SSD" --mid "$MID" --nfs "$NFS" --heartbeat "$HB" \
	       --once --stage 1 --quiet-min 0 --min-free-gb 700 "$@" > "$T/out.txt" 2>&1
	RC=$?
}

echo "=========================================================="
echo "  dataflow.sh — 압박 모드 / 잔재 / 조용함 / 2단계 분리 시험"
echo "=========================================================="

# ---------------------------------------------------------------------
echo ""; echo "[1] 보통 모드 (여유 5000G) : keep_ssd 2 는 최근 두 런을 남긴다"
setup
for r in 000001 000002 000003 000004; do mkrun "$SSD" $r 3 3; done
run_sut --keep-ssd 2
chk "종료코드 0" "$RC" "0"
chk "000001 은 /data 로" "$(on_ssd 000001)" "mid"
chk "000002 는 /data 로" "$(on_ssd 000002)" "mid"
chk "000003 은 남는다"   "$(on_ssd 000003)" "ssd"
chk "000004 는 남는다"   "$(on_ssd 000004)" "ssd"
hasnt "압박 모드가 아니다" "압박 모드"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[2] ★ 압박 모드 (여유 100G < 700G) : keep 을 무시하고 오래된 것부터 옮긴다"
setup; FREE=100
for r in 000001 000002 000003 000004; do mkrun "$SSD" $r 3 3; done
run_sut --keep-ssd 2
chk "종료코드 0" "$RC" "0"
for r in 000001 000002 000003 000004; do chk "$r 은 /data 로" "$(on_ssd $r)" "mid"; done
has "'[1] 압박 모드' 를 밝힌다" "\[1\] 압박 모드"
has "보관 창을 무시했다고 밝힌다" "압박 모드로 보관 창 무시"
o1=$(grep -n 'run 000001 : ' "$T/out.txt" | head -1 | cut -d: -f1)
o4=$(grep -n 'run 000004 : ' "$T/out.txt" | head -1 | cut -d: -f1)
if [ -n "$o1" ] && [ -n "$o4" ] && [ "$o1" -lt "$o4" ]; then ok "오래된 000001 이 000004 보다 먼저"
else bad "순서가 다르다" "000001@$o1 000004@$o4"; fi
chk "★ 옮긴 런의 파일이 그대로 (FADC 3 + PRD 3)" "$(find "$MID/RAW/000004" -type f | wc -l)" "6"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[3] ★ 압박이 풀리면 그 자리에서 보통 모드로 (런 하나 옮길 때마다 다시 잰다)"
setup
for r in 000001 000002 000003 000004; do mkrun "$SSD" $r 3 3; done
#  여유 = 100 + 300 x (/data 에 옮겨진 런 수) : 둘을 옮기면 700 이 된다
FREECMD="n=\$(ls -1 '$MID/RAW' | wc -l); echo \$((100 + 300*n))" run_sut --keep-ssd 2
chk "000001 은 /data 로" "$(on_ssd 000001)" "mid"
chk "000002 는 /data 로" "$(on_ssd 000002)" "mid"
chk "★ 회복 뒤 000003 은 남는다" "$(on_ssd 000003)" "ssd"
chk "★ 회복 뒤 000004 는 남는다" "$(on_ssd 000004)" "ssd"
has "해제를 밝힌다" "압박 모드 해제"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[4] ★ 압박 모드에서도 수집 중인 런은 건드리지 않는다"
setup; FREE=100
mkrun "$SSD" 994310 3 3; mkrun "$SSD" 994320 3 3
{ echo "time=$(date +%s)"; echo "run=994320"; echo "phase=running"; } > "$HB"
run_sut --keep-ssd 2
chk "994310 은 /data 로"         "$(on_ssd 994310)" "mid"
chk "수집 중 994320 는 남는다"   "$(on_ssd 994320)" "ssd"
has "수집 중이라고 밝힌다" "run 994320 : 수집 중"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[5] ★ 압박 모드에서도 후처리 미완료 런은 건드리지 않는다"
setup; FREE=100
mkrun "$SSD" 000001 10 7          # PRD 7 / FADC 10
mkrun "$SSD" 000002 3 3
run_sut --keep-ssd 2
chk "미완료 000001 은 남는다" "$(on_ssd 000001)" "ssd"
chk "완결 000002 는 옮긴다"   "$(on_ssd 000002)" "mid"
has "사유를 밝힌다" "run 000001 : 후처리 미완료"
has "이어지는 압박을 알린다" "압박 모드가 이어진다"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[6] ★ 부팅 실패 잔재 (FADC < 2) 는 후처리 완결 없이 옮긴다. 지우지 않는다"
setup
mkrun "$SSD" 994240 1 0                         # FADC 1 · PRD 0
echo x > "$SSD/RAW/994240/SADC_994240.root.00000"
mkdir -p "$SSD/RAW/993890/badrun"               # 전부 격리된 런 : FADC 0
echo x > "$SSD/RAW/993890/badrun/FADC_993890.root.00000"
echo x > "$SSD/RAW/993890/badrun/README.txt"
mkrun "$SSD" 994300 5 3                         # 진짜 미완료
mkrun "$SSD" 994310 3 3; mkrun "$SSD" 994320 3 3
run_sut --keep-ssd 2
chk "994240 (FADC 1) 는 /data 로" "$(on_ssd 994240)" "mid"
chk "★ 994240 의 파일 2 개 그대로" "$(find "$MID/RAW/994240" -type f | wc -l)" "2"
chk "993890 (badrun 만) 는 /data 로" "$(on_ssd 993890)" "mid"
chk "★ badrun/ 까지 함께 갔다" "$(find "$MID/RAW/993890/badrun" -type f | wc -l)" "2"
chk "진짜 미완료 994300 은 남는다" "$(on_ssd 994300)" "ssd"
has "잔재라고 밝힌다" "부팅 실패 잔재"
teardown

echo ""; echo "[6b] 잔재라도 수집 중이면 남긴다 (갓 부팅한 런은 FADC 가 0 이다)"
setup
mkdir -p "$SSD/RAW/994330"
mkrun "$SSD" 994310 3 3; mkrun "$SSD" 994320 3 3
{ echo "time=$(date +%s)"; echo "run=994330"; echo "phase=booting"; } > "$HB"
run_sut --keep-ssd 0
chk "수집 중 빈 런 994330 은 남는다" "$(on_ssd 994330)" "ssd"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[7] ★ 조용함 관문 : 최근 바뀐 런은 옮기지 않는다 (기본 10 분)"
setup; FREE=100
mkrun "$SSD" 000001 3 3
run_sut --keep-ssd 0 --quiet-min 10
chk "방금 쓴 런은 남는다" "$(on_ssd 000001)" "ssd"
has "사유를 밝힌다" "최근 10분 안에 바뀐 파일"
find "$SSD/RAW/000001" -exec touch -d '1 hour ago' {} +
run_sut --keep-ssd 0 --quiet-min 10
chk "한 시간 묵은 뒤에는 옮긴다" "$(on_ssd 000001)" "mid"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[8] ★ --dry-run 은 압박 모드에서도 아무것도 옮기지 않는다"
setup; FREE=100
for r in 000001 000002; do mkrun "$SSD" $r 3 3; done
run_sut --keep-ssd 2 --dry-run
chk "000001 그대로" "$(on_ssd 000001)" "ssd"
chk "000002 그대로" "$(on_ssd 000002)" "ssd"
chk "/data 는 비어 있다" "$(ls -A "$MID/RAW" | wc -l)" "0"
has "미리보기를 보여준다" "\[DRY\]"
has "압박 모드는 알린다" "\[1\] 압박 모드"
teardown

echo ""; echo "[8b] --dry-run 의 2단계는 그 자리에서(기다림) --dry-run 으로, 잠금 파일도 안 만든다"
setup
DATAFLOW_BACKUP_SH="$T/fake-backup.sh" run_sut --stage 2 --dry-run
chk "종료코드 0" "$RC" "0"
chk "2단계에 --dry-run 을 넘겼다" "$(grep -c -- '--dry-run' "$T/bk.args" 2>/dev/null)" "1"
chk "2단계 잠금 파일 없음" "$([ -e "$T/.lock.stage2" ] && echo yes || echo no)" "no"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[9] --once 는 예전처럼 2단계가 끝날 때까지 기다린다"
setup
s0=$(date +%s)
FAKE_SLEEP=3 DATAFLOW_BACKUP_SH="$T/fake-backup.sh" run_sut --stage 2
el=$(( $(date +%s) - s0 ))
chk "종료코드 0" "$RC" "0"
if [ "$el" -ge 3 ]; then ok "기다렸다 (${el}s)"; else bad "기다리지 않았다" "${el}s"; fi
chk "2단계가 한 번 돌았다" "$(wc -l < "$T/bk.args")" "1"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[10] ★ --follow : 2단계가 도는 동안에도 1·3 단계가 돈다"
setup
for r in 000001 000002 000003; do mkrun "$SSD" $r 3 3; done
mkrun "$MID" 000000 3 3                          # 백업이 끝난 런 -> 3단계 대상
printf 'RAW x 3\nPRD x 3\nPNG x 0\nDAQLOG x 0\nconfig x 0\n' > "$MID/RAW/000000/.backup_done"
FAKE_SLEEP=60 DATAFLOW_ALLOW_UNMOUNTED=1 DATAFLOW_LOCK="$T/.lock" \
DATAFLOW_BACKUP_SH="$T/fake-backup.sh" DATAFLOW_TEST_SSD_FREE_CMD="echo 5000" \
	"$SUT" --ssd "$SSD" --mid "$MID" --nfs "$NFS" --heartbeat "$HB" \
	       --follow --poll 1 --quiet-min 0 --keep-ssd 1 > "$T/out.txt" 2>&1 &
DF=$!
for i in $(seq 1 30); do
	[ "$(on_ssd 000002)" = mid ] && [ -d "$NFS/RAW/000000" ] && [ ! -d "$MID/RAW/000000" ] \
		&& grep -q '외부 백업이 아직 돈다' "$T/out.txt" && break
	sleep 0.5
done
chk "1단계 : 000001 은 옮겨졌다" "$(on_ssd 000001)" "mid"
chk "1단계 : 000002 는 옮겨졌다" "$(on_ssd 000002)" "mid"
chk "1단계 : keep 1 이라 000003 은 남는다" "$(on_ssd 000003)" "ssd"
chk "3단계 : 000000 은 /scratch 로" "$([ -d "$NFS/RAW/000000" ] && echo yes || echo no)" "yes"
has "2단계가 도는 중이라 다음 주기에 건너뛴다" "외부 백업이 아직 돈다"
chk "2단계는 한 번만 띄웠다" "$(wc -l < "$T/bk.args" 2>/dev/null)" "1"
BK=$(cat "$T/bk.pid" 2>/dev/null)

#  다시 띄운 dataflow 는 본 잠금이 풀려 있어 돌고, 2단계는 잠금 때문에 띄우지 않는다
kill -TERM "$DF"; t0=$(date +%s)
wait "$DF" 2>/dev/null; dfrc=$?
chk "TERM 에 곧바로 빠진다 (rc 130)" "$dfrc" "130"
if [ $(( $(date +%s) - t0 )) -le 3 ]; then ok "3 초 안에 빠졌다"; else bad "늦게 빠졌다"; fi
if [ -n "$BK" ] && kill -0 "$BK" 2>/dev/null; then ok "뒤의 2단계는 계속 돈다 (pid $BK)"
else bad "2단계가 같이 죽었다"; fi
DATAFLOW_BACKUP_SH="$T/fake-backup.sh" run_sut --stage 2
hasnt "★ 본 잠금을 2단계가 쥐고 있지 않다" "이미 실행 중이다"
has "★ 도는 2단계가 있으면 두 번째를 띄우지 않는다" "다른 외부 백업이 돌고 있다"
chk "2단계는 여전히 한 번" "$(wc -l < "$T/bk.args")" "1"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[11] cron 환경(env -i)에서도 압박 모드가 돈다"
setup
for r in 000001 000002; do mkrun "$SSD" $r 3 3; done
env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$T" \
	DATAFLOW_ALLOW_UNMOUNTED=1 DATAFLOW_LOCK="$T/.lock" DATAFLOW_TEST_SSD_FREE_CMD="echo 1" \
	"$SUT" --ssd "$SSD" --mid "$MID" --nfs "$NFS" --heartbeat "$HB" \
	       --no-backup --once --stage 1 --quiet-min 0 --keep-ssd 2 > "$T/out.txt" 2>&1
chk "종료코드 0" "$?" "0"
chk "keep 안의 000002 도 옮겼다" "$(on_ssd 000002)" "mid"
teardown

# ---------------------------------------------------------------------
echo ""; echo "[12] params 파일의 quiet_min · min_subruns 를 읽는다"
setup
mkrun "$SSD" 000001 2 0                          # FADC 2, min_subruns 3 이면 잔재
mkrun "$SSD" 000002 3 3
printf 'quiet_min = 0\nmin_subruns = 3\nkeep_ssd = 1\nbackup_enable = 0\n' > "$T/p.params"
DATAFLOW_ALLOW_UNMOUNTED=1 DATAFLOW_LOCK="$T/.lock" DATAFLOW_TEST_SSD_FREE_CMD="echo 5000" \
	"$SUT" --params "$T/p.params" --ssd "$SSD" --mid "$MID" --nfs "$NFS" --heartbeat "$HB" \
	       --once --stage 1 > "$T/out.txt" 2>&1
chk "min_subruns 3 이라 FADC 2 런도 잔재로 옮겼다" "$(on_ssd 000001)" "mid"
teardown

echo ""
echo "=========================================================="
printf "  통과 %d · 실패 %d\n" "$PASS" "$FAIL"
echo "=========================================================="
[ "$FAIL" -eq 0 ]
