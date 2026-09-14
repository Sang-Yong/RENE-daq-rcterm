//  ThrByRun.C — 런마다 첫 PRD 파일의 entry 0 에서 S_THR[30] · F_THR[4] 를 읽어 한 줄로 낸다 (문턱값 변경 이력의 정본 재료).
//  타입에 상관없이 읽으려고 TLeaf::GetValue 를 쓴다.  사용 : root -l -b -q 'ThrByRun.C+("<PRD 파일>", <run>)'  → 표준출력 한 줄
#include <TFile.h>
#include <TTree.h>
#include <TLeaf.h>
#include <cstdio>
void ThrByRun(const char *prd, int run) {
   TFile *f = TFile::Open(prd, "READ"); if (!f || f->IsZombie()) { printf("THR\t%d\tERR\n", run); return; }
   TTree *t = (TTree *)f->Get("Event"); if (!t || t->GetEntries() == 0) { printf("THR\t%d\tERR\n", run); f->Close(); return; }
   t->SetBranchStatus("*", 0); t->SetBranchStatus("S_THR", 1); t->SetBranchStatus("F_THR", 1); t->SetBranchStatus("nCH_SADC", 1);
   t->GetEntry(0);
   TLeaf *ls = t->GetLeaf("S_THR"), *lf = t->GetLeaf("F_THR");
   printf("THR\t%d", run);
   for (int i = 0; i < 4; ++i) printf("\t%.0f", lf ? lf->GetValue(i) : -1);
   int ns = ls ? ls->GetLen() : 0; if (ns > 30) ns = 30;
   for (int i = 0; i < 30; ++i) printf("\t%.0f", (ls && i < ns) ? ls->GetValue(i) : -1);
   printf("\n"); f->Close();
}
