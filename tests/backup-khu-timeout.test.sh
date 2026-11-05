#!/bin/bash
# =====================================================================
#  backup-khu.sh 의 망 단절 대비 옵션 시험 (ssh ServerAlive · rsync --timeout).
#
#  ★ 경희대에 닿지 않는다. PATH 앞에 가짜 ssh/rsync 를 두고, 그것이 받은 인자만
#    기록한다. 원본은 임시 디렉터리의 가짜 런이다.
#
#  돌리는 법 :  tests/backup-khu-timeout.test.sh
# =====================================================================
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../scripts/backup-khu.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }

setup() {
	T=$(mktemp -d); mkdir -p "$T/bin" "$T/mid/RAW/994000"
	echo x > "$T/mid/RAW/994000/FADC_994000.root.00000"
	cat > "$T/bin/ssh" <<'EOS'
#!/bin/bash
echo "$*" >> "$FAKE_LOG.ssh"
case "$*" in *"ls -1"*) echo 1 ;; *) echo OK-fake ;; esac
exit 0
EOS
	cat > "$T/bin/rsync" <<'EOS'
#!/bin/bash
echo "$*" >> "$FAKE_LOG.rsync"
exit 0
EOS
	chmod +x "$T/bin/ssh" "$T/bin/rsync"
	export FAKE_LOG="$T/log"
	RUNARG=(--run 994000)
}
run_sut() {
	BACKUP_LOCK="$T/.bk.lock" DATAFLOW_SSD_ROOT="$T/ssd" \
	PATH="$T/bin:$PATH" "$SUT" --mid "$T/mid" --host fakehost --dest /fake \
	     --only RAW --quiet "${RUNARG[@]}" "$@" > "$T/out.txt" 2>&1
	RC=$?
}
grepf() { grep -q -- "$2" "$1" 2>/dev/null; }

echo "=========================================================="
echo "  backup-khu.sh — ssh/rsync 시간 제한 시험"
echo "=========================================================="

echo ""; echo "[1] 기본값"
setup; run_sut
[ "$RC" = 0 ] && ok "종료코드 0" || bad "종료코드 $RC" "$(tail -3 "$T/out.txt")"
grepf "$T/log.ssh" "ServerAliveInterval=30" && ok "ssh 에 ServerAliveInterval=30" || bad "ssh 옵션 없음" "$(head -1 "$T/log.ssh")"
grepf "$T/log.ssh" "ServerAliveCountMax=4"  && ok "ssh 에 ServerAliveCountMax=4"  || bad "ssh 옵션 없음"
xfer=$(grep -v -- ' -c -n ' "$T/log.rsync" | head -1)
ver=$(grep -- ' -c -n ' "$T/log.rsync" | head -1)
case "$xfer" in *"--timeout=600"*) ok "전송 rsync 에 --timeout=600" ;; *) bad "전송 rsync" "$xfer" ;; esac
case "$xfer" in *"ServerAliveInterval=30"*) ok "전송 rsync 의 -e 에도 ServerAlive" ;; *) bad "전송 -e" "$xfer" ;; esac
[ -n "$ver" ] && ok "체크섬 대조가 돌았다" || bad "대조 rsync 가 없다"
case "$ver"  in *"--timeout"*) bad "★ 대조에 --timeout 이 걸렸다 (체크섬 중 keepalive 없음 -> code 30)" "$ver" ;; *) ok "★ 체크섬 대조에는 --timeout 을 걸지 않는다 (기본)" ;; esac
case "$ver"  in *"ServerAliveInterval=30"*) ok "대조도 ServerAlive 로 망 단절을 잡는다" ;; *) bad "대조 -e" "$ver" ;; esac
grepf "$T/mid/RAW/994000/.backup_done" "^RAW " && ok "마커가 찍혔다 (흐름이 그대로)" || bad "마커 없음"
rm -rf "$T"

echo ""; echo "[2] params 로 끈다 (backup_rsync_timeout = 0)"
setup
printf 'backup_rsync_timeout = 0\nbackup_verify_timeout = 0\n' > "$T/p.params"
run_sut --params "$T/p.params" --force
if ! grepf "$T/log.rsync" "--timeout"; then ok "--timeout 이 없다"; else bad "--timeout 이 남았다" "$(head -1 "$T/log.rsync")"; fi
grepf "$T/log.ssh" "ServerAliveInterval=30" && ok "ServerAlive 는 그대로" || bad "ServerAlive 가 빠졌다"
rm -rf "$T"

echo ""; echo "[3] params 로 대조 시간 제한을 켤 수 있다 (backup_verify_timeout = 7200)"
setup
printf 'backup_verify_timeout = 7200\n' > "$T/p.params"
run_sut --params "$T/p.params"
grepf "$T/log.rsync" "-c -n -i --timeout=7200" && ok "대조에 --timeout=7200" || bad "대조 rsync" "$(grep -- ' -c -n ' "$T/log.rsync")"
rm -rf "$T"

echo ""; echo "[4] ★ --all 은 1단계가 아직 옮기는 중인 런(원본이 ssd 에 남음)을 집지 않는다"
setup
mkdir -p "$T/mid/RAW/994001" "$T/ssd/RAW/994001"
echo x > "$T/mid/RAW/994001/FADC_994001.root.00000"
RUNARG=(--all)
run_sut
if grepf "$T/log.rsync" "994000"; then ok "다 옮겨진 994000 은 보냈다"; else bad "994000 을 안 보냈다"; fi
if ! grepf "$T/log.rsync" "994001"; then ok "옮기는 중인 994001 은 안 보냈다"; else bad "994001 을 보냈다" "$(grep 994001 "$T/log.rsync" | head -1)"; fi
[ -f "$T/mid/RAW/994001/.backup_done" ] && bad "994001 에 마커가 찍혔다" || ok "994001 에 마커 없음"
rm -rf "$T"

echo ""; echo "[5] ★ 겹쳐 돌지 않는다 (잠금을 다른 프로세스가 쥐면 rc 75, 아무것도 안 보낸다)"
setup
( exec 7>"$T/.bk.lock"; flock 7; sleep 5 ) & HOLD=$!
for i in 1 2 3 4 5 6 7 8 9 10; do flock -n "$T/.bk.lock" true 2>/dev/null || break; sleep 0.2; done
run_sut
[ "$RC" = 75 ] && ok "rc 75" || bad "rc $RC" "$(tail -2 "$T/out.txt")"
[ ! -f "$T/log.rsync" ] && ok "rsync 를 한 번도 안 불렀다" || bad "rsync 가 불렸다"
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
run_sut --dry-run
[ "$RC" = 0 ] && ok "--dry-run 은 잠금 없이 돈다" || bad "dry-run rc $RC"
rm -rf "$T"

echo ""
echo "=========================================================="
printf "  통과 %d · 실패 %d\n" "$PASS" "$FAIL"
echo "=========================================================="
[ "$FAIL" -eq 0 ]
