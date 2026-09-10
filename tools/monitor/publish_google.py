#!/usr/bin/env python3
"""런 서머리를 구글 시트/드라이브로 발행한다.
   시트 : 새 런 행만 append (기존 행 불변 -- 쓰기 전 백업, 쓴 뒤 되대조)
   드라이브 : map_file 의 이름->fileId 로 PNG 내용을 같은 ID 에 교체
   --init : PNG 를 새 파일로 올리고 map_file 과 퍼가기 URL 을 찍는다
   새 pip 의존 없음 : gspread + google-auth + urllib 뿐이다."""
import argparse, glob, json, os, sys, time, urllib.parse, urllib.request

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
    #  ★ map_file 이 상대 경로면 저장소 루트(params 파일이 있는 config/ 의 부모) 기준으로 푼다.
    #    cron 은 홈에서 부르므로 'config/websummary.map' 을 못 찾아 그림을 0/0 으로 교체했다
    #    (2026-09-10 17:07 첫 자동 회차에서 실측). 손으로 돌릴 때는 저장소 안이라 드러나지 않았다.
    mf = p.get("map_file", "")
    if mf and not os.path.isabs(mf):
        root = os.path.dirname(os.path.dirname(os.path.abspath(path)))
        p["map_file"] = os.path.join(root, mf)
    return p

def read_tsv(path):
    rows = []
    if not os.path.isfile(path): return rows
    for ln in open(path, encoding="utf-8"):
        if ln.startswith("#") or not ln.strip(): continue
        rows.append(ln.rstrip("\n").split("\t"))
    return rows

def build_rows(p):
    """TSV 셋을 합쳐 시트 열(= HTML 표와 같은 20열, Run 다음이 Type) 리스트를
       만든다. gen-summary-html.sh 와 같은 조인 규칙. run 오름차순 (시트는
       아래로 자라는 것이 자연스럽다 -- HTML 만 최신을 위로 뒤집는다).
       type 은 gen-runclass.sh 가 낸 runclass.tsv 를 run 을 키로만 읽는다
       (컨트롤러 판정 R9 -- 분류 규칙은 그 스크립트 하나뿐이다). 파일이
       없거나 그 안에 이 run 이 없으면 '-'."""
    d = p["tsv_dir"]; src = p.get("metrics_source", "legacy")
    start = int(p.get("start_run", "0"))
    rs = {int(r[0]): r for r in read_tsv(os.path.join(d, "run_summary.tsv"))}
    pair_f = "metrics_summary.tsv" if src == "dst" else "pair_summary.tsv"
    ibd = {}   # (run, tag) -> row
    for r in read_tsv(os.path.join(d, pair_f)):
        ibd[(int(r[0]), r[1])] = r
    runclass = {int(r[0]): r[1] for r in read_tsv(os.path.join(d, "runclass.tsv"))}
    #  veto_summary.tsv (veto-summary.sh) : 패널 AND 비율 1 % 이상인 패널 수 -- HTML 의 Panels 열과 같은 규칙
    panels = {}
    for r in read_tsv(os.path.join(d, "veto_summary.tsv")):
        try:
            alive = [q for q in range(15) if float(r[11 + q]) >= 1.0]
            panels[int(r[0])] = f"{len(alive)}/15"
        except (ValueError, IndexError):
            pass
    out = []
    pf = pv = None            # 앞 런의 FADC/VETO 계수율 (Δ 열. HTML 과 같은 규칙 : 바로 앞 런)
    for run in sorted(rs):
        if run < start: continue
        r = rs[run]
        es, live, wall = float(r[3]), float(r[7]), float(r[5])
        t1, t2, t3 = int(r[9]), int(r[10]), int(r[11])
        gd = ibd.get((run, "_nGd")); nh = ibd.get((run, "_nH"))
        def col(row, i): return row[i] if row else "-"
        rll = col(gd, 9 if src == "dst" else 16)
        srcflag = col(gd, 2)
        #  fast-n 과 Li/He 는 서로 다른 조건으로 독립적으로 gate 한다
        #  (발견 2 -- gen-summary-html.sh 의 awk 와 정확히 같은 두 문 :
        #  Li/He 는 lihe_stat=="ok" 만 보고, fast-n 은 n_fn_side_scaled>=0
        #  만 본다. 한쪽이 실패해도 다른 쪽 표시를 막지 않는다).
        lihe = fn = "—"
        if src == "dst" and gd and len(gd) > 18:
            if gd[15] == "ok":
                lihe = f"{float(gd[13]):.1f}(예비)"
            if float(gd[17]) >= 0:
                fn = f"{float(gd[17]):.1f}(예비)"
        #  gen-summary-html.sh 의 awk strftime() 은 utc 인자를 안 주면 로컬
        #  시간이다 -- 여기도 맞춰야 한다(발견 1). gmtime 이면 한국 사이트
        #  기준 약 9시간이 어긋난다.
        #  2026-09-09 넉 열 (HTML 표 20 열과 같은 자리) : FADC Hz · VETO Hz · dF/dV % · Panels
        if live > 0:
            fhz, vhz = (t1 + t3) / live, (t2 + t3) / live
            fs, vs = f"{fhz:.1f}", f"{vhz:.1f}"
            df = f"{100*(fhz-pf)/pf:+.1f}" if pf else "-"
            dv = f"{100*(vhz-pv)/pv:+.1f}" if pv else "-"
            delta = f"{df} / {dv}" if (pf or pv) else "-"
            pf, pv = fhz, vhz
        else:
            fs = vs = delta = "-"
        out.append([run, runclass.get(run, "-"),
                    time.strftime("%Y-%m-%d %H:%M", time.localtime(es)),
                    f"{live/3600:.1f}/{wall/3600:.1f}", t1 + t2 + t3, t1, t2, t3,
                    fs, vs, delta, panels.get(run, "-"),
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

def drive_find(token, folder_id, name):
    """폴더 안에서 이름이 같은 파일의 fileId (없으면 None). --init 이 먼저 이것을 본다 --
       ★ 서비스 계정은 저장 용량이 없어 내 드라이브에 파일을 *만들* 수 없다
       (storageQuotaExceeded, 2026-09-10 실측). 사용자가 올려 둔 파일의 내용을 갈아끼우는
       것(drive_update 의 PATCH)은 된다. 그래서 그림은 사용자가 한 번 올리고, 여기서는 찾기만 한다."""
    q = urllib.parse.quote(f"'{folder_id}' in parents and name = '{name}' and trashed = false")
    req = urllib.request.Request(
        f"https://www.googleapis.com/drive/v3/files?q={q}&fields=files(id,name)&supportsAllDrives=true&includeItemsFromAllDrives=true",
        headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        fs = json.load(r).get("files", [])
    return fs[0]["id"] if fs else None

def drive_create(token, folder_id, name, path):
    """--init 전용 : multipart 업로드로 새 파일. fileId 를 돌려준다.
       ★ 내 드라이브 폴더에서는 storageQuotaExceeded 로 실패한다(위 drive_find 참조).
       공유 드라이브(Workspace)일 때만 된다."""
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

HEADER = ["Run", "Type", "Start", "live/wall [h]", "Total", "Target only",
          "VETO only", "V+T", "FADC [Hz]", "VETO [Hz]", "dF/dV [%]", "Panels",
          "IBD nGd", "acci nGd", "IBD nH", "acci nH",
          "R_LL [Hz]", "fast-n", "Li/He", "Source"]

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
        fmap = {}; missing = []
        for f in sorted(glob.glob(os.path.join(p["webroot"], "*.png"))):
            n = os.path.splitext(os.path.basename(f))[0]
            fid = drive_find(cr.token, p["drive_folder_id"], n + ".png")
            how = "found"
            if not fid:
                try:
                    fid = drive_create(cr.token, p["drive_folder_id"], n + ".png", f); how = "created"
                except urllib.error.HTTPError as e:
                    body = e.read().decode(errors="replace")
                    if "storageQuotaExceeded" in body:
                        missing.append(n + ".png"); continue
                    raise
            fmap[n] = fid
            print(f"[INIT] {n}.png -> fileId {fid} ({how})")
            print(f"       퍼가기 URL : https://drive.google.com/thumbnail?id={fid}&sz=w1600")
        if fmap:
            with open(p["map_file"], "w", encoding="utf-8") as fh:
                for n, fid in fmap.items(): fh.write(f"{n}\t{fid}\n")
            print(f"[INIT] {p['map_file']} 에 {len(fmap)}줄을 썼다")
        if missing:
            print(f"[INIT] ★ 서비스 계정은 내 드라이브에 파일을 만들 수 없다 (storageQuotaExceeded)."
                  f" 아래 {len(missing)}개를 사람이 폴더에 올린 뒤 --init 을 다시 돌리면 찾아서 map 에 넣는다 :")
            for n in missing: print(f"       {n}")
            sys.exit(1)
        return
    ws = gspread.authorize(cr).open_by_key(p["sheet_id"]) \
               .get_worksheet_by_id(int(p.get("sheet_gid", "0")))
    grid = ws.get_all_values()
    bdir = "/Data_ssd/LOG/websummary"; os.makedirs(bdir, exist_ok=True)
    bak = os.path.join(bdir, time.strftime("sheet-backup-%Y%m%d%H%M%S.tsv"))
    with open(bak, "w", encoding="utf-8") as fh:
        for r in grid: fh.write("\t".join(r) + "\n")
    #  gspread 는 빈 탭을 [] 로도, [[]] 처럼 빈 행 하나로도 돌려준다(실측 : 새로 만든
    #  DAQ_runsummary 탭이 rows=1, cols=0 이었다). 내용 있는 행이 하나도 없으면 빈 것이다 --
    #  그 판정을 안 하면 헤더 없이 자료 행부터 붙는다.
    if not any(any(c.strip() for c in r) for r in grid):
        ws.append_row(HEADER, value_input_option="RAW"); grid = [HEADER]
    have = {r[0] for r in grid[1:] if r and r[0].isdigit()}
    new = [[str(c) for c in r] for r in rows if str(r[0]) not in have]
    #  append-only 로 남긴다 -- Run 이 시트의 현재 끝보다 낮은 값이라도
    #  삽입하지 않고 그대로 맨 끝에 붙인다(컨트롤러 판정 R7. 옛 런을
    #  나중에 되메울 때 이런 일이 생긴다 -- CLAUDE.md §11.5 의 4208~4211
    #  처럼). 그러면 시트 안 Run 값이 더 이상 오름차순이 아니게 되므로
    #  사람이 알아채도록 여기서 경고만 낸다.
    #  ★ 이 스크립트 자체는 동시에 두 벌이 떠도 서로를 막지 않는다 --
    #  단일 기록자 보장은 여기가 아니라 오케스트레이터(websummary.sh,
    #  Task 9)의 flock 몫이다.
    existing_nums = [int(r[0]) for r in grid[1:] if r and r[0].isdigit()]
    sheet_max_run = max(existing_nums) if existing_nums else None
    if sheet_max_run is not None:
        for r in new:
            rn = int(r[0])
            if rn < sheet_max_run:
                print(f"[WARN] run {rn} 이 시트의 현재 최댓값 {sheet_max_run} 보다 "
                      f"낮다 -- append-only 라 끝에 그대로 붙는다 (삽입하지 않는다)")
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
    failed = []             # (이름, 사유) -- 부분 실패를 조용히 넘기지 않는다
    for n, fid in fmap.items():
        f = os.path.join(p["webroot"], n + ".png")
        if not os.path.isfile(f):
            failed.append((n, "로컬 png 없음"))
            continue
        try:
            if drive_update(cr.token, fid, f, False):
                nup += 1
            else:
                failed.append((n, "드라이브가 200 이 아닌 응답을 줬다"))
        except Exception as e:
            #  파일 하나가 죽어도 나머지는 계속 올린다 -- 여기서 잡는 것은
            #  이 루프 안의 개별 실패뿐이다. 이 루프 밖(시트 backup/append
            #  등)에서 나는 예외는 그대로 전파된다(전면 실패까지 삼키지
            #  않는다).
            failed.append((n, f"{type(e).__name__}: {e}"))
    print(f"[DRIVE] {nup}/{len(fmap)} 개 교체")
    if failed:
        for n, reason in failed:
            print(f"[WARN] drive update 실패 : {n}.png -- {reason}")
        sys.exit(1)   # 오케스트레이터(Task 9)가 다음 주기에 다시 시도하도록

def read_map(path):
    m = {}
    if path and os.path.isfile(path):
        for ln in open(path, encoding="utf-8"):
            if "\t" in ln:
                n, fid = ln.rstrip("\n").split("\t", 1); m[n] = fid
    return m

if __name__ == "__main__":
    main()
