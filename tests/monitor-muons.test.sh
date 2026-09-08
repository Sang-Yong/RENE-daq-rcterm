#!/usr/bin/env bash
# monitor-muons.test.sh -- RenePrdSingles.h 뮤온 수집이 기존 동작을 바꾸지
# 않는지. 실데이터는 읽기만 하고 캐시는 임시 디렉터리에 쓴다.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh 2>/dev/null
command -v root >/dev/null 2>&1 || { echo "SKIP: ROOT 없음"; exit 0; }
RUNDIR=""
for r in /Data_ssd/RAW /data/RAW /scratch/RAW; do
   [ -f "$r/004237/PRD/PRD_004237.00100.root" ] && RUNDIR=$r && break
done
[ -n "$RUNDIR" ] || { echo "SKIP: run 4237 PRD 없음"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/t.C" <<EOF
#include "$DIR/tools/monitor/RenePrdSingles.h"
void t() {
   TString prd = "$RUNDIR/004237/PRD/PRD_004237.00100.root";
   double thr; { SetChannel(CH_NH); double a=std::min(S1_MIN_NPE,S2_MIN_NPE);
                 SetChannel(CH_NGD); double b=std::min(S1_MIN_NPE,S2_MIN_NPE);
                 thr = std::min(a,b); }
   ReneCarry c1, c2;
   std::vector<S1S2_Candidate> s1, s2;
   std::vector<ReneMuon> mu;
   ReneSubrunStat a = ReneProcessSubrun(prd, 100, thr, 150.0, c1, s1);
   ReneSubrunStat b = ReneProcessSubrun(prd, 100, thr, 150.0, c2, s2, &mu);
   printf("CHK singles_same=%d\n", (int)(s1.size()==s2.size()));
   printf("CHK nmuon_match=%d\n", (int)((long long)mu.size()==b.nMuon));
   printf("CHK muon_sorted=%d\n", (int)std::is_sorted(mu.begin(), mu.end(),
          [](const ReneMuon&x,const ReneMuon&y){return x.t_us<y.t_us;}));
   TString cp = "$T/cache_"; gSystem->mkdir(cp, kTRUE); cp += "/";
   TString path = ReneCachePath(cp, 4237, 100);
   ReneSaveCache(path, thr, 150.0, s2, 0, c2, b, &mu, 0);
   std::vector<S1S2_Candidate> s3; ReneCarry c3; ReneSubrunStat st3;
   printf("CHK legacy_load=%d\n", (int)ReneLoadCache(path, thr, 150.0, s3, c3, st3));
   printf("CHK legacy_n=%d\n", (int)(s3.size()==s2.size()));
   std::vector<ReneMuon> mu2;
   printf("CHK muon_load=%d\n", (int)(ReneLoadCacheMuons(path, mu2) && mu2.size()==mu.size()));
}
EOF
OUT=$(root -l -b -q "$T/t.C+" 2>&1)
echo "$OUT" | grep -q 'CHK singles_same=1' || { echo "FAIL singles"; echo "$OUT" | tail -20; exit 1; }
for k in nmuon_match muon_sorted legacy_load legacy_n muon_load; do
   echo "$OUT" | grep -q "CHK $k=1" || { echo "FAIL $k"; echo "$OUT" | tail -20; exit 1; }
done
echo "PASS monitor-muons (6/6)"
