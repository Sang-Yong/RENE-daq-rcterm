#!/usr/bin/env bash
# minerwatch.sh -- DAQ PC 에 채굴기·위장 프로세스가 또 생기면 책임자에게 알린다. cron 이 10 분마다 부른다 (2026-10-09, CLAUDE.md §11.210).
#   읽기 전용. root 가 아니라서 세우지는 못한다 -- 징후를 잡아 메일을 보내고 /Data_ssd/LOG/minerwatch.log 에 남긴다.
#     minerwatch.sh              검사 + (징후가 있으면) 메일.  같은 징후는 6 시간에 한 번
#     minerwatch.sh --status     지금 징후만 찍는다 (메일 없음, 상태 파일 안 건드림)
#     minerwatch.sh --dry-run    검사 + 메일 본문을 찍되 보내지 않는다
#     minerwatch.sh --install-cron
#   징후 (2026-09-10 의 실물에서 뽑았다, §11.209) :
#     A  명령줄이 ./sshd ./rcu-sched ./kworker ./kthreadd 처럼 상대 경로로 뜬 시스템 이름 (진짜는 /usr/sbin/sshd, 커널 스레드는 [rcu_sched])
#     B  /dev/shm · /tmp/.* · /var/tmp/.* 안의 실행 파일
#     C  채굴 풀 포트(3333 3334 4444 5555 14444 45700. 7777 은 store ssh 라 제외)로 맺힌 TCP 연결
#     D  frontend·root 가 아닌 계정의 프로세스가 300 % CPU 넘게 10 분 이상 (분석 작업일 수 있어 '참고' 로만 싣는다)
#   시험 : MINERWATCH_PS · MINERWATCH_SS · MINERWATCH_FIND 로 ps/ss/find 출력을 갈아끼운다. MINERWATCH_MAIL 로 가짜 send_mail.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
LOGDIR=${MINERWATCH_LOGDIR:-/Data_ssd/LOG}; LOG=$LOGDIR/minerwatch.log; STATE=$LOGDIR/minerwatch.state
MAIL=${MINERWATCH_MAIL:-$DIR/tools/notify/send_mail.py}; PARAMS=$DIR/config/notify.params
EVERY=${MINERWATCH_MAIL_EVERY:-21600}; CPU_HI=${MINERWATCH_CPU_HI:-300}
PORTS='3333|3334|4444|5555|14444|45700'   # 7777 은 저장소 서버 ssh 포트라 뺀다
MODE=run
case "${1:-}" in --status) MODE=status;; --dry-run) MODE=dry;; "") ;;
   --install-cron)
      cur=$(crontab -l 2>/dev/null); printf '%s\n' "$cur" | grep -q 'minerwatch.sh' && { echo "이미 등록돼 있다"; exit 0; }
      cp <(printf '%s\n' "$cur") "$HOME/crontab.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null
      { printf '%s\n' "$cur"; printf '# 채굴기·위장 프로세스 감시 (CLAUDE.md 11.210). 상태 : scripts/minerwatch.sh --status\n*/10 * * * * %s/scripts/minerwatch.sh >/dev/null 2>&1\n' "$DIR"; } | crontab - && echo "등록했다 (*/10)"; exit $? ;;
   -h|--help) sed -n '2,16p' "$0"; exit 0;; *) echo "모르는 옵션 : $1"; exit 1;; esac
mkdir -p "$LOGDIR" 2>/dev/null
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

ps_lines() { if [ -n "${MINERWATCH_PS:-}" ]; then cat "$MINERWATCH_PS"; else ps -eo pid=,user=,pcpu=,etimes=,args= 2>/dev/null; fi; }
ss_lines() { if [ -n "${MINERWATCH_SS:-}" ]; then cat "$MINERWATCH_SS"; else ss -tnH state established 2>/dev/null; fi; }
find_exec() { if [ -n "${MINERWATCH_FIND:-}" ]; then cat "$MINERWATCH_FIND"; else
   find /dev/shm -maxdepth 3 -type f -perm /111 2>/dev/null
   find /tmp /var/tmp -maxdepth 1 -name '.*' -type d 2>/dev/null | while read -r d; do find "$d" -maxdepth 2 -type f -perm /111 2>/dev/null; done; fi; }

A=$(ps_lines | awk '{cmd=$5; if (cmd ~ /^\.\/(sshd|rcu[-_]sched|kworker|kthreadd|kswapd|crond|systemd|ksoftirqd|migration)$/) print "  pid "$1" "$2" cpu "$3"% up "$4"s : "$5" "$6}')
B=$(find_exec | sed 's/^/  /')
C=$(ss_lines | awk -v P="^($PORTS)$" '{n=split($4,r,":"); if (r[n] ~ P) print "  -> "$4}' | sort | uniq -c | sed 's/^ *\([0-9]*\) /  x\1 /')
D=$(ps_lines | awk -v hi="$CPU_HI" '$2!="frontend" && $2!="root" && $3+0>=hi && $4+0>=600 {print "  pid "$1" "$2" cpu "$3"% up "int($4/60)"m : "$5" "$6}')

body=""; sig=""
[ -n "$A" ] && { body+="[A] 상대 경로로 뜬 시스템 이름 프로세스 (위장 의심)\n$A\n"; sig+="A$(printf '%s' "$A" | md5sum | cut -c1-8)"; }
[ -n "$B" ] && { body+="[B] /dev/shm · /tmp/.* 안의 실행 파일\n$B\n"; sig+="B$(printf '%s' "$B" | md5sum | cut -c1-8)"; }
[ -n "$C" ] && { body+="[C] 채굴 풀 포트($PORTS)로 맺힌 연결\n$C\n"; sig+="C$(printf '%s' "$C" | sed 's/.*://' | sort -u | md5sum | cut -c1-8)"; }
[ -n "$D" ] && { body+="[D] (참고) 다른 계정의 고 CPU 프로세스 (${CPU_HI}% 이상, 10 분 이상)\n$D\n"; }

if [ "$MODE" = status ]; then
   if [ -z "$body" ]; then echo "징후 없음"; else printf '%b' "$body"; fi
   [ -f "$STATE" ] && echo "상태 : $(tr '\n' ' ' < "$STATE")"; exit 0
fi
if [ -z "$sig" ]; then
   [ -f "$STATE" ] && grep -q '^sig=' "$STATE" && grep -q '^sig=.\+' "$STATE" && log "[OK  ] 징후 해소 (이전 $(sed -n 's/^sig=//p' "$STATE"))"
   printf 'sig=\nlast_mail=%s\n' "$(sed -n 's/^last_mail=//p' "$STATE" 2>/dev/null)" > "$STATE"
   [ -n "$D" ] && log "[INFO] 고 CPU 참고 : $(printf '%s' "$D" | tr '\n' ';')"
   exit 0
fi
log "[WARN] 징후 $sig : $(printf '%b' "$body" | tr '\n' ';' | cut -c1-400)"
prev=$(sed -n 's/^sig=//p' "$STATE" 2>/dev/null); lastm=$(sed -n 's/^last_mail=//p' "$STATE" 2>/dev/null); lastm=${lastm:-0}; now=$(date +%s)
if [ "$sig" = "$prev" ] && [ $((now - lastm)) -lt "$EVERY" ]; then log "[MAIL] 생략 (같은 징후, $(( (now - lastm) / 60 )) 분 전)"; printf 'sig=%s\nlast_mail=%s\n' "$sig" "$lastm" > "$STATE"; exit 0; fi
text="DAQ PC 에서 채굴기·위장 프로세스 징후가 보입니다 ($(date '+%F %T')). minerwatch 는 frontend 권한이라 세우지 못합니다 -- root 로 확인하세요.

$(printf '%b' "$body")
무엇을 하면 되나 (root) :
  sudo bash /Data_ssd/LOG/security-20261009/cleanup-root.sh --dry-run   (대상 확인)  →  --dry-run 없이 실행
  정리 뒤 : sudo bash /Data_ssd/LOG/security-20261009/harden-root.sh --apply
지난 사례 : CLAUDE.md §11.209 (2026-09-10 sklee 계정 XMRig). 로그 : $LOG"
if [ "$MODE" = dry ]; then printf '%s\n' "$text"; exit 0; fi
if python3 "$MAIL" --params "$PARAMS" --to routine --subject "[보안] 채굴기·위장 프로세스 징후 ($sig)" --body-file <(printf '%s\n' "$text") >> "$LOG" 2>&1; then
   log "[MAIL] 보냄 $sig"; printf 'sig=%s\nlast_mail=%s\n' "$sig" "$now" > "$STATE"
else
   log "[WARN] 메일 실패"; printf 'sig=%s\nlast_mail=%s\n' "$sig" "$lastm" > "$STATE"
fi
exit 0
