// ---------------------------------------------------------------------------
//  RenePairing.h - clean single 목록에서 IBD 후보 수를 센다.
//
//  규칙의 정본은 분석 쪽 RunBothChannels.C::PairAndSelect 다. 저쪽은 결과를
//  파일로 쓰는 것이 목적이라 **세기만 하는 진입점이 없어서** 여기에 loop 을
//  따로 두었다. 그래서 갈라질 수 있고, 갈라지면 이 표만 조용히 틀린다.
//  BuildPairSummary.C 가 실행할 때마다 분석 Step4 산출물이 있는 런에서는
//  수를 대조하는 이유가 이것이다.
//
//  세 가지가 저쪽과 같아야 한다 --
//     1. delayed-first. delayed 하나에 바로 앞 prompt 하나만 짝지운다.
//        prompt-first 로 모든 조합을 만들면 중성자 포획 하나가 여러 번
//        세어져 후보가 부풀려진다 (저쪽 주석에 4237~4240 실측이 있다 :
//        서로 다른 delayed 7,056 개에서 쌍이 13,648 개 나왔다).
//     2. multiplicity 세 조건 -- ISO_PRE 앞, ISO_POST 뒤, 그리고
//        [S1, S1+DT_MAX] 창 안이 비어 있을 것(_veto_extra).
//     3. 우발도 **같은 규칙**으로 [DT_ACCI, DT_ACCI+DT_MAX] 에서 센다.
//        한쪽만 모든 조합을 세면 뺄셈이 서로 다른 양을 비교하게 된다.
//
//  ev 는 시간 순으로 정렬돼 있어야 하고, 모든 원소가 LOWER_LIMIT 위여야 한다
//  (창 점유 수를 인덱스 차이로 세기 때문이다).
// ---------------------------------------------------------------------------
#ifndef RENE_PAIRING_H
#define RENE_PAIRING_H

#include <vector>

//  S1S2_Candidate 와 컷 상수(DT_*/S2_*/ISO_*/LOWER_LIMIT)를 쓰는 쪽에서
//  AnalysisCondition.h 를 먼저 include 해야 한다. RenePrdSingles.h 가 한다.

struct PairCounts {
   long long nCoinc     = 0;   // coincidence 창을 만족한 쌍
   long long nAcci      = 0;   // off-window 쌍
   long long nCoincMult = 0;   // 거기에 multiplicity 통과 (= T_IBD)
   long long nAcciMult  = 0;   // (= T_IBD_Acci)
};

inline PairCounts PairAndCount(const std::vector<S1S2_Candidate> &ev) {
   PairCounts c;
   const long long nEv = (long long)ev.size();
   if (nEv == 0) return c;

   auto isS1 = [](const S1S2_Candidate &e) {
      return e._pe_sum >= S1_MIN_NPE && e._pe_sum <= S1_MAX_NPE;
   };
   auto isS2 = [](const S1S2_Candidate &e) {
      return e._pe_sum >= S2_MIN_NPE && e._pe_sum <= S2_MAX_NPE;
   };

   //  [S1, S1+DT_MAX] 창에 들어오는 마지막 이벤트의 인덱스. 창이 비어 있으면
   //  i1 자신을 준다.
   auto windowEnd = [&](long long i1) {
      long long w = i1;
      double tLimit = ev[i1]._t_us + DT_MAX_US;
      while (w + 1 < nEv && ev[w + 1]._t_us <= tLimit) ++w;
      return w;
   };

   auto passMult = [&](double prevE, double prevT, double s1t,
                       double nextE, double nextT, double s2t, double vetoExtra) {
      if (prevE >= LOWER_LIMIT && s1t - prevT < ISO_PRE_US)  return false;
      if (nextE >= LOWER_LIMIT && nextT - s2t < ISO_POST_US) return false;
      if (vetoExtra > 0) return false;
      return true;
   };

   //  ---- on-time ----
   for (long long i2 = 0; i2 < nEv; ++i2) {
      const S1S2_Candidate &s2 = ev[i2];
      if (!isS2(s2)) continue;
      for (long long i1 = i2 - 1; i1 >= 0; --i1) {
         double dt = s2._t_us - ev[i1]._t_us;
         if (dt > DT_MAX_US) break;      // 창을 지나쳤다
         if (dt < DT_MIN_US) continue;   // 아직 dead band 안
         const S1S2_Candidate &s1 = ev[i1];
         if (!isS1(s1)) continue;
         const long long wEnd = windowEnd(i1);
         const S1S2_Candidate &prev = (i1 > 0) ? ev[i1 - 1] : s1;
         const S1S2_Candidate &next = (i2 + 1 < nEv) ? ev[i2 + 1] : s2;
         double vetoExtra = (double)(wEnd - i1) - ((i2 <= wEnd) ? 1.0 : 0.0);
         c.nCoinc++;
         if (passMult(prev._pe_sum, prev._t_us, s1._t_us,
                      next._pe_sum, next._t_us, s2._t_us, vetoExtra))
            c.nCoincMult++;
         break;   // delayed 하나에 prompt 하나. 재사용하지 않는다
      }
   }

   //  ---- off-time (우발) ----
   const double accLo = DT_ACCI_US;
   const double accHi = DT_ACCI_US + DT_MAX_US;
   for (long long j = 0; j < nEv; ++j) {
      const S1S2_Candidate &s2 = ev[j];
      if (!isS2(s2)) continue;
      //  i >= 1 인 것은 저쪽과 같다 -- prev 를 ev[i-1] 로 무조건 읽기 때문이다
      for (long long i = j - 1; i >= 1; --i) {
         double dt = s2._t_us - ev[i]._t_us;
         if (dt > accHi) break;
         if (dt < accLo) continue;
         const S1S2_Candidate &s1 = ev[i];
         if (!isS1(s1)) continue;
         const long long wEnd = windowEnd(i);
         const S1S2_Candidate &prev = ev[i - 1];
         const S1S2_Candidate &next = (j + 1 < nEv) ? ev[j + 1] : ev[j];
         double vetoExtra = (double)(wEnd - i) - ((j <= wEnd) ? 1.0 : 0.0);
         c.nAcci++;
         if (passMult(prev._pe_sum, prev._t_us, s1._t_us,
                      next._pe_sum, next._t_us, s2._t_us, vetoExtra))
            c.nAcciMult++;
         break;
      }
   }
   return c;
}

#endif
