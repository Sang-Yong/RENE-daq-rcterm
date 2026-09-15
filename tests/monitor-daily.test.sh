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
N=$(ls "$T/out"/3[2-9]_*.png "$T/out"/4[0-9]_*.png "$T/out"/5[0-8]_*.png "$T/out"/6[0-3]_*.png 2>/dev/null | wc -l)
[ "$N" -eq 31 ] && ok "그림 32~63 서른한 장 (추이 5 · 스펙트럼 4 · 배경 성분 4 · 분해 4 · PSD 2 · Li/He dt 2 · 다중도 2 · 모양 대조 2 · Δt 2 · 신호창 검수 2 · 창 rate 2)" || bad "그림 $N 장" "$(ls "$T/out" | grep png)"
echo "$OUT" | grep -qE '^\s*\[DT  \] n-Gd all : tau [0-9.]+ us' && ok "[DT] 줄 : Δt 적합" || bad "[DT] 줄" "$(echo "$OUT" | grep 'DT  ')"
echo "$OUT" | grep -qE '^\s*\[MULT\] n-Gd : N\(0\)=[0-9.]+ N\(1\)=' && ok "[MULT] 줄 : 다중도 N(0)·N(1)·N(2) 와 포아송 외삽" || bad "[MULT] 줄" "$(echo "$OUT" | grep MULT)"
head -5 "$TSV" | grep -q $'\tn_psd_rej\tfn_mode\tn_mu_rej\tn_on_win\tn_off_win\tn_cand_win\tcand_win_err\trate_win\trate_win_err\twin_lo_mev\twin_hi_mev$' && ok "표 머리에 n_psd_rej · fn_mode · n_mu_rej + 신호창 8 열" || bad "표 머리" "$(grep '^#date' "$TSV")"
FM=$(awk -F'\t' '!/^#/ {print $21}' "$TSV" | sort -u | tr '\n' ' ')
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
echo "$DRY" | grep -q ', 1.0, -1, 0, 8.5, 0, 0, "dst", -1, -1, -1, -1)' && ok "--dry-run 기본 인자 (psd -1 · fn_norm 0 · 8.5 · mu_veto 0 · shower_veto 0 · dst · iso -1/-1 · window -1/-1)" || bad "dry-run 인자" "$DRY"
cp "$TSV" "$T/daily_default.tsv"
printf 'daily_psd_nsig = 3.0\nfn_norm_mode = 1\nfn_norm_lo_mev = 8.5\nmu_veto_us = 300\n' > "$T/cuts.params"
OUT2=$(RUNSUM_OUT="$T/out" MONITORCUTS="$T/cuts.params" "$DIR/tools/monitor/daily.sh" 2>&1); RC2=$?
[ "$RC2" -eq 0 ] && ok "PSD 컷 + 꼬리 규격화 rc=0" || bad "rc=$RC2" "$(echo "$OUT2" | grep -E 'rror|FATAL' | head -3)"
echo "$OUT2" | grep -qE '^\[FN  \] n-Gd : sideband [0-9.]+  used [0-9.]+  \(flat, normalized to the 8.5-12 MeV tail' && ok "[FN] 줄 : 꼬리 규격화 문구" || bad "[FN] 줄" "$(echo "$OUT2" | grep FN)"
FM=$(awk -F'\t' '!/^#/ {print $21}' "$TSV" | sort -u | tr '\n' ' ')
[ "$FM" = "1 " ] && ok "fn_mode 열 = 1" || bad "fn_mode 열 '$FM'"
NR=$(awk -F'\t' '!/^#/ && $2=="_nGd"{s+=$20+$22} END{print s+0}' "$TSV")
awk -v x="$NR" 'BEGIN{exit !(x >= 0 && x < 2998)}' && ok "PSD·뮤온 veto 로 버린 on 쌍 수가 표에 있다 ($NR, 합성 자료라 뜻은 없다)" || bad "n_psd_rej+n_mu_rej $NR"
MR=$(awk -F'\t' '!/^#/ && $2=="_nGd"{s+=$22} END{print s+0}' "$TSV")
[ "$MR" -gt 0 ] && ok "뮤온 veto 300 µs 가 실제로 쌍을 버린다 ($MR)" || bad "n_mu_rej $MR"
LV=$(awk -F'\t' '!/^#/ && $2=="_nGd"{s+=$3} END{printf "%.2f", s}' "$TSV"); SUMF=$(awk -F'\t' '!/^#/ && $2=="_nGd"{s+=$3} END{printf "%.2f", s}' "$T/daily_default.tsv")
awk -v a="$LV" -v b="$SUMF" 'BEGIN{exit !(a+0 < b+0)}' && ok "늘린 veto 만큼 라이브타임이 준다 ($LV < $SUMF; 픽스처 뮤온 0.2 Hz 라 차이는 작다)" || bad "라이브타임 보정" "$LV vs $SUMF"
DON2=$(awk -F'\t' '!/^#/ && $2=="_nGd"{s+=$6} END{print s+0}' "$TSV")
[ "$((DON2 + NR))" = "$RON" ] && ok "★ on 쌍 = 남은 것 + PSD·뮤온 veto 로 버린 것 ($DON2 + $NR = $RON)" || bad "컷 회계" "on $DON2 + rej $NR != $RON"
#  ⑥ 원자로 참조 신호창 (2026-09-15) : daily_prompt_lo/hi_mev 가 넘어가고, 창 안 쌍 수 ≤ 전체, 창 밖으로 두면 창 열 = 전체, 그림 60~63 과 [WIN] 줄
WON=$(awk -F'\t' '!/^#/ && $2=="_nGd"{s+=$23} END{print s+0}' "$TSV"); DON3=$(awk -F'\t' '!/^#/ && $2=="_nGd"{s+=$6} END{print s+0}' "$TSV")
[ "$WON" = "$DON3" ] && ok "창을 안 주면 n_on_win = n_ibd ($WON)" || bad "창 기본값" "n_on_win $WON vs n_ibd $DON3"
printf 'daily_prompt_lo_mev = 3.0\ndaily_prompt_hi_mev = 7.0\n' > "$T/cuts2.params"
OUT3=$(RUNSUM_OUT="$T/out" MONITORCUTS="$T/cuts2.params" "$DIR/tools/monitor/daily.sh" 2>&1); RC3=$?
[ "$RC3" -eq 0 ] && ok "신호창 3.0-7.0 rc=0" || bad "rc=$RC3" "$(echo "$OUT3" | grep -E 'rror|FATAL' | head -3)"
echo "$OUT3" | grep -qE '^\[WIN \] n-Gd : window 3.0-7.0 MeV  on [0-9]+  acc [0-9.]+  fast-n [0-9.]+  Li/He [0-9.]+  -> cand -?[0-9.]+ \+- [0-9.]+ .* reactor template eff\(window\) 0\.[0-9]+ eff\(S1\) 0\.[0-9]+' \
   && ok "[WIN] 줄 : 창 통계 + 템플릿 효율" || bad "[WIN] 줄" "$(echo "$OUT3" | grep 'WIN ')"
EFFW=$(echo "$OUT3" | sed -n 's/.*eff(window) \([0-9.]*\) eff(S1) \([0-9.]*\).*/\1 \2/p' | head -1)
awk -v e="$EFFW" 'BEGIN{split(e,a," "); exit !(a[1] > 0.45 && a[1] < 0.80 && a[2] > 0.90)}' && ok "원자로 템플릿 효율 : 3-7 MeV 0.45~0.80, 1.2-12 MeV > 0.90 ($EFFW)" || bad "템플릿 효율 $EFFW"
WON3=$(awk -F'\t' '!/^#/ && $2=="_nGd"{s+=$23} END{print s+0}' "$TSV"); DON3=$(awk -F'\t' '!/^#/ && $2=="_nGd"{s+=$6} END{print s+0}' "$TSV"); WLO=$(awk -F'\t' '!/^#/ {print $29"-"$30}' "$TSV" | sort -u | tr '\n' ' ')
[ "$WON3" -le "$DON3" ] && [ "$WLO" = "3.00-7.00 " ] && ok "창 안 on 쌍 $WON3 ≤ 전체 $DON3, win 열 $WLO" || bad "창 열" "on_win $WON3 / $DON3, win $WLO"
[ -s "$T/out/60_signal_window_nGd.png" ] && [ -s "$T/out/62_daily_rate_window_nGd.png" ] && ok "그림 60 (신호창 검수) · 62 (창 rate)" || bad "그림 60/62 없음"
echo; echo "PASS $PASS  FAIL $FAIL"; [ "$FAIL" -eq 0 ]
