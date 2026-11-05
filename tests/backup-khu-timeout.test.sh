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
}
run_sut() {
	PATH="$T/bin:$PATH" "$SUT" --mid "$T/mid" --host fakehost --dest /fake \
	     --only RAW --run 994000 --quiet "$@" > "$T/out.txt" 2>&1
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
case "$ver"  in *"--timeout=3600"*) ok "★ 체크섬 대조는 더 긴 --timeout=3600" ;; *) bad "대조 rsync" "$ver" ;; esac
grepf "$T/mid/RAW/994000/.backup_done" "^RAW " && ok "마커가 찍혔다 (흐름이 그대로)" || bad "마커 없음"
rm -rf "$T"

echo ""; echo "[2] params 로 끈다 (backup_rsync_timeout = 0)"
setup
printf 'backup_rsync_timeout = 0\nbackup_verify_timeout = 0\n' > "$T/p.params"
run_sut --params "$T/p.params" --force
if ! grepf "$T/log.rsync" "--timeout"; then ok "--timeout 이 없다"; else bad "--timeout 이 남았다" "$(head -1 "$T/log.rsync")"; fi
grepf "$T/log.ssh" "ServerAliveInterval=30" && ok "ServerAlive 는 그대로" || bad "ServerAlive 가 빠졌다"
rm -rf "$T"

echo ""
echo "=========================================================="
printf "  통과 %d · 실패 %d\n" "$PASS" "$FAIL"
echo "=========================================================="
[ "$FAIL" -eq 0 ]
