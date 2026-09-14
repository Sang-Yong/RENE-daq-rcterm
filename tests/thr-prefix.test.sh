#!/usr/bin/env bash
# thr_prefix.py — veto 문턱값 변경 문구 판정 (표만 쓰고 ROOT·시트 무접촉)
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ $# -gt 1 ] && echo "       $2"; }
mk() { python3 - "$T/thr.tsv" <<'PY'
import sys
base = [100]*30
rows = {900000: base, 900001: base, 900002: [200]*10 + [100]*20, 900003: [200]*10 + [50]*20, 900004: [200]*10 + [50]*10 + [100]*10, 900005: [200]*10 + [50]*10 + [100]*10}
with open(sys.argv[1], 'w') as o:
    o.write('#run\tstart\tF0\tF1\tF2\tF3' + ''.join('\tS%d' % i for i in range(30)) + '\tprd\n')
    for r in sorted(rows): o.write('%d\t2026-01-01 00:00:00\t80\t80\t1\t1\t%s\tx\n' % (r, '\t'.join(map(str, rows[r]))))
    o.write('900006\t2026-01-01\t80\t80\t1\t1\t' + '\t'.join(['ERR']*30) + '\tx\n')
PY
}
mk
OUT=$(THR_TABLE=$T/thr.tsv python3 "$DIR/tools/sheetlog/thr_prefix.py" 900000 900001 900002 900003 900004 900005 900006 2>&1)
chk() { echo "$OUT" | grep -qP "^$1\t$2$" && ok "$3" || bad "$3" "$(echo "$OUT" | grep -P "^$1\t")"; }
chk 900000 '' '첫 런 : 비교 대상 없음 → 빈 문구'
chk 900001 '' '같은 값 → 빈 문구'
chk 900002 '비토 문턱값 변경\(증가\) ' '10 채널 상승 → 증가'
chk 900003 '비토 문턱값 변경\(감소\) ' '20 채널 하강 → 감소'
chk 900004 '비토 문턱값 변경\(증가\) ' '10 상승 / 0 하강 → 증가'
chk 900005 '' '900004 와 같음 → 빈 문구'
chk 900006 '' 'ERR 런 → 빈 문구 (스캔 없이)'
python3 - "$DIR" <<'PY' && ok "strip_prefix 가 겹친 문구를 뗀다 · classify 동수 → 변경" || bad "strip/classify"
import sys; sys.path.insert(0, sys.argv[1] + '/tools/sheetlog'); import thr_prefix as tp
assert tp.strip_prefix('비토 문턱값 변경(증가) 비토 문턱값 변경(감소) abc') == 'abc'
assert tp.strip_prefix('abc') == 'abc' and tp.strip_prefix('') == ''
assert tp.classify([1,1,1,1], [2,2,0,0]) == '변경' and tp.classify(None, [1]) == '' and tp.classify([1],[1]) == ''
PY
echo; echo "PASS $PASS  FAIL $FAIL"; [ "$FAIL" -eq 0 ]
