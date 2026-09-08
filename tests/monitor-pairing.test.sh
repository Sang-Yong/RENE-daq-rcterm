#!/usr/bin/env bash
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh 2>/dev/null
command -v root >/dev/null 2>&1 || { echo "SKIP: ROOT 없음"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/t.C" <<'EOF2'
#include "TOOLDIR/RenePrdSingles.h"
#include "TOOLDIR/RenePairing.h"
void t() {
   SetChannel(CH_NGD);
   PairWindows w = CurrentPairWindows();
   //  손으로 만든 이벤트 : S1(창 안 에너지) 하나 + 그 dt 창 안 S2 하나.
   //  에너지는 창 중앙값으로 잡아 어떤 사이트 상수여도 통과한다.
   double e1 = 0.5*(w.s1lo+w.s1hi), e2 = 0.5*(w.s2lo+w.s2hi);
   double dt = 0.5*(w.dtMin+w.dtMax);
   std::vector<S1S2_Candidate> ev;
   //  index 0 에는 낮은 에너지 이력 한 건을 둔다. on-time 루프는 i1==0 일 때
   //  prev 를 s1 자신으로 대체하는데(이력이 없어서), S1 후보는 정의상
   //  _pe_sum>=LOWER_LIMIT 이라 그 대체가 곧 "직전에 에너지 있는 이웃"으로
   //  읽혀 passMult 가 항상 떨어진다 -- 이 파일을 건드리지 않은 원본
   //  PairAndCount 로도 동일하게 재현되는, 기존 검증 통과 로직의 성질이다.
   //  실제 파이프라인은 서브런 경계마다 ReneCarry 로 이 이력을 채워 주므로
   //  S1 이 진짜 인덱스 0 인 경우가 없다. 여기서도 같은 이력을 흉내낸다.
   ev.push_back({-1,0, 500.0,           w.lower*0.1});
   ev.push_back({0,0, 1000.0,           e1});
   ev.push_back({1,0, 1000.0+dt,        e2});
   ev.push_back({2,0, 1000.0+w.dtAcci+dt, e2});   // 우발 창 상대
   std::vector<double> pt;
   PairCounts a = PairAndCountW(ev, w, &pt);
   PairCounts b = PairAndCount(ev);
   printf("CHK delegate=%d\n", (int)(a.nCoinc==b.nCoinc && a.nAcci==b.nAcci
          && a.nCoincMult==b.nCoincMult && a.nAcciMult==b.nAcciMult));
   printf("CHK found_pair=%d\n", (int)(a.nCoincMult>=1));
   printf("CHK prompt_t=%d\n", (int)(!pt.empty() && std::fabs(pt[0]-1000.0)<1e-9));
   //  S1 창을 비켜 세우면 쌍이 사라져야 한다
   PairWindows w2 = w; w2.s1lo = e1*10; w2.s1hi = e1*20;
   PairCounts c = PairAndCountW(ev, w2);
   printf("CHK window_moves=%d\n", (int)(c.nCoincMult==0));
}
EOF2
sed -i "s|TOOLDIR|$DIR/tools/monitor|g" "$T/t.C"
OUT=$(root -l -b -q "$T/t.C+" 2>&1)
for k in delegate found_pair prompt_t window_moves; do
   echo "$OUT" | grep -q "CHK $k=1" || { echo "FAIL $k"; echo "$OUT" | tail -20; exit 1; }
done
echo "PASS monitor-pairing (4/4)"
