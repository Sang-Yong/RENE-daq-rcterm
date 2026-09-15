#!/usr/bin/env bash
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh 2>/dev/null
command -v root >/dev/null 2>&1 || { echo "SKIP: ROOT 없음"; exit 0; }
RUN=4220
FOUND=0
for r in /Data_ssd/RAW /data/RAW /scratch/RAW; do
   [ -d "$r/00$RUN/PRD" ] && FOUND=1 && break
done
[ "$FOUND" = 1 ] || { echo "SKIP: run $RUN PRD 없음"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/out"
# 1) 첫 빌드 (파형 경로)
RUNSUM_OUT="$T/out" "$DIR/tools/monitor/dst-build.sh" --list $RUN > "$T/log1" 2>&1 \
   || { echo "FAIL build1"; tail -20 "$T/log1"; exit 1; }
DST="$T/out/dst/DST_00$RUN.root"
[ -s "$DST" ] || { echo "FAIL: DST 없음"; exit 1; }
# 2) 트리 셋 존재 + 싱글 수 == 캐시 싱글 수
OUT=$(root -l -b -q -e "
   TFile f(\"$DST\");
   TTree*s=(TTree*)f.Get(\"T_Singles\"); TTree*m=(TTree*)f.Get(\"T_Muons\");
   TTree*i=(TTree*)f.Get(\"T_Info\");
   printf(\"CHK trees=%d\n\", (int)(s&&m&&i));
   printf(\"CHK muons_pos=%d\n\", (int)(m->GetEntries()>0));
   TTree*x=(TTree*)f.Get(\"T_Sat\"); Int_t sch=0; i->SetBranchAddress(\"schema\",&sch); i->GetEntry(0);
   printf(\"CHK schema2=%d\n\", (int)(sch==2 && x!=nullptr && s->GetBranch(\"psd\")!=nullptr));
   Float_t psd=-1; s->SetBranchAddress(\"psd\",&psd); int ok=1; for(Long64_t k=0;k<s->GetEntries();k++){ s->GetEntry(k); if(!(psd>=0 && psd<=1)) ok=0; }
   printf(\"CHK psd_range=%d\n\", ok);
" 2>&1)
echo "$OUT" | grep -q 'CHK trees=1'     || { echo "FAIL trees"; exit 1; }
echo "$OUT" | grep -q 'CHK muons_pos=1' || { echo "FAIL muons"; exit 1; }
echo "$OUT" | grep -q 'CHK schema2=1'   || { echo "FAIL schema2 (psd 열·T_Sat·schema=2)"; echo "$OUT" | tail -5; exit 1; }
echo "$OUT" | grep -q 'CHK psd_range=1' || { echo "FAIL psd_range"; exit 1; }
# 3) 재실행은 캐시 경로 -- '캐시 1 / 새로 0' 이어야 한다
RUNSUM_OUT="$T/out" "$DIR/tools/monitor/dst-build.sh" --list $RUN --force > "$T/log2" 2>&1
grep -q '캐시 1 / 새로 0' "$T/log2" || { echo "FAIL resume"; tail -5 "$T/log2"; exit 1; }
# 4) force 없는 재실행은 '최신' 으로 건너뛴다
RUNSUM_OUT="$T/out" "$DIR/tools/monitor/dst-build.sh" --list $RUN > "$T/log3" 2>&1
grep -q 'DST 최신' "$T/log3" || { echo "FAIL uptodate"; exit 1; }
# 5) 서브런 경계 단조성 -- run 4237 을 서브런 0~1 만으로 새 캐시에 빌드,
#    두 트리 모두 t_us 가 경계를 넘어 단조 증가해야 한다 (carry 확인)
FOUND2=0
for r in /Data_ssd/RAW /data/RAW /scratch/RAW; do
   [ -f "$r/004237/PRD/PRD_004237.00001.root" ] && FOUND2=1 && break
done
if [ "$FOUND2" = 1 ]; then
   mkdir -p "$T/out2"
   RUNSUM_OUT="$T/out2" "$DIR/tools/monitor/dst-build.sh" --list 4237 --max-subrun 1 \
      > "$T/log4" 2>&1 || { echo "FAIL build-4237"; tail -10 "$T/log4"; exit 1; }
   OUT2=$(root -l -b -q -e "
      TFile f(\"$T/out2/dst/DST_004237.root\");
      for (const char* tn : {\"T_Singles\", \"T_Muons\"}) {
         TTree* t=(TTree*)f.Get(tn); Double_t tu; t->SetBranchAddress(\"t_us\",&tu);
         double prev=-1e18; bool mono=true; int nsub2=0; Int_t sb;
         t->SetBranchAddress(\"sub_id\",&sb);
         std::set<int> ss2;
         for (Long64_t i=0;i<t->GetEntries();++i){ t->GetEntry(i);
            if (tu<prev) mono=false; prev=tu; ss2.insert(sb); }
         printf(\"CHK %s_mono=%d nsub=%zu\n\", tn, (int)mono, ss2.size());
      }" 2>&1)
   echo "$OUT2" | grep -q 'CHK T_Singles_mono=1 nsub=2' || { echo "FAIL boundary-singles"; exit 1; }
   echo "$OUT2" | grep -q 'CHK T_Muons_mono=1 nsub=2'   || { echo "FAIL boundary-muons"; exit 1; }
   # 6) mode 2 의 pedestal 가드 (2026-09-15) : run 4237 sub 3000 은 ch7 의 S_ADC 가 전 사건에서 컷(50) 위라 가드 없이는 single 이 0 이다.
   #    가드(비트 꺼진 사건 중 > 10 %)가 그 채널을 빼면 single 이 mode 0 의 절반 이상 돌아오고, 가드를 끄면(비율 2.0) 다시 0 근처다
   PRD3000=""
   for r in /Data_ssd/RAW /data/RAW /scratch/RAW; do [ -f "$r/004237/PRD/PRD_004237.03000.root" ] && PRD3000="$r/004237/PRD/PRD_004237.03000.root" && break; done
   if [ -n "$PRD3000" ]; then
      cat > "$T/guard.C" <<EOF3
#include "$DIR/tools/monitor/RenePrdSingles.h"
void guard() {
   long long n[3] = {0, 0, 0}; unsigned ch[3] = {0, 0, 0}; int k = 0;
   for (int mode : {0, 2, 2}) {
      gReneMuonMode = mode; gReneMuonAdcCut = 50; gReneAdcNoiseFrac = (k == 1) ? 2.0 : 0.10; gReneAdcExclSub = 0; gReneAdcExclCh = 0;
      ReneCarry carry; std::vector<S1S2_Candidate> sing; std::vector<ReneMuon> mu;
      ReneSubrunStat st = ReneProcessSubrun("$PRD3000", 3000, LOWER_LIMIT, 150.0, carry, sing, &mu);
      n[k] = st.nSingle; ch[k] = gReneAdcExclCh; k++;
   }
   printf("CHK guard=%d  (mode0 %lld, mode2 noguard %lld, mode2 guard %lld, excl 0x%x)\\n",
          (int)(n[1] < n[0] / 10 && n[2] > n[0] / 2 && (ch[2] & (1u << 7)) != 0 && ch[1] == 0), n[0], n[1], n[2], ch[2]);
}
EOF3
      OUT3=$(root -l -b -q "$T/guard.C+" 2>&1)
      echo "$OUT3" | grep -q 'CHK guard=1' || { echo "FAIL adc-guard"; echo "$OUT3" | grep -E 'CHK|rror' | tail -5; exit 1; }
      echo "PASS monitor-dst (9/9)"
   else
      echo "PASS monitor-dst (8/8, 가드 시험 SKIP: 4237 sub 3000 없음)"
   fi
else
   echo "PASS monitor-dst (6/6, 경계 시험 SKIP: 4237 없음)"
fi
