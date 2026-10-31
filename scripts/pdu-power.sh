#!/usr/bin/env bash
# pdu-power.sh -- NETIO PDU(192.168.0.3) 웹 API 로 보드 크레이트 전원 채널을 읽고/끄고/켠다 (2026-11-01, CLAUDE.md §11.224).
#   pdu-power.sh status              채널 상태 (읽기 전용. 수집 중이어도 된다)
#   pdu-power.sh off 1 2 3           끈다        pdu-power.sh on 2      켠다
#   pdu-power.sh cycle               1 2 3 끔 -> 10 s -> 2(TCB) 켬 -> 30 s -> 1(FADC)+3(SADC) 켬. 단계마다 상태를 되읽어 확인
#   옵션  --dry-run      로그인을 포함해 어떤 HTTP 도 보내지 않고, 보낼 요청만 찍는다 (비밀번호는 *** 로)
#         --params FILE  자격증명 (기본 <저장소>/config/pdu.params, 0600. 예시는 config/pdu.params.example)
#         --wait N       cycle 의 TCB 뒤 대기 [s] (기본 30)      --off-wait N   cycle 의 끈 뒤 대기 [s] (기본 10)
#         --force        수집 중(rcsupervisor·rcterm·daq·tcb·merger 가 살아 있음)이어도 on/off/cycle 을 한다
#   채널 : 1 FADC · 2 TCB · 3 SADC.  그 밖의 채널과 PDU 설정을 바꾸는 action 은 부르지 않는다
#   켤 때 순서 : TCB(2) 먼저 -> 30 s -> FADC(1)+SADC(3)  (사용자 지시).  끌 때는 셋을 함께 끈다
#   ★ 전원을 내렸다 올리면 트리거 설정이 날아간다 -> NOTICE_CODE_RUN.sh -> usbreset 2 회 -> 10 s 더미 런 -> 확인 런 (§11.119 · §11.224)
#   종료코드 : 0 정상 · 1 사용법/설정/수집 중 거부 · 2 로그인·HTTP·API 실패 · 3 상태 되읽기가 기대와 다름
#   로그 : /Data_ssd/LOG/pdu-power.log (PDU_LOG).  status 와 --dry-run 은 로그를 쓰지 않는다
#   시험 : PDU_CURL · PDU_SLEEP · PDU_PGREP 로 curl/sleep/pgrep 를 갈아끼운다 (tests/pdu-power.test.sh)
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
PARAMS=$DIR/config/pdu.params
LOG=${PDU_LOG:-/Data_ssd/LOG/pdu-power.log}
CURL=${PDU_CURL:-curl}; SLEEP=${PDU_SLEEP:-sleep}; PGREP=${PDU_PGREP:-pgrep}
DRY=0; FORCE=0; WAIT=30; OFFWAIT=10; CMD=""; CHS=()
NAME=([1]=FADC [2]=TCB [3]=SADC)

usage() { sed -n '2,16p' "$0"; }
die() { local rc=$1; shift; printf '%s\n' "$*" >&2; [ "$DRY" = 0 ] && [ "$CMD" != status ] && log "ERROR rc=$rc $*"; exit "$rc"; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; return 0; }
isint() { case "$1" in ''|*[!0-9]*) return 1;; esac; return 0; }

while [ $# -gt 0 ]; do
   case "$1" in
      --dry-run) DRY=1 ;;
      --force) FORCE=1 ;;
      --params) [ $# -ge 2 ] || { echo "--params 에 파일이 필요하다" >&2; exit 1; }; PARAMS=$2; shift ;;
      --wait) [ $# -ge 2 ] && isint "$2" || { echo "--wait 에 0 이상의 정수가 필요하다" >&2; exit 1; }; WAIT=$2; shift ;;
      --off-wait) [ $# -ge 2 ] && isint "$2" || { echo "--off-wait 에 0 이상의 정수가 필요하다" >&2; exit 1; }; OFFWAIT=$2; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) echo "모르는 옵션 : $1" >&2; exit 1 ;;
      *) if [ -z "$CMD" ]; then CMD=$1; else CHS+=("$1"); fi ;;
   esac; shift
done
[ -n "$CMD" ] || { usage; exit 1; }
case "$CMD" in
   status|cycle) [ ${#CHS[@]} -eq 0 ] || { echo "$CMD 는 채널 인자를 받지 않는다" >&2; exit 1; } ;;
   on|off) [ ${#CHS[@]} -gt 0 ] || { echo "$CMD 에 채널(1~3)이 필요하다" >&2; exit 1; }
      U=(); for c in "${CHS[@]}"; do
         case "$c" in 1|2|3) ;; *) echo "채널 $c 는 허용되지 않는다 (1 FADC · 2 TCB · 3 SADC 만)" >&2; exit 1 ;; esac
         case " ${U[*]-} " in *" $c "*) ;; *) U+=("$c") ;; esac
      done; CHS=("${U[@]}") ;;
   *) echo "모르는 명령 : $CMD (status | on N.. | off N.. | cycle)" >&2; exit 1 ;;
esac

# ---- 자격증명 (내용은 화면·로그에 찍지 않는다) ----
{ set +x; } 2>/dev/null      # bash -x 로 불려도 비밀번호가 추적에 안 나오게 (여기부터 끝까지 끈다)
[ -r "$PARAMS" ] || { echo "자격증명 파일이 없다 : $PARAMS" >&2
   echo "  cp $DIR/config/pdu.params.example $DIR/config/pdu.params && chmod 600 $DIR/config/pdu.params  (그 뒤 pass 를 채운다)" >&2; exit 1; }
getp() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PARAMS" | head -1 | sed 's/[[:space:]]*$//'; }
HOST=$(getp host); USER_=$(getp user); PASS=$(getp pass)
[ -n "$HOST" ] && [ -n "$USER_" ] || { echo "자격증명 파일에 host/user 가 없다 : $PARAMS" >&2; exit 1; }
case "$PASS" in ''|'<'*) echo "자격증명 파일의 pass 가 비었거나 예시 그대로다 : $PARAMS" >&2; exit 1 ;; esac
perm=$(stat -c %a "$PARAMS" 2>/dev/null); case "$perm" in 600|400) ;; *) echo "[WARN] $PARAMS 권한이 $perm 이다 -- chmod 600 권장" >&2 ;; esac
API="http://$HOST/api"

# JSON 은 python 으로 만든다 (비밀번호에 따옴표·역슬래시가 있어도 깨지지 않게). 인자 : action [output value] , 환경 MASK=1 이면 *** 로
jbody() { PDU_U=$USER_ PDU_P=$PASS PDU_S=${SID-} python3 -I -c '
import json,os,sys
a=sys.argv[1]; m=os.environ.get("MASK")=="1"
d={"sessionId": "" if a=="login" else ("***" if m else os.environ.get("PDU_S",""))}
d["action"]=a
if a=="login": d["data"]={"username":os.environ["PDU_U"],"password":"***" if m else os.environ["PDU_P"]}
if a=="setOutputState": d["data"]={"output":int(sys.argv[2]),"value":int(sys.argv[3])}
print(json.dumps(d))' "$@"; }

# 응답 검사 : JSON 이 아니거나 errorCode/error 가 있으면 사유를 찍고 1
apierr() { python3 -I -c '
import json,sys
try: d=json.loads(sys.stdin.read() or "null")
except Exception: print("JSON 이 아닌 응답"); sys.exit(1)
if not isinstance(d,dict): print("예상과 다른 응답"); sys.exit(1)
# NETIO 실물 형식 (netio-all.js CoreJsonParser.getErrors) : {"errors":[{"code":"1004","message":..,"severity":"fatal"}]}
#   성공 코드 0 SUCCESS · 626 SOME_ERRORS_OCCURED.  1000 INVALID_SESSION_ID · 1002 FORBIDDEN · 1004 INVALID_CREDENTIALS
E=d.get("errors")
if E is None: sys.exit(0)
if not isinstance(E,list): print("errors 가 리스트가 아니다"); sys.exit(1)
names={1000:"INVALID_SESSION_ID",1002:"FORBIDDEN",1004:"INVALID_CREDENTIALS",1021:"ALREADY_LOGGED_IN"}
bad=[]
for e in E:
    if not isinstance(e,dict): bad.append("?"); continue
    try: c=int(str(e.get("code","")).strip())
    except ValueError: c=None
    if c not in (0,626) or e.get("severity")=="fatal":
        bad.append("code %s%s%s" % (e.get("code"), (" "+names[c]) if c in names else "", (": "+str(e.get("message"))[:120]) if e.get("message") else ""))
if bad: print("; ".join(bad)); sys.exit(1)'; }

SID=""
api() {   # $1 action ... -> 응답을 stdout. dry-run 이면 보내지 않는다
   if [ "$DRY" = 1 ]; then echo "[dry-run] POST $API $(MASK=1 jbody "$@")" >&2
      case "$1" in login) echo '{"data":{"sessionId":"DRYRUN"}}';; *) echo '{}';; esac; return 0; fi
   local body out rc
   body=$(jbody "$@") || return 2
   out=$(printf '%s' "$body" | "$CURL" -sS -f -m 10 --noproxy '*' -H 'Content-Type: application/json' --data-binary @- "$API" 2>/dev/null); rc=$?
   [ $rc -eq 0 ] || { echo "HTTP 실패 : $1 (curl rc=$rc, $API)" >&2; return 2; }
   printf '%s' "$out"
}
logout() { [ -n "$SID" ] && [ "$DRY" = 0 ] && api logout >/dev/null 2>&1; SID=""; return 0; }
trap 'rc=$?; logout; exit $rc' EXIT

login() {
   local r why; r=$(api login) || die 2 "로그인 요청 실패 ($API)"
   SID=$(printf '%s' "$r" | python3 -I -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print((d.get("data") or {}).get("sessionId") or d.get("sessionId") or "")' 2>/dev/null)
   [ -n "$SID" ] || { why=$(printf '%s' "$r" | apierr); die 2 "로그인 실패 : 응답에 sessionId 가 없다 (${why:-사유 없음}). user/pass 를 확인 ($PARAMS)"; }
}

# 상태 : "id on(0/1) load[W] current[mA]" 줄들
states() {
   local r; r=$(api getOutputStatusList) || return 2
   printf '%s' "$r" | python3 -I -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
o=(d.get("data") or {}).get("outputs") if isinstance(d,dict) else None
if not isinstance(o,list): sys.exit(1)
for x in o: print(x.get("outputId"), 1 if x.get("on") else 0, x.get("load","-"), x.get("current","-"))' || { echo "상태 응답을 읽을 수 없다" >&2; return 2; }
}

setch() {   # $1 채널 $2 0|1
   local r why w; w=$([ "$2" = 1 ] && echo on || echo off)
   r=$(api setOutputState "$1" "$2") || die 2 "ch$1(${NAME[$1]}) $w 요청 실패"
   if [ "$DRY" = 0 ]; then why=$(printf '%s' "$r" | apierr) || die 2 "ch$1(${NAME[$1]}) $w 거부 : $why"; fi
   echo "ch$1 (${NAME[$1]}) $w"; [ "$DRY" = 0 ] && log "ch$1(${NAME[$1]}) $w -> ok"; return 0
}

verify() {  # 인자 : "채널:기대" ...  최대 5 번 되읽는다
   [ "$DRY" = 1 ] && { echo "[dry-run] 상태 되읽기 확인 : $*" >&2; return 0; }
   local t s ok e c v got
   for t in 1 2 3 4 5; do
      s=$(states) || die 2 "상태 읽기 실패"; ok=1
      for e in "$@"; do c=${e%:*}; v=${e#*:}; got=$(printf '%s\n' "$s" | awk -v c="$c" '$1==c {print $2}')
         [ "$got" = "$v" ] || ok=0; done
      [ $ok = 1 ] && { echo "  확인 : $*"; log "verify ok $*"; return 0; }
      "$SLEEP" 1
   done
   die 3 "상태가 기대와 다르다 (기대 $*) -- 지금 : $(printf '%s\n' "$s" | awk '$1<=3 {printf "ch%s=%s ", $1, $2}')"
}

pause() { if [ "$DRY" = 1 ]; then echo "[dry-run] $1 s 대기" >&2; else echo "  $1 s 대기"; "$SLEEP" "$1"; fi; }

remind() { echo "★ 전원을 올렸으면 : src/NOTICE_CODE_RUN.sh -> src/usbreset 2 회 -> 10 s 더미 런 -> 확인 런 (TCB 로그 is aligned 8 줄, LIBUSB 0)"; }

# ---- 수집 중 가드 (status 는 무관) ----
if [ "$CMD" != status ]; then
   command -v "$PGREP" >/dev/null 2>&1 || { echo "pgrep($PGREP) 를 찾을 수 없어 수집 여부를 모른다 -- 거부한다" >&2; exit 1; }
   busy=""; for p in rcsupervisor rcterm daq tcb merger; do "$PGREP" -x "$p" >/dev/null 2>&1 && busy="$busy $p"; done
   if [ -n "$busy" ]; then
      msg="수집이 돌고 있다 (살아 있는 것 :$busy). 전원을 내리면 런이 깨진다 -- 감시자를 먼저 세우거나 --force"
      if [ "$FORCE" = 1 ]; then echo "[WARN] $msg -- --force 로 진행한다" >&2; [ "$DRY" = 0 ] && log "WARN forced while busy:$busy"
      elif [ "$DRY" = 1 ]; then echo "[dry-run] 실제로는 거부된다 : $msg" >&2
      else echo "$msg" >&2; log "REFUSED $CMD ${CHS[*]-} busy:$busy"; exit 1; fi
   fi
fi

[ "$DRY" = 0 ] && [ "$CMD" != status ] && log "start $CMD ${CHS[*]-} (host $HOST)"
login
case "$CMD" in
   status)
      [ "$DRY" = 1 ] && { api getOutputStatusList >/dev/null; echo "[dry-run] 상태를 읽지 않았다"; exit 0; }
      s=$(states) || die 2 "상태 읽기 실패"
      printf '%-4s %-6s %-4s %8s %10s\n' ch board on load[W] current[mA]
      printf '%s\n' "$s" | while read -r id on ld cu; do
         case "$id" in 1|2|3) b=${NAME[$id]};; *) b="(미사용)";; esac
         printf '%-4s %-6s %-4s %8s %10s\n' "$id" "$b" "$([ "$on" = 1 ] && echo ON || echo off)" "$ld" "$cu"
      done ;;
   on|off)
      v=$([ "$CMD" = on ] && echo 1 || echo 0); exp=()
      for c in "${CHS[@]}"; do setch "$c" "$v"; exp+=("$c:$v"); done
      verify "${exp[@]}"
      [ "$CMD" = on ] && remind ;;
   cycle)
      echo "[1/5] 끔 : 1 2 3"; setch 1 0; setch 2 0; setch 3 0; verify 1:0 2:0 3:0
      echo "[2/5]"; pause "$OFFWAIT"
      echo "[3/5] 켬 : 2 (TCB)"; setch 2 1; verify 2:1
      echo "[4/5]"; pause "$WAIT"
      echo "[5/5] 켬 : 1 (FADC) 3 (SADC)"; setch 1 1; setch 3 1; verify 1:1 2:1 3:1
      [ "$DRY" = 0 ] && log "cycle done"; remind ;;
esac
exit 0
