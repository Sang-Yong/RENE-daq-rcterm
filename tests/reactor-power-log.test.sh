#!/usr/bin/env bash
# reactor-power-log -- KHNP 호기별 출력 기록기 시험. 망·구글·메일에 닿지 않는다 (fixture JSON · TSV 시트 · 가짜 send_mail).
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
PY=$DIR/tools/reactor/reactor_power_log.py
SH=$DIR/scripts/reactor-power-log.sh
FX=$DIR/tests/fixtures/khnp_hanbit_20260915.json
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ $# -gt 1 ] && echo "       $2"; }
cat > "$T/mail.py" <<'EOF'
#!/usr/bin/env python3
import sys, os
a = sys.argv; sub = a[a.index('--subject') + 1] if '--subject' in a else ''
body = open(a[a.index('--body-file') + 1]).read() if '--body-file' in a else ''
open(os.environ['FAKE_MAIL_LOG'], 'a').write('SUBJECT ' + sub + '\n' + body + '\n---\n')
EOF
run() {  # run <logdir> <now> [extra py args]
   local d=$1 n=$2; shift 2
   REACTOR_LOG_DIR="$d" REACTOR_NET_CHECK=0 REACTOR_MAIL="$T/mail.py" FAKE_MAIL_LOG="$d/mail.log" \
      REACTOR_PY_ARGS="--fixture $FX --sheet-tsv $d/sheet.tsv --now ${n// /T} $*" bash "$SH" > "$d/run.out" 2>&1; echo $?
}
# ① 한 시간 행 : 26 열, 열출력 = 4 호기 × 2815, 기대 IBD 0.345
mkdir -p "$T/a"; rc=$(run "$T/a" '2026-09-15 18:47')
[ "$rc" = 0 ] && ok "첫 기록 rc=0" || bad "rc=$rc" "$(cat "$T/a/run.out")"
ROW=$(awk -F'\t' 'NR==2' "$T/a/reactor_power.tsv"); NF=$(awk -F'\t' 'NR==2{print NF}' "$T/a/reactor_power.tsv")
[ "$NF" = 26 ] && ok "26 열" || bad "열 수 $NF"
echo "$ROW" | awk -F'\t' '{exit !($21==11260 && $24=="0.345" && $25=="0.199" && $3=="정지" && $9=="운전" && $10=="100.0" && $11==1040)}' && ok "열출력 11,260 MW(4 호기 × 2,815) · 기대 IBD 0.345 · 창 0.199 · 1 호기 정지 · 3 호기 운전 100 % 1,040 MW" || bad "행 값" "$ROW"
echo "$ROW" | awk -F'\t' '{exit !($22>=11200 && $22<=11300)}' && ok "발전기 환산 열출력이 % 기준과 1 % 안 ($(echo "$ROW" | cut -f22))" || bad "발전기 환산" "$(echo "$ROW" | cut -f22)"
diff <(tail -n +2 "$T/a/reactor_power.tsv") <(tail -n +2 "$T/a/sheet.tsv") >/dev/null && ok "시트(TSV 대역) = 로컬 TSV" || bad "시트 불일치"
grep -q 'fails=0' "$T/a/reactor-power-log.state" && ok "상태 fails=0" || bad "상태" "$(cat "$T/a/reactor-power-log.state")"
# ② 날짜가 바뀐 첫 기록에 지난 날짜의 일일 행이 생기고, 시트에도 붙는다. 두 번째 돌려도 일일 행은 하나
run "$T/a" '2026-09-15 19:47' >/dev/null; run "$T/a" '2026-09-16 00:47' >/dev/null; run "$T/a" '2026-09-16 01:47' >/dev/null
ND=$(awk -F'\t' '$2=="day"' "$T/a/reactor_power.tsv" | wc -l); NDS=$(awk -F'\t' '$2=="day"' "$T/a/sheet.tsv" | wc -l)
[ "$ND" = 1 ] && [ "$NDS" = 1 ] && ok "일일 행 하나 (로컬·시트)" || bad "일일 행 $ND/$NDS"
awk -F'\t' '$2=="day"{exit !($1=="2026-09-15 00:00" && $9=="운전 2/2h" && $21==11260)}' "$T/a/reactor_power.tsv" && ok "일일 행 = 09-15 두 시간 평균 (운전 2/2h, 11,260 MW)" || bad "일일 행 내용" "$(awk -F'\t' '$2=="day"' "$T/a/reactor_power.tsv")"
[ "$(tail -n +2 "$T/a/sheet.tsv" | wc -l)" = 5 ] && ok "시트 5 행 (시간 4 + 일 1)" || bad "시트 행 수 $(tail -n +2 "$T/a/sheet.tsv" | wc -l)"
# ③ --dry-run 은 아무것도 안 쓴다
mkdir -p "$T/b"; REACTOR_LOG_DIR="$T/b" REACTOR_NET_CHECK=0 REACTOR_PY_ARGS="--fixture $FX --sheet-tsv $T/b/sheet.tsv" bash "$SH" --dry-run > "$T/b/out" 2>&1
[ ! -f "$T/b/reactor_power.tsv" ] && [ ! -f "$T/b/sheet.tsv" ] && grep -q '미리보기' "$T/b/out" && ok "--dry-run : 읽기만" || bad "dry-run 이 썼다" "$(ls "$T/b"; cat "$T/b/out")"
# ④ KHNP 실패 : 1 회는 조용, 2 회째 메일, 다시 성공하면 복구 메일. 시트가 막힌 동안 빠진 행은 다음 성공 때 메워진다
mkdir -p "$T/c"; : > "$T/c/mail.log"
rc1=$(run "$T/c" '2026-09-15 10:47' --fixture /nonexistent.json); rc2=$(run "$T/c" '2026-09-15 11:47' --fixture /nonexistent.json)
NM=$(grep -c '^SUBJECT' "$T/c/mail.log")
[ "$rc1" = 2 ] && [ "$rc2" = 2 ] && [ "$NM" = 1 ] && grep -q '연속 2 회' "$T/c/mail.log" && ok "KHNP 실패 : rc=2, 두 번째에 메일 한 통" || bad "실패 경로" "rc $rc1/$rc2 mail $NM: $(cat "$T/c/mail.log")"
run "$T/c" '2026-09-15 12:47' --fixture /nonexistent.json >/dev/null
[ "$(grep -c '^SUBJECT' "$T/c/mail.log")" = 1 ] && ok "같은 사유 세 번째는 메일 생략 (간격 6 h)" || bad "메일 중복"
rc3=$(run "$T/c" '2026-09-15 13:47')
[ "$rc3" = 0 ] && [ "$(grep -c '^SUBJECT 원자로 출력 기록 복구' "$T/c/mail.log")" = 1 ] && grep -q 'fails=0' "$T/c/reactor-power-log.state" && ok "복구 : rc=0 + 복구 메일 + fails=0" || bad "복구" "$(cat "$T/c/mail.log" "$T/c/reactor-power-log.state")"
# ⑤ 시트가 막혀도 로컬 TSV 는 쓰고 rc=3, 시트가 돌아오면 빠진 행을 메운다
mkdir -p "$T/d/ro"; chmod 555 "$T/d/ro"
rc4=$(run "$T/d" '2026-09-15 10:47' --sheet-tsv "$T/d/ro/sheet.tsv"); rc5=$(run "$T/d" '2026-09-15 11:47' --sheet-tsv "$T/d/ro/sheet.tsv")
chmod 755 "$T/d/ro"; rc6=$(run "$T/d" '2026-09-15 12:47' --sheet-tsv "$T/d/ro/sheet.tsv")
NL=$(tail -n +2 "$T/d/reactor_power.tsv" | wc -l); NS=$(tail -n +2 "$T/d/ro/sheet.tsv" 2>/dev/null | wc -l)
[ "$rc4" = 3 ] && [ "$rc5" = 3 ] && [ "$rc6" = 0 ] && [ "$NL" = 3 ] && [ "$NS" = 3 ] && ok "시트 실패 rc=3 (로컬 3 행) → 복구 때 시트 3 행으로 메움" || bad "시트 복구" "rc $rc4/$rc5/$rc6 local $NL sheet $NS"
# ⑥ 잠금 : 두 벌이 겹치면 둘째는 SKIP
mkdir -p "$T/e"; exec 8>"$T/e/.lock"; flock 8
REACTOR_LOG_DIR="$T/e" REACTOR_NET_CHECK=0 REACTOR_PY_ARGS="--fixture $FX --sheet-tsv $T/e/sheet.tsv" bash "$SH" > "$T/e/out" 2>&1; exec 8>&-
grep -q 'SKIP' "$T/e/reactor-power-log.log" && [ ! -f "$T/e/reactor_power.tsv" ] && ok "잠금이 걸려 있으면 SKIP" || bad "잠금" "$(cat "$T/e/reactor-power-log.log")"
# ⑦ --status 가 읽기 전용으로 돈다
REACTOR_LOG_DIR="$T/a" bash "$SH" --status > "$T/a/status" 2>&1 && grep -q 'fails=0' "$T/a/status" && grep -q '2026-09-16 01:47' "$T/a/status" && ok "--status" || bad "--status" "$(cat "$T/a/status")"
# ⑧ cron 환경 (env -i)
mkdir -p "$T/f"; env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$HOME" REACTOR_LOG_DIR="$T/f" REACTOR_NET_CHECK=0 REACTOR_PY_ARGS="--fixture $FX --sheet-tsv $T/f/sheet.tsv" bash "$SH" > "$T/f/out" 2>&1
[ -s "$T/f/reactor_power.tsv" ] && ok "cron 환경(env -i)에서 기록" || bad "cron 환경" "$(cat "$T/f/out")"
echo; echo "PASS $PASS  FAIL $FAIL"; [ "$FAIL" -eq 0 ]
