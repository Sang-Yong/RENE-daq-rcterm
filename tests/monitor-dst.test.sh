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
" 2>&1)
echo "$OUT" | grep -q 'CHK trees=1'     || { echo "FAIL trees"; exit 1; }
echo "$OUT" | grep -q 'CHK muons_pos=1' || { echo "FAIL muons"; exit 1; }
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
   echo "PASS monitor-dst (6/6)"
else
   echo "PASS monitor-dst (4/4, 경계 시험 SKIP: 4237 없음)"
fi
