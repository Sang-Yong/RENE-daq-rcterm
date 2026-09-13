#!/usr/bin/env bash
# BuildDaily.C / daily.sh — 날짜 기준 계산 + 스펙트럼. 합성 DST 두 런(자정에 걸침) 으로 :
#   ① 날짜별 라이브타임이 서브런 등분으로 나뉜다 ② 날짜별 IBD/우발 합 = 런별 PairAndCountW 값 (쌍 단위 판본의 동치)
#   ③ 표·스펙트럼·그림 32~40 이 나온다 ④ 배경을 뺀 prompt 스펙트럼 적분 ≈ 심은 신호 수.  ROOT 필요, 실자료 무접촉.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh 2>/dev/null
command -v root >/dev/null 2>&1 || { echo "SKIP monitor-daily : ROOT 없음"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/out/dst"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; [ $# -gt 1 ] && echo "       $2"; }

#  픽스처 : monitor-bg 의 합성 DST 생성기 (신호 500 쌍 + 우발 1000 쌍 + 배경 싱글 + 포화 40). 두 런, 서브런 100 개씩
sed -n '/^cat > "\$T\/mkdst.C" <<'"'"'EOF2'"'"'$/,/^EOF2$/p' "$DIR/tests/monitor-bg.test.sh" | sed '1d;$d' > "$T/mkdst.C"
sed -i "s|TOOLDIR|$DIR/tools/monitor|g; s|i_nsub = 1,|i_nsub = 100,|" "$T/mkdst.C"
for r in 999998 999999; do
   sed "s|OUTDST|$T/out/dst/DST_$r.root|g; s|i_run = 999999|i_run = $r|" "$T/mkdst.C" > "$T/mk_$r.C"
   sed -i "s|void mkdst()|void mk_$r()|" "$T/mk_$r.C"
   root -l -b -q "$T/mk_$r.C+" > "$T/log_$r" 2>&1 || { echo "FAIL fixture $r"; tail -5 "$T/log_$r"; exit 1; }
done
LIVE=$(grep -oE 'live=[0-9]+' "$T/log_999999" | cut -d= -f2)          # 두 런 같다
#  run_summary : 999998 은 2026-09-01 23:00 KST 시작(자정에 걸침), 999999 는 09-03 06:00. span = live
E1=$(date -d '2026-09-01 23:00:00' +%s); E2=$(date -d '2026-09-03 06:00:00' +%s)
printf '# fixture\n#run\tn_subrun\tn_bad\tepoch_start\tepoch_end\twall_s\tspan_s\tlive_s\tdead_s\tn_type1\tn_type2\tn_type3\tsource\n' > "$T/out/run_summary.tsv"
printf '999998\t100\t0\t%s\t%s\t%s\t%s\t%s\t0\t1\t1\t1\tnone\n' "$E1" $((E1+LIVE)) "$LIVE" "$LIVE" "$LIVE" >> "$T/out/run_summary.tsv"
printf '999999\t100\t0\t%s\t%s\t%s\t%s\t%s\t0\t1\t1\t1\tnone\n' "$E2" $((E2+LIVE)) "$LIVE" "$LIVE" "$LIVE" >> "$T/out/run_summary.tsv"
printf '999998\tnone\n999999\tnone\n' > "$T/out/runtype.tsv"

OUT=$(RUNSUM_OUT="$T/out" MONITORCUTS=/nonexistent "$DIR/tools/monitor/daily.sh" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "daily.sh rc=0" || bad "daily.sh rc=$RC" "$(echo "$OUT" | grep -E 'rror|FATAL' | head -3)"
TSV="$T/out/daily_summary.tsv"
[ -s "$TSV" ] && ok "daily_summary.tsv" || bad "표 없음"
ND=$(awk -F'\t' '!/^#/ && $2=="_nGd"' "$TSV" | wc -l)
[ "$ND" -eq 3 ] && ok "n-Gd 날짜 3 개 (09-01 · 09-02 · 09-03 : 첫 런이 자정에 걸친다)" || bad "날짜 수 $ND" "$(awk -F'\t' '!/^#/' "$TSV" | cut -f1-6)"
#  ① 라이브타임 : 두 런 합 = 2·LIVE (±서브런 하나), 09-01 몫은 1 시간(23:00~24:00) 근처
SUM=$(awk -F'\t' '!/^#/ && $2=="_nGd"{s+=$3} END{printf "%d", s}' "$TSV")
awk -v s="$SUM" -v l="$LIVE" 'BEGIN{exit !(s > 2*l-2*l/100-1 && s < 2*l+1)}' && ok "라이브타임 합 = 2 런 ($SUM ≈ $((2*LIVE)))" || bad "라이브타임 합 $SUM (기대 $((2*LIVE)))"
L1=$(awk -F'\t' '!/^#/ && $2=="_nGd" && $1=="2026-09-01"{print int($3)}' "$TSV")
awk -v x="$L1" 'BEGIN{exit !(x > 3000 && x < 4200)}' && ok "09-01 몫 ≈ 1 시간 ($L1 s)" || bad "09-01 몫 $L1 s"
#  ② 날짜별 IBD/우발 합 = 런별 PairAndCountW (같은 컷)
cat > "$T/cnt.C" <<EOF2
#include "$DIR/tools/monitor/ReneDailyCore.h"
void cnt() {
   long long on = 0, off = 0;
   for (int r : {999998, 999999}) {
      std::vector<S1S2_Candidate> s; std::vector<Float_t> p; std::vector<ReneSat> x; std::vector<ReneMuon> m; double l; int n, sc;
      DailyLoadDst(Form("$T/out/dst/DST_%d.root", r), s, p, x, m, l, n, sc);
      SetChannel(CH_NGD); PairCounts c = PairAndCountW(s, CurrentPairWindows());
      on += c.nCoincMult; off += c.nAcciMult;
   }
   printf("COUNT on=%lld off=%lld\n", on, off);
}
EOF2
root -l -b -q "$T/cnt.C+" 2>&1 | grep COUNT > "$T/cnt.txt"
RON=$(sed -n 's/.*on=\([0-9]*\).*/\1/p' "$T/cnt.txt"); ROFF=$(sed -n 's/.*off=\([0-9]*\).*/\1/p' "$T/cnt.txt")
DON=$(awk -F'\t' '!/^#/ && $2=="_nGd"{s+=$6} END{print s+0}' "$TSV"); DOFF=$(awk -F'\t' '!/^#/ && $2=="_nGd"{s+=$7} END{print s+0}' "$TSV")
[ "$DON" = "$RON" ] && [ "$DOFF" = "$ROFF" ] && ok "★ 날짜별 IBD/우발 합 = 런별 PairAndCountW (on $RON, off $ROFF)" || bad "쌍 개수 불일치" "daily on=$DON off=$DOFF / run on=$RON off=$ROFF"
#  ③ 산출물
N=$(ls "$T/out"/3[2-9]_*.png "$T/out"/4[0-9]_*.png "$T/out"/5[0-2]_*.png 2>/dev/null | wc -l)
[ "$N" -eq 21 ] && ok "그림 32~52 스물한 장 (추이 5 · 스펙트럼 4 · 배경 성분 4 · 분해 4 · PSD 2 · Li/He dt 2)" || bad "그림 $N 장" "$(ls "$T/out" | grep png)"
head -5 "$TSV" | grep -q $'\tn_psd_rej\tfn_mode\tn_mu_rej$' && ok "표 머리에 n_psd_rej · fn_mode · n_mu_rej 열" || bad "표 머리" "$(grep '^#date' "$TSV")"
FM=$(awk -F'\t' '!/^#/ {print $(NF-1)}' "$TSV" | sort -u | tr '\n' ' ')
[ "$FM" = "0 " ] && ok "기본은 fn_mode 0 (사이드밴드) · PSD 컷 끔" || bad "fn_mode 열 '$FM'"
[ -s "$T/out/daily_spectra.root" ] && ok "daily_spectra.root" || bad "스펙트럼 파일 없음"
#  ④ 픽스처의 뮤온 상관 쌍(런당 500) 은 Li/He 적합이 잡아 빼고, 시간 무관 쌍(런당 1000, on-window 라 우발로는 안 빠진다) 이 남는다.
#     -> Li/He 합 ≈ 1000, 배경 뺀 prompt 적분 ≈ 2000 (±10 %)
LI=$(echo "$OUT" | grep -E '\[SPEC\] n-Gd' | sed -n 's/.*Li\/He \([0-9.]*\).*/\1/p')
INT=$(echo "$OUT" | grep -E '\[SPEC\] n-Gd' | sed -n 's/.*prompt after \([0-9.]*\).*/\1/p')
awk -v x="$LI" 'BEGIN{exit !(x > 900 && x < 1100)}' && ok "날짜별 Li/He 적합 합 ≈ 1000 ($LI)" || bad "Li/He $LI" "$(echo "$OUT" | grep SPEC)"
awk -v x="$INT" 'BEGIN{exit !(x > 1800 && x < 2200)}' && ok "prompt 배경 뺀 적분 ≈ 2000 ($INT)" || bad "prompt 적분 $INT" "$(echo "$OUT" | grep SPEC)"
#  ⑤ 추가 컷 · 대안 규격화 (2026-09-14) : monitorcuts 키 daily_psd_nsig · fn_norm_mode · fn_norm_lo_mev 가 그대로 넘어가고,
#     PSD 컷을 걸면 on/off 쌍 수가 줄 수 있어도 표는 여전히 쓰이며 fn_mode 열이 1 이 된다. --dry-run 은 인자 11 개를 보인다
DRY=$(RUNSUM_OUT="$T/out" MONITORCUTS=/nonexistent "$DIR/tools/monitor/daily.sh" --dry-run 2>&1)
echo "$DRY" | grep -q ', 1.0, -1, 0, 8.5, 0, 0)' && ok "--dry-run 기본 인자 (psd -1 · fn_norm 0 · 8.5 · mu_veto 0 · shower_veto 0)" || bad "dry-run 인자" "$DRY"
printf 'daily_psd_nsig = 3.0\nfn_norm_mode = 1\nfn_norm_lo_mev = 8.5\nmu_veto_us = 300\n' > "$T/cuts.params"
OUT2=$(RUNSUM_OUT="$T/out" MONITORCUTS="$T/cuts.params" "$DIR/tools/monitor/daily.sh" 2>&1); RC2=$?
[ "$RC2" -eq 0 ] && ok "PSD 컷 + 꼬리 규격화 rc=0" || bad "rc=$RC2" "$(echo "$OUT2" | grep -E 'rror|FATAL' | head -3)"
echo "$OUT2" | grep -qE '^\[FN  \] n-Gd : sideband [0-9.]+  used [0-9.]+  \(flat, normalized to the 8.5-12 MeV tail' && ok "[FN] 줄 : 꼬리 규격화 문구" || bad "[FN] 줄" "$(echo "$OUT2" | grep FN)"
FM=$(awk -F'\t' '!/^#/ {print $(NF-1)}' "$TSV" | sort -u | tr '\n' ' ')
[ "$FM" = "1 " ] && ok "fn_mode 열 = 1" || bad "fn_mode 열 '$FM'"
NR=$(awk -F'\t' '!/^#/ && $2=="_nGd"{s+=$(NF-2)+$NF} END{print s+0}' "$TSV")
awk -v x="$NR" 'BEGIN{exit !(x >= 0 && x < 2998)}' && ok "PSD·뮤온 veto 로 버린 on 쌍 수가 표에 있다 ($NR, 합성 자료라 뜻은 없다)" || bad "n_psd_rej+n_mu_rej $NR"
MR=$(awk -F'\t' '!/^#/ && $2=="_nGd"{s+=$NF} END{print s+0}' "$TSV")
[ "$MR" -gt 0 ] && ok "뮤온 veto 300 µs 가 실제로 쌍을 버린다 ($MR)" || bad "n_mu_rej $MR"
LV=$(awk -F'\t' '!/^#/ && $2=="_nGd"{s+=$3} END{printf "%d", s}' "$TSV")
awk -v a="$LV" -v b="$SUM" 'BEGIN{exit !(a < b)}' && ok "늘린 veto 만큼 라이브타임이 준다 ($LV < $SUM)" || bad "라이브타임 보정" "$LV vs $SUM"
DON2=$(awk -F'\t' '!/^#/ && $2=="_nGd"{s+=$6} END{print s+0}' "$TSV")
[ "$((DON2 + NR))" = "$RON" ] && ok "★ on 쌍 = 남은 것 + PSD·뮤온 veto 로 버린 것 ($DON2 + $NR = $RON)" || bad "컷 회계" "on $DON2 + rej $NR != $RON"
echo; echo "PASS $PASS  FAIL $FAIL"; [ "$FAIL" -eq 0 ]
