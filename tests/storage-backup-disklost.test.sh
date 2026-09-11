#!/usr/bin/env bash
# 전송 중 하드가 떨어지면 : rsync 를 세우고, 그 자리에서 메일 한 통, exit 1, 원본 무손실, 다음 하드로 안 넘어감.
# 회차 시작 전 유령 마운트도 잡는다. 하드·메일 무접촉 (mktemp + BACKUP_TEST_HOOK + 가짜 rsync). 한/영 두 판본.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✅ $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  ❌ $1"; [ $# -gt 1 ] && echo "       $2"; }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "기대 '$3' / 실제 '$2'"; fi; }

setup() {   # $1=SUT
   SUT=$1; T=$(mktemp -d); SRC=$T/RAW; QUEUE=$T/MAILQ; mkdir -p "$SRC" "$QUEUE"
   for r in 000001 000002; do mkdir -p "$SRC/$r/PRD"; for i in 1 2 3 4; do dd if=/dev/zero of="$SRC/$r/FADC_$r.root.0000$i" bs=1024 count=100 status=none; done; done
   find "$SRC" -exec touch -d '1 day ago' {} + 2>/dev/null
   DISKS=""; for i in 1 2; do m=$T/hdd$i; mkdir -p "$m"; echo 100000 > "$T/cap.hdd$i"; : > "$T/mounted.hdd$i"; : > "$T/alive.hdd$i"; DISKS="${DISKS:+$DISKS,}$m"; done
   HOOK=$T/hook.sh
   cat > "$HOOK" <<HOOKEOF
disk_is_mounted() { [ -f "$T/mounted.\$(basename "\$1")" ]; }
disk_alive()      { [ -f "$T/alive.\$(basename "\$1")" ]; }
disk_cap_kb()     { cat "$T/cap.\$(basename "\$1")" 2>/dev/null || echo 0; }
disk_used_kb()    { du -sk "\$1" 2>/dev/null | awk '{print \$1}'; }
disk_avail_kb()   { local c u; c=\$(disk_cap_kb "\$1"); u=\$(disk_used_kb "\$1"); echo \$(( c - u < 0 ? 0 : c - u )); }
HOOKEOF
   #  느린 가짜 rsync : 시작 표식을 남기고 30초 잔다 (그 사이 하드를 '뽑는다'). 하나 복사해 둔다
   mkdir -p "$T/fakebin"
   cat > "$T/fakebin/rsync" <<'S'
#!/bin/bash
src=""; dst=""; for a in "$@"; do case "$a" in -*) ;; *) if [ -z "$src" ]; then src=$a; else dst=$a; fi ;; esac; done
mkdir -p "$dst"; f=$(ls "$src" | head -1); [ -n "$f" ] && cp "$src/$f" "$dst/" 2>/dev/null
touch "$FAKE_RSYNC_STARTED"; sleep 30; exit 0
S
   chmod +x "$T/fakebin/rsync"
}
run_sut() {
   BACKUP_SOURCE="$SRC" BACKUP_MOUNTS="$DISKS" BACKUP_TEST_HOOK="$HOOK" BACKUP_LOG="$T/backup_log.txt" \
   BACKUP_SIZE_CACHE="$T/size.cache" BACKUP_PARTS_INDEX="$T/parts_index.txt" BACKUP_LOCK="$T/.lock" \
   BACKUP_SKIP_LIST="$T/skip.txt" BACKUP_MAILQ="$QUEUE" BACKUP_SAFETY_MARGIN_KB=64 BACKUP_MIN_USEFUL_KB=32 BACKUP_BWLIMIT= \
   BACKUP_ALIVE_POLL=1 FAKE_RSYNC_STARTED="$T/rsync.started" PATH="$T/fakebin:$PATH" \
   timeout 120 bash "$SUT" "$@" > "$T/out.txt" 2>&1; RC=$?
}

for v in storage-backup.sh storage-backup-en.sh; do
   echo ""; echo "[$v] 전송 중 이탈"
   setup "$DIR/scripts/$v"
   ( for i in $(seq 1 300); do [ -f "$T/rsync.started" ] && break; sleep 0.2; done; sleep 1.5; rm -f "$T/alive.hdd1" ) &
   T0=$(date +%s); run_sut; EL=$(( $(date +%s) - T0 ))
   chk "exit 1" "$RC" "1"
   [ "$EL" -lt 25 ] && ok "rsync 를 기다리지 않고 바로 세웠다 (${EL}s)" || bad "rsync 30초를 다 기다렸다 (${EL}s)"
   grep -qE '전송 도중 떨어졌|dropped during the transfer' "$T/out.txt" && ok "이탈을 말한다" || bad "이탈 문구 없음" "$(grep -E '❌|⚠️' "$T/out.txt" | tail -2)"
   n=$(ls "$QUEUE"/*.mail 2>/dev/null | wc -l); chk "메일 정확히 1통" "$n" "1"
   grep -qE 'subject: .*(떨어졌습니다|dropped mid-transfer)' "$QUEUE"/*.mail 2>/dev/null && ok "메일 제목이 이탈" || bad "메일 제목" "$(grep -h subject "$QUEUE"/*.mail 2>/dev/null)"
   grep -qE 'umount -l' "$QUEUE"/*.mail && ok "복구 명령이 본문에" || bad "복구 명령 없음"
   chk "원본 8개 그대로" "$(find "$SRC" -type f | wc -l)" "8"
   chk "다음 하드는 건드리지 않았다" "$(find "$T/hdd2" -type f | wc -l)" "0"
   grep -q 'DISK LOST' "$T/backup_log.txt" && ok "로그에 DISK LOST" || bad "로그 표식 없음"
   rm -rf "$T"

   echo "[$v] 회차 시작 전 유령 마운트"
   setup "$DIR/scripts/$v"; rm -f "$T/alive.hdd1"
   run_sut
   chk "exit 1" "$RC" "1"
   grep -qE '유령 마운트|ghost mount' "$T/out.txt" && ok "유령 마운트라고 말한다" || bad "문구 없음" "$(grep -E '❌' "$T/out.txt" | head -2)"
   chk "메일 1통" "$(ls "$QUEUE"/*.mail 2>/dev/null | wc -l)" "1"
   chk "원본 그대로" "$(find "$SRC" -type f | wc -l)" "8"
   [ ! -f "$T/rsync.started" ] && ok "rsync 를 시작하지 않았다" || bad "rsync 가 돌았다"
   rm -rf "$T"

   echo "[$v] 정상 (alive 유지) 이면 이탈 경로를 타지 않는다"
   setup "$DIR/scripts/$v"; printf '#!/bin/bash\nsrc=""; dst=""; for a in "$@"; do case "$a" in -*) ;; *) if [ -z "$src" ]; then src=$a; else dst=$a; fi ;; esac; done; mkdir -p "$dst"; cp "$src"/* "$dst"/; exit 0\n' > "$T/fakebin/rsync"
   run_sut
   grep -qE 'DISK LOST|유령|ghost' "$T/backup_log.txt" "$T/out.txt" && bad "정상인데 이탈로 봤다" || ok "이탈 경로 안 탐"
   chk "메일에 이탈 없음" "$(grep -lE '떨어졌|dropped|ghost|유령' "$QUEUE"/*.mail 2>/dev/null | wc -l)" "0"
   rm -rf "$T"
done
echo; echo "=========================================================="; printf "  통과 %d · 실패 %d\n" "$PASS" "$FAIL"; echo "=========================================================="; [ "$FAIL" -eq 0 ]
