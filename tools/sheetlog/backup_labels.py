#!/usr/bin/env python3
"""외장하드 라벨 정본(docs/backup-disks/disks.tsv) — 읽기 · 자동 부여 · 예약 · 사람용 표 재생성 (2026-09-16).

라벨 규칙 : RENE-<종류>-NNN. 종류 = 그 하드에 담은 것 (RAW · PRD · MERGED · ALL). 번호는 종류별로 처음 담은 순서.
★ 한 번 준 라벨은 바뀌지 않는다 — 이 파일의 어떤 함수도 기존 줄의 라벨을 고치지 않는다.

왜 따로 뺐나 : 2026-09-16 까지 라벨은 `rebuild_backup_sheet.py --scan` 을 사람이 돌릴 때만 붙었다. 매시 cron(append_backup_rows.py)은
행을 붙이면서 'Disk Label' 을 비워 두어 09-15 의 하드 두 장(Z4ZBZE7F · Z4ZBZEBA, 108 행)이 라벨 없이 남았다. 이제 cron 이 새 시리얼을 보면
parts_index 의 종류(raw/prd)로 그 자리에서 번호를 주고 정본에 적는다. 정본은 운영 디렉터리의 파일이므로 바뀌면 work 클론으로 복사해 커밋한다.

    backup_labels.py --list                          정본 표
    backup_labels.py --reserve <시리얼> <모델> <raw|prd|all|merged> [메모]   아직 안 담은 하드에 다음 번호를 미리 준다 (스티커 인쇄용)
    backup_labels.py --regen-md                      docs/BACKUP-DISKS.md 를 정본에서 다시 만든다
"""
import argparse, datetime, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DOCS = os.path.join(os.path.dirname(os.path.dirname(HERE)), "docs", "backup-disks")
DISKS_TSV = os.environ.get("BACKUP_DISKS_TSV") or os.path.join(DOCS, "disks.tsv")
DISKS_MD = os.environ.get("BACKUP_DISKS_MD") or os.path.join(os.path.dirname(DOCS), "BACKUP-DISKS.md")
NCOL = 14   # key label serial model wwn uuids capacity first_ts last_ts runs files GB scanned_at note
HEAD = ["# 외장하드 목록 — 라벨 정본. rebuild_backup_sheet.py / backup_labels.py 가 갱신한다. 라벨 열은 한 번 정해지면 바뀌지 않는다.",
        "# key(serial|uuid)\tlabel\tserial\tmodel\twwn\tuuids\tcapacity\tfirst_ts\tlast_ts\truns\tfiles\tGB\tscanned_at\tnote"]


def load_rows(path=DISKS_TSV):
    rows = []
    if not os.path.isfile(path):
        return rows
    with open(path, encoding="utf-8") as f:
        for ln in f:
            ln = ln.rstrip("\n")
            if not ln.strip() or ln.startswith("#"):
                continue
            r = ln.split("\t")
            rows.append(r + [""] * (NCOL - len(r)))
    return rows


def labels_of(rows):
    return {r[0]: r[1] for r in rows if r[0] and r[1]}


def cat_of(mode):
    m = (mode or "").lower()
    return {"raw": "RAW", "prd": "PRD", "merged": "MERGED"}.get(m, "ALL")


def next_label(labels, cat):
    used = [int(m.group(1)) for l in labels.values() for m in [re.match(rf"RENE-{cat}-(\d+)$", l)] if m]
    return f"RENE-{cat}-{(max(used) + 1 if used else 1):03d}"


def write_rows(rows, path=DISKS_TSV):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(HEAD) + "\n")
        for r in rows:
            f.write("\t".join(r[:NCOL]) + "\n")
    os.replace(tmp, path)


def ensure_label(serial, uuid, model, mode, first_ts, cap="", note="", path=DISKS_TSV, md_path=DISKS_MD, commit=True):
    """(라벨, 새로 줬는가). 시리얼(없으면 UUID)로 찾고, 없으면 종류의 다음 번호를 정본에 붙인다. commit=False 면 정본을 안 건드린다."""
    rows = load_rows(path)
    labels = labels_of(rows)
    key = serial or uuid
    if not key:
        return "", False
    if key in labels:
        return labels[key], False
    if uuid and uuid in labels:                       # UUID 로 먼저 알려진 하드가 시리얼을 얻은 경우 : 라벨을 물려받는다 (번호 불변)
        lab = labels[uuid]
        if commit:
            for r in rows:
                if r[0] == uuid:
                    r[0] = serial; r[2] = serial; r[3] = r[3] or model; r[13] = (r[13] + "; " if r[13] else "") + f"serial learned {datetime.date.today()}"
            write_rows(rows, path); regen_md(path, md_path)
        return lab, False
    lab = next_label(labels, cat_of(mode))
    if commit:
        rows.append([key, lab, serial, model, "", uuid, cap, first_ts, first_ts, "", "", "", "",
                     (note + "; " if note else "") + f"auto-labeled {datetime.datetime.now():%Y-%m-%d %H:%M} from parts_index ({(mode or '?').lower()})"])
        write_rows(rows, path); regen_md(path, md_path)
    return lab, True


def touch_last(key, last_ts, path=DISKS_TSV):
    """정본의 last_ts 를 앞으로 당긴다 (라벨은 안 건드린다)."""
    rows = load_rows(path); hit = False
    for r in rows:
        if r[0] == key and last_ts and last_ts > r[8]:
            r[8] = last_ts; hit = True
    if hit:
        write_rows(rows, path)


def regen_md(path=DISKS_TSV, md_path=DISKS_MD):
    rows = load_rows(path)
    md = ["# 외장하드 백업 — 하드 목록과 라벨\n",
          "`tools/sheetlog/backup_labels.py` / `rebuild_backup_sheet.py` 가 만든다. 손으로 고치지 말 것 (정본은 `docs/backup-disks/disks.tsv`).\n",
          "라벨은 **하드에 스티커로 붙이는 이름**이다 : `RENE-<종류>-NNN` (RAW = 원시 자료만 · PRD = PRD·PNG 만 · MERGED = Merged 만(재처리 캐시) · ALL = 섞임, 나누기 전). "
          "번호는 종류별로 처음 담은 순서. 시리얼은 하드에 새겨진 제조사 값(`udevadm`). **스티커에는 라벨과 시리얼을 함께 적는다.**\n",
          "| 라벨 | 시리얼 | 모델 | UUID | 처음~마지막 | 런 수 | 파일 | GB | 스캔 | 비고 |", "|---|---|---|---|---|---|---|---|---|---|"]
    def sk(r):
        m = re.match(r"RENE-([A-Z]+)-(\d+)$", r[1] or "")
        return (m.group(1), int(m.group(2))) if m else ("~", 0)
    for r in sorted(rows, key=sk):
        uu = " ".join(u[:8] for u in r[5].split(",") if u)
        md.append(f"| **{r[1]}** | {r[2] or '?'} | {r[3] or '?'} | {uu} | {r[7][:10]} ~ {r[8][:10]} | {r[9]} | {r[10]} | {r[11]} | {r[12][:10] or '-'} | {r[13]} |")
    md.append(f"\n생성 {datetime.datetime.now():%Y-%m-%d %H:%M} · 하드 {len(rows)}")
    os.makedirs(os.path.dirname(os.path.abspath(md_path)), exist_ok=True)
    with open(md_path, "w", encoding="utf-8") as f:
        f.write("\n".join(md) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--reserve", nargs="+", metavar="ARG", help="<시리얼> <모델> <raw|prd|all|merged> [메모]")
    ap.add_argument("--regen-md", action="store_true")
    ap.add_argument("--disks-tsv", default=DISKS_TSV); ap.add_argument("--disks-md", default=DISKS_MD)
    a = ap.parse_args()
    if a.reserve:
        if len(a.reserve) < 3:
            sys.exit("--reserve <시리얼> <모델> <raw|prd|all|merged> [메모]")
        serial, model, mode = a.reserve[:3]; note = " ".join(a.reserve[3:]) or "reserved before first use"
        lab, new = ensure_label(serial, "", model, mode, "", note=note, path=a.disks_tsv, md_path=a.disks_md)
        print(f"{'[NEW ]' if new else '[KEEP]'} {serial} -> {lab}")
    if a.regen_md:
        regen_md(a.disks_tsv, a.disks_md); print(f"[MD  ] {a.disks_md}")
    if a.list or not (a.reserve or a.regen_md):
        for r in load_rows(a.disks_tsv):
            print(f"{r[1]:18s} {r[2] or r[0]:14s} {r[3]:20s} {r[7][:10]:10s} {r[13]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
