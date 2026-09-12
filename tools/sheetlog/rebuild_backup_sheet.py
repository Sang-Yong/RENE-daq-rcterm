#!/usr/bin/env python3
"""
rebuild_backup_sheet.py — 외장하드 백업 기록 시트(back_up_hdd_log)를 통째로 다시 쓴다 (2026-09-12, 사용자 지시).

입력 세 갈래를 합쳐 (런 번호, 시각) 순으로 정렬한 표를 만든다.
  ① 하드 스캔  tools/sheetlog/disk-inventory-remote.sh 의 출력 (scripts/backup-disk-inventory.sh 가 하드마다 파일로)
               = 실물이 담고 있는 것. 시리얼·모델·용량·런별 개수/바이트/서브런 범위/복사 시각
  ② 서버 기록  ~/sykim/backup_log/parts_index.txt + backup_log.txt (append_backup_rows.py 와 같은 파서)
               = 언제 무엇을 보냈고 대조를 통과했는가
  ③ 기존 시트  손으로 적은 열(Also at KHU · Storage Location · Notes)을 (Run, UUID, 날짜) 로 맞춰 살린다.
               어느 갈래에서도 다시 만들 수 없는 옛 행은 그대로 옮긴다 — 행이 사라지는 일은 없다.

라벨 : 물리 하드(시리얼, 없으면 UUID)마다 RENE-<종류>-NNN. 종류는 그 하드가 담은 것 — RAW(최상위 FADC·SADC 만) ·
       PRD(PRD·PNG 만) · ALL(둘 다, 나누기 전의 옛 하드). NNN 은 종류별로 처음 담은 순서. 한 번 부여한 라벨은
       docs/backup-disks/disks.tsv 에 남아 다시 바뀌지 않는다 (사용자 지시 2026-09-13 : RENE-PRD-00? · RENE-RAW-00?). 재포맷으로 UUID 가 바뀐 하드(aliases.tsv)는 새 UUID 의
       라벨을 받고 옛 기록은 '소실' 로 표시한다.

기본은 미리보기. --commit 라야 시트를 지우고 다시 쓴다 (쓰기 전 백업 TSV, 쓴 뒤 되읽어 대조).
--sheet-tsv 는 시험용 — 구글에 닿지 않고 그 파일을 시트로 본다.
매시 37분의 append_backup_rows.py 는 이 표 위에도 그대로 붙는다 (마지막 시각 = 최대 시각, No = 최대 No).
"""
import argparse, csv, glob, io, os, re, sys, datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from append_backup_rows import (HEADER, SHEET_ID, GID, SCOPES, find_creds, read_lines, parse_index, parse_log,
                                subrun_of, gb, type_of)

DOCS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "docs", "backup-disks")


def tsv_rows(path):
    if not path or not os.path.exists(path):
        return []
    return [ln.split("\t") for ln in read_lines(path) if ln.strip() and not ln.startswith("#")]


def load_inventories(d):
    """DIR/*.tsv -> {uuid: disk}. disk = {uuid, mount, dev, model, serial, wwn, cap, used, fs_created, scanned_at, runs{run: rec}}"""
    disks = {}
    for f in sorted(glob.glob(os.path.join(d, "*.tsv"))) if d else []:
        cur = None
        for ln in read_lines(f):
            if not ln.strip():
                continue
            c = ln.split("\t")
            if c[0] == "#disk":
                cur = {"mount": c[1], "dev": c[2], "uuid": c[3], "model": c[4], "serial": c[5], "wwn": c[6],
                       "cap": c[7], "used": c[8], "fs_created": c[9], "scanned_at": c[10] if len(c) > 10 else "",
                       "runs": {}, "file": os.path.basename(f)}
                disks[cur["uuid"]] = cur
            elif c[0].startswith("#") or cur is None:
                continue
            else:
                k = ["run", "files", "bytes", "sub_lo", "sub_hi", "first", "last", "cfrom", "cto", "manifest",
                     "n_fadc", "n_sadc", "n_prd", "n_merged", "n_png", "n_other"]
                cur["runs"][c[0]] = dict(zip(k, c + [""] * (len(k) - len(c))))
    return disks


def load_aliases(path):
    return {r[0]: {"new": r[1], "at": r[2] if len(r) > 2 else "", "note": r[3] if len(r) > 3 else ""} for r in tsv_rows(path) if len(r) >= 2}


def load_known(path):
    return {r[0]: {"serial": r[1], "model": r[2] if len(r) > 2 else "", "wwn": r[3] if len(r) > 3 else "",
                   "source": r[4] if len(r) > 4 else ""} for r in tsv_rows(path) if len(r) >= 2}


def load_labels(path):
    """disks.tsv : key(serial 또는 uuid) -> label. 한 번 준 라벨은 지킨다."""
    out = {}
    for r in tsv_rows(path):
        if len(r) >= 2 and r[0] and r[1]:
            out[r[0]] = r[1]
    return out


def parse_log_all(lines, indexed_full):
    """append_backup_rows.parse_log + code7 시절의 'UUID: xxx' 줄도 하드 경계로 본다."""
    fixed = []
    for ln in lines:
        m = re.match(r"^(\[[^\]]+\])\s*탐색된 외장하드 UUID:\s*(\S+)", ln)
        if m:
            fixed.append(f"{m.group(1)} === 하드 /backup_hdd - UUID={m.group(2)} 회차 시작 ===")
        else:
            fixed.append(ln)
    return parse_log(fixed, indexed_full)


def run_cat(s):
    """스캔한 런 폴더가 담은 종류 : raw(최상위 FADC/SADC 만) · prd(PRD/PNG 만) · all(둘 다)."""
    raw = int(s["n_fadc"] or 0) + int(s["n_sadc"] or 0)
    prd = int(s["n_prd"] or 0)                   # PNG 는 어느 쪽에도 안 센다 (2026-05 의 손 분할은 PNG 를 RAW 쪽에 뒀다)
    if raw and not prd:
        return "raw"
    if prd and not raw:
        return "prd"
    return "all"


def disk_cat(rows_types):
    """하드의 종류 = 그 하드에 실린 행들의 Type 에서. 전부 RAW 면 RAW, 전부 PRD 면 PRD, 아니면 ALL."""
    cats = {t.split("·")[1] for t in rows_types if "·" in t}
    plain = any("·" not in t and t != "log-only" for t in rows_types)
    if plain or len(cats) != 1:
        return "ALL"
    return cats.pop()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--inventory", default="/Data_ssd/LOG/backup-inventory")
    ap.add_argument("--index", default="")
    ap.add_argument("--log", default="")
    ap.add_argument("--mounts", default="", help="uuid<TAB>mount 목록 (지금 붙어 있는 것)")
    ap.add_argument("--source-dirs", default="", help="ls -1 /data/RAW")
    ap.add_argument("--aliases", default=os.path.join(DOCS, "aliases.tsv"))
    ap.add_argument("--known-serials", default=os.path.join(DOCS, "known-serials.tsv"))
    ap.add_argument("--disks-tsv", default=os.path.join(DOCS, "disks.tsv"), help="라벨 정본 (읽고 갱신)")
    ap.add_argument("--disks-md", default=os.path.join(DOCS, "..", "BACKUP-DISKS.md"))
    ap.add_argument("--sheet-tsv", default="")
    ap.add_argument("--out-tsv", default="", help="미리보기 결과를 이 TSV 로")
    ap.add_argument("--commit", action="store_true")
    ap.add_argument("--creds", default="")
    ap.add_argument("--backup-dir", default="/Data_ssd/LOG/backup-sheetlog")
    a = ap.parse_args()

    inv = load_inventories(a.inventory)
    aliases = load_aliases(a.aliases)
    known = load_known(a.known_serials)
    labels = load_labels(a.disks_tsv)
    recs = parse_index(read_lines(a.index)) if a.index else []
    indexed_full = frozenset(r["run"] for r in recs if r["mode"] == "full")
    uuid_mount, fulls = parse_log_all(read_lines(a.log), indexed_full) if a.log else ({}, [])
    recs += fulls
    mounted = {ln.split("\t")[0].strip() for ln in read_lines(a.mounts) if ln.strip()} if a.mounts else set()
    srcdirs = {ln.strip() for ln in read_lines(a.source_dirs) if ln.strip()} if a.source_dirs else None

    # ---- 기존 시트 ----
    ws = None
    if a.sheet_tsv:
        grid = [ln.split("\t") for ln in read_lines(a.sheet_tsv) if ln.strip()]
    else:
        creds = a.creds or find_creds()
        if not creds:
            sys.exit("[FATAL] 서비스 계정 json 을 찾지 못했다")
        from google.oauth2.service_account import Credentials
        import gspread
        cr = Credentials.from_service_account_file(creds, scopes=SCOPES)
        ws = gspread.authorize(cr).open_by_key(SHEET_ID).get_worksheet_by_id(GID)
        grid = ws.get_all_values()
    if grid and [c.strip() for c in grid[0][:3]] != HEADER[:3]:
        sys.exit(f"[FATAL] 헤더가 기대와 다르다 : {grid[0][:5]}")
    old_rows = [r + [""] * (len(HEADER) - len(r)) for r in grid[1:] if any(c.strip() for c in r)]
    old_by_key = {}
    for r in old_rows:
        old_by_key.setdefault((r[3].strip(), r[14].strip()[:8], r[1].strip()), []).append(r)

    # ---- 물리 하드 목록 : 스캔 > known > 기록 ----
    def resolve(uuid):
        """uuid -> (물리키, 시리얼, 모델, wwn, 별칭인가)"""
        al = aliases.get(uuid)
        u = al["new"] if al else uuid
        if u in inv:
            d = inv[u]; return (d["serial"] or u, d["serial"], d["model"], d["wwn"], al)
        if u in known:
            k = known[u]; return (k["serial"] or u, k["serial"], k["model"], k["wwn"], al)
        for r in recs:
            if r["uuid"] == u and r.get("serial"):
                return (r["serial"], r["serial"], r.get("model", ""), "", al)
        return (u, "", "", "", al)

    # ---- 행 만들기 ----
    rows = []      # (sortkey, row)
    used_keys = set()
    rec_by_disk_run = {}
    for r in recs:
        rec_by_disk_run.setdefault((r["uuid"], r["run"]), []).append(r)

    def scan_note(d, run):
        s = d["runs"].get(run)
        if not s:
            return "", None
        return (f"scan {d['scanned_at'][:10]}: {s['files']} files / {gb(s['bytes'])} GB on disk"
                f" (FADC {s['n_fadc']} · SADC {s['n_sadc']} · PRD {s['n_prd']} · Merged {s['n_merged']} · PNG {s['n_png']})"), s

    def hand_merge(row, key):
        """기존 시트의 같은 행에서 손으로 적은 열을 가져온다."""
        for o in old_by_key.get(key, []):
            for i in (5, 6, 7, 8, 9, 10, 21, 23):           # Files · GB · Range · First/Last · Left · Also at KHU · Storage Location
                if o[i].strip() and not str(row[i]).strip():
                    row[i] = o[i].strip()
            if o[24].strip() and not o[24].strip().startswith("auto (backup-sheetlog)"):
                row[24] = (row[24] + " | " if row[24] else "") + "hand: " + o[24].strip()
            used_keys.add(key)
        return row

    # ① 서버 기록 행 (스캔이 있으면 대조 내용을 덧붙인다)
    for r in recs:
        pk, serial, model, wwn, al = resolve(r["uuid"])
        d = inv.get(aliases.get(r["uuid"], {}).get("new", r["uuid"]))
        date, tm = (r["ts"].split(" ") + [""])[:2]
        mount = r["mount"] or uuid_mount.get(r["uuid"], "")
        lo, hi = subrun_of(r["first"]), subrun_of(r["last"])
        if lo and hi:
            lo, hi = min(lo, hi), max(lo, hi)
        rng = f"{lo}~{hi}" if lo and hi else ""
        left = "" if srcdirs is None else ("0" if r["run"] not in srcdirs else "(still on server)")
        if r["mode"] == "full":
            deleted = "Y"
        else:
            deleted = "Y (run complete across disks)" if (srcdirs is not None and r["run"] not in srcdirs) else "moved files only"
        notes, verified = [], "count+bytes" if r["files"] else ""
        if r["src"] == "log":
            notes.append("full move recorded from backup_log.txt (not in index) — file count/size not available")
        status = ""
        if al:
            status = f"WIPED — disk reformatted {al['at']}"
            notes.append(al["note"])
            deleted = "Y (and backup wiped)"
        elif d and not al:
            sn, s = scan_note(d, r["run"])
            if s:
                notes.append(sn)
                if r["files"] and s["manifest"] == "0" and int(s["files"]) != int(r["files"]) and r["mode"] == "full":
                    notes.append(f"scan count {s['files']} ≠ record {r['files']}")
                verified = (verified + " + " if verified else "") + f"scan {d['scanned_at'][:10]}"
                if not r["files"] and r["mode"] == "full":
                    r = dict(r, files=s["files"], bytes=s["bytes"], first=s["first"], last=s["last"])
                    rng = f"{s['sub_lo']}~{s['sub_hi']}" if s["sub_lo"] and s["sub_hi"] else rng
            else:
                notes.append(f"★ scan {d['scanned_at'][:10]}: run NOT found on disk")
            status = "on disk (attached)" if d["uuid"] in mounted else "on disk (not attached)"
            status += " · verified by scan"
        elif mounted or a.mounts:
            status = "on disk (attached)" if r["uuid"] in mounted else "on disk (not attached, not yet scanned)"
        cap = f"{int(d['cap']) / 1e12:.2f} TB" if d and d.get("cap") else (f"{int(r['capkb']) / 1073741824:.1f} TB" if r.get("capkb") else "")
        model = model or r.get("model", "")
        dest = f"{mount}/RENE_data_backup/{r['run']}" if mount else ""
        script = "code9" if r["src"] != "log" or r["ts"] >= "2026-09-03" else "code7/8"
        row = ["", date, tm, r["run"], type_of(r), r["files"], gb(r["bytes"]), rng, r["first"], r["last"], left, status,
               "", mount, r["uuid"], model, serial, cap, dest, verified, deleted, "", script, "", "; ".join(notes)]
        row = hand_merge(row, (r["run"], r["uuid"][:8], date))
        rows.append(((r["run"], r["ts"]), pk, row))

    # ② 스캔에만 있는 런 (기록이 없는 하드 — 2026-04 의 옛 하드가 이렇다)
    for u, d in inv.items():
        pk, serial, model, wwn, _ = resolve(u)
        for run, s in sorted(d["runs"].items()):
            if (u, run) in rec_by_disk_run or int(s["files"]) == 0:
                continue
            ts = s["cto"] or s["cfrom"] or d["fs_created"]
            date, tm = (ts.split(" ") + [""])[:2]
            mode = "part" if s["manifest"] != "0" else "full"
            if int(s["files"]) == 1 and int(s["bytes"]) < 4096:
                mode = "log-only"                       # PRD/Run_DLY_THR.log 하나뿐 — 자료는 이 하드에 없다
            else:
                c = run_cat(s)
                if c in ("raw", "prd"):
                    mode = f"{mode}·{c.upper()}"
            rng = f"{s['sub_lo']}~{s['sub_hi']}" if s["sub_lo"] and s["sub_hi"] else ""
            left = "" if srcdirs is None else ("0" if run not in srcdirs else "(still on server)")
            note = f"from disk scan {d['scanned_at'][:10]} (no server record); copied {s['cfrom'][:16]} ~ {s['cto'][:16]}"
            if int(s["files"]) == 1 and int(s["bytes"]) < 4096:
                note += "; ★ log file only — run data not on this disk"
            elif mode == "full" and s["sub_lo"] not in ("", "00000"):
                note += f"; starts at subrun {s['sub_lo']} — earlier subruns elsewhere or never existed"
            status = ("on disk (attached)" if u in mounted else "on disk (not attached)") + " · verified by scan"
            deleted = "" if srcdirs is None else ("Y (not on server)" if run not in srcdirs else "(still on server)")
            row = ["", date, tm, run, mode, s["files"], gb(s["bytes"]), rng, s["first"], s["last"], left, status, "",
                   d["mount"], u, model, serial, f"{int(d['cap']) / 1e12:.2f} TB", f"{d['mount']}/RENE_data_backup/{run}",
                   f"scan {d['scanned_at'][:10]}: {s['files']} files / {gb(s['bytes'])} GB", deleted, "",
                   "pre-code9" if ts < "2026-09-01" else "", "", note]
            row = hand_merge(row, (run, u[:8], date))
            rows.append(((run, ts), pk, row))

    # ③ 어느 갈래로도 못 만든 옛 행은 그대로 옮긴다
    carried = 0
    for r in old_rows:
        key = (r[3].strip(), r[14].strip()[:8], r[1].strip())
        if key in used_keys:
            continue
        pk, serial, model, wwn, al = resolve(r[14].strip()) if r[14].strip() else ("", "", "", "", None)
        row = list(r)
        if serial and not row[16].strip():
            row[16] = serial
        if model and not row[15].strip():
            row[15] = model
        row[24] = (row[24].strip() + " | " if row[24].strip() else "") + "carried from previous sheet"
        rows.append(((row[3].strip(), f"{row[1].strip()} {row[2].strip()}"), pk or row[14].strip(), row))
        carried += 1

    # ---- 라벨 : 물리키마다 처음 담은 시각 -> 라벨. 이미 준 라벨은 지킨다 ----
    first_ts, disk_info = {}, {}
    for (run, ts), pk, row in rows:
        if not pk:
            continue
        first_ts[pk] = min(first_ts.get(pk, ts), ts)
        di = disk_info.setdefault(pk, {"uuids": set(), "serial": "", "model": "", "wwn": "", "cap": "", "runs": set(),
                                       "files": 0, "bytes": 0.0, "last_ts": "", "scanned": "", "status": ""})
        di["uuids"].add(row[14]); di["last_ts"] = max(di["last_ts"], ts)
        if str(row[11]).startswith("WIPED"):
            continue                                        # 소실된 기록은 하드 합계에 넣지 않는다 (라벨·처음 시각에는 쓴다)
        if row[4] != "log-only":
            di["runs"].add(row[3])
        else:
            di.setdefault("logonly", set()).add(row[3])
        di["serial"] = di["serial"] or row[16]; di["model"] = di["model"] or row[15]; di["cap"] = di["cap"] or row[17]
        try:
            di["files"] += int(row[5] or 0)
        except ValueError:
            pass
        try:
            di["bytes"] += float(row[6] or 0)
        except ValueError:
            pass
    for u, d in inv.items():
        pk = resolve(u)[0]
        if pk in disk_info:
            disk_info[pk]["scanned"] = d["scanned_at"]; disk_info[pk]["wwn"] = d["wwn"]
            disk_info[pk]["used"] = d["used"]; disk_info[pk]["fs_created"] = d["fs_created"]
    #  라벨 : RENE-<종류>-NNN. 종류별 번호는 처음 담은 순서. 이미 준 라벨(정본)은 그대로, 새 하드는 그 종류의 다음 번호.
    taken = set(labels.values())
    pk_types = {}
    for (run, ts), pk, row in rows:
        if pk:
            pk_types.setdefault(pk, []).append(row[4])
    for pk in sorted(first_ts, key=lambda k: first_ts[k]):
        if pk in labels:
            continue
        cat = disk_cat(pk_types.get(pk, []))
        used = [int(m.group(1)) for l in taken for m in [re.match(rf"RENE-{cat}-(\d+)$", l)] if m]
        lab = f"RENE-{cat}-{(max(used) + 1 if used else 1):03d}"
        labels[pk] = lab; taken.add(lab)
    for (run, ts), pk, row in rows:
        if pk and not row[12].strip():
            row[12] = labels.get(pk, "")

    rows.sort(key=lambda x: x[0])
    out = []
    for i, (_, pk, row) in enumerate(rows, 1):
        row[0] = str(i)
        out.append([str(c) for c in row[:len(HEADER)]])

    # ---- 하드 표 (라벨 정본) ----
    disk_lines = ["# 외장하드 목록 — 라벨 정본. rebuild_backup_sheet.py 가 갱신한다. 라벨 열은 한 번 정해지면 바뀌지 않는다.",
                  "# key(serial|uuid)\tlabel\tserial\tmodel\twwn\tuuids\tcapacity\tfirst_ts\tlast_ts\truns\tfiles\tGB\tscanned_at\tnote"]
    md = ["# 외장하드 백업 — 하드 목록과 라벨\n", "`tools/sheetlog/rebuild_backup_sheet.py` 가 만든다. 손으로 고치지 말 것 (정본은 `docs/backup-disks/disks.tsv`).\n",
          "라벨은 **하드에 스티커로 붙이는 이름**이다 : `RENE-<종류>-NNN` (RAW = 원시 자료만 · PRD = PRD·PNG 만 · ALL = 둘 다, 나누기 전). 번호는 종류별로 처음 담은 순서. 시리얼은 하드에 새겨진 제조사 값(`udevadm`).\n",
          "| 라벨 | 시리얼 | 모델 | UUID | 처음~마지막 | 런 수 | 파일 | GB | 스캔 | 비고 |", "|---|---|---|---|---|---|---|---|---|---|"]
    for pk in sorted(disk_info, key=lambda k: first_ts.get(k, "")):
        di = disk_info[pk]; lab = labels.get(pk, "")
        note = "" if di["serial"] else "★ 시리얼 미확인 — 꽂아서 스캔할 것"
        if di.get("logonly"):
            note = (note + "; " if note else "") + f"log-only dirs {len(di['logonly'])} (data not on this disk)"
        al_notes = [f"{o[:8]} wiped {v['at']}" for o, v in aliases.items() if v["new"] in di["uuids"]]
        if al_notes:
            note = (note + "; " if note else "") + "; ".join(al_notes)
        uu = ",".join(sorted(di["uuids"]))
        disk_lines.append("\t".join([pk, lab, di["serial"], di["model"], di["wwn"], uu, di["cap"], first_ts.get(pk, ""),
                                     di["last_ts"], str(len(di["runs"])), str(di["files"]), f"{di['bytes']:.1f}", di["scanned"], note]))
        md.append(f"| **{lab}** | {di['serial'] or '?'} | {di['model'] or '?'} | {' '.join(u[:8] for u in sorted(di['uuids']))} | "
                  f"{first_ts.get(pk, '')[:10]} ~ {di['last_ts'][:10]} | {len(di['runs'])} | {di['files']} | {di['bytes']:.0f} | "
                  f"{di['scanned'][:10] or '-'} | {note} |")
    md.append(f"\n생성 {datetime.datetime.now():%Y-%m-%d %H:%M} · 행 {len(out)} · 하드 {len(disk_info)}")

    print(f"[INFO] 기록 {len(recs)} 건 · 스캔 하드 {len(inv)} · 기존 시트 {len(old_rows)} 행 (옮긴 것 {carried}) -> 새 표 {len(out)} 행 · 하드 {len(disk_info)}")
    for pk in sorted(disk_info, key=lambda k: first_ts.get(k, "")):
        di = disk_info[pk]
        print(f"   {labels.get(pk, ''):22s} {di['serial'] or '?':10s} {first_ts.get(pk, '')[:10]} runs {len(di['runs']):4d} {di['bytes']:8.0f} GB {'scanned' if di['scanned'] else ''}")
    if a.out_tsv:
        with open(a.out_tsv, "w") as f:
            f.write("\t".join(HEADER) + "\n")
            for r in out:
                f.write("\t".join(r) + "\n")
        print(f"[INFO] 미리보기 -> {a.out_tsv}")
    if not a.commit:
        print("[INFO] 미리보기만. 시트는 그대로 (--commit 라야 쓴다)")
        return 0

    # ---- 쓰기 ----
    os.makedirs(a.backup_dir, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    bak = os.path.join(a.backup_dir, f"sheet-before-rebuild-{stamp}.tsv")
    with open(bak, "w") as f:
        for r in grid:
            f.write("\t".join(r) + "\n")
    if a.sheet_tsv:
        with open(a.sheet_tsv, "w") as f:
            f.write("\t".join(HEADER) + "\n")
            for r in out:
                f.write("\t".join(r) + "\n")
        back = [ln.split("\t") for ln in read_lines(a.sheet_tsv) if ln.strip()][1:]
    else:
        ws.clear()
        ws.update(range_name="A1", values=[HEADER] + out, value_input_option="RAW")
        back = [r for r in ws.get_all_values()[1:] if any(c.strip() for c in r)]
    if len(back) != len(out) or any([c for c in b[:len(HEADER)]] + [""] * (len(HEADER) - len(b)) != o for b, o in zip(back, out)):
        sys.exit(f"[FATAL] 되읽은 표가 쓴 것과 다르다 (백업 {bak})")
    for p, lines in ((a.disks_tsv, disk_lines), (a.disks_md, md)):
        os.makedirs(os.path.dirname(os.path.abspath(p)), exist_ok=True)
        with open(p, "w") as f:
            f.write("\n".join(lines) + "\n")
    print(f"[SHEET] {len(out)} 행으로 다시 씀 + 되대조 통과 (백업 {bak}) · 라벨 정본 {a.disks_tsv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
