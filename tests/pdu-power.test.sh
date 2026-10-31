#!/usr/bin/env bash
# pdu-power.test.sh -- scripts/pdu-power.sh 시험. 실제 PDU·네트워크에 닿지 않는다 (가짜 curl/sleep/pgrep).
#   상태 응답 픽스처는 2026-11-01 실물 getOutputStatusList (tests/fixtures/pdu_status_20261101.json, output 1~4)
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd); S=$REPO/scripts/pdu-power.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

SECRET='s3cr"et\pw'      # 따옴표·역슬래시가 섞인 비밀번호
printf 'host = 10.255.255.1\nuser = admin\npass = %s\n' "$SECRET" > "$T/pdu.params"; chmod 600 "$T/pdu.params"

# 가짜 curl : 본문을 seq 에 남기고, 상태 파일로 응답한다
cat > "$T/curl" <<'FAKE'
#!/usr/bin/env bash
F=$FAKE_DIR; body=$(cat); echo "$*" >> "$F/args"; printf '%s\n' "$body" >> "$F/bodies"
[ "${FAKE_HTTPFAIL:-0}" = 1 ] && { echo "curl: (22) The requested URL returned error: 500" >&2; exit 22; }
FAKE_BODY=$body python3 -I - "$F" <<'PY'
import json,os,sys
F=sys.argv[1]; d=json.loads(os.environ["FAKE_BODY"]); a=d["action"]
st=json.load(open(F+"/state"))
open(F+"/seq","a").write("REQ %s %s\n" % (a, " ".join(str(v) for v in d.get("data",{}).values()) if a=="setOutputState" else ""))
if a=="login":
    ok = d["data"]["password"]==os.environ.get("FAKE_PW") and d["data"]["username"]=="admin"
    print(json.dumps({"data":{"sessionId":"S123"}}) if ok else os.environ.get("FAKE_LOGINFAIL","{}"))
elif d.get("sessionId")!="S123": print(json.dumps({"errors":[{"code":"1000","message":"Invalid session ID","severity":"fatal"}]}))
elif a=="getOutputStatusList":
    fx=json.load(open(os.environ["FAKE_FIX"]))
    for o in fx["data"]["outputs"]: o["on"]=bool(st[str(o["outputId"])])
    print(json.dumps(fx))
elif a=="setOutputState":
    if os.environ.get("FAKE_SETERR"): print(os.environ["FAKE_SETERR"]); sys.exit(0)
    o=str(d["data"]["output"]); stuck=os.environ.get("FAKE_STUCK","")
    if o!=stuck: st[o]=d["data"]["value"]
    json.dump(st,open(F+"/state","w")); print("{}")
elif a=="logout": print("{}")
else: print(json.dumps({"errors":[{"code":"-502","message":"Unknown command","severity":"fatal"}]}))
PY
FAKE
cat > "$T/sleep" <<'FAKE'
#!/usr/bin/env bash
echo "SLEEP $1" >> "$FAKE_DIR/seq"
FAKE
cat > "$T/pgrep" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = -x ] || { echo "pgrep 는 -x 로만 불려야 한다 : $*" >> "$FAKE_DIR/pgrep_bad"; exit 2; }
case " ${FAKE_BUSY:-} " in *" $2 "*) echo 4242; exit 0;; esac; exit 1
FAKE
chmod +x "$T/curl" "$T/sleep" "$T/pgrep"

reset() { rm -rf "$T/f"; mkdir -p "$T/f"; echo '{"1":1,"2":1,"3":1,"4":0}' > "$T/f/state"; : > "$T/f/seq"; : > "$T/f/bodies"; : > "$T/log"; }
run() { env FAKE_DIR="$T/f" FAKE_PW="${FAKE_PW:-$SECRET}" FAKE_FIX="$REPO/tests/fixtures/pdu_status_20261101.json" \
        PDU_CURL="$T/curl" PDU_SLEEP="$T/sleep" PDU_PGREP="$T/pgrep" PDU_LOG="$T/log" \
        bash "$S" --params "$T/pdu.params" "$@" > "$T/out" 2>&1; echo $? > "$T/rc"; }
rc() { cat "$T/rc"; }
nreq() { grep -c '^REQ' "$T/f/seq"; }

echo "[1] status 파싱 (실물 픽스처)"
reset; run status
chk "rc 0" '[ "$(rc)" = 0 ]'
chk "ch1 FADC ON 53 W" 'grep -Eq "^1 +FADC +ON +53 +276" "$T/out"'
chk "ch2 TCB ON" 'grep -Eq "^2 +TCB +ON" "$T/out"'
chk "ch4 미사용 off" 'grep -Eq "^4 +\(미사용\) +off" "$T/out"'
chk "status 는 setOutputState 를 안 보낸다" '! grep -q setOutputState "$T/f/seq"'
chk "status 는 로그를 안 쓴다" '[ ! -s "$T/log" ]'
chk "로그아웃 함" 'grep -q "REQ logout" "$T/f/seq"'
chk "busy 여도 status 는 된다" 'reset; FAKE_BUSY="rcterm daq" run status; [ "$(rc)" = 0 ]'

echo "[2] on/off 가 올바른 JSON 을 보낸다"
reset; run off 3
chk "rc 0" '[ "$(rc)" = 0 ]'
chk "setOutputState output 3 value 0" 'grep -q "\"action\": \"setOutputState\", \"data\": {\"output\": 3, \"value\": 0}" "$T/f/bodies"'
chk "sessionId S123 사용" 'grep setOutputState "$T/f/bodies" | grep -q "\"sessionId\": \"S123\""'
chk "상태 되읽기로 확인" 'grep -q "확인 : 3:0" "$T/out"'
chk "로그에 ch3 off" 'grep -q "ch3(SADC) off -> ok" "$T/log"'
chk "on 은 재초기화 안내" 'reset; run on 2; [ "$(rc)" = 0 ] && grep -q NOTICE_CODE_RUN "$T/out"'
chk "중복 채널은 한 번" 'reset; run off 1 1; [ "$(grep -c "\"output\": 1" "$T/f/bodies")" = 1 ]'
chk "curl 은 -m 10 · 본문은 stdin(@-)" 'head -1 "$T/f/args" | grep -q -- "-m 10" && head -1 "$T/f/args" | grep -q -- "--data-binary @-"'

echo "[3] cycle 순서와 대기"
reset; run cycle
chk "rc 0" '[ "$(rc)" = 0 ]'
SEQ=$(grep -E '^(REQ setOutputState|SLEEP (10|30))' "$T/f/seq" | tr '\n' '|')
chk "끔 1 2 3 -> 10 s -> 켬 2 -> 30 s -> 켬 1 3" '[ "$SEQ" = "REQ setOutputState 1 0|REQ setOutputState 2 0|REQ setOutputState 3 0|SLEEP 10|REQ setOutputState 2 1|SLEEP 30|REQ setOutputState 1 1|REQ setOutputState 3 1|" ]'
chk "단계마다 상태 되읽기 3 회 이상" '[ "$(grep -c "REQ getOutputStatusList" "$T/f/seq")" -ge 3 ]'
chk "끝 상태 1 2 3 모두 켜짐" 'grep -q "\"1\": 1, \"2\": 1, \"3\": 1" "$T/f/state"'
chk "로그에 cycle done" 'grep -q "cycle done" "$T/log"'
chk "--wait 5 --off-wait 2" 'reset; run cycle --wait 5 --off-wait 2; [ "$(grep -c "^SLEEP 5$" "$T/f/seq")" = 1 ] && [ "$(grep -c "^SLEEP 2$" "$T/f/seq")" = 1 ]'
chk "되읽기 어긋나면 exit 3" 'reset; FAKE_STUCK=2 run cycle; [ "$(rc)" = 3 ] && grep -q "기대와 다르다" "$T/out"'
chk "TCB 가 안 켜지면 FADC·SADC 를 켜지 않는다" '! grep -q "REQ setOutputState 1 1" "$T/f/seq"'

echo "[4] 채널 검사"
for c in 4 0 8 x; do chk "채널 $c 거부" "reset; run on $c; [ \"\$(rc)\" = 1 ] && [ \"\$(nreq)\" = 0 ]"; done
chk "채널 없는 off 거부" 'reset; run off; [ "$(rc)" = 1 ]'
chk "cycle 에 채널 인자 거부" 'reset; run cycle 1; [ "$(rc)" = 1 ]'
chk "모르는 명령 거부" 'reset; run reset 1; [ "$(rc)" = 1 ] && [ "$(nreq)" = 0 ]'
chk "--wait 숫자 아님 거부" 'reset; run cycle --wait abc; [ "$(rc)" = 1 ]'

echo "[5] --dry-run 은 네트워크 0 회"
for a in "status" "on 2" "off 1 2 3" "cycle"; do
   chk "dry-run $a : curl·sleep 0 회, rc 0" "reset; run --dry-run $a; [ \"\$(rc)\" = 0 ] && [ ! -s \"\$T/f/seq\" ] && [ ! -s \"\$T/f/bodies\" ]"
done
reset; run --dry-run cycle
chk "dry-run 이 보낼 요청을 찍는다" 'grep -q "\[dry-run\] POST http://10.255.255.1/api .*setOutputState" "$T/out"'
chk "dry-run 로그인 본문의 비밀번호는 ***" 'grep "\"action\": \"login\"" "$T/out" | grep -q "\"password\": \"\*\*\*\""'
chk "dry-run 은 로그를 안 쓴다" '[ ! -s "$T/log" ]'
chk "dry-run + 수집 중 : 거부될 것이라고 알린다" 'reset; FAKE_BUSY=tcb run --dry-run off 1; [ "$(rc)" = 0 ] && grep -q "실제로는 거부된다" "$T/out" && [ ! -s "$T/f/seq" ]'

echo "[6] params"
chk "params 없음 exit 1 + 안내" 'reset; run status --params "$T/none"; [ "$(rc)" = 1 ] && grep -q "pdu.params.example" "$T/out" && [ "$(nreq)" = 0 ]'
printf 'host = 1.2.3.4\nuser = admin\npass = <채워 넣을 것>\n' > "$T/ex.params"; chmod 600 "$T/ex.params"
chk "예시 그대로의 pass 거부" 'reset; run status --params "$T/ex.params"; [ "$(rc)" = 1 ] && [ "$(nreq)" = 0 ]'
cp "$T/pdu.params" "$T/open.params"; chmod 644 "$T/open.params"
chk "권한 644 면 경고" 'reset; run status --params "$T/open.params"; grep -q "chmod 600" "$T/out"'
chk "기본 params 는 <저장소>/config/pdu.params" 'grep -q "^PARAMS=\$DIR/config/pdu.params" "$S"'

echo "[7] 로그인·HTTP 실패 exit 2"
chk "비밀번호 틀림 ({}) exit 2" 'reset; FAKE_PW=other run status; [ "$(rc)" = 2 ] && grep -q "로그인 실패" "$T/out"'
# 오류 형식은 장치 UI 코드(netio-all.js CoreJsonParser.getErrors)의 실물 : {"errors":[{"code","message","severity"}]}
E1004='{"errors":[{"code":"1004","message":"Invalid credentials","severity":"fatal"}]}'
chk "로그인 1004 사유 표시" 'reset; FAKE_PW=other FAKE_LOGINFAIL="$E1004" run status; [ "$(rc)" = 2 ] && grep -q "1004 INVALID_CREDENTIALS" "$T/out"'
E1000='{"errors":[{"code":"1000","severity":"fatal"}]}'
chk "setOutputState 가 errors 로 거부되면 rc 2 · 화면/로그에 ok 없음" 'reset; FAKE_SETERR="$E1000" run off 1; [ "$(rc)" = 2 ] && grep -q "1000 INVALID_SESSION_ID" "$T/out" && ! grep -q "ok" "$T/log" && ! grep -q "^ch1 (FADC) off" "$T/out"'
chk "code 626(SOME_ERRORS_OCCURED) 비치명은 성공" 'reset; FAKE_SETERR="{\"errors\":[{\"code\":\"626\",\"severity\":\"warning\"}]}" run off 1 --force; grep -q "ch1(FADC) off -> ok" "$T/log"'
chk "code 0 이라도 severity fatal 이면 실패" 'reset; FAKE_SETERR="{\"errors\":[{\"code\":\"0\",\"severity\":\"fatal\"}]}" run off 1; [ "$(rc)" = 2 ]'
chk "HTTP 실패 exit 2" 'reset; FAKE_HTTPFAIL=1 run off 1; [ "$(rc)" = 2 ] && grep -q "HTTP 실패" "$T/out"'
chk "HTTP 실패는 로그에 ERROR" 'grep -q "ERROR rc=2" "$T/log"'

echo "[8] 비밀번호가 화면·로그·curl 인자에 없다"
reset; run cycle; cat "$T/out" > "$T/allout"; cat "$T/log" > "$T/alllog"; cat "$T/f/args" > "$T/allargs"
FAKE_PW=other run status; cat "$T/out" >> "$T/allout"; cat "$T/log" >> "$T/alllog"
run --dry-run cycle; cat "$T/out" >> "$T/allout"
chk "화면에 없음" '! grep -qF "s3cr" "$T/allout"'
chk "로그에 없음" '! grep -qF "s3cr" "$T/alllog"'
chk "curl 인자(ps 에 보이는 곳)에 없음" '! grep -qF "s3cr" "$T/allargs"'
chk "bash -x 추적에도 없음" 'reset; env FAKE_DIR="$T/f" FAKE_PW="$SECRET" FAKE_FIX="$REPO/tests/fixtures/pdu_status_20261101.json" PDU_CURL="$T/curl" PDU_SLEEP="$T/sleep" PDU_PGREP="$T/pgrep" PDU_LOG="$T/log" bash -x "$S" --params "$T/pdu.params" off 1 > "$T/xout" 2>&1; ! grep -qF "s3cr" "$T/xout" && grep -q "ch1 (FADC) off" "$T/xout"'
chk "bash -x --dry-run 추적에도 없음" 'reset; env PDU_PGREP="$T/pgrep" PDU_LOG="$T/log" FAKE_DIR="$T/f" bash -x "$S" --params "$T/pdu.params" --dry-run status > "$T/xout" 2>&1; ! grep -qF "s3cr" "$T/xout"'
chk "따옴표·역슬래시 비밀번호로도 로그인 성공 (본문에는 실렸다)" 'reset; run status; [ "$(rc)" = 0 ] && grep -qF "s3cr" "$T/f/bodies"'

echo "[9] 수집 중 거부와 --force"
for p in rcsupervisor rcterm daq tcb merger; do
   chk "$p 살아 있으면 off 거부" "reset; FAKE_BUSY=$p run off 1; [ \"\$(rc)\" = 1 ] && [ \"\$(nreq)\" = 0 ]"
done
chk "거부 사유에 이름" 'reset; FAKE_BUSY="rcterm daq" run cycle; grep -q "rcterm daq" "$T/out" && grep -q REFUSED "$T/log"'
chk "--force 면 진행" 'reset; FAKE_BUSY=rcterm run --force off 3; [ "$(rc)" = 0 ] && grep -q "REQ setOutputState 3 0" "$T/f/seq" && grep -q "WARN forced" "$T/log"'
chk "pgrep 를 못 찾으면 거부" 'reset; env FAKE_DIR="$T/f" PDU_CURL="$T/curl" PDU_PGREP="$T/nope" PDU_LOG="$T/log" bash "$S" --params "$T/pdu.params" off 1 > "$T/out" 2>&1; [ $? = 1 ] && [ "$(nreq)" = 0 ]'
chk "curl 에 --noproxy" 'reset; run status; head -1 "$T/f/args" | grep -q -- "--noproxy \*"'
chk "pgrep 는 -x 로만" '[ ! -s "$T/f/pgrep_bad" ]'
chk "스크립트에 pgrep -f 없음" '! grep -q "pgrep -f\|pkill" "$S"'

echo "[10] PDU 설정 action 은 부르지 않는다 · cron 환경"
chk "허용 action 은 4 개뿐" '[ "$(grep -o "\"action\": \"[A-Za-z]*\"" "$T/f/bodies" | sort -u | grep -vcE "login|logout|getOutputStatusList|setOutputState")" = 0 ]'
chk "스크립트에 다른 action 이름 없음" '! grep -qE "resetOutputState|setOutputBase|setOutputSchedule|toggleOutputTimer" "$S"'
reset
( cd / && env -i PATH=/usr/bin:/bin HOME="$HOME" FAKE_DIR="$T/f" FAKE_PW="$SECRET" FAKE_FIX="$REPO/tests/fixtures/pdu_status_20261101.json" \
    PDU_CURL="$T/curl" PDU_SLEEP="$T/sleep" PDU_PGREP="$T/pgrep" PDU_LOG="$T/log" bash "$S" --params "$T/pdu.params" status > "$T/out" 2>&1; echo $? > "$T/rc" )
chk "cd / + env -i 에서 status" '[ "$(rc)" = 0 ] && grep -q TCB "$T/out"'

echo "통과 $PASS / 실패 $FAIL"
[ "$FAIL" = 0 ]
