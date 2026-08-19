#!/usr/bin/env python3
"""RENE 런 로그를 구글시트에 이어 쓴다.  규칙은 CLAUDE.md 11.5 가 정본이다.

  * 기존에 작성된 내용은 절대 수정하지 않는다
  * 마지막으로 작성된 Run 번호 이후의 런만 추가한다
  * 마지막 작성 줄 다음의 빈 줄부터 이어 쓴다

기본은 미리보기다.  실제로 쓰려면 --commit 을 준다.
"""
import argparse, glob, os, sqlite3, subprocess, sys, datetime, re

SHEET_ID = "1-8wPIg-Q-DpgsyBeSiwHezxM6QlcqhZ3qspAFGusqD0"
GID      = 0
DB       = "/Data_ssd/runcatalog.db"
ROOTS    = ["/Data_ssd/RAW", "/data/RAW", "/scratch/RAW"]

#  ---- 시트의 소유권 경계 (CLAUDE.md 11.5) ----------------------------
#  금지선은 '기존 행' 이 아니라 '남의 행' 이다. 다른 계정의 사람들이 써 놓은
#  행은 내용도 위치도 건드리지 않는다. 우리가 쓴 행은 우리가 고쳐도 된다.
#  ★ 행 번호로 정하면 안 된다 -- 중간에 끼워 넣으면 아래가 전부 밀린다.
OURS_MIN   = 4280                                  # 이 번호 이상은 우리가 썼다
OURS_EXTRA = {4208, 4209, 4210, 4211, 4276}        # 그보다 앞에 되메운 것


def is_ours(run):
    return run >= OURS_MIN or run in OURS_EXTRA
#  DAQ 로그도 같은 우선순위로 찾는다. 런이 옮겨 다니므로 한 곳만 보면 놓친다.
LOGROOTS = ["/Data_ssd/LOG", "/data/LOG", "/scratch/LOG"]

# 직전 행에서 그대로 복사해 오는 열들 (사용자 지침)
CARRY = ["Detector", "Source", "PMT-A HV (V)", "PMT-B HV (V)", "THR (mV)",
         "Coincidence (ns)", "Record length", "Time after HV ON", "TLT"]


def norm(s):
    return re.sub(r"\s+", " ", (s or "").strip()).lower()


def _dirs(run):
    """그 런이 존재하는 모든 root 의 디렉터리. 앞이 이긴다."""
    rr = "%06d" % run
    return [os.path.join(r, rr) for r in ROOTS if os.path.isdir(os.path.join(r, rr))]


def _tally(d, pred):
    n = b = 0
    try:
        for f in os.scandir(d):
            if f.is_file() and pred(f.name):
                n += 1
                b += f.stat().st_size
    except OSError:
        pass
    return n, b


def scan_run(run):
    """서브런 수 / RAW bytes / PRD 수 / PRD bytes 를 디스크에서 실측한다.

    RAW 와 PRD 는 **각각 따로** root 를 고른다.  dataflow 가 옮기는 도중이거나
    옛 --outroot 구성이면 한 런의 RAW 와 PRD 가 서로 다른 디스크에 있다
    (run 4290 : RAW 는 /scratch, PRD 는 /Data_ssd).  한 디렉터리만 보면
    RAW 를 0 GB 로 적는다.
    """
    rr = "%06d" % run
    dirs = _dirs(run)
    nf = raw = 0
    for d in dirs:
        nf, raw = _tally(d, lambda x: x.startswith("FADC_%s.root" % rr)
                         or x.startswith("SADC_%s.root" % rr))
        if nf:
            # SADC 까지 합산했으므로 서브런 수는 FADC 만 다시 센다
            nf, _ = _tally(d, lambda x: x.startswith("FADC_%s.root" % rr))
            break
    np = prd = 0
    for d in dirs:
        np, prd = _tally(os.path.join(d, "PRD"),
                         lambda x: x.endswith(".root") and rr in x)
        if np:
            break
    return nf, raw, np, prd


CRED_HINTS = ["$RENE_SHEETS_SA",
              "<저장소>/.config/rene/*.json",
              "~/.config/rene/*.json"]


def find_creds():
    """자격증명 위치는 사이트마다 다르다. 환경변수 -> 저장소 -> 홈 순서로 찾는다."""
    env = os.environ.get("RENE_SHEETS_SA")
    if env and os.path.isfile(env):
        return env
    here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    for d in (os.path.join(here, ".config", "rene"),
              os.path.expanduser("~/.config/rene")):
        hit = sorted(glob.glob(os.path.join(d, "*.json")))
        if hit:
            return hit[0]
    return None


TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})")


def derive_times(run):
    """DB 에 시각이 없는 런의 시작/끝을 **로컬 디스크에서** 끌어온다.

    시작 = TCB 로그의 첫 줄 (DAQ 가 부팅한 시각)
    끝   = 마지막 FADC 서브런 파일의 mtime (자료가 실제로 멈춘 시각)

    끝을 TCB 로그의 마지막 줄로 잡으면 안 된다 -- rcterm 이 먼저 떨어져 나가고
    DAQ 가 한동안 더 쓰는 경우가 있다 (run 4291 : 로그 22:43 / 마지막 파일 22:53).
    """
    rr = "%06d" % run
    st = et = ""
    for r in LOGROOTS:
        f = os.path.join(r, "TCB_%s.log" % rr)
        if not os.path.isfile(f):
            continue
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    m = TS_RE.match(line)
                    if m:
                        st = m.group(1)
                        break
        except OSError:
            pass
        break
    newest = 0
    for d in _dirs(run):
        try:
            for f in os.scandir(d):
                if f.is_file() and f.name.startswith("FADC_%s.root" % rr):
                    newest = max(newest, f.stat().st_mtime)
        except OSError:
            pass
        if newest:
            break
    if newest:
        et = datetime.datetime.fromtimestamp(newest).strftime("%Y-%m-%d %H:%M:%S")
    return st, et


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


def make_row(dbrow, pre, hdr, col, carry):
    """DB 한 줄 + 디스크 실측으로 시트 한 행을 만든다.

    ★ 로컬 디스크가 우선이다. 시각만은 DB 를 먼저 본다 -- 기존 행들이 전부
      DB 의 stime/etime 으로 적혀 있어서, 같은 런을 두 기준으로 섞어 쓰면
      표 안에서 서로 안 맞는다. DB 가 비어 있을 때만 디스크에서 끌어온다.
    """
    run, st, et, onl, log, desc, nf, tf = dbrow
    derived = ""
    if not st:
        st2, et2 = derive_times(run)
        if st2 or et2:
            st, et = st or st2, et or et2
            derived = "times from DAQ log and file mtime"
    if run in pre:
        n_prd, raw, prd = pre[run]      # 원격 실측 -- FADC 수는 알 수 없다
        n_fadc = 0
    else:
        n_fadc, raw, n_prd, prd = scan_run(run)
    rate = round(nf / tf / 1000.0, 2) if (nf and tf) else ""
    issue = "" if onl == 1 else (log or "").strip()
    # 시각을 디스크에서 끌어왔으면 그 사실을 남긴다. 나중에 이 행을 보는 사람이
    # DB 기록과 같은 무게로 읽으면 곤란하다.
    if derived:
        issue = (issue + "; " + derived) if issue else derived
    # 이 열은 개수가 아니라 '마지막 서브런 번호'다 = 개수-1.
    # 기존 13개 런에서 실측 확인 (4085 4204 4207 4226 4232 4234 4237~4241 4243 4246).
    # 기준은 RAW(FADC) 서브런이다 -- 후처리가 덜 끝난 런은 PRD 가 모자란다
    # (4237 : FADC 12722 / PRD 12720, 시트 12721).  PRD 밖에 없으면 그것으로 센다.
    base = n_fadc or n_prd
    maxsub = base - 1 if base else ""
    prd_gb = gb(prd) if n_prd else ""   # 없는 것은 0.0 이 아니라 빈 칸
    raw_gb = gb(raw) if raw else ""
    rec = {
        "run": run,
        "start date (yyyy-mm-dd)": (st or "")[:10],
        "start time (hh:mm)": (st or "")[11:16],
        "duration": duration(st, et),
        "max subrun": maxsub,
        "event rate (khz)": rate,
        "raw (gb)": raw_gb,
        "prd (gb)": prd_gb,
        "description": (desc or "").strip(),
        "data issue": issue,
    }
    for c in CARRY:
        rec[norm(c)] = carry[c]
    line = [""] * len(hdr)
    for k, v in rec.items():
        if k in col:
            line[col[k]] = v
    return line


def do_insert(a, ws, grid, hdr_i, hdr, col, run_c):
    """빠진 런을 번호 순서에 맞게 끼워 넣는다.

    ★ 이것은 11.5 의 '마지막 Run 이후에만 추가한다' 규칙을 벗어나는 동작이다.
      2026-08-20 에 사용자가 명시적으로 요청해서 넣었다. 기존 행의 **내용은
      건드리지 않고** 위치만 아래로 밀린다.

    안전장치 :
      * 이미 있는 Run 번호는 건너뛴다 (중복 행을 만들지 않는다)
      * 아래에서 위로 넣는다 -- 위에서부터 넣으면 다음 삽입 위치가 어긋난다
      * 쓰기 전에 기존 격자를 통째로 들고 있다가, 쓴 뒤 한 줄씩 대조한다
    """
    import gspread

    want = sorted({int(x) for x in re.split(r"[,\s]+", a.insert) if x.strip().isdigit()})
    have = {}
    for i in range(hdr_i + 1, len(grid)):
        c = grid[i][run_c] if run_c < len(grid[i]) else ""
        if c.strip().isdigit():
            have[int(c.strip())] = i
    dup = [r for r in want if r in have]
    if dup:
        print("이미 있어 건너뜀 :", " ".join(map(str, dup)))
    want = [r for r in want if r not in have]
    if not want:
        print("끼워 넣을 런이 없다")
        return

    db = sqlite3.connect("file:%s?mode=ro" % DB, uri=True)
    plans = []
    for run in want:
        row = db.execute(
            "select runnum,stime,etime,onlbit,runlog,rundesc,nfadc,tfadc "
            "from runcatalog where runnum=?", (run,)).fetchone()
        if row is None:
            print("  DB 에 없다, 건너뜀 :", run)
            continue
        # 넣을 자리 = 자기보다 큰 첫 런의 행. 없으면 맨 끝.
        after = [i for r, i in sorted(have.items()) if r > run]
        at = after[0] if after else max(have.values()) + 1
        # 양식 열은 바로 위 행에서 가져온다 (11.5 규칙)
        above = at - 1
        carry = {c: (grid[above][col[norm(c)]]
                     if col.get(norm(c), 99) < len(grid[above]) else "")
                 for c in CARRY}
        plans.append((run, at, make_row(row, {}, hdr, col, carry)))

    if not plans:
        return
    print("\n--- 끼워 넣을 %d 행 (시트 행번호는 1-base, 아래에서 위로 처리) ---" % len(plans))
    for run, at, line in plans:
        print("  run %-5d -> %d행 앞  [%s]  %s"
              % (run, at + 1, "우리" if is_ours(run) else "★남의 구간",
                 [str(x)[:24] for x in line[:6]]))
    alien = [r for r, _, _ in plans if not is_ours(r)]
    if alien:
        print("  ※ %s 은(는) 남의 행 사이에 들어간다. 내용은 그대로이고 위치만 밀린다."
              % " ".join(map(str, alien)))

    if not a.commit:
        print("\n미리보기다. 실제로 쓰려면 --commit")
        return

    before = [r[:] for r in grid]
    #  아래에서 위로 넣는다. 같은 자리에 여럿이 들어갈 때는 **런 번호도 내림차순**
    #  이어야 한다 -- 같은 index 에 계속 밀어 넣으면 나중 것이 위로 올라가므로,
    #  오름차순으로 넣으면 그 구간만 거꾸로 박힌다 (2026-08-20 에 실제로 겪었다:
    #  4208~4211 이 4211 4210 4209 4208 순으로 들어갔다).
    for run, at, line in sorted(plans, key=lambda x: (-x[1], -x[0])):
        ws.insert_row(line, index=at + 1, value_input_option="USER_ENTERED")
        print("  넣음 : run %d -> %d행" % (run, at + 1))

    # ---- 대조 : 기존 행이 내용 그대로인지 ----
    after_grid = ws.get_all_values()
    ins = {run for run, _, _ in plans}
    kept = [r for r in after_grid
            if not (r and r[run_c].strip().isdigit() and int(r[run_c]) in ins)]
    bad = 0
    for i, (x, y) in enumerate(zip(before, kept)):
        if [c.strip() for c in x] != [c.strip() for c in y]:
            bad += 1
            if bad <= 3:
                print("  ★ 어긋남 %d행" % (i + 1))
    print("대조 : 기존 %d행 중 어긋남 %d건%s"
          % (len(before), bad, "" if bad == 0 else "  ← 확인 필요"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--creds", help="서비스 계정 json. 생략하면 아래 순서로 찾는다")
    ap.add_argument("--scan", help="미리 만들어 둔 스캔 결과 tsv (run/dir/n/raw/prd)")
    ap.add_argument("--commit", action="store_true", help="실제로 시트에 쓴다")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--all-runs", action="store_true",
                    help="onlbit 무관하게 전부 (기본은 onlbit=1 인 것만)")
    ap.add_argument("--insert", metavar="RUNS",
                    help="빠진 런을 번호 순서에 맞게 끼워 넣는다 (쉼표로 구분). "
                         "기존 행의 내용은 그대로이고 위치만 아래로 밀린다")
    a = ap.parse_args()

    import gspread
    from google.oauth2.service_account import Credentials

    creds = a.creds or find_creds()
    if not creds:
        sys.exit("서비스 계정 json 을 찾지 못했다. --creds 로 지정하라\n  찾아본 곳 : "
                 + ", ".join(CRED_HINTS))

    cr = Credentials.from_service_account_file(
        creds, scopes=["https://www.googleapis.com/auth/spreadsheets"])
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

    if a.insert:
        return do_insert(a, ws, grid, hdr_i, hdr, col, run_c)

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

    out = [make_row(r, pre, hdr, col, carry) for r in rows]
    # 쓰기 전에는 전부 보여 준다. 20행이 넘으면 앞뒤만.
    show = out if len(out) <= 20 else out[:10] + out[-10:]
    print("\n--- 미리보기 %d/%d 행 (Description 은 40자로 줄임) ---" % (len(show), len(out)))
    for l in show:
        print([str(x)[:40] for x in l])

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
