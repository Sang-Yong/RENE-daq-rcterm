#!/bin/bash
# tests/storage-backup-mount.test.sh -- scripts/storage-backup-mount.sh 의 시험
# root · 실하드 · 실 fstab · 실서버 · 메일을 건드리지 않는다.
# lsblk/udevadm/mount/mountpoint/findmnt/df/chown/systemctl/sudo/fuser/ps 를 PATH 앞의 가짜로,
# fstab·by-id·로그·code9·사슬 경로는 BACKUP_MOUNT_* 로 갈아끼운다.
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
	printf 'UUID=fe85 /  xfs defaults 0 0\nLABEL=data\t/data\text4\tdefaults\t0\t0\n' > "$T/fstab"
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
echo "mount $*" >> "$FAKE/calls"; mp=$1
dev=$(awk -v m="$mp" '$1 !~ /^#/ && $2==m {print $1}' "$BACKUP_MOUNT_FSTAB" | tail -1)
[ -z "$dev" ] && { echo "mount: $mp: can't find in fstab"; exit 1; }
echo "$mp $(readlink -f "$dev")" >> "$FAKE/mounts"
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
	export BACKUP_MOUNT_FSTAB=$T/fstab BACKUP_MOUNT_BYID=$T/byid BACKUP_MOUNT_HOME=$T/home \
	       BACKUP_MOUNT_LOGDIR=$T/home/sykim/backup_log BACKUP_MOUNT_CODE9=$T/code9 \
	       BACKUP_MOUNT_CHAIN=$T/home/backup_raw_then_prd.sh BACKUP_MOUNT_WAIT=1 \
	       BACKUP_MOUNT_EUID=0 BACKUP_MOUNT_USER=$(id -un)
	unset FAKE_FUSER FAKE_CODE9_RC
	MPS=(--mountpoints "$T/mp1" "$T/mp2")
}
runsut() { OUT=$(bash "$SUT" "$@" 2>&1); RC=$?; sleep 0.3; }
done_() { rm -rf "$T"; }

echo "[1] 2 장 탐지 · 배정 · 전 단계 (--no-start)"
setup 2; runsut "${MPS[@]}" --no-start
chk "rc 0" '[ $RC = 0 ]'
chk "RAW=sdb ZK206HAY" 'grep -q "RAW -> $T/mp1 = /dev/sdb  ZK206HAY" <<<"$OUT"'
chk "PRD=sdc Z4ZBZE0A" 'grep -q "PRD -> $T/mp2 = /dev/sdc  Z4ZBZE0A" <<<"$OUT"'
chk "by-id 줄 2 개" '[ $(grep -c "^$T/byid/ata-.*-part1  $T/mp[12]  ext4  defaults,nofail,x-systemd.device-timeout=10  0 2" $T/fstab) = 2 ]'
chk "fstab 백업" 'ls $T/fstab.bak-* >/dev/null 2>&1'
chk "daemon-reload" 'grep -q "systemctl daemon-reload" $F/calls'
chk "마운트 2 회" '[ $(grep -c "^mount " $F/calls) = 2 ]'
chk "RENE_data_backup 생성" '[ -d $T/mp1/RENE_data_backup ] && [ -d $T/mp2/RENE_data_backup ]'
chk "chown 호출" 'grep -q "chown .* $T/mp1 $T/mp1/RENE_data_backup" $F/calls'
chk "dry-run raw/prd" 'grep -q -- "--disks $T/mp1 --only raw --dry-run" $F/code9.calls && grep -q -- "--disks $T/mp2 --only prd --dry-run" $F/code9.calls'
chk "⑧ --no-start 는 기동 안 함" '[ $(grep -vc -- --dry-run $F/code9.calls) = 0 ]'
chk "⑨ [n/8] 단계 8 개" '[ $(grep -cE "^\[[1-8]/8\]" <<<"$OUT") = 8 ]'
chk "⑨ OK 가 찍힌다" 'grep -q "  OK" <<<"$OUT"'
chk "로그 파일 (tee)" 'ls $T/home/sykim/backup_log/mount-and-backup-*.log >/dev/null && grep -q "\[7/8\]" $T/home/sykim/backup_log/mount-and-backup-*.log'
chk "요약 줄을 보인다" 'grep -q "합계   : 런 1 개" <<<"$OUT"'

echo "[3] fstab idempotent (두 번째 실행)"
cp $T/fstab $T/fstab.first; : > $F/mounts
runsut "${MPS[@]}" --no-start
chk "rc 0" '[ $RC = 0 ]'
chk "줄이 그대로 (diff 없음)" 'cmp -s $T/fstab $T/fstab.first'
chk "바꿀 것 없음 안내" 'grep -q "바꿀 것 없음" <<<"$OUT"'
done_

echo "[3b] 같은 마운트지점의 옛 줄은 주석으로"
setup 2; printf '/dev/sdx1 %s ext4 defaults 0 0\n' "$T/mp1" >> $T/fstab
runsut "${MPS[@]}" --no-start
chk "옛 줄 주석" 'grep -q "^#(storage-backup-mount .*) /dev/sdx1 $T/mp1" $T/fstab'
chk "주석 안 된 mp1 줄은 by-id 하나" '[ $(grep -v "^#" $T/fstab | awk -v m=$T/mp1 "\$2==m" | wc -l) = 1 ]'
runsut "${MPS[@]}" --no-start
chk "다시 돌려도 mp1 줄 1 개" '[ $(grep -v "^#" $T/fstab | awk -v m=$T/mp1 "\$2==m" | wc -l) = 1 ] && [ $(grep -c "^#(storage-backup-mount" $T/fstab) = 1 ]'
done_

echo "[2] --raw / --prd 지정 (뒤바꾸기)"
setup 2; runsut "${MPS[@]}" --no-start --raw Z4ZBZE0A --prd ZK206HAY
chk "RAW=sdc" 'grep -q "RAW -> $T/mp1 = /dev/sdc  Z4ZBZE0A" <<<"$OUT"'
chk "PRD=sdb" 'grep -q "PRD -> $T/mp2 = /dev/sdb  ZK206HAY" <<<"$OUT"'
chk "fstab mp1 = Z4ZBZE0A" 'grep -q "Z4ZBZE0A-part1  $T/mp1 " $T/fstab'
done_
setup 2; runsut "${MPS[@]}" --no-start --raw NOPE
chk "없는 시리얼이면 FAIL" '[ $RC = 1 ] && grep -q "FAIL: --raw NOPE" <<<"$OUT"'
done_

echo "[4] --dry-run 은 fstab·mount·chown 을 안 건드린다"
setup 2; cp $T/fstab $T/fstab.orig; runsut "${MPS[@]}" --dry-run
chk "rc 0" '[ $RC = 0 ]'
chk "fstab 그대로" 'cmp -s $T/fstab $T/fstab.orig && ! ls $T/fstab.bak-* >/dev/null 2>&1'
chk "mount·chown·systemctl·code9 호출 없음" '! grep -v mount-and-backup- $F/calls | grep -qE "^(mount|chown|systemctl)" && [ ! -e $F/code9.calls ]'
chk "RENE_data_backup 안 만듦" '[ ! -e $T/mp1/RENE_data_backup ]'
chk "할 명령을 보인다" 'grep -q "(dry-run) \$ mount $T/mp1" <<<"$OUT"'
chk "탐지는 실제로" 'grep -q "ZK206HAY" <<<"$OUT"'
done_

echo "[5] ext4 아니면 FAIL"
setup 2 ntfs; cp $T/fstab $T/fstab.orig; runsut "${MPS[@]}" --no-start
chk "rc 1 + 사유" '[ $RC = 1 ] && grep -q "FAIL: /dev/sdc (Z4ZBZE0A) 의 첫 파티션이 ext4 가 아닙니다 (fs=ntfs)" <<<"$OUT"'
chk "fstab 그대로" 'cmp -s $T/fstab $T/fstab.orig'
done_

echo "[6] 3 장이면 FAIL"
setup 3; runsut "${MPS[@]}" --no-start
chk "rc 1" '[ $RC = 1 ] && grep -q "USB 하드가 3 장" <<<"$OUT"'
runsut "${MPS[@]}" --no-start --raw ZK206HAY --prd Z4ZBZE0A
chk "지정하면 된다" '[ $RC = 0 ]'
done_

echo "[7] 도는 세션이 있으면 FAIL"
setup 2; : > $T/home/sykim/backup_log/.backup.lock; export FAKE_FUSER=1; runsut "${MPS[@]}" --no-start
chk "잠금 보유자 FAIL" '[ $RC = 1 ] && grep -q "잠금을 쥐고" <<<"$OUT" && [ -z "$(grep -v mount-and-backup- $F/calls)" ]'
unset FAKE_FUSER
echo "21588 /bin/bash ./data_backup_simple_code9.sh --only raw" > $F/ps.txt
runsut "${MPS[@]}" --no-start
chk "ps 의 code9 FAIL" '[ $RC = 1 ] && grep -q "백업이 이미 돌고" <<<"$OUT"'
echo "777 grep data_backup_simple_code[0-9]*\.sh" > $F/ps.txt
runsut "${MPS[@]}" --no-start
chk "검사 문자열 자체는 안 잡는다" '[ $RC = 0 ]'
done_

echo "[10] root 가 아니면 안내"
setup 2; export BACKUP_MOUNT_EUID=1001; runsut "${MPS[@]}"
chk "rc 1 + sudo 안내" '[ $RC = 1 ] && grep -q "root 로 실행해야" <<<"$OUT" && grep -q "sudo bash" <<<"$OUT"'
chk "아무것도 안 함" '[ -z "$(grep -v mount-and-backup- $F/calls)" ]'
done_

echo "[11] 1 장 : RAW 만, PRD 건너뜀"
setup 1; runsut "${MPS[@]}" --no-start
chk "rc 0 + 경고" '[ $RC = 0 ] && grep -q "PRD 세션은 건너뜁니다" <<<"$OUT"'
chk "prd dry-run 없음" '! grep -q -- "--only prd" $F/code9.calls'
done_

echo "[12] 다른 장치가 마운트돼 있으면(유령) FAIL"
setup 2; echo "$T/mp1 /dev/sdz1" > $F/mounts; runsut "${MPS[@]}" --no-start
chk "rc 1 + umount 안내" '[ $RC = 1 ] && grep -q "다른 장치(/dev/sdz1)" <<<"$OUT" && grep -q "umount -l" <<<"$OUT"'
done_

echo "[13] code9 dry-run 실패면 멈춘다"
setup 2; export FAKE_CODE9_RC=1; runsut "${MPS[@]}"
chk "rc 1, 기동 없음" '[ $RC = 1 ] && grep -q "RAW dry-run 이 실패" <<<"$OUT" && [ $(grep -vc -- --dry-run $F/code9.calls) = 0 ]'
done_

echo "[14] 기동 : 서버 사슬이 맞으면 그것을"
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
runsut "${MPS[@]}"
chk "rc 0" '[ $RC = 0 ]'
chk "사슬 그대로" 'grep -q "사슬 스크립트 그대로" <<<"$OUT"'
chk "code9 실행 (raw, prd)" 'grep -q -- "--only raw$" $F/code9.calls && grep -q -- "--only prd$" $F/code9.calls'
chk "지난 code9.log 보관" 'ls $T/home/sykim/backup_log/code9.log.prev-* >/dev/null 2>&1'
chk "세션 pid 와 다음에 볼 것" 'grep -q "4343 " <<<"$OUT" && grep -q "다음에 볼 것" <<<"$OUT"'
done_

echo "[15] 기동 : 사슬이 없으면 같은 동작을 직접"
setup 2; runsut "${MPS[@]}"
chk "rc 0" '[ $RC = 0 ]'
chk "inline 사슬 파일" 'ls $T/home/sykim/backup_log/chain-inline-*.sh >/dev/null && grep -q "sleep 30" $T/home/sykim/backup_log/chain-inline-*.sh'
chk "inline 문법" 'bash -n $T/home/sykim/backup_log/chain-inline-*.sh'
chk "RAW 세션 실행" 'grep -q -- "--disks $T/mp1 --only raw$" $F/code9.calls'
chk "chain.log 시작 줄" 'grep -q "chain start (storage-backup-mount)" $T/home/sykim/backup_log/chain.log'
done_

echo "[18] 임시 파일을 못 만들면 fstab 은 바이트 그대로 (리뷰 1-1)"
setup 2; cp -p $T/fstab $T/fstab.orig
OUT=$(TMPDIR=/nonexistent-dir bash "$SUT" "${MPS[@]}" --no-start 2>&1); RC=$?
chk "rc 1 + 손대지 않았다" '[ $RC = 1 ] && grep -q "임시 파일을 만들 수 없습니다" <<<"$OUT"'
chk "fstab 바이트 동일" 'cmp -s $T/fstab $T/fstab.orig'
chk "mount 안 함" '! grep -q "^mount " $F/calls'
done_

echo "[19] 정상 실행 뒤 '/' · '/data' 줄이 바이트 그대로 (리뷰 1-2)"
setup 2; grep -v '^#' $T/fstab > $T/sys.lines
runsut "${MPS[@]}" --no-start
chk "rc 0" '[ $RC = 0 ]'
chk "시스템 줄 보존" 'while IFS= read -r l; do grep -Fxq -- "$l" $T/fstab || exit 1; done < $T/sys.lines'
chk "LABEL=data 탭 줄 그대로" 'grep -qP "^LABEL=data\t/data\text4\tdefaults\t0\t0$" $T/fstab'
chk "스테이징 파일 안 남음" '! ls $T/fstab.new-* >/dev/null 2>&1'
done_

echo "[20] 같은 장치·마운트지점 줄이라도 nofail 이 없으면 바꾼다 (리뷰 2)"
setup 1; printf '%s %s ext4 defaults 0 0\n' "$T/byid/ata-ST2000DM008-2FR102_ZK206HAY-part1" "$T/mp1" >> $T/fstab
runsut "${MPS[@]}" --no-start
chk "rc 0" '[ $RC = 0 ]'
chk "옛 줄 주석" 'grep -q "^#(storage-backup-mount .*) $T/byid/ata-ST2000DM008-2FR102_ZK206HAY-part1 $T/mp1 ext4 defaults 0 0" $T/fstab'
chk "살아 있는 mp1 줄은 nofail 하나" '[ "$(grep -v "^#" $T/fstab | awk -v m=$T/mp1 "\$2==m" | grep -c nofail)" = 1 ] && [ "$(grep -v "^#" $T/fstab | awk -v m=$T/mp1 "\$2==m" | wc -l)" = 1 ]'
done_

echo "[21] 지난 회차 하드가 우리 마운트지점에 붙은 채면 fstab 전에 멈춘다 (리뷰 3)"
setup 2
sed -i "s#NAME=\"sdb1\" TYPE=\"part\" FSTYPE=\"ext4\" MOUNTPOINT=\"\"#NAME=\"sdb1\" TYPE=\"part\" FSTYPE=\"ext4\" MOUNTPOINT=\"$T/mp2\"#" $F/parts
echo "$T/mp2 $T/dev/sdb1" > $F/mounts
cp -p $T/fstab $T/fstab.orig; cp $F/mounts $F/mounts.orig
runsut "${MPS[@]}" --no-start
chk "rc 1 + 지난 회차 안내" '[ $RC = 1 ] && grep -q "에 /dev/sdb ZK206HAY (지난 회차 하드?) 가 붙어 있는데" <<<"$OUT" && grep -q "umount $T/mp2" <<<"$OUT"'
chk "fstab 바이트 동일" 'cmp -s $T/fstab $T/fstab.orig'
chk "마운트 그대로 (두 번 붙이지 않음)" 'cmp -s $F/mounts $F/mounts.orig && ! grep -q "^mount " $F/calls'
chk "[3/8] 에 안 감" '! grep -q "^\[3/8\]" <<<"$OUT"'
chk "표에 지금 마운트 표시" 'grep -q "sdb .*ZK206HAY .*$T/mp2" <<<"$OUT"'
runsut "${MPS[@]}" --no-start --raw Z4ZBZE0A --prd ZK206HAY
chk "지금 마운트와 맞게 지정하면 된다" '[ $RC = 0 ] && grep -q "이미 $T/mp2 에 붙어 있고 배정과 같습니다" <<<"$OUT"'
done_

echo "[22] 로그 폴더가 없으면 만든다"
setup 2; rm -rf $T/home/sykim/backup_log; runsut "${MPS[@]}" --dry-run
chk "rc 0 + 로그 생김" '[ $RC = 0 ] && ls $T/home/sykim/backup_log/mount-and-backup-*.log >/dev/null'
done_

echo "[16] -h"
OUT=$(bash "$SUT" -h); chk "사용법" 'grep -q -- "--dry-run" <<<"$OUT"'

echo "[17] bash -n"
chk "문법" 'bash -n "$SUT"'

echo
echo "통과 $PASS / 실패 $FAILN"
[ $FAILN = 0 ]
