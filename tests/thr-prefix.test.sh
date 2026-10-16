#!/usr/bin/env bash
# thr_prefix.py — 설정·문턱값 변경 문구 판정 (표 · 설정 사본 · 가짜 DB 만 쓴다. ROOT·시트·구글 무접촉)
#   픽스처 tests/fixtures/thr-config/00438[1-7].config 는 /Data_ssd/CONFIG 의 실제 사본 그대로다 (2026-10-16 복사)
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FX=$DIR/tests/fixtures/thr-config
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ $# -gt 1 ] && echo "       $2"; }
#  바깥(운영 CONFIG · DB · /scratch 표)을 절대 읽지 않게 막는다
export RENE_CONFIG_DIRS=$T/none RENE_RUNDB=$T/none.db RENE_RAW_ROOTS=$T/noraw THR_TABLE=$T/none.tsv

# ---- [1] 표만 (옛 시험 그대로, 문구 뒤에 세부가 붙는다) ----
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
chk 900002 '비토 문턱값 변경\(증가\) \[10ch 변경 → 200×10 100×20 \(이전 100×30\)\] ' '10 채널 상승 → 증가 + 많은 채널은 새 값 전체를 줄여 적는다'
chk 900003 '비토 문턱값 변경\(감소\) \[20ch 변경 → 200×10 50×20 \(이전 200×10 100×20\)\] ' '20 채널 하강 → 감소'
chk 900004 '비토 문턱값 변경\(증가\) \[10ch 변경 .*\] ' '10 상승 / 0 하강 → 증가'
chk 900005 '' '900004 와 같음 → 빈 문구'
chk 900006 '\?.*못 읽었다.*' 'ERR 런 → 판정 불가 (스캔 없이)'

# ---- [2] 설정 사본 (실물) + 가짜 DB ----
mkdir -p "$T/cfg"; cp "$FX"/*.config "$T/cfg/"
python3 - "$T/run.db" <<'PY'
import sqlite3, sys
d = sqlite3.connect(sys.argv[1])
d.execute("create table runcatalog (runnum integer primary key, stime text, etime text, onlbit integer, runlog text, rundesc text, nfadc integer, tfadc real, config text)")
cf = '/home/frontend/ConfigFiles/'
for r, c in [(4380, 'DataTaking_IBD_sykim_2026_thr4067.config'),
             (4381, 'DataTaking_IBD_sykim_2026_thr4067_trg9L.config'), (4382, 'VETO_test_9layers_v2_mid3.config'),
             (4383, 'VETO_test_9layers_v2_mid3_mthrsm16.config'), (4384, 'VETO_test_9layers_v2_mid3.config'),
             (4385, 'VETO_test_9layers_v2_mid3_mthrsm16_ch8thr80.config'), (4386, 'VETO_test_9layers_v2_mid3.config'),
             (4387, 'VETO_test_9layers_v2_mid3_pidfix.config')]:
    d.execute("insert into runcatalog values (?,?,?,?,?,?,?,?,?)",
              (r, '2026-10-16 01:00:00', '2026-10-16 02:00:00', 1, '', 'site A', 1000, 10.0, cf + c))
d.commit()
PY
#  우선순위 확인용 : 표에는 4385 를 엉뚱한 값으로 둔다. 설정 사본이 이겨야 한다
python3 - "$T/thr2.tsv" <<'PY'
import sys
with open(sys.argv[1], 'w') as o:
    o.write('4385\t2026\t1\t1\t1\t1\t' + '\t'.join(['7']*30) + '\tx\n')
    o.write('4380\t2026\t1\t1\t1\t1\t' + '\t'.join('356 251 164 384 182 187 293 454 245 200 335 505 257 205 443 224 200 215 1992 1032 877 125 1762 1963 1192 1237 857 295 597 1228'.split()) + '\tx\n')
PY
export RENE_CONFIG_DIRS=$T/none:$T/cfg RENE_RUNDB=$T/run.db THR_TABLE=$T/thr2.tsv
OUT=$(python3 "$DIR/tools/sheetlog/thr_prefix.py" 4381 4382 4383 4384 4385 4386 4387 2>&1)
chk 4385 '비토 문턱값 변경\(감소\) \[VETO_test_9layers_v2_mid3_mthrsm16_ch8thr80\.config: ch8\(PMT18\) 100→80\] ' '소수 채널 : ch8(PMT18) 100→80 (설정 사본이 표보다 앞선다)'
chk 4386 '비토 문턱값 변경\(증가\) \[VETO_test_9layers_v2_mid3\.config: ch8\(PMT18\) 80→100\] ' '되돌림 : 증가'
chk 4383 '설정 파일 변경 \[VETO_test_9layers_v2_mid3_mthrsm16\.config\] ' '파일만 바뀌고 THR·PID 같음 → 설정 파일 변경'
chk 4384 '설정 파일 변경 \[VETO_test_9layers_v2_mid3\.config\] ' '4383 → 4384 도 파일만'
chk 4387 '비토 문턱값 변경\(증가\) \[VETO_test_9layers_v2_mid3_pidfix\.config: 18ch 변경 → 266 201 131 300 146 150 234 289 120 160 268 210 206 164 298 179 160 172 off×12 \(이전 100×18 off×12\); PID 순서 변경\] ' '다수 채널 + PID 순서 변경'
chk 4382 '비토 문턱값 변경\(감소\) \[VETO_test_9layers_v2_mid3\.config: 30ch 변경 → 100×18 off×12 \(이전 356 .* 1228\); PID 순서 변경; FADC 문턱 80×2 off×2→100×4\] ' 'FADC 문턱 변경도 함께'
chk 4381 '설정 파일 변경 \[DataTaking_IBD_sykim_2026_thr4067_trg9L\.config\] ' '직전 4380 은 표에서 (주석 THR 줄 18 개 무시, 첫 활성 THR 만)'

python3 - "$DIR" <<'PY' && ok "parse_config : 주석 줄·줄 끝 주석 무시, 블록별 첫 THR/PID" || bad "parse_config"
import sys, os; sys.path.insert(0, sys.argv[1] + '/tools/sheetlog'); import thr_prefix as tp
r = tp.parse_config(sys.argv[1] + '/tests/fixtures/thr-config/004381.config')
assert r['sthr'][:3] == [356, 251, 164] and len(r['sthr']) == 30, r
assert r['fthr'] == [80, 80, 5000000, 5000000], r['fthr']
r = tp.parse_config(sys.argv[1] + '/tests/fixtures/thr-config/004387.config')
assert r['spid'][:4] == [38, 27, 9, 24] and r['sthr'][8] == 120 and r['fthr'] == [100]*4, r
open(os.environ['RENE_CONFIG_DIRS'].split(':')[-1] + '/x.config', 'w').write('SADCT 1 30 3\n# THR 1 2 3\nEND\n')
assert tp.parse_config(os.environ['RENE_CONFIG_DIRS'].split(':')[-1] + '/x.config') is None
PY

python3 - "$DIR" <<'PY' && ok "strip_prefix : 옛·새 형식 겹친 것까지 떼고, 다시 붙여도 한 번만 (멱등)" || bad "strip_prefix"
import sys; sys.path.insert(0, sys.argv[1] + '/tools/sheetlog'); import thr_prefix as tp
assert tp.strip_prefix('비토 문턱값 변경(증가) 비토 문턱값 변경(감소) abc') == 'abc'
assert tp.strip_prefix('비토 문턱값 변경(감소) [f.config: ch8(PMT18) 100→80] abc') == 'abc'
assert tp.strip_prefix('설정 파일 변경 [f.config] 비토 문턱값 변경(증가) abc') == 'abc'
assert tp.strip_prefix('설정 파일 변경 [f.config: PID 순서 변경] [rundesc 괄호] x') == '[rundesc 괄호] x'
assert tp.strip_prefix('[rundesc 괄호] x') == '[rundesc 괄호] x'
assert tp.strip_prefix('비토 문턱값 변경(증가) [m] = 1 test') == '[m] = 1 test'
assert tp.strip_prefix('설정 파일 변경 [check list] x') == '[check list] x'
assert tp.strip_prefix('비토 문턱값 변경(증가) [18ch 변경 → 100×18 off×12 (이전 7×30)] y') == 'y'
assert tp.strip_prefix('abc') == 'abc' and tp.strip_prefix('') == ''
p = tp.prefix_for(4385)
once = p + tp.strip_prefix('비토 문턱값 변경(감소) Yeong-Gwang site')
twice = tp.prefix_for(4385) + tp.strip_prefix(once)
assert once == twice and once.count('비토') == 1, (once, twice)
assert tp.classify([1,1,1,1], [2,2,0,0]) == '변경' and tp.classify(None, [1]) == '' and tp.classify([1],[1]) == ''
PY

python3 - "$DIR" <<'PY' && ok "직전 런을 못 읽으면 None (eligible 의 4379 없음) · 이번 런 없으면 None · 직전 런 없으면 ''" || bad "unknown"
import sys; sys.path.insert(0, sys.argv[1] + '/tools/sheetlog'); import thr_prefix as tp
t = tp.load_table()
assert tp.describe(4381, t, eligible={4379, 4381})[0] is None
assert tp.describe(4388, t, eligible={4387, 4388})[0] is None
assert tp.describe(4381, t, eligible={4381})[0] == ''
assert tp.describe(4385, t, eligible={4383, 4385})[0].startswith('비토 문턱값 변경(감소) [')
assert tp.prefix_for(4388, t, eligible={4387, 4388}) == ''
PY

# ---- [3] append_runs --update-desc ours --sheet-tsv (구글 무접촉) ----
python3 - "$T/sheet.tsv" <<'PY'
import sys
rows = [['RENE Offline', '', ''], ['Run', 'Max subrun', 'Description'],
        ['4246', '1', '비토 문턱값 변경(증가) 남의 행'],           # 남의 행 : 절대 안 건드린다
        ['4383', '9', 'site A'],
        ['4385', '9', '비토 문턱값 변경(감소) site A'],             # 옛 형식 → 새 형식으로
        ['4386', '9', 'site A'],
        ['4387', '9', '비토 문턱값 변경(증가) [VETO_test_9layers_v2_mid3_pidfix.config: 18ch 변경 → 266 201 131 300 146 150 234 289 120 160 268 210 206 164 298 179 160 172 off×12 (이전 100×18 off×12); PID 순서 변경] site A'],
        ['4390', '9', '비토 문턱값 변경(감소) 사본 없는 런']]      # 판정 불가 → 그대로
open(sys.argv[1], 'w').write('\n'.join('\t'.join(r) for r in rows) + '\n')
PY
OUT=$(python3 "$DIR/tools/sheetlog/append_runs.py" --sheet-tsv "$T/sheet.tsv" --update-desc ours --full 2>&1)
echo "$OUT" | grep -q 'run 4246' && bad "남의 행이 계획에 들어갔다" "$(echo "$OUT" | grep 4246)" || ok "ours : 남의 행 4246 은 대상이 아니다"
echo "$OUT" | grep -qF '후 : 비토 문턱값 변경(감소) [VETO_test_9layers_v2_mid3_mthrsm16_ch8thr80.config: ch8(PMT18) 100→80] site A' && ok "4385 옛 문구 → 새 문구 (원래 설명 보존)" || bad "4385" "$(echo "$OUT" | grep -A2 'run 4385')"
echo "$OUT" | grep -q 'run 4387 : 그대로' && ok "이미 새 문구인 4387 은 그대로 (멱등)" || bad "4387" "$(echo "$OUT" | grep 4387)"
echo "$OUT" | grep -q 'run 4390 : 판정 불가, 그대로 둔다' && ok "사본 없는 4390 은 판정 불가로 건너뜀 (옛 문구를 지우지 않음)" || bad "4390" "$(echo "$OUT" | grep 4390)"
echo "$OUT" | grep -q 'run 4383 : 판정 불가.*직전 런 4246' && ok "4383 의 시트 직전 런 4246 을 못 읽으면 건너뜀 (시트의 직전 런으로 비교한다)" || bad "4383" "$(echo "$OUT" | grep 4383)"
echo "$OUT" | grep -q '미리보기다' && ok "--sheet-tsv 는 미리보기로 끝난다" || bad "미리보기"
python3 "$DIR/tools/sheetlog/append_runs.py" --sheet-tsv "$T/sheet.tsv" --update-desc ours --commit >/dev/null 2>&1 \
   && bad "--sheet-tsv --commit 이 막히지 않았다" || ok "--sheet-tsv 와 --commit 은 함께 못 쓴다"

python3 - "$DIR" "$T" <<'PY' && ok "describe(allow_scan=False) 는 PRD 스캔을 부르지 않는다 · 미리보기(--commit 없음)도" || bad "allow_scan"
import sys, io, contextlib; sys.path.insert(0, sys.argv[1] + '/tools/sheetlog'); import thr_prefix as tp
def boom(*a, **k): raise AssertionError('scan_run called')
tp.scan_run = boom
assert tp.describe(4390, tp.load_table(), eligible={4387, 4390}, allow_scan=False)[0] is None
import append_runs as ar
sys.argv = ['append_runs.py', '--sheet-tsv', sys.argv[2] + '/sheet.tsv', '--update-desc', 'ours']
with contextlib.redirect_stdout(io.StringIO()): ar.main()
assert ar.ALLOW_SCAN is False
PY

# ---- [4] --insert 미리보기도 시트의 직전 런과 비교한다 (리뷰 필수 1) ----
printf 'Run\tMax subrun\tDescription\n4384\t9\tsite A\n4387\t9\tx\n' > "$T/sheet2.tsv"
OUT=$(python3 "$DIR/tools/sheetlog/append_runs.py" --sheet-tsv "$T/sheet2.tsv" --insert 4386 --full 2>&1)
echo "$OUT" | grep -qx '     Description : site A' && ok "--insert 4386 : 시트 직전 런 4384 와 같은 설정 → 문구 없음 (시트 밖 4385 와 비교하지 않는다)" || bad "--insert eligible" "$(echo "$OUT" | grep -E 'Description|run 4386')"
echo "$OUT" | grep -q '미리보기다' && ok "--insert --sheet-tsv 는 미리보기로 끝난다" || bad "insert 미리보기"

# ---- [5] 마운트 안 된 루트 밑의 CONFIG 는 보지 않는다 (리뷰 권고 4) ----
mkdir -p "$T/mnt/CONFIG"; cp "$FX/004385.config" "$FX/004384.config" "$T/mnt/CONFIG/"
OUT=$(THR_TABLE=$T/none.tsv RENE_CONFIG_DIRS=$T/mnt/CONFIG RENE_MOUNT_ROOTS=$T/mnt python3 "$DIR/tools/sheetlog/thr_prefix.py" 4385 2>&1)
OUT2=$(RENE_CONFIG_DIRS=$T/mnt/CONFIG RENE_MOUNT_ROOTS=$T/elsewhere python3 "$DIR/tools/sheetlog/thr_prefix.py" 4385 2>&1)
echo "$OUT" | grep -qP '^4385\t\?' && echo "$OUT2" | grep -qP '^4385\t비토 문턱값 변경\(감소\)' && ok "미마운트 루트 밑 CONFIG 는 건너뛴다 · 마운트 대상이 아니면 그대로 읽는다" || bad "mount guard" "$OUT / $OUT2"

echo; echo "PASS $PASS  FAIL $FAIL"; [ "$FAIL" -eq 0 ]
