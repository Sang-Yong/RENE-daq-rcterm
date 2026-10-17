#!/bin/bash
# =====================================================================
#  storage-backup-mount.sh  --  저장소 서버(ssh store)에서 root 로 실행
#
#  외장하드(독 2 베이)를 by-id 이름으로 직접 마운트하고 백업을 띄운다. fstab 은 건드리지 않는다.
#
#  1) 인자 없이 실행 : USB 하드의 by-id 후보 표와, 복사해 쓸 다음 명령을 보여 주고 끝난다 (아무것도 안 바꾼다)
#       sudo bash /home/frontend/storage-backup-mount.sh
#  2) by-id 이름 두 개(RAW, PRD 순)를 주어 실행 : 마운트 -> 권한 -> 내용 -> code9 dry-run -> 백업 기동
#       sudo bash /home/frontend/storage-backup-mount.sh ata-<모델>_<시리얼>-part1 ata-<모델>_<시리얼>-part1
#     · 첫 번째 -> /backup_hdd (RAW), 두 번째 -> /backup_hdd_2 (PRD). 하나만 주면 RAW 만
#     · /dev/disk/by-id/ 접두어가 있어도 되고, 시리얼만 줘도 된다 (예 : ZK206HAY Z4ZBZE0A)
#
#  옵션
#     --dry-run    아무것도 바꾸지 않고 할 명령만 보여 준다 (탐지는 실제로)
#     --no-start   마운트 · 권한 · dry-run 까지만 하고 백업은 띄우지 않는다
#     -h           이 설명
#
#  단계마다 [n/7] · 실행한 명령 · 그 출력 · OK / FAIL 을 찍는다. FAIL 이면 거기서 멈춘다.
#  출력은 화면과 /home/frontend/sykim/backup_log/mount-and-backup-<시각>.log 둘 다.
#
#  ★ 포맷은 하지 않는다. ext4 가 아니면 멈춘다 (포맷은 사람이 정한다)
#  ★ 재부팅하면 마운트는 풀린다 (fstab 에 안 적으므로). 다시 이 스크립트를 같은 인자로
#  ★ 하드가 떨어지면 : umount <마운트> (안 되면 umount -l) -> ls -l /dev/disk/by-id | grep ata- -> 같은 인자로 다시
#  ★ 프로세스 검사에 pgrep -f 를 쓰지 않는다 (§11.142 의 3)
# =====================================================================

DRYRUN=0; NOSTART=0
ARGS=()
ORIG_ARGS="$*"

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run)     DRYRUN=1; shift ;;
		--no-start)    NOSTART=1; shift ;;
		-h|--help)     usage; exit 0 ;;
		-*) echo "알 수 없는 옵션 : $1  (-h 로 사용법)"; exit 2 ;;
		*)  ARGS+=("$1"); shift ;;
	esac
done

MP_RAW=${BACKUP_MOUNT_MP_RAW:-/backup_hdd}
MP_PRD=${BACKUP_MOUNT_MP_PRD:-/backup_hdd_2}
SELF=$(readlink -f "$0" 2>/dev/null)
case "$SELF" in *.sh) ;; *) SELF=/home/frontend/storage-backup-mount.sh ;; esac

# ---- 갈아끼울 수 있는 경로 (시험용. 실서버에서는 기본값 그대로) ----
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
# 없으면 $BUSER 소유로 만든다 (root 소유로 생기면 code9 가 backup_log.txt 를 못 쓴다)
[ -d "$LOGDIR" ] || install -d -o "$BUSER" -g "$BUSER" "$LOGDIR" 2>/dev/null || mkdir -p "$LOGDIR" 2>/dev/null
if touch "$LOGDIR/mount-and-backup-$TS.log" 2>/dev/null; then
	LOGFILE=$LOGDIR/mount-and-backup-$TS.log
	chown "$BUSER:$BUSER" "$LOGFILE" 2>/dev/null
	exec > >(tee -a "$LOGFILE") 2>&1
fi

NSTEP=7
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

kv() { sed -n "s/.*\\b$1=\"\\([^\"]*\\)\".*/\\1/p" <<<"$2"; }

# ---- USB 하드 후보 : 표 만들기 (읽기 전용) ----
DISKS=$(lsblk -d -n -P -o NAME,TRAN,TYPE,SIZE,MODEL 2>/dev/null)
PARTS=$(lsblk -n -P -o NAME,TYPE,FSTYPE,MOUNTPOINT,PKNAME 2>/dev/null)
CAND=()
declare -A SER MOD LNAME DEV FST SIZ MNT
while IFS= read -r line; do
	[ -z "$line" ] && continue
	[ "$(kv TRAN "$line")" = usb ] || continue
	[ "$(kv TYPE "$line")" = disk ] || continue
	nm=$(kv NAME "$line")
	props=$(udevadm info --query=property --name="/dev/$nm" 2>/dev/null)
	s=$(sed -n 's/^ID_SERIAL_SHORT=//p' <<<"$props" | head -1)
	md=$(sed -n 's/^ID_MODEL=//p' <<<"$props" | head -1)
	ln=""
	if [ -n "$s" ]; then
		[ -n "$md" ] && [ -e "$BYID/ata-${md}_${s}-part1" ] && ln="ata-${md}_${s}-part1"
		[ -z "$ln" ] && ln=$(ls -1 "$BYID" 2>/dev/null | grep -E "^ata-.*_${s}-part1\$" | head -1)
	fi
	dv=""; fs=""; mt=""
	[ -n "$ln" ] && dv=$(readlink -f "$BYID/$ln")
	while IFS= read -r pl; do
		[ "$(kv PKNAME "$pl")" = "$nm" ] || continue
		m=$(kv MOUNTPOINT "$pl"); [ -n "$m" ] && mt=$m
		[ -n "$dv" ] && [ "$(kv NAME "$pl")" = "$(basename "$dv")" ] && fs=$(kv FSTYPE "$pl")
	done <<<"$PARTS"
	CAND+=("$nm")
	SER[$nm]=${s:-?}; MOD[$nm]=${md:-?}; LNAME[$nm]=$ln; DEV[$nm]=$dv; FST[$nm]=$fs; MNT[$nm]=$mt
	SIZ[$nm]=$(kv SIZE "$line")
done <<<"$DISKS"

show_table() {
	printf '  %-6s %-6s %-6s %-10s %-14s %s\n' "장치" "크기" "fs" "시리얼" "지금 마운트" "by-id 이름 (/dev/disk/by-id/...)"
	local n
	for n in "${CAND[@]}"; do
		printf '  %-6s %-6s %-6s %-10s %-14s %s\n' "$n" "${SIZ[$n]}" "${FST[$n]:-없음}" "${SER[$n]}" "${MNT[$n]:--}" "${LNAME[$n]:-(by-id 링크 없음)}"
	done
}

echo "=========================================================="
echo "  외장하드 마운트 + 백업 기동   ($STAMP)"
[ "$DRYRUN" = 1 ] && echo "  ★ --dry-run : 아무것도 바꾸지 않습니다. 할 명령만 보여 줍니다."
[ "$NOSTART" = 1 ] && echo "  ★ --no-start : dry-run 까지만 하고 백업은 띄우지 않습니다."
[ -n "$LOGFILE" ] && echo "  로그 : $LOGFILE"
echo "=========================================================="

# ---- 인자 없음 : 후보 표 + 다음 명령 안내 ----
if [ ${#ARGS[@]} -eq 0 ]; then
	echo
	echo "USB 외장하드 후보"
	if [ ${#CAND[@]} -eq 0 ]; then
		echo "  (USB 하드가 없습니다. 독 전원·케이블을 보고 lsblk 에 TRAN=usb 가 보이는지 확인하세요)"
		exit 0
	fi
	show_table
	use=()
	for n in "${CAND[@]}"; do
		[ -n "${LNAME[$n]}" ] && [ "${FST[$n]}" = ext4 ] || continue
		case "${MNT[$n]}" in ''|"$MP_RAW"|"$MP_PRD") use+=("${LNAME[$n]}") ;; esac
	done
	echo
	if [ ${#use[@]} -eq 0 ]; then
		echo "쓸 수 있는 하드가 없습니다 (by-id 링크가 있고 ext4 이며 다른 곳에 마운트되지 않은 것)."
		exit 0
	fi
	echo "다음과 같이 by-id 이름 두 개를 (RAW, PRD 순으로) 인자로 주어 다시 실행하세요 :"
	echo
	echo "  sudo bash $SELF ${use[*]:0:2}"
	echo
	echo "  · 첫 번째 -> $MP_RAW (RAW), 두 번째 -> $MP_PRD (PRD). 하나만 주면 RAW 만 합니다"
	echo "  · 먼저 미리 보려면 끝에 --dry-run, 백업은 띄우지 않으려면 --no-start"
	[ ${#use[@]} -gt 2 ] && echo "  ★ 후보가 ${#use[@]} 장입니다. 위 예시는 앞의 두 장 — 표를 보고 고르세요."
	exit 0
fi

# =====================================================================
step 1 "전제 확인 : root 인가 · 이미 도는 백업 세션이 없는가"
# =====================================================================
echo "  \$ id -u   ->  $MY_EUID"
if [ "$MY_EUID" != 0 ]; then
	if [ "$DRYRUN" = 1 ]; then
		warn "root 가 아니지만 --dry-run 이라 계속합니다 (아무것도 바꾸지 않음)."
	else
		fail "root 로 실행해야 합니다" "sudo bash $SELF $ORIG_ARGS" "(미리 보기만 하려면 --dry-run)"
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
step 2 "하드 확인 : 인자로 받은 by-id 이름"
# =====================================================================
run lsblk -o NAME,SIZE,TRAN,TYPE,FSTYPE,MOUNTPOINT,MODEL
show_table
echo
[ ${#ARGS[@]} -gt 2 ] && fail "인자가 ${#ARGS[@]} 개입니다. by-id 이름은 두 개까지 (RAW, PRD 순)"

resolve() {   # $1 = 인자  ->  장치 이름(sdX) 을 찍는다
	local a=${1#/dev/disk/by-id/} n
	for n in "${CAND[@]}"; do [ -n "${LNAME[$n]}" ] && [ "${LNAME[$n]}" = "$a" ] && { echo "$n"; return 0; }; done
	for n in "${CAND[@]}"; do [ "${SER[$n]}" = "$a" ] && { echo "$n"; return 0; }; done
	if [ -e "$BYID/$a" ]; then echo "notusb"; return 1; fi
	return 1
}
ROLE_MP=("$MP_RAW" "$MP_PRD"); ROLE=(RAW PRD)
PAIRS=(); USED=" "
for i in "${!ARGS[@]}"; do
	a=${ARGS[$i]}; mp=${ROLE_MP[$i]}
	if ! n=$(resolve "$a"); then
		if [ "$n" = notusb ]; then
			fail "$a 는 by-id 에 있지만 USB 외장하드가 아닙니다" "위 표의 by-id 이름을 쓰세요."
		fi
		fail "$a 에 해당하는 USB 하드가 없습니다 (by-id 이름도 시리얼도 아님)" \
			"ls -l /dev/disk/by-id | grep ata-   로 하드가 보이는지 보고, 위 표의 이름을 쓰세요."
	fi
	[ -z "${LNAME[$n]}" ] && fail "/dev/$n (${SER[$n]}) 의 by-id 첫 파티션 링크가 없습니다" \
		"파티션·포맷(ext4)은 사람이 정합니다 — 이 스크립트는 포맷하지 않습니다."
	case "$USED" in *" $n "*) fail "같은 하드(/dev/$n ${SER[$n]})를 두 번 주었습니다" ;; esac
	USED="$USED$n "
	[ "${FST[$n]}" = ext4 ] || fail "/dev/$n (${SER[$n]}) 의 첫 파티션이 ext4 가 아닙니다 (fs=${FST[$n]:-없음})" \
		"포맷은 하지 않습니다. 포맷할지(자료가 지워진다)는 사람이 정합니다 :" \
		"  mkfs.ext4 ${DEV[$n]}   (★ 하드의 자료가 전부 지워진다)"
	m=${MNT[$n]}
	if [ -n "$m" ] && [ "$m" != "$mp" ]; then
		fail "/dev/$n ${SER[$n]} 는 이미 $m 에 마운트돼 있습니다 (${ROLE[$i]} 자리는 $mp)" \
			"인자 순서를 바꾸거나(첫 번째 = RAW = $MP_RAW), 그 하드를 umount $m 한 뒤 다시"
	fi
	echo "  ${ROLE[$i]} -> $mp = /dev/$n  ${SER[$n]}  (${MOD[$n]})  $BYID/${LNAME[$n]}"
	PAIRS+=("$mp:$n")
done
# 인자로 안 준 하드가 우리 마운트지점에 붙어 있으면 (지난 회차 하드) 멈춘다
for n in "${CAND[@]}"; do
	case "$USED" in *" $n "*) continue ;; esac
	m=${MNT[$n]}
	if [ "$m" = "$MP_RAW" ] || { [ ${#ARGS[@]} -ge 2 ] && [ "$m" = "$MP_PRD" ]; }; then
		fail "$m 에 /dev/$n ${SER[$n]} (지난 회차 하드?) 가 붙어 있습니다" \
			"아무것도 바꾸지 않았습니다. 그 하드를 뺄 것이면 : umount $m  (안 되면 umount -l $m)" \
			"그 하드를 그대로 쓸 것이면 인자로 주세요."
	fi
done
[ ${#ARGS[@]} -eq 1 ] && warn "인자가 하나입니다. RAW 만 하고 PRD 세션은 건너뜁니다."
PRDD=""; [ ${#ARGS[@]} -eq 2 ] && PRDD=${PAIRS[1]#*:}
ok "하드 ${#ARGS[@]} 장"

# =====================================================================
step 3 "마운트 (mount -t ext4 <by-id> <마운트지점>) 와 장치 대조"
# =====================================================================
for pr in "${PAIRS[@]}"; do
	mp=${pr%%:*}; n=${pr#*:}; dv=${DEV[$n]}; lk=$BYID/${LNAME[$n]}
	[ -d "$mp" ] || act mkdir -p "$mp" || fail "$mp 를 만들 수 없습니다"
	if mountpoint -q "$mp" 2>/dev/null; then
		src=$(findmnt -n -o SOURCE "$mp" 2>/dev/null)
		echo "  \$ findmnt -n -o SOURCE $mp   ->  $src"
		if [ "$src" != "$dv" ]; then
			fail "$mp 에 다른 장치($src)가 마운트돼 있습니다. 기대 : $dv (${SER[$n]})" \
				"지난 회차 하드이거나, 떨어졌다 다시 붙은 유령 마운트일 수 있습니다 (§11.124)." \
				"umount $mp  (안 되면 umount -l $mp)  ->  같은 인자로 이 스크립트 다시"
		fi
		[ -e "$src" ] || fail "$mp 의 장치 $src 가 /dev 에 없습니다 (유령 마운트)" "umount -l $mp 뒤 같은 인자로 다시"
		echo "    (이미 마운트됨 : 건너뜁니다)"
	else
		act mount -t ext4 "$lk" "$mp" || fail "mount $lk $mp 실패" "dmesg | tail -20 으로 사유를 보세요."
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
step 4 "권한 : RENE_data_backup 을 만들고 $BUSER 소유로"
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
step 5 "하드 내용 확인 (빈 하드인가)"
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
step 6 "$BUSER 로 백업 계획 미리 보기 (code9 --dry-run)"
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
step 7 "백업 기동 (RAW 세션 -> 끝나면 30 초 뒤 PRD 세션)"
# =====================================================================
if [ "$NOSTART" = 1 ]; then
	echo "  (--no-start : 띄우지 않습니다)"
	ok "건너뜀"
	echo; echo "띄우려면 : sudo bash $SELF ${ARGS[*]}   (같은 인자, --no-start 없이)"
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
       1) umount $MP_RAW ${PRDD:+$MP_PRD}      (안 되면 umount -l <마운트>)
       2) ls -l /dev/disk/by-id | grep ata-    (하드가 다시 보이는지)
       3) sudo bash $SELF ${ARGS[*]}
          (code9 는 이미 옮긴 파일을 건너뛰고 이어간다)
  - 재부팅하면 마운트가 풀린다 (fstab 에 안 적었다) -> 3) 과 같은 명령
  - 뽑을 때는 umount 부터 (독은 한 USB 장치라 둘이 같이 떨어진다)
==========================================================
EOF
[ -n "$LOGFILE" ] && echo "로그 : $LOGFILE"
exit 0
