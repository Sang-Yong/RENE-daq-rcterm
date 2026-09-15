#!/usr/bin/env python3
"""한빛 원전 호기별 출력을 KHNP 열린원전운영정보에서 읽어 시간마다 기록한다 (2026-09-15, 사용자 지시).

    reactor_power_log.py --commit             KHNP 를 읽어 로컬 TSV + 구글 시트(KHNP_daily_power 탭)에 한 줄 붙인다
    reactor_power_log.py                      (기본) 미리보기 -- 읽기만 하고 아무것도 쓰지 않는다
    reactor_power_log.py --status             로컬 TSV 의 마지막 줄들과 시트 상태
    reactor_power_log.py --daily              지난 날짜의 일일 평균 행을 (아직 없으면) 만든다. --commit 와 함께
    시험용 : --fixture <json>(KHNP 대신) · --sheet-tsv <파일>(구글 대신) · --log-dir <폴더> · --now 'YYYY-MM-DD HH:MM'

무엇을 기록하나 (26 열, 시트 탭이 26 열이라 딱 맞춘다)
    datetime · type(hour|day) · 호기마다 status / reactor_pct / gen_MW (6 × 3) · total_th_MW(원자로 출력 % × 정격 열출력)
    · total_th_from_gen_MW(발전기 MW ÷ 정격 발전 효율, 대조용) · flux[ν/cm²/s] · exp_ibd_per_day(효율 0.29)
    · exp_ibd_window_per_day(prompt 3~7 MeV 창, ×0.576) · source
    ★ 필요한 것은 발전기 출력이 아니라 핵분열 열출력이다 -- 사이트의 '원자로 출력 %' 가 곧 열출력 비율이라 그것을 정본으로 쓰고,
      발전기 MW 는 정격 발전 효율(3~6 호기 1,040 MWe/2,815 MWth)로 나눠 대조 열로만 둔다.
    일일 행(type=day) : 날짜가 바뀐 뒤 첫 성공 때 지난 날짜의 시간별 행을 평균해 한 줄 (출력 % · MW 는 산술평균, status 는 '운전 N/M h').

종료 코드 : 0 정상 · 2 KHNP 읽기 실패(아무것도 안 씀) · 3 로컬 TSV 는 썼으나 시트 실패 · 4 로컬 TSV 실패
정본은 로컬 TSV (/Data_ssd/LOG/reactor-power/reactor_power.tsv) 다. 시트는 그 사본이며, 실패한 시간은 다음 성공 때 --sheet-catchup 로 메운다.
"""
import argparse, csv, datetime as dt, glob, io, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import expected_ibd as ei   # noqa: E402

SHEET_ID = "1-8wPIg-Q-DpgsyBeSiwHezxM6QlcqhZ3qspAFGusqD0"
GID = 748730312
RATED_TH_MW = [p * 1000 for p in ei.P_GW]
WIN_EFF = 0.576           # prompt 3~7 MeV 창의 원자로 템플릿 효율 (BuildDaily 그림 60/61 과 같은 값)
DEFAULT_LOG_DIR = "/Data_ssd/LOG/reactor-power"

HEADER = ["datetime", "type"] + [f"u{i}_{k}" for i in range(1, 7) for k in ("status", "reactor_pct", "gen_MW")] + \
         ["total_th_MW", "total_th_from_gen_MW", "flux_nu_cm2_s", "exp_ibd_per_day", "exp_ibd_window_per_day", "source"]
assert len(HEADER) == 26


def find_creds():
    env = os.environ.get("RENE_SHEETS_SA")
    if env and os.path.isfile(env): return env
    repo = os.path.dirname(os.path.dirname(HERE))
    for d in (os.path.join(repo, ".config", "rene"), os.path.expanduser("~/.config/rene")):
        hit = sorted(glob.glob(os.path.join(d, "*.json")))
        if hit: return hit[0]
    return None


def fmt(x, nd=1):
    return "" if x is None else (f"{x:.{nd}f}" if isinstance(x, float) else str(x))


def build_row(units, now, source):
    """호기 dict 여섯 개 → 26 열 행 + 계산값."""
    pct = [u["pct"] for u in units]
    th = sum((p or 0.0) / 100.0 * RATED_TH_MW[i] for i, p in enumerate(pct))
    th_gen = sum((u["mwe"] or 0.0) / (ei.RATED_GROSS_MWE[i] / RATED_TH_MW[i]) for i, u in enumerate(units))
    ex = ei.expected(pct)
    row = [now.strftime("%Y-%m-%d %H:%M"), "hour"]
    for u in units: row += [u["status"] or "", fmt(u["pct"]), fmt(u["mwe"], 0)]
    row += [fmt(th, 0), fmt(th_gen, 0), f"{ex['flux']:.3e}", f"{ex['ibd']:.3f}", f"{ex['ibd'] * WIN_EFF:.3f}", source]
    return row


def read_tsv(path):
    if not os.path.isfile(path): return []
    with open(path, encoding="utf-8") as f:
        rows = [r for r in csv.reader(f, delimiter="\t") if r and not r[0].startswith("#")]
    return [r for r in rows if r[0] != "datetime"]


def append_tsv(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    new = not os.path.isfile(path) or os.path.getsize(path) == 0
    with open(path, "a", encoding="utf-8", newline="") as f:
        w = csv.writer(f, delimiter="\t", lineterminator="\n")
        if new: w.writerow(HEADER)
        for r in rows: w.writerow(r)


def daily_row(hour_rows, day):
    """day('YYYY-MM-DD') 의 시간별 행을 평균한 일일 행. 표본이 없으면 None."""
    rs = [r for r in hour_rows if r[1] == "hour" and r[0].startswith(day)]
    if not rs: return None
    def mean(col):
        v = [float(r[col]) for r in rs if r[col] not in ("", None)]
        return sum(v) / len(v) if v else None
    row = [day + " 00:00", "day"]
    for i in range(6):
        c = 2 + 3 * i
        on = sum(1 for r in rs if r[c] == "운전")
        row += [f"운전 {on}/{len(rs)}h", fmt(mean(c + 1)), fmt(mean(c + 2), 0)]
    row += [fmt(mean(20), 0), fmt(mean(21), 0), f"{mean(22):.3e}" if mean(22) is not None else "",
            fmt(mean(23), 3), fmt(mean(24), 3), f"mean of {len(rs)} hourly rows"]
    return row


class SheetTsv:
    """시험용 시트 : TSV 파일 하나. 구글과 같은 append/last-row 인터페이스."""
    def __init__(self, path): self.path = path
    def all_rows(self): return read_tsv(self.path) if os.path.isfile(self.path) else []
    def has_header(self):
        if not os.path.isfile(self.path): return False
        with open(self.path, encoding="utf-8") as f: return f.readline().rstrip("\n").split("\t")[:2] == HEADER[:2]
    def append(self, rows, header):
        with open(self.path, "a", encoding="utf-8", newline="") as f:
            w = csv.writer(f, delimiter="\t", lineterminator="\n")
            if header: w.writerow(HEADER)
            for r in rows: w.writerow(r)


class SheetGoogle:
    def __init__(self, creds):
        import gspread
        from google.oauth2.service_account import Credentials
        cr = Credentials.from_service_account_file(creds, scopes=["https://www.googleapis.com/auth/spreadsheets"])
        self.ws = gspread.authorize(cr).open_by_key(SHEET_ID).get_worksheet_by_id(GID)
    def all_rows(self):
        vals = [r for r in self.ws.get_all_values() if any(c.strip() for c in r)]
        return [r for r in vals if r and r[0] != "datetime"]
    def has_header(self):
        vals = self.ws.get_all_values()
        return bool(vals) and vals[0][:2] == HEADER[:2]
    def append(self, rows, header):
        if header: self.ws.append_row(HEADER, value_input_option="RAW")
        self.ws.append_rows(rows, value_input_option="RAW")


def sheet_sync(sheet, tsv_rows, log):
    """시트에 없는 로컬 행(마지막 시트 행 이후의 datetime)을 붙이고, 붙인 뒤 마지막 행을 되읽어 대조한다."""
    have = sheet.all_rows()
    keys = {(h[0], h[1]) for h in have if len(h) >= 2}
    missing = [r for r in tsv_rows if (r[0], r[1]) not in keys]       # 일일 행은 datetime 이 앞 날짜라 (datetime, type) 짝으로 가른다
    if not missing: log("시트 : 붙일 것 없음"); return 0
    for attempt in range(3):
        try:
            sheet.append(missing, header=not sheet.has_header())
            back = sheet.all_rows()
            if back and back[-1][:2] == missing[-1][:2]:
                log(f"시트 : {len(missing)} 행 붙임, 되읽기 일치 ({missing[-1][0]} {missing[-1][1]})"); return len(missing)
            log(f"[WARN] 시트 되읽기 불일치 : {back[-1][:2] if back else None} != {missing[-1][:2]}")
            return -1
        except Exception as e:
            log(f"[WARN] 시트 쓰기 실패 ({attempt + 1}/3) : {e}"); time.sleep(5)
    return -1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit", action="store_true"); ap.add_argument("--status", action="store_true")
    ap.add_argument("--daily", action="store_true", help="지난 날짜의 일일 행을 만든다 (없을 때만)")
    ap.add_argument("--fixture"); ap.add_argument("--sheet-tsv"); ap.add_argument("--log-dir", default=os.environ.get("REACTOR_LOG_DIR", DEFAULT_LOG_DIR))
    ap.add_argument("--now", help="시험용 시각 'YYYY-MM-DD HH:MM' 또는 YYYY-MM-DDTHH:MM"); ap.add_argument("--no-sheet", action="store_true")
    a = ap.parse_args()
    tsv = os.path.join(a.log_dir, "reactor_power.tsv")
    now = dt.datetime.strptime(a.now.replace("T", " "), "%Y-%m-%d %H:%M") if a.now else dt.datetime.now()   # 'T' 도 받는다 (셸 인자에 공백을 못 넣을 때)
    def log(m): print(f"[{dt.datetime.now().strftime('%F %T')}] {m}", flush=True)

    if a.status:
        rows = read_tsv(tsv)
        print(f"로컬 TSV : {tsv}  ({len(rows)} 행)")
        for r in rows[-5:]: print("  ", r[0], r[1], "th_MW", r[20], "exp_ibd", r[23], "|", " ".join(f"U{i+1}:{r[2+3*i]}/{r[3+3*i]}%" for i in range(6)))
        return 0

    # ---- 읽기 ----
    try:
        raw = ei.khnp_fetch_raw(fixture=a.fixture)
        units = ei.khnp_parse(raw)
    except Exception as e:
        log(f"[FAIL] KHNP 읽기 실패 : {e}"); return 2
    if all(u["pct"] is None and u["status"] is None for u in units):
        log("[FAIL] KHNP 응답에 값이 없다"); return 2
    row = build_row(units, now, "fixture" if a.fixture else "khnp")
    log("호기 : " + "  ".join(f"U{u['unit']} {u['status']} {fmt(u['pct'])}% {fmt(u['mwe'], 0)}MW" for u in units))
    log(f"열출력 {row[20]} MW (발전기 환산 {row[21]})  flux {row[22]}  기대 IBD {row[23]} /day (창 {row[24]})")
    if not a.commit:
        log("(미리보기 : --commit 이 없어 쓰지 않는다)"); return 0

    # ---- 로컬 TSV ----
    prev = read_tsv(tsv)
    new_rows = [row]
    if a.daily or True:
        yday = (now - dt.timedelta(days=1)).strftime("%Y-%m-%d")
        if not any(r[1] == "day" and r[0].startswith(yday) for r in prev):
            d = daily_row(prev + [row], yday)
            if d: new_rows.append(d); log(f"일일 행 : {yday} ({d[-1]})")
    try:
        append_tsv(tsv, new_rows)
    except Exception as e:
        log(f"[FAIL] 로컬 TSV 쓰기 실패 : {e}"); return 4
    log(f"로컬 TSV : {len(new_rows)} 행 ({tsv})")
    if a.no_sheet: return 0

    # ---- 시트 ----
    try:
        if a.sheet_tsv: sheet = SheetTsv(a.sheet_tsv)
        else:
            creds = find_creds()
            if not creds: log("[FAIL] 서비스 계정 json 없음"); return 3
            sheet = SheetGoogle(creds)
        n = sheet_sync(sheet, read_tsv(tsv), log)
    except Exception as e:
        log(f"[FAIL] 시트 : {e}"); return 3
    return 0 if n >= 0 else 3


if __name__ == "__main__":
    sys.exit(main())
