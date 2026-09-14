#!/usr/bin/env python3
"""thr_prefix.py — 런의 veto(SADC) 문턱값이 직전 런과 다르면 Description 앞에 붙일 문구를 만든다 (2026-09-14 사용자 지시).

   문구 : '비토 문턱값 변경(증가) ' / '비토 문턱값 변경(감소) ' / '비토 문턱값 변경(변경) '  (바뀐 채널 중 오른 것이 많으면 증가,
          내린 것이 많으면 감소, 같으면 변경).  안 바뀌었으면 빈 문자열.
   비교 대상 = 표에 있는 직전 런 (번호가 작은 것 중 가장 큰 것). 정본 표는 tools/psd/thr-history.sh 가 만드는
   /scratch/RunSummary/psd/thr_by_run.tsv 이고, 런이 표에 없으면 그 런의 첫 PRD 를 ROOT 로 읽어 표 끝에 덧붙인다.

   사용 : thr_prefix.py 4340 4341 4344      → 런마다 '런<TAB>문구' 한 줄
   모듈 : from thr_prefix import prefix_for
"""
import glob, os, subprocess, sys

TABLE = os.environ.get("THR_TABLE", "/scratch/RunSummary/psd/thr_by_run.tsv")
ROOTS = os.environ.get("RENE_RAW_ROOTS", "/Data_ssd/RAW:/data/RAW:/scratch/RAW").split(":")
HERE = os.path.dirname(os.path.abspath(__file__))
MACRO = os.path.join(HERE, "..", "psd", "ThrByRun.C")
PREFIX = "비토 문턱값 변경"


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
        out = subprocess.run(["root", "-l", "-b", "-q", '%s+("%s", %d)' % (MACRO, prd, run)],
                             capture_output=True, text=True, timeout=600).stdout
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


def prefix_for(run, table=None, allow_scan=True):
    """Description 앞에 붙일 문구 ('' 이면 붙일 것 없음)."""
    if table is None:
        table = load_table()
    cur = table.get(run)
    if cur is None and allow_scan:
        cur = scan_run(run, table)
    if cur is None:
        return ""
    prevs = [r for r in table if r < run]
    if not prevs:
        return ""
    prev = table[max(prevs)]
    c = classify(prev, cur)
    return "%s(%s) " % (PREFIX, c) if c else ""


def strip_prefix(desc):
    """이미 붙어 있는 문구를 뗀다 (다시 붙일 때 두 번 붙지 않게)."""
    d = desc or ""
    while d.startswith(PREFIX):
        i = d.find(")")
        d = d[i + 1:].lstrip() if i > 0 else d[len(PREFIX):].lstrip()
    return d


if __name__ == "__main__":
    t = load_table()
    for a in sys.argv[1:]:
        if a.isdigit():
            print("%s\t%s" % (a, prefix_for(int(a), t)))
