#!/bin/bash
# =====================================================================
#  mailq-send.sh 시험.
#  ★ 실제 메일은 한 통도 나가지 않는다 — 가짜 발송기로 갈아끼운다.
#    (남의 메일함으로 나가는 것이라 시험 발송을 하지 않는다는 규칙, §11.128)
# =====================================================================
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../scripts/mailq-send.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "기대 '$3' / 실제 '$2'"; fi; }

setup() {                 # $1 = 가짜 발송기의 종료코드
	T=$(mktemp -d); Q="$T/MAILQ"; mkdir -p "$Q"
	cat > "$T/fake_send.py" <<FAKE
#!/bin/bash
rc=$1
subj=""; to=""; bf=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --subject) subj=\$2; shift 2 ;;
    --to)      to=\$2;   shift 2 ;;
    --body-file) bf=\$2; shift 2 ;;
    *) shift ;;
  esac
done
{ echo "CALL to=\$to subject=\$subj"; echo "--body--"; cat "\$bf" 2>/dev/null; echo "--end--"; } >> "$T/calls.txt"
[ -n "\${FAKE_SLOW:-}" ] && sleep 3
exit \$rc
FAKE
	chmod +x "$T/fake_send.py"
	: > "$T/params"          # 존재하고 읽히기만 하면 된다
	: > "$T/calls.txt"
}
teardown() { [ -n "${T:-}" ] && rm -rf "$T"; }

mkmail() {                # 이름  제목  수신자  본문...
	local n=$1 s=$2 w=$3; shift 3
	{ echo "subject: $s"; echo "to: $w"; echo "body:"; printf '%s\n' "$@"; } > "$Q/$n.mail"
}

run_sut() {
	MAILQ_DIR="$Q" MAILQ_PARAMS="$T/params" MAILQ_SENDER="$T/fake_send.py" \
	MAILQ_LOG="$T/mailq.log" MAILQ_LOCK="$T/.mailq.lock" MAILQ_REQUIRE_MOUNT="${REQ:-}" \
	bash "$SUT" "$@" > "$T/out.txt" 2>&1
	RC=$?
}
nq()   { find "$Q" -maxdepth 1 -name '*.mail'    2>/dev/null | wc -l; }
nsent(){ find "$Q/sent"   -maxdepth 1 -name '*.mail' 2>/dev/null | wc -l; }
nfail(){ find "$Q/failed" -maxdepth 1 -name '*.mail' 2>/dev/null | wc -l; }
ncall(){ grep -c '^CALL ' "$T/calls.txt" 2>/dev/null || true; }

echo "=========================================================="
echo "  mailq-send.sh 시험"
echo "=========================================================="

echo ""; echo "[1] 큐를 비우고 sent/ 로 옮긴다"
setup 0
mkmail a "백업 완료" routine "본문 첫 줄" "둘째 줄"
mkmail b "하드 교체" routine "다른 본문"
run_sut
chk "종료코드 0" "$RC" "0"
chk "발송 호출 2회" "$(ncall)" "2"
chk "큐가 비었다" "$(nq)" "0"
chk "sent/ 에 2 통" "$(nsent)" "2"
teardown

echo ""; echo "[2] 제목·수신자·본문을 정확히 갈라 넘긴다 (본문에 subject:/body: 가 있어도)"
setup 0
mkmail a "제목 한 줄" expert "본문 시작" "subject: 이건 본문이다" "body:" "끝 줄"
run_sut
if grep -q '^CALL to=expert subject=제목 한 줄$' "$T/calls.txt"; then ok "제목과 수신자"
else bad "제목/수신자가 어긋났다" "$(head -1 "$T/calls.txt")"; fi
BODY=$(sed -n '/^--body--$/,/^--end--$/p' "$T/calls.txt" | sed '1d;$d')
EXP=$(printf '본문 시작\nsubject: 이건 본문이다\nbody:\n끝 줄')
if [ "$BODY" = "$EXP" ]; then ok "본문이 한 글자도 다르지 않다"
else bad "본문이 어긋났다" "$(echo "$BODY" | tr '\n' '|')"; fi
teardown

echo ""; echo "[3] 발송 실패는 큐에 남기고 다음 회차에 다시 시도한다"
setup 7
mkmail a "실패할 것" routine "본문"
run_sut
chk "종료코드 0 (죽지 않는다)" "$RC" "0"
chk "큐에 그대로" "$(nq)" "1"
chk "sent 없음" "$(nsent)" "0"
chk "시도 횟수 1" "$(cat "$Q"/a.try 2>/dev/null || echo -)" "1"
run_sut; run_sut
chk "시도 횟수 3" "$(cat "$Q"/a.try 2>/dev/null || echo -)" "3"
chk "아직 포기하지 않았다" "$(nq)" "1"
run_sut; run_sut
chk "5회에서 failed/ 로" "$(nfail)" "1"
chk "큐에서 빠졌다" "$(nq)" "0"
teardown

echo ""; echo "[4] 실패했다가 성공하면 sent/ 로 간다"
setup 7
mkmail a "나중에 성공" routine "본문"
run_sut
chk "일단 실패로 남았다" "$(nq)" "1"
rm -f "$T/fake_send.py"; setup_rc=0
printf '#!/bin/bash\nexit 0\n' > "$T/fake_send.py"; chmod +x "$T/fake_send.py"
run_sut
chk "이번엔 보냈다" "$(nsent)" "1"
chk "큐가 비었다" "$(nq)" "0"
teardown

echo ""; echo "[5] 보내다 죽어 남은 .sending 을 되살린다"
setup 0
mkmail a "되살릴 것" routine "본문"
mv "$Q/a.mail" "$Q/a.sending"
touch -d '2 hours ago' "$Q/a.sending"
run_sut
chk "되살려 보냈다" "$(nsent)" "1"
if grep -q '되살림' "$T/mailq.log"; then ok "되살렸다고 로그에 남긴다"
else bad "로그가 없다"; fi
teardown

echo ""; echo "[6] 갓 만들어진 .sending 은 건드리지 않는다 (다른 회차가 보내는 중)"
setup 0
mkmail a "보내는 중" routine "본문"
mv "$Q/a.mail" "$Q/a.sending"      # mtime = 지금
run_sut
chk "손대지 않았다" "$(ncall)" "0"
chk ".sending 그대로" "$(find "$Q" -maxdepth 1 -name '*.sending' | wc -l)" "1"
teardown

echo ""; echo "[7] 요구한 마운트가 없으면 조용히 물러난다 (큐를 건드리지 않는다)"
setup 0
mkmail a "나중에" routine "본문"
REQ="/definitely/not/a/mountpoint" run_sut
chk "종료코드 0" "$RC" "0"
chk "보내지 않았다" "$(ncall)" "0"
chk "큐 그대로" "$(nq)" "1"
chk "화면에 아무 말도 없다" "$(wc -c < "$T/out.txt")" "0"
teardown

echo ""; echo "[8] 큐가 아예 없어도 죽지 않는다"
setup 0
rm -rf "$Q"
run_sut
chk "종료코드 0" "$RC" "0"
teardown

echo ""; echo "[9] 겹쳐 돌지 않는다 (cron 5분보다 오래 걸릴 때)"
setup 0
mkmail a "느린 것" routine "본문"
mkmail b "느린 것2" routine "본문"
( FAKE_SLOW=1 MAILQ_DIR="$Q" MAILQ_PARAMS="$T/params" MAILQ_SENDER="$T/fake_send.py" \
  MAILQ_LOG="$T/mailq.log" MAILQ_LOCK="$T/.mailq.lock" \
  bash "$SUT" >/dev/null 2>&1 ) &
BG=$!
sleep 1
run_sut
chk "둘째 회차는 종료코드 0" "$RC" "0"
chk "둘째 회차는 한 통도 안 보냈다" "$(grep -c '^CALL ' "$T/calls.txt")" "1"
wait $BG
chk "첫 회차가 둘 다 보냈다" "$(nsent)" "2"
teardown

echo ""; echo "[10] --status 는 읽기 전용이다"
setup 0
mkmail a "대기 중" routine "본문"
run_sut --status
chk "종료코드 0" "$RC" "0"
chk "보내지 않았다" "$(ncall)" "0"
chk "큐 그대로" "$(nq)" "1"
if grep -q '대기 중' "$T/out.txt"; then ok "대기 중인 제목을 보여준다"
else bad "제목이 안 보인다" "$(cat "$T/out.txt")"; fi
teardown

echo ""; echo "[11] --dry-run 은 큐를 비우지 않는다 (사람이 점검하다 알림을 지우면 안 된다)"
setup 0
mkmail a "미리보기" routine "본문"
run_sut --dry-run
chk "종료코드 0" "$RC" "0"
chk "발송기는 --dry-run 으로 호출됐다" "$(ncall)" "1"
chk "★ 큐에 그대로 남아 있다" "$(nq)" "1"
chk "sent/ 로 옮기지 않았다" "$(nsent)" "0"
chk "시도 횟수를 올리지도 않았다" "$(cat "$Q"/a.try 2>/dev/null || echo -)" "-"
teardown

echo ""; echo "[12] cron 환경(env -i)에서도 돈다"
setup 0
mkmail a "cron" routine "본문"
env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$T" \
	MAILQ_DIR="$Q" MAILQ_PARAMS="$T/params" MAILQ_SENDER="$T/fake_send.py" \
	MAILQ_LOG="$T/mailq.log" MAILQ_LOCK="$T/.mailq.lock" \
	bash "$SUT" > "$T/out.txt" 2>&1
chk "종료코드 0" "$?" "0"
chk "보냈다" "$(nsent)" "1"
teardown

echo ""; echo "[13] 한 회차 상한(--max)을 지킨다"
setup 0
for i in 1 2 3 4 5; do mkmail "m$i" "메일 $i" routine "본문"; done
run_sut --max 2
chk "2 통만 보냈다" "$(ncall)" "2"
chk "3 통이 남았다" "$(nq)" "3"
teardown

echo ""
echo "=========================================================="
printf "  통과 %d · 실패 %d\n" "$PASS" "$FAIL"
echo "=========================================================="
[ "$FAIL" -eq 0 ]
