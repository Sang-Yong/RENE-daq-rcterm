#!/bin/bash
# =====================================================================
#  storage-backup.sh   (스토리지 서버에서 돈다. 배포 이름 data_backup_simple_code9.sh)
#     /data/RAW 의 런 폴더를 외장하드로 옮긴다 (대조를 통과한 뒤 원본 삭제).
#
#  ★ 옵션 없이 그냥 돌리면 된다.   ./data_backup_simple_code9.sh
#
#  code8 에서 달라진 것 두 가지
#    1) 하드를 여러 개 순서대로 쓴다.  /backup_hdd -> /backup_hdd_2
#       앞 하드가 가득 차면 그 자리에서 다음 하드로 이어서 담는다.
#       ★ 다음 하드가 마운트돼 있지 않거나 여유가 없으면 오류를 남기고 멈춘다.
#    2) 결과를 메일로 보낸다.  하드를 다 채워 넘어갈 때 한 통, 끝날 때 종합 한 통,
#       오류로 멈출 때 한 통.  하드 UUID·장치·모델·시리얼이 본문에 들어간다.
#
#       ★ 이 서버에는 인터넷 경로가 없다 (10.0.0.0/24 뿐, DNS 도 안 된다).
#         그래서 직접 보내지 못하고 /data/MAILQ 에 파일로 떨군다. DAQ PC 가
#         그 자리를 /scratch 로 마운트하고 있어, 거기 cron 이 5분마다 집어
#         scripts/mailq-send.sh -> tools/notify/send_mail.py 로 내보낸다.
#         /scratch 가 잠시 빠져 있어도 큐는 남아 나중에 나간다.
#
#  하는 일 (하드 하나에 대한 한 회차)
#    1) 이 하드에 무엇이 담기는지 먼저 계산해 보여준다
#         - 런과 서브런 범위, 파일 개수, 용량, 예상 소요 시간
#    2) 그대로 옮긴다. 하드는 남김없이 채운다
#         - 안 들어가는 폴더는 들어가는 만큼 잘라 담는다
#         - 하드보다 큰 런(6.7 TB 짜리도 있다)은 하드 여러 개에 나눠 담고,
#           어느 조각이 어느 하드에 있는지 매니페스트에 남긴다
#    3) 보낸 뒤 개수와 바이트를 대조하고, 통과한 것만 원본에서 지운다
#
#  한 회차를 마친 뒤 어떻게 판단하나
#    남은 일이 없다 (원본이 비었거나 남은 것이 '사용 중' 런뿐)
#          -> ✅ 성공 종료. 다음 하드는 건드리지도 않는다
#    남은 일이 있다  +  이 하드가 실제로 찼다
#          -> 다음 하드로 넘어간다
#    남은 일이 있다  +  이 하드는 안 찼다  (--split never 로 큰 런이 안 들어갈 때)
#          -> 하드를 바꿔도 소용없다. 사유를 적고 멈춘다 (하드를 태우지 않는다)
#
#  다른 작업과 부딪히지 않게 하는 장치 (code8 그대로)
#    - 두 번 겹쳐 돌지 못한다 (flock + 프로세스 검사 -- 옛 판본으로 띄운 것도 잡는다)
#    - 최근 30분 안에 파일이 바뀐 런은 건드리지 않는다 (누가 쓰는 중)
#    - .rsync-partial 이 남아 있는 런도 건드리지 않는다 (전송이 진행 중)
#    - backup_log/backup_skip.txt 에 런 번호를 적어 두면 그 런은 제외한다
#    - 지우기 직전에 원본 크기를 다시 확인해, 그 사이 바뀐 파일은 남긴다
#
#  종료코드
#    0  정상 (더 옮길 것이 없다)
#    1  오류 (다음 하드가 없거나 가득 참 · 연속 전송 실패 · 설정 오류)
#    3  하드를 다 썼는데 아직 남았다 -> 하드를 교체하고 다시 실행할 것
#
#  가끔 쓰는 옵션 (평소에는 필요 없다)
#     --dry-run        계획만 보고 끝낸다. 아무것도 옮기거나 지우지 않는다
#     --disks a,b      쓸 하드를 순서대로 (기본 /backup_hdd,/backup_hdd_2)
#     --no-mail        메일을 큐에 넣지 않는다
#     --no-bwlimit     속도 제한 해제 (기본 50M)
#     --margin 10      안전 마진을 10 GB 로 (기본 2 GB)
#     --split auto     런이 여러 하드에 흩어지는 것이 싫을 때.
#                      하드보다 큰 런만 쪼갠다 (대신 하드가 덜 찬다)
# =====================================================================

# --- 설정 구간 -------------------------------------------------------
SOURCE_PARENT="${BACKUP_SOURCE:-/data/RAW}"          # 백업할 원본 경로
#  ★ 쓸 하드를 순서대로. 쉼표로 구분. --disks 로도 준다.
MOUNTS_RAW="${BACKUP_MOUNTS:-/backup_hdd,/backup_hdd_2}"
DEST_SUBDIR="${BACKUP_DEST_SUBDIR:-RENE_data_backup}"
LOG_FILE="${BACKUP_LOG:-/home/frontend/sykim/backup_log/backup_log.txt}"
SIZE_CACHE="${BACKUP_SIZE_CACHE:-/home/frontend/sykim/backup_log/folder_size.cache}"

#  안전 마진 — 파일시스템을 마지막 바이트까지 채우지 않기 위한 여유.
#  rsync 가 전송 중인 파일 하나를 담을 자리만 있으면 되므로(가장 큰 DAQ 파일이
#  80 MB 안팎) 2 GB 면 25배 넉넉하다. 10 GB 로 두면 하드마다 8 GB 를 그냥 버린다.
#  더 보수적으로 가려면  --margin 10  (단위 GB)
SAFETY_MARGIN="${BACKUP_SAFETY_MARGIN_KB:-$((2 * 1024 * 1024))}"   # 2 GB [KB]
#  여유가 이보다 적으면 더 담을 것이 없다고 보고 이 하드를 '찼다'고 판정한다.
#  DAQ 파일 하나가 9~80 MB 라 100 MB 면 사실상 마지막 한 파일까지 담긴다.
MIN_USEFUL="${BACKUP_MIN_USEFUL_KB:-$((100 * 1024))}"              # 100 MB [KB]
BWLIMIT="${BACKUP_BWLIMIT-50M}"       # 비우면 무제한.  --no-bwlimit 로도 해제
MAX_CONSEC_FAIL=3                     # 연속 실패가 이만큼이면 하드를 의심하고 멈춘다
#  들어가지 않는 폴더를 어떻게 할까
#    always: 남은 자리에 안 들어가면 무엇이든 쪼개 담는다  ★ 기본.
#    auto  : 하드보다 큰 폴더만 쪼갠다.
#    never : 쪼개지 않는다 (건너뛰기만)
SPLIT_MODE="${BACKUP_SPLIT_MODE:-always}"
PARTS_INDEX="${BACKUP_PARTS_INDEX:-/home/frontend/sykim/backup_log/parts_index.txt}"
LOCK="${BACKUP_LOCK:-/home/frontend/sykim/backup_log/.backup.lock}"
#  ★ 다른 작업이 만지는 중인 런은 건드리지 않는다.
#    이 폴더의 파일이 최근 이 시간[분] 안에 바뀌었으면 누군가 쓰는 중으로 본다.
#    (쓰는 쪽이 NFS 클라이언트라 lsof 로는 안 보인다. mtime 이 유일한 신호다.)
QUIET_MIN="${BACKUP_QUIET_MIN:-30}"
#  손으로 제외하고 싶은 런을 한 줄에 하나씩 (있으면 읽는다)
SKIP_LIST="${BACKUP_SKIP_LIST:-/home/frontend/sykim/backup_log/backup_skip.txt}"
#  ★ 메일 큐. 이 서버는 인터넷이 없어 직접 못 보낸다. 파일로 떨구면
#    DAQ PC 의 cron(scripts/mailq-send.sh) 이 5분마다 집어 보낸다.
MAILQ_DIR="${BACKUP_MAILQ:-/data/MAILQ}"
MAIL_ENABLE="${BACKUP_MAIL:-1}"
DRYRUN=0

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run)     DRYRUN=1; shift ;;
		--disks)       MOUNTS_RAW=$2; shift 2 ;;
		--no-mail)     MAIL_ENABLE=0; shift ;;
		--mailq)       MAILQ_DIR=$2; shift 2 ;;
		--no-bwlimit)  BWLIMIT=""; shift ;;
		--split)       SPLIT_MODE=$2; shift 2 ;;
		--margin)      SAFETY_MARGIN=$(( ${2%[gG]} * 1024 * 1024 )); shift 2 ;;   # GB
		--no-split)    SPLIT_MODE=never; shift ;;
		--bwlimit)     BWLIMIT=$2; shift 2 ;;
		-h|--help)     sed -n '2,57p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "모르는 옵션 : $1" >&2; exit 2 ;;
	esac
done

IFS=',' read -r -a DISKS <<< "$MOUNTS_RAW"
[ "${#DISKS[@]}" -ge 1 ] || { echo "❌ 쓸 하드가 지정되지 않았습니다." >&2; exit 2; }

# =====================================================================
#  디스크 판정 — 이 네 함수만이 '마운트돼 있나 · 얼마나 남았나' 를 안다.
#
#  ★ BACKUP_TEST_HOOK 으로 갈아끼울 수 있다. 실제 2 TB 를 채워 보지 않고도
#    '하드가 찼다' · '하드가 없다' 를 만들어 상태 기계를 시험하기 위한 것이다.
#    (dataflow.sh 의 DATAFLOW_ALLOW_UNMOUNTED 와 같은 성격의 탈출구다.)
#    평소 운용에서는 절대 쓰지 않는다.
# =====================================================================
disk_is_mounted() { mountpoint -q "$1"; }
disk_df_field()   { df -k "$1" 2>/dev/null | tail -1 | awk -v f="$2" '{print $f+0}'; }
disk_cap_kb()     { disk_df_field "$1" 2; }
disk_used_kb()    { disk_df_field "$1" 3; }
disk_avail_kb()   { disk_df_field "$1" 4; }

# ---------------------------------------------------------------------
#  ★ 목적지에 실제로 쓸 수 있는가.  마운트돼 있다고 쓸 수 있는 것이 아니다.
#
#    2026-09-03 에 이것 때문에 백업이 통째로 헛돌았다. 갓 포맷한 하드의
#    루트는 root:root 755 라 frontend 가 <마운트>/RENE_data_backup 을 만들 수
#    없었다. 그런데 mkdir 의 오류를 2>/dev/null 로 삼키고 있어서, 1,723 개
#    폴더의 계획을 다 세운 뒤 첫 rsync 가 "No such file or directory" 로 죽고
#    나서야 무언가 잘못된 것이 드러났다. 게다가 그 뒤의 진단 메시지가
#    엉뚱하게 '--split 으로는 쪼갤 수 없다' 를 가리켜 사람을 딴 곳으로 보냈다.
#
#    ★ -w 만으로는 부족하다. root 스쿼시나 읽기전용 재마운트는 권한 비트가
#      멀쩡해 보인다. 실제로 파일을 하나 만들어 봐야 안다.
#
#    실패 사유를 DEST_ERR 에 남긴다.
# ---------------------------------------------------------------------
DEST_ERR=""
dest_ready() {           # 마운트지점
	local dest="$1/$DEST_SUBDIR" t
	DEST_ERR=""
	if ! DEST_ERR=$(mkdir -p "$dest" 2>&1); then
		DEST_ERR="${DEST_ERR:-목적지 폴더를 만들 수 없다}"; return 1
	fi
	t="$dest/.write-test.$$"
	if ! DEST_ERR=$(: > "$t" 2>&1); then
		DEST_ERR="${DEST_ERR:-목적지에 파일을 쓸 수 없다}"; return 1
	fi
	rm -f "$t" 2>/dev/null
	DEST_ERR=""
	return 0
}

#  하드의 신원 — 메일 본문에 넣는다. 사람이 어느 하드인지 알아야 뽑아 간다.
#  전역 D_DEV · D_UUID · D_MODEL · D_SERIAL 을 채운다.
disk_ident() {
	D_DEV=$(findmnt -no SOURCE "$1" 2>/dev/null)
	D_UUID=""; D_MODEL=""; D_SERIAL=""
	[ -n "$D_DEV" ] || return 0
	D_UUID=$(lsblk -no UUID "$D_DEV" 2>/dev/null | head -1)
	local parent
	parent=$(lsblk -no PKNAME "$D_DEV" 2>/dev/null | head -1)
	if [ -n "$parent" ]; then
		D_MODEL=$(lsblk -dno MODEL  "/dev/$parent" 2>/dev/null | head -1 | sed 's/ *$//')
		D_SERIAL=$(lsblk -dno SERIAL "/dev/$parent" 2>/dev/null | head -1 | sed 's/ *$//')
	fi
	return 0
}

#  ★ 시험용 갈아끼우기. 위 다섯 함수만 바꿔 끼운다.
#    실제 2 TB 를 채워 보지 않고도 '하드가 찼다' · '하드가 없다' 를 만들어
#    하드를 넘기는 상태 기계를 시험하기 위한 것이다 (tests/storage-backup.test.sh).
#    ★ 평소 운용에서는 절대 쓰지 않는다. 설정하지 않으면 아무 일도 없다.
if [ -n "${BACKUP_TEST_HOOK:-}" ]; then
	if [ -r "$BACKUP_TEST_HOOK" ]; then
		echo "⚠️  시험 모드 : 용량·마운트 판정을 $BACKUP_TEST_HOOK 로 갈아끼웁니다."
		. "$BACKUP_TEST_HOOK"
	else
		echo "❌ BACKUP_TEST_HOOK 을 읽을 수 없습니다 : $BACKUP_TEST_HOOK" >&2; exit 2
	fi
fi

# --- KB 를 사람이 읽는 단위로 (런이 MB~TB 로 3자릿수 넘게 벌어진다) -----
fmt_kb() { awk -v k="$1" 'BEGIN{
   if (k>=1073741824) printf "%.2f TB", k/1073741824;
   else if (k>=1048576) printf "%.1f GB", k/1048576;
   else if (k>=1024)    printf "%.0f MB", k/1024;
   else                 printf "%d KB", k; }'; }

#  초 -> "3시간 20분"
fmt_sec() { awk -v t="$1" 'BEGIN{
	t=int(t+0.5); d=int(t/86400); h=int(t%86400/3600); m=int(t%3600/60)
	if (d>0) printf "%d일 %d시간", d, h
	else if (h>0) printf "%d시간 %d분", h, m
	else if (m>0) printf "%d분", m
	else printf "1분 미만" }'; }

# --- 폴더 용량 (캐시). 큰 폴더에 du 를 매번 다시 걸지 않는다 ---------
folder_size() {                       # 폴더이름 -> KB
	local n=$1 mt sz line
	mt=$(stat -c %Y "$n" 2>/dev/null)
	line=$(grep -m1 "^$n " "$SIZE_CACHE" 2>/dev/null)
	if [ -n "$line" ]; then
		set -- $line
		if [ "$3" = "$mt" ] && [ -n "$2" ]; then echo "$2"; return 0; fi
	fi
	sz=$(du -sk "$n" 2>/dev/null | awk '{print $1}')
	[ -n "$sz" ] || return 1
	{ grep -v "^$n " "$SIZE_CACHE" 2>/dev/null; echo "$n $sz $mt"; } \
		> "$SIZE_CACHE.tmp" 2>/dev/null && mv -f "$SIZE_CACHE.tmp" "$SIZE_CACHE" 2>/dev/null
	echo "$sz"
}

# ---------------------------------------------------------------------
#  ★ 이 런을 다른 작업이 만지는 중인가.  세 가지를 본다.
#     1) 사람이 손으로 제외해 둔 런
#     2) 최근 $QUIET_MIN 분 안에 파일이 바뀐 런 (누가 쓰는 중)
#     3) rsync 가 중간에 남긴 조각 (.rsync-partial)
#    맞으면 이번에는 건드리지 않는다. 다음 회차에 조용해지면 담긴다.
#
#    ★ 계획 단계와 '남은 일이 있나' 판정이 반드시 같은 눈으로 봐야 한다.
#      다르면 계획은 비었는데 남은 일은 있다고 읽어 하드를 헛되이 넘긴다.
#      그래서 두 곳이 이 함수 하나를 함께 쓴다.
#      -> 이유를 표준출력에 한 낱말로 남긴다 (제외목록 / 사용중 / 전송중)
# ---------------------------------------------------------------------
is_busy() {
	local F=$1
	if [ -r "$SKIP_LIST" ] && grep -qx "$F" "$SKIP_LIST" 2>/dev/null; then
		echo "제외목록"; return 0
	fi
	#  ★ -type f 가 없으면 디렉터리 자신의 mtime 까지 걸려 모든 런이 '사용 중' 이 된다
	if [ -n "$(find "$F" -type f -newermt "-${QUIET_MIN} minutes" -print -quit 2>/dev/null)" ]; then
		echo "사용중"; return 0
	fi
	if [ -d "$F/.rsync-partial" ] || [ -n "$(find "$F" -maxdepth 2 -name '.rsync-partial' -print -quit 2>/dev/null)" ]; then
		echo "전송중"; return 0
	fi
	return 1
}

# ---------------------------------------------------------------------
#  아직 옮길 것이 남았나.  ★ 값싸게 센다 -- du 를 걸지 않는다.
#  런이 1,700 개라 폴더마다 용량을 재면 판정 한 번에 몇 분이 걸린다.
#  여기서 알고 싶은 것은 '있나 없나' 와 '몇 개인가' 뿐이다.
#     REMAIN_N   옮길 것이 남은 런 개수
#     REMAIN_LIST 앞 10 개 이름
# ---------------------------------------------------------------------
remaining_work() {
	REMAIN_N=0; REMAIN_LIST=""
	local F
	for F in */; do
		F=${F%/}
		[ -d "$F" ] || continue
		#  파일이 하나도 없는 껍데기는 옮길 것이 아니다
		[ -n "$(find "$F" -type f -print -quit 2>/dev/null)" ] || continue
		is_busy "$F" >/dev/null && continue
		REMAIN_N=$((REMAIN_N+1))
		[ "$REMAIN_N" -le 10 ] && REMAIN_LIST="$REMAIN_LIST $F"
	done
	[ "$REMAIN_N" -gt 0 ]
}

# ---------------------------------------------------------------------
#  담길 파일들을 사람이 읽는 한 줄로 (카테고리 · 개수 · 서브런 범위)
#     FADC_<런>.root.<서브런>  ·  PRD_<런>.<서브런>.root  둘 다 해석한다
# ---------------------------------------------------------------------
summarize_files() {      # 파일목록 파일경로
	awk '{
		p=$0
		if      (p ~ /^Merged\//) c="Merged"
		else if (p ~ /^PRD\//)    c="PRD"
		else if (p ~ /^PNG\//)    c="PNG"
		else if (p ~ /^FADC_/)    c="FADC"
		else if (p ~ /^SADC_/)    c="SADC"
		else                      c="기타"
		n[c]++
		s=""
		if      (match(p, /\.root\.[0-9]+$/)) s=substr(p, RSTART+6)
		else if (match(p, /\.[0-9]+\.root$/)) s=substr(p, RSTART+1, RLENGTH-6)
		if (s != "") { v=s+0
			if (!(c in mn) || v<mn[c]) mn[c]=v
			if (!(c in mx) || v>mx[c]) mx[c]=v }
	} END {
		split("FADC SADC Merged PRD PNG 기타", o, " ")
		out=""
		for (i=1;i<=6;i++) { c=o[i]; if (c in n) {
			t=sprintf("%s %d", c, n[c])
			if (c in mn) t=t sprintf(" (서브런 %05d~%05d)", mn[c], mx[c])
			out = (out=="" ? t : out " · " t) } }
		print out
	}' "$1"
}

# =====================================================================
#  메일 — 이 서버는 인터넷이 없으므로 파일로 떨군다 (§ 머리말 참조).
#
#  ★ 메일이 안 나가도 백업은 계속되어야 한다. 여기서 나는 어떤 실패도
#    백업을 멈추지 않는다. 알림이 감시 대상을 죽이면 없느니만 못하다.
#
#  형식 (DAQ PC 의 scripts/mailq-send.sh 가 읽는다)
#      subject: <한 줄>
#      to: routine
#      body:
#      <나머지 전부>
# =====================================================================
MAIL_SEQ=0
MAIL_QUEUED=0
queue_mail() {           # 제목  본문파일
	local subj=$1 body=$2 base tmp
	[ "$MAIL_ENABLE" = 1 ] || return 0
	#  ★ 미리보기는 바깥으로 나가지 않는다. --dry-run 은 아무것도 바꾸지
	#    않는다고 적어 두었는데, 메일이 나가면 그 약속이 깨진다.
	#    (오류로 멈추는 경로도 finish 를 지나므로 여기서 한 번에 막는다.)
	if [ "$DRYRUN" -eq 1 ]; then
		echo "   (--dry-run : 메일을 보내지 않습니다 — \"$subj\")"
		return 0
	fi
	mkdir -p "$MAILQ_DIR" 2>/dev/null
	if [ ! -d "$MAILQ_DIR" ] || [ ! -w "$MAILQ_DIR" ]; then
		echo "⚠️  메일 큐에 쓸 수 없습니다 ($MAILQ_DIR). 메일 없이 계속합니다."
		echo "[$(date)] WARN mailq 쓰기 불가 : $MAILQ_DIR" >> "$LOG_FILE"
		return 0
	fi
	MAIL_SEQ=$((MAIL_SEQ+1))
	base="$MAILQ_DIR/$(date +%Y%m%d-%H%M%S)-$$-$MAIL_SEQ"
	tmp="$base.tmp"
	{
		#  제목에 줄바꿈이 섞이면 파서가 깨진다. 한 줄로 눌러 둔다.
		printf 'subject: %s\n' "$(printf '%s' "$subj" | tr '\n\r' '  ')"
		printf 'to: routine\n'
		printf 'body:\n'
		cat "$body"
	} > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
	#  ★ rename 은 원자적이다. 받는 쪽이 반쯤 쓰인 파일을 집지 않는다.
	mv -f "$tmp" "$base.mail" 2>/dev/null && MAIL_QUEUED=$((MAIL_QUEUED+1))
	return 0
}

#  하드 한 개의 신원과 용량을 사람이 읽는 블록으로
disk_block() {           # 마운트지점
	local M=$1
	disk_ident "$M"
	local cap used avail
	cap=$(disk_cap_kb "$M"); used=$(disk_used_kb "$M"); avail=$(disk_avail_kb "$M")
	echo "  마운트   : $M"
	echo "  장치     : ${D_DEV:-(모름)}"
	echo "  UUID     : ${D_UUID:-(모름)}"
	[ -n "$D_MODEL" ]  && echo "  모델     : $D_MODEL"
	[ -n "$D_SERIAL" ] && echo "  시리얼   : $D_SERIAL"
	if [ "${cap:-0}" -gt 0 ]; then
		echo "  용량     : $(fmt_kb "$cap")   사용 $(fmt_kb "$used")  여유 $(fmt_kb "$avail")  (채움률 $((used*100/cap)) %)"
	fi
	local dest="$M/$DEST_SUBDIR" first last
	if [ -d "$dest" ]; then
		first=$(ls -1 "$dest" 2>/dev/null | sort | head -1)
		last=$(ls -1  "$dest" 2>/dev/null | sort | tail -1)
		[ -n "$first" ] && echo "  담긴 런  : $first ~ $last"
	fi
}

# =====================================================================
#  한 회차 — 하드 하나를 채운다.  code8 의 「계획 -> 실행」 이 이 안에 있다.
#
#  들어가는 것 : $1 = 마운트지점
#  나오는 것   : PASS_RC   0 정상 종료 · 2 연속 실패로 중단 (하드를 의심한다)
#                그리고 아래 회차 통계 전역들
# =====================================================================
run_pass() {
	local MOUNT_POINT=$1
	PASS_RC=0
	N_OK=0; N_SKIP=0; N_FAIL=0; MOVED_KB=0; CONSEC_FAIL=0
	N_PART=0; PART_LIST=""; SKIPPED_LIST=""; TOOBIG_LIST=""; N_TOOBIG=0
	N_BUSY=0; BUSY_LIST=""; P_FILES=0; P_KB=0; P_FULL=0; P_PART=0; SHOWN=0
	PASS_T0=$(date +%s)

	local DEST="$MOUNT_POINT/$DEST_SUBDIR"

	disk_ident "$MOUNT_POINT"
	local UUID=$D_UUID
	local CAP; CAP=$(disk_cap_kb "$MOUNT_POINT")
	echo "[$(date)] === 하드 $MOUNT_POINT ${D_DEV:-?} UUID=${UUID:-?} 회차 시작 ===" >> "$LOG_FILE"

	echo ""
	echo "=========================================================="
	echo "  하드 $MOUNT_POINT  ( ${D_DEV:-?}  UUID=${UUID:-?} )"
	echo "=========================================================="
	echo "🔍 백업 대상 : $SOURCE_PARENT   ->   $DEST"
	echo "   외장하드 : $(fmt_kb "$CAP")  (여유 $(fmt_kb "$(disk_avail_kb "$MOUNT_POINT")"))"
	echo "   대조 : 개수+바이트 (원본을 지우기 전에 반드시 통과해야 한다)   속도 제한 : ${BWLIMIT:-없음}"

	#  ★ 회차 사이에 계획 파일을 반드시 지운다.
	#    앞 하드의 list.<런> 이 남아 있으면 이번 회차가 그것을 그대로 읽어,
	#    보내지도 않은 파일을 '대조 통과' 로 보고 지울 수 있다.
	#    이 변경에서 가장 위험한 자리다.
	rm -f "$PLANDIR"/plan.tsv "$PLANDIR"/list.* "$PLANDIR"/sizes.* \
	      "$PLANDIR"/cur.* "$PLANDIR"/del.* "$PLANDIR"/chg.* 2>/dev/null
	: > "$PLANDIR/plan.tsv"

	# -----------------------------------------------------------------
	#  1단계 — 계획.  실제로 옮기기 전에 "이 하드에 무엇이 얼마나 담기는지" 를
	#  먼저 계산한다. 사람이 시작 전에 소요 시간과 대상을 볼 수 있어야 한다.
	# -----------------------------------------------------------------
	local SIM; SIM=$(disk_avail_kb "$MOUNT_POINT")
	local FOLDER F USABLE SZ NF B TOT WHY FITS_EMPTY DO_SPLIT

	echo "🔍 이 하드에 무엇을 담을지 계산 중... (폴더가 많으면 몇 분 걸립니다)"
	for FOLDER in */; do
		[ -e "$FOLDER" ] || continue
		F=${FOLDER%/}
		USABLE=$((SIM - SAFETY_MARGIN))
		[ "$USABLE" -lt "$MIN_USEFUL" ] && break

		if WHY=$(is_busy "$F"); then
			N_BUSY=$((N_BUSY+1)); BUSY_LIST="$BUSY_LIST $F($WHY)"; continue
		fi

		SZ=$(folder_size "$F") || continue

		if [ "$SZ" -lt "$USABLE" ]; then
			( cd "$F" && find . -type f -printf '%s\t%P\n' 2>/dev/null | sort -t"$(printf '\t')" -k2 ) \
				> "$PLANDIR/sizes.$F"
			cut -f2- "$PLANDIR/sizes.$F" > "$PLANDIR/list.$F"
			NF=$(wc -l < "$PLANDIR/list.$F")
			printf '%s\tfull\t%s\t%s\n' "$F" "$NF" "$SZ" >> "$PLANDIR/plan.tsv"
			SIM=$((SIM - SZ)); P_FILES=$((P_FILES+NF)); P_KB=$((P_KB+SZ)); P_FULL=$((P_FULL+1))
			continue
		fi

		#  들어가지 않는다. 쪼갤 것인가?
		FITS_EMPTY=1
		[ "$SZ" -ge "$((CAP - SAFETY_MARGIN))" ] && FITS_EMPTY=0
		DO_SPLIT=0
		case "$SPLIT_MODE" in
			always) DO_SPLIT=1 ;;
			auto)   [ "$FITS_EMPTY" -eq 0 ] && DO_SPLIT=1 ;;
		esac

		if [ "$DO_SPLIT" -eq 0 ]; then
			N_SKIP=$((N_SKIP+1))
			if [ "$FITS_EMPTY" -eq 0 ]; then N_TOOBIG=$((N_TOOBIG+1)); TOOBIG_LIST="$TOOBIG_LIST $F"
			else SKIPPED_LIST="$SKIPPED_LIST $F"; fi
			continue
		fi

		#  들어가는 파일만 골라 목록을 만든다 (이 목록을 2단계에서 그대로 쓴다)
		( cd "$F" && find . -type f -printf '%s\t%P\n' 2>/dev/null | sort -t"$(printf '\t')" -k2 ) \
			> "$PLANDIR/sizes.$F"
		awk -F'\t' -v cap=$(( USABLE * 1024 )) '{ if (s + $1 <= cap) { s += $1; print $2 } }' \
			"$PLANDIR/sizes.$F" > "$PLANDIR/list.$F"
		NF=$(wc -l < "$PLANDIR/list.$F")
		if [ "$NF" -eq 0 ]; then
			N_SKIP=$((N_SKIP+1)); SKIPPED_LIST="$SKIPPED_LIST $F"
			rm -f "$PLANDIR/list.$F" "$PLANDIR/sizes.$F"; continue
		fi
		B=$(awk -F'\t' -v cap=$(( USABLE * 1024 )) '{ if (s + $1 <= cap) s += $1 } END{ print s+0 }' \
			"$PLANDIR/sizes.$F")
		TOT=$(wc -l < "$PLANDIR/sizes.$F")
		printf '%s\tpart\t%s\t%s\t%s\n' "$F" "$NF" "$((B/1024))" "$TOT" >> "$PLANDIR/plan.tsv"
		SIM=$((SIM - B/1024)); P_FILES=$((P_FILES+NF)); P_KB=$((P_KB+B/1024)); P_PART=$((P_PART+1))
	done

	# --- 계획을 보여준다 ---------------------------------------------
	echo ""
	echo "  이번 하드에 담을 것"
	echo "  ----------------------------------------------------------"
	if [ ! -s "$PLANDIR/plan.tsv" ]; then
		echo "  담을 것이 없습니다."
		echo "   - 하드 여유 : $(fmt_kb "$(disk_avail_kb "$MOUNT_POINT")") (안전 마진 $(fmt_kb "$SAFETY_MARGIN") 필요)"
		[ "$N_SKIP" -gt 0 ] && echo "   - 자리가 없어 건너뛴 런 : $N_SKIP 개"
		if [ "$N_BUSY" -gt 0 ]; then
			echo "   - 다른 작업이 쓰는 중이라 건드리지 않은 런 : $N_BUSY 개"
			echo "$BUSY_LIST" | tr ' ' '\n' | grep -v '^$' | head -10 | sed 's/^/       /'
			echo "     최근 ${QUIET_MIN}분 안에 바뀐 파일이 있습니다. 조용해지면 다음 회차에 담깁니다."
		fi
		return 0
	fi
	local KB MODE
	while IFS=$'\t' read -r F MODE NF KB TOT; do
		SHOWN=$((SHOWN+1))
		if [ "$SHOWN" -le 25 ]; then
			if [ "$MODE" = part ]; then
				printf '  런 %s  [부분]  %s / %s 개  %s\n' "$F" "$NF" "$TOT" "$(fmt_kb "$KB")"
			else
				printf '  런 %s  [전체]  %s 개  %s\n' "$F" "$NF" "$(fmt_kb "$KB")"
			fi
			printf '       %s\n' "$(summarize_files "$PLANDIR/list.$F")"
		fi
	done < "$PLANDIR/plan.tsv"
	[ "$SHOWN" -gt 25 ] && echo "  ... 외 $((SHOWN-25)) 개 런"
	echo "  ----------------------------------------------------------"
	echo "  합계   : 런 $SHOWN 개 (전체 $P_FULL · 부분 $P_PART) · 파일 $P_FILES 개 · $(fmt_kb "$P_KB")"
	echo "  하드   : $(fmt_kb "$CAP") 중 $(fmt_kb "$P_KB") 를 새로 담음 → 끝나면 여유 $(fmt_kb "$SIM")"
	local RATE_KBPS ETA
	if [ -n "$BWLIMIT" ]; then
		RATE_KBPS=$(awk -v b="$BWLIMIT" 'BEGIN{ v=b+0; if (b ~ /[mM]/) v=v*1024; else if (b ~ /[gG]/) v=v*1024*1024; print v }')
	else
		RATE_KBPS=80000        # 무제한일 때의 어림값 (약 80 MB/s)
	fi
	ETA=$(( P_KB / (RATE_KBPS>0 ? RATE_KBPS : 1) ))
	echo "  속도   : ${BWLIMIT:-무제한} → 예상 소요 약 $(fmt_sec "$ETA")  (대조 시간은 별도)"
	[ "$N_SKIP" -gt 0 ] && echo "  건너뜀 : $N_SKIP 개 (이 하드에 자리가 없음. 다음 하드에서 담깁니다)"
	if [ "$N_BUSY" -gt 0 ]; then
		echo "  ⏸️  다른 작업이 쓰는 중이라 이번엔 건드리지 않은 런 : $N_BUSY 개"
		echo "$BUSY_LIST" | tr ' ' '\n' | grep -v '^$' | head -10 | sed 's/^/       /'
		[ "$N_BUSY" -gt 10 ] && echo "       ... 외 $((N_BUSY-10)) 개"
	fi
	echo "=========================================================="
	echo ""

	[ "$DRYRUN" -eq 1 ] && return 0

	# -----------------------------------------------------------------
	#  2단계 — 실행.  위 계획을 그대로 따른다.
	# -----------------------------------------------------------------
	local T0 DONE_KB IDX FOLDER_NAME RC WANT_N WANT_B GOT NCHG LEFT EL REMAINSEC RSOPT
	T0=$(date +%s); DONE_KB=0; IDX=0
	while IFS=$'\t' read -r FOLDER_NAME MODE NF KB TOT; do
		IDX=$((IDX+1))
		echo "----------------------------------------------------------"
		if [ "$MODE" = part ]; then
			echo "📂 [$IDX/$SHOWN] $FOLDER_NAME  (부분 $NF / $TOT 개, $(fmt_kb "$KB"))"
		else
			echo "📂 [$IDX/$SHOWN] $FOLDER_NAME  ($NF 개, $(fmt_kb "$KB"))"
		fi

		echo "[$(date)]  $FOLDER_NAME 전송 시작 ($MODE) -> $MOUNT_POINT" >> "$LOG_FILE"
		RSOPT=(-a --partial-dir=.rsync-partial --info=progress2 --files-from="$PLANDIR/list.$FOLDER_NAME")
		[ -n "$BWLIMIT" ] && RSOPT+=(--bwlimit="$BWLIMIT")
		#  ★ 여기서 조용히 실패하면 rsync 가 엉뚱한 오류로 죽는다. 사유를 그대로 낸다.
		if ! MKERR=$(mkdir -p "$DEST/$FOLDER_NAME" 2>&1); then
			N_FAIL=$((N_FAIL+1)); CONSEC_FAIL=$((CONSEC_FAIL+1))
			echo "❌ $FOLDER_NAME : 목적지 폴더를 만들 수 없습니다 — $MKERR"
			echo "[$(date)] FAIL mkdir $DEST/$FOLDER_NAME : $MKERR" >> "$LOG_FILE"
			continue
		fi
		#  ★ --remove-source-files 를 쓰지 않는다. 대조를 통과한 뒤에 지운다.
		rsync "${RSOPT[@]}" "$FOLDER_NAME/" "$DEST/$FOLDER_NAME/" 2>>"$LOG_FILE"
		RC=$?

		if [ "$RC" -ne 0 ]; then
			N_FAIL=$((N_FAIL+1)); CONSEC_FAIL=$((CONSEC_FAIL+1))
			echo "❌ $FOLDER_NAME 전송 실패 (rc=$RC). ★ 원본은 그대로 둡니다."
			echo "[$(date)] FAIL rsync $FOLDER_NAME rc=$RC" >> "$LOG_FILE"
			if [ "$CONSEC_FAIL" -ge "$MAX_CONSEC_FAIL" ]; then
				echo ""
				echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
				echo "⚠️  연속 ${CONSEC_FAIL}회 실패했습니다. 외장하드가 버스에서 떨어졌을 수 있습니다."
				echo "   확인 :  ls /dev/sd*  ·  dmesg -T | tail -30  ·  df -h $MOUNT_POINT"
				echo "   (df 가 멀쩡해 보여도 장치가 사라진 '유령 마운트' 일 수 있습니다)"
				echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
				echo "[$(date)] 연속 실패 ${CONSEC_FAIL}회로 중단" >> "$LOG_FILE"
				PASS_RC=2
				break
			fi
			continue
		fi

		#  대조 : 목록에 적힌 파일이 목적지에 같은 크기로 있는가
		WANT_N=$(wc -l < "$PLANDIR/list.$FOLDER_NAME")
		WANT_B=$( cd "$FOLDER_NAME" && tr '\n' '\0' < "$PLANDIR/list.$FOLDER_NAME" \
		          | xargs -0 stat -c %s 2>/dev/null | awk '{t+=$1} END{print t+0}' )
		GOT=$( cd "$DEST/$FOLDER_NAME" && tr '\n' '\0' < "$PLANDIR/list.$FOLDER_NAME" \
		       | xargs -0 stat -c %s 2>/dev/null | awk '{c++; t+=$1} END{printf "%d %d", c+0, t+0}' )
		set -- $GOT
		if [ "${1:-0}" -ne "$WANT_N" ] || [ "${2:-0}" -ne "${WANT_B:-0}" ]; then
			N_FAIL=$((N_FAIL+1)); CONSEC_FAIL=$((CONSEC_FAIL+1))
			echo "❌ $FOLDER_NAME 대조 실패 (목적지 $1 개 $2 B / 보낸 것 $WANT_N 개 $WANT_B B). ★ 원본을 지우지 않습니다."
			echo "[$(date)] FAIL verify $FOLDER_NAME" >> "$LOG_FILE"
			continue
		fi

		#  조각이 어느 하드에 있는지 남긴다 (부분일 때만 의미가 있다)
		if [ "$MODE" = part ]; then
			{
				echo "# run $FOLDER_NAME  part  $(date '+%F %T')  UUID=$UUID  files=$WANT_N bytes=$WANT_B"
				echo "# $(head -1 "$PLANDIR/list.$FOLDER_NAME") ~ $(tail -1 "$PLANDIR/list.$FOLDER_NAME")"
				cat "$PLANDIR/list.$FOLDER_NAME"
			} >> "$DEST/$FOLDER_NAME/.part_manifest.txt" 2>/dev/null
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$FOLDER_NAME" "$UUID" "$(date '+%F %T')" \
				"$WANT_N" "$WANT_B" "$(head -1 "$PLANDIR/list.$FOLDER_NAME")" \
				"$(tail -1 "$PLANDIR/list.$FOLDER_NAME")" >> "$PARTS_INDEX" 2>/dev/null
		fi

		#  ★ 지우기 직전에 원본을 한 번 더 확인한다.
		#    계획을 세운 뒤 전송이 끝나기까지 몇 시간이 걸린다. 그 사이 다른 작업이
		#    같은 런에 파일을 덧쓰거나 새로 넣었을 수 있다. 계획 당시의 크기와
		#    지금 크기가 같은 파일만 지운다. 달라진 것은 남겨 두고 알린다.
		( cd "$FOLDER_NAME" && tr '\n' '\0' < "$PLANDIR/list.$FOLDER_NAME" \
		  | xargs -0 stat --printf='%s\t%n\n' 2>/dev/null ) > "$PLANDIR/cur.$FOLDER_NAME"
		awk -F'\t' 'NR==FNR { want[$2]=$1; next }
		            { if (($2 in want) && want[$2]==$1) print $2; else print $2 > "/dev/stderr" }' \
			"$PLANDIR/sizes.$FOLDER_NAME" "$PLANDIR/cur.$FOLDER_NAME" \
			> "$PLANDIR/del.$FOLDER_NAME" 2> "$PLANDIR/chg.$FOLDER_NAME"
		NCHG=$(wc -l < "$PLANDIR/chg.$FOLDER_NAME")
		if [ "$NCHG" -gt 0 ]; then
			echo "⚠️  $FOLDER_NAME : 전송 도중 바뀐 파일 $NCHG 개는 지우지 않습니다 (다른 작업이 만진 것)"
			echo "[$(date)] WARN $FOLDER_NAME 변경된 파일 $NCHG 개 보존" >> "$LOG_FILE"
			head -5 "$PLANDIR/chg.$FOLDER_NAME" | sed 's/^/       /'
		fi

		#  대조를 통과했고 그 사이 바뀌지도 않은 것만 지운다
		( cd "$FOLDER_NAME" && tr '\n' '\0' < "$PLANDIR/del.$FOLDER_NAME" | xargs -0 rm -f 2>/dev/null )
		find "$FOLDER_NAME" -mindepth 1 -type d -empty -delete 2>/dev/null
		CONSEC_FAIL=0; MOVED_KB=$((MOVED_KB+KB)); DONE_KB=$((DONE_KB+KB))

		LEFT=$(find "$FOLDER_NAME" -type f 2>/dev/null | wc -l)
		if [ "$LEFT" -eq 0 ]; then
			rm -rf "$FOLDER_NAME"
			N_OK=$((N_OK+1))
			echo "✅ $FOLDER_NAME 완료 및 서버에서 제거됨"
			echo "[$(date)] $FOLDER_NAME 완료 및 서버에서 제거됨." >> "$LOG_FILE"
		else
			N_PART=$((N_PART+1)); PART_LIST="$PART_LIST $FOLDER_NAME"
			echo "📦 $FOLDER_NAME 이 하드 몫 완료. 남은 파일 $LEFT 개 — 다음 하드로 이어집니다"
			echo "[$(date)] $FOLDER_NAME 부분백업 $WANT_N 개 (남은 $LEFT 개)" >> "$LOG_FILE"
		fi

		EL=$(( $(date +%s) - T0 ))
		if [ "$DONE_KB" -gt 0 ] && [ "$EL" -gt 0 ]; then
			REMAINSEC=$(( (P_KB - DONE_KB) * EL / DONE_KB ))
			printf '📊 진행 %d%% (%s / %s) · 남은 예상 시간 약 %s · 하드 여유 %s\n' \
				$(( DONE_KB * 100 / (P_KB>0?P_KB:1) )) "$(fmt_kb "$DONE_KB")" "$(fmt_kb "$P_KB")" \
				"$(fmt_sec "$REMAINSEC")" "$(fmt_kb "$(disk_avail_kb "$MOUNT_POINT")")"
		fi
	done < "$PLANDIR/plan.tsv"

	echo ""
	echo "  하드 $MOUNT_POINT 회차 결과"
	echo "  옮김 $N_OK 개 · 나눠담음 $N_PART 개 · 합계 $(fmt_kb "$MOVED_KB") · 건너뜀 $N_SKIP 개 · 실패 $N_FAIL 개"
	{
		echo " back up status = HDD UUID = $UUID , Back up date = $(date)"
		echo " 옮김 $N_OK / 건너뜀 $N_SKIP / 실패 $N_FAIL"
		[ -n "$SKIPPED_LIST" ] && echo " skipped:$SKIPPED_LIST"
	} >> "$LOG_FILE"
	return 0
}

# =====================================================================
#  메일 본문 — 어느 메일이든 이 꼬리를 붙인다.
#  새벽에 이것만 받아 보고 사람이 움직일 수 있어야 한다.
# =====================================================================
body_tail() {
	echo "── 하드별 결과 ──────────────────────────────────────────"
	if [ -s "$PLANDIR/disks.txt" ]; then
		cat "$PLANDIR/disks.txt"
	else
		echo "  (이번 세션에서 담은 하드가 없습니다)"
	fi
	echo ""
	echo "── 서버에 남은 일 ───────────────────────────────────────"
	if [ "${REMAIN_N:--1}" -lt 0 ]; then
		echo "  (확인하지 않았습니다)"
	elif [ "$REMAIN_N" -eq 0 ]; then
		echo "  옮길 것이 남아 있지 않습니다."
	else
		echo "  옮길 것이 남은 런 : $REMAIN_N 개"
		echo "  앞 10 개 :$REMAIN_LIST"
	fi
	echo ""
	echo "── 이번 세션 로그 (끝 40 줄) ────────────────────────────"
	tail -n "+$((LOG_MARK+1))" "$LOG_FILE" 2>/dev/null | tail -40
	echo ""
	echo "─────────────────────────────────────────────────────────"
	echo "  호스트 : $(hostname)    시각 : $(date '+%F %T')"
	echo "  원본   : $SOURCE_PARENT"
	echo "  로그   : $LOG_FILE"
	echo "  조각   : $PARTS_INDEX  (런이 여러 하드에 나뉘어 담긴 기록)"
	echo "  스크립트 : $0"
}

#  종료 — 화면에는 이미 사유를 찍은 뒤에 부른다. 본문 머리말은 stdin 으로 받는다.
finish() {               # 종료코드  제목
	local code=$1 subj=$2 bf="$PLANDIR/mail.body"
	{ cat; echo ""; body_tail; } > "$bf" 2>/dev/null
	queue_mail "$subj" "$bf"
	if [ "$MAIL_ENABLE" = 1 ]; then
		if [ "$MAIL_QUEUED" -gt 0 ]; then
			echo "✉️  메일 $MAIL_QUEUED 통을 큐에 넣었습니다 ($MAILQ_DIR)."
			echo "   DAQ PC 의 cron 이 5분 안에 보냅니다."
		fi
	fi
	echo "[$(date)] 종료 code=$code : $subj" >> "$LOG_FILE"
	exit "$code"
}

# =====================================================================
#  시작 — 확인과 잠금
# =====================================================================
[ -t 1 ] && clear
echo "=========================================================="
echo "           스마트 백업 시스템 (여러 하드 순차 모드)"
echo "    현재 백업작업중인 터미널은 스토리지 서버안입니다!    "
echo "=========================================================="
echo "  하드 순서 : ${DISKS[*]}"
[ "$DRYRUN" -eq 1 ] && echo "※ --dry-run : 아무것도 옮기거나 지우지 않습니다."

[ -d "$SOURCE_PARENT" ] || { echo "❌ 에러: $SOURCE_PARENT 가 없습니다."; exit 1; }
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$SIZE_CACHE")" 2>/dev/null
touch "$SIZE_CACHE" "$LOG_FILE" 2>/dev/null

#  ★ 두 번 겹쳐 돌면 같은 파일을 둘이 옮기고 둘이 지운다. 반드시 막는다.
#
#  ★ 잠금만으로는 부족하다. 옛 판본으로 띄워 둔 것은 이 잠금을 쥐지 않는다.
#    실제로 2026-09-02 에 01:48 에 돌던 것을 못 보고 02:24 에 하나를 더 띄워,
#    같은 USB 하드에 30+50 = 80 MB/s 를 동시에 쏟은 적이 있다 (그 속도는
#    08-27 에 이 하드가 버스에서 떨어진 바로 그 속도다). 그래서 프로세스
#    목록도 함께 본다.
#
#  ★ pgrep -f 는 명령줄 전체를 본다. 그래서 자기 계보가 함께 잡힌다.
#    자손만 빼는 것으로는 부족하다 -- 두 방향을 다 빼야 한다.
#
#      자손 : $(...) 서브셸.  그 프로세스의 조상을 거슬러 $$ 가 나온다
#      조상 : 나를 띄운 셸.  그 셸의 명령줄에 이 스크립트 경로가 통째로
#             들어 있으면(ssh 로 긴 명령을 보낼 때가 그렇다) 그대로 걸린다.
#             2026-09-03 시험에서 실제로 이것 때문에 한 번도 못 돌았다.
#             찾은 pid 가 내 조상 목록에 있으면 뺀다.
my_ancestors() {
	local anc=$$ i out=""
	for i in 1 2 3 4 5 6 7 8; do
		anc=$(ps -o ppid= -p "$anc" 2>/dev/null | tr -d ' ')
		{ [ -n "$anc" ] && [ "$anc" != 0 ]; } || break
		out="$out $anc"
	done
	echo "$out"
}
other_backup() {
	local p anc i found mine args
	mine=" $(my_ancestors) "
	for p in $(pgrep -f 'data_backup_simple_code[0-9]*\.sh|storage-backup\.sh' 2>/dev/null); do
		[ "$p" = "$$" ] && continue
		case "$mine" in *" $p "*) continue ;; esac      # 내 조상
		#  ★ 이미 죽은 것은 백업이 아니다.
		#    $( ) 를 쓰면 bash 가 이 스크립트의 명령줄을 그대로 물려받은
		#    서브셸을 잠깐 만든다. pgrep 은 그것을 잡는데, 우리가 확인할
		#    때는 벌써 사라져 있어 조상 추적이 빈손으로 끝난다. 그러면
		#    '남의 백업' 으로 오인해 영원히 못 돈다 (2026-09-03 시험에서
		#    이것 때문에 한 회차도 시작하지 못했다).
		args=$(ps -o args= -p "$p" 2>/dev/null)
		[ -n "$args" ] || continue
		found=0; anc=$p
		for i in 1 2 3 4 5 6; do
			anc=$(ps -o ppid= -p "$anc" 2>/dev/null | tr -d ' ')
			{ [ -n "$anc" ] && [ "$anc" != 0 ]; } || break
			[ "$anc" = "$$" ] && { found=1; break; }
		done
		[ "$found" = 1 ] && continue                    # 내 자손
		echo "$p"; return 0
	done
	return 1
}
if OTHER=$(other_backup); then
	echo "❌ 이미 백업이 돌고 있습니다 (pid $OTHER)."
	echo "   $(ps -o lstart=,args= -p "$OTHER" 2>/dev/null | sed 's/^ *//')"
	echo "   그 백업이 끝난 뒤에 다시 실행하세요. 같은 하드에 둘이 쓰면"
	echo "   용량 계산이 어긋나고, 속도가 겹쳐 USB 하드가 떨어질 수 있습니다."
	exit 1
fi

mkdir -p "$(dirname "$LOCK")" 2>/dev/null
exec 9>"$LOCK" || exit 1
if ! flock -n 9; then
	echo "❌ 이미 백업이 돌고 있습니다 (잠금 $LOCK)."
	exit 1
fi

cd "$SOURCE_PARENT" || exit 1

PLANDIR=$(mktemp -d) || exit 1
trap 'rm -rf "$PLANDIR"' EXIT
: > "$PLANDIR/disks.txt"

SESSION_T0=$(date +%s)
LOG_MARK=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
echo "Data backup start, by sykim, $(date) " >> "$LOG_FILE"
echo "[$(date)] 세션 시작 하드=${DISKS[*]} bwlimit=${BWLIMIT:-없음} split=$SPLIT_MODE" >> "$LOG_FILE"

#  ★ 시작할 때 하드 상태를 한 번에 보여준다. 8시간짜리 작업을 눈감고
#    시작하지 않기 위한 것이고, 못 쓰는 하드를 미리 알아채기 위한 것이다.
echo ""
echo "  쓸 하드"
for M in "${DISKS[@]}"; do
	if ! disk_is_mounted "$M"; then
		printf '    %-16s ❌ 마운트되어 있지 않음\n' "$M"; continue
	fi
	disk_ident "$M"
	printf '    %-16s %s  여유 %s  %s\n' "$M" "${D_DEV:-?}" \
		"$(fmt_kb "$(disk_avail_kb "$M")")" \
		"$( [ -w "$M" ] && echo '쓰기 가능' || echo '⚠️  쓰기 권한 없음 — 아래 조치 필요' )"
	[ -w "$M" ] || printf '                     sudo chown %s:%s %s\n' "$(id -un)" "$(id -gn)" "$M"
done
echo ""

TOT_OK=0; TOT_PARTRUN=0; TOT_FAIL=0; TOT_KB=0; TOT_SKIP=0
REMAIN_N=-1; REMAIN_LIST=""
USED_DISKS=""; LAST_DISK=""; OUTCOME=""

# =====================================================================
#  하드를 순서대로 — 이 루프가 이 스크립트의 핵심이다.
# =====================================================================
for IDXD in "${!DISKS[@]}"; do
	M=${DISKS[$IDXD]}
	FIRST=0; [ "$IDXD" -eq 0 ] && FIRST=1

	# --- 마운트 확인 ------------------------------------------------
	if ! disk_is_mounted "$M"; then
		if [ "$FIRST" -eq 1 ]; then
			echo "❌ 에러: $M 가 마운트되어 있지 않습니다."
			finish 1 "스토리지 백업 실패 — 첫 하드 $M 가 마운트되어 있지 않습니다" <<EOF
백업을 시작하지 못했습니다.

  첫 하드 $M 가 마운트되어 있지 않습니다.

★ df 가 멀쩡해 보여도 장치가 사라진 '유령 마운트' 일 수 있습니다.
  확인 :  ls /dev/sd*  ·  lsblk  ·  findmnt $M  ·  dmesg -T | tail -30
  마운트 :  sudo mount UUID=<그 디스크의 UUID> $M
EOF
		fi
		#  ★ 여기가 요청하신 판정이다 — 앞 하드를 다 채우고 넘어왔는데 없다.
		echo "❌ 다음 하드 $M 가 마운트되어 있지 않습니다. 백업을 여기서 멈춥니다."
		finish 1 "스토리지 백업 중단 — 다음 하드 $M 가 마운트되어 있지 않습니다" <<EOF
앞 하드를 다 채우고 $M 로 이어가려 했으나, 그 하드가 마운트되어 있지 않습니다.
아직 옮기지 못한 자료가 서버에 남아 있습니다.

  다 채운 하드 : $LAST_DISK
  이어갈 하드  : $M   ← 마운트되어 있지 않음

★ df 가 멀쩡해 보여도 장치가 사라진 '유령 마운트' 일 수 있습니다.
  확인 :  ls /dev/sd*  ·  lsblk  ·  findmnt $M  ·  dmesg -T | tail -30
  마운트 :  sudo mount UUID=<그 디스크의 UUID> $M
  그런 뒤 같은 명령을 다시 실행하면 남은 것부터 이어집니다.
EOF
	fi

	# --- ★ 목적지에 실제로 쓸 수 있는가 -----------------------------
	#  마운트만 보고 넘어가면 계획을 다 세운 뒤에야 첫 rsync 에서 죽는다.
	if ! dest_ready "$M"; then
		echo "❌ $M 에 쓸 수 없습니다 — $DEST_ERR"
		finish 1 "스토리지 백업 중단 — $M 에 쓸 수 없습니다" <<EOF
$M 는 마운트되어 있지만 백업 폴더를 만들거나 쓸 수 없습니다.

  하드      : $M   (${D_DEV:-?}  UUID=${D_UUID:-?})
  목적지    : $M/$DEST_SUBDIR
  사유      : $DEST_ERR

★ 갓 포맷한 하드에서 가장 흔한 원인은 권한입니다. 마운트 지점의 루트가
  root 소유이면 일반 계정은 그 밑에 폴더를 만들 수 없습니다.

  확인 :  ls -ld $M
  조치 :  sudo chown $(id -un):$(id -gn) $M
          (또는  sudo mkdir -p $M/$DEST_SUBDIR && sudo chown $(id -un):$(id -gn) $M/$DEST_SUBDIR )

  읽기전용으로 다시 마운트된 경우라면 :  mount | grep $M   ·  dmesg -T | tail -30
EOF
	fi

	# --- 여유 공간 확인 ---------------------------------------------
	AVAIL=$(disk_avail_kb "$M")
	if [ "$((AVAIL - SAFETY_MARGIN))" -lt "$MIN_USEFUL" ]; then
		if [ "$FIRST" -eq 1 ]; then
			#  첫 하드가 이미 차 있는 것은 오류가 아니다 — 지난 세션에서 채운 것이다.
			#  그대로 다음 하드로 넘어간다.
			echo "ℹ️  $M 는 이미 가득 찼습니다 (여유 $(fmt_kb "$AVAIL")). 다음 하드로 넘어갑니다."
			echo "[$(date)] $M 이미 가득 참 -> 다음 하드" >> "$LOG_FILE"
			LAST_DISK=$M
			continue
		fi
		#  ★ 요청하신 또 하나의 판정 — 넘어왔는데 그 하드도 가득 찼다.
		echo "❌ 다음 하드 $M 에 여유 공간이 없습니다. 백업을 여기서 멈춥니다."
		finish 1 "스토리지 백업 중단 — 다음 하드 $M 에 여유 공간이 없습니다" <<EOF
앞 하드를 다 채우고 $M 로 이어가려 했으나, 그 하드에도 여유 공간이 없습니다.
아직 옮기지 못한 자료가 서버에 남아 있습니다.

  다 채운 하드 : $LAST_DISK
  이어갈 하드  : $M
      여유 $(fmt_kb "$AVAIL")  /  필요한 최소 $(fmt_kb "$((SAFETY_MARGIN + MIN_USEFUL))")
      (안전 마진 $(fmt_kb "$SAFETY_MARGIN") + 최소 유효 $(fmt_kb "$MIN_USEFUL"))

★ 하드를 새 것으로 바꾸고 같은 명령을 다시 실행하면 남은 것부터 이어집니다.
  가득 찬 하드는 그대로 보관하시면 됩니다 — 담긴 것은 이미 대조를 통과했습니다.
EOF
	fi

	# --- 이 하드를 채운다 -------------------------------------------
	LAST_DISK=$M
	USED_DISKS="$USED_DISKS $M"
	run_pass "$M"
	PASS_EL=$(( $(date +%s) - PASS_T0 ))
	TOT_OK=$((TOT_OK + N_OK)); TOT_PARTRUN=$((TOT_PARTRUN + N_PART))
	TOT_FAIL=$((TOT_FAIL + N_FAIL)); TOT_KB=$((TOT_KB + MOVED_KB))
	TOT_SKIP=$((TOT_SKIP + N_SKIP))
	{
		echo "[$M]"
		disk_block "$M"
		echo "  이번 회차: 옮김 $N_OK 개 · 나눠담음 $N_PART 개 · 실패 $N_FAIL 개 · $(fmt_kb "$MOVED_KB") · 소요 $(fmt_sec "$PASS_EL")"
		echo ""
	} >> "$PLANDIR/disks.txt"

	#  연속 실패로 중단 — 하드웨어를 의심해야 한다. 다음 하드로 넘어가지 않는다.
	if [ "$PASS_RC" -eq 2 ]; then
		remaining_work; :
		OUTCOME=hwfail
		finish 1 "스토리지 백업 중단 — $M 전송이 연속 ${MAX_CONSEC_FAIL}회 실패했습니다" <<EOF
$M 로 보내던 중 연속 ${MAX_CONSEC_FAIL}회 실패해 백업을 멈췄습니다.
★ 외장하드가 버스에서 떨어졌을 수 있습니다 (2026-08-27 · 08-28 에 겪은 그 증상).

  확인 :  ls /dev/sd*        그 장치가 실제로 있는지 먼저 본다
          dmesg -T | tail -30    'device offline' 뒤에 'Attached SCSI disk' 가 보이면
                                 디스크가 떨어졌다 다른 이름으로 다시 붙은 것이다
          df -h $M           ★ df 가 멀쩡해 보여도 유령 마운트일 수 있다

★ 원본은 지우지 않았습니다. 대조를 통과한 것만 지우는 설계라,
  이 실패로 잃은 자료는 없습니다.
EOF
	fi

	#  --- 이 회차를 마쳤다. 다음을 어떻게 할까 -----------------------
	if [ "$DRYRUN" -eq 1 ]; then
		echo ""
		echo "※ --dry-run 이라 첫 하드의 계획만 보고 끝냅니다."
		echo "   실제 실행에서는 이 하드가 가득 차면 다음 하드로 이어집니다."
		OUTCOME=dryrun
		break
	fi

	if ! remaining_work; then
		OUTCOME=done
		break
	fi

	AVAIL=$(disk_avail_kb "$M")
	if [ "$((AVAIL - SAFETY_MARGIN))" -lt "$MIN_USEFUL" ]; then
		#  하드가 찼다. 다음 하드로 넘어간다.
		NEXT=${DISKS[$((IDXD+1))]:-}
		echo ""
		echo "📦 $M 가 가득 찼습니다 (여유 $(fmt_kb "$AVAIL")). 옮길 것이 $REMAIN_N 개 런 남았습니다."
		if [ -n "$NEXT" ]; then
			echo "   → 다음 하드 $NEXT 로 이어갑니다."
			echo "[$(date)] $M 가득 참 -> $NEXT 로 이어감 (남은 런 $REMAIN_N)" >> "$LOG_FILE"
			#  ★ 사람이 이 메일을 보고 하드를 뽑아 갈 수 있어야 한다. 그래서
			#    다음 하드로 넘어가는 이 순간에 한 통 보낸다.
			{
				echo "$M 가 가득 차 다음 하드 $NEXT 로 이어갑니다."
				echo "이 하드는 이제 뽑아 보관하셔도 됩니다 — 담긴 것은 모두 대조를 통과했습니다."
				echo ""
				body_tail
			} > "$PLANDIR/mail.body"
			queue_mail "스토리지 백업 — $M 가득 참, $NEXT 로 이어갑니다" "$PLANDIR/mail.body"
			continue
		fi
		OUTCOME=nodisk
		break
	fi

	#  하드는 안 찼는데 진도가 안 나갔다. 왜인지를 갈라야 한다 —
	#  ★ 전송이 실패한 것과 애초에 담을 수 없는 것은 조치가 전혀 다르다.
	if [ "$N_FAIL" -gt 0 ]; then
		OUTCOME=xferfail
		break
	fi
	OUTCOME=stuck
	break
done

# =====================================================================
#  마무리
# =====================================================================
[ "${REMAIN_N:--1}" -lt 0 ] && { remaining_work || true; }
SESSION_EL=$(( $(date +%s) - SESSION_T0 ))

echo ""
echo "=========================================================="
echo "  세션 합계 : 옮김 $TOT_OK 개 · 나눠담음 $TOT_PARTRUN 개 · $(fmt_kb "$TOT_KB")"
echo "              건너뜀 $TOT_SKIP 개 · 실패 $TOT_FAIL 개 · 소요 $(fmt_sec "$SESSION_EL")"
echo "  쓴 하드   :${USED_DISKS:- (없음)}"
echo "=========================================================="
echo "Data backup done, by sykim, $(date) " >> "$LOG_FILE"

case "$OUTCOME" in
dryrun)
	echo "※ 아무것도 옮기거나 지우지 않았습니다."
	exit 0
	;;
done)
	echo "🎉 백업이 안전하게 끝났습니다! 옮길 것이 더 남아 있지 않습니다." | tee -a "$LOG_FILE"
	finish 0 "스토리지 백업 완료 — 옮김 $TOT_OK 개 · $(fmt_kb "$TOT_KB")" <<EOF
백업이 정상적으로 끝났습니다. 서버에 옮길 것이 더 남아 있지 않습니다.

  옮긴 런     : $TOT_OK 개
  나눠 담은 런: $TOT_PARTRUN 개
  총 용량     : $(fmt_kb "$TOT_KB")
  실패        : $TOT_FAIL 개
  소요 시간   : $(fmt_sec "$SESSION_EL")
  쓴 하드     :${USED_DISKS:- (없음)}
EOF
	;;
nodisk)
	echo "⚠️  지정한 하드를 모두 채웠는데 아직 옮길 것이 남았습니다 (런 $REMAIN_N 개)."
	echo "   하드를 새 것으로 바꾸고 같은 명령을 다시 실행하면 이어집니다."
	finish 3 "스토리지 백업 — 하드를 다 썼습니다. 교체가 필요합니다 (런 $REMAIN_N 개 남음)" <<EOF
지정한 하드(${DISKS[*]})를 모두 가득 채웠는데, 아직 옮기지 못한 자료가 남아 있습니다.

  옮긴 런     : $TOT_OK 개   ($(fmt_kb "$TOT_KB"))
  남은 런     : $REMAIN_N 개
  소요 시간   : $(fmt_sec "$SESSION_EL")

★ 가득 찬 하드를 새 것으로 바꾸고 같은 명령을 다시 실행하면 남은 것부터 이어집니다.
  뽑아 가는 하드에 담긴 것은 모두 대조(개수+바이트)를 통과했습니다.
EOF
	;;
xferfail)
	echo "❌ 전송이 실패해 진도가 나가지 않았습니다 (이번 회차 실패 $N_FAIL 건, 남은 런 $REMAIN_N 개)."
	echo "   ★ 원본은 지우지 않았습니다. 사유는 로그의 FAIL 줄에 있습니다 :"
	echo "     grep FAIL $LOG_FILE | tail -20"
	finish 1 "스토리지 백업 중단 — 전송이 실패했습니다 (실패 $N_FAIL 건)" <<EOF
하드에 자리가 남아 있는데 전송이 실패해 한 발짝도 나가지 못했습니다.

  마지막 하드 : $LAST_DISK   (여유 $(fmt_kb "$(disk_avail_kb "$LAST_DISK")"))
  이번 회차   : 실패 $N_FAIL 건 · 옮김 $N_OK 개
  남은 런     : $REMAIN_N 개

★ 원본은 하나도 지우지 않았습니다. 대조를 통과한 것만 지우는 설계입니다.

사유를 보는 곳 :
  grep FAIL $LOG_FILE | tail -20

자주 나오는 것 :
  mkdir ... Permission denied          목적지 폴더를 만들 권한이 없다
        -> ls -ld $LAST_DISK  ·  sudo chown $(id -un):$(id -gn) $LAST_DISK
  No such file or directory            목적지 상위 폴더가 없다 (대개 위와 같은 원인)
  Input/output error / rc=23           ★ 하드가 버스에서 떨어졌을 수 있다
        -> ls /dev/sd*  ·  dmesg -T | tail -30
EOF
	;;
stuck)
	echo "⚠️  하드에 자리가 남았는데도 더 담지 못했습니다 (남은 런 $REMAIN_N 개)."
	if [ "$N_TOOBIG" -gt 0 ] || [ "$SPLIT_MODE" != always ]; then
		echo "   쪼개기 모드가 --split $SPLIT_MODE 입니다. 하드보다 큰 런은"
		echo "   --split always (기본값) 라야 나눠 담깁니다."
	else
		echo "   계획이 비어 있었습니다. 남은 런이 전부 '다른 작업이 쓰는 중'이거나,"
		echo "   용량을 잴 수 없는 상태일 수 있습니다."
		echo "   확인 :  $0 --dry-run"
	fi
	finish 3 "스토리지 백업 — 더 담지 못했습니다 (남은 런 $REMAIN_N 개)" <<EOF
하드에 자리가 남아 있는데도 더 담지 못했습니다. 하드를 바꿔도 해결되지 않으므로
하드를 태우지 않고 여기서 멈췄습니다.

  마지막 하드 : $LAST_DISK   (여유 $(fmt_kb "$(disk_avail_kb "$LAST_DISK")"))
  남은 런     : $REMAIN_N 개
  이번 회차   : 옮김 $N_OK · 건너뜀 $N_SKIP (그중 하드보다 큰 런 $N_TOOBIG) · 쓰는 중 $N_BUSY
  쪼개기 모드 : --split $SPLIT_MODE

★ 무엇을 담으려 했는지는 계획으로 볼 수 있습니다 (아무것도 바꾸지 않습니다) :
  $0 --dry-run
EOF
	;;
*)
	#  하드 목록이 비었거나 첫 하드가 이미 차 있고 그 뒤가 없는 경우
	if [ "${REMAIN_N:-0}" -gt 0 ]; then
		echo "⚠️  쓸 수 있는 하드가 없습니다. 옮길 것이 런 $REMAIN_N 개 남았습니다."
		finish 3 "스토리지 백업 — 쓸 수 있는 하드가 없습니다 (런 $REMAIN_N 개 남음)" <<EOF
지정한 하드(${DISKS[*]})가 모두 가득 차 있어 한 개도 담지 못했습니다.

  남은 런 : $REMAIN_N 개

★ 하드를 새 것으로 바꾸고 같은 명령을 다시 실행하세요.
EOF
	fi
	echo "🎉 옮길 것이 없습니다." | tee -a "$LOG_FILE"
	finish 0 "스토리지 백업 — 옮길 것이 없습니다" <<EOF
백업을 돌렸으나 옮길 것이 없었습니다. 정상입니다.
EOF
	;;
esac
