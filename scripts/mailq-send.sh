#!/bin/bash
# =====================================================================
#  mailq-send.sh — 메일 큐를 비운다.  ★ 이 PC(DAQ PC)의 cron 이 부른다.
#
#  왜 있나
#    스토리지 서버(10.0.0.10)에는 인터넷으로 나가는 경로가 없다 (10.0.0.0/24
#    뿐이고 DNS 도 안 된다). 그래서 그 서버의 백업 스크립트는 메일을 직접
#    보내지 못하고 /data/MAILQ 에 파일로 떨군다. 그 자리는 이 PC 에서
#    /scratch/MAILQ 로 보이므로, 여기서 집어 tools/notify/send_mail.py 로 보낸다.
#
#    새 ssh 키도, 새 신뢰 방향도 필요 없다. 이미 마운트돼 있는 것만 쓴다.
#
#  큐 파일 형식 (스토리지 서버의 storage-backup.sh 가 쓴다)
#      subject: <한 줄>
#      to: routine | expert
#      body:
#      <나머지 전부>
#
#  큐는 둘이다 (2026-11-05)
#    /scratch/MAILQ        스토리지 서버가 떨군 것. /scratch 마운트를 요구한다
#    /Data_ssd/LOG/MAILQ   이 PC 의 daq-notify.sh 가 못 보낸 것 (망 단절). 로컬이라 마운트 무관
#
#  하는 일 (큐마다)
#    1) *.mail 을 오래된 것부터 (한 번에 최대 20통)
#    2) <이름>.sending 으로 rename 한 뒤 보낸다  <- 두 번 보내지 않기 위해
#    3) 성공하면 sent/ 로, 5회 실패하면 failed/ 로 옮긴다
#       실패는 그대로 두고 다음 회차에 다시 시도한다 (망 장애는 곧 낫는다)
#       ★ 망 실패(send_mail rc 5 = DNS·접속·타임아웃)는 시도 횟수에 세지 않는다.
#         예전에는 5 회 = 25 분 끊기면 큐가 통째로 failed/ 로 갔다. 망 실패를 만나면 그 회차는
#         거기서 멈춘다 (나머지도 어차피 30 초씩 기다리다 실패한다). 인증 실패(4) 등만 센다
#    4) 큐가 상한(기본 500 통)을 넘으면 오래된 것부터 failed/ 로 -- 망이 며칠 끊겨도 디스크를 안 먹게
#    netsync.sh 가 망 단절(net=down)이라고 적어 두었으면 보내지 않고 물러난다
#
#  ★ 죽지 않는다. 큐가 없어도, /scratch 가 빠져 있어도, 메일이 안 나가도
#    종료코드는 0 이다. 감시·알림이 스스로 넘어지면 없느니만 못하다
#    (daq-notify.sh · chainwatch.sh 와 같은 원칙).
#
#  옵션
#    --status     읽기 전용. 큐에 무엇이 몇 통 있는지만 본다
#    --dry-run    실제로 보내지 않는다 (send_mail.py --dry-run)
#    --queue DIR  이 큐 하나만 (기본은 위 둘, MAILQ_DIRS 로 갈아끼운다)
#                 큐가 /scratch 밑이면 그 마운트를 요구한다.
#                 MAILQ_REQUIRE_MOUNT 로 요구할 마운트를 직접 줄 수도 있다 (큐 하나일 때)
#    --max N      한 회차에 보낼 최대 통수 (기본 20)
# =====================================================================
set -u

SELF=$(readlink -f "$0")
REPO=$(dirname "$(dirname "$SELF")")
PARAMS="${MAILQ_PARAMS:-$REPO/config/notify.params}"
SENDER="${MAILQ_SENDER:-$REPO/tools/notify/send_mail.py}"
#  MAILQ_DIR(또는 --queue) 이 있으면 그 큐 하나만, 아니면 MAILQ_DIRS 의 둘
QUEUES="${MAILQ_DIR:-${MAILQ_DIRS:-/scratch/MAILQ /Data_ssd/LOG/MAILQ}}"
CAP="${MAILQ_CAP:-500}"
NETRC="${MAILQ_NET_RC:-5}"        # send_mail.py 의 망 실패 종료코드
MAXN="${MAILQ_MAX:-20}"
MAXTRY="${MAILQ_MAXTRY:-5}"
#  보내다 죽어 .sending 으로 남은 것을 이 시간[분] 뒤에 되살린다
STALE_MIN="${MAILQ_STALE_MIN:-30}"
LOG="${MAILQ_LOG:-/Data_ssd/LOG/mailq-send.log}"
LOCK="${MAILQ_LOCK:-/Data_ssd/LOG/.mailq-send.lock}"
DRYRUN=0; STATUS=0

while [ $# -gt 0 ]; do
	case "$1" in
		--status)  STATUS=1; shift ;;
		--dry-run) DRYRUN=1; shift ;;
		--queue)   QUEUES=$2; shift 2 ;;
		--max)     MAXN=$2; shift 2 ;;
		--params)  PARAMS=$2; shift 2 ;;
		-h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "모르는 옵션 : $1" >&2; exit 0 ;;
	esac
done

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }
# shellcheck source=/dev/null
. "$REPO/scripts/netsync-lib.sh" 2>/dev/null || netsync_is_down() { return 1; }
NQUEUE=$(set -- $QUEUES; echo $#)
req_mount_of() {          # 큐가 요구하는 마운트 (없으면 빈 문자열)
	if [ "$NQUEUE" -eq 1 ] && [ -n "${MAILQ_REQUIRE_MOUNT-}" ]; then echo "$MAILQ_REQUIRE_MOUNT"; return; fi
	case "$1" in /scratch/*) echo /scratch ;; esac
}

# --- 상태 보기 (읽기 전용) -------------------------------------------
status_one() {
	local QUEUE=$1 req
	echo "큐      : $QUEUE"
	if [ ! -d "$QUEUE" ]; then
		req=$(req_mount_of "$QUEUE")
		if [ -n "$req" ] && ! mountpoint -q "$req" 2>/dev/null; then
			echo "상태    : $req 가 마운트되어 있지 않습니다 (큐를 볼 수 없음)"
		else
			echo "상태    : 큐 디렉터리가 없습니다 (보낼 것이 없다는 뜻입니다)"
		fi
		return 0
	fi
	printf '대기    : %s 통\n' "$(find "$QUEUE" -maxdepth 1 -name '*.mail'    2>/dev/null | wc -l)"
	printf '보내는중: %s 통\n' "$(find "$QUEUE" -maxdepth 1 -name '*.sending' 2>/dev/null | wc -l)"
	printf '보냄    : %s 통\n' "$(find "$QUEUE/sent"   -maxdepth 1 -name '*.mail' 2>/dev/null | wc -l)"
	printf '실패    : %s 통\n' "$(find "$QUEUE/failed" -maxdepth 1 -name '*.mail' 2>/dev/null | wc -l)"
	echo ""
	echo "대기 중인 것 (앞 10 통) :"
	find "$QUEUE" -maxdepth 1 -name '*.mail' 2>/dev/null | sort | head -10 | while read -r f; do
		printf '  %s\n     %s\n' "$(basename "$f")" "$(head -1 "$f" | sed 's/^subject: //')"
	done
	echo ""
}
if [ "$STATUS" -eq 1 ]; then
	for q in $QUEUES; do status_one "$q"; done
	netsync_is_down && echo "망      : ★ netsync 가 단절(net=down)이라고 적어 두었다 -- 망이 돌아올 때까지 보내지 않는다"
	[ -s "$LOG" ] && { echo "최근 로그 :"; tail -5 "$LOG" | sed 's/^/  /'; }
	exit 0
fi

# --- 보낼 수 있는 상황인가 -------------------------------------------
#  ★ 망이 끊긴 것을 netsync 가 이미 안다면 보내지 않는다. 한 통에 30 초씩 타임아웃을 기다리면
#    한 회차가 cron 5 분을 넘는다. 큐는 그대로 남고 망이 돌아오면 netsync 가 이것을 부른다.
#    (상태 파일이 오래됐으면 모르는 것으로 보고 그냥 시도한다 -- netsync-lib.sh)
if [ "$DRYRUN" -eq 0 ] && netsync_is_down; then exit 0; fi
[ -x "$SENDER" ] || { log "발송기가 없다 : $SENDER"; exit 0; }
[ -r "$PARAMS" ] || { log "설정을 읽을 수 없다 : $PARAMS"; exit 0; }

mkdir -p "$(dirname "$LOG")" "$(dirname "$LOCK")" 2>/dev/null

#  ★ cron 이 5분마다 부르는데 한 회차가 5분을 넘길 수 있다 (망이 느릴 때).
#    겹쳐 돌면 같은 메일을 두 번 보낸다. 잠금으로 막는다.
exec 9>"$LOCK" 2>/dev/null || exit 0
flock -n 9 2>/dev/null || exit 0

NETFAIL=0            # 이 회차에 망 실패를 만났다 -> 나머지 큐도 건너뛴다
process_queue() {
	local QUEUE=$1 REQ_MOUNT n over
	#  ★ /scratch 가 빠져 있으면 조용히 물러난다. 큐는 스토리지 서버에 그대로
	#    남아 있으므로, 마운트가 돌아오면 다음 회차에 나간다. 여기서 시끄럽게
	#    굴면 5분마다 로그가 쌓이기만 한다 (2026-09-01 에 하루 종일 빠져 있었다).
	REQ_MOUNT=$(req_mount_of "$QUEUE")
	if [ -n "$REQ_MOUNT" ] && ! mountpoint -q "$REQ_MOUNT" 2>/dev/null; then return 0; fi
	[ -d "$QUEUE" ] || return 0
	mkdir -p "$QUEUE/sent" "$QUEUE/failed" 2>/dev/null

	# --- 보내다 죽어 남은 것을 되살린다 ----------------------------------
	#  .sending 인 채로 STALE_MIN 분이 지났으면 그 프로세스는 죽은 것이다.
	#  ★ 되살리는 쪽이 두 번 보내는 것보다 낫다 — 안 온 메일은 아무도 모른다.
	while IFS= read -r s; do
		[ -n "$s" ] || continue
		mv -f "$s" "${s%.sending}.mail" 2>/dev/null && log "되살림 : $(basename "$s")"
	done < <(find "$QUEUE" -maxdepth 1 -name '*.sending' -mmin "+$STALE_MIN" 2>/dev/null)

	# --- 상한 : 오래된 것부터 failed/ 로 ---------------------------------
	n=$(find "$QUEUE" -maxdepth 1 -name '*.mail' 2>/dev/null | wc -l)
	if [ "$DRYRUN" -eq 0 ] && [ "$n" -gt "$CAP" ]; then
		over=$(( n - CAP ))
		find "$QUEUE" -maxdepth 1 -name '*.mail' 2>/dev/null | sort | head -n "$over" | while IFS= read -r f; do
			mv -f "$f" "$QUEUE/failed/" 2>/dev/null; rm -f "${f%.mail}.try" 2>/dev/null
		done
		log "상한 ${CAP} 통 초과 : 오래된 ${over} 통을 failed/ 로 ($QUEUE)"
	fi

	# --- 큐를 비운다 ------------------------------------------------------
	local SENT=0 FAILED=0 N=0 f snd subj who body rc tryf t
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		N=$((N+1)); [ "$N" -gt "$MAXN" ] && break

		snd="${f%.mail}.sending"
		mv -f "$f" "$snd" 2>/dev/null || continue     # 다른 손이 먼저 집었다

		subj=$(head -1 "$snd" | sed 's/^subject: *//')
		who=$(sed -n '2p'  "$snd" | sed 's/^to: *//')
		case "$who" in routine|expert|both) : ;; *) who=routine ;; esac
		#  3번째 줄이 'body:' 이고 그 뒤가 전부 본문이다
		body="$snd.body"
		tail -n +4 "$snd" > "$body" 2>/dev/null
		[ -n "$subj" ] || subj="스토리지 백업 알림"

		if [ "$DRYRUN" -eq 1 ]; then
			"$SENDER" --params "$PARAMS" --to "$who" --subject "$subj" --body-file "$body" --dry-run
			rc=$?
		else
			"$SENDER" --params "$PARAMS" --to "$who" --subject "$subj" --body-file "$body" >>"$LOG" 2>&1
			rc=$?
		fi
		rm -f "$body" 2>/dev/null

		if [ "$DRYRUN" -eq 1 ]; then
			#  ★ 미리보기는 큐를 소비하지 않는다. 사람이 설정을 점검하려고 돌렸다가
			#    아직 안 나간 알림을 지워 버리면, 그 알림은 아무도 못 본다.
			mv -f "$snd" "${snd%.sending}.mail" 2>/dev/null
		elif [ "$rc" -eq 0 ]; then
			mv -f "$snd" "$QUEUE/sent/$(basename "${snd%.sending}").mail" 2>/dev/null
			rm -f "${snd%.sending}.try" 2>/dev/null
			SENT=$((SENT+1)); log "보냄 : $subj"
		elif [ "$rc" -eq "$NETRC" ]; then
			#  ★ 망 실패는 세지 않는다. 메일 탓이 아니다. 이 회차는 여기서 멈춘다.
			mv -f "$snd" "${snd%.sending}.mail" 2>/dev/null
			log "망 실패 (rc=$rc, 횟수에 세지 않음) : $subj -- 이 회차는 여기서 멈춘다"
			FAILED=$((FAILED+1)); NETFAIL=1
			break
		else
			#  ★ 시도 횟수를 파일 이름이 아니라 곁 파일에 센다. 이름을 바꾸면
			#    정렬 순서(=오래된 것 먼저)가 무너진다.
			tryf="${snd%.sending}.try"
			t=$(cat "$tryf" 2>/dev/null || echo 0); t=$((t+1))
			echo "$t" > "$tryf" 2>/dev/null
			if [ "$t" -ge "$MAXTRY" ]; then
				mv -f "$snd" "$QUEUE/failed/$(basename "${snd%.sending}").mail" 2>/dev/null
				rm -f "$tryf" 2>/dev/null
				log "포기 (${t}회 실패) : $subj"
			else
				mv -f "$snd" "${snd%.sending}.mail" 2>/dev/null
				log "실패 ${t}/${MAXTRY} (rc=$rc) : $subj"
			fi
			FAILED=$((FAILED+1))
		fi
	done < <(find "$QUEUE" -maxdepth 1 -name '*.mail' 2>/dev/null | sort)

	{ [ "$SENT" -gt 0 ] || [ "$FAILED" -gt 0 ]; } && log "회차 종료 ($QUEUE) : 보냄 $SENT · 실패 $FAILED"
	return 0
}

for q in $QUEUES; do
	[ "$NETFAIL" -eq 1 ] && break
	process_queue "$q"
done
exit 0
