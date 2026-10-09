---
name: run-summary-analysis
description: "RENE 런 서머리·모니터링 파이프라인을 돌리고 결과를 해석하는 방법. 단계(run-summary → dst-build → metrics → ibd-summary(legacy) → rate-trend/bg-trend/veto-summary → daily → websummary), 그림 규칙(선형 기본·로그 _log·nGd/nH 분리·배경별 전체 스펙트럼·번호순 파일명), veto 패널 비교표, 기대 IBD 와의 대조, 뮤온 스펙트럼(muon-spec), 수집 중인 런의 별도 OUT 처리를 다룬다. '그림 그려', '지표', '비교표', '통계 검수', '추이', '월별', '기대 신호' 에 쓴다. 수집·문턱 변경·백업에는 쓰지 않는다."
---

# 런 서머리 분석 — 단계, 그림 규칙, 해석

`monitor-analyst` 가 따른다. 구조 지도는 `docs/RUNSUMMARY.md`, 단계별 상세는 `tools/monitor/README.md`. 여기에는 판단 기준만 둔다.

## 1. 단계와 입력

| 단계 | 명령 | 입력 → 산출 | 비용 |
|---|---|---|---|
| 1 run-summary | `tools/monitor/run-summary.sh` | PRD → `run_summary.tsv` | 분 |
| 2 dst-build | `tools/monitor/dst-build.sh --list R [--muon-mode 2 --adc-cut 50] [--force]` | PRD → `dst_m2/DST_R.root` | 24 h 런 ~35 분 (3 병렬) |
| 3 metrics | `tools/monitor/metrics.sh --list R [--force]` | DST → `metrics_summary.tsv` | 초 |
| 4 추이 | `rate-trend.sh` `bg-trend.sh` `veto-summary.sh` | 표 → `NN_*.png` 01~31 | 초 |
| 4d daily | `tools/monitor/daily.sh` | 전 런 DST → `daily_summary.tsv` · 그림 32~63 | 12 분 |
| 5 websummary | cron :27 | 전부 → HTML · 시트 · 드라이브 | 손으로 돌리지 않는다 |
| veto 패널 | `PSD_OUT=… tools/psd/veto-history.sh R R` | PRD 서브런 10·100·600·1200 → `veto_history.tsv` | 분 |
| 뮤온 스펙트럼 | `tools/monitor/muon-spec.sh` | DST → `muspec/<dst>/` | 5 분 |
| 기대 IBD | `tools/reactor/expected_ibd.py` | KHNP 실시간 → flux · IBD/day | 초 |

운영 표 자리는 `/scratch/RunSummary/`. 운영 설정은 `config/monitorcuts.params` (dst_subdir=dst_m2 · metrics_dst_subdir · fn_norm_mode 2 · daily_prompt_lo/hi_mev 3/7 · daily_expected_ibd_per_day 0.345).

## 2. 규칙 — 왜

- **수집 중인 런을 운영 표에 넣지 않는다.** 덜 끝난 DST 가 캐시로 남아 legacy 대조를 영원히 막은 날이 있다(§11.190). 보고 싶으면 `/scratch/RunSummary/<이름>/` 별도 OUT 에 링크·복사로.
- **`--force` 는 DST 만 다시 쓰고 서브런 캐시(`cache_m2/`)는 읽는다.** 파형부터 다시 만들려면 캐시를 `cache_m2.<꼬리표>/` 로 옮긴 뒤. 병렬로 띄우기 전에 `--list 999999` 로 `.so` 를 먼저 만든다(ACLiC 경쟁).
- **헤더를 고치면 `.C` 를 touch** 한다. ACLiC 는 include 변경을 안 본다.
- **긴 배치는 setsid nohup + 로그** 로 띄우고 끝나기를 기다리지 않는다. 끝나면 metrics → trend → daily → 웹 폴더 순.
- **legacy(ibd-summary)와 DST 는 veto 정의가 다르다**(패널 AND 대 mode 2). `--verify` 대조는 건너뛰도록 돼 있다. 둘의 차이를 결함으로 읽지 않는다.

## 3. 그림 규칙 (사용자 지침 2026-09-14 · 09-18)

- **선형축이 기본.** 로그는 같은 이름에 `_log` 를 붙여 따로. 로그에서만 보이는 값은 선형 그림의 빈 구석에 inset.
- nGd 와 nH 는 캔버스를 나눈다. 색은 nGd 빨강 · nH 파랑.
- 배경마다 전체 양의 스펙트럼을 같이 낸다(우발 · fast-n · Li/He · multiplicity 기각 · 사이드밴드).
- 파일 이름은 `NN_묶음_양_채널.png` 번호순(01~63). 새 그림은 다음 번호.
- 문턱 변경 런에는 세로 점선 `THR <런>` (ReneTrendPlot 의 TrendMarker).
- 비교표는 **패널별 절대 Hz = 비율 % × (FADC + VETO) 합계**, 표본 서브런 수를 함께. 그림만 주지 말고 표를 같이.

## 4. 해석의 기준 (현재 확정된 사실)

- 패널 AND 태깅은 관통 뮤온의 60 % 안팎, 강한 veto(mode 2, S_ADC>50) 는 93 %. 하드웨어 문턱을 바꿔도 mode 2 후보율은 거의 안 변한다(§11.199).
- 남는 prompt 스펙트럼의 2.2 · 8 MeV 언덕은 두-중성자 상관 배경이다. IBD 창은 3~7 MeV(§11.200). 기대 IBD 는 한빛 1·2 호기 정지 중 0.35/day, 창 0.20/day(§11.201). 창 후보 2.0 ± 0.7/day 는 fast-n 뺄셈 모양 오차가 주도(§11.203).
- '죽은' 7 패널은 450 m.w.e. 뮤온율(0.3~1.5 Hz)로 세는 정상 카운터이고, 문턱 바로 위 잡음을 100 배로 세는 쪽이 '산' 패널이다(§11.195). 패널 Hz 가 뮤온율에 가까운가로 판정한다.
- 통계: 하루 단위 IBD 검증은 불가능하다(S/B 2 %). 달 단위 합으로.

## 5. 출력

그림 경로 목록 · 핵심 수치 표 · 해석 5 줄 · 다음 손잡이. 사용자에게 보여 줄 그림이 많으면 zip 을 `/Data_ssd/LOG/` 에 만들고 10 MB 를 넘지 않게 나눈다(SendUserFile 상한).
