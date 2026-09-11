#!/usr/bin/env bash
# disk_ident() 가 udevadm 의 ID_SERIAL_SHORT / ID_WWN 을 읽고, lsblk 의 RANDOM__ 브리지 값을 쓰지 않는지.
# 하드·udev 무접촉 : PATH 앞에 가짜 findmnt/lsblk/udevadm 을 둔다. 한/영 두 판본 모두.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
mkdir -p "$T/bin"
cat > "$T/bin/findmnt" <<'S'
#!/bin/sh
echo /dev/sdz1
S
cat > "$T/bin/lsblk" <<'S'
#!/bin/sh
case "$*" in *UUID*) echo 11111111-2222-3333-4444-555555555555 ;; *PKNAME*) echo sdz ;; *MODEL*) echo "ST2000DM008-2FR102" ;; *SERIAL*) echo "RANDOM__DEADBEEF0001" ;; esac
S
cat > "$T/bin/udevadm" <<'S'
#!/bin/sh
[ "${UDEV_EMPTY:-0}" = 1 ] && exit 0
printf 'ID_MODEL=ST2000DM008-2FR102\nID_SERIAL=ST2000DM008-2FR102_ZK206014\nID_SERIAL_SHORT=ZK206014\nID_WWN=0x5000c500c8b28f6e\n'
S
chmod +x "$T/bin"/*
for v in storage-backup.sh storage-backup-en.sh; do
   echo "[$v]"
   # 함수만 뽑아 source 한다 (스크립트 본체는 실행하지 않는다)
   sed -n '/^disk_ident() {/,/^}/p' "$DIR/scripts/$v" > "$T/f.sh"
   out=$(PATH="$T/bin:$PATH" bash -c '. "$1"; disk_ident /mnt/x; printf "%s|%s|%s|%s|%s\n" "$D_DEV" "$D_UUID" "$D_MODEL" "$D_SERIAL" "$D_WWN"' _ "$T/f.sh")
   check "udevadm 시리얼"      '[ "$(printf "%s" "$out" | cut -d"|" -f4)" = ZK206014 ]'
   check "WWN"                 '[ "$(printf "%s" "$out" | cut -d"|" -f5)" = 0x5000c500c8b28f6e ]'
   check "RANDOM__ 안 씀"      '! printf "%s" "$out" | grep -q RANDOM__'
   check "UUID·모델 그대로"    'printf "%s" "$out" | grep -q "11111111-2222.*ST2000DM008"'
   out2=$(UDEV_EMPTY=1 PATH="$T/bin:$PATH" bash -c '. "$1"; disk_ident /mnt/x; printf "%s|%s\n" "$D_SERIAL" "$D_WWN"' _ "$T/f.sh")
   check "udevadm 비면 lsblk 로 물러나되 브리지 표시" 'printf "%s" "$out2" | grep -q "RANDOM__DEADBEEF0001 (" && [ "$(printf "%s" "$out2" | cut -d"|" -f2)" = "" ]'
done
echo; echo "PASS $PASS  FAIL $FAIL"; [ $FAIL = 0 ]
