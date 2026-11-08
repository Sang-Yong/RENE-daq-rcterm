#!/usr/bin/env bash
# append_runs.py 가 이벤트 0 인 런(nfadc=0)을 싣지 않는지 (2026-11-08 run 4441~4445 가 onlbit=1 · nfadc=0 으로
#   GoodRuns 에 실렸다). 구글·운영 DB 무접촉 (가짜 gspread, 가짜 runcatalog)
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export RENE_CONFIG_DIRS=$T/none RENE_RAW_ROOTS=$T/noraw THR_TABLE=$T/none.tsv RENE_RUNDB=$T/run.db
python3 - "$T/run.db" <<'PY'
import sqlite3, sys
d = sqlite3.connect(sys.argv[1])
d.execute("create table runcatalog (runnum integer primary key, stime text, etime text, onlbit integer, runlog text, rundesc text, nfadc integer, tfadc real, config text)")
d.execute("insert into runcatalog values (4387,'2026-10-16 09:04:13','2026-10-16 11:04:13',1,'','desc',1000,7200.0,'x.config')")
# 실물 run 4441 처럼 : 정상 종료 · onlbit=1 · nfadc=0 · tfadc=0 (2400 s 동안 사건 없음)
d.execute("insert into runcatalog values (4388,'2026-11-08 09:37:00','2026-11-08 10:17:00',1,'','desc',0,0.0,'x.config')")
d.execute("insert into runcatalog values (4389,'2026-11-08 10:18:00','2026-11-08 10:58:00',1,'','desc',NULL,NULL,'x.config')")
d.commit()
PY
python3 - "$DIR" "$T" <<'PY'
import sys, os, types, io, contextlib
D, T = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(D, "tools/sheetlog"))
P = F = 0
def ok(c, m):
    global P, F
    if c: P += 1; print("  ok   " + m)
    else: F += 1; print("  FAIL " + m)

class WS:
    def __init__(s, grid, rows):
        s.grid = [r[:] for r in grid]; s.row_count = rows; s.title = "Y2026B"; s.calls = []
    def get_all_values(s): return [r[:] for r in s.grid]
    def add_rows(s, n): s.calls.append(("add_rows", n)); s.row_count += n
    def update(s, values, range_name, value_input_option=None):
        import re
        m = re.match(r"[A-Z]+(\d+):[A-Z]+(\d+)$", range_name)
        a, b = int(m.group(1)), int(m.group(2))
        if b > s.row_count:
            raise RuntimeError("APIError: [400]: Range (Y2026B!%s) exceeds grid limits. Max rows: %d" % (range_name, s.row_count))
        s.calls.append(("update", range_name))
        while len(s.grid) < b: s.grid.append([""] * len(s.grid[0]))
        for i, v in enumerate(values): s.grid[a - 1 + i] = [str(x) for x in v]

import sheet_grid
# ---- [1] 도우미 단독 ----
w = WS([["x"]], 358)
ok(sheet_grid.ensure_rows(w, 358, True, log=lambda *_: 0) == 0 and not w.calls, "필요 행 <= 그리드 : 아무것도 안 한다")
w = WS([["x"]], 358)
n = sheet_grid.ensure_rows(w, 359, False, log=lambda *_: 0)
ok(n == 21 and not w.calls and w.row_count == 358, "미리보기 : 늘릴 수(21)만 돌려주고 add_rows 는 안 부른다")
n = sheet_grid.ensure_rows(w, 359, True, log=lambda *_: 0)
ok(w.calls == [("add_rows", 21)] and w.row_count == 379, "commit : add_rows(필요 + 여유 20)")

# ---- [2] append_runs.main 의 추가 경로 (gspread 를 가짜로) ----
hdr = ["Run", "Start Date", "Start Time", "Duration", "Max subrun", "Event Rate (kHz)", "RAW (GB)", "PRD (GB)", "Description", "Data issue"]
grid = [hdr] + [[str(4029 + i)] + [""] * 9 for i in range(357)]       # 358행, 마지막 Run 4386
grid[-1][0] = "4386"
def fake_gspread(ws):
    g = types.ModuleType("gspread")
    g.authorize = lambda cr: types.SimpleNamespace(open_by_key=lambda k: types.SimpleNamespace(get_worksheet_by_id=lambda i: ws))
    u = types.ModuleType("gspread.utils")
    def a1(r, c): return "%s%d" % (chr(64 + c), r)
    u.rowcol_to_a1 = a1; g.utils = u
    sys.modules["gspread"] = g; sys.modules["gspread.utils"] = u
    oa = types.ModuleType("google.oauth2.service_account")
    oa.Credentials = types.SimpleNamespace(from_service_account_file=lambda *a, **k: None)
    sys.modules["google"] = types.ModuleType("google"); sys.modules["google.oauth2"] = types.ModuleType("google.oauth2")
    sys.modules["google.oauth2.service_account"] = oa
def run(ws, args):
    fake_gspread(ws)
    import importlib, append_runs
    importlib.reload(append_runs)
    sys.argv = ["append_runs.py", "--creds", "/dev/null"] + args
    buf = io.StringIO(); rc = 0
    with contextlib.redirect_stdout(buf):
        try: append_runs.main()
        except SystemExit as e: rc = e.code if isinstance(e.code, int) else 1
    return rc, buf.getvalue()

w = WS(grid, 358)
rc, out = run(w, [])
ok(rc == 0 and "건너뜀(0 사건) 1 런 : 4388" in out, "미리보기 : nfadc=0 인 4388 을 '건너뜀(0 사건)' 으로 알린다")
ok("추가 대상 : 2 런 (4387 ~ 4389)" in out, "추가 대상은 4387 · 4389 (nfadc NULL 인 옛 꼴은 그대로)")
w = WS(grid, 400)
rc, out = run(w, ["--commit"])
ok(rc == 0 and [r[0] for r in w.grid[358:360]] == ["4387", "4389"], "commit : 4388 은 시트에 없다")
ok(w.grid[:358] == grid, "기존 358행 그대로")
print("PASS %d FAIL %d" % (P, F)); sys.exit(1 if F else 0)
PY
