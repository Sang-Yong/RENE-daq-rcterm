# DAQ 모니터링 요약 — livetime 부터 neutrino candidate, 그리고 웹 발행까지

**2026-09-08 부터 5단계다** (설계는 `docs/superpowers/specs/2026-09-08-run-summary-web-design.md`).
1·2·3단계와 legacy pair_summary(과도기) 는 전부 production 산출물(PRD)까지
거슬러 올라가는 값만 쓴다 — 다른 계정의 분석 산출물에 기대지 않으므로,
production 이 끝난 런은 곧바로 표에 들어온다. 4·5단계는 그 위에서 만든
TSV(+DST) 만 읽는다.

```
<root>/RAW/<런번호>/PRD/PRD_<런번호>.<서브런>.root      ← 1·2·(과도기) 단계의 유일한 입력
root = /Data_ssd/RAW : /data/RAW : /scratch/RAW        앞에 오는 것이 이긴다
```

root 를 여럿 두는 이유는 두 가지다. dataflow 가 런을 `/Data_ssd → /data →
/scratch` 로 흘려보내므로 한 곳만 보면 옮겨진 런을 놓치고, **앞쪽이 압도적으로
빠르다** — 같은 서브런이 로컬 NVMe 1.1초, `/scratch` 14.6초다(100 Mb 링크 기준,
CLAUDE.md §11.12 — 스토리지 링크는 §11.115 이후 10G 라 지금은 더 빠를 것이나
이 문서의 서브런당 실측치는 아직 100 Mb 기준으로 남아 있다). 1단계는
`RUNSUM_RAW`, 2단계(dst-build)는 `RENE_RAW_ROOTS` 로 바꾼다. **읽기만 한다.**

단계마다 코드 하나, 스크립트 하나다. 순서가 있고, 앞 단계가 없어도 죽지는 않는다
(그 칸만 비고 나중에 다시 돌리면 채워진다). **legacy pair_summary 경로(옛
`ibd-summary.sh`)는 폐기되지 않았다** — DST 경로(`metrics.sh`)가 같은 값을
낸다는 것을 실측으로 확인하는 교차검증 기준이자, 4단계(`rate-trend.sh`)의
**현재 유일한 입력**이다(아래 4단계 참조). `websummary.params` 의
`metrics_source` 가 `dst` 로 바뀌어 사용자 승인이 나기 전까지는, 웹 표
(HTML·시트)도 이 경로 값을 쓴다.

| 순서 | 스크립트 | 매크로 | 입력 | 내는 것 |
|---|---|---|---|---|
| 1 | `run-summary.sh` | `BuildRunSummary.C` | PRD | livetime, 종류별 이벤트 수 → `run_summary.{txt,tsv}` |
| 2 (신설) | `dst-build.sh` | `BuildMonitorDst.C` | PRD | 뮤온·클린싱글 런당 DST 1개 → `dst/DST_<런>.root` — ★2차 프로덕션, 재생 가능 캐시 |
| 3 (신설) | `metrics.sh` | `BuildMetrics.C` | DST | IBD·acci·Li/He·fast-n(★예비) → `metrics_summary.tsv` |
| (과도기) | `ibd-summary.sh` | `BuildPairSummary.C` (+`RenePrdSingles.h`, `RenePairing.h`) | PRD | 페어링해서 IBD 후보 수·R_LL → `pair_summary.{txt,tsv}` — 교차검증용 + 4단계 입력, 유지 |
| 4 (개편) | `rate-trend.sh` | `BuildRateTrend.C` | pair_summary | 효율 보정 + 시간축 추이 그림 11종 → `rate_trend.{pdf,tsv}`, `*.png` |
| 5 (신설) | `websummary.sh` | `gen-runclass.sh` + `gen-summary-html.sh` + `publish_google.py` | 위 전부 + `runcatalog.db` | 런당 1줄 표(Type 열 포함) + 그림 + 구글사이트 발행. cron 매시 27분 |
| legacy 자동화 | `monitor-all.sh` | — | — | 1·(과도기)·4 만 순서대로 수동/구식 자동화. 운영 cron 은 5단계(`websummary.sh`)가 갖는다(★ 아직 미설치 — 배포 대기, CLAUDE.md §11.142 참조) |

```bash
tools/monitor/monitor-all.sh              # legacy 한 번 (1→과도기→4)
tools/monitor/monitor-all.sh --follow     # legacy 1시간마다 계속 갱신
tools/monitor/ibd-summary.sh --missing    # 아직 안 센 런을 알려준다
tools/monitor/websummary.sh --dry-run     # 지금 무엇을 처리·발행할지만 본다
```

**런이 하나 끝날 때마다 그림 오른쪽 끝에 점이 하나 붙는다.** x축은 그 런의 DAQ
시작 시각이고, 표가 누적되므로 다시 돌리기만 하면 추이가 계속 자란다. 지우고
새로 그리는 것이 아니다.

DST(2단계)·metrics(3단계) 상세는 바로 아래 두 절, legacy pair_summary(과도기)는
그 다음 절, rate_trend 는 4단계, websummary(표 생성 + 발행)는 5단계 — 1단계는
그 앞, 바로 아래다.

---

# 1단계 : run_summary — production 산출물(PRD)에서 뽑는 DAQ 운용 지표

**입력은 production 을 마친 데이터다.** 파형은 읽지 않고 두 가지만 본다.

```
<root>/<런번호>/PRD/PRD_<런번호>.<서브런>.root     TTree "Event"
      TCBTRGTime  [ns]  TCB 트리거 시각
      EventType   1 = target only(FADC) · 2 = veto only(SADC) · 3 = both
<root>/<런번호>/FADC_<런번호>.root.<서브런>        수집 시각(mtime)
```

FADC 원시 파일은 **모든 root 에서 찾는다.** 예전 `--outroot` 구성은 RAW 가
`/scratch`, PRD 가 `/Data_ssd` 라 둘이 다른 디스크에 있다. 못 찾아 PRD mtime
으로 떨어지면 런마다 기준이 달라져 3단계 그림의 x축이 어긋난다.

## 1. EventType 의 뜻은 실측으로 확인했다

문서를 믿지 않고 트리거 플래그와 대조했다 (run 4237 서브런 101).

| EventType | 개수 | `F_Triggered>0` | `S_Triggered>0` |
|---|---|---|---|
| 1 | 10,918 | 10,918 | 9 |
| 2 | 51,738 | 1 | 51,738 |
| 3 | 381 | 378 | 377 |

따라서 `total = 1+2+3`, `target = 1+3`, `veto = 2+3`, `both = 3`.

## 2. TCBTRGTime 은 되감긴다 ★

TCB 시계는 약 **16.78초**(2²⁴×1000 ns)마다 0 으로 돌아간다. 60초 서브런 하나에
서너 번 감긴다. `AnalysisStep1.C` 가 쓰는 규칙을 그대로 따른다.

```
if (t < prev) offset += prev;        globalTime = t + offset
```

풀지 않으면 livetime 이 음수가 되거나 16초로 나온다. carry 는 **런 전체에
이어 간다** — 그래야 서브런 사이의 빈 시간까지 한 시간축에서 잰다.

```
livetime = Σ (서브런의 마지막 트리거 − 첫 트리거)
span     = 런의 첫 트리거 ~ 마지막 트리거
dead     = span − livetime          duty = livetime / span
```

## 3. TTree cycle 이 여러 개다 ★

PRD 파일에는 `Event;2`, `Event;3` 처럼 cycle 이 여럿 있다(생산 중 autosave).
`TFile::Get("Event")` 가 **가장 높은 cycle** 을 주고 그것이 완전한 것이다.
**cycle 을 더하면 이벤트를 두 번 센다.**

## 4. 기존 분석 체인과 일치한다 (검증)

같은 런을 두 경로로 계산해 대조했다.

```
PRD 직독     run 4234  subrun 61  live 2486.5 s  total 14,627,857
Step1 경유   run 4234  subrun 61  live 2486.5 s  total 14,627,857
```

## 4.1 속도 — 끊어서 따라잡는다

파형을 빼고 `TCBTRGTime`·`EventType` 두 가지만 읽지만, `/scratch` 가 100 Mb
링크라(CLAUDE.md §11.12) 서브런당 약 **1.3초**다.

| 런 크기 | 걸리는 시간 |
|---|---|
| 61 서브런 | 약 80초 |
| 1,440 서브런 (24시간 런) | 약 30분 |
| 12,720 서브런 | 몇 시간 |

그래서 `--newest N` 으로 한 번에 처리할 런 수를 끊는다. `monitor-all.sh` 는
기본 2개다. 끊지 않으면 첫 실행이 며칠 물린다(지금 PRD 가 있는 런이 1,406개).
런 하나가 끝날 때마다 파일을 쓰므로 중간에 끊겨도 한 것은 남는다.

대상 런 찾기는 `/scratch/RAW/<6자리>/PRD` 디렉터리 존재로만 판단한다(약 40초).
안에 파일이 있는지까지 확인하면 NFS 왕복이 배로 든다.

## 5. `tsv` 에는 `-` 를 쓰지 않는다 ★고칠 때 주의

`txt` 에서 값이 없으면 `-` 로 찍지만, **`tsv` 에는 반드시 숫자(없으면 음수)를
쓴다.** 되읽기가 `>>` 로 파싱하기 때문에 `-` 를 만나면 그 행 전체가 조용히
버려진다. 실제로 그렇게 표가 15행에서 8행으로 줄고 run 4084 가 사라진 적이 있다.
`FmtF`(txt 용, `-` 를 낸다)와 `FmtRaw`(tsv 용, 항상 숫자)를 섞지 말 것.

`run_summary.tsv` 첫머리에 `# schema <N>` 이 있다. 열 구성이 바뀌면 이 번호를
올리고, 옛 파일은 **조용히 잘못 읽지 말고 거부한다**. 2·3단계가 이 열 순서를
그대로 읽으므로(`live_s` 자리가 어긋나면 `span_s` 를 livetime 으로 쓰게 된다)
`WriteTsv` 를 고칠 때 `BuildPairSummary.C` · `BuildRateTrend.C` 도 함께 볼 것.

---

# 2단계 : dst-build — 2차 프로덕션 DST (재생 가능 캐시)

## 왜 두는가

fast-n 과 Li/He 는 둘 다 "이 후보가 직전 (샤워링) 뮤온에서 얼마나 떨어져
있나"를 요구한다. PRD 전체를 훑어야만 나오는 값이라, 레시피(문턱값·창)가
바뀔 때마다 PRD 를 다시 읽으면 12,722서브런짜리 런 하나에 몇 시간이 든다.
**런당 DST 파일 하나에 뮤온 시각과 클린 싱글만 뽑아 두면, 레시피가 바뀌어도
PRD 재독 없이 DST 에서 초 단위로 다시 계산된다.** IBD·acci 도 같은 이득을
받는다 — 컷을 바꾸는 것이 DST 재계산 한 번으로 끝난다.

**★ 산출물은 재생 가능 캐시다 — 백업·dataflow 청소 대상이 아니다.** PRD 만
있으면 `dst-build.sh --force` 로 언제든 다시 만든다. Merged 를 재생 가능
캐시로 판정한 것(CLAUDE.md §11.149)과 같은 이유 — 파생 자료는 원본이 있는 한
장기보관할 값어치가 없다.

## 스키마 2 — `DST_<런>.root`, 트리 4개 (`BuildMonitorDst.C`, 2026-09-08~)

```
T_Singles   clean single 전체, 시간순      evt_id(Int_t)  sub_id(Int_t)
                                           t_us(Double_t)  pe(Float_t)
                                           psd(Float_t) ★ 꼬리비율 = Σch tail(피크+40 ns 이후)
                                                          / Σch total. -1 = 없음
T_Sat ★     muon·after-muon 은 통과했으나   sub_id(Int_t)  t_us(Double_t)
            **포화라 single 에서 버린** 사건  pe(Float_t, 잘린 적분값 = 하한)
T_Muons     뮤온 전체, 시간순              sub_id(Int_t)  t_us(Double_t)
                                           pe(Float_t, -1 = 순수 veto, target
                                           파형 없음)  sat(Char_t, 포화 여부)
T_Info      메타데이터 (엔트리 1개)        run  thr_npe  veto_us  n_subrun
                                           n_bad  live_s  built  schema(=2)  psd_tail_ns(=40)
```

**single 의 개수·순서·pe 는 스키마 1 과 같다** — legacy 패리티 게이트가 그것에
걸려 있다. 더한 것은 열 하나(`psd`)와 트리 하나(`T_Sat`)뿐이다.

**왜 더했나** (배경 레시피 v2 스펙 `docs/superpowers/specs/2026-09-08-background-recipes-v2-design.md`)

- `T_Sat` — fast-n 사이드밴드(prompt 12 MeV 이상)는 **실측 93 % 가 포화**라
  (run 4332 : NPE 7265–15000 구간 15개 중 14개), clean single 만으로는 표본의
  7 % 로 만든 값이었다. 포화 사건을 따로 담아 사이드밴드 페어링 때 합친다.
- `psd` — NEOS 는 fast-n 을 PSD 로 잡는다(고영주 §4.3.2, 김진유 §5.1.5). 이
  사이트에서는 분리력이 약해(AmBe run 4221 : n-Gd 포획이 뒤따르는 prompt
  0.316±0.029 대 그렇지 않은 single 0.289±0.043, **FoM 0.53**, NEOS 는 2.8)
  사건별 컷은 못 하지만, 런 단위 γ-band 평균·RMS 는 **파형 안정성 지표**가
  된다 — 같은 꼬리비율이 run 4221 에서 0.29, run 4332 에서 0.40 이다.

싱글에는 '직전 샤워링 뮤온까지 dt' 열을 **저장하지 않는다.** 샤워링 문턱이
파라미터라 뮤온 트리에서 그때그때 계산해야 맞고, 싱글에 박아 두면 문턱이
바뀔 때 낡은 값이 남는다.

**스키마 1 DST 는 자동으로 다시 만든다** — `DstUpToDate` 가 `schema==2` 를
함께 보고, 서브런 캐시도 `psd` 열·`T_Sat` 이 없으면 파형에서 다시 만든다.

## 캐시 — legacy 와 반드시 분리한다 ★

```
<OUT>/cache/                dst-build 전용 서브런별 캐시. Singles + Muons + State
<OUT>/cache/singles/        ibd-summary.sh(legacy) 전용 캐시 — 뮤온이 없다
```

**같은 이름이라도 합치면 안 된다.** legacy 캐시는 뮤온을 담지 않으므로,
dst-build 가 그것을 그대로 읽으면 carry 가 이중 적용되는 함정에 빠진다(Task 3
리뷰가 도달 가능성까지 확인 — 지금 코드 경로에서는 발생하지 않지만, 두 캐시를
합치는 순간 다시 열리는 위험이다). 자리를 분리해 애초에 그 함정에 들어설 길을
막았다(컨트롤러 판정 R3).

부분 캐시 히트(예: 뮤온이 없는 옛 캐시를 잘못 읽은 경우)는 carry 를 전진시킨
채로 남기지 않는다 — 실패하면 그 서브런 진입 전 carry 로 되돌린다.

## 실측 비용 (첫 빌드, 캐시 미스 기준)

| 런 | DST 크기 | 서브런 | 소요시간 | 서브런당 | singles | muons |
|---|---|---|---|---|---|---|
| 4305 | 406 MB | 1,440 | 1,930.2 s | 1.34 s | 7,601,557 | 68,654,229 |
| 4237 | 3.5 GB | 12,722 | 18,170 s (≈5.05h) | 1.43 s | 69,360,981 | 610,833,552 |

둘 다 실패 0. 재실행(DST 최신, 캐시 전부 적중)은 초 단위로 끝난다(4305 재실행
5.2s).

## 사용

```bash
tools/monitor/dst-build.sh --list 4237,4240
tools/monitor/dst-build.sh --list 4237 --force          # 강제로 다시 만든다
tools/monitor/dst-build.sh --list 4237 --max-subrun 100 # 앞 100개만 (시험용)
```

`DstUpToDate()` 는 **서브런 개수만으로** 최신 여부를 판단한다. `--max-subrun`
으로 일부러 축소해 만든 DST 가 있으면, 나중에 전체를 다시 만들 때 `--force`
를 반드시 쓸 것 — 안 그러면 완전한 DST 를 조용히 축소판으로 덮어쓸 위험이
있다(캐시가 있으므로 다시 만드는 비용 자체는 크지 않다).

---

# 3단계 : metrics — DST 에서 지표 계산 (`metrics_summary.tsv`)

`BuildMetrics.C` 가 DST(`T_Singles`+`T_Muons`)를 읽어 IBD·accidental·
(★예비) Li/He·fast-n 을 계산한다. 컷은 `AnalysisCondition.h` 값이 기본이고,
`config/monitorcuts.params` 로 오버라이드할 수 있다.

## `metrics_summary.tsv` — 42열 (`# schema 2`, 2026-09-08~)

```
run  tag  src  live_s  n_paired  n_paired_acci  n_ibd  n_ibd_acci  n_single
r_ll  n_subrun  n_mu  n_mu_shower  n_lihe  e_lihe  lihe_stat
n_fn_side  n_fn_side_scaled                                      <- 여기까지 18열은 schema 1 과 같은 자리
n_fn_side_lin  fn_sat_frac  n_lihe_rev  e_lihe_rev  r_mu_shower
n_acci_rp  n_mult_rej  psd_mean  psd_rms  n_ibd_psd_nlike
dt_min  dt_max  dt_acci  s2_lo  s2_hi  iso_pre  iso_post
mu_shower_npe  fn_e_lo  fn_e_hi  lihe_fit_lo  lihe_fit_hi  lihe_li_frac  psd_nsig
```

| 열 | 뜻 |
|---|---|
| `run` / `tag` / `src` | 런 번호 / `_nGd`·`_nH` / 선원(§6.3 과 같은 규칙, `runtype.tsv`) |
| `live_s` | livetime [s] (DST `T_Info.live_s`) |
| `n_paired` / `n_paired_acci` | on-time / off-time 페어 수 (multiplicity 전) |
| `n_ibd` / `n_ibd_acci` | on-time / off-time IBD 후보 수 (§6.1 의 우발 빼기 **전** 원값) |
| `n_single` / `r_ll` | DST 의 clean single 전체 개수 / 1.2 MeV 이상 clean single rate [Hz] |
| `n_subrun` / `n_mu` | DST 를 만들 때 읽은 서브런 수 / 전체 뮤온 |
| `n_mu_shower` / `r_mu_shower` | 샤워링 뮤온(`pe > mu_shower_npe`) 개수 / rate [Hz]. **1/R 이 τ(⁹Li)=0.257 s 에서 얼마나 떨어져 있나**를 표가 스스로 말한다 |
| `n_lihe` / `e_lihe` / `lihe_stat` | ★예비 Li/He 적합 수·오차·상태 (`ok`\|`degen`\|`lowstat`\|`nofit`\|`noshower`\|`off`) |
| `n_lihe_rev` / `e_lihe_rev` | 같은 적합을 **다음** 샤워링 뮤온까지의 시간에 (시간 역방향 대조). 물리 상관이 없으니 **0 과 맞아야 한다** |
| `n_fn_side` | prompt 창을 [fn_e_lo, fn_e_hi] MeV 로 올린 페어링의 on-time 수. **T_Sat(포화 사건)을 합쳐** 센다 |
| `n_fn_side_scaled` / `n_fn_side_lin` | 신호창 [1.2,12] MeV 로 외삽한 fast-n 수. `scaled` = 0차(평평)·1차(선형) 외삽의 평균(Daya Bay §4.3), `lin` = 1차 단독. 둘의 차이가 계통오차 |
| `fn_sat_frac` | 사이드밴드 에너지 구간 사건 중 포화 사건의 비율. 1 에 가까우면 에너지 축이 눌려 있다는 뜻 (schema 1 DST 면 -1) |
| `n_acci_rp` | accidental 교차검증 : R_S1·R_S2·(dt_max−dt_min)·live (RENE PTEP 2025 §2, Daya Bay Eq.1). `n_paired_acci × acciScale` 과 같은 양(multiplicity 전)이라 나란히 읽는다 |
| `n_mult_rej` | multiplicity 가 걸러낸 on-time 쌍에서 우발 몫(off-time 의 같은 값 × acciScale)을 뺀 것 = **뮤온 유발 다중 중성자**(NEOS 'correlated background') 지표 |
| `psd_mean` / `psd_rms` | 1–3 MeV clean single 의 꼬리비율 γ-band 평균·RMS (**파형 안정성 지표**. -1 = psd 없음) |
| `n_ibd_psd_nlike` | IBD 후보 prompt 중 psd > mean + psd_nsig·rms 인 수. NEOS 의 p_psd 정의(§4.3.2.2)를 런 단위로. 분리력이 약해(FoM 0.5) **비율의 추이**로만 본다 |
| `dt_min` ~ `iso_post` | IBD 페어링에 **실제 적용된** 창값 |
| `mu_shower_npe` ~ `psd_nsig` | 배경 컷에 **실제 적용된** 값 |

`lihe_stat` — `ok`(적합 성공) · `degen`(R_μ 가 1/τ_Li 의 2 배 안이라 우발항과
축퇴. 값은 적혀 있지만 웹에는 안 나간다 — `mu_shower_npe` 를 올릴 것) ·
`lowstat`(창 안 표본이 `lihe_min_cand` 미만) · `nofit` · `noshower`(샤워링 뮤온
0) · `off`. **`ok` 가 아니면 `n_lihe`=`e_lihe`=`-1`** 이다 — 소비자
(`gen-summary-html.sh`)는 반드시 `lihe_stat` 을 먼저 본다.

## `config/monitorcuts.params` — 컷 손잡이

`.example` 에서 복사해 쓴다(gitignore 대상, 파일이 없으면 아래 기본값):

| 키 | 기본값 | 뜻 |
|---|---|---|
| `mu_shower_npe` | 3000 | 이 NPE 초과 target 뮤온을 '샤워링'으로 본다 |
| `lihe_fit_lo_s` / `lihe_fit_hi_s` | 0.002 / 10.0 | Li/He 적합 창 [s] |
| `lihe_min_cand` | 100 | 창 안 표본이 이보다 적으면 적합하지 않는다(`lowstat`) |
| `fn_e_lo_mev` / `fn_e_hi_mev` | 12.0 / 50.0 | fast-n prompt 사이드밴드 [MeV] |
| `fn_tag_s` | 0.1 | 직전 샤워링 뮤온에서 이 시간 안의 후보 수 = `n_fn_mutag` |

**IBD 컷 오버라이드 10종**(`s1_lo_npe s1_hi_npe s2_lo_mev s2_hi_mev dt_min_us
dt_max_us dt_acci_us iso_pre_us iso_post_us lower_npe`, `PairWindows` 멤버와
1:1)은 기본값이 없다 — 주석을 푼 것만 적용되고, **하나라도 풀면 `--verify` 가
그 자리에서 거부한다**(legacy 와 컷이 달라 대조가 무의미하다).

**★ `*_mev` 는 분석 헤더 자신의 `MeVToNpe()` 로 NPE 가 된다** — 계획이 처음
정한 선형 `_NPE_MEV` 가 아니다(컨트롤러 판정 R5). 창 상수를 만든 바로 그
함수라(`AnalysisCondition.h` : `S2_MIN_NPE = MeVToNpe(6)`), `s2_lo_mev = 6`
이 기본 창을 정확히 되살린다. 적용된 실효값은 `metrics_summary.tsv` 의 컷
열에 MeV 로 남으므로, 표만 보고도 어떤 컷의 결과인지 알 수 있다.

## 전환 게이트 — `metrics.sh --verify`

```bash
tools/monitor/metrics.sh --list 4237                 # metrics_summary.tsv 를 만들거나 갱신
tools/monitor/metrics.sh --verify                     # 빌드 없이 대조만
tools/monitor/metrics.sh --list 4237 --verify          # 만들고 나서 대조
```

`metrics_summary.tsv` 와 `pair_summary.tsv`(legacy) 에 **공통으로 있는
(run,tag) 행**에서 `n_ibd`·`n_ibd_acci` 를 대조하고
`[VERIFY] 공통 N 행, 불일치 M` 을 찍는다. `M>0` 이면 exit 1 — **`websummary.params`
의 `metrics_source` 를 `dst` 로 바꾸는 것은 이 게이트가 반복적으로 통과한
뒤, 사람이 승인해야 한다.** IBD 오버라이드가 걸려 있으면(§ 위) 대조 자체가
무의미하므로 `--verify` 는 그 자리에서 거부한다.

**실측 (2026-09-08)**

```
[VERIFY] 공통 2 행, 불일치 0
```

공통 행은 legacy `pair_summary.tsv` 에 **있는** (run,tag) 만 잡힌다. run 4305
는 두 표 모두에 있어(각 `_nGd`/`_nH`) 공통 2행이 되고, 불일치 0 이다. run 4237
은 `metrics_summary.tsv` 에는 있지만(DST 경로로 이미 계산됨, 아래) legacy
`pair_summary.tsv` 에는 아직 없다 — legacy 페어링(`ibd-summary.sh`)이 4237 을
아직 돌지 않았기 때문이다(과도기 절이 "51시간, 급하지 않다"로 못박아 둔 바로
그 작업). **그래서 지금은 공통 2행이 맞는 상태이고, 그 2행의 불일치는 0 이다.**
4237 자체의 값은 DST 경로로 이미 확보돼 있다.

**run 4237 실측값** (DST 경로, `metrics.sh --list 4237`, DST 로드 83.5s 포함
총 수 분):

```
_nGd  live 763,275.1s  n_ibd=854      n_ibd_acci=250      lihe=455.5±22.8(ok)     fn_side=6  (환산 1.7)
_nH   live 763,275.1s  n_ibd=607,486  n_ibd_acci=555,257  lihe=332,054.4±576.8(ok) fn_side=36 (환산 10.2)
```

4237 을 legacy 경로로도 대조하려면 `ibd-summary.sh` 로 51시간짜리 페어링을
먼저 돌려야 한다 — 급하지 않으므로 미뤄 둔다. DST 값 자체는 이미 쓸 수 있고,
4305 에서 게이트가 이미 한 번 통과했으므로 같은 코드 경로다(전환 승인의
근거는 반복 통과이지, 4237 한 런의 단독 대조가 아니다).

## 배경 레시피 v2 — ★예비. 분석팀 검증 전까지 물리로 읽지 말 것 (2026-09-08)

논문(NEOS 박사논문 2편 · PRL 118 121802 · Daya Bay 1402.6876 · RENE PTEP 2025
093C03)의 정의를 읽고 RENE 트리에서 잴 수 있는 형태로 다시 세운 것이다. 설계와
근거는 `docs/superpowers/specs/2026-09-08-background-recipes-v2-design.md`.
**v1(2026-09-08 오전)이 왜 틀렸는지**가 곧 v2 의 정의다.

| 배경 | 논문의 정의 | v1 의 문제 | v2 |
|---|---|---|---|
| accidental | off-window(time-delayed coincidence) · R₁·R₂·T | — | off-window 그대로 + **`n_acci_rp` 로 rate-곱을 나란히** |
| fast-n | NEOS : PSD 로 prompt 의 proton recoil 을 잡는다. Daya Bay : prompt 12–100 MeV 사이드밴드를 0차·1차 외삽 | 사이드밴드 표본이 clean single 뿐 → **포화(93 %)를 다 버린 채** 7 % 로 셌다 | `T_Sat` 을 합쳐 센다. 0차·1차 외삽 평균 + 1차 단독 + 포화 비율 |
| ⁹Li/⁸He | Daya Bay Eq.2 : `N_LiHe[R λ_Li e^{−λ_Li t}+(1−R) λ_He e^{−λ_He t}] + N_unc R_μ e^{−R_μ t}` | 우발항을 **상수**로 두었고 R_μ=1.33 Hz(문턱 3000)가 1/τ 와 축퇴 → 후보의 56 % 를 흡수 | 우발항 = R_μ e^{−R_μ t} (R_μ 는 데이터에서 고정), 문턱 20000 (R_μ 0.63 Hz, 1/R 1.6 s) · **시간 역방향 대조 `n_lihe_rev`** (0 이어야 한다) · 축퇴면 `degen` |
| 상관 다중중성자 | NEOS : multiplicity 로 제거 | 없었다 | `n_mult_rej` = multiplicity 가 걸러낸 쌍의 우발 초과분 |
| PSD | NEOS p_psd = (r − m_γ(E,t))/σ_γ, 3.5 σ 기각 | 없었다 | `psd_mean`/`psd_rms`(γ-band) + `n_ibd_psd_nlike`(mean+3σ 밖) — 분리력이 약해 추이용 |

**★ 실측으로 확정한 이 사이트의 제약** (읽기 전용, 2026-09-08)

```
PSD    AmBe run 4221 : 포획이 뒤따르는 prompt 0.316±0.029 / 아닌 single 0.289±0.043 -> FoM 0.53 (NEOS 2.8)
       같은 꼬리비율이 run 4332 에서는 0.40 (4221 은 0.29) -> 파형이 런에 따라 변한다 = 런 품질 지표
포화   run 4332 : NPE 1500-3000 의 2.8 %, 3000-5000 의 12 %, 7265 이상의 93 % 가 포화
뮤온   run 4305 : target 뮤온 3.05 Hz, pe>3000 1.33 Hz, pe>20000 0.63 Hz, pe>50000 은 0 (적분창 1 µs)
```

**합성 DST 검증** (`tests/monitor-bg.test.sh`, 12/12) — Poisson 뮤온(0.2 Hz) 위에
Li/He 참값 500 을 심으면 **507.5 ± 26.2** 로 되찾고, 시간 역방향은 **0.0 ± 3.9**.
포화 사이드밴드 40쌍을 T_Sat 에 두면 `n_fn_side=40`, `fn_sat_frac=1.00`.
n-like psd 60개를 심으면 63 을 센다(3 은 3σ 꼬리의 기대치).

**여전히 못 하는 것** — fast-n 은 이 사이트에서 가장 큰 배경일 가능성이 높다
(NEOS 20 mwe 에서 off 배경의 73 % 가 PSD 로 제거된 fast-n → 톤당 60/일 → RENE
0.27 t 면 ~16/일, n-Gd 후보 ~90/일의 20 %). 사이드밴드 외삽은 **크기**를 주지
사건별 제거를 못 한다. 사건별 제거는 PSD 개선(분석팀 몫)이 필요하다. ⁹Li/⁸He 는
이 크기·깊이에서 ~0.5/일로 작을 것이라 적합값은 대부분 **상한**으로 읽는다.

**둘 다 웹 표에는 '(예비)' 로 나간다**(`lihe_stat=="ok"` 이고
`n_fn_side_scaled>=0` 일 때만 값을 채우고, 그렇지 않으면 '—').

---

# (과도기) pair_summary — legacy neutrino candidate (교차검증용, 개략)

DST 경로(3단계)가 반복 검증을 통과하고 사용자가 `metrics_source=dst` 로
승인하기 전까지, **웹 표의 실제 출처는 여기다.** 4단계(`rate-trend.sh`)의
추이 그림도 `metrics_source` 설정과 무관하게 **지금은 이 표만** 읽는다 —
`BuildRateTrend.C` 는 `pair_summary.tsv` 를 직접 연다.

**★ 2026-08-18 에 입력이 바뀌었다.** 예전에는 분석 쪽
`/scratch/junkyo/SampleFiles/Step3` 의 페어링 산출물을 읽기만 했다. 그러면
저쪽이 그 런을 아직 안 돌렸을 때 이 표가 멈춘다 — 실제로 1단계가 run 4291 까지
갔는데 2단계는 4240 에서 멎어 있었다. 이제 **1단계와 똑같이 PRD 를 읽고
페어링까지 여기서 한다.**

```
PRD ──► clean single ──► 페어링 ──► IBD 후보 수 + R_LL
     RenePrdSingles.h   RenePairing.h
     (= 분석 Step1+Step2) (= 분석 Step3+Step4)
```

## 6.0 물리는 베끼지 않는다. 분석 코드를 include 한다

파형 → NPE 변환, 보정 상수, 컷 값은 전부 분석 쪽 것을 그대로 쓴다.

```c
#include "/home/ojk/analysis3/essential/helper_functions.cc"   // GetPed/GetQsum/…
#include "/home/ojk/analysis3/essential/AnalysisCondition.h"   // DT_*/S2_*/ISO_*
```

베껴 두면 저쪽이 바꿨을 때 이 표만 조용히 틀린 값이 된다(§5.8 에서 production
매크로를 호출만 한 것과 같은 이유다). 경로는 `RENE_ANA_HELPERS` /
`RENE_COND_HEADER` 로 바꾼다.

**예외는 페어링 loop 하나뿐이다.** 분석 쪽 `RunBothChannels.C::PairAndSelect`
는 결과를 파일로 쓰는 것이 목적이라 **세기만 하는 진입점이 없다.** 그래서
`RenePairing.h` 에 loop 을 따로 두었고, 그만큼 갈라질 수 있다. 그래서
`ibd-summary.sh` 는 분석 Step4 가 있는 런에서 **매번 수를 대조하고** 다르면
알린다.

## 6.0.1 재현하는 규칙 (분석 Step1/Step2 그대로)

1. `globalTime = TCBTRGTime + offset`. TCB 시계가 되감기면 보정하고, carry 는
   **런 전체에 이어 간다** — 서브런마다 0 부터 다시 세면 서브런 경계를 넘는
   coincidence 창이 깨진다.
2. muon veto : SADC 패널 15개 중 위/아래가 함께 켜진 것이 있으면 veto.
   **`muonTime` 갱신이 `dt` 계산보다 먼저다.**
3. FADC ch0·ch1 파형을 적분해 NPE 를 얻는다.
4. Step2 컷을 **이 순서로** — muon → after-muon(`dt < 150 us`) → saturation.
   순서를 바꾸면 범주별 수가 달라진다.
5. `(q0<5 && q1<5)` 를 버리고 `q0+q1 > 610.6 NPE`(1.2 MeV) 인 것만 single 로
   남긴다. **`float` 로 깎아서 비교한다** — Step2 가 float 로 저장하므로
   그렇게 하지 않으면 경계에 걸친 이벤트에서 결과가 갈린다.

## 6.0.2 검증 — 분석 체인과 수가 정확히 맞는다 ★

두 토막으로 나눠 실측했다. 나누지 않으면 어디가 틀렸는지 알 수 없다.

**(A) 재구성** — run 4237 서브런 98~100 을 순서대로 돌려 carry 를 세운 뒤,
서브런 100 을 같은 서브런의 분석 Step2 part 와 대조했다.

```
single 개수   here 5,739   analysis 5,739     일치
evt_id 어긋남  0
pe 어긋남      0        (최대 0 NPE)
간격 어긋남    0        (최대 0 us)
```

**single 목록이 비트 단위로 같다.** clean 11,356 개도 예전에 기록해 둔 값과
같다.

**(B) 페어링** — 분석 Step2 에서 읽은 **같은 입력**(run 4237 전체, single
72,658,494 개)에 `RenePairing.h` 를 돌려 Step3/Step4 트리와 대조했다.

| | `_nGd` here / analysis | `_nH` here / analysis |
|---|---|---|
| paired | 7,879 / 7,879 | 798,857 / 798,857 |
| paired_acci | 3,023 / 3,023 | 664,641 / 664,641 |
| ibd | 2,097 / 2,097 | 601,739 / 601,739 |
| ibd_acci | 1,377 / 1,377 | 551,422 / 551,422 |

**여덟 개 전부 일치.** (A)+(B) 로 PRD → single → 후보 전 구간이 분석 체인과
같은 값을 낸다는 것이 확인됐다.

## 6.0.3 비용과 캐시 ★ 여기가 실무에서 제일 중요하다

파형을 읽으므로 1단계보다 훨씬 비싸다. **어느 디스크에 있느냐가 13배를 가른다.**

| 위치 | 서브런당 | 24시간 런(1440) | 병목 |
|---|---|---|---|
| `/Data_ssd` (로컬 NVMe) | **1.1초** | 약 27분 | CPU |
| `/scratch` (100 Mb NFS) | 14.6초 | 약 5.8시간 | 링크 |

그래서 **런이 아직 `/Data_ssd` 에 있을 때 돌리는 것이 압도적으로 유리하다.**
dataflow 가 `/scratch` 로 보내고 나면 13배가 된다.

서브런마다 single 목록을 캐시한다(`<OUT>/cache/singles`). 실측 —

```
run 4290 (197 서브런)  처음 228초  →  캐시 재사용 0.7초   (수는 동일)
캐시 크기 14 MB (서브런당 71 KB).  24시간 런이면 약 100 MB
```

중간에 끊겨도 한 것은 남고, 런 하나가 끝날 때마다 표를 쓴다. 캐시에는 그때 쓴
문턱과 veto 창을 함께 적어 두고, 값이 바뀌면 무시하고 다시 만든다.

자동화에서는 `--newest N` 으로 끊는다(`monitor-all.sh` 기본 2개). 끊지 않으면
PRD 가 있는 런이 1,400개가 넘어 첫 실행이 며칠 물린다.

## 6.1 우발 빼기 — `DrawIBD.C` 규약을 그대로 따른다

on-time 창은 `dt ∈ [DT_MIN, DT_MAX]` 라 폭이 `DT_MAX − DT_MIN` 인데,
off-time 창은 `[DT_ACCI, DT_ACCI + DT_MAX]` 라 폭이 `DT_MAX` 다. **두 폭이
같지 않다.** 그래서 폭 비율로 맞춘 뒤 뺀다.

```
acciScale   = (DT_MAX − DT_MIN) / DT_MAX        n-Gd 0.99 · n-H 0.995
N_candidate = N_IBD − acciScale × N_IBD_Acci
err         = sqrt(N_IBD + acciScale² × N_IBD_Acci)      통계 오차만
```

배율을 1 로 두면 우발을 과하게 빼서 후보가 낮게 나온다.
`DrawIBD.C:164` 의 `h_dt_sub->Add(h_dt_on, h_dt_acci, 1.0, -acciScale)` 와
같은 양을 세는 것이 목적이므로, **규약을 바꾸려면 그쪽과 함께 바꿀 것.**

## 6.2 컷 상수는 복제하지 않는다 (§6.0 참조)

표에 찍히는 컷은 **문서가 아니라 코드에서 읽은 값**이다. 그래서 표에 찍히는 컷은 **문서가 아니라 코드에서 읽은 값**이다. 둘이 다를 수
있다 — `README_pipeline.md` 는 n-Gd S2 를 `[7.77, 9.36]` 이라 적었지만
코드에서 그 줄은 주석이고 실제로는 **`[6.0, 10.0]`** 이 쓰인다(2026-08-18 확인).

## 6.3 선원 런을 반드시 구분한다 ★

AmBe · Cf252 를 넣고 받은 교정 런은 **후보 수가 백만 단위로 나온다.** 선원이
만든 중성자이지 neutrino 가 아니다. 구분하지 않으면 합계가 통째로 무의미해진다.

`ibd-summary.sh` 가 런 카탈로그(`runcatalog.db`)의 `rundesc` 에서 선원 이름을
뽑아 `runtype.tsv` 를 만들고, 매크로가 그것을 붙인다.

- `src = none` — 선원 없음. **채널별 합계는 이것만 더한다.**
- `src = AmBe` / `Cf252` / … — 교정 런. 표에는 남기되 합계에서 뺀다.
- `src = ?` — 카탈로그에 없거나 설명에서 못 읽었다. 안전하게 합계에서 뺀다.

실측 예 (같은 n-Gd 채널인데 자릿수가 다르다) :

```
4224  _nGd  AmBe     ibd 847,911   acci 3,095.7   cand 844,815.3   S/B 272.90
4237  _nGd  none     ibd   2,097   acci 1,363.2   cand     733.8   S/B   0.54
```

## 6.4 지금 나오는 값

**입력이 바뀌면서 표를 처음부터 다시 만들고 있다.** 옛 표(분석 Step3/Step4 를
읽던 것)는 열이 달라 `# schema 2` 검사에 걸려 자동으로 버려진다. 옛 값은
`/scratch/RunSummary/old-schema1/` 에 남겨 두었다.

```
run 4290  서브런 197  live 11,820 s  single 1,047,623  R_LL 88.63 Hz   [228 s]
   _nGd   paired 103     ibd 26      acci 10.9      cand 15.1 ± 6.1
   _nH    paired 9,490   ibd 8,019   acci 7,494.3   cand 524.7 ± 124.4
run 4291  서브런 865  live 51,900 s  single 4,607,001  R_LL 88.77 Hz  [1,019 s]
   _nGd   paired 478     ibd 153     acci 99.0      cand 54.0 ± 15.8
   _nH    paired 40,997  ibd 34,787  acci 32,929.5  cand 1,857.5 ± 259.9
```

**옛 표와도 맞는다.** Part B 에서 나온 run 4237 `_nGd` 의 `ibd 2,097` /
`ibd_acci 1,377` 은 옛 표의 `ibd 2,097` · `acci 1,363.2` · `cand 733.8` 과
그대로 이어진다(`acci = 0.99 x 1,377`). 입력을 바꿨어도 **같은 런이면 같은 행**이
나온다는 뜻이다.

**깨진 서브런은 조용히 넘기지 않는다.** run 4291 은 서브런 866 을 읽지 못했다고
알린다 — 그 런이 쓰기 도중에 끊겨 마지막 파일이 잘려 있기 때문이다(§11.17).
1단계도 같은 서브런을 `읽지 못한 서브런 1 개`로 표시한다. **두 도구가 독립적으로
같은 곳을 짚었다.**

livetime 도 두 단계가 맞는다 — 4291 이 1단계 `51,899.941 s`, 2단계 `51,899.9 s`.

되채우는 순서는 **최신 런부터**다. 옛 런은 PRD 가 `/scratch` 에 있어 13배
비싸고(§6.0.3), run 4237 처럼 12,720 서브런짜리는 51시간이 걸린다. 급하지 않다.

**★ 2026-09-08 현재도 이 51시간은 그대로 안 돌았다.** run 4237 은 3단계
(DST 경로, `metrics.sh`)로는 이미 값이 있다 — 5.05시간짜리 DST 빌드 하나로
끝났다(3단계 절 참조). 여기(legacy 페어링)에서 4237 을 대조하려면 이
51시간짜리 작업을 언젠가 별도로 돌려야 한다.

**이 cand 는 개략값이다.** 우발만 뺀 것이고 검출 효율, 우주선 유발 배경
(fast neutron, ⁹Li/⁸He), 컷 효율 보정이 들어 있지 않다. 물리 결과가 아니라
**"수집이 정상이면 이만큼 나온다"는 운용 지표**로 볼 것. n-H 의 S/B 가 0.1
언저리인 것은 이 채널에서 추가 컷 없이는 정상이다.

# 4단계 : rate_trend — 시간축 추이와 효율 보정

`rate-trend.sh` 가 `pair_summary` 를 읽어 **시각을 x축으로** 그린다(§ 위
'과도기' 참조 — `metrics_source=dst` 로 바뀌어도 이 4단계 자체는 여전히
`pair_summary.tsv` 만 읽는다). 쪽마다 PNG 도 하나씩 나오므로 화면에 띄워
두기 좋다. **11종**(기존 7 + Task 6 신설 4).

| 쪽 | PNG | 내용 |
|---|---|---|
| 1 | `rate_trend_candidates.png` | 런당 IBD 후보 수 (우발 뺀 값) |
| 2 | `rate_trend_rate_raw.png` | 보정 전 rate [/day] |
| 3 | `rate_trend_rate_corrected.png` | **효율 보정 rate [/day]** ← 핵심 |
| 4 | `rate_trend_efficiency.png` | ε_iso, ε_tot 추이 |
| 5 | `rate_trend_accidental.png` | 우발 [/day] |
| 6 | `rate_trend_rll.png` | R_LL — ε_iso 가 흔들리면 여기가 원인이다 |
| 7 | `rate_trend_cumulative.png` | 누적 후보 수 |
| 8 (신설) | `rate_trend_evt_total.png` | 전체 트리거 rate [Hz] (`n_type1+2+3`, 런당 점 하나) |
| 9 (신설) | `rate_trend_evt_target.png` | Target only(FADC) rate [Hz] |
| 10 (신설) | `rate_trend_evt_veto.png` | VETO only(SADC) rate [Hz] |
| 11 (신설) | `rate_trend_evt_coinc.png` | VETO+Target coincidence rate [Hz] |

두 채널의 크기가 100배쯤 달라서 후보 수·rate 쪽은 **로그축**이다. 선형축이면
n-Gd 이 바닥에 깔려 보이지 않는다.

**★ 8~11번이 비어도(`run_summary.tsv` 가 없거나 겹치는 런이 없거나) PDF 는
항상 닫힌다.** 처음에는 마지막 쪽이 닫는 구조라, 8~11번이 전부 빈 채로
반환되면 PDF 스트림이 열린 채로 남는 결함이 있었다(Task 6 리뷰가 Critical 로
잡았다) — 지금은 데이터 유무와 무관하게 항상 실행되는 블록이 마지막에 따로
스트림을 닫는다.

## 8.1 효율 — 분석 쪽 정의를 그대로 쓴다

```
eps_T   = exp(-DT_MIN/tau) - exp(-DT_MAX/tau)        diagnostics/EffCutFlow.C:86
          포획시간 tau : n-Gd 25 us, n-H 171 us       같은 파일 :85
eps_iso = exp(-R_LL x (ISO_PRE + ISO_POST))          diagnostics/IsolationEfficiency.C:62
          R_LL = 1.2 MeV 이상 clean single 의 rate

rate_corr = rate_raw / (eps_T x eps_iso x eps_E)
```

**ε_E(에너지창)는 자동으로 구할 수 없다.** 봉우리 fit 이 필요해 사람이 봐야
한다. 기본 1.0 이고 보정에서 **빠져 있다.** 값을 알면 넣어 줄 수 있다.

```bash
tools/monitor/rate-trend.sh --eps-e 0.85
```

## 8.2 R_LL 은 2단계가 전수로 준다 ★

`run_summary` 의 `n_clean / live` 를 R_LL 로 쓰고 싶어지지만 **틀린다.**
clean 이벤트에는 에너지 문턱이 없다(muon / after-muon / saturation 컷만).
실측 — run 4237 서브런 100 에서 clean 11,356 개 중 1.2 MeV 이상은
**5,739 개뿐**이다. 그대로 쓰면 R_LL 이 두 배가 되고 ε_iso 가 낮아져
보정 rate 가 부풀려진다.

예전에는 여기서 분석 Step2 part 를 서브런 20개쯤 **표본으로** 열어 쟀다.
이제 2단계가 PRD 에서 런 전체의 single 을 이미 세므로 `pair_summary.tsv` 의
`r_ll` 열을 그대로 읽는다 — **표본이 아니라 전수**이고, `/scratch/junkyo` 에
기대지 않는다. `rll.tsv` 는 더 이상 만들지 않는다(옛 파일이 있으면 `r_ll` 이
비어 있는 행에만 예비로 쓴다).

다시 재려면 2단계를 다시 돌린다 : `ibd-summary.sh --force <런>`.

## 8.3 지금 나오는 값

```
run 4290  R_LL 88.63 Hz  eps_T 0.942  eps_iso 0.948  eps_tot 0.894
   _nGd  rate 110.4 -> 보정 123.6 ± 49.6 /day
run 4291  R_LL 88.77 Hz  eps_T 0.942  eps_iso 0.948  eps_tot 0.894
   _nGd  rate  89.9 -> 보정 100.6 ± 29.5 /day
```

R_LL 이 지금까지 잰 런에서 88~95 Hz 로 안정적이라 ε_iso 도 0.948 근처에서
거의 변하지 않는다. 4290 은 livetime 이 3.3시간뿐이라 오차가 크다.

# 5단계 : websummary — 표 생성 + 발행

`websummary.sh` 가 완결(FADC==PRD) 런 게이트부터 구글사이트 발행까지 전부
오케스트레이션한다. **cron 이 이것을 갖는다**(★ 아직 미설치 — 배포 대기,
CLAUDE.md §11.142 참조) — `monitor-all.sh` 는 legacy 3단계(1·과도기·4)만
도는 수동/구식 자동화로 남는다(§9 참조).

## 순서

```
게이트(완결 런, start_run 부터 연속으로 완결된 접두만)
  -> run-summary.sh -> dst-build.sh -> metrics.sh(빌드) -> metrics.sh --verify
     (legacy 인 동안은 불일치해도 경고만 — 전환 전이라 게이트로 막지 않는다)
  -> ibd-summary.sh -> rate-trend.sh
  -> gen-runclass.sh (type 열 분류, 컨트롤러 판정 R9 — 실패해도 WARN 뿐,
     type='-' 로 계속) -> gen-summary-html.sh
  -> rate_trend_*.png 11개 + summary.html 을 webroot 로 rsync 복사
  -> publish_google.py (publish=1 일 때만)
```

## 완결 게이트

`sheetlog-auto.sh` 의 `run_complete` 와 같은 판정 — `WEBSUMMARY_ROOTS`(기본
`/Data_ssd/RAW /data/RAW /scratch/RAW`) 를 훑어 **FADC 서브런 개수 == PRD
개수 (> 0)** 인 런만 완결로 본다. `start_run`(기본 4280) 부터 **연속으로**
완결된 접두만 처리한다 — 중간에 미완결 런이 하나 있으면 그 런에서 멈추고,
그 뒤에 이미 완결된 런이 있어도 건너뛰지 않는다(순서를 지킨다).

**실측 (2026-09-08, run 4281 재처리 직후)** — `start_run=4280` 기준 32개 런
(4280 부터 4323 까지 — 그 사이 4295~4299·4308~4312 처럼 boot-fail 로 RAW
디렉터리 자체가 없는 자리는 `discover_runs()` 가 애초에 안 만나므로 그냥
지나간다)이 연속 완결로 잡히고, 다음은 run 4324 에서 막힌다(그 시점에
FADC=0 — 아직 시작 전인 자리, 뒤쪽 4325·4326 은 이미 완결이지만 연속
규칙이라 건너뛰지 않고 4324 에서 정지).

## 사용

```bash
tools/monitor/websummary.sh                 # 한 바퀴 (cron 이 부르는 것과 동일)
tools/monitor/websummary.sh --dry-run        # 무엇을 할지 목록만. 아무것도 안 바꾼다
tools/monitor/websummary.sh --status         # 읽기 전용 현황 (잠금을 잡지 않는다)
tools/monitor/websummary.sh --force          # last_run 무시하고 start_run 부터 다시 훑는다
                                              # (이미 처리된 런은 각 단계가 알아서 건너뛴다)
```

cron (매시 27분 — sheetlog 07분과 겹치지 않게):

```
27 * * * * <저장소>/tools/monitor/websummary.sh >/dev/null 2>&1
```

## 상태·잠금·로그

| 자리 | 기본값 | 뜻 |
|---|---|---|
| 상태 | `/Data_ssd/LOG/websummary.state` | `last_run=N` 한 줄. 모든 단계(발행 포함)가 성공한 뒤에만 전진 |
| 잠금 | `/tmp/websummary.lock` | `flock -n` — 겹쳐 돌면 조용히 물러난다 |
| 로그 | `/Data_ssd/LOG/websummary.log` | 회차마다 `[RUN]/[OK]/[FAIL]` |

`publish=0` 이면 로컬 생성(webroot 복사)까지만 마치고도 상태를 전진시킨다.
`publish=1` 인데 발행이 실패하면 상태는 그대로 남아 다음 회차가 **같은
런부터** 다시 시도한다 — 부분 발행을 완료로 치지 않는다.

## 환경변수 — WEBSUMMARY_\* 6종, 그중 3종은 시험 전용(운영 금지)

| 변수 | 기본값 | 성격 |
|---|---|---|
| `WEBSUMMARY_ROOTS` | `/Data_ssd/RAW /data/RAW /scratch/RAW` | ★시험 전용 — 게이트가 훑을 RAW 루트. 시험이 가짜 트리로 갈아끼우는 자리 |
| `WEBSUMMARY_MON_DIR` | 이 스크립트 자신의 디렉터리 | ★시험 전용 — 다섯 단계 스크립트를 부를 디렉터리. 기본과 다르면 회차마다 `[TEST]` 로 크게 알린다. **운영에서 절대 쓰지 말 것** |
| `WEBSUMMARY_STAGES_DISABLED` | `0` | ★시험 전용 — `1` 이면 단계 호출을 전부 건너뛰고 게이트/상태/잠금/마운트/dry-run 로직만 시험한다. **운영에서 절대 쓰지 말 것** |
| `WEBSUMMARY_LOCK` | `/tmp/websummary.lock` | 잠금 파일 경로. 운영과 시험이 같은 잠금을 잡으면 시험이 조용히 exit 0 으로 끝나므로(`dataflow.sh` `DATAFLOW_LOCK` 과 같은 교훈, CLAUDE.md §11.150) 시험은 반드시 갈아끼운다 |
| `WEBSUMMARY_STATE` | `/Data_ssd/LOG/websummary.state` | 상태 파일 경로 재배치 |
| `WEBSUMMARY_LOG` | `/Data_ssd/LOG/websummary.log` | 로그 파일 경로 재배치 |

## `gen-runclass.sh` — type(physics/calibration/test) 분류

```
gen-runclass.sh <TSV디렉터리> <출력 runclass.tsv>
```

런마다 `physics`/`calibration`/`test`/`-` 를 매기는 **유일한 생산자**다
(컨트롤러 판정 R9). `gen-summary-html.sh`·`publish_google.py` 는 이 파일을
run 을 키로만 읽는다 — 분류 규칙을 각자 다시 판단하지 않는다.

**분류 규칙 (우선순위 : calibration > test > physics > `-`)**

| type | 조건 |
|---|---|
| `calibration` | 그 런의 src(`metrics_summary.tsv` 가 있으면 그것, 없으면 `pair_summary.tsv`, 3열)가 `none`/`?`/`-`/빈값이 아니다 — 즉 AmBe 등 진짜 선원 이름이다. 태그(`_nGd`/`_nH`) 행이 둘이면 어느 한쪽이라도 진짜 선원이면 calibration 이다 |
| `test` | 위에 안 걸리고, `runcatalog.db` 가 그 런을 `onlbit=0` 이라 한다 |
| `physics` | 위 둘 다 안 걸리고, `onlbit=1` 로 안다 |
| `-` | src 도 DB 도 그 런을 모른다 |

선원을 넣고 받다가 aborted 된 런(onlbit=0 인데 src 가 AmBe 등)도 표를 읽을
때는 여전히 `calibration` 이다 — calibration 이 test 를 이긴다.

**DB 의존은 조용히 강등된다.** `runcatalog.db`(기본 `/Data_ssd/runcatalog.db`,
`RUNCLASS_DB` 로 재배치, `sqlite3` CLI 는 이 프로젝트의 기존 런타임
의존이다 — §0.0)가 없거나 못 읽거나 `sqlite3` 자체가 없으면, **경고 한 줄
없이** src 만으로 분류하고 `exit 0` 이다. 이 스크립트가 죽어서(또는
시끄러워져서) 웹 발행 전체를 막으면 안 된다는 chainwatch 원칙(CLAUDE.md
§11.138)을 그대로 따른다 — `websummary.sh` 도 이 단계의 실패를 **WARN
으로만** 다루고 다음 단계로 넘어간다(그러면 `gen-summary-html.sh` 가
`runclass.tsv` 를 못 찾아 type 열이 전부 `-` 로 뜬다).

**대상 런은 `run_summary.tsv` 에 있는 런 전부다** — `pair_summary.tsv`나
`metrics_summary.tsv`에만 있는 런은 안 싣는다(그 반대 방향으로 표에 없는
런을 만들지 않기 위해서다).

출력은 `run<TAB>type` 줄 + `#` 헤더 두 줄. 실측(2026-09-08, `/scratch/RunSummary`
35개 런) : physics 28 · test 4 · `-` 3 · calibration 0(이 구간엔 선원 런이
없었다) — `test` 4개·`-` 3개 전부 `runcatalog.db` 의 `onlbit=0`/`NULL` 과
정확히 일치함을 직접 대조로 확인했다.

## `gen-summary-html.sh` — 16열 표

```
gen-summary-html.sh <TSV디렉터리> <출력.html> <legacy|dst> <refresh_s>
```

`run_summary.tsv` + (legacy 면 `pair_summary.tsv`, dst 면 `metrics_summary.tsv`)
+ `runclass.tsv`(있으면)를 조인해 런당 1줄, 16열(Run/**Type**/시작/live·wall/
전체/Target only/VETO only/V+T/IBD nGd/acci nGd/IBD nH/acci nH/R_LL/fast-n/
Li/He/선원) 표를 만든다. 순수 소비자다 — 어느 런을 실을지는 앞 단계가 TSV 를
쓸 때 이미 걸러 두었으므로 여기서 다시 거르지 않는다. `metrics_source=dst`
일 때만 fast-n·Li/He 값을 채우고(그것도 `lihe_stat=="ok"`/
`n_fn_side_scaled>=0` 일 때만), 값 옆에 '(예비)' 를 붙인다. legacy 모드거나
값이 없으면 '—'. **Type 열**은 `runclass.tsv` 가 없거나 그 안에 이 런이
없으면 `-` — 열이 밀리는 일은 절대 없다(다른 열과 같은 fallback 관례).

## `publish_google.py` — 시트 + 드라이브

```bash
tools/monitor/publish_google.py --params config/websummary.params --init       # 1회성 초기화
tools/monitor/publish_google.py --params config/websummary.params --dry-run    # 무엇이 나갈지만
tools/monitor/publish_google.py --params config/websummary.params              # 실발행
```

**시트** — 새 런 행만 append(기존 행 불변). 쓰기 전 `/Data_ssd/LOG/websummary/
sheet-backup-<시각>.tsv` 로 백업하고, 쓴 뒤 다시 읽어 **되대조**한다 — 다르면
`[FATAL]`. append-only 라 시트의 현재 최댓값보다 낮은 런을 나중에 되메워도
삽입하지 않고 그대로 끝에 붙이며 `[WARN]` 만 낸다(컨트롤러 판정 R7 — 단일
기록자 보장은 `websummary.sh` 의 `flock` 몫이지 이 스크립트가 아니다).

**드라이브** — `map_file`(이름→fileId)에 있는 PNG 를 같은 파일 ID 에
**내용만** 교체(PATCH). 개별 실패는 나머지 계속 진행 후 모아서 exit 1 —
오케스트레이터가 다음 주기에 다시 시도한다.

**`--init`** — `webroot` 의 PNG 를 각각 새 드라이브 파일로 올리고
`map_file`(이름`\t`fileId)을 쓴다. 퍼가기(임베드) URL 을
`https://drive.google.com/thumbnail?id=<fileId>&sz=w1600` 형태로 함께 찍는다.

**dry-run 약속(컨트롤러 판정 R6)** — `--dry-run` 은 **`--init` 과 결합돼도**
자격증명을 찾지도, 네트워크를 건드리지도 않는다. `--init` 과 함께면 로컬
`webroot/*.png` 목록(이름+크기)과 갈 폴더만 찍고, 단독이면 시트에 붙을
후보 행 몇 개와 드라이브에서 교체될 PNG 개수만 찍는다.

**자격증명** — `RENE_SHEETS_SA` 환경변수 → `<저장소>/.config/rene/*.json` →
`~/.config/rene/*.json` 순서로 찾는다(GoodRuns 시트를 쓰는 `append_runs.py`
와 같은 관례). 서비스 계정 json 은 gitignore 대상이라 저장소에 없다.

---

## 9. 자동화 (legacy) — `monitor-all.sh`

**cron 은 이제 5단계(`websummary.sh`, 매시 27분)가 갖는다**(★ 아직
미설치 — 배포 대기, CLAUDE.md §11.142 참조).
아래 `monitor-all.sh` 는 legacy 3단계(1·과도기·4)만 순서대로 돌리는
수동/구식 자동화로 남아 있다 — DST·metrics·발행 없이 `pair_summary.tsv` 와
그림만 다시 만들고 싶을 때, 또는 `websummary.sh` 없이 그림만 점검할 때
쓴다.

```bash
# tmux 새 창으로 (기존 화면 배치는 건드리지 않는다)
tmux new-window -t daq -n monitor 'tools/monitor/monitor-all.sh --follow'

# cron 이면 ROOT 환경을 먼저 잡아야 한다 (legacy 경로 — 운영 cron 은 위 5단계)
0 * * * * . /usr/local/bin/thisroot.sh; \
          /home/frontend/DAQ/RENE-daq-rcterm/tools/monitor/monitor-all.sh --quiet
```

한 바퀴가 끝날 때마다 채널별 **가장 최근 점**을 한 줄로 찍는다. 그것만 봐도
수집이 정상인지 감이 온다.

**페어링을 여기서 한다.** 다른 계정의 산출물을 기다리지 않으므로 production
이 끝난 런은 곧바로 표에 들어온다. 아직 안 센 런은 `ibd-summary.sh --missing`
이 알려 준다.

2단계(과도기 페어링)가 1단계보다 비싸므로 `--newest` 는 **두 단계 모두에**
적용된다.

---

## 10. 지금 상태와 다음

- **입력을 PRD 로 일원화했다(2026-08-18).** 1·과도기 단계는 다른 계정의 분석
  산출물 없이 돈다. 검증은 §6.0.2 — 재구성은 single 목록이 비트 단위로 같고,
  페어링은 여덟 개 수가 전부 일치한다.
- **5단계 파이프라인으로 확장했다(2026-09-08).** DST(2단계)·metrics(3단계)·
  websummary(5단계, 표 생성 + 발행)가 새로 붙었다. 전환 게이트(`metrics.sh
  --verify`)는 run 4305 에서 공통 2행 불일치 0 으로 통과했고, run 4237 도
  DST 경로 값은 확보했지만 legacy 페어링이 아직 그 런을 안 돌아 공통 행에는
  안 잡힌다(3단계 절 참조) — **`metrics_source=dst` 전환은 사용자 승인
  전까지 보류, 표는 계속 legacy(과도기) 값을 쓴다.**
- 표는 다시 채우는 중이다. 최신 런부터, `/Data_ssd` 에 있는 동안 돌리는 것이
  13배 싸다(§6.0.3).
- 하지 않은 것
  - `runcatalog.db` 의 `nfadc`/`tfadc`(DAQ 가 보고한 값) 대 `n_events`/`live`
    (데이터에서 나온 값) 대조. 나란히 놓으면 수집과 저장 사이의 손실이 보인다.
  - ε_E(에너지창 효율). 봉우리 fit 이 필요해 자동으로 못 구한다. 기본 1.0 이고
    보정에서 빠져 있다.
  - 병합 런은 다루지 않는다. 단일 런만 센다.
  - 페어링 loop 은 분석 쪽에 세기 전용 진입점이 없어 따로 두었다. 저쪽이
    `RunBothChannels.C` 를 고치면 여기도 고쳐야 한다 — 대조가 알려 준다.
  - run 4237 의 legacy 페어링(51시간짜리 `ibd-summary.sh` 전체 재계산)은
    아직 안 돌았다 — 급하지 않다. DST 경로 값은 이미 있다(3단계 절).
  - Li/He·fast-n 은 이 사이트 조건(뮤온 간격 vs τ, saturation 컷)에서
    레시피 자체의 한계가 실측으로 확인돼 있다 — 분석팀 검증과 레시피 개선이
    남아 있다(3단계 절의 caveat).
