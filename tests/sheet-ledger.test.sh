#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  sheet-ledger.test.sh -- 시트 로컬 원장 (2026-11-09 "로컬을 우선으로 먼저 등재 · 망이 되면 로컬 기준으로 동기화")
#
#  ★ 구글 · 실메일 · 운영 원장(/Data_ssd/LOG/sheetledger) · 운영 DB 무접촉.
#    시트 = RENE_SHEET_FAKE_DIR 의 TSV (sheet_ledger.TsvSheet), 망 단절 = RENE_SHEET_FAKE_NET=down.
#    픽스처의 시트 행은 실물 백업에서 복사했다 (tests/fixtures/sheet_*.tsv -- Y2026B 11-08 16:01 삭제 직전,
#    back_up_hdd_log 10-21, DAQ_runsummary 11-08). 날짜 '2026. 11. 08' · 시각 '9:19' 처럼 시트가 바꿔 보이는 모양 그대로.
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
LED=$DIR/tools/sheetlog/sheet_ledger.py
AR=$DIR/tools/sheetlog/append_runs.py
AB=$DIR/tools/sheetlog/append_backup_rows.py
PG=$DIR/tools/monitor/publish_google.py
RP=$DIR/tools/reactor/reactor_power_log.py
FX=$DIR/tests/fixtures
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PROD_BEFORE=$(ls -l --time-style=+%s /Data_ssd/LOG/sheetledger 2>&1 | md5sum)
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ $# -gt 1 ] && echo "       $2"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

export RENE_SHEET_LEDGER_DIR=$T/led RENE_SHEET_FAKE_DIR=$T/fake RENE_SHEET_BACKUP_DIR=$T/bak \
       DRILL_FLAG=$T/drill.active RENE_RUNDB=$T/run.db RENE_RAW_ROOTS=$T/RAW THR_TABLE=$T/thr.tsv \
       RENE_CONFIG_DIRS=$T/cfg RENE_MOUNT_ROOTS=$T/nomount REACTOR_LOG_DIR=$T/reactor \
       BACKUP_DISKS_TSV=$T/disks.tsv BACKUP_DISKS_MD=$T/disks.md PYTHONWARNINGS=ignore
unset RENE_SHEET_FAKE_NET RENE_SHEET_FAKE_CORRUPT
mkdir -p "$T/fake" "$T/RAW" "$T/cfg"
cp "$FX/sheet_y2026b_20261108.tsv" "$T/fake/Y2026B.tsv"
SH=$T/fake/Y2026B.tsv
L=$T/led/Y2026B.tsv
st() { python3 - "$1" "$2" <<'PY'                     # st <탭> <키> -> 원장의 그 행 _state
import sys, os; sys.path.insert(0, os.environ['LEDDIR'])
import sheet_ledger as sl
lg = sl.Ledger(sys.argv[1]); r = lg.by_key().get(sys.argv[2]); print(r["state"] if r else "-")
PY
}
export LEDDIR=$DIR/tools/sheetlog
srow() { awk -F'\t' -v k="$1" '$1==k' "$SH"; }          # 시트의 그 Run 행

#  runcatalog : 실물 열 이름 (stime 은 텍스트, 수집 중 런은 stime NULL)
python3 - "$T/run.db" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("create table runcatalog (runnum integer primary key, stime text, etime text, onlbit integer, runlog text, rundesc text, nfadc integer, tfadc real, config text)")
D = "Yeong-Gwang site at A dong container tent 26.10.15., VETO detector only data taking for MIP, Split T [m] = 1"
for r in [(4440, "2026-11-08 09:19:40", "2026-11-08 09:19:52", 0, "boot failed; run never started", D, None, None, ""),
          (4446, "2026-11-08 15:51:16", "2026-11-08 16:32:21", 1, "", D, 16502368, 2465.0, ""),
          (4447, "2026-11-08 16:32:39", "2026-11-09 16:32:27", 1, "", D, 581000000, 86380.0, "")]:
    db.execute("insert into runcatalog values (?,?,?,?,?,?,?,?,?)", r)
db.commit()
PY
for r in 004446 004447; do mkdir -p "$T/RAW/$r"; for i in 00000 00001; do head -c 1000 /dev/zero > "$T/RAW/$r/FADC_$r.root.$i"; done; done
adddb() { python3 -c "import sqlite3,sys; db=sqlite3.connect('$T/run.db'); db.execute(\"insert into runcatalog values ($1,'2026-11-10 16:33:00','2026-11-11 16:32:00',1,'','desc $1',1000,100.0,'')\"); db.commit()"
          mkdir -p "$T/RAW/00$1"; head -c 1000 /dev/zero > "$T/RAW/00$1/FADC_00$1.root.00000"; }
ar() { (cd "$DIR" && python3 "$AR" "$@") > "$T/ar.out" 2>&1; echo $?; }

echo "[1] 첫 등재 (망 있음) : 원장 씨앗(시트 거울) + 새 런 2 개 -> 원장에 먼저, 시트 끝 행 다음에"
rc=$(ar --commit)
check "rc 0"                               '[ "$rc" = 0 ]' "$(tail -5 "$T/ar.out")"
check "[LOCAL] 줄이 '기록함' 보다 먼저"     '[ "$(grep -n "^\[LOCAL\]" "$T/ar.out" | cut -d: -f1)" -lt "$(grep -n "^기록함" "$T/ar.out" | cut -d: -f1)" ]'
check "시트에 A9:S10 (8 행 다음)"          'grep -q "^기록함 : A9:S10  (2행)" "$T/ar.out"'
check "시트 끝 두 행 = 4446 4447"           '[ "$(tail -2 "$SH" | cut -f1 | tr "\n" " ")" = "4446 4447 " ]'
check "남의 행(3785) 은 원장에 foreign"     '[ "$(st Y2026B 3785)" = foreign ]'
check "우리 행(4439) 은 sent · 새 행 sent"  '[ "$(st Y2026B 4439)" = sent ] && [ "$(st Y2026B 4447)" = sent ]'
check "실패 런 4440(onlbit 0) 은 없다"     '! grep -q "^4440" "$SH" && [ "$(st Y2026B 4440)" = - ]'
check "양식 열은 직전 행(4439)에서 : Full 1680 1642" 'srow 4446 | awk -F"\t" "{exit !(\$9==\"Full\" && \$11==1680 && \$12==1642 && \$17==\"1x2\")}"'
check "앞 8 행 바이트 그대로"               '[ "$(head -8 "$SH" | md5sum)" = "$(md5sum < "$FX/sheet_y2026b_20261108.tsv")" ]'
check "쓰기 전 시트 백업"                   'ls "$T/bak"/Y2026B-before-*.tsv >/dev/null 2>&1'

echo "[2] 멱등 : 다시 돌려도 시트 행 수 그대로"
rc=$(ar --commit)
check "rc 0 · 추가할 런 없음"              '[ "$rc" = 0 ] && grep -q "추가할 런이 없다" "$T/ar.out"'
check "시트 10 행"                          '[ "$(wc -l < "$SH")" = 10 ]'

echo "[3] 망 단절 : 원장에만 등재 (rc 0, 보류), 시트는 그대로. 두 번 돌려도 원장에 한 번"
adddb 4448; cp "$SH" "$T/sheet.before"
rc=$(RENE_SHEET_FAKE_NET=down ar --commit)
check "rc 0"                               '[ "$rc" = 0 ]' "$(tail -6 "$T/ar.out")"
check "[LOCAL] + [SHEET] 보류 (망 없음)"    'grep -q "^\[LOCAL\] Y2026B : 원장에 새로 1" "$T/ar.out" && grep -q "^\[SHEET\] Y2026B : 보류 1 행 -- 망 없음 (rc 5)" "$T/ar.out"'
check "원장 4448 pending · 시트 그대로"     '[ "$(st Y2026B 4448)" = pending ] && cmp -s "$SH" "$T/sheet.before"'
rc=$(RENE_SHEET_FAKE_NET=down ar --commit)
check "두 번째 : 추가할 런 없음 (원장 기준) · 원장에 4448 한 행" '[ "$rc" = 0 ] && grep -q "추가할 런이 없다" "$T/ar.out" && [ "$(awk -F"\t" "\$1==4448" "$L" | wc -l)" = 1 ]'
rc=$(ar --offline)
check "--offline 미리보기도 원장 기준"      '[ "$rc" = 0 ] && grep -q "원장 pending (시트에 아직 안 간 것) : 1 행 \[4448\]" "$T/ar.out"'

echo "[4] --status 와 --flush --dry-run 은 아무것도 안 바꾼다"
cp "$L" "$T/led.before"
out=$(python3 "$LED" --status --tab Y2026B 2>&1)
check "--status : pending 1"                'printf "%s" "$out" | grep -q "Y2026B           pending 1 · sent 6 · foreign 3"' "$out"
python3 "$LED" --flush --dry-run --tab Y2026B >/dev/null 2>&1
check "--flush --dry-run : 시트·원장 그대로" 'cmp -s "$SH" "$T/sheet.before" && cmp -s "$L" "$T/led.before"'
RENE_SHEET_FAKE_NET=down python3 "$LED" --flush --tab Y2026B >/dev/null 2>&1; rc=$?
check "망 없이 --flush : rc 5 · 그대로"      '[ "$rc" = 5 ] && cmp -s "$SH" "$T/sheet.before" && [ "$(st Y2026B 4448)" = pending ]'

echo "[5] 망 복귀 --flush : 원장 pending 이 시트로, sent"
python3 "$LED" --flush --tab Y2026B > "$T/fl.out" 2>&1; rc=$?
check "rc 0 · A11"                          '[ "$rc" = 0 ] && grep -q "^기록함 : A11:S11  (1행)" "$T/fl.out"' "$(cat "$T/fl.out")"
check "시트 끝 = 4448 · 원장 sent"          '[ "$(tail -1 "$SH" | cut -f1)" = 4448 ] && [ "$(st Y2026B 4448)" = sent ]'
python3 "$LED" --flush --tab Y2026B > "$T/fl.out" 2>&1
check "다시 flush : pending 0 · 시트 그대로" 'grep -q "\[OK\] Y2026B : pending 0" "$T/fl.out" && [ "$(wc -l < "$SH")" = 11 ]'

echo "[6] 로컬이 정본 : pending 인 우리 행이 시트와 다르면 그 칸을 원장 값으로 고친다 (양식 열은 사람 몫이라 둔다)"
#  시트 쪽 4448 의 Description 을 누가 지우고 Detector 를 고쳤다 + 원장 쪽은 Description 을 고친 pending
python3 - "$SH" <<'PY'
import sys; p = sys.argv[1]; L = open(p, encoding="utf-8").read().split("\n")
for i, l in enumerate(L):
    f = l.split("\t")
    if f[0] == "4448":
        f[17] = "WRONG"; f[8] = "UserEdit"; L[i] = "\t".join(f)
open(p, "w", encoding="utf-8").write("\n".join(L))
PY
python3 - <<'PY'
import sys, os; sys.path.insert(0, os.environ["LEDDIR"]); import sheet_ledger as sl
lg = sl.Ledger("Y2026B")
with lg.locked():
    r = lg.by_key()["4448"]; v = list(r["vals"]); v[17] = "desc 4448 (local)"; lg.append([v], mode="upsert"); lg.save()
PY
check "원장 4448 pending (upsert)"           '[ "$(st Y2026B 4448)" = pending ]'
python3 "$LED" --flush --tab Y2026B > "$T/fl.out" 2>&1; rc=$?
check "rc 0 · 우리 행 1 개의 칸을 고침"      '[ "$rc" = 0 ] && grep -q "우리 행 1 개의 1 칸을 원장 값으로 고침" "$T/fl.out"' "$(cat "$T/fl.out")"
check "Description = 원장 값"               'srow 4448 | awk -F"\t" "{exit !(\$18==\"desc 4448 (local)\")}"'
check "Detector(양식 열) 는 사람 값 그대로"  'srow 4448 | awk -F"\t" "{exit !(\$9==\"UserEdit\")}"'
check "행 수 그대로 · sent"                  '[ "$(wc -l < "$SH")" = 11 ] && [ "$(st Y2026B 4448)" = sent ]'
check "그 뒤 pull 로 원장도 사람 값을 받는다" '[ "$(awk -F"\t" "\$1==4448{print \$9}" "$L")" = UserEdit ]'

echo "[7] 남의 행 : 같은 키가 남의 행이면 시트를 건드리지 않고 failed:foreign"
cp "$SH" "$T/sheet.before"
python3 - <<'PY'
import sys, os; sys.path.insert(0, os.environ["LEDDIR"]); import sheet_ledger as sl
lg = sl.Ledger("Y2026B")
with lg.locked():
    r = lg.by_key()["3805"]; r["state"] = "pending"; r["vals"][17] = "OURS?"; lg.save()
PY
python3 "$LED" --flush --tab Y2026B > "$T/fl.out" 2>&1; rc=$?
check "rc 0 · 시트 그대로"                  '[ "$rc" = 0 ] && cmp -s "$SH" "$T/sheet.before"' "$(cat "$T/fl.out")"
check "3805 failed · 사유 foreign"          '[ "$(st Y2026B 3805)" = failed ] && grep -q "3805.*failed.*foreign" "$L"'
check "upsert 는 foreign 행을 바꾸지 않는다" 'python3 -c "
import sys,os; sys.path.insert(0,os.environ[\"LEDDIR\"]); import sheet_ledger as sl
lg=sl.Ledger(\"Y2026B\"); r=lg.by_key()[\"3785\"]; v=list(r[\"vals\"]); v[17]=\"X\"
print(lg.append([v], mode=\"upsert\"))" | grep -qx "(0, 0, 1)"'

echo "[8] 시트에 이미 같은 값이 있으면 (쓰다 죽은 뒤) 쓰지 않고 sent"
python3 - <<'PY'
import sys, os; sys.path.insert(0, os.environ["LEDDIR"]); import sheet_ledger as sl
lg = sl.Ledger("Y2026B")
with lg.locked():
    lg.by_key()["4447"]["state"] = "pending"; lg.save()
PY
cp "$SH" "$T/sheet.before"
python3 "$LED" --flush --tab Y2026B > "$T/fl.out" 2>&1
check "시트 그대로 · 4447 sent (already)"   'cmp -s "$SH" "$T/sheet.before" && [ "$(st Y2026B 4447)" = sent ] && grep -q "4447.*already in sheet" "$L"' "$(cat "$T/fl.out")"

echo "[9] 되대조 어긋남 -> rc 3, pending 그대로 (rc 는 append_runs 도 3)"
adddb 4449
rc=$(RENE_SHEET_FAKE_CORRUPT=1 ar --commit)
check "append_runs rc 3 · [LOCAL] 은 됐다"   '[ "$rc" = 3 ] && grep -q "^\[LOCAL\]" "$T/ar.out" && grep -q "되대조 어긋남" "$T/ar.out"' "$(tail -4 "$T/ar.out")"
check "4449 pending"                         '[ "$(st Y2026B 4449)" = pending ]'
#  사람이 깨진 줄(4449x)을 지운 뒤 다시 민다
grep -v '^4449x' "$SH" > "$T/s" && cp "$T/s" "$SH"
python3 "$LED" --flush --tab Y2026B >/dev/null 2>&1; rc=$?
check "고친 뒤 flush rc 0 · sent"           '[ "$rc" = 0 ] && [ "$(st Y2026B 4449)" = sent ] && [ "$(tail -1 "$SH" | cut -f1)" = 4449 ]'

echo "[10] 마지막 Run 행 아래에 무엇이 있으면 붙이지 않고 멈춘다 (덮어쓰기 방지)"
adddb 4450; RENE_SHEET_FAKE_NET=down ar --commit >/dev/null
printf '\tnote by someone\n' >> "$SH"; cp "$SH" "$T/sheet.before"
python3 "$LED" --flush --tab Y2026B > "$T/fl.out" 2>&1; rc=$?
check "rc 6 · 시트 그대로 · pending"         '[ "$rc" = 6 ] && cmp -s "$SH" "$T/sheet.before" && [ "$(st Y2026B 4450)" = pending ] && grep -q "멈춤" "$T/fl.out"' "$(cat "$T/fl.out")"
head -n -1 "$SH" > "$T/s" && cp "$T/s" "$SH"; python3 "$LED" --flush --tab Y2026B >/dev/null 2>&1

echo "[11] 사람이 시트에서 지운 우리 행은 removed -- 다시 싣지 않는다"
grep -v '^4450	' "$SH" > "$T/s" && cp "$T/s" "$SH"
rc=$(ar --commit)
check "다시 안 실림 (마지막 Run 은 원장 기준 4450)" '! grep -q "^4450	" "$SH" && grep -q "추가할 런이 없다" "$T/ar.out" && grep -q "마지막 작성 : Run 4450 (원장, 상태 removed)" "$T/ar.out"' "$(tail -4 "$T/ar.out")"
python3 "$LED" --pull --tab Y2026B >/dev/null 2>&1
check "--pull 이 원장에 removed 로 남긴다"   '[ "$(st Y2026B 4450)" = removed ]'

echo "[12] 드릴 중이면 원장에만 적고 시트에 밀지 않는다 (§11.229)"
pst() { awk '{ sub(/.*\) /, ""); print $20 }' "/proc/$1/stat"; }
printf 'pid=%s\npstart=%s\nplan=offline-full\n' "$$" "$(pst $$)" > "$DRILL_FLAG"
adddb 4451; cp "$SH" "$T/sheet.before"
rc=$(ar --commit)
check "rc 0 · [SKIP] 드릴 · 시트 그대로"     '[ "$rc" = 0 ] && grep -q "\[SKIP\] Y2026B : 드릴 중" "$T/ar.out" && cmp -s "$SH" "$T/sheet.before" && [ "$(st Y2026B 4451)" = pending ]'
python3 "$LED" --flush --tab Y2026B > "$T/fl.out" 2>&1
check "--flush 도 건너뛴다"                   'grep -q "드릴 중" "$T/fl.out" && cmp -s "$SH" "$T/sheet.before"'
rm -f "$DRILL_FLAG"; python3 "$LED" --flush --tab Y2026B >/dev/null 2>&1
check "드릴이 끝나면 민다"                    '[ "$(st Y2026B 4451)" = sent ]'

echo "[13] 원장이 비어 있고 망도 없으면 아무것도 안 만든다 (rc 5)"
rc=$(RENE_SHEET_LEDGER_DIR=$T/led-empty RENE_SHEET_FAKE_NET=down ar --commit)
check "rc 5 · 원장 디렉터리 없음"           '[ "$rc" = 5 ] && [ ! -e "$T/led-empty" ]' "$(tail -3 "$T/ar.out")"

echo "[14] back_up_hdd_log : 망 없이 등재 -> 원장 pending, 망 복귀 flush -> 시트 (No 는 원장 기준으로 이어진다)"
cp "$FX/sheet_backup_hdd_log_20261021.tsv" "$T/fake/back_up_hdd_log.tsv"; BS=$T/fake/back_up_hdd_log.tsv
printf '002938\tU-A\t2026-10-21 12:00:00\t60\t35000000000\tPNG/a.png\tPRD/Run002938_DLY_THR.log\tfull\t/backup_hdd_2\tST2000DM006-2DM164\tZ4ZCA14T\t1953514584\tprd\n' > "$T/index"
(cd "$DIR" && python3 "$AB" --index "$T/index" --commit) > "$T/ab.out" 2>&1; rc=$?
check "망 있음 첫 등재 : rc 0 · 시트 끝 No 2274" '[ "$rc" = 0 ] && [ "$(tail -1 "$BS" | cut -f1,4)" = "2274	002938" ]' "$(tail -5 "$T/ab.out")"
printf '002939\tU-A\t2026-10-21 13:00:00\t61\t35000000000\tPNG/a.png\tPRD/Run002939_DLY_THR.log\tfull\t/backup_hdd_2\tST2000DM006-2DM164\tZ4ZCA14T\t1953514584\tprd\n' >> "$T/index"
cp "$BS" "$T/bs.before"
(cd "$DIR" && RENE_SHEET_FAKE_NET=down python3 "$AB" --index "$T/index" --commit) > "$T/ab.out" 2>&1; rc=$?
check "망 없음 : rc 0 · 새 행 1 · 시트 그대로" '[ "$rc" = 0 ] && grep -q "새 행 1" "$T/ab.out" && cmp -s "$BS" "$T/bs.before" && grep -q "보류 1 행 -- 망 없음" "$T/ab.out"' "$(tail -5 "$T/ab.out")"
(cd "$DIR" && RENE_SHEET_FAKE_NET=down python3 "$AB" --index "$T/index" --commit) > "$T/ab.out" 2>&1
check "망 없음 두 번째 : 새 행 0 (원장 기준 멱등)" 'grep -q "새 행 0" "$T/ab.out"'
python3 "$LED" --flush --tab back_up_hdd_log > "$T/fl.out" 2>&1; rc=$?
check "flush rc 0 · 시트 끝 No 2275 002939"  '[ "$rc" = 0 ] && [ "$(tail -1 "$BS" | cut -f1,4)" = "2275	002939" ] && [ "$(wc -l < "$BS")" = 6 ]' "$(cat "$T/fl.out")"
check "사람 열(Storage Location)은 비워 둔 채" '[ -z "$(tail -1 "$BS" | cut -f24)" ]'

echo "[15] DAQ_runsummary (publish_google.py) : 망 없으면 원장에만, rc 0 · 드라이브 보류"
mkdir -p "$T/ws/web"
cp "$FX/sheet_daq_runsummary_20261108.tsv" "$T/fake/DAQ_runsummary.tsv"
printf '4446\t1762613476\t1762615941\t1762613476\t0\t2465\t0\t2465\t0\t16502368\t0\t0\n' > "$T/ws/run_summary.tsv"
cat > "$T/ws.params" <<EOF
sheet_id = FAKE_SHEET
sheet_gid = 511745186
tsv_dir = $T/ws
webroot = $T/ws/web
start_run = 4280
sheet_ledger_dir = $T/led
sheet_backup_dir = $T/bak
EOF
cp "$T/fake/DAQ_runsummary.tsv" "$T/ds.before"
RENE_SHEET_FAKE_NET=down python3 "$PG" --params "$T/ws.params" > "$T/pg.out" 2>&1; rc=$?
check "rc 0 · [LOCAL] · 보류 · [DRIVE] 보류"  '[ "$rc" = 0 ] && grep -q "^\[LOCAL\] DAQ_runsummary : 원장에 새로 1" "$T/pg.out" && grep -q "^\[DRIVE\] 보류" "$T/pg.out" && cmp -s "$T/fake/DAQ_runsummary.tsv" "$T/ds.before"' "$(cat "$T/pg.out")"
check "원장이 없던 탭도 망 없이 등재된다 (DAQ_runsummary 는 키가 새 런뿐)" '[ "$(st DAQ_runsummary 4446)" = pending ]'
python3 "$LED" --flush > "$T/fl.out" 2>&1; rc=$?
check "전 탭 --flush : rc 0 · 4446 이 시트 끝" '[ "$rc" = 0 ] && [ "$(tail -1 "$T/fake/DAQ_runsummary.tsv" | cut -f1)" = 4446 ] && [ "$(st DAQ_runsummary 4446)" = sent ]' "$(cat "$T/fl.out")"
check "기존 두 행 그대로 (4280 · 4437)"      '[ "$(head -3 "$T/fake/DAQ_runsummary.tsv" | md5sum)" = "$(md5sum < "$FX/sheet_daq_runsummary_20261108.tsv")" ]'
python3 "$PG" --params "$T/ws.params" > "$T/pg.out" 2>&1; rc=$?
check "다시 발행 : 새 행 없음 (insert 만)"    '[ "$rc" = 0 ] && grep -q "^\[SHEET\] 새 행 없음" "$T/pg.out" && [ "$(wc -l < "$T/fake/DAQ_runsummary.tsv")" = 4 ]' "$(cat "$T/pg.out")"
python3 "$PG" --params "$T/ws.params" --dry-run > /dev/null 2>&1; cp "$T/led/DAQ_runsummary.tsv" "$T/d1"
python3 "$PG" --params "$T/ws.params" --dry-run > /dev/null 2>&1
check "--dry-run 은 원장을 안 바꾼다"         'cmp -s "$T/led/DAQ_runsummary.tsv" "$T/d1"'

echo "[16] KHNP_daily_power : 로컬 TSV 가 원장. 망 없으면 rc 0 보류, sheet_ledger --flush 가 메운다"
RF=$FX/khnp_hanbit_20260915.json
python3 "$RP" --commit --fixture "$RF" --log-dir "$T/reactor" --now 2026-09-15T18:47 > "$T/rp.out" 2>&1; rc=$?
check "망 있음 : rc 0 · 시트 1 행"             '[ "$rc" = 0 ] && [ "$(tail -n +2 "$T/fake/KHNP_daily_power.tsv" | wc -l)" = 1 ]' "$(cat "$T/rp.out")"
RENE_SHEET_FAKE_NET=down python3 "$RP" --commit --fixture "$RF" --log-dir "$T/reactor" --now 2026-09-15T19:47 > "$T/rp.out" 2>&1; rc=$?
check "망 없음 : rc 0 (예전엔 3) · [SHEET] 보류" '[ "$rc" = 0 ] && grep -q "\[SHEET\] 보류 -- 망 없음" "$T/rp.out"' "$(cat "$T/rp.out")"
out=$(python3 "$LED" --status --tab KHNP_daily_power 2>&1)
check "--status : 맞추지 않은 것 1"           'printf "%s" "$out" | grep -q "로컬 TSV 2 행 · 시트와 맞추지 않은 것 1"' "$out"
python3 "$LED" --flush --tab KHNP_daily_power > "$T/fl.out" 2>&1; rc=$?
check "--flush : rc 0 · 시트 2 행 = 로컬"      '[ "$rc" = 0 ] && diff <(tail -n +2 "$T/reactor/reactor_power.tsv") <(tail -n +2 "$T/fake/KHNP_daily_power.tsv") >/dev/null' "$(cat "$T/fl.out")"
out=$(python3 "$LED" --status --tab KHNP_daily_power 2>&1)
check "--status : 0"                          'printf "%s" "$out" | grep -q "시트와 맞추지 않은 것 0"' "$out"

echo "[17] cron 환경 (env -i, cd /) : --status · --flush"
out=$(cd / && env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$T" RENE_SHEET_LEDGER_DIR=$T/led RENE_SHEET_FAKE_DIR=$T/fake \
      DRILL_FLAG=$T/none REACTOR_LOG_DIR=$T/reactor python3 "$LED" --status 2>&1); rc=$?
check "--status rc 0 · 네 탭"                  '[ "$rc" = 0 ] && [ "$(printf "%s\n" "$out" | grep -cE "^  (Y2026B|back_up_hdd_log|DAQ_runsummary|KHNP_daily_power) ")" = 4 ]' "$out"
(cd / && env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$T" RENE_SHEET_LEDGER_DIR=$T/led RENE_SHEET_FAKE_DIR=$T/fake \
      DRILL_FLAG=$T/none REACTOR_LOG_DIR=$T/reactor RENE_SHEET_BACKUP_DIR=$T/bak python3 "$LED" --flush >/dev/null 2>&1); rc=$?
check "--flush rc 0"                           '[ "$rc" = 0 ]'

echo "[18] 운영 원장 무접촉"
check "/Data_ssd/LOG/sheetledger 가 시험 전과 같다" '[ "$(ls -l --time-style=+%s /Data_ssd/LOG/sheetledger 2>&1 | md5sum)" = "$PROD_BEFORE" ]'

echo; echo "PASS $PASS  FAIL $FAIL"
[ "$FAIL" -eq 0 ]
