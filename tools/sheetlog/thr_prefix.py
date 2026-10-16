#!/usr/bin/env python3
"""thr_prefix.py — 런의 설정이 직전 런과 다르면 Description 앞에 붙일 문구를 만든다.

   2026-09-14 : veto(SADC) 문턱값이 바뀌면 '비토 문턱값 변경(증가|감소|변경) ' (사용자 지시)
   2026-10-16 : 무엇이 바뀌었는지도 적는다 (사용자 지시 '설정 파일을 바꿨을 때 THR 값 변경이 있다면 그것도 기록, 소급 적용')

   문구 (뒤에 원래 rundesc 가 온다)
     비토 문턱값 변경(감소) [VETO_..._ch8thr80.config: ch8(PMT18) 100→80] 원래설명
     비토 문턱값 변경(증가) [X.config: 24ch 변경 → 285 201 … off×12 (이전 100×18 off×12); PID 순서 변경] 원래설명
     설정 파일 변경 [X.config] 원래설명                ← 파일 이름만 바뀌고 THR·PID·FADC 문턱은 같다
     설정 파일 변경 [X.config: PID 순서 변경] 원래설명   ← SADC 문턱은 같고 PID(또는 FADC 문턱)만 바뀌었다
   ch 번호는 0 부터 (분석 ch = CID-1), 괄호 안 PMT 는 이번 런의 SADCT PID 줄. 100000 이상은 off.
   증가/감소/변경 = 바뀐 SADC 채널 중 오른 것이 많으면 증가, 내린 것이 많으면 감소, 같으면 변경.

   비교 대상 = 직전 런. eligible(예: 시트에 있는 런)이 주어지면 그 안에서, 아니면 아는 런 전체에서 번호가 작은 것 중 가장 큰 것.
   ★ 이번 런이나 직전 런을 못 읽으면 판정하지 않는다 (describe 가 None). 부르는 쪽이 있던 문구를 그대로 둔다.

   값을 읽는 순서 (앞이 이긴다)
     1  런마다 rcterm 이 복사한 설정 사본  <CONFIG 디렉터리>/<런6자리>.config
          RENE_CONFIG_DIRS (기본 /Data_ssd/CONFIG:/data/CONFIG:/scratch/CONFIG). SADCT 블록의 주석 아닌 첫 THR · PID,
          FADCT 블록의 첫 THR. 설정 파일 이름은 runcatalog.db 의 config 열 (RENE_RUNDB) 의 basename
     2  /scratch/RunSummary/psd/thr_by_run.tsv  (PRD 의 S_THR. PID 는 없다)
     3  그 런의 첫 PRD 를 ROOT 로 읽어 표 끝에 덧붙인다

   사용 : thr_prefix.py 4340 4341 4344      → 런마다 '런<TAB>문구' 한 줄 (판정 불가면 '?사유')
   모듈 : from thr_prefix import describe, prefix_for, strip_prefix
"""
import glob, os, re, sqlite3, subprocess, sys

TABLE = os.environ.get("THR_TABLE", "/scratch/RunSummary/psd/thr_by_run.tsv")
ROOTS = os.environ.get("RENE_RAW_ROOTS", "/Data_ssd/RAW:/data/RAW:/scratch/RAW").split(":")
HERE = os.path.dirname(os.path.abspath(__file__))
MACRO = os.path.join(HERE, "..", "psd", "ThrByRun.C")
PREFIX = "비토 문턱값 변경"
PREFIX_CFG = "설정 파일 변경"
CONFIG_DIRS = [d for d in os.environ.get("RENE_CONFIG_DIRS", "/Data_ssd/CONFIG:/data/CONFIG:/scratch/CONFIG").split(":") if d]
RUNDB = os.environ.get("RENE_RUNDB", "/Data_ssd/runcatalog.db")
#  ★ 이 아래의 CONFIG 디렉터리는 그 루트가 실제로 마운트돼 있을 때만 본다. /scratch 는 hard NFS 라 서버가 죽은 채
#    마운트가 빠져 있거나 걸려 있으면 isfile 이 멎을 수 있다 -- cron 이 매시 매달리지 않게 (리뷰 2026-10-16)
MOUNT_ROOTS = [d.rstrip("/") for d in os.environ.get("RENE_MOUNT_ROOTS", "/scratch").split(":") if d]
OFF = 100000           # 이 이상인 문턱은 꺼 둔 채널이다 (500000 · 5000000)
MANY = 8               # 바뀐 채널이 이보다 많으면 채널별로 늘어놓지 않고 새 값 전체를 줄여 적는다


def load_table(path=TABLE):
    """run -> S_THR 30 개 (int). 못 읽은 런(ERR)은 빠진다."""
    t = {}
    if not os.path.exists(path):
        return t
    for ln in open(path):
        if not ln.strip() or ln.startswith("#"):
            continue
        f = ln.rstrip("\n").split("\t")
        if len(f) < 36 or not f[0].isdigit():
            continue
        vals = f[6:36]
        if any(v == "ERR" or v == "" for v in vals):
            continue
        try:
            t[int(f[0])] = [int(float(v)) for v in vals]
        except ValueError:
            continue
    return t


def _first_prd(run):
    for root in ROOTS:
        d = os.path.join(root, "%06d" % run, "PRD")
        if os.path.isdir(d):
            fs = sorted(glob.glob(os.path.join(d, "PRD_%06d.*.root" % run)))
            if fs:
                return fs[0]
    return None


def scan_run(run, table=None, path=TABLE):
    """표에 없는 런을 PRD 에서 읽어 표에 덧붙이고 값을 돌려준다. 못 읽으면 None."""
    prd = _first_prd(run)
    if not prd or not os.path.exists(MACRO):
        return None
    try:
        #  cron 환경에는 ROOT 가 PATH 에 없다 -- thisroot.sh 를 먼저 source 한다 (sheetlog-auto.sh 가 cron 에서 부른다)
        cmd = "command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh; root -l -b -q '%s+(\"%s\", %d)'" % (MACRO, prd, run)
        out = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=600).stdout
    except Exception:
        return None
    for ln in out.splitlines():
        if ln.startswith("THR\t"):
            f = ln.split("\t")[1:]
            if len(f) >= 35 and "ERR" not in f:
                vals = [int(float(v)) for v in f[5:35]]
                try:
                    with open(path, "a") as o:
                        o.write("%d\t\t%s\t%s\n" % (run, "\t".join(f[1:5]), "\t".join(f[5:35]) + "\t" + prd))
                except OSError:
                    pass
                if table is not None:
                    table[run] = vals
                return vals
    return None


def classify(prev, cur):
    """직전 런의 문턱 prev 와 이번 런 cur (각 30 개) → '' / '증가' / '감소' / '변경'"""
    if prev is None or cur is None or prev == cur:
        return ""
    up = sum(1 for a, b in zip(prev, cur) if b > a)
    dn = sum(1 for a, b in zip(prev, cur) if b < a)
    return "증가" if up > dn else ("감소" if dn > up else "변경")



# ---- 설정 사본 ----------------------------------------------------------
def _ints(tok):
    out = []
    for t in tok:
        try:
            out.append(int(float(t)))
        except ValueError:
            break
    return out


def parse_config(path):
    """설정 사본에서 {'sthr','spid','fthr'} 를 읽는다. '#' 뒤는 버리고, 블록마다 주석 아닌 첫 THR/PID 만 쓴다."""
    r = {"sthr": None, "spid": None, "fthr": None}
    blk = None
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError:
        return None
    for ln in lines:
        f = ln.split("#", 1)[0].split()
        if not f:
            continue
        k = f[0]
        if k == "END":
            blk = None
        elif blk is None:
            blk = k                       # DAQ · TCB · FADCT · SADCT … 블록 머리
        elif blk == "SADCT" and k == "THR" and r["sthr"] is None:
            r["sthr"] = _ints(f[1:]) or None
        elif blk == "SADCT" and k == "PID" and r["spid"] is None:
            r["spid"] = _ints(f[1:]) or None
        elif blk == "FADCT" and k == "THR" and r["fthr"] is None:
            r["fthr"] = _ints(f[1:]) or None
    return r if r["sthr"] else None


def _dir_usable(d):
    """d 가 MOUNT_ROOTS 중 하나의 밑이면 그 루트가 마운트돼 있을 때만 참"""
    for m in MOUNT_ROOTS:
        if d == m or d.startswith(m + "/"):
            return os.path.ismount(m)
    return True


def config_dirs():
    return [d for d in CONFIG_DIRS if _dir_usable(d)]


def _config_copy(run):
    for d in config_dirs():
        p = os.path.join(d, "%06d.config" % run)
        if os.path.isfile(p):
            return p
    return None


_NAMES = None


def config_names():
    """run -> 설정 파일 basename (runcatalog.db 의 config 열, 읽기 전용). DB 를 못 읽으면 빈 dict."""
    global _NAMES
    if _NAMES is None:
        _NAMES = {}
        if os.path.exists(RUNDB):
            try:
                db = sqlite3.connect("file:%s?mode=ro" % RUNDB, uri=True)
                for run, c in db.execute("select runnum, config from runcatalog"):
                    if c and str(c).strip():
                        _NAMES[int(run)] = os.path.basename(str(c).strip())
                db.close()
            except sqlite3.Error as e:
                sys.stderr.write("thr_prefix : DB 를 못 읽었다 (%s) -- 설정 파일 이름 없이 간다\n" % e)
    return _NAMES


_INFO = {}


def run_info(run, table=None, allow_scan=True):
    """그 런의 {'sthr','spid','fthr','cfg','src'}. 못 읽으면 None. 설정 사본 → 표 → PRD 순서."""
    key = (run, id(table))
    if key in _INFO:
        return _INFO[key]
    info = None
    p = _config_copy(run)
    if p:
        info = parse_config(p)
        if info:
            info["src"] = p
    if info is None:
        if table is None:
            table = load_table()
        v = table.get(run)
        if v is None and allow_scan:
            v = scan_run(run, table)
        if v is not None:
            info = {"sthr": v, "spid": None, "fthr": None, "src": "thr_by_run"}
    if info is not None:
        info["cfg"] = config_names().get(run)
    _INFO[key] = info
    return info


def known_runs(table):
    """eligible 이 없을 때의 비교 후보 = 표의 런 + 설정 사본이 있는 런"""
    cand = set(table.keys())
    for d in config_dirs():
        for f in glob.glob(os.path.join(d, "[0-9]" * 6 + ".config")):
            cand.add(int(os.path.basename(f)[:6]))
    return cand


# ---- 문구 ---------------------------------------------------------------
def _v(x):
    return "off" if x >= OFF else str(x)


def compress(vals):
    """100 100 100 500000 500000 → '100×3 off×2'  (이웃한 같은 값만 묶는다)"""
    out, i = [], 0
    while i < len(vals):
        j = i
        while j + 1 < len(vals) and _v(vals[j + 1]) == _v(vals[i]):
            j += 1
        n = j - i + 1
        out.append(_v(vals[i]) + ("×%d" % n if n > 1 else ""))
        i = j + 1
    return " ".join(out)


def _chan_diff(prev, cur, pid):
    if len(prev) != len(cur):
        return "채널 수 %d→%d → %s (이전 %s)" % (len(prev), len(cur), compress(cur), compress(prev))
    ch = [i for i, (a, b) in enumerate(zip(prev, cur)) if a != b]
    if len(ch) > MANY:
        return "%dch 변경 → %s (이전 %s)" % (len(ch), compress(cur), compress(prev))
    parts = []
    for i in ch:
        pm = "(PMT%d)" % pid[i] if pid and i < len(pid) else ""
        parts.append("ch%d%s %s→%s" % (i, pm, _v(prev[i]), _v(cur[i])))
    return ", ".join(parts)


def describe(run, table=None, eligible=None, allow_scan=True):
    """(문구, 사유).  문구 None = 판정 불가(있던 문구를 그대로 둘 것), '' = 바뀐 것 없음."""
    if table is None:
        table = load_table()
    cur = run_info(run, table, allow_scan)
    if cur is None:
        return None, "run %d 의 문턱값을 못 읽었다 (설정 사본·표·PRD 모두 없음)" % run
    cand = set(eligible) if eligible is not None else known_runs(table)
    prevs = [r for r in cand if r < run]
    if not prevs:
        return "", "직전 런이 없다"
    pr = max(prevs)
    prev = run_info(pr, table, allow_scan)
    if prev is None:
        return None, "직전 런 %d 의 문턱값을 못 읽었다" % pr
    det = []
    c = classify(prev["sthr"], cur["sthr"])
    if c:
        det.append(_chan_diff(prev["sthr"], cur["sthr"], cur.get("spid")))
    if prev.get("spid") and cur.get("spid") and prev["spid"] != cur["spid"]:
        det.append("PID 순서 변경")
    if prev.get("fthr") and cur.get("fthr") and prev["fthr"] != cur["fthr"]:
        det.append("FADC 문턱 %s→%s" % (compress(prev["fthr"]), compress(cur["fthr"])))
    name_changed = bool(cur.get("cfg") and prev.get("cfg") and cur["cfg"] != prev["cfg"])
    if not det and not name_changed:
        return "", "같다 (직전 런 %d)" % pr
    inner = cur.get("cfg") or ""
    if det:
        inner = (inner + ": " if inner else "") + "; ".join(det)
    head = "%s(%s)" % (PREFIX, c) if c else PREFIX_CFG
    return "%s [%s] " % (head, inner), "직전 런 %d 대비" % pr


def prefix_for(run, table=None, allow_scan=True, eligible=None):
    """Description 앞에 붙일 문구. 바뀐 것이 없거나 판정 불가면 '' (판정 불가의 사유는 stderr)."""
    p, why = describe(run, table, eligible, allow_scan)
    if p is None:
        sys.stderr.write("thr_prefix : run %d 판정 불가 -- %s\n" % (run, why))
        return ""
    return p


OURS_RE = re.compile(r"\.config|\bch\d+|\d+ch 변경|PID 순서 변경|FADC 문턱|채널 수")


def strip_prefix(desc):
    """이미 붙은 문구를 뗀다 — 옛 형식 '비토 문턱값 변경(X) ' 와 새 형식 '… [ … ] ' 둘 다, 겹쳐 있어도 전부."""
    d = desc or ""
    while True:
        if d.startswith(PREFIX):
            i = d.find(")")
            d = d[i + 1:].lstrip() if i > 0 else d[len(PREFIX):].lstrip()
        elif d.startswith(PREFIX_CFG):
            d = d[len(PREFIX_CFG):].lstrip()
        else:
            return d
        if d.startswith("["):              # 우리 문구 바로 뒤의 [ … ] 만, 그것도 우리가 쓰는 낱말이 있을 때만 뗀다
            j = d.find("]")                #   (옛 형식 뒤 rundesc 가 '[m] = 1 …' 처럼 괄호로 시작하는 경우를 지키려고)
            if j > 0 and OURS_RE.search(d[1:j]):
                d = d[j + 1:].lstrip()


if __name__ == "__main__":
    t = load_table()
    for a in sys.argv[1:]:
        if a.isdigit():
            p, why = describe(int(a), t)
            print("%s\t%s" % (a, "?" + why if p is None else p))
