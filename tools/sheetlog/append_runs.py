#!/usr/bin/env python3
"""RENE 런 로그를 구글시트에 이어 쓴다.  규칙은 CLAUDE.md 11.5 가 정본이다.

  * 기존에 작성된 내용은 절대 수정하지 않는다
  * 마지막으로 작성된 Run 번호 이후의 런만 추가한다
  * 마지막 작성 줄 다음의 빈 줄부터 이어 쓴다

기본은 미리보기다.  실제로 쓰려면 --commit 을 준다.
"""
import argparse, os, sqlite3, subprocess, sys, datetime, re

SHEET_ID = "1-8wPIg-Q-DpgsyBeSiwHezxM6QlcqhZ3qspAFGusqD0"
GID      = 0
DB       = "/Data_ssd/runcatalog.db"
ROOTS    = ["/Data_ssd/RAW", "/data/RAW", "/scratch/RAW"]

# 직전 행에서 그대로 복사해 오는 열들 (사용자 지침)
CARRY = ["Detector", "Source", "PMT-A HV (V)", "PMT-B HV (V)", "THR (mV)",
         "Coincidence (ns)", "Record length", "Time after HV ON", "TLT"]


def norm(s):
    return re.sub(r"\s+", " ", (s or "").strip()).lower()


def scan_run(run):
    """Max subrun / RAW bytes / PRD bytes 를 디스크에서 실측한다."""
    rr = "%06d" % run
    d = next((os.path.join(r, rr) for r in ROOTS if os.path.isdir(os.path.join(r, rr))), None)
    if not d:
        return None, None, None
    raw = 0
    try:
        for f in os.scandir(d):
            if f.is_file() and (f.name.startswith("FADC_%s.root" % rr)
                                or f.name.startswith("SADC_%s.root" % rr)):
                raw += f.stat().st_size
    except OSError:
        pass
    n = pb = 0
    pd = os.path.join(d, "PRD")
    if os.path.isdir(pd):
        try:
            for f in os.scandir(pd):
                if f.is_file() and f.name.endswith(".root") and rr in f.name:
                    n += 1
                    pb += f.stat().st_size
        except OSError:
            pass
    return n, raw, pb


def gb(b):
    return "" if b is None else round(b / 1024.0 ** 3, 1)


def duration(st, et):
    if not st or not et:
        return ""
    try:
        a = datetime.datetime.strptime(st[:19], "%Y-%m-%d %H:%M:%S")
        b = datetime.datetime.strptime(et[:19], "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return ""
    s = int((b - a).total_seconds())
    if s < 0:
        return ""
    h, m = s // 3600, (s % 3600) // 60
    return ("%dh%dm" % (h, m)) if h else ("%dm" % m)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--creds", default=os.path.expanduser("~/.config/rene/sheets-sa.json"))
    ap.add_argument("--scan", help="미리 만들어 둔 스캔 결과 tsv (run/dir/n/raw/prd)")
    ap.add_argument("--commit", action="store_true", help="실제로 시트에 쓴다")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--all-runs", action="store_true",
                    help="onlbit 무관하게 전부 (기본은 onlbit=1 인 것만)")
    a = ap.parse_args()

    import gspread
    from google.oauth2.service_account import Credentials

    cr = Credentials.from_service_account_file(
        a.creds, scopes=["https://www.googleapis.com/auth/spreadsheets"])
    ws = gspread.authorize(cr).open_by_key(SHEET_ID).get_worksheet_by_id(GID)
    grid = ws.get_all_values()
    print("탭 '%s'  %d행 x %d열" % (ws.title, len(grid), max(len(r) for r in grid)))

    # 헤더 행 찾기 -- 'Run' 과 'Max subrun' 이 같이 있는 줄
    hdr_i = hdr = None
    for i, row in enumerate(grid):
        n = [norm(c) for c in row]
        if "run" in n and "max subrun" in n:
            hdr_i, hdr = i, row
            break
    if hdr is None:
        sys.exit("헤더를 찾지 못했다")
    col = {norm(c): j for j, c in enumerate(hdr) if c.strip()}
    run_c = col["run"]
    print("헤더 %d행, Run 은 %d열" % (hdr_i + 1, run_c + 1))

    # 마지막으로 Run 번호가 적힌 줄
    last_i = last_run = None
    for i in range(len(grid) - 1, hdr_i, -1):
        cell = grid[i][run_c] if run_c < len(grid[i]) else ""
        if cell.strip().isdigit():
            last_i, last_run = i, int(cell.strip())
            break
    if last_run is None:
        sys.exit("기존 Run 행을 찾지 못했다")
    print("마지막 작성 : Run %d (시트 %d행)" % (last_run, last_i + 1))

    # 그 뒤가 정말 비어 있는지 확인한다. 아니면 멈춘다 (덮어쓰기 방지)
    for i in range(last_i + 1, len(grid)):
        if any(c.strip() for c in grid[i]):
            sys.exit("멈춤 : %d행에 내용이 있다. 덮어쓸 수 없다" % (i + 1))

    carry = {c: (grid[last_i][col[norm(c)]] if col.get(norm(c), 99) < len(grid[last_i]) else "")
             for c in CARRY}
    print("복사해 갈 값 :", {k: v for k, v in carry.items() if v})

    pre = {}
    if a.scan:
        for ln in open(a.scan):
            f = ln.rstrip("\n").split("\t")
            if len(f) >= 5 and f[0].isdigit() and f[2]:
                pre[int(f[0])] = (int(f[2]), int(f[3]), int(f[4]))

    db = sqlite3.connect("file:%s?mode=ro" % DB, uri=True)
    rows = db.execute(
        "select runnum,stime,etime,onlbit,runlog,rundesc,nfadc,tfadc "
        "from runcatalog where runnum>? order by runnum", (last_run,)).fetchall()
    # 이 시트는 onlbit=0 인 런을 싣지 않는다 -- 기존 282행 중 단 하나도 없다(실증).
    # stime 이 없는 런은 진행 중이거나 마감되지 않은 것이라 뺀다.
    if not a.all_runs:
        keep, drop = [], []
        for r in rows:
            (keep if (r[3] == 1 and r[1]) else drop).append(r)
        if drop:
            print("제외 %d 런 (onlbit!=1 또는 stime 없음) : %s"
                  % (len(drop), " ".join(str(d[0]) for d in drop)))
        rows = keep
    if a.limit:
        rows = rows[:a.limit]
    print("추가 대상 : %d 런 (%s ~ %s)" % (len(rows), rows[0][0], rows[-1][0]) if rows else "추가할 런이 없다")
    if not rows:
        return

    out = []
    for run, st, et, onl, log, desc, nf, tf in rows:
        n, raw, prd = pre.get(run, (None, None, None))
        if n is None:
            n, raw, prd = scan_run(run)
        rate = round(nf / tf / 1000.0, 2) if (nf and tf) else ""
        issue = "" if onl == 1 else (log or "").strip()
        rec = {
            "run": run,
            "start date (yyyy-mm-dd)": (st or "")[:10],
            "start time (hh:mm)": (st or "")[11:16],
            "duration": duration(st, et),
            "max subrun": n if n is not None else "",
            "event rate (khz)": rate,
            "raw (gb)": gb(raw),
            "prd (gb)": gb(prd),
            "description": (desc or "").strip(),
            "data issue": issue,
        }
        for c in CARRY:
            rec[norm(c)] = carry[c]
        line = [""] * len(hdr)
        for k, v in rec.items():
            if k in col:
                line[col[k]] = v
        out.append(line)

    print("\n--- 처음 3행 미리보기 (Description 은 60자로 줄임) ---")
    for l in out[:3]:
        print([str(x)[:60] for x in l])

    if not a.commit:
        print("\n미리보기다. 실제로 쓰려면 --commit")
        return

    first = last_i + 2                      # 1-base, 마지막 줄 바로 다음
    rng = gspread.utils.rowcol_to_a1(first, 1) + ":" + \
          gspread.utils.rowcol_to_a1(first + len(out) - 1, len(hdr))
    ws.update(values=out, range_name=rng, value_input_option="USER_ENTERED")
    print("기록함 : %s  (%d행)" % (rng, len(out)))


if __name__ == "__main__":
    main()
