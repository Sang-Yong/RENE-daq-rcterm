#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  src/RunQuality.hh -- 이벤트 0 인 런의 onlbit 판정 (2026-11-08 run 4441~4445)
#  ROOT 없이 g++ 로 작은 시험 프로그램을 만들어 돌린다. DB · 하드웨어 무접촉.
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/t.cc" <<'C'
#include "RunQuality.hh"
#include <cstdio>
#include <cstring>
static int pass = 0, fail = 0;
static void check(const char* n, bool c) { if (c) { ++pass; std::printf("  ok   %s\n", n); } else { ++fail; std::printf("  FAIL %s\n", n); } }
int main() {
   using runq::AllAdcZero; using runq::OnlBit;
   // 실물 : run 4445 heartbeat  daq0=FADCDAQ n=0 · daq1=SADCDAQ n=0 , rcterm 의 종류는 FADC · SADC
   check("FADC 0 · SADC 0 -> 0 사건 런",            AllAdcZero({"FADC","SADC"}, {0, 0}));
   check("FADC 0 · SADC 0 -> onlbit 0",             OnlBit(true, AllAdcZero({"FADC","SADC"}, {0, 0})) == 0);
   check("정상 런 (560 M) -> onlbit 1",             OnlBit(true, AllAdcZero({"FADC","SADC"}, {560218484LL, 560000000LL})) == 1);
   check("한쪽만 0 -> 0 사건 런이 아니다",          !AllAdcZero({"FADC","SADC"}, {0, 1000}));
   check("ADC 가 없으면 판정하지 않는다",           !AllAdcZero({}, {}));
   check("4 글자가 아닌 종류(TCB) 는 세지 않는다",  !AllAdcZero({"TCB"}, {0}));
   check("TCB 가 섞여도 ADC 합으로",                AllAdcZero({"FADC","TCB","SADC"}, {0, 5, 0}));
   check("goodRun=false 면 언제나 0",               OnlBit(false, false) == 0);
   check("runlog 문구",                             std::strstr(runq::NoEventsRunlog(), "0 events on all ADCs") != nullptr);
   std::printf("\nPASS %d  FAIL %d\n", pass, fail);
   return fail ? 1 : 0;
}
C
g++ -std=c++17 -Wall -Wextra -Werror -I"$DIR/src" -o "$T/t" "$T/t.cc" || { echo "compile FAIL"; echo "PASS 0  FAIL 1"; exit 1; }
"$T/t"
