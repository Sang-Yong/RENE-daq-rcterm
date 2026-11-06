#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  badrun.sh 의 꼬리 '열리지만 사건 0' 판정 시험 (2026-11-06)
#     꼬리 서브런(FADC 번호 최대)의 SADC 또는 FADC 가 AbsEvent 0 사건이면 bad_raw (격리 대상)
#     꼬리가 아닌 서브런은 예전 그대로 (열리면 gap)
#  ★ 실물 사본(tests/fixtures/badrun-tail, run 4392 의 꼬리 짝)만 쓴다. 실데이터·DB·운영 목록 무접촉.
#    ROOT 가 필요하다 (없으면 건너뛴다).
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
BR=${BADRUN_UNDER_TEST:-$DIR/scripts/badrun.sh}   # 옛 판과 비교할 때 갈아끼운다
FX=$DIR/tests/fixtures/badrun-tail
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

command -v root >/dev/null 2>&1 || { [ -f /usr/local/bin/thisroot.sh ] && . /usr/local/bin/thisroot.sh; }
command -v root >/dev/null 2>&1 || { echo "ROOT 가 없어 건너뛴다"; echo "결과 : 0 통과 / 0 실패 (건너뜀)"; exit 0; }

GOOD=$FX/FADC_004392.root.00962       # 100 사건 -- '정상' 서브런 대역으로 쓴다
ZERO=$FX/SADC_004392.root.00962       # 0 사건
export BACKUP_DBFILE=$T/none.db BADRUN_LIST=$T/badrun_list.txt BADRUN_EXPORT=$T/BADRUNS.md BADRUN_HB=/dev/null

mkrun() {   # run  tail_sadc(GOOD|ZERO)  [mid_sadc]   서브런 0..3, PRD 는 0..1 만
   local rp; rp=$(printf '%06d' "$1"); local d=$T/RAW/$rp
   rm -rf "$d"; mkdir -p "$d/PRD" "$d/Merged"
   for s in 00000 00001 00002 00003; do cp "$GOOD" "$d/FADC_$rp.root.$s"; cp "$GOOD" "$d/SADC_$rp.root.$s"; done
   [ "$2" = ZERO ] && cp "$ZERO" "$d/SADC_$rp.root.00003"
   [ "${3:-}" = ZERO ] && cp "$ZERO" "$d/SADC_$rp.root.00002"
   for s in 00000 00001; do echo x > "$d/PRD/PRD_$rp.$s.root"; echo x > "$d/Merged/MERGED_$rp.root.$s"; done
}
scan() { "$BR" --scan --run "$1" --roots "$T/RAW" 2>&1; }

echo "[1] 꼬리 SADC 0 사건 -> 격리 대상"
mkrun 9101 ZERO
o=$(scan 9101); echo "$o" | sed 's/^/      /' | tail -4
check "truncated_tail 로 분류"        'echo "$o" | grep -q "9101 *truncated_tail"'
check "꼬리 사건 0 이 메모에"          'echo "$o" | grep -q "꼬리가 열리지만 사건 0"'
check "앞 서브런 00002 는 gap 그대로" 'echo "$o" | grep -q "00002.* 은 원본이 멀쩡하다"'

echo "[2] 꼬리가 정상 -> 예전 그대로 prd_gap"
mkrun 9102 GOOD
o=$(scan 9102)
check "prd_gap"                       'echo "$o" | grep -q "9102 *prd_gap"'
check "truncated_tail 아님"           '! echo "$o" | grep -q "9102 *truncated"'

echo "[3] 꼬리가 아닌 서브런의 SADC 0 사건 -> 바꾸지 않는다 (gap)"
mkrun 9103 GOOD ZERO
o=$(scan 9103)
check "prd_gap 그대로"                'echo "$o" | grep -q "9103 *prd_gap"'

echo "[4] --quarantine : 꼬리 짝만 badrun/ 으로"
mkrun 9104 ZERO
"$BR" --quarantine --run 9104 --roots "$T/RAW" >/dev/null 2>&1
d=$T/RAW/009104
check "FADC 00003 격리"               '[ -f "$d/badrun/FADC_009104.root.00003" ] && [ ! -e "$d/FADC_009104.root.00003" ]'
check "SADC 00003 격리"               '[ -f "$d/badrun/SADC_009104.root.00003" ]'
check "00002 는 그대로"               '[ -f "$d/FADC_009104.root.00002" ] && [ ! -e "$d/badrun/FADC_009104.root.00002" ]'
check "README 에 사건 0 사유"         'grep -q "사건 0" "$d/badrun/README.txt"'
check "목록에 truncated_tail"         'grep -q "9104 .*truncated_tail" "$T/badrun_list.txt"'

echo "[5] --quarantine --dry-run 은 아무것도 안 옮긴다"
mkrun 9105 ZERO
"$BR" --quarantine --run 9105 --roots "$T/RAW" --dry-run >/dev/null 2>&1
check "격리 안 됨"                    '[ ! -d "$T/RAW/009105/badrun" ] && [ -f "$T/RAW/009105/SADC_009105.root.00003" ]'

echo
echo "결과 : $PASS 통과 / $FAIL 실패"
[ "$FAIL" -eq 0 ]
