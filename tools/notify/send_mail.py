#!/usr/bin/env python3
"""
config/notify.params 를 읽어 SMTP 로 메일 한 통을 보낸다.

    send_mail.py --params <파일> --to expert --subject '...' [--body-file <파일>]

'#' 뒤는 주석으로 잘리는 파서를 셸 쪽과 똑같이 맞췄다. 두 곳이 같은 파일을
읽으므로 해석이 갈리면 안 된다.

메일이 안 나가는 것은 알람이 안 울리는 것과 다르다 -- 조용히 실패하면
아무도 모른다. 그래서 실패하면 종료코드로 알리고 stderr 에 이유를 적는다.
"""
import argparse, os, smtplib, socket, ssl, sys
from email.message import EmailMessage
from email.utils import formatdate, make_msgid


def load_params(path):
    cfg = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.split("#", 1)[0]
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip().lower().replace("-", "_")
            if k:
                cfg[k] = v.strip()
    return cfg


def recipients(cfg, who):
    """책임자(routine) / 전문가(expert). 전문가가 비어 있으면 책임자에게 간다."""
    raw = cfg.get("mail_to", "")
    if who == "expert":
        raw = cfg.get("mail_to_expert", "").strip() or raw
    return [a.strip() for a in raw.replace(";", ",").split(",") if a.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--params", required=True)
    ap.add_argument("--to", default="routine", choices=["routine", "expert"])
    ap.add_argument("--subject", required=True)
    ap.add_argument("--body-file")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    try:
        cfg = load_params(a.params)
    except OSError as e:
        print(f"설정 파일을 읽을 수 없다 : {e}", file=sys.stderr)
        return 2

    if cfg.get("mail_enable", "1") not in ("1", "yes", "true", "on"):
        print("mail_enable = 0 이라 보내지 않는다.", file=sys.stderr)
        return 0

    host = cfg.get("smtp_host", "").strip()
    user = cfg.get("smtp_user", "").strip()
    #  구글은 앱 비밀번호를 'abcd efgh ijkl mnop' 처럼 네 자씩 띄어 보여준다.
    #  보이는 대로 붙여넣어도 되게 공백을 전부 걷어낸다. 실제 값은 16자다.
    pwd = "".join(cfg.get("smtp_pass", "").split())
    sender = cfg.get("mail_from", "").strip() or user
    to = recipients(cfg, a.to)

    missing = [n for n, v in (("smtp_host", host), ("smtp_user", user),
                              ("smtp_pass", pwd), ("mail_to", ",".join(to))) if not v]
    if missing:
        print("메일 설정이 비어 있다 : " + ", ".join(missing)
              + f"   ({a.params} 를 채울 것)", file=sys.stderr)
        return 3

    body = ""
    if a.body_file:
        try:
            with open(a.body_file, encoding="utf-8", errors="replace") as fh:
                body = fh.read()
        except OSError as e:
            body = f"(본문 파일을 읽지 못했다 : {e})"

    prefix = cfg.get("mail_subject_prefix", "[RENE DAQ]").strip()
    msg = EmailMessage()
    msg["Subject"] = f"{prefix} {a.subject}".strip()
    msg["From"] = sender
    msg["To"] = ", ".join(to)
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain=socket.gethostname() or "rene-daq")
    msg.set_content(body or a.subject)

    if a.dry_run:
        print(f"[DRY] {msg['Subject']}  ->  {msg['To']}  ({host}:{cfg.get('smtp_port','587')})")
        return 0

    port = int(cfg.get("smtp_port", "587") or 587)
    sec = cfg.get("smtp_security", "starttls").strip().lower()
    try:
        if sec == "ssl":
            srv = smtplib.SMTP_SSL(host, port, timeout=30,
                                   context=ssl.create_default_context())
        else:
            srv = smtplib.SMTP(host, port, timeout=30)
        with srv:
            srv.ehlo()
            if sec == "starttls":
                srv.starttls(context=ssl.create_default_context())
                srv.ehlo()
            srv.login(user, pwd)
            srv.send_message(msg)
    except smtplib.SMTPAuthenticationError:
        print("SMTP 인증 실패. Gmail 이라면 계정 비밀번호가 아니라 "
              "'앱 비밀번호'여야 한다.", file=sys.stderr)
        return 4
    except Exception as e:                      # 망 장애·DNS·타임아웃 전부 여기로
        print(f"SMTP 발송 실패 : {type(e).__name__}: {e}", file=sys.stderr)
        return 5

    print(f"보냄 : {msg['Subject']}  ->  {msg['To']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
