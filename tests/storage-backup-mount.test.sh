#!/bin/bash
# tests/storage-backup-mount.test.sh -- scripts/storage-backup-mount.sh 의 시험
# root · 실하드 · 실 fstab · 실서버 · 메일을 건드리지 않는다.
# lsblk/udevadm/mount/mountpoint/findmnt/df/chown/systemctl/sudo/fuser/ps 를 PATH 앞의 가짜로,
# 마운트지점·by-id·로그·code9·사슬 경로는 BACKUP_MOUNT_* 로 갈아끼운다.
# 픽스처는 저장소 서버 실물 출력(2026-10-17, lsblk -P · udevadm) 을 복사한 것이다.
HERE=$(cd "$(dirname "$0")/.." && pwd)
SUT=$HERE/scripts/storage-backup-mount.sh
PASS=0; FAILN=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
ng()  { FAILN=$((FAILN+1)); echo "  FAIL $1"; }
chk() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

setup() {   # $1 = 디스크 수 (1|2|3), $2 = sdc fstype (기본 ext4)
	T=$(mktemp -d); F=$T/fake; mkdir -p "$F" "$T/bin" "$T/byid" "$T/dev" "$T/home/sykim/backup_log" "$T/mp1" "$T/mp2"
	local n=${1:-2} fs2=${2:-ext4}
	{
		echo 'NAME="sda" TRAN="" TYPE="disk" SIZE="140.1T" MODEL="MR9361-8i"'
		echo 'NAME="sdb" TRAN="usb" TYPE="disk" SIZE="1.8T" MODEL="ST2000DM008-2FR102"'
		[ "$n" -ge 2 ] && echo 'NAME="sdc" TRAN="usb" TYPE="disk" SIZE="1.8T" MODEL="ST2000DM006-2DM164"'
		[ "$n" -ge 3 ] && echo 'NAME="sdd" TRAN="usb" TYPE="disk" SIZE="1.8T" MODEL="ST2000DM008-2FR102"'
		echo 'NAME="nvme0n1" TRAN="nvme" TYPE="disk" SIZE="931.5G" MODEL="SHPP41-1000GM"'
	} > "$F/disks"
	{
		echo 'NAME="sda" TYPE="disk" FSTYPE="" MOUNTPOINT="" PKNAME=""'
		echo 'NAME="sda1" TYPE="part" FSTYPE="ext4" MOUNTPOINT="/data" PKNAME="sda"'
		echo 'NAME="sdb" TYPE="disk" FSTYPE="" MOUNTPOINT="" PKNAME=""'
		echo 'NAME="sdb1" TYPE="part" FSTYPE="ext4" MOUNTPOINT="" PKNAME="sdb"'
		echo 'NAME="sdc" TYPE="disk" FSTYPE="" MOUNTPOINT="" PKNAME=""'
		echo "NAME=\"sdc1\" TYPE=\"part\" FSTYPE=\"$fs2\" MOUNTPOINT=\"\" PKNAME=\"sdc\""
		echo 'NAME="sdd" TYPE="disk" FSTYPE="" MOUNTPOINT="" PKNAME=""'
		echo 'NAME="sdd1" TYPE="part" FSTYPE="ext4" MOUNTPOINT="" PKNAME="sdd"'
		echo 'NAME="nvme0n1p4" TYPE="part" FSTYPE="xfs" MOUNTPOINT="/" PKNAME="nvme0n1"'
	} > "$F/parts"
	printf 'ID_BUS=ata\nID_MODEL=ST2000DM008-2FR102\nID_SERIAL_SHORT=ZK206HAY\n' > "$F/udev.sdb"
	printf 'ID_BUS=ata\nID_MODEL=ST2000DM006-2DM164\nID_SERIAL_SHORT=Z4ZBZE0A\n' > "$F/udev.sdc"
	printf 'ID_BUS=ata\nID_MODEL=ST2000DM008-2FR102\nID_SERIAL_SHORT=ZK206XXX\n' > "$F/udev.sdd"
	for d in sdb1 sdc1 sdd1; do : > "$T/dev/$d"; done
	ln -s "$T/dev/sdb1" "$T/byid/ata-ST2000DM008-2FR102_ZK206HAY-part1"
	ln -s "$T/dev/sdc1" "$T/byid/ata-ST2000DM006-2DM164_Z4ZBZE0A-part1"
	ln -s "$T/dev/sdd1" "$T/byid/ata-ST2000DM008-2FR102_ZK206XXX-part1"
	: > "$F/mounts"; : > "$F/ps.txt"; : > "$F/calls"

	cat > "$T/bin/lsblk" <<'X'
#!/bin/bash
case " $* " in *" -d "*) cat "$FAKE/disks";; *" -P "*) cat "$FAKE/parts";; *) echo "NAME SIZE TRAN (table)";; esac
X
	cat > "$T/bin/udevadm" <<'X'
#!/bin/bash
for a; do case $a in --name=*) n=${a#--name=/dev/};; esac; done; cat "$FAKE/udev.$n" 2>/dev/null
X
	cat > "$T/bin/mountpoint" <<'X'
#!/bin/bash
mp=${@: -1}; grep -q "^$mp " "$FAKE/mounts"
X
	cat > "$T/bin/findmnt" <<'X'
#!/bin/bash
mp=${@: -1}; awk -v m="$mp" '$1==m{print $2}' "$FAKE/mounts"
X
	cat > "$T/bin/mount" <<'X'
#!/bin/bash
echo "mount $*" >> "$FAKE/calls"
[ "$1" = -t ] && [ "$2" = ext4 ] || { echo "fake mount: -t ext4 expected"; exit 1; }
[ -e "$3" ] || { echo "mount: $3: no such device"; exit 32; }
echo "$4 $(readlink -f "$3")" >> "$FAKE/mounts"
X
	cat > "$T/bin/df" <<'X'
#!/bin/bash
echo "Filesystem Size Used Avail Use% Mounted"; echo "/dev/fake 1.8T 28K 1.7T 1% ${@: -1}"
X
	for c in chown systemctl; do printf '#!/bin/bash\necho "%s $*" >> "$FAKE/calls"\n' "$c" > "$T/bin/$c"; done
	cat > "$T/bin/fuser" <<'X'
#!/bin/bash
[ "${FAKE_FUSER:-0}" = 1 ] && { echo " 4242"; exit 0; }; exit 1
X
	cat > "$T/bin/sudo" <<'X'
#!/bin/bash
echo "sudo $*" >> "$FAKE/calls"
while [ $# -gt 0 ]; do case $1 in -u) shift 2;; -H) shift;; *) break;; esac; done
exec "$@"
X
	cat > "$T/bin/ps" <<'X'
#!/bin/bash
case " $* " in *" -eo "*) cat "$FAKE/ps.txt";; *) exec /usr/bin/ps "$@";; esac
X
	cat > "$T/code9" <<'X'
#!/bin/bash
echo "code9 $*" >> "$FAKE/code9.calls"
case " $* " in
*" --dry-run "*)
	echo "    /backup_hdd      /dev/sdb1  여유 1.70 TB  쓰기 가능"
	echo "  런 002458  [부분]  4682 / 5853 개  1.70 TB"
	echo "  합계   : 런 1 개 (전체 0 · 부분 1) · 파일 4682 개 · 1.70 TB"
	echo "  속도   : 50M → 예상 소요 약 9시간 53분  (대조 시간은 별도)"
	exit "${FAKE_CODE9_RC:-0}";;
*)	echo "4343 /home/frontend/data_backup_simple_code9.sh $*" >> "$FAKE/ps.txt"
	echo "  쓸 하드"; echo "  담는 종류 : raw"; exit 0;;
esac
X
	chmod +x "$T/bin/"* "$T/code9"
	export FAKE=$F PATH="$T/bin:$PATH"
	export BACKUP_MOUNT_MP_RAW=$T/mp1 BACKUP_MOUNT_MP_PRD=$T/mp2 BACKUP_MOUNT_BYID=$T/byid BACKUP_MOUNT_HOME=$T/home \
	       BACKUP_MOUNT_LOGDIR=$T/home/sykim/backup_log BACKUP_MOUNT_CODE9=$T/code9 \
	       BACKUP_MOUNT_CHAIN=$T/home/backup_raw_then_prd.sh BACKUP_MOUNT_WAIT=1 \
	       BACKUP_MOUNT_EUID=0 BACKUP_MOUNT_USER=$(id -un)
	unset FAKE_FUSER FAKE_CODE9_RC
}
runsut() { OUT=$(bash "$SUT" "$@" 2>&1); RC=$?; sleep 0.3; }
done_() { rm -rf "$T"; }
B1=ata-ST2000DM008-2FR102_ZK206HAY-part1
B2=ata-ST2000DM006-2DM164_Z4ZBZE0A-part1
nocalls() { [ -z "$(grep -v mount-and-backup- $F/calls)" ]; }

echo "[1] 인자 없음 : 후보 표 + 복사해 쓸 명령, rc 0, 아무것도 안 함"
setup 2; export BACKUP_MOUNT_EUID=1001; runsut
chk "rc 0" '[ $RC = 0 ]'
chk "표에 두 하드" 'grep -q "sdb .*ext4 .*ZK206HAY .*$B1" <<<"$OUT" && grep -q "sdc .*Z4ZBZE0A .*$B2" <<<"$OUT"'
chk "예시 명령이 실제 탐지값" 'grep -q "sudo bash .*storage-backup-mount.sh $B1 $B2$" <<<"$OUT"'
chk "RAW, PRD 순 안내" 'grep -q "RAW, PRD 순으로" <<<"$OUT"'
chk "단계를 안 탐" '! grep -q "^\[1/7\]" <<<"$OUT"'
chk "호출 없음" 'nocalls && [ ! -e $F/code9.calls ]'
done_
setup 3; runsut
chk "3 장이면 앞 두 장 예시 + 경고" '[ $RC = 0 ] && grep -q "후보가 3 장" <<<"$OUT"'
done_

echo "[2] 인자 2 개 : 전 단계 (--no-start)"
setup 2; runsut $B1 $B2 --no-start
chk "rc 0" '[ $RC = 0 ]'
chk "RAW=sdb PRD=sdc" 'grep -q "RAW -> $T/mp1 = /dev/sdb  ZK206HAY" <<<"$OUT" && grep -q "PRD -> $T/mp2 = /dev/sdc  Z4ZBZE0A" <<<"$OUT"'
chk "mount -t ext4 by-id 직접" 'grep -q "^mount -t ext4 $T/byid/$B1 $T/mp1$" $F/calls && grep -q "^mount -t ext4 $T/byid/$B2 $T/mp2$" $F/calls'
chk "systemctl 호출 없음" '! grep -q "^systemctl" $F/calls'
chk "RENE_data_backup 생성 + chown" '[ -d $T/mp1/RENE_data_backup ] && [ -d $T/mp2/RENE_data_backup ] && grep -q "chown .* $T/mp1 $T/mp1/RENE_data_backup" $F/calls'
chk "dry-run raw/prd" 'grep -q -- "--disks $T/mp1 --only raw --dry-run" $F/code9.calls && grep -q -- "--disks $T/mp2 --only prd --dry-run" $F/code9.calls'
chk "--no-start 는 기동 안 함" '[ $(grep -vc -- --dry-run $F/code9.calls) = 0 ]'
chk "[n/7] 단계 7 개" '[ $(grep -cE "^\[[1-7]/7\]" <<<"$OUT") = 7 ]'
chk "OK 가 찍힌다" 'grep -q "  OK" <<<"$OUT"'
chk "로그 파일 (tee)" 'grep -q "\[6/7\]" $T/home/sykim/backup_log/mount-and-backup-*.log'
chk "요약 줄" 'grep -q "합계   : 런 1 개" <<<"$OUT"'
echo "  -- 같은 인자로 다시 : 이미 같은 장치면 건너뜀"
: > $F/calls; runsut $B1 $B2 --no-start
chk "rc 0 + 이미 마운트됨" '[ $RC = 0 ] && [ $(grep -c "이미 마운트됨" <<<"$OUT") = 2 ]'
chk "mount 다시 안 함" '! grep -q "^mount " $F/calls'
done_

echo "[3] 접두어 · 시리얼만 · 1 개"
setup 2; runsut /dev/disk/by-id/$B1 Z4ZBZE0A --no-start
chk "접두어+시리얼 받아들임" '[ $RC = 0 ] && grep -q "PRD -> $T/mp2 = /dev/sdc  Z4ZBZE0A" <<<"$OUT"'
done_
setup 2; runsut Z4ZBZE0A ZK206HAY --no-start
chk "순서대로 배정 (뒤바꿈)" '[ $RC = 0 ] && grep -q "RAW -> $T/mp1 = /dev/sdc" <<<"$OUT" && grep -q "PRD -> $T/mp2 = /dev/sdb" <<<"$OUT"'
done_
setup 2; runsut ZK206HAY --no-start
chk "1 개 : RAW 만" '[ $RC = 0 ] && grep -q "PRD 세션은 건너뜁니다" <<<"$OUT" && ! grep -q -- "--only prd" $F/code9.calls && [ ! -e $T/mp2/RENE_data_backup ]'
done_

echo "[4] 잘못된 인자"
setup 2; runsut ata-NOPE_XXXX-part1 --no-start
chk "없는 이름 FAIL" '[ $RC = 1 ] && grep -q "FAIL: ata-NOPE_XXXX-part1 에 해당하는 USB 하드가 없습니다" <<<"$OUT" && ! grep -q "^mount" $F/calls'
done_
setup 2; ln -s $T/dev/sdb1 $T/byid/ata-SYSTEMDISK_123-part1; runsut ata-SYSTEMDISK_123-part1 --no-start
chk "USB 아닌 by-id FAIL" '[ $RC = 1 ] && grep -q "USB 외장하드가 아닙니다" <<<"$OUT"'
done_
setup 2; runsut ZK206HAY ZK206HAY --no-start
chk "같은 하드 두 번 FAIL" '[ $RC = 1 ] && grep -q "두 번 주었습니다" <<<"$OUT"'
done_
setup 2; runsut a b c --no-start
chk "인자 3 개 FAIL" '[ $RC = 1 ] && grep -q "인자가 3 개" <<<"$OUT"'
done_
setup 2 ntfs; runsut $B1 $B2 --no-start
chk "ext4 아니면 FAIL" '[ $RC = 1 ] && grep -q "FAIL: /dev/sdc (Z4ZBZE0A) 의 첫 파티션이 ext4 가 아닙니다 (fs=ntfs)" <<<"$OUT" && ! grep -q "^mount" $F/calls'
done_

echo "[5] 다른 장치가 마운트지점에 붙어 있으면 FAIL + umount 안내"
setup 2; echo "$T/mp1 /dev/sdz1" > $F/mounts; runsut $B1 $B2 --no-start
chk "rc 1 + 안내" '[ $RC = 1 ] && grep -q "다른 장치(/dev/sdz1)" <<<"$OUT" && grep -q "umount $T/mp1  (안 되면 umount -l" <<<"$OUT"'
done_

echo "[6] 지난 회차 하드가 붙은 채"
setup 2
sed -i "s#NAME=\"sdb1\" TYPE=\"part\" FSTYPE=\"ext4\" MOUNTPOINT=\"\"#NAME=\"sdb1\" TYPE=\"part\" FSTYPE=\"ext4\" MOUNTPOINT=\"$T/mp2\"#" $F/parts
echo "$T/mp2 $T/dev/sdb1" > $F/mounts; cp $F/mounts $F/mounts.orig
runsut $B1 $B2 --no-start
chk "RAW 자리에 /backup_hdd_2 의 하드 → FAIL" '[ $RC = 1 ] && grep -q "이미 $T/mp2 에 마운트돼 있습니다" <<<"$OUT" && cmp -s $F/mounts $F/mounts.orig && ! grep -q "^mount" $F/calls'
runsut $B2 --no-start
chk "인자에 없는 하드가 RAW 자리… 아니면 통과" '[ $RC = 0 ]'
done_
setup 2
sed -i "s#NAME=\"sdb1\" TYPE=\"part\" FSTYPE=\"ext4\" MOUNTPOINT=\"\"#NAME=\"sdb1\" TYPE=\"part\" FSTYPE=\"ext4\" MOUNTPOINT=\"$T/mp1\"#" $F/parts
echo "$T/mp1 $T/dev/sdb1" > $F/mounts
runsut $B2 --no-start
chk "RAW 자리에 지난 회차 하드 FAIL" '[ $RC = 1 ] && grep -q "(지난 회차 하드?) 가 붙어 있습니다" <<<"$OUT" && ! grep -q "^mount" $F/calls'
runsut $B2 $B1 --no-start
chk "그 하드를 PRD 로 주면 바로 그 자리 아님 FAIL" '[ $RC = 1 ]'
runsut $B1 $B2 --no-start
chk "제자리 하드 + 새 하드 통과" '[ $RC = 0 ] && grep -q "이미 마운트됨" <<<"$OUT"'
done_

echo "[7] --dry-run 은 아무것도 안 바꾼다"
setup 2; runsut $B1 $B2 --dry-run
chk "rc 0" '[ $RC = 0 ]'
chk "mount·chown·code9 호출 없음" '! grep -v mount-and-backup- $F/calls | grep -qE "^(mount|chown|systemctl)" && [ ! -e $F/code9.calls ]'
chk "RENE_data_backup 안 만듦" '[ ! -e $T/mp1/RENE_data_backup ]'
chk "할 명령을 보인다" 'grep -q "(dry-run) \$ mount -t ext4 $T/byid/$B1 $T/mp1" <<<"$OUT"'
done_

echo "[8] 도는 세션이 있으면 FAIL"
setup 2; : > $T/home/sykim/backup_log/.backup.lock; export FAKE_FUSER=1; runsut $B1 $B2 --no-start
chk "잠금 보유자 FAIL" '[ $RC = 1 ] && grep -q "잠금을 쥐고" <<<"$OUT" && nocalls'
unset FAKE_FUSER
echo "21588 /bin/bash ./data_backup_simple_code9.sh --only raw" > $F/ps.txt
runsut $B1 $B2 --no-start
chk "ps 의 code9 FAIL" '[ $RC = 1 ] && grep -q "백업이 이미 돌고" <<<"$OUT"'
echo "777 grep data_backup_simple_code[0-9]*\.sh" > $F/ps.txt
runsut $B1 $B2 --no-start
chk "검사 문자열 자체는 안 잡는다" '[ $RC = 0 ]'
done_

echo "[9] root 가 아니면 안내"
setup 2; export BACKUP_MOUNT_EUID=1001; runsut $B1 $B2
chk "rc 1 + sudo 안내 (같은 인자)" '[ $RC = 1 ] && grep -q "root 로 실행해야" <<<"$OUT" && grep -q "sudo bash .* $B1 $B2" <<<"$OUT"'
chk "아무것도 안 함" 'nocalls'
done_

echo "[10] code9 dry-run 실패면 멈춘다"
setup 2; export FAKE_CODE9_RC=1; runsut $B1 $B2
chk "rc 1, 기동 없음" '[ $RC = 1 ] && grep -q "RAW dry-run 이 실패" <<<"$OUT" && [ $(grep -vc -- --dry-run $F/code9.calls) = 0 ]'
done_

echo "[11] 기동 : 서버 사슬이 맞으면 그것을"
setup 2
cat > $T/home/backup_raw_then_prd.sh <<X
#!/bin/bash
L=$T/home/sykim/backup_log
echo chain >> "\$L/chain.log"
$T/code9 --disks $T/mp1 --only raw > "\$L/code9.log" 2>&1
sleep 0
$T/code9 --disks $T/mp2 --only prd > "\$L/code9-prd.log" 2>&1
X
echo old > $T/home/sykim/backup_log/code9.log
runsut $B1 $B2
chk "rc 0 + 사슬 그대로" '[ $RC = 0 ] && grep -q "사슬 스크립트 그대로" <<<"$OUT"'
chk "code9 실행 (raw, prd)" 'grep -q -- "--only raw$" $F/code9.calls && grep -q -- "--only prd$" $F/code9.calls'
chk "지난 code9.log 보관" 'ls $T/home/sykim/backup_log/code9.log.prev-* >/dev/null 2>&1'
chk "세션 pid · 다음에 볼 것 · 떨어졌을 때 절차" 'grep -q "4343 " <<<"$OUT" && grep -q "다음에 볼 것" <<<"$OUT" && grep -q "ls -l /dev/disk/by-id | grep ata-" <<<"$OUT" && grep -q "sudo bash .* $B1 $B2$" <<<"$OUT"'
done_

echo "[12] 기동 : 사슬이 없으면 같은 동작을 직접 (1 개 인자)"
setup 2; runsut $B1
chk "rc 0" '[ $RC = 0 ]'
chk "inline 사슬 (PRD 없음) + 문법" 'f=$(ls $T/home/sykim/backup_log/chain-inline-*.sh) && bash -n $f && ! grep -q -- "--only prd" $f'
chk "RAW 세션 실행" 'grep -q -- "--disks $T/mp1 --only raw$" $F/code9.calls'
done_

echo "[13] 로그 폴더가 없으면 만든다"
setup 2; rm -rf $T/home/sykim/backup_log; runsut $B1 $B2 --dry-run
chk "rc 0 + 로그 생김" '[ $RC = 0 ] && ls $T/home/sykim/backup_log/mount-and-backup-*.log >/dev/null'
done_

echo "[14] -h · bash -n"
OUT=$(bash "$SUT" -h); chk "사용법 (새 방식)" 'grep -q -- "--dry-run" <<<"$OUT" && grep -q "by-id 이름 두 개" <<<"$OUT" && ! grep -q -- "--mountpoints" <<<"$OUT"'
chk "문법" 'bash -n "$SUT"'
chk "fstab 을 건드리는 코드 없음" '! grep -vE "^\s*#|echo" "$SUT" | grep -qE "/etc/fstab|daemon-reload"'

echo
echo "통과 $PASS / 실패 $FAILN"
[ $FAILN = 0 ]
