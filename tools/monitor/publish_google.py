#!/usr/bin/env python3
"""런 서머리를 구글 시트/드라이브로 발행한다.
   시트 : 새 런 행만 append (기존 행 불변 -- 쓰기 전 백업, 쓴 뒤 되대조)
   드라이브 : map_file 의 이름->fileId 로 PNG 내용을 같은 ID 에 교체
   --init : PNG 를 새 파일로 올리고 map_file 과 퍼가기 URL 을 찍는다
   새 pip 의존 없음 : gspread + google-auth + urllib 뿐이다."""
import argparse, glob, json, os, sys, time, urllib.request

SCOPES = ["https://www.googleapis.com/auth/spreadsheets",
          "https://www.googleapis.com/auth/drive"]

def find_creds():            # append_runs.py 의 순서 그대로
    env = os.environ.get("RENE_SHEETS_SA")
    if env and os.path.isfile(env): return env
    here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    for d in (os.path.join(here, ".config", "rene"), os.path.expanduser("~/.config/rene")):
        hit = sorted(glob.glob(os.path.join(d, "*.json")))
        if hit: return hit[0]
    return None

def read_params(path):
    p = {}
    for ln in open(path, encoding="utf-8"):
        ln = ln.split("#", 1)[0].strip()
        if "=" in ln:
            k, v = ln.split("=", 1); p[k.strip()] = v.strip()
    return p

def read_tsv(path):
    rows = []
    if not os.path.isfile(path): return rows
    for ln in open(path, encoding="utf-8"):
        if ln.startswith("#") or not ln.strip(): continue
        rows.append(ln.rstrip("\n").split("\t"))
    return rows

def build_rows(p):
    """TSV 셋을 합쳐 시트 열(= HTML 표와 같은 15열) 리스트를 만든다.
       gen-summary-html.sh 와 같은 조인 규칙. run 오름차순 (시트는 아래로
       자라는 것이 자연스럽다 -- HTML 만 최신을 위로 뒤집는다)."""
    d = p["tsv_dir"]; src = p.get("metrics_source", "legacy")
    start = int(p.get("start_run", "0"))
    rs = {int(r[0]): r for r in read_tsv(os.path.join(d, "run_summary.tsv"))}
    pair_f = "metrics_summary.tsv" if src == "dst" else "pair_summary.tsv"
    ibd = {}   # (run, tag) -> row
    for r in read_tsv(os.path.join(d, pair_f)):
        ibd[(int(r[0]), r[1])] = r
    out = []
    for run in sorted(rs):
        if run < start: continue
        r = rs[run]
        es, live, wall = float(r[3]), float(r[7]), float(r[5])
        t1, t2, t3 = int(r[9]), int(r[10]), int(r[11])
        gd = ibd.get((run, "_nGd")); nh = ibd.get((run, "_nH"))
        def col(row, i): return row[i] if row else "-"
        rll = col(gd, 9 if src == "dst" else 16)
        srcflag = col(gd, 2)
        if src == "dst" and gd and len(gd) > 18 and gd[15] == "ok":
            lihe = f"{float(gd[13]):.1f}(예비)"; fn = f"{float(gd[17]):.1f}(예비)"
        else:
            lihe = fn = "—"
        out.append([run, time.strftime("%Y-%m-%d %H:%M", time.gmtime(es)),
                    f"{live/3600:.1f}/{wall/3600:.1f}", t1 + t2 + t3, t1, t2, t3,
                    col(gd, 6), col(gd, 7), col(nh, 6), col(nh, 7),
                    rll, fn, lihe, srcflag])
    return out

def drive_update(token, file_id, path, dry):
    if dry:
        print(f"  (dry) drive update {os.path.basename(path)} -> {file_id}"); return True
    req = urllib.request.Request(
        f"https://www.googleapis.com/upload/drive/v3/files/{file_id}?uploadType=media",
        data=open(path, "rb").read(), method="PATCH",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "image/png"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status == 200

def drive_create(token, folder_id, name, path):
    """--init 전용 : multipart 업로드로 새 파일. fileId 를 돌려준다."""
    meta = json.dumps({"name": name, "parents": [folder_id]}).encode()
    png = open(path, "rb").read()
    B = b"rene_boundary_7f3a"
    body = (b"--" + B + b"\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n"
            + meta + b"\r\n--" + B + b"\r\nContent-Type: image/png\r\n\r\n"
            + png + b"\r\n--" + B + b"--")
    req = urllib.request.Request(
        "https://www.googleapis.com/upload/drive/v3/files"
        "?uploadType=multipart&fields=id",
        data=body, method="POST",
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": f"multipart/related; boundary={B.decode()}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)["id"]

HEADER = ["Run", "Start", "live/wall [h]", "Total", "Target only", "VETO only",
          "V+T", "IBD nGd", "acci nGd", "IBD nH", "acci nH", "R_LL [Hz]",
          "fast-n", "Li/He", "Source"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--params", required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--init", action="store_true")
    a = ap.parse_args()
    p = read_params(a.params)
    for k in ("sheet_id", "tsv_dir", "webroot"):
        if not p.get(k) and not (a.init and k == "sheet_id"):
            sys.exit(f"[FATAL] {a.params} 에 {k} 가 비어 있다")
    if a.init:
        #  --init 은 sheet_id 없이도 돌지만(위 예외) drive_folder_id/map_file
        #  없이는 못 돈다 -- 업로드 갈 곳과 기록할 곳이라서다. 여기서
        #  걸러야 dry-run 미리보기도 실제 실행과 같은 곳에서 막힌다.
        for k in ("drive_folder_id", "map_file"):
            if not p.get(k):
                sys.exit(f"[FATAL] {a.params} 에 {k} 가 비어 있다")
    rows = build_rows(p)
    print(f"[INFO] 표 행 : {len(rows)} (출처 {p.get('metrics_source','legacy')})")
    if a.dry_run and a.init:
        #  --init 의 dry-run -- 자격증명을 찾지도, 네트워크를 건드리지도
        #  않는다(find_creds 도 urllib/gspread import 도 이 아래에 없다).
        #  실제로 무엇이 올라갈지만 보여준다 : 파일명+크기, 갈 폴더,
        #  쓰일 map_file. (컨트롤러 판정 R6 -- dry-run 은 어떤 플래그
        #  조합에서도 네트워크/자격증명을 절대 건드리지 않는다.)
        pngs = sorted(glob.glob(os.path.join(p["webroot"], "*.png")))
        for f in pngs:
            print(f"  (dry) drive create {os.path.basename(f)} "
                  f"({os.path.getsize(f)} bytes) -> folder {p['drive_folder_id']}")
        print(f"[DRY] {p['map_file']} 에 {len(pngs)}줄을 쓸 예정 (폴더 {p['drive_folder_id']})")
        return
    if a.dry_run and not a.init:
        for r in rows[-3:]: print("  (dry) sheet row:", r)
        pngs = sorted(glob.glob(os.path.join(p["webroot"], "*.png")))
        fmap = read_map(p.get("map_file", ""))
        for n, fid in fmap.items():
            print(f"  (dry) drive update {n}.png -> {fid}")
        print(f"[DRY] 시트 {len(rows)} 행 후보, 그림 {len(fmap)}/{len(pngs)} 개 교체 예정")
        return
    creds = find_creds()
    if not creds: sys.exit("[FATAL] 서비스 계정 json 을 찾지 못했다")
    from google.oauth2.service_account import Credentials
    import google.auth.transport.requests, gspread
    cr = Credentials.from_service_account_file(creds, scopes=SCOPES)
    cr.refresh(google.auth.transport.requests.Request())
    if a.init:
        fmap = {}
        for f in sorted(glob.glob(os.path.join(p["webroot"], "*.png"))):
            n = os.path.splitext(os.path.basename(f))[0]
            fid = drive_create(cr.token, p["drive_folder_id"], n + ".png", f)
            fmap[n] = fid
            print(f"[INIT] {n}.png -> fileId {fid}")
            print(f"       퍼가기 URL : https://drive.google.com/thumbnail?id={fid}&sz=w1600")
        with open(p["map_file"], "w", encoding="utf-8") as fh:
            for n, fid in fmap.items(): fh.write(f"{n}\t{fid}\n")
        print(f"[INIT] {p['map_file']} 에 {len(fmap)}줄을 썼다")
        return
    ws = gspread.authorize(cr).open_by_key(p["sheet_id"]) \
               .get_worksheet_by_id(int(p.get("sheet_gid", "0")))
    grid = ws.get_all_values()
    bdir = "/Data_ssd/LOG/websummary"; os.makedirs(bdir, exist_ok=True)
    bak = os.path.join(bdir, time.strftime("sheet-backup-%Y%m%d%H%M%S.tsv"))
    with open(bak, "w", encoding="utf-8") as fh:
        for r in grid: fh.write("\t".join(r) + "\n")
    if not grid:
        ws.append_row(HEADER, value_input_option="RAW"); grid = [HEADER]
    have = {r[0] for r in grid[1:] if r and r[0].isdigit()}
    new = [[str(c) for c in r] for r in rows if str(r[0]) not in have]
    if new:
        ws.append_rows(new, value_input_option="RAW")
        back = ws.get_all_values()[-len(new):]
        if [r[:len(HEADER)] for r in back] != new:
            sys.exit("[FATAL] 되대조 실패 -- 시트에 쓴 것과 읽은 것이 다르다")
        print(f"[SHEET] {len(new)} 행 추가 + 되대조 통과 (백업 {bak})")
    else:
        print("[SHEET] 새 행 없음")
    fmap = read_map(p.get("map_file", ""))
    nup = 0
    for n, fid in fmap.items():
        f = os.path.join(p["webroot"], n + ".png")
        if os.path.isfile(f) and drive_update(cr.token, fid, f, False): nup += 1
    print(f"[DRIVE] {nup}/{len(fmap)} 개 교체")

def read_map(path):
    m = {}
    if path and os.path.isfile(path):
        for ln in open(path, encoding="utf-8"):
            if "\t" in ln:
                n, fid = ln.rstrip("\n").split("\t", 1); m[n] = fid
    return m

if __name__ == "__main__":
    main()
