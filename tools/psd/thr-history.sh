#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  thr-history.sh - 문턱값 변경 이력의 정본을 데이터에서 다시 만든다 (읽기 전용 스캔, 2026-09-14 사용자 지시).
#
#   PRD 가 있는 모든 런의 첫 PRD 파일에서 S_THR[30] · F_THR[4] 를 읽어
#      /scratch/RunSummary/psd/thr_by_run.tsv      런마다 한 줄 (run · 시작시각 · F_THR0..3 · S_THR0..29)
#      docs/THRESHOLD-HISTORY.md                   값이 바뀐 자리마다 한 행 (런 구간 · 날짜 · 문턱 줄) — 저장소에 커밋되는 이력
#   설정 파일의 주석이 아니라 **데이터에 기록된 값**이 정본이다. 런 시작 시각은 runcatalog.db 의 stime, 없으면 PRD 파일 mtime.
#   사용 : thr-history.sh [--runs 4200-4400] [--out <tsv>] [--md <md>]     (기본은 전 런. /scratch 1,700 런에 10 분쯤)
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd)
OUT=${THR_OUT:-/scratch/RunSummary/psd/thr_by_run.tsv}; MD=$REPO/docs/THRESHOLD-HISTORY.md
ROOTS=${RENE_RAW_ROOTS:-/Data_ssd/RAW:/data/RAW:/scratch/RAW}; DB=${RENE_DB:-/Data_ssd/runcatalog.db}
LO=0; HI=999999
while [ $# -gt 0 ]; do case "$1" in
   --runs) LO=${2%-*}; HI=${2#*-}; shift 2 ;;
   --out) OUT=$2; shift 2 ;;  --md) MD=$2; shift 2 ;;
   -h|--help) sed -n '2,10p' "$0"; exit 0 ;;  *) echo "모르는 옵션 $1"; exit 1 ;; esac; done
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh
mkdir -p "$(dirname "$OUT")"
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
#  런 목록 : 세 뿌리의 합집합 (앞 뿌리가 이긴다)
declare -A SEEN
IFS=: read -ra RR <<< "$ROOTS"
for root in "${RR[@]}"; do
   for d in "$root"/[0-9][0-9][0-9][0-9][0-9][0-9]; do
      [ -d "$d/PRD" ] || continue; r=$((10#$(basename "$d")))
      [ $r -ge $LO ] && [ $r -le $HI ] || continue
      [ -n "${SEEN[$r]:-}" ] && continue
      f=$(ls -U "$d/PRD" 2>/dev/null | grep -E '^PRD_[0-9]+\.[0-9]+\.root$' | sort | head -1)
      [ -n "$f" ] || continue
      SEEN[$r]="$d/PRD/$f"
   done
done
echo "런 ${#SEEN[@]} 개 스캔 → $OUT" >&2
{  printf '#run\tstart\tF_THR0\tF_THR1\tF_THR2\tF_THR3'; for j in $(seq 0 29); do printf '\tS_THR%d' $j; done; printf '\tprd_file\n'
   for r in $(printf '%s\n' "${!SEEN[@]}" | sort -n); do
      f=${SEEN[$r]}
      line=$(nice -n 15 root -l -b -q "$DIR/ThrByRun.C+(\"$f\", $r)" 2>/dev/null | grep -m1 '^THR' | cut -f2-)
      [ -n "$line" ] || continue
      st=""
      [ -r "$DB" ] && command -v sqlite3 >/dev/null 2>&1 && st=$(sqlite3 "$DB" "select stime from runcatalog where runnum=$r" 2>/dev/null | head -1)
      [ -n "$st" ] || st=$(date -r "$f" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
      printf '%s\t%s\t%s\t%s\n' "${line%%$'\t'*}" "$st" "${line#*$'\t'}" "$f"
   done
} > "$TMP"
mv -f "$TMP" "$OUT"
#  변경 지점 → markdown
python3 - "$OUT" "$MD" <<'PY'
import sys
tsv, md = sys.argv[1], sys.argv[2]
rows = [l.rstrip('\n').split('\t') for l in open(tsv) if l and not l.startswith('#')]
segs = []
for r in rows:
    run, st = int(r[0]), r[1]; fthr = r[2:6]; sthr = r[6:36]
    if 'ERR' in r[2:36]: continue
    key = (tuple(fthr), tuple(sthr))
    if segs and segs[-1]['key'] == key: segs[-1]['to'] = run; segs[-1]['n'] += 1; segs[-1]['to_st'] = st
    else: segs.append({'key': key, 'from': run, 'to': run, 'n': 1, 'st': st, 'to_st': st})
out = ['# 문턱값 변경 이력 (데이터 정본)', '',
       '`tools/psd/thr-history.sh` 가 **PRD 에 기록된 S_THR/F_THR** 로 다시 만든다. 설정 파일의 주석이 아니라 이 표가 정본이다.',
       f'런 {len(rows)} 개 스캔. 값이 바뀐 자리마다 한 행. 같은 값이 이어지는 구간은 한 행으로 묶는다 (구간 안에 PRD 없는 런은 셈에서 빠진다).', '',
       '| 구간 (런) | 첫 런 시작 | 런 수 | F_THR ch0..3 | S_THR ch0..29 |', '|---|---|---|---|---|']
for s in segs:
    out.append(f"| {s['from']:06d} ~ {s['to']:06d} | {s['st']} | {s['n']} | {' '.join(s['key'][0])} | `{' '.join(s['key'][1])}` |")
out += ['', '★ 변경 사유·누가·언제 결정했는가는 `CLAUDE.md` §11 과 `/Data_ssd/LOG/threshold-changes.log` 에, 설정 파일의 주석 줄은 `/home/frontend/ConfigFiles/DataTaking_IBD_sykim_2026.config` 에 있다.',
        f'', f'생성 : {__import__("datetime").datetime.now():%Y-%m-%d %H:%M} · 원본 표 `{tsv}`']
open(md, 'w').write('\n'.join(out) + '\n')
print(f'변경 구간 {len(segs)} 개 → {md}')
PY
