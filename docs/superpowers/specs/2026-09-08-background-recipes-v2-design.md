# 배경 레시피 v2 — IBD 후보와 배경 4종을 논문 정의에 맞춘다 (2026-09-08 설계)

앞선 스펙(`2026-09-08-run-summary-web-design.md`)이 Li/He·fast-n 을 "★예비"
로 남겨 두었고, 실측에서 두 레시피 모두 구조적 한계가 드러났다(§11.156).
이 문서는 **NEOS(고영주 2017 · 김진유 2022 박사논문, PRL 118 121802) ·
Daya Bay(arXiv 1402.6876) · RENE(PTEP 2025 093C03)** 의 정의를 읽고, RENE
데이터 트리(PRD → DST)에서 실제로 잴 수 있는 형태로 다시 세운 레시피다.
사용자 요청(2026-09-08) : "있는 것을 맹신하지 말고 논문에서 정의를 이해한 뒤
RENE 트리에 맞는 선택 기준을 세우고, 필요하면 2차 프로덕션을 바꿔라."

## 0. 논문에서 확인한 정의 (요약)

| 항목 | NEOS-I (고영주 §4.3) | NEOS-II (김진유 §5) | Daya Bay (1402.6876) | RENE (PTEP 2025) |
|---|---|---|---|---|
| prompt | 1–10 MeV | 1–10 MeV | 0.7–12 MeV | 1–8 MeV (설계) |
| delayed n-Gd | 4–10 MeV | 4→3.96 MeV 시간 변화 | 6–12 MeV | 6–10 MeV |
| dt | 1–30 µs (τ≈7 µs) | 시간 변화 | 1–200 µs | — |
| muon veto | 150 µs | 150 µs | 600 µs–1 s | 오프라인 veto |
| multiplicity | [tp−30, tp+150] µs | 45 µs 전 / 150 µs 후 | 앞뒤 200 µs | — |
| accidental | off-window(time-delayed coincidence) 7±1/day | 반응로 off 로 총배경 | R₁·R₂·T (Eq.1) | R₁·R₂·T |
| fast-n | **PSD** (prompt 의 proton recoil), off 기간 배경의 73% 제거 | PSD 컷(중성자 56% 기각, γ 99% 수용), 뮤온 뒤 1–50 µs 표본으로 보정 | prompt 12–100 MeV 사이드밴드 0차/1차 외삽 평균 | PSD 가 핵심이라 EJ-309 10% 첨가 |
| ⁹Li/⁸He | 별도 추정 없음(반응로 off 로 흡수) | 없음 | dt-since-last-muon 적합 Eq.2 : `N_LiHe[R λ_Li e^{−λ_Li t} + (1−R) λ_He e^{−λ_He t}] + N_unc R_μ e^{−R_μ t}` | 시뮬레이션 |

현재 분석 헤더(`AnalysisCondition.h`)의 컷 — prompt 1.2–12 MeV, n-Gd 6–10 MeV
dt 1–100 µs, n-H 1.87–2.59 MeV dt 2–400 µs, veto 150 µs, ISO 200/400 (600/1000)
— 은 위 표의 범위 안에 있고 legacy 와 비트 단위 검증이 끝나 있으므로 **IBD·
off-window accidental 은 그대로 둔다.** 바꾸는 것은 배경 3종의 레시피와 그
재료(DST)다.

## 1. 실측으로 확정한 이 사이트의 제약 (2026-09-08, 읽기 전용)

```
① PSD 분리력이 약하다.  AmBe run 4221 서브런 100–104, 꼬리비율(피크+40 ns 이후/전체)
      n-Gd 포획이 뒤따르는 prompt   mean 0.316  rms 0.029   (중성자 풍부, 4.4 MeV γ 섞임)
      뒤따르지 않는 single           mean 0.289  rms 0.043   (γ 풍부)
      FoM = |Δmean| / sqrt(σ₁²+σ₂²) = 0.53        (NEOS 는 2.8)
   -> 사건별 컷은 불가. 런 단위 통계량(γ-band 평균·RMS, 3σ 밖 분율)으로만 쓴다.
   -> 같은 꼬리비율이 run 4332 에서는 0.40 이다 (4221 은 0.29). 파형 자체가
      런에 따라 변한다 -> 이것이 오히려 **런 품질 지표**가 된다.

② 12 MeV 이상은 93 % 가 포화다 (run 4332, NPE 7265–15000 구간 15 개 중 14 개).
   clean single 이 포화 사건을 버리므로(Step2 순서) 기존 fast-n 사이드밴드는
   표본의 7 % 로 만든 값이었다.  3–6 MeV 에서도 2.8 % 가 포화한다.

③ target 을 지나는 뮤온은 3.05 Hz, 그중 NPE > 20000 이 0.63 Hz 다 (run 4305 DST).
   적분창이 1 µs 라 NPE 는 5만을 넘지 못한다 -> '샤워링' 을 에너지로 더 좁힐 수 없다.
   옛 문턱 3000 NPE(1.33 Hz, 1/R = 0.75 s) 는 τ(⁹Li)=0.257 s 와 축퇴 -> n_lihe 가
   후보의 56 % 를 흡수했다(§11.156). 문턱 20000 이면 1/R = 1.6 s 로 6 배 벌어진다.
```

## 2. DST 스키마 2 (2차 프로덕션 변경)

| 트리 | 열 | 바뀐 것 |
|---|---|---|
| `T_Singles` | evt_id sub_id t_us pe **psd** | `psd` = Σch tail(피크+40 ns 이후) / Σch total. 파형에서만 나오므로 DST 에 둔다 |
| `T_Sat` ★신설 | sub_id t_us pe | muon·after-muon 을 통과했으나 **포화라 버린** 사건. pe 는 잘린 적분값(하한) |
| `T_Muons` | 그대로 | |
| `T_Info` | schema=**2**, + psd_tail_ns=40 | |

singles 의 개수·순서·pe 는 바꾸지 않는다 — legacy 패리티 게이트(`metrics.sh
--verify`)는 그대로 성립한다. 서브런 캐시(`cache/`)에도 같은 열·트리를 더하고,
없는 캐시는 파형에서 다시 만든다(옛 캐시는 자동 무효).

## 3. 지표 (metrics_summary.tsv schema 2)

앞 18 열은 자리를 지킨다(웹·시트 소비자가 14/16/18 열을 읽는다). 19 열부터 새로 낸다.

| 열 | 정의 | 근거 |
|---|---|---|
| `n_ibd` `n_ibd_acci` | 그대로 | legacy 패리티 |
| `n_acci_rp` ★ | R_S1 · R_S2 · (dt_max−dt_min) · live. 창 안 단독 rate 곱 | RENE PTEP §2 · Daya Bay Eq.1. off-window 값과 나란히 놓아 방법 자체를 대조 |
| `n_mult_rej` ★ | (n_paired − n_ibd) − acciScale·(n_paired_acci − n_ibd_acci) | multiplicity 가 걸러낸 **상관** 쌍 = 뮤온 유발 다중 중성자(NEOS "correlated bg") 지표 |
| `n_fn_side` `n_fn_side_scaled` | prompt 창을 [fn_e_lo, fn_e_hi] 로 올린 페어링. **T_Sat 을 합쳐** 센다. scaled = 0차·1차 외삽 평균 | Daya Bay §4.3 그대로. 포화 사건 포함이 v1 과 다른 점 |
| `n_fn_side_lin` `fn_sat_frac` ★ | 1차 외삽 단독값 · 사이드밴드 중 포화 사건 비율 | 0차−1차 차이가 계통오차. sat_frac 이 크면 에너지 축이 눌린 것 |
| `n_lihe` `e_lihe` `lihe_stat` | Daya Bay Eq.2 적합. R_μ 는 **데이터에서 고정**(n_mu_shower/live), Li 분율 R 고정(기본 1.0) | 우발항을 상수가 아니라 R_μ e^{−R_μ t} 로. 이것이 v1 의 오류였다 |
| `n_lihe_rev` `e_lihe_rev` ★ | 같은 적합을 **다음** 샤워링 뮤온까지의 시간(시간 역방향)에 | 물리 상관이 없는 대조 표본. 0 과 맞아야 한다. 벗어나면 적합이 우발을 흡수한 것 |
| `r_mu_shower` ★ | 샤워링 뮤온 rate [Hz] | 1/R 대 τ 의 간격을 표가 스스로 말한다 |
| `psd_mean` `psd_rms` `n_ibd_psd_nlike` ★ | 1–3 MeV single 의 psd 평균·RMS(γ-band) · IBD 후보 prompt 중 psd > mean+psd_nsig·rms 인 수 | NEOS 의 p_psd 정의(§4.3.2.2)를 런 단위로. 분리력이 약해 **비율의 추이**만 본다 |

컷 열 : 기존 + `lihe_li_frac` `psd_nsig`. `fn_tag_s`/`n_fn_mutag` 는 뺀다 —
"직전 샤워링 뮤온 0.1 s 안의 후보 수" 는 fast-n 과 무관하고(fast-n 은 µs
단위) R_μ 가 1 Hz 급이라 순수 우발이었다.

## 4. 검증 계획

- 합성 DST(뮤온 간격 **Poisson**, Li 상관 500, 우발 1000, 포화 사이드밴드 사건)로
  n_lihe 가 참값 ±20 %·±3σ, n_lihe_rev ≈ 0, n_fn_side 가 포화 사건을 센다,
  n_acci_rp > 0, psd 열이 옛 DST(schema 1)에서는 −1.
- 실데이터 : run 4305 DST 를 schema 2 로 다시 만들고 `metrics.sh --verify` 가
  여전히 불일치 0. n_lihe_rev 가 0 과 맞는지 실측.
- 하드웨어·수집·실데이터 무접촉(읽기만). 쓰는 곳은 `/scratch/RunSummary` 뿐.

## 5. 이 레시피가 여전히 못 하는 것 (알고 시작한다)

- fast-n 은 이 사이트에서 **가장 큰 배경**일 가능성이 높다(NEOS 20 mwe 에서
  off 배경의 73 % 가 PSD 로 제거된 fast-n 이었다 → 톤당 60/일 → RENE 0.27 t 면
  ~16/일, n-Gd 후보 ~90/일의 20 %). 사이드밴드 외삽은 그 **크기**를 주지
  사건별 제거를 못 한다. 사건별 제거는 PSD 개선(분석팀 몫)이 필요하다.
- ⁹Li/⁸He 는 이 크기·깊이에서 ~0.5/일로 작을 것이다. 적합값은 대부분 0 과
  맞는 **상한**으로 읽는다. 시간 역방향 대조가 그것을 확인해 준다.
- 반응로 on/off 정보가 없다. 총배경의 최종 확인(NEOS 방식)은 off 기간 데이터가
  생기면 `run_summary` 의 후보 rate 로 그때 한다.
