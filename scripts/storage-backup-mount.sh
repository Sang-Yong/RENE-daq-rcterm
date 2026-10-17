#!/bin/bash
# =====================================================================
#  storage-backup-mount.sh  --  저장소 서버(ssh store)에서 root 로 한 번 실행
#
#  새 외장하드 두 장(독 2 베이)을 꽂은 뒤 이것 하나로 :
#    1 전제 확인 (root · 도는 백업 세션 없음)
#    2 USB 하드 탐지 -> 제조사 시리얼로 by-id 경로 (ata-<모델>_<시리얼>-part1)
#    3 /etc/fstab 에 by-id 줄 (백업 · 옛 줄은 주석 · 두 번 돌려도 한 줄)
#    4 마운트 + 장치 대조 (§11.124 유령 마운트)
#    5 RENE_data_backup 만들고 frontend 소유로 (§11.148)
#    6 하드 내용 확인 (빈 하드인가)
#    7 frontend 로 code9 --only raw / --only prd 의 --dry-run
#    8 frontend 로 RAW -> PRD 사슬 기동 (backup_raw_then_prd.sh)
#
#  단계마다 [n/8] · 실행한 명령 · 그 출력 · OK / FAIL 을 찍는다. FAIL 이면 거기서 멈춘다.
#  출력은 화면과 /home/frontend/sykim/backup_log/mount-and-backup-<시각>.log 둘 다.
#
#  쓰는 법
#    sudo bash storage-backup-mount.sh --dry-run      # 아무것도 바꾸지 않는다 (탐지는 실제로)
#    sudo bash storage-backup-mount.sh                # 마운트 + dry-run + 백업 기동
#    sudo bash storage-backup-mount.sh --no-start     # 마운트 · 권한 · dry-run 까지만
#    sudo bash storage-backup-mount.sh --raw ZK206HAY --prd Z4ZBZE0A
#
#  ★ 포맷은 하지 않는다. ext4 가 아니면 멈춘다 (포맷은 사람이 정한다)
#  ★ 하드가 떨어지면 : umount -l <마운트> -> e2fsck -f -> 이 스크립트 다시 (§11.180)
#  ★ 프로세스 검사에 pgrep -f 를 쓰지 않는다 (§11.142 의 3)
# =====================================================================

MP_RAW=/backup_hdd
MP_PRD=/backup_hdd_2
WANT_RAW=""; WANT_PRD=""
DRYRUN=0; NOSTART=0
ORIG_ARGS="$*"

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run)     DRYRUN=1; shift ;;
		--no-start)    NOSTART=1; shift ;;
		--raw)         WANT_RAW=$2; shift 2 ;;
		--prd)         WANT_PRD=$2; shift 2 ;;
		--mountpoints) MP_RAW=$2; MP_PRD=$3; shift 3 ;;
		-h|--help)     usage; exit 0 ;;
		*) echo "알 수 없는 옵션 : $1  (-h 로 사용법)"; exit 2 ;;
	esac
done

# ---- 갈아끼울 수 있는 경로 (시험용. 실서버에서는 기본값 그대로) ----
FSTAB=${BACKUP_MOUNT_FSTAB:-/etc/fstab}
BYID=${BACKUP_MOUNT_BYID:-/dev/disk/by-id}
BUSER=${BACKUP_MOUNT_USER:-frontend}
UHOME=${BACKUP_MOUNT_HOME:-/home/$BUSER}
LOGDIR=${BACKUP_MOUNT_LOGDIR:-$UHOME/sykim/backup_log}
CODE9=${BACKUP_MOUNT_CODE9:-$UHOME/data_backup_simple_code9.sh}
CHAIN=${BACKUP_MOUNT_CHAIN:-$UHOME/backup_raw_then_prd.sh}
LOCK=${BACKUP_MOUNT_LOCK:-$LOGDIR/.backup.lock}
WAIT_S=${BACKUP_MOUNT_WAIT:-10}
MY_EUID=${BACKUP_MOUNT_EUID:-$EUID}

TS=$(date +%Y%m%d-%H%M%S)
STAMP=$(date '+%Y-%m-%d %H:%M')

if [ -t 1 ]; then C_OK=$'\e[32m'; C_NG=$'\e[31;1m'; C_WR=$'\e[33;1m'; C_HD=$'\e[36;1m'; C_0=$'\e[0m'
else C_OK=""; C_NG=""; C_WR=""; C_HD=""; C_0=""; fi

# 화면 + 로그 파일 (로그 디렉터리가 없으면 화면만)
LOGFILE=""
if mkdir -p "$LOGDIR" 2>/dev/null && touch "$LOGDIR/mount-and-backup-$TS.log" 2>/dev/null; then
	LOGFILE=$LOGDIR/mount-and-backup-$TS.log
	exec > >(tee -a "$LOGFILE") 2>&1
fi

NSTEP=8
step() { echo; echo "${C_HD}[$1/$NSTEP] $2${C_0}"; }
ok()   { echo "  ${C_OK}OK${C_0}${1:+ : $1}"; }
warn() { echo "  ${C_WR}★ 경고 : $*${C_0}"; }
fail() {
	echo "  ${C_NG}FAIL: $1${C_0}"
	shift
	local l; for l in "$@"; do echo "        $l"; done
	echo
	echo "${C_NG}여기서 멈췄습니다.${C_0} 위 FAIL 을 고친 뒤 같은 명령을 다시 실행하세요 (이미 된 단계는 건너뜁니다)."
	[ -n "$LOGFILE" ] && echo "로그 : $LOGFILE"
	exit 1
}
# 명령을 보여 주고 실행한다. 출력은 들여쓴다. 반환값 = 명령의 rc
run() {
	echo "  \$ $*"
	local out rc
	out=$("$@" 2>&1); rc=$?
	[ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/    /'
	return $rc
}
# 바꾸는 명령 : --dry-run 이면 보여 주기만 한다
act() {
	if [ "$DRYRUN" = 1 ]; then echo "  (dry-run) \$ $*"; return 0; fi
	run "$@"
}

echo "=========================================================="
echo "  외장하드 마운트 + 백업 기동   ($STAMP)"
[ "$DRYRUN" = 1 ] && echo "  ★ --dry-run : 아무것도 바꾸지 않습니다. 할 명령만 보여 줍니다."
[ "$NOSTART" = 1 ] && echo "  ★ --no-start : dry-run 까지만 하고 백업은 띄우지 않습니다."
echo "  RAW 하드 -> $MP_RAW    PRD 하드 -> $MP_PRD"
[ -n "$LOGFILE" ] && echo "  로그 : $LOGFILE"
echo "=========================================================="

# =====================================================================
step 1 "전제 확인 : root 인가 · 이미 도는 백업 세션이 없는가"
# =====================================================================
echo "  \$ id -u   ->  $MY_EUID"
if [ "$MY_EUID" != 0 ]; then
	if [ "$DRYRUN" = 1 ]; then
		warn "root 가 아니지만 --dry-run 이라 계속합니다 (아무것도 바꾸지 않음)."
	else
		fail "root 로 실행해야 합니다" "sudo bash $0 $ORIG_ARGS" "(미리 보기만 하려면 --dry-run)"
	fi
fi

# 내 조상 pid (ps 결과에서 뺀다)
ANC=" $$ "
p=$$
while [ -n "$p" ] && [ "$p" != 0 ] && [ "$p" != 1 ]; do
	p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
	[ -n "$p" ] && ANC="$ANC$p "
done

echo "  \$ fuser $LOCK"
if [ -e "$LOCK" ] && fuser "$LOCK" >/dev/null 2>&1; then
	holders=$(fuser "$LOCK" 2>/dev/null | tr -s ' ')
	fail "백업 세션이 이미 잠금을 쥐고 있습니다 (pid$holders)" \
	     "도는 세션이 끝난 뒤 다시 실행하세요. 세우려면 : kill -TERM <pid>"
fi
echo "    (잠금을 쥔 프로세스 없음)"

echo "  \$ ps -eo pid,args | (data_backup_simple_code*.sh · storage-backup.sh · backup_raw_then_prd.sh)"
# 정규식이 자기 자신(awk 의 인자 문자열)에는 맞지 않게 쓴다 : 'code[0-9]*\.sh' 는 'code[0-9]*\.sh' 글자에 안 맞는다
running=$(ps -eo pid=,args= 2>/dev/null | awk -v anc="$ANC" '
	$0 ~ /data_backup_simple_code[0-9]*\.sh|storage-backup\.sh|backup_raw_then_prd\.sh/ {
		if (index(anc, " " $1 " ") == 0) print
	}')
if [ -n "$running" ]; then
	printf '%s\n' "$running" | sed 's/^/    /'
	fail "백업이 이미 돌고 있습니다" "위 프로세스가 끝난 뒤 다시 실행하세요 (§11.141)."
fi
echo "    (도는 백업 없음)"
ok "root · 도는 세션 없음"

# =====================================================================
step 2 "USB 하드 탐지 : 제조사 시리얼로 by-id 경로 찾기"
# =====================================================================
kv() { sed -n "s/.*\\b$1=\"\\([^\"]*\\)\".*/\\1/p" <<<"$2"; }

run lsblk -o NAME,SIZE,TRAN,TYPE,FSTYPE,MOUNTPOINT,MODEL
DISKS=$(lsblk -d -n -P -o NAME,TRAN,TYPE,SIZE,MODEL 2>/dev/null)
PARTS=$(lsblk -n -P -o NAME,TYPE,FSTYPE,MOUNTPOINT,PKNAME 2>/dev/null)
[ -z "$DISKS" ] && fail "lsblk 가 아무것도 내지 않았습니다"

# 후보 : TRAN=usb · TYPE=disk · 그 파티션이 우리 마운트지점 밖에 마운트돼 있지 않은 것
CAND=()
while IFS= read -r line; do
	[ -z "$line" ] && continue
	[ "$(kv TRAN "$line")" = usb ] || continue
	[ "$(kv TYPE "$line")" = disk ] || continue
	nm=$(kv NAME "$line")
	busy=""
	while IFS= read -r pl; do
		[ "$(kv PKNAME "$pl")" = "$nm" ] || continue
		m=$(kv MOUNTPOINT "$pl")
		[ -z "$m" ] && continue
		[ "$m" = "$MP_RAW" ] || [ "$m" = "$MP_PRD" ] && continue
		busy=$m
	done <<<"$PARTS"
	if [ -n "$busy" ]; then echo "    ($nm 는 $busy 에 마운트된 시스템/다른 디스크라 뺍니다)"; continue; fi
	CAND+=("$nm")
done <<<"$DISKS"

[ ${#CAND[@]} -eq 0 ] && fail "USB 하드를 찾지 못했습니다" "독 전원·케이블을 보고 'lsblk' 에 TRAN=usb 디스크가 보이는지 확인하세요."

declare -A SER MOD LINK DEV FST SIZ
echo
printf '  %-6s %-6s %-20s %-10s %-6s %s\n' "장치" "크기" "모델" "시리얼" "fs" "by-id"
for nm in "${CAND[@]}"; do
	props=$(udevadm info --query=property --name="/dev/$nm" 2>/dev/null)
	s=$(sed -n 's/^ID_SERIAL_SHORT=//p' <<<"$props" | head -1)
	md=$(sed -n 's/^ID_MODEL=//p' <<<"$props" | head -1)
	[ -z "$s" ] && fail "/dev/$nm 의 시리얼을 udevadm 이 주지 않습니다" "udevadm info --query=property --name=/dev/$nm"
	lk=""
	[ -n "$md" ] && [ -e "$BYID/ata-${md}_${s}-part1" ] && lk="$BYID/ata-${md}_${s}-part1"
	if [ -z "$lk" ]; then
		# 모델 글자가 다를 때 : 시리얼로만 찾는다
		lk=$(ls -1 "$BYID" 2>/dev/null | grep -E "^ata-.*_${s}-part1\$" | head -1)
		[ -n "$lk" ] && lk="$BYID/$lk"
	fi
	[ -z "$lk" ] && fail "/dev/$nm ($s) 의 by-id 첫 파티션 링크가 없습니다" \
		"ls -l $BYID | grep $s" "파티션이 없는 하드라면 파티션·포맷(ext4)은 사람이 정합니다 — 이 스크립트는 포맷하지 않습니다."
	dv=$(readlink -f "$lk")
	fs=""
	while IFS= read -r pl; do
		[ "$(kv NAME "$pl")" = "$(basename "$dv")" ] && fs=$(kv FSTYPE "$pl")
	done <<<"$PARTS"
	sz=$(kv SIZE "$(grep "NAME=\"$nm\"" <<<"$DISKS")")
	SER[$nm]=$s; MOD[$nm]=$md; LINK[$nm]=$lk; DEV[$nm]=$dv; FST[$nm]=$fs; SIZ[$nm]=$sz
	printf '  %-6s %-6s %-20s %-10s %-6s %s\n' "$nm" "$sz" "${md:-?}" "$s" "${fs:-없음}" "$lk"
done
echo

find_by_serial() { local n; for n in "${CAND[@]}"; do [ "${SER[$n]}" = "$1" ] && { echo "$n"; return 0; }; done; return 1; }

RAWD=""; PRDD=""
if [ -n "$WANT_RAW" ]; then RAWD=$(find_by_serial "$WANT_RAW") || fail "--raw $WANT_RAW 시리얼의 하드가 없습니다" "위 표의 시리얼을 쓰세요."; fi
if [ -n "$WANT_PRD" ]; then PRDD=$(find_by_serial "$WANT_PRD") || fail "--prd $WANT_PRD 시리얼의 하드가 없습니다" "위 표의 시리얼을 쓰세요."; fi
[ -n "$RAWD" ] && [ "$RAWD" = "$PRDD" ] && fail "--raw 와 --prd 가 같은 하드입니다"

if [ -z "$WANT_RAW" ] && [ -z "$WANT_PRD" ]; then
	if [ ${#CAND[@]} -gt 2 ]; then
		fail "USB 하드가 ${#CAND[@]} 장입니다. 어느 것을 쓸지 정해 주세요" "--raw <시리얼> --prd <시리얼>"
	fi
	RAWD=${CAND[0]}
	[ ${#CAND[@]} -eq 2 ] && PRDD=${CAND[1]}
elif [ -z "$WANT_PRD" ]; then
	rest=(); for n in "${CAND[@]}"; do [ "$n" != "$RAWD" ] && rest+=("$n"); done
	[ ${#rest[@]} -gt 1 ] && fail "남은 하드가 ${#rest[@]} 장이라 PRD 하드를 정할 수 없습니다" "--prd <시리얼> 도 주세요."
	[ ${#rest[@]} -eq 1 ] && PRDD=${rest[0]}
elif [ -z "$WANT_RAW" ]; then
	rest=(); for n in "${CAND[@]}"; do [ "$n" != "$PRDD" ] && rest+=("$n"); done
	[ ${#rest[@]} -ne 1 ] && fail "RAW 하드를 정할 수 없습니다 (남은 하드 ${#rest[@]} 장)" "--raw <시리얼> 도 주세요."
	RAWD=${rest[0]}
fi

for n in $RAWD $PRDD; do
	[ "${FST[$n]}" = ext4 ] || fail "/dev/$n (${SER[$n]}) 의 첫 파티션이 ext4 가 아닙니다 (fs=${FST[$n]:-없음})" \
		"포맷은 하지 않습니다. 포맷할지(자료가 지워진다)는 사람이 정합니다 :" \
		"  mkfs.ext4 ${DEV[$n]}   (★ 하드의 자료가 전부 지워진다)"
done

echo "  배정 : RAW -> $MP_RAW = /dev/$RAWD  ${SER[$RAWD]}  (${MOD[$RAWD]})"
if [ -n "$PRDD" ]; then
	echo "         PRD -> $MP_PRD = /dev/$PRDD  ${SER[$PRDD]}  (${MOD[$PRDD]})"
else
	warn "하드가 1 장입니다. RAW 만 하고 PRD 세션은 건너뜁니다."
fi
ok "탐지 ${#CAND[@]} 장"

PAIRS=("$MP_RAW:$RAWD")
[ -n "$PRDD" ] && PAIRS+=("$MP_PRD:$PRDD")

# =====================================================================
step 3 "/etc/fstab 에 by-id 줄 넣기 (백업 · 옛 줄 주석 · 이미 있으면 그대로)"
# =====================================================================
OPTS="defaults,nofail,x-systemd.device-timeout=10"
[ -f "$FSTAB" ] || fail "$FSTAB 가 없습니다"
NEW=$(mktemp); cp -p "$FSTAB" "$NEW"
for pr in "${PAIRS[@]}"; do
	mp=${pr%%:*}; n=${pr#*:}; lk=${LINK[$n]}
	tmp=$(mktemp)
	# 같은 마운트지점 · 같은 장치의 다른 줄은 주석으로. 같은 줄(장치+마운트지점)이 있으면 둔다
	awk -v mp="$mp" -v lk="$lk" -v tag="#(storage-backup-mount $STAMP) " '
		BEGIN { have = 0 }
		/^[[:space:]]*#/ || NF < 2 { print; next }
		$1 == lk && $2 == mp && have == 0 { have = 1; print; next }
		$2 == mp || $1 == lk { print tag $0; next }
		{ print }
		END { if (have == 0) exit 3 }' "$NEW" > "$tmp"
	rc=$?
	if [ $rc = 3 ]; then printf '%s  %s  ext4  %s  0 2\n' "$lk" "$mp" "$OPTS" >> "$tmp"; fi
	cat "$tmp" > "$NEW"; rm -f "$tmp"
done
if cmp -s "$FSTAB" "$NEW"; then
	echo "  (바꿀 것 없음 : 두 줄이 이미 있습니다)"
	rm -f "$NEW"
else
	echo "  \$ diff -u $FSTAB (새 내용)"
	diff -u "$FSTAB" "$NEW" | sed 's/^/    /'
	act cp -p "$FSTAB" "$FSTAB.bak-$TS" || fail "fstab 백업 실패"
	if [ "$DRYRUN" = 1 ]; then
		echo "  (dry-run) \$ (위 diff 대로 $FSTAB 를 고친다)"
	else
		echo "  \$ (위 diff 대로 $FSTAB 를 고친다)"
		cat "$NEW" > "$FSTAB" || fail "$FSTAB 쓰기 실패"
	fi
	rm -f "$NEW"
	act systemctl daemon-reload || fail "systemctl daemon-reload 실패"
fi
ok "fstab"

# =====================================================================
step 4 "마운트 (fstab 경유) 와 장치 대조"
# =====================================================================
for pr in "${PAIRS[@]}"; do
	mp=${pr%%:*}; n=${pr#*:}; dv=${DEV[$n]}
	[ -d "$mp" ] || act mkdir -p "$mp" || fail "$mp 를 만들 수 없습니다"
	if mountpoint -q "$mp" 2>/dev/null; then
		src=$(findmnt -n -o SOURCE "$mp" 2>/dev/null)
		echo "  \$ findmnt -n -o SOURCE $mp   ->  $src  (이미 마운트됨)"
		if [ "$src" != "$dv" ]; then
			fail "$mp 에 다른 장치($src)가 마운트돼 있습니다. 기대 : $dv (${SER[$n]})" \
				"떨어졌다 다시 붙은 유령 마운트일 수 있습니다 (§11.124)." \
				"umount -l $mp  ->  e2fsck -f $dv  ->  이 스크립트 다시"
		fi
		[ -e "$src" ] || fail "$mp 의 장치 $src 가 /dev 에 없습니다 (유령 마운트)" "umount -l $mp 뒤 다시"
	else
		act mount "$mp" || fail "mount $mp 실패" "dmesg | tail -20 으로 사유를 보세요."
		if [ "$DRYRUN" = 0 ]; then
			src=$(findmnt -n -o SOURCE "$mp" 2>/dev/null)
			echo "  \$ findmnt -n -o SOURCE $mp   ->  $src"
			[ "$src" = "$dv" ] || fail "마운트된 장치($src)가 기대($dv)와 다릅니다"
		fi
	fi
	[ "$DRYRUN" = 0 ] && run df -h "$mp"
done
ok "마운트"

# =====================================================================
step 5 "권한 : RENE_data_backup 을 만들고 $BUSER 소유로"
# =====================================================================
for pr in "${PAIRS[@]}"; do
	mp=${pr%%:*}; d=$mp/RENE_data_backup
	act mkdir -p "$d" || fail "$d 를 만들 수 없습니다" "읽기 전용으로 붙었을 수 있습니다 : findmnt -o OPTIONS $mp"
	act chown "$BUSER:$BUSER" "$mp" "$d" || fail "chown 실패"
	if [ "$DRYRUN" = 0 ]; then
		echo "  \$ sudo -u $BUSER test -w $d"
		sudo -u "$BUSER" test -w "$d" || fail "$BUSER 가 $d 에 쓸 수 없습니다" "findmnt -o OPTIONS $mp  (ro 인가)"
		echo "    (쓰기 가능)"
	fi
done
ok "권한"

# =====================================================================
step 6 "하드 내용 확인 (빈 하드인가)"
# =====================================================================
if [ "$DRYRUN" = 1 ]; then
	echo "  (dry-run) 마운트 전이라 볼 수 없습니다 — 실제 실행에서 ls -A 로 봅니다."
else
	for pr in "${PAIRS[@]}"; do
		mp=${pr%%:*}; d=$mp/RENE_data_backup
		run ls -A "$mp"
		other=$(ls -A "$mp" 2>/dev/null | grep -v -x -e lost+found -e RENE_data_backup)
		if [ -n "$other" ]; then
			warn "$mp 에 lost+found · RENE_data_backup 밖의 것이 있습니다 : $(echo $other)"
			warn "새 하드가 아닐 수 있습니다. 멈추지는 않습니다 (code9 는 이미 담긴 런을 건너뛴다)."
		fi
		nrun=$(find "$d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
		if [ "$nrun" -gt 0 ]; then
			warn "$d 에 런 폴더가 $nrun 개 있습니다 ($(du -sh "$d" 2>/dev/null | cut -f1)). 이어 담는 하드입니다."
		else
			echo "    ($d 는 비어 있음)"
		fi
	done
fi
ok "내용 확인"

# =====================================================================
step 7 "$BUSER 로 백업 계획 미리 보기 (code9 --dry-run)"
# =====================================================================
[ -x "$CODE9" ] || fail "$CODE9 가 없거나 실행할 수 없습니다"
dry9() {   # $1 = 마운트, $2 = raw|prd
	local cmd=(sudo -u "$BUSER" "$CODE9" --disks "$1" --only "$2" --dry-run)
	if [ "$DRYRUN" = 1 ]; then echo "  (dry-run) \$ ${cmd[*]}   (마운트 뒤에 돈다)"; return 0; fi
	echo "  \$ ${cmd[*]}"
	local out rc
	out=$("${cmd[@]}" 2>&1); rc=$?
	[ -n "$LOGFILE" ] && printf '%s\n' "$out" >> "$LOGFILE.code9-dryrun"
	printf '%s\n' "$out" | grep -E '쓰기|담는 종류|^  런 [0-9]|합계|하드   :|속도   :|이미 백업|❌|오류|FAIL' | head -25 | sed 's/^/    /'
	[ -n "$LOGFILE" ] && echo "    (전체 출력 : $LOGFILE.code9-dryrun)"
	return $rc
}
dry9 "$MP_RAW" raw || fail "RAW dry-run 이 실패했습니다 (rc=$?)" "위 출력을 보세요."
if [ -n "$PRDD" ]; then dry9 "$MP_PRD" prd || fail "PRD dry-run 이 실패했습니다 (rc=$?)" "위 출력을 보세요."; fi
ok "dry-run"

# =====================================================================
step 8 "백업 기동 (RAW 세션 -> 끝나면 30 초 뒤 PRD 세션)"
# =====================================================================
if [ "$NOSTART" = 1 ]; then
	echo "  (--no-start : 띄우지 않습니다)"
	ok "건너뜀"
	echo; echo "띄우려면 : sudo bash $0   (같은 명령, --no-start 없이)"
	exit 0
fi

# 서버의 사슬 스크립트가 지금 마운트·옵션과 맞으면 그것을, 아니면 같은 동작을 여기서 만든다
use_chain=0
if [ -n "$PRDD" ] && [ -f "$CHAIN" ] \
   && grep -qF -- "$CODE9 --disks $MP_RAW --only raw" "$CHAIN" \
   && grep -qF -- "$CODE9 --disks $MP_PRD --only prd" "$CHAIN"; then
	use_chain=1
fi
if [ $use_chain = 1 ]; then
	echo "  사슬 스크립트 그대로 : $CHAIN"
	RUNME=$CHAIN
else
	echo "  사슬 스크립트가 없거나 지금 구성과 달라 같은 동작을 직접 만듭니다."
	RUNME=$LOGDIR/chain-inline-$TS.sh
	{
		echo '#!/bin/bash'
		echo "# storage-backup-mount.sh 가 $STAMP 에 만든 사슬 (backup_raw_then_prd.sh 와 같은 동작)"
		echo "L='$LOGDIR'"
		echo "echo \"[\$(date)] chain start (storage-backup-mount) : RAW -> $MP_RAW${PRDD:+, then PRD -> $MP_PRD}\" >> \"\$L/chain.log\""
		echo "'$CODE9' --disks '$MP_RAW' --only raw > \"\$L/code9.log\" 2>&1"
		echo "echo \"[\$(date)] RAW session ended rc=\$?\" >> \"\$L/chain.log\""
		if [ -n "$PRDD" ]; then
			echo "sleep 30"
			echo "'$CODE9' --disks '$MP_PRD' --only prd > \"\$L/code9-prd.log\" 2>&1"
			echo "echo \"[\$(date)] PRD session ended rc=\$?\" >> \"\$L/chain.log\""
		fi
	} > "$RUNME.tmp"
	if [ "$DRYRUN" = 1 ]; then
		sed 's/^/    | /' "$RUNME.tmp"; rm -f "$RUNME.tmp"
	else
		mv -f "$RUNME.tmp" "$RUNME"; chown "$BUSER:$BUSER" "$RUNME" 2>/dev/null
		echo "  ($RUNME)"; sed 's/^/    | /' "$RUNME"
	fi
fi
# 지난 세션의 code9.log 는 남겨 둔다 (사슬이 > 로 덮어쓴다)
for f in code9.log code9-prd.log; do
	[ -s "$LOGDIR/$f" ] && act sudo -u "$BUSER" cp -p "$LOGDIR/$f" "$LOGDIR/$f.prev-$TS"
done
launch="cd '$UHOME' && setsid nohup bash '$RUNME' > '$LOGDIR/chain.out' 2>&1 < /dev/null &"
if [ "$DRYRUN" = 1 ]; then
	echo "  (dry-run) \$ sudo -u $BUSER bash -c $launch"
	ok "dry-run 이라 띄우지 않았습니다"
	exit 0
fi
echo "  \$ sudo -u $BUSER bash -c $launch"
sudo -u "$BUSER" bash -c "$launch" || fail "기동 명령이 실패했습니다"
echo "  ($WAIT_S 초 기다린 뒤 첫 화면을 봅니다)"
sleep "$WAIT_S"

pids=$(ps -eo pid=,args= 2>/dev/null | awk -v anc="$ANC" '
	$0 ~ /data_backup_simple_code[0-9]*\.sh/ { if (index(anc, " " $1 " ") == 0) print }')
if [ -n "$pids" ]; then
	echo "  세션 :"; printf '%s\n' "$pids" | sed 's/^/    /'
else
	warn "도는 code9 세션이 보이지 않습니다. 아래 로그를 보세요."
fi
echo "  \$ head $LOGDIR/code9.log"
grep -E '쓰기|담는 종류|하드 순서|^  런 [0-9]|전송 시작|❌|오류' "$LOGDIR/code9.log" 2>/dev/null | head -15 | sed 's/^/    /'
[ -s "$LOGDIR/chain.out" ] && { echo "  chain.out :"; tail -5 "$LOGDIR/chain.out" | sed 's/^/    /'; }
if [ -z "$pids" ]; then fail "백업 세션이 떠 있지 않습니다" "cat $LOGDIR/code9.log $LOGDIR/chain.out"; fi
ok "백업 기동"

cat <<EOF

==========================================================
  다음에 볼 것
  - 메일 : 세션 시작 알림(cron :37, build=NEW) · 하드가 차면 · 끝나면 온다 (책임자)
  - 진행 : tail -c 400 $LOGDIR/code9.log | tr '\r' '\n' | tail -3
           cat $LOGDIR/chain.log
  - DAQ PC 에서 : scripts/mailq-send.sh --status   (메일 큐)
  - 하드가 떨어지면 (메일 '전송 도중 떨어졌습니다') :
       umount -l $MP_RAW ${PRDD:+$MP_PRD}  ->  e2fsck -f <장치>  ->  sudo bash $0
  - 뽑을 때는 umount 부터 (독은 한 USB 장치라 둘이 같이 떨어진다)
==========================================================
EOF
[ -n "$LOGFILE" ] && echo "로그 : $LOGFILE"
exit 0
