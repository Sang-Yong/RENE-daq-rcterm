#!/usr/bin/env python3
"""저장소 서버의 외장하드 백업 기록을 구글시트 'back_up_hdd_log' 탭에 이어 쓴다.

    append_backup_rows.py --index <parts_index.txt> --log <backup_log.txt> [--mounts <파일>] [--source-dirs <파일>]
                          [--sheet-tsv <파일>] [--commit] [--creds <json>]

원천 (둘 다 저장소 서버 ~/sykim/backup_log/ 에 있다. scripts/backup-sheetlog.sh 가 ssh 로 받아 넘긴다)
    parts_index.txt   run  UUID  시각  files  bytes  first  last  [mode  mount  model  serial  capKB]
                      2026-09-12 이전 줄은 7 열(전부 part). 그 뒤는 12 열이고 full 도 들어 있다.
    backup_log.txt    '=== 하드 <mount> <dev> UUID=<uuid> 회차 시작 ===' 줄에서 UUID -> 마운트를 배우고,
                      '<run> 완료 및 서버에서 제거됨.' 줄로 색인에 없는 옛 full 전송(2026-09-12 이전)을 되메운다.
보조
    --mounts        'uuid<TAB>mount' 줄들 (지금 서버에 붙어 있는 하드). Status 열에 쓴다
    --source-dirs   서버 /data/RAW 에 남아 있는 런 폴더 이름 줄들. 'Files Left'·'Source Deleted' 열에 쓴다

규칙 (§11.5 와 같다)
    * 기존 행은 절대 손대지 않는다. 시트의 마지막 (Backup Date, Backup Time) 보다 늦은 기록만 뒤에 붙인다.
      같은 (run, date, time) 이 이미 있으면 건너뛴다.
    * 기본은 미리보기. --commit 이라야 쓴다. 쓰기 전 시트 전체를 백업하고, 쓴 뒤 되읽어 대조한다.
    * --sheet-tsv 를 주면 구글 대신 그 TSV 를 읽고(기존 행) 거기에 덧붙인다 -- 시험용. 네트워크에 닿지 않는다.
"""
import argparse, glob, os, re, sys, time

SHEET_ID = "1-8wPIg-Q-DpgsyBeSiwHezxM6QlcqhZ3qspAFGusqD0"
GID = 219954027                       # 탭 back_up_hdd_log
HEADER = ["No", "Backup Date", "Backup Time", "Run", "Type", "Files", "Size (GB)", "Subrun Range",
          "First File", "Last File", "Files Left in Source", "Status", "Disk Label", "Disk Mount",
          "Disk UUID", "Disk Model", "Disk Serial", "Disk Capacity", "Dest Path", "Verified",
          "Source Deleted", "Also at KHU", "Script", "Storage Location", "Notes"]
SCOPES = ["https://www.googleapis.com/auth/spreadsheets"]
#  full 전송은 2026-09-12 판부터 색인에 남는다. 그 전 세션(옛 판이 도는 동안 포함)의 full 은 backup_log 의
#  "완료 및 서버에서 제거됨" 줄로 되메운다 -- 색인에 그 런의 full 행이 없을 때만 (런은 한 번만 제거되므로 런이 열쇠다).


def find_creds():
    env = os.environ.get("RENE_SHEETS_SA")
    if env and os.path.isfile(env):
        return env
    here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    for d in (os.path.join(here, ".config", "rene"), os.path.expanduser("~/.config/rene")):
        hit = sorted(glob.glob(os.path.join(d, "*.json")))
        if hit:
            return hit[0]
    return None


def read_lines(path):
    if not path or not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8", errors="replace") as fh:
        return [ln.rstrip("\n") for ln in fh]


MONTHS = {m: i for i, m in enumerate(["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], 1)}
LOG_TS = re.compile(r"^\[\w{3} (\w{3}) +(\d+) (\d{2}):(\d{2}):(\d{2}) (AM|PM) \w+ (\d{4})\]\s*(.*)$")


def log_ts(line):
    """'[Sat Sep 12 04:10:42 AM KST 2026] ...' -> ('2026-09-12 04:10:42', 나머지). 못 읽으면 None."""
    m = LOG_TS.match(line)
    if not m:
        return None
    mon, day, hh, mm, ss, ap, year, rest = m.groups()
    h = int(hh) % 12 + (12 if ap == "PM" else 0)
    return f"{year}-{MONTHS[mon]:02d}-{int(day):02d} {h:02d}:{mm}:{ss}", rest


def subrun_of(name):
    m = re.search(r"\.root\.(\d{5})$", name or "")
    return m.group(1) if m else None


def gb(b):
    try:
        return f"{int(b) / 1e9:.1f}"
    except (TypeError, ValueError):
        return ""


def parse_index(lines):
    out = []
    for ln in lines:
        if not ln.strip() or ln.startswith("#"):
            continue
        f = ln.split("\t")
        if len(f) < 7:
            continue
        rec = {"run": f[0], "uuid": f[1], "ts": f[2], "files": f[3], "bytes": f[4], "first": f[5], "last": f[6],
               "mode": f[7] if len(f) > 7 and f[7] else "part", "mount": f[8] if len(f) > 8 else "",
               "model": f[9] if len(f) > 9 else "", "serial": f[10] if len(f) > 10 else "",
               "capkb": f[11] if len(f) > 11 else "", "src": "index"}
        out.append(rec)
    return out


def parse_log(lines, indexed_full=frozenset()):
    """UUID -> 마운트 (마지막 회차 시작 기준) 와, 색인에 없는 full 완료 기록."""
    uuid_mount, cur_mount, cur_uuid, fulls = {}, "", "", []
    for ln in lines:
        p = log_ts(ln)
        if not p:
            continue
        ts, rest = p
        m = re.search(r"=== 하드 (\S+) \S+ UUID=(\S+) 회차 시작", rest)
        if m:
            cur_mount, cur_uuid = m.group(1), m.group(2)
            uuid_mount[cur_uuid] = cur_mount
            continue
        m = re.match(r"(\d{6}) 완료 및 서버에서 제거됨", rest)
        if m and m.group(1) not in indexed_full:
            fulls.append({"run": m.group(1), "uuid": cur_uuid, "ts": ts, "files": "", "bytes": "", "first": "",
                          "last": "", "mode": "full", "mount": cur_mount, "model": "", "serial": "", "capkb": "",
                          "src": "log"})
    return uuid_mount, fulls


def make_row(no, r, uuid_mount, mounted, srcdirs):
    date, tm = (r["ts"].split(" ") + [""])[:2]
    mount = r["mount"] or uuid_mount.get(r["uuid"], "")
    lo, hi = subrun_of(r["first"]), subrun_of(r["last"])
    if lo and hi:
        lo, hi = min(lo, hi), max(lo, hi)     # 첫/끝 파일은 이름순이라 서브런 번호가 뒤집힐 수 있다
    rng = f"{lo}~{hi}" if lo and hi else ""
    left = ""
    if srcdirs is not None:
        left = "0" if r["run"] not in srcdirs else "(still on server)"
    if r["mode"] == "full":
        deleted = "Y"
    else:
        deleted = "Y (run complete across disks)" if (srcdirs is not None and r["run"] not in srcdirs) else "moved files only"
    if mounted is None:
        status = ""
    elif r["uuid"] in mounted:
        status = "on disk (attached)"
    else:
        status = "on disk (not attached)"
    cap = ""
    if r["capkb"]:
        try:
            cap = f"{int(r['capkb']) / 1073741824:.1f} TB"
        except ValueError:
            cap = ""
    notes = "auto (backup-sheetlog)"
    if r["src"] == "log":
        notes += "; full move recorded from backup_log.txt (not in index) — file count/size not available"
    dest = f"{mount}/RENE_data_backup/{r['run']}" if mount else ""
    return [str(no), date, tm, r["run"], r["mode"], r["files"], gb(r["bytes"]), rng, r["first"], r["last"],
            left, status, "", mount, r["uuid"], r["model"], r["serial"], cap, dest,
            "count+bytes" if r["files"] else "", deleted, "", "code9", "", notes]


def load_sheet_tsv(path):
    rows = []
    for ln in read_lines(path):
        if ln.strip():
            rows.append(ln.split("\t"))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--index", required=True)
    ap.add_argument("--log", default="")
    ap.add_argument("--mounts", default="")
    ap.add_argument("--source-dirs", default="")
    ap.add_argument("--sheet-tsv", default="")
    ap.add_argument("--commit", action="store_true")
    ap.add_argument("--creds", default="")
    ap.add_argument("--backup-dir", default="/Data_ssd/LOG/backup-sheetlog")
    a = ap.parse_args()

    recs = parse_index(read_lines(a.index))
    indexed_full = frozenset(r["run"] for r in recs if r["mode"] == "full")
    uuid_mount, fulls = parse_log(read_lines(a.log), indexed_full) if a.log else ({}, [])
    recs += fulls
    recs.sort(key=lambda r: r["ts"])
    mounted = None
    if a.mounts:
        mounted = {ln.split("\t")[0].strip() for ln in read_lines(a.mounts) if ln.strip()}
    srcdirs = None
    if a.source_dirs:
        srcdirs = {ln.strip() for ln in read_lines(a.source_dirs) if ln.strip()}

    # ---- 기존 행 ----
    ws = None
    if a.sheet_tsv:
        grid = load_sheet_tsv(a.sheet_tsv)
    else:
        creds = a.creds or find_creds()
        if not creds:
            sys.exit("[FATAL] 서비스 계정 json 을 찾지 못했다")
        from google.oauth2.service_account import Credentials
        import gspread
        cr = Credentials.from_service_account_file(creds, scopes=SCOPES)
        ws = gspread.authorize(cr).open_by_key(SHEET_ID).get_worksheet_by_id(GID)
        grid = ws.get_all_values()
    if not grid or [c.strip() for c in grid[0][:3]] != HEADER[:3]:
        sys.exit(f"[FATAL] 헤더가 기대와 다르다 : {grid[0][:5] if grid else '(빈 시트)'}")
    body = [r for r in grid[1:] if any(c.strip() for c in r)]
    have = {(r[3].strip(), r[1].strip(), r[2].strip()) for r in body if len(r) > 3}
    last_ts = max((f"{r[1].strip()} {r[2].strip()}" for r in body if len(r) > 2 and r[1].strip()), default="")
    nos = [int(r[0]) for r in body if r and r[0].strip().isdigit()]
    no = max(nos) if nos else 0

    new = []
    for r in recs:
        if r["ts"] <= last_ts:
            continue
        key = (r["run"], r["ts"][:10], r["ts"][11:])
        if key in have:
            continue
        no += 1
        new.append(make_row(no, r, uuid_mount, mounted, srcdirs))
        have.add(key)

    print(f"[INFO] 시트 기존 {len(body)} 행 (마지막 {last_ts or '-'}) · 서버 기록 {len(recs)} 건 · 새 행 {len(new)}")
    for row in new:
        print("  " + " | ".join(row[:8]) + f" | {row[13]} {row[16]} | {row[11]}")
    if not new:
        return 0
    if not a.commit:
        print("[DRY] --commit 이 없어 쓰지 않는다")
        return 0

    if a.sheet_tsv:
        with open(a.sheet_tsv, "a", encoding="utf-8") as fh:
            for row in new:
                fh.write("\t".join(row) + "\n")
        print(f"[SHEET-TSV] {len(new)} 행 추가 -> {a.sheet_tsv}")
        return 0

    os.makedirs(a.backup_dir, exist_ok=True)
    bak = os.path.join(a.backup_dir, time.strftime("sheet-backup-%Y%m%d%H%M%S.tsv"))
    with open(bak, "w", encoding="utf-8") as fh:
        for r in grid:
            fh.write("\t".join(r) + "\n")
    ws.append_rows(new, value_input_option="RAW")
    after = ws.get_all_values()
    kept = [r for r in after[:len(grid)]]
    if [[c.strip() for c in x] for x in kept] != [[c.strip() for c in x] for x in grid]:
        sys.exit(f"[FATAL] 되대조 실패 -- 기존 행이 바뀌었다. 백업 {bak}")
    tail = [[c.strip() for c in r[:len(HEADER)]] for r in after[len(grid):len(grid) + len(new)]]
    if tail != [[c.strip() for c in r] for r in new]:
        sys.exit(f"[FATAL] 되대조 실패 -- 쓴 것과 읽은 것이 다르다. 백업 {bak}")
    print(f"[SHEET] {len(new)} 행 추가 + 되대조 통과 (백업 {bak})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
