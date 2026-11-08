#!/usr/bin/env python3
"""구글 시트에 쓰는 모든 경로의 '로컬 원장' (2026-11-09 사용자 지시).

    "앞으로 모든 시트 등재할때 로컬을 우선으로 먼저 등재해서 우선적으로 저장하고
     네트워크가 확인될때 로컬의 정보를 우선으로 등재 기록을 동기화해줘"

  등재 = 로컬 원장에 적는 것이다. 그 순간 '등재됨' 이다.  시트는 원장의 사본이고,
  망이 되면 원장의 pending 행을 시트로 밀어 넣는다 (flush).

원장 파일  <dir>/<탭이름>.tsv   (dir = $RENE_SHEET_LEDGER_DIR 또는 /Data_ssd/LOG/sheetledger)
    1 줄   '#ledger tab=… sheet_id=… gid=… key=열|열'
    2 줄   시트 헤더 열 그대로 + 메타 열 _key _added _state _sent _range _note
    그 뒤  행.  값의 탭·줄바꿈·역슬래시는 \\t \\n \\\\ 로 적는다.
    _state  pending  아직 시트에 안 갔다 (또는 고칠 것이 있다)
            sent     시트에 있다 (우리 행)
            foreign  시트에 있는 남의 행 (GoodRuns 의 run <= 4246). 원장은 거울일 뿐 절대 밀지 않는다
            removed  보냈는데 지금 시트에 없다 (사람이 지웠다). 다시 밀지 않는다
            failed   밀 수 없다 (_note 에 사유. 예: foreign -- 같은 키가 남의 행)

규칙
  * append 는 언제나 로컬만 쓴다 (망 무관).  기본 mode 'insert' : 같은 키가 있으면 그대로 둔다
    (§11.5 규칙 3 -- 같은 런을 두 번 싣지 않는다).  'upsert' : 값이 다르면 원장 값을 바꾸고 pending.
  * flush 는 먼저 시트를 읽어 sent/foreign 행을 시트 값으로 갱신한다 (pull -- 사람이 시트에서 고친 값이
    원장에 남는다).  그 다음 pending 행 :
        시트에 같은 키가 없다      -> 끝 행 다음에 붙인다
        같은 키가 우리 행이다      -> 원장 값이 다른 칸만 원장 값으로 고친다 (로컬이 정본).
                                      단 원장 칸이 빈 것·보호 열(사람 열)은 시트 값을 둔다
        같은 키가 남의 행이다      -> 건드리지 않고 failed:foreign
    쓰기 전 시트 전체 백업 TSV, 범위 쓰기 전 sheet_grid.ensure_rows, 쓴 뒤 되읽어 대조 (§11.5 규칙 4).
    되대조가 어긋나면 종료 3, pending 그대로 (다음 flush 가 같은 키를 찾아 sent 로 맞춘다 -- 멱등).
  * 종료 코드 (send_mail.py 와 같은 관례) : 0 정상 · 3 되대조 어긋남 · 4 인증 · 5 망 · 6 그 밖
  * 드릴 플래그(drill.active, netsync-lib.sh 와 같은 판정)가 살아 있으면 flush 는 건너뛴다 (§11.229).

CLI
    sheet_ledger.py --status [--tab X]          읽기 전용. pending / sent / failed 수, 가장 오래된 pending
    sheet_ledger.py --flush  [--tab X] [--dry-run]   망이 되면 pending 을 시트로 (dry-run 은 망·시트·원장 무접촉)
    sheet_ledger.py --drop KEY --tab X [--dry-run]   pending/failed 행 하나를 원장에서 뺀다 (키가 여럿이면 '|')
    sheet_ledger.py --pull   --tab X [--dry-run] [--sheet-id ID --gid N]
                                                시트를 읽어 원장을 채운다/갱신한다 (첫 배포의 씨앗). 시트는 안 쓴다.
                                                원장이 없으면 탭의 기본 sheet_id · gid · 키(TABS)로 연다
시험
    RENE_SHEET_FAKE_DIR=<폴더>  구글 대신 <폴더>/<탭>.tsv 를 시트로 쓴다 (TsvSheet)
    RENE_SHEET_FAKE_NET=down    시트를 열려고 하면 ConnectionError (망 단절 흉내)
"""
import argparse, contextlib, datetime as dt, fcntl, glob, os, re, socket, sys, time, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DEFAULT_DIR = "/Data_ssd/LOG/sheetledger"
DEFAULT_BACKUP = "/Data_ssd/LOG/sheetledger/backup"
META = ["_key", "_added", "_state", "_sent", "_range", "_note"]
RC_OK, RC_VERIFY, RC_AUTH, RC_NET, RC_OTHER = 0, 3, 4, 5, 6


# ---- 탭별 설정 ---------------------------------------------------------
#  header : 'runmax' = 'Run' 과 'Max subrun' 이 같이 있는 줄 (Y2026B 는 헤더 위에 줄이 있다) · 'first' = 첫 줄
#  anchor : 'lastkey' = 마지막 키 행 다음 (그 아래에 무엇이든 있으면 멈춘다 -- append_runs 의 옛 안전장치)
#           'lastrow' = 내용 있는 마지막 행 다음
#  protect : 원장이 시트를 고칠 때도 건드리지 않는 열 (사람이 채우는 열)
def _ours_goodruns(key):
    try:
        run = int(key)
    except ValueError:
        return False
    sys.path.insert(0, HERE)
    import append_runs                       # 소유권 경계의 정본은 append_runs.is_ours (§11.5)
    return append_runs.is_ours(run)


GOODRUNS_SHEET_ID = "1-8wPIg-Q-DpgsyBeSiwHezxM6QlcqhZ3qspAFGusqD0"     # RENE Offline Data GoodRuns 문서 (§11.5)
#  sheet_id · gid · key 는 원장이 아직 없을 때 --pull 씨앗이 쓰는 기본값이다 (쓰는 도구의 상수와 같다 :
#  append_runs.SHEET_ID/GID · append_backup_rows.SHEET_ID/GID · websummary.params 의 sheet_id/sheet_gid, §11.176)
TABS = {
    "Y2026B": dict(sheet_id=GOODRUNS_SHEET_ID, gid=0, key=["Run"], header="runmax", anchor="lastkey", value_input="USER_ENTERED", ours=_ours_goodruns,
                   protect=["Detector", "Source", "PMT-A HV (V)", "PMT-B HV (V)", "THR (mV)", "Coincidence (ns)",
                            "Record length", "Time after HV ON", "TLT"]),
    "back_up_hdd_log": dict(sheet_id=GOODRUNS_SHEET_ID, gid=219954027, key=["Run", "Backup Date", "Backup Time"], header="first", anchor="lastrow", value_input="RAW", ours=None,
                            protect=["Also at KHU", "Storage Location"]),
    "DAQ_runsummary": dict(sheet_id=GOODRUNS_SHEET_ID, gid=511745186, key=["Run"], header="first", anchor="lastrow", value_input="RAW", ours=None, protect=[]),
}
EXTERNAL = {   # 자기 TSV 를 정본으로 쓰는 탭 (원장 형식이 아니다). --flush/--status 가 그 도구에 맡긴다
    "KHNP_daily_power": "reactor",
}


def now_s():
    return dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def ledger_dir(d=None):
    return d or os.environ.get("RENE_SHEET_LEDGER_DIR") or DEFAULT_DIR


def esc(s):
    return str(s).replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "")


def unesc(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append({"t": "\t", "n": "\n", "\\": "\\"}.get(n, n)); i += 2
        else:
            out.append(c); i += 1
    return "".join(out)


def norm_name(s):
    return " ".join((s or "").split()).lower()


def nv(s):
    """값 비교용 : 앞뒤 공백을 떼고, 숫자면 숫자로 (시트는 '75.0' 을 '75' 로 보이기도 한다)."""
    s = ("" if s is None else str(s)).strip()
    #  USER_ENTERED 로 쓴 칸은 시트가 바꿔 보인다 : '2026-11-08' -> '2026. 11. 08', '05:58' -> '5:58' (Y2026B 실물)
    m = re.match(r"^(\d{4})[.-]\s*(\d{1,2})[.-]\s*(\d{1,2})\.?$", s)
    if m:
        return "%s-%02d-%02d" % (m.group(1), int(m.group(2)), int(m.group(3)))
    m = re.match(r"^(\d{1,2}):(\d{2})$", s)
    if m:
        return "%d:%s" % (int(m.group(1)), m.group(2))
    try:
        f = float(s.replace(",", ""))
        return repr(round(f, 9))
    except ValueError:
        return s


# ---- 망 오류의 분류 --------------------------------------------------------
def classify(e):
    """예외 -> 종료코드. 5 망 · 4 인증 · 6 그 밖."""
    name = type(e).__name__
    mod = type(e).__module__ or ""
    if isinstance(e, (socket.gaierror, socket.timeout, ConnectionError, TimeoutError)):
        return RC_NET
    if name in ("RefreshError",):
        return RC_AUTH
    if name in ("TransportError",) and "google.auth" in mod:
        return RC_NET
    if mod.startswith("requests") and name in ("ConnectionError", "Timeout", "ConnectTimeout", "ReadTimeout",
                                               "SSLError", "ChunkedEncodingError"):
        return RC_NET
    if mod.startswith("urllib3") or mod.startswith("http.client"):
        return RC_NET
    if name == "APIError":
        code = getattr(e, "code", None)
        if code is None:
            code = getattr(getattr(e, "response", None), "status_code", None)
        try:
            code = int(code)
        except (TypeError, ValueError):
            code = 0
        if code in (401, 403):
            return RC_AUTH
        if code == 429 or code >= 500:
            return RC_NET
        return RC_OTHER
    if isinstance(e, OSError):
        return RC_NET if getattr(e, "errno", None) in (101, 110, 111, 113, -2, -3) else RC_OTHER
    return RC_OTHER


RC_WORD = {RC_NET: "망 없음", RC_AUTH: "인증 실패", RC_OTHER: "시트 오류", RC_VERIFY: "되대조 어긋남"}


# ---- 드릴 플래그 (netsync-lib.sh 의 drill_active 와 같은 판정) ---------------
def drill_active():
    path = os.environ.get("DRILL_FLAG") or "/Data_ssd/LOG/drill.active"
    try:
        kv = dict(l.rstrip("\n").split("=", 1) for l in open(path, encoding="utf-8") if "=" in l)
    except OSError:
        return False
    pid = kv.get("pid", "")
    if not pid.isdigit() or not os.path.isdir(f"/proc/{pid}"):
        return False
    ps = kv.get("pstart", "")
    try:
        st = open(f"/proc/{pid}/stat").read().rsplit(") ", 1)[1].split()
        cur = st[19]
    except (OSError, IndexError):
        return False
    if ps:
        if cur != ps:
            return False
    else:
        try:
            if b"autonomy-drill" not in open(f"/proc/{pid}/cmdline", "rb").read():
                return False
        except OSError:
            return False
    try:
        age = time.time() - os.stat(path).st_mtime
    except OSError:
        return False
    return age <= int(os.environ.get("DRILL_FLAG_MAX_AGE", "86400"))


# ---- 시트 (구글 · 시험용 TSV) -------------------------------------------------
def find_creds():
    env = os.environ.get("RENE_SHEETS_SA")
    if env and os.path.isfile(env):
        return env
    for d in (os.path.join(REPO, ".config", "rene"), os.path.expanduser("~/.config/rene")):
        hit = sorted(glob.glob(os.path.join(d, "*.json")))
        if hit:
            return hit[0]
    return None


class AuthMissing(Exception):
    pass


class TsvSheet:
    """시험용 시트 : TSV 한 파일 (이스케이프 없이 탭으로 나눈다). gspread Worksheet 가 쓰는 메서드만 흉내 낸다.
    ★ 손대지 않은 줄은 바이트 그대로 둔다 (시험이 '기존 행 그대로' 를 md5 로 본다)."""
    def __init__(self, path, title=""):
        self.path, self.title, self.row_count = path, title, 100000

    def _lines(self):
        if not os.path.isfile(self.path):
            return []
        with open(self.path, encoding="utf-8") as f:
            return [ln.rstrip("\n") for ln in f]

    def get_all_values(self):
        rows = [ln.split("\t") for ln in self._lines()]
        while rows and not any(c.strip() for c in rows[-1]):
            rows.pop()
        w = max((len(r) for r in rows), default=0)
        return [r + [""] * (w - len(r)) for r in rows]

    def update(self, values=None, range_name="A1", value_input_option=None):
        if os.environ.get("RENE_SHEET_FAKE_NET") == "down":
            raise ConnectionError("fake: network down (RENE_SHEET_FAKE_NET=down)")
        r0, c0 = a1_to_rc(range_name.split(":")[0])
        lines = self._lines()
        for i, line in enumerate(values or []):
            r = r0 + i
            while len(lines) <= r:
                lines.append("")
            row = lines[r].split("\t") if lines[r] else []
            for j, v in enumerate(line):
                while len(row) <= c0 + j:
                    row.append("")
                v = "" if v is None else str(v).replace("\t", " ").replace("\n", " ")
                if os.environ.get("RENE_SHEET_FAKE_CORRUPT") and j == 0 and c0 == 0:
                    v += "x"                                   # 되대조 시험 : 쓴 것과 다르게 남긴다
                row[c0 + j] = v
            lines[r] = "\t".join(row)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            for ln in lines:
                f.write(ln + "\n")
        os.replace(tmp, self.path)

    def batch_update(self, data, value_input_option=None):
        for d in data:
            self.update(values=d["values"], range_name=d["range"])

    def add_rows(self, n):
        self.row_count += n


def a1_to_rc(a1):
    col = row = 0
    for ch in a1:
        if ch.isalpha():
            col = col * 26 + (ord(ch.upper()) - 64)
        elif ch.isdigit():
            row = row * 10 + int(ch)
    return row - 1, col - 1


def rc_to_a1(r, c):     # 0-base -> 'A1'
    c += 1; s = ""
    while c:
        c, m = divmod(c - 1, 26); s = chr(65 + m) + s
    return f"{s}{r + 1}"


def open_ws(sheet_id, gid, tab, creds=None):
    """시트 탭을 연다. 실패하면 예외 (classify 로 분류). 시험은 RENE_SHEET_FAKE_* 로 갈아끼운다."""
    if os.environ.get("RENE_SHEET_FAKE_NET") == "down":
        raise ConnectionError("fake: network down (RENE_SHEET_FAKE_NET=down)")
    fake = os.environ.get("RENE_SHEET_FAKE_DIR")
    if fake:
        return TsvSheet(os.path.join(fake, tab + ".tsv"), tab)
    creds = creds or find_creds()
    if not creds:
        raise AuthMissing("서비스 계정 json 을 찾지 못했다 ($RENE_SHEETS_SA · <저장소>/.config/rene · ~/.config/rene)")
    import gspread
    from google.oauth2.service_account import Credentials
    cr = Credentials.from_service_account_file(creds, scopes=["https://www.googleapis.com/auth/spreadsheets"])
    return gspread.authorize(cr).open_by_key(sheet_id).get_worksheet_by_id(int(gid))


def rc_of(e):
    return RC_AUTH if isinstance(e, AuthMissing) else classify(e)


# ---- 원장 ---------------------------------------------------------------
class Ledger:
    def __init__(self, tab, header=None, key_cols=None, sheet_id="", gid="", dir=None):
        self.tab = tab
        self.dir = ledger_dir(dir)
        self.path = os.path.join(self.dir, tab + ".tsv")
        self.meta = {"tab": tab, "sheet_id": sheet_id, "gid": str(gid), "key": "|".join(key_cols or [])}
        self.header = list(header or [])
        self.rows = []          # dict(vals=[...], key, added, state, sent, range, note)
        self._lockf = None
        self.load()
        if sheet_id:
            self.meta["sheet_id"] = sheet_id
        if gid != "":
            self.meta["gid"] = str(gid)
        if key_cols:
            self.meta["key"] = "|".join(key_cols)
        if header and not self.header:
            self.header = list(header)

    # -- 파일 --
    def exists(self):
        return os.path.isfile(self.path)

    def load(self):
        self.rows = []
        if not os.path.isfile(self.path):
            return
        with open(self.path, encoding="utf-8") as f:
            lines = [l.rstrip("\n") for l in f]
        if not lines or not lines[0].startswith("#ledger"):
            raise ValueError(f"원장 형식이 아니다 : {self.path}")
        for tok in lines[0][len("#ledger"):].split():
            if "=" in tok:
                k, v = tok.split("=", 1); self.meta[k] = urllib.parse.unquote(v)
        cols = [unesc(c) for c in lines[1].split("\t")] if len(lines) > 1 else []
        n = len(cols) - len(META)
        file_header = cols[:n]
        if file_header:
            self.header = file_header
        for l in lines[2:]:
            if not l:
                continue
            f = [unesc(c) for c in l.split("\t")]
            f += [""] * (len(cols) - len(f))
            m = dict(zip(META, f[n:n + len(META)]))
            self.rows.append({"vals": f[:n], "key": m["_key"], "added": m["_added"], "state": m["_state"] or "pending",
                              "sent": m["_sent"], "range": m["_range"], "note": m["_note"]})

    @contextlib.contextmanager
    def locked(self):
        """원장을 바꾸는 동안 잡는다. 잡은 뒤 다시 읽어 남이 그 사이 쓴 것을 놓치지 않는다."""
        os.makedirs(self.dir, exist_ok=True)
        f = open(self.path + ".lock", "a")
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            hdr, meta = list(self.header), dict(self.meta)
            self.load()
            if not self.header:
                self.header = hdr
            for k, v in meta.items():
                if v:
                    self.meta[k] = v
            yield self
        finally:
            fcntl.flock(f, fcntl.LOCK_UN); f.close()

    def save(self):
        os.makedirs(self.dir, exist_ok=True)
        tmp = f"{self.path}.tmp.{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("#ledger " + " ".join(f"{k}={urllib.parse.quote(str(v), safe='|-_.()')}" for k, v in self.meta.items()) + "\n")
            f.write("\t".join(esc(c) for c in self.header + META) + "\n")
            for r in self.rows:
                v = list(r["vals"]) + [""] * (len(self.header) - len(r["vals"]))
                v = v[:len(self.header)]
                f.write("\t".join(esc(c) for c in v + [r["key"], r["added"], r["state"], r["sent"], r["range"], r["note"]]) + "\n")
            f.flush(); os.fsync(f.fileno())
        os.replace(tmp, self.path)

    # -- 키 --
    def key_cols(self):
        return [c for c in self.meta.get("key", "").split("|") if c]

    def key_idx(self, header=None):
        h = [norm_name(c) for c in (header or self.header)]
        idx = []
        for c in self.key_cols():
            if norm_name(c) not in h:
                raise ValueError(f"키 열 '{c}' 이 헤더에 없다")
            idx.append(h.index(norm_name(c)))
        return idx

    def key_of(self, vals, idx=None):
        idx = idx if idx is not None else self.key_idx()
        return "\x1f".join(str(vals[i]).strip() if i < len(vals) else "" for i in idx)

    def by_key(self):
        return {r["key"]: r for r in self.rows}

    def keys_with_vals(self):
        return [(r["key"], r["vals"], r["state"]) for r in self.rows]

    # -- 쓰기 (로컬만) --
    def append(self, rows, mode="insert", log=print):
        """rows : 헤더 순서 값 목록들, 또는 (원장 키, 값 목록) 짝.  돌려줌 (새로, 바뀜, 그대로).
        ★ 짝으로 주면 그 키의 행만 고친다 -- 같은 키 둘째 행('k#2')을 고칠 때 값에서 키를 다시 계산하면
          '#N' 이 빠져 첫째 행을 덮는다 (2026-11-09 리뷰 필수 1 : --fill-labels 가 No·Files·Serial 을 덮었다)."""
        idx = self.key_idx(); have = self.by_key(); new = upd = same = 0
        batch = set()
        for item in rows:
            given = None
            if isinstance(item, tuple) and len(item) == 2 and isinstance(item[0], str):
                given, item = item
            vals = ["" if v is None else str(v) for v in item]
            vals += [""] * (len(self.header) - len(vals))
            k = given if given is not None else self.key_of(vals, idx)
            if not k.replace("\x1f", "").strip():
                continue
            if given is None and k in batch:
                log(f"[WARN] {self.tab} : 같은 배치 안에 같은 키 {k.replace(chr(31), ' | ')!r} 가 또 있다 -- 둘째는 싣지 않는다")
                same += 1; continue
            batch.add(k)
            r = have.get(k)
            if given is not None and r is None:
                log(f"[WARN] {self.tab} : 고칠 키 {k.replace(chr(31), ' | ')!r} 가 원장에 없다 -- 건너뛴다")
                same += 1; continue
            if r is None:
                r = {"vals": vals, "key": k, "added": now_s(), "state": "pending", "sent": "", "range": "", "note": ""}
                self.rows.append(r); have[k] = r; new += 1
            elif mode == "upsert" and [nv(a) for a in r["vals"]] != [nv(b) for b in vals]:
                if r["state"] == "foreign":
                    same += 1; continue
                r["vals"] = vals; r["state"] = "pending"; r["note"] = "updated locally " + now_s(); upd += 1
            else:
                same += 1
        return new, upd, same

    def pending(self):
        return [r for r in self.rows if r["state"] == "pending"]

    def counts(self):
        c = {}
        for r in self.rows:
            c[r["state"]] = c.get(r["state"], 0) + 1
        return c


# ---- 시트 읽기 · 원장 거울 ---------------------------------------------------
def find_header(grid, mode):
    if mode == "runmax":
        for i, row in enumerate(grid):
            n = [norm_name(c) for c in row]
            if "run" in n and "max subrun" in n:
                return i
        return None
    return 0 if grid and any(c.strip() for c in grid[0]) else None


def sheet_keymap(grid, hdr_i, idx):
    """시트의 (키 -> 행 index). 같은 키가 둘 이상이면 '#2' '#3' 을 붙여 순서로 가른다 (백업 시트의 옛 스캔 행)."""
    out, seen = {}, {}
    for i in range(hdr_i + 1, len(grid)):
        row = grid[i]
        k = "\x1f".join(row[j].strip() if j < len(row) else "" for j in idx)
        if not k.replace("\x1f", "").strip():
            continue
        seen[k] = seen.get(k, 0) + 1
        out[k if seen[k] == 1 else f"{k}#{seen[k]}"] = i
    return out


def header_check(ledger, sheet_hdr):
    """원장 헤더가 시트 헤더와 같은가 (이름만, 공백·대소문자 무시). 원장이 비었으면 시트 헤더를 받는다."""
    sh = [c for c in sheet_hdr]
    while sh and not sh[-1].strip():
        sh.pop()
    if not ledger.header:
        ledger.header = sh
        return True
    a = [norm_name(c) for c in ledger.header]
    b = [norm_name(c) for c in sh]
    return a == b[:len(a)] and not any(x for x in b[len(a):])


def pull(ledger, grid, cfg, log=print):
    """시트 -> 원장. sent/foreign/removed 행은 시트 값으로, 시트에만 있는 행은 들여온다. pending 은 안 건드린다.
    돌려줌 (hdr_i, keymap) 또는 예외."""
    hdr_i = find_header(grid, cfg["header"])
    if hdr_i is None:
        if cfg["header"] == "first" and not any(any(c.strip() for c in r) for r in grid):
            return None, {}                    # 빈 탭 (DAQ_runsummary 첫 발행)
        raise ValueError("시트에서 헤더를 찾지 못했다")
    if not header_check(ledger, grid[hdr_i]):
        raise ValueError(f"원장 헤더와 시트 헤더가 다르다 : 원장 {ledger.header[:4]}… 시트 {grid[hdr_i][:4]}…")
    idx = ledger.key_idx()
    km = sheet_keymap(grid, hdr_i, idx)
    have = ledger.by_key()
    ours = cfg.get("ours")
    imported = refreshed = removed = 0
    n = len(ledger.header)
    for k, i in km.items():
        vals = (grid[i] + [""] * n)[:n]
        r = have.get(k)
        st = "foreign" if (ours and not ours(k.split("#")[0])) else "sent"
        if r is None:
            r = {"vals": vals, "key": k, "added": now_s(), "state": st, "sent": now_s(),
                 "range": rc_to_a1(i, 0), "note": "pulled from sheet"}
            ledger.rows.append(r); have[k] = r; imported += 1
        elif r["state"] in ("sent", "foreign", "removed"):
            if r["vals"] != vals or r["state"] == "removed":
                refreshed += 1
            r["vals"] = vals; r["state"] = st; r["range"] = rc_to_a1(i, 0)
    for r in ledger.rows:
        if r["state"] == "sent" and r["key"] not in km:
            r["state"] = "removed"; r["note"] = "not in sheet at " + now_s(); removed += 1
    if imported or refreshed or removed:
        log(f"[PULL] {ledger.tab} : 시트에서 들여옴 {imported} · 시트 값으로 갱신 {refreshed} · 시트에 없음(removed) {removed}")
    return hdr_i, km


def anchor_row(grid, hdr_i, cfg, key_idx):
    """새 행을 붙일 첫 행 (0-base). 'lastkey' 는 그 아래가 비어 있어야 한다."""
    if cfg["anchor"] == "lastkey":
        last = hdr_i
        for i in range(len(grid) - 1, hdr_i, -1):
            if any((grid[i][j].strip() if j < len(grid[i]) else "") for j in key_idx):
                last = i; break
        for i in range(last + 1, len(grid)):
            if any(c.strip() for c in grid[i]):
                raise ValueError(f"멈춤 : 마지막 키 행 아래 {i + 1}행에 내용이 있다. 덮어쓸 수 없다")
        return last + 1
    last = hdr_i
    for i in range(len(grid) - 1, hdr_i, -1):
        if any(c.strip() for c in grid[i]):
            last = i; break
    return last + 1


# ---- flush -----------------------------------------------------------------
def flush(ledger, ws, cfg=None, commit=True, backup_dir=None, log=print):
    """pending -> 시트. 돌려줌 (rc, 보낸 행 수, 범위 문자열).  예외는 잡아 rc 로 바꾼다. 원장은 호출자가 잡은 잠금 안에서 저장한다."""
    cfg = cfg or TABS[ledger.tab]
    try:
        grid = ws.get_all_values()
        hdr_i, km = pull(ledger, grid, cfg, log)
        if hdr_i is None:                                  # 빈 탭 : 헤더부터
            if commit:
                ws.update(values=[ledger.header], range_name="A1", value_input_option="RAW")
                grid = ws.get_all_values(); hdr_i, km = pull(ledger, grid, cfg, log)
            else:
                grid, hdr_i, km = [ledger.header], 0, {}
        idx = ledger.key_idx()
        ours = cfg.get("ours")
        prot = {norm_name(c) for c in cfg.get("protect", [])}
        n = len(ledger.header)
        appends, cells, done = [], [], []
        for r in ledger.pending():
            i = km.get(r["key"])
            if i is None:
                appends.append(r); continue
            if ours and not ours(r["key"].split("#")[0]):
                r["state"] = "failed"; r["note"] = "foreign -- 같은 키가 남의 행이다. 건드리지 않는다"
                log(f"[SKIP] {ledger.tab} 키 {r['key']!r} 는 남의 행 ({i + 1}행) -- 쓰지 않는다")
                continue
            row = (grid[i] + [""] * n)[:n]
            diff = [(j, r["vals"][j]) for j in range(n)
                    if str(r["vals"][j]).strip() and norm_name(ledger.header[j]) not in prot and nv(r["vals"][j]) != nv(row[j])]
            if diff:
                cells.append((r, i, diff))
            else:
                done.append((r, i))
        if not appends and not cells:
            for r, i in done:
                r["state"] = "sent"; r["sent"] = now_s(); r["range"] = rc_to_a1(i, 0); r["note"] = "already in sheet"
            if done:
                log(f"[SHEET] {ledger.tab} : 이미 시트에 있던 {len(done)} 행을 sent 로")
            return RC_OK, 0, ""
        first = anchor_row(grid, hdr_i, cfg, idx) if appends else None
        rng = ""
        if appends:
            rng = rc_to_a1(first, 0) + ":" + rc_to_a1(first + len(appends) - 1, n - 1)
        if not commit:
            log(f"[DRY] {ledger.tab} : 붙일 {len(appends)} 행 {rng} · 고칠 {sum(len(d) for _, _, d in cells)} 칸 ({len(cells)} 행)")
            return RC_OK, 0, rng
        # -- 백업 --
        bdir = backup_dir or os.environ.get("RENE_SHEET_BACKUP_DIR") or os.path.join(ledger.dir, "backup")
        os.makedirs(bdir, exist_ok=True)
        bak = os.path.join(bdir, f"{ledger.tab}-before-{time.strftime('%Y%m%d%H%M%S')}.tsv")
        with open(bak, "w", encoding="utf-8") as f:
            for row in grid:
                f.write("\t".join(row) + "\n")
        # -- 쓰기 --
        vio = cfg.get("value_input", "RAW")
        if cells:
            ws.batch_update([{"range": rc_to_a1(i, j), "values": [[v]]} for _, i, d in cells for j, v in d],
                            value_input_option=vio)
            log(f"[SHEET] {ledger.tab} : 우리 행 {len(cells)} 개의 {sum(len(d) for _, _, d in cells)} 칸을 원장 값으로 고침")
        if appends:
            sys.path.insert(0, HERE)
            import sheet_grid
            sheet_grid.ensure_rows(ws, first + len(appends), True, log=log)
            ws.update(values=[r["vals"][:n] for r in appends], range_name=rng, value_input_option=vio)
        # -- 되대조 --
        back = ws.get_all_values()
        touched = {i for _, i, _ in cells}
        bad = []
        for i, x in enumerate(grid):
            if i in touched:
                continue
            y = back[i] if i < len(back) else []
            if [c.strip() for c in x] + [""] * (len(y) - len(x)) != [c.strip() for c in y] + [""] * (len(x) - len(y)):
                bad.append(i + 1)
        #  고친 칸·붙인 행은 쓴 값 그대로인지 (nv : 시트가 USER_ENTERED 로 바꿔 보이는 날짜·시각·숫자 모양은 같게 본다)
        for r, i, d in cells:
            y = back[i] if i < len(back) else []
            if any(nv(y[j] if j < len(y) else "") != nv(v) for j, v in d):
                bad.append(i + 1)
        for k, r in enumerate(appends or []):
            i = first + k
            y = back[i] if i < len(back) else []
            if [nv(y[j] if j < len(y) else "") for j in range(n)] != [nv(r["vals"][j]) for j in range(n)]:
                bad.append(i + 1)
        if bad:
            log(f"[FAIL] {ledger.tab} : 되대조 어긋남 {len(bad)} 행 ({' '.join(map(str, bad[:5]))}) -- pending 그대로. 백업 {bak}")
            return RC_VERIFY, 0, rng
        t = now_s()
        for r, i in done:
            r["state"] = "sent"; r["sent"] = t; r["range"] = rc_to_a1(i, 0); r["note"] = "already in sheet"
        for r, i, d in cells:
            #  원장도 지금 시트와 같게 : 원장 값으로 고친 칸 + 시트에 남긴 칸(빈 원장 칸 · 보호 열)
            merged = (grid[i] + [""] * n)[:n]
            for j, v in d:
                merged[j] = v
            r["vals"] = merged
            r["state"] = "sent"; r["sent"] = t; r["range"] = rc_to_a1(i, 0); r["note"] = "sheet corrected from ledger " + t
        for k, r in enumerate(appends):
            r["state"] = "sent"; r["sent"] = t; r["range"] = rc_to_a1(first + k, 0); r["note"] = ""
        if appends:
            log(f"기록함 : {rng}  ({len(appends)}행)")
        log(f"[SHEET] {ledger.tab} : 붙임 {len(appends)} · 고침 {len(cells)} · 이미 있음 {len(done)} -- 되대조 통과 (백업 {bak})")
        return RC_OK, len(appends) + len(cells), rng
    except Exception as e:      # noqa: BLE001 -- 망·인증·시트 오류를 종료코드로 바꾼다
        rc = rc_of(e)
        log(f"[SHEET] {ledger.tab} : 보류 {len(ledger.pending())} 행 -- {RC_WORD.get(rc, '?')} (rc {rc}) : {type(e).__name__}: {str(e)[:160]}")
        return rc, 0, ""


def commit_rows(ledger, rows, ws=None, grid=None, cfg=None, mode="insert", offline_rc=None, log=print):
    """쓰는 도구의 공통 흐름 : 잠금 -> (망이 되면 시트로 원장 거울 갱신) -> 원장에 append -> 저장(=등재) -> flush -> 저장.
    ws/grid 가 None 이면 망이 없는 것 (offline_rc 가 그 사유).  돌려줌 (로컬 rc, 시트 rc, 새로, 보낸, 범위)."""
    cfg = cfg or TABS[ledger.tab]
    with ledger.locked():
        if grid is not None:
            try:
                pull(ledger, grid, cfg, log)
            except Exception as e:      # noqa: BLE001
                log(f"[WARN] {ledger.tab} : 시트 거울 갱신 실패 ({e}) -- 원장 그대로 쓴다")
        new, upd, same = ledger.append(rows, mode, log=log)
        try:
            ledger.save()
        except OSError as e:
            log(f"[FAIL] 원장 쓰기 실패 : {e} ({ledger.path})")
            return 4, None, 0, 0, ""
        log(f"[LOCAL] {ledger.tab} : 원장에 새로 {new} · 바뀜 {upd} · 그대로 {same} 행 기록 -- pending {len(ledger.pending())} ({ledger.path})")
        if ws is None:
            rc = offline_rc or RC_NET
            log(f"[SHEET] {ledger.tab} : 보류 {len(ledger.pending())} 행 -- {RC_WORD.get(rc, '?')} (rc {rc}). 망이 돌아오면 sheet_ledger.py --flush")
            return 0, rc, new, 0, ""
        if drill_active():
            log(f"[SKIP] {ledger.tab} : 드릴 중 -- 시트에 밀지 않는다 (pending {len(ledger.pending())})")
            return 0, 0, new, 0, ""
        rc, sent, rng = flush(ledger, ws, cfg, commit=True, log=log)
        try:
            ledger.save()
        except OSError as e:
            log(f"[WARN] 원장 갱신 실패 (시트는 썼다) : {e}")
        return 0, rc, new, sent, rng


def online(sheet_id, gid, tab, creds=None, offline=False, log=print):
    """(ws, grid, rc).  망이 없으면 (None, None, rc)."""
    if offline:
        return None, None, RC_NET
    try:
        ws = open_ws(sheet_id, gid, tab, creds)
        return ws, ws.get_all_values(), RC_OK
    except Exception as e:      # noqa: BLE001
        rc = rc_of(e)
        log(f"[SHEET] {tab} : 시트를 읽지 못했다 -- {RC_WORD.get(rc, '?')} (rc {rc}) : {type(e).__name__}: {str(e)[:160]}")
        return None, None, rc


def flush_tab(tab, commit=True, dir=None, log=print):
    """원장 파일 하나를 열어 flush. 드릴 중이면 건너뛴다."""
    if tab in EXTERNAL:
        return flush_external(tab, commit, log)
    lg = Ledger(tab, dir=dir)
    if not lg.exists():
        log(f"[SKIP] {tab} : 원장 없음 ({lg.path})"); return RC_OK
    if not lg.pending():
        log(f"[OK] {tab} : pending 0"); return RC_OK
    if not commit:
        log(f"[DRY] {tab} : pending {len(lg.pending())} 행 -- 시트에 붙지 않는다 (미리보기)"); return RC_OK
    if drill_active():
        log(f"[SKIP] {tab} : 드릴 중 -- 시트에 밀지 않는다"); return RC_OK
    with lg.locked():
        if not lg.pending():
            return RC_OK
        try:
            ws = open_ws(lg.meta.get("sheet_id", ""), lg.meta.get("gid", "0"), tab)
        except Exception as e:      # noqa: BLE001
            rc = rc_of(e)
            log(f"[SHEET] {tab} : 보류 {len(lg.pending())} 행 -- {RC_WORD.get(rc, '?')} (rc {rc}) : {e}")
            return rc
        rc, _, _ = flush(lg, ws, TABS.get(tab), commit=True, log=log)
        lg.save()
    return rc


def flush_external(tab, commit, log):
    if EXTERNAL[tab] == "reactor":
        sys.path.insert(0, os.path.join(REPO, "tools", "reactor"))
        import reactor_power_log as rp
        return rp.sheet_only(commit=commit, log=log)
    return RC_OK


def status_tab(tab, dir=None):
    if tab in EXTERNAL and EXTERNAL[tab] == "reactor":
        sys.path.insert(0, os.path.join(REPO, "tools", "reactor"))
        import reactor_power_log as rp
        return rp.sheet_status()
    lg = Ledger(tab, dir=dir)
    if not lg.exists():
        return f"{tab:16s} 원장 없음 (씨앗 필요 : sheet_ledger.py --pull --tab {tab} -- 망이 있을 때 한 번)"
    c = lg.counts(); p = lg.pending()
    old = min((r["added"] for r in p), default="")
    s = f"{tab:16s} pending {c.get('pending', 0)} · sent {c.get('sent', 0)} · foreign {c.get('foreign', 0)} · removed {c.get('removed', 0)} · failed {c.get('failed', 0)}"
    if old:
        s += f"  (가장 오래된 pending {old})"
    return s


def all_tabs(dir=None):
    d = ledger_dir(dir)
    found = [os.path.basename(p)[:-4] for p in sorted(glob.glob(os.path.join(d, "*.tsv")))]
    #  원장이 아직 없는 탭도 보인다 (--status 가 '씨앗 필요' 를 알린다. --flush 는 '[SKIP] 원장 없음')
    return found + [t for t in list(TABS) + list(EXTERNAL) if t not in found]


def drop_row(tab, key, dry=False, dir=None, log=print):
    """시트에 아직 안 간(pending) 또는 못 간(failed) 행 하나를 원장에서 뺀다 (리뷰 참고 ②).
    예 : 망이 없던 동안 원장에 등재된 런을 나중에 onlbit=0 으로 뺄 때.  sent/foreign/removed 는 거부한다 --
    시트에 있는 행은 시트에서 지우는 것이 먼저다 (그러면 다음 pull 이 removed 로 둔다)."""
    if tab not in TABS:
        log("--drop 은 --tab 하나 (" + " ".join(TABS) + ")"); return RC_OTHER
    lg = Ledger(tab, dir=dir)
    if not lg.exists():
        log(f"원장 없음 ({lg.path})"); return RC_OTHER
    k = key.replace("|", "\x1f")
    with lg.locked():
        r = lg.by_key().get(k)
        if r is None:
            log(f"[FAIL] {tab} : 키 {key!r} 가 원장에 없다"); return RC_OTHER
        if r["state"] not in ("pending", "failed"):
            log(f"[FAIL] {tab} : 키 {key!r} 는 {r['state']} -- pending/failed 만 뺀다 (시트에 있으면 시트에서 먼저 지울 것)")
            return RC_OTHER
        if dry:
            log(f"[DRY] {tab} : 키 {key!r} ({r['state']}) 를 뺄 것이다"); return RC_OK
        lg.rows = [x for x in lg.rows if x is not r]
        lg.save()
    log(f"[DROP] {tab} : 키 {key!r} ({r['state']}, 등재 {r['added']}) 를 원장에서 뺐다")
    return RC_OK


def main():
    ap = argparse.ArgumentParser(description="시트 로컬 원장")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--status", action="store_true"); g.add_argument("--flush", action="store_true")
    g.add_argument("--pull", action="store_true")
    g.add_argument("--drop", metavar="KEY", help="pending/failed 행 하나를 원장에서 뺀다 (키 열이 여럿이면 '|' 로 잇는다)")
    ap.add_argument("--tab"); ap.add_argument("--dry-run", action="store_true"); ap.add_argument("--dir")
    ap.add_argument("--sheet-id", help="--pull : 원장 머리의 sheet_id 대신 (원장이 없으면 탭의 기본값)")
    ap.add_argument("--gid", help="--pull : 원장 머리의 gid 대신 (원장이 없으면 탭의 기본값)")
    a = ap.parse_args()
    tabs = [a.tab] if a.tab else all_tabs(a.dir)
    if a.status:
        print(f"시트 원장 ({ledger_dir(a.dir)})  {now_s()}")
        for t in tabs:
            print("  " + status_tab(t, a.dir))
        return 0
    if a.drop is not None:
        return drop_row(a.tab, a.drop, a.dry_run, a.dir)
    if a.pull:
        if not a.tab or a.tab not in TABS:
            print("--pull 은 --tab 하나 (" + " ".join(TABS) + ")"); return RC_OTHER
        cfg = TABS[a.tab]
        lg = Ledger(a.tab, dir=a.dir)
        #  씨앗 (원장이 아직 없다) : 탭의 기본 sheet_id · gid · 키로 연다 (리뷰 필수 2a, 2026-11-09)
        if a.sheet_id or not lg.meta.get("sheet_id"):
            lg.meta["sheet_id"] = a.sheet_id or cfg["sheet_id"]
        if a.gid is not None or not lg.meta.get("gid"):
            lg.meta["gid"] = str(a.gid if a.gid is not None else cfg["gid"])
        if not lg.key_cols():
            lg.meta["key"] = "|".join(cfg["key"])
        if not lg.exists():
            print(f"[SEED] {a.tab} : 원장 없음 -- 시트(sheet_id {lg.meta['sheet_id'][:12]}… gid {lg.meta['gid']})를 읽어 씨앗을 만든다 ({lg.path})")
        try:
            ws = open_ws(lg.meta["sheet_id"], lg.meta.get("gid", "0"), a.tab)
            grid = ws.get_all_values()
        except Exception as e:      # noqa: BLE001
            print(f"[SHEET] 읽기 실패 rc {rc_of(e)} : {e}"); return rc_of(e)
        if a.dry_run:
            pull(lg, grid, TABS[a.tab]); print(status_tab(a.tab, a.dir) + "  (미리보기, 원장 안 바꿈)")
            return 0
        if not any(any(str(c).strip() for c in r) for r in grid):
            print(f"[SEED] {a.tab} : 시트 탭이 비어 있다 -- 원장을 만들지 않는다 (쓰는 도구의 첫 등재가 헤더부터 쓴다)")
            return 0
        with lg.locked():
            pull(lg, grid, TABS[a.tab]); lg.save()
        print(status_tab(a.tab, a.dir)); return 0
    worst = 0
    for t in tabs:
        rc = flush_tab(t, commit=not a.dry_run, dir=a.dir)
        worst = rc if (worst == 0 or rc == RC_NET) and rc else worst
    return worst


if __name__ == "__main__":
    sys.exit(main())
