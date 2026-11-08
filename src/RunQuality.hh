// RunQuality.hh -- 런 마감 때 DB onlbit 판정에 쓰는 순수 함수 (ROOT 의존 없음)
//
// 2026-11-08 run 4441~4445 : HV 가 꺼진 채 정상 종료한 런이 이벤트 0 으로 onlbit=1 이 되어
// GoodRuns 시트에 올라갔다. ADC(FADC/SADC 등, 종류 이름 4 글자) 가 하나 이상 있고
// 그 이벤트 합이 0 이면 좋은 런이 아니다.
#ifndef RENE_RUNQUALITY_HH
#define RENE_RUNQUALITY_HH

#include <string>
#include <vector>

namespace runq {

// kinds[i] 는 모니터 대상의 종류 (FADC · SADC · TCB ...), nev[i] 는 그 이벤트 수
inline bool AllAdcZero(const std::vector<std::string>& kinds,
                       const std::vector<long long>& nev)
{
   int nAdc = 0;
   long long sum = 0;
   for (size_t i = 0; i < kinds.size() && i < nev.size(); ++i) {
      if (kinds[i].size() != 4) continue;
      ++nAdc;
      sum += nev[i];
   }
   return nAdc > 0 && sum == 0;
}

inline int OnlBit(bool goodRun, bool allAdcZero) { return (goodRun && !allAdcZero) ? 1 : 0; }

inline const char* NoEventsRunlog() { return "no events; run ended with 0 events on all ADCs"; }

}  // namespace runq

#endif
