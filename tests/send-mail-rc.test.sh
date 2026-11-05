#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  send_mail.py 의 종료코드 : 연결 단계 실패 = 5 (mailq-send 가 세지 않음) · 서버 거부 = 6 (센다).
#  ★ 망에 붙지 않는다. smtplib.SMTP 를 예외를 던지는 가짜로 바꿔 main() 을 부른다.
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf 'smtp_host = smtp.invalid\nsmtp_user = u@example.org\nsmtp_pass = p\nmail_to = boss@example.org\n' > "$T/p"
PASS=0; FAIL=0
case_rc() {   # $1=이름 $2=기대 rc $3=단계(connect|send) $4=python 예외 식
   python3 - "$DIR/tools/notify" "$T/p" "$3" "$4" >/dev/null 2>&1 <<'PY'
import sys, smtplib, socket, ssl
sys.path.insert(0, sys.argv[1]); import send_mail
stage, expr = sys.argv[3], sys.argv[4]
class Fake:
    def __init__(self, *a, **k):
        if stage == "connect": raise eval(expr)
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def ehlo(self): pass
    def starttls(self, **k): pass
    def login(self, u, p): pass
    def send_message(self, m):
        if stage == "send": raise eval(expr)
smtplib.SMTP = Fake
sys.argv = ["send_mail.py", "--params", sys.argv[2], "--to", "routine", "--subject", "s"]
sys.exit(send_mail.main())
PY
   local rc=$?
   if [ "$rc" = "$2" ]; then PASS=$((PASS+1)); echo "  ok   $1 -> $rc"; else FAIL=$((FAIL+1)); echo "  FAIL $1 -> $rc (기대 $2)"; fi
}
echo "[연결 단계 = 5]"
case_rc "DNS 실패 (gaierror)"          5 connect 'socket.gaierror(-2, "Name or service not known")'
case_rc "타임아웃 (socket.timeout)"    5 connect 'socket.timeout("timed out")'
case_rc "연결 거부 (OSError)"          5 connect 'ConnectionRefusedError(111, "refused")'
case_rc "SMTPConnectError 421"         5 connect 'smtplib.SMTPConnectError(421, b"busy")'
case_rc "SMTPServerDisconnected"       5 send    'smtplib.SMTPServerDisconnected("closed")'
case_rc "TLS 오류 (ssl.SSLError)"      5 connect 'ssl.SSLError("bad handshake")'
echo "[서버 거부 = 6]"
case_rc "SMTPDataError 550"            6 send    'smtplib.SMTPDataError(550, b"5.7.1 rejected")'
case_rc "SMTPRecipientsRefused"        6 send    'smtplib.SMTPRecipientsRefused({"x@y": (550, b"no such user")})'
case_rc "SMTPSenderRefused"            6 send    'smtplib.SMTPSenderRefused(553, b"bad sender", "u@example.org")'
echo "[그 밖]"
case_rc "인증 실패 = 4"                4 send    'smtplib.SMTPAuthenticationError(535, b"bad creds")'
case_rc "보냄 = 0"                     0 none    'None'
echo; echo "PASS $PASS  FAIL $FAIL"
[ "$FAIL" -eq 0 ]
