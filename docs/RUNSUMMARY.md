# 런 서머리 모니터링 — 구조 · 코드 · 이어받기 (2026-09-09)

**이 문서는 무엇인가.** 2026-09-08 ~ 09-09 에 새로 지은 **런 서머리 웹 모니터링**
(PRD → DST → 지표 → 추이 → 웹 표·발행)과, 그 위에 세운 **배경 레시피 v2** ·
**PSD 기준** · **VETO 이력 도구**를 *구조* 로 정리한 것이다. 무엇을 왜 만들었고,
어느 파일이 무엇을 하고, 무엇이 검증됐고, 밖에서 접속해 어떻게 이어서 보는가.

상세는 세 곳에 있고 이 문서는 그 **지도**다.

| 무엇을 알고 싶나 | 어디에 |
|---|---|
| 단계별 알고리즘 · 스키마 · 함정 · 실측 비용 | `tools/monitor/README.md` (895 줄) |
| PSD 기준과 선원 런 결과 · VETO 패널/문턱 이력 | `tools/psd/README.md` |
| 왜 이렇게 설계했나 (논문 근거 · 판정 R5~R9) | `docs/superpowers/specs/2026-09-08-run-summary-web-design.md` · `…-background-recipes-v2-design.md` |
| 세션별 경위와 실측 | `CLAUDE.md` §11.154 ~ §11.169 |

---

## 1. 한눈에

```
                PRD (production 산출물)  <- 유일한 입력. 다른 계정의 분석 산출물에 기대지 않는다
                /Data_ssd/RAW : /data/RAW : /scratch/RAW   (앞이 이긴다. 읽기만 한다)
                       │
   1  run-summary.sh ──┼──> run_summary.tsv          livetime · 종류별 이벤트 수
   2  dst-build.sh ────┼──> dst/DST_<런>.root         ★ 2차 프로덕션. 뮤온 · 클린싱글(+psd) · 포화 사건
   3  metrics.sh ──────┘    metrics_summary.tsv      IBD · accidental · fast-n · Li/He · PSD · 다중중성자 (42 열)
   (과도기) ibd-summary.sh  pair_summary.tsv         legacy 페어링 (PRD 재독). 3 의 교차검증 기준 + 4 의 입력
   4  rate-trend.sh         rate_trend_*.png 11 장   효율 보정 rate · 시간축 추이
   4b bg-trend.sh           bg_trend_*.png 6 장      배경 지표 추이
   5  websummary.sh         summary.html + 시트/드라이브    완결 게이트 → 1~4b 순서 실행 → 표 → 발행
                            (gen-runclass.sh · gen-summary-html.sh · publish_google.py)
```

- **DST 를 끼운 이유** — fast-n · Li/He 는 "직전 샤워링 뮤온까지의 시간"이 필요해
  PRD 전체를 훑어야 한다. 레시피(문턱)가 바뀔 때마다 그것을 다시 하면 12,722
  서브런짜리 런 하나에 5 시간이다. 뮤온 시각 + 클린싱글 + 포화 사건만 DST 에
  뽑아 두면 그 뒤로는 런당 수십 초다. **DST 는 Merged 와 같은 재생 가능 캐시**
  (`dst-build.sh --force` 로 언제든 다시 만든다) — 백업·청소 대상이 아니다.
- **legacy 경로를 폐기하지 않은 이유** — DST 경로가 같은 답을 내는지 **실측으로**
  확인하는 게이트(`metrics.sh --verify`)의 기준이고, 아직 4 단계의 유일한 입력이다.
  웹 표는 `metrics_source=legacy` 로 잠겨 있다. `dst` 전환은 사람이 승인한다.
- **물리는 복제하지 않는다** — 컷 상수와 파형→NPE 는 분석 트리의 헤더 두 개를
  include 한다(`RenePrdSingles.h`). 그 경로가 없으면 2·3 단계는 빌드가 안 된다
  (`RENE_ANA_HELPERS` · `RENE_COND`, `CLAUDE.md` §0.0).

---

## 2. 지킨 원칙 — 되돌리기 전에 읽을 것

| 원칙 | 어디에 박혀 있나 |
|---|---|
| **single 의 개수·순서·pe 는 손대지 않는다.** 스키마 2 로 psd 열과 T_Sat 를 더했지만 single 목록은 스키마 1 과 같다 — legacy 패리티 게이트가 그대로 성립한다 | `RenePrdSingles.h` · `BuildMonitorDst.C` |
| **`metrics_summary.tsv` 앞 18 열은 자리를 지킨다.** 웹·시트가 14/16/18 열을 읽는다. 새 열은 19 열부터 붙인다 (`# schema 2`) | `BuildMetrics.C` · `gen-summary-html.sh` |
| **`--dry-run` 은 절대 바깥에 닿지 않는다.** `--init` 과 결합돼도 자격증명을 찾지도, 네트워크를 건드리지도 않는다 (판정 R6) | `publish_google.py` · `websummary.sh` |
| **완결 게이트 — FADC 개수 == PRD 개수 (> 0) 인 런까지만, `start_run` 부터 연속으로.** 미완결 런이 하나 있으면 거기서 멈춘다. 원시 파일이 전부 `badrun/` 으로 격리된 런(FADC 0)은 완결로 본다 | `websummary.sh` `run_complete` |
| **시트는 append-only.** 되메움 런이 와도 끼워 넣지 않고 끝에 붙이며 `[WARN]` (판정 R7). 쓰기 전 백업, 쓴 뒤 되대조, 다르면 `[FATAL]` | `publish_google.py` |
| **MeV→NPE 는 분석 헤더의 `MeVToNpe()` 로.** 선형 환산을 쓰면 같은 12 MeV 가 창 정의와 다른 NPE 가 되어 사이드밴드가 신호창을 침범한다 (판정 R5, 실측으로 겹침 확인) | `BuildMetrics.C` |
| **type 분류는 `gen-runclass.sh` 하나만 한다** (판정 R9). calibration(선원) > test(onlbit=0) > physics > `-` | `gen-runclass.sh` |
| **캐시는 legacy 와 분리한다** (`cache/` ≠ `cache/singles/`). 합치면 뮤온 없는 옛 캐시를 읽어 carry 가 이중 적용된다 | `BuildMonitorDst.C` 머리 주석 |
| **예비 지표는 '(예비)' 를 달고 나간다.** Li/He · fast-n 은 분석팀 검증 전까지 물리로 읽지 않는다 | `gen-summary-html.sh` |
| **결과 수치는 실측만 적는다.** 산술 추정은 그렇게 표시한다 | 이 문서 전체 |

---

## 3. 파일 — 새로 만든 것과 고친 것

### 3.1 `tools/monitor/` — 파이프라인

| 파일 | 줄 | 역할 | 이번에 |
|---|---|---|---|
| `RenePrdSingles.h` | 630 | PRD → clean single (분석 Step1+2 재현). 뮤온 시각 · **psd(꼬리비율)** · **포화 사건(`ReneSat`)** 수집, 서브런 캐시 저장/로드 | 고침 (뮤온 · psd · sat · 캐시 확장) |
| `RenePairing.h` | 151 | single → 후보 수 (분석 Step3+4 재현). 창을 매개변수로 받는 `PairAndCountW` | 고침 |
| `BuildRunSummary.C` | 513 | 1 단계 매크로 | 그대로 |
| `BuildMonitorDst.C` | 208 | **2 단계** — 런당 DST 1 개. 스키마 2 : `T_Singles(+psd)` · `T_Sat` · `T_Muons` · `T_Info(schema, psd_tail_ns)`. 부분 캐시 히트 시 carry 되돌림 | **신설** |
| `BuildMetrics.C` | 667 | **3 단계** — DST 에서 42 열. n-Gd/n-H 두 채널, accidental(off-window + rate-곱), fast-n 사이드밴드(single ∪ T_Sat, 0차·1차 외삽), Li/He(Daya Bay Eq.2 + 시간 역방향 대조), 다중중성자 `n_mult_rej`, PSD `p_psd(E)` | **신설** (v1 → v2 전면 개정) |
| `BuildPairSummary.C` | 587 | legacy 페어링 (과도기) | 그대로 |
| `BuildRateTrend.C` | 445 | 4 단계 — 효율 보정 rate 추이 11 장 (종류별 4 장 추가) | 고침 |
| `BuildBgTrend.C` | 195 | **4b 단계** — 배경 지표 추이 6 장 | **신설** |
| `run-summary.sh` `ibd-summary.sh` `rate-trend.sh` | 210 / 276 / 66 | 1 · 과도기 · 4 단계 껍데기 | 그대로 |
| `dst-build.sh` | 27 | 2 단계 껍데기. `RENE_RAW_ROOTS` · `--force` | **신설** |
| `metrics.sh` | 132 | 3 단계 껍데기. `--list` · `--verify`(legacy 패리티) · `config/monitorcuts.params` 를 읽는다 | **신설** |
| `bg-trend.sh` | 22 | 4b 껍데기. 입력이 없거나 schema 1 이면 `[SKIP]` exit 0 | **신설** |
| `gen-runclass.sh` | 100 | type(physics/calibration/test/-) 분류 → `runclass.tsv` | **신설** |
| `gen-summary-html.sh` | 213 | 런당 1 줄 16 열 HTML. fast-n · Li/He 는 n-Gd 행에서만 | **신설** |
| `publish_google.py` | 239 | 시트(append-only) + 드라이브(PNG 를 같은 파일 ID 로 교체). `--init` · `--dry-run` | **신설** |
| `websummary.sh` | 351 | **5 단계 오케스트레이터.** 완결 게이트 · `flock` · 상태 파일 · cron 안전장치 · `--dry-run/--status/--force` | **신설** |
| `monitor-all.sh` | 110 | legacy 자동화 (1 → 과도기 → 4). 운영 cron 은 5 단계가 갖는다 | 그대로 |
| `README.md` | 895 | 단계별 상세 | 고침 (2·3·4b·5 단계 절 추가) |

### 3.2 `tools/psd/` — PSD 기준 · VETO 이력 (전부 신설)

| 파일 | 줄 | 역할 |
|---|---|---|
| `PsdScan.C` | 160 | PRD 파형에서 사건마다 q · 피크 · CFD · rise · fwhm · pkfrac · tail20/30/40/50 · mt · asym + n-H/n-Gd 태그 |
| `PsdAnalyze.C` | 224 | 에너지 밴드별 on−off 분해(corr = f·N + (1−f)·G), FoM, γ 99 % 수용에서의 recoil 기각률. 모드 `nH`/`nGd` |
| `PsdSummary.C` | 86 | 런·위치별 요약 표와 그림 |
| `psd-scan.sh` `psd-source-scan.sh` | 11 / 22 | 런 하나 / 선원 런 전부 (약 20 분, 2 병렬). `--analyze-only` |
| `source-runs.tsv` `source-runs-gd.tsv` | | 선원 런 지도 (2025-11 Gd 없는 LS / **Gd-LS 정본 : AmBe 3956~3961 · 4221~4224, Cf252 3963~3974 · 4230~4234**) |
| `VetoHistoryScan.C` `VetoHistoryPlot.C` `veto-history.sh` | 28 / 28 / 44 | PRD 의 `S_THR`/`F_THR` 와 패널별 반응을 런마다 훑어 `thr_history.tsv` · `veto_history.tsv` · 그림 3 장 |
| `README.md` | 225 | 결과와 근거. §2.5 가 Gd-LS 정본, §6 이 VETO/문턱 이력 |

### 3.3 설정 · 시험 · 문서

| 파일 | 무엇 |
|---|---|
| `config/websummary.params(.example)` | 5 단계 설정. **gitignore.** 지금 값 : `publish=0` · `metrics_source=legacy` · `start_run=4280` · `tsv_dir=/scratch/RunSummary` · `webroot=/scratch/RunSummary/web` · `refresh_s=600`. `sheet_id` · `drive_folder_id` 는 비어 있다 (사람이 `--init` 때 채운다) |
| `config/monitorcuts.params(.example)` | 3 단계 컷 손잡이 : `mu_shower_npe=20000` · `lihe_fit 0.002~10 s` · `lihe_min_cand=50` · `lihe_li_frac=1.0` · `fn_e 12~50 MeV` · `psd_nsig=3.0` |
| `tests/monitor-{bg,bgtrend,dst,html,metrics,muons,pairing,publish,runclass,typetrend}.test.sh` · `tests/websummary.test.sh` | 시험 11 벌. 전부 mktemp 샌드박스 — 실 `/scratch` · `/Data_ssd` · 구글 API 무접촉 (`monitor-metrics` 만 실 DST 를 읽는다, 쓰지는 않는다) |
| `docs/superpowers/specs/2026-09-08-run-summary-web-design.md` · `…/plans/2026-09-08-run-summary-web.md` | 설계와 10 태스크 계획 |
| `docs/superpowers/specs/2026-09-08-background-recipes-v2-design.md` | 논문 근거표 (NEOS-I/II 박사논문 · NEOS PRL · Daya Bay 1402.6876 · RENE PTEP 2025) 와 실측 셋 (PSD FoM 0.53 · 12 MeV 이상 93 % 포화 · 뮤온 간격 0.75 s ≈ τ_Li) |

전부 `origin/main` 에 있다. 관련 커밋 34 개 (`d510726` 2026-09-08 ~ `f87ee12` 2026-09-09).

---

## 4. 산출물 — `/scratch/RunSummary/` (2026-09-09 13:30 실측)

```
run_summary.tsv        58 행     1 단계
dst/DST_<런>.root      41 개 · 14 GB     2 단계 (스키마 2, 4280~4332 완결 런)
cache/                 19 GB            2 단계 서브런 캐시 (재생 가능)
metrics_summary.tsv    83 행 (# schema 2, 42 열)    3 단계 — 40 런 × n-Gd/n-H
pair_summary.tsv       85 행     legacy
rate_trend.tsv + rate_trend_*.png 11 장    4 단계
bg_trend.pdf + bg_trend_*.png 6 장         4b
runclass.tsv 54 행 · summary.html (53 행)  5 단계 로컬 생성물
web/                   532 KB    summary.html(legacy 출처, 26 런) · summary_dst.html(DST 출처, 53 행) · png 17 장
psd/                   2.9 GB   psdscan/psdana_*.root · psd_summary(_gd).tsv · thr_history.tsv · veto_history.tsv · 그림
old-schema1/           스키마 1 DST 보관 (지워도 된다)
```

상태 파일 `/Data_ssd/LOG/websummary.state` (`last_run=4332`), 로그
`/Data_ssd/LOG/websummary.log`, 잠금 `/tmp/websummary.lock`.

---

## 5. 검증 상태

| 무엇 | 결과 | 어디에 |
|---|---|---|
| 전환 게이트 `metrics.sh --verify` (run 4305) | 공통 2 행 (n-Gd/n-H) **불일치 0** — DST 경로와 legacy 가 `n_ibd`·`n_ibd_acci` 에서 같다. 스키마 2 로 재생성한 뒤에도 같다 | §11.155 · §11.164 |
| 합성 DST (Li/He 500 심음) | 507.5 ± 26.2 회수, 역방향 0.0 ± 3.9 | `tests/monitor-bg.test.sh` |
| run 4305 v2 실측 | n-Gd : IBD 82 / acci 17 · Li/He 0.0 ± 2.9 (역방향 0) · fast-n 사이드밴드 27 쌍 → 7.7/일 (전부 포화, 평평 외삽) · mult_rej 557 · PSD γ-band 0.399 ± 0.059 | §11.164 |
| PSD 기준 (Gd-LS AmBe, 2.2 MeV 포획 γ 참조) | FoM 1.29 (1.2–2 MeV). γ 99 % 수용에서 recoil 기각 62 / 44 / 23 / 4 % (0.6–1.2 / 1.2–2 / 2–3 / 3–4.5 MeV). Cf252 는 참조 불가 | `tools/psd/README.md` §2.5 |
| 문턱 이력 | SADC THR 은 run 4237(06-14) ~ 4333 불변. 08-26 의 보드 직접 설정은 런 시작 때 설정 파일에 덮어써졌다 | `tools/psd/README.md` §6 |
| 시험 11 벌 | 아래 표 (2026-09-09 재실행) | |

| 시험 | 2026-09-09 13:35 재실행 | 무엇을 보나 |
|---|---|---|
| `monitor-html` | PASS 8/8 | 16 열 표, '(예비)' 표기, legacy/dst 갈림 |
| `monitor-publish` | PASS 9/9 | 시트 append-only · 되대조 · dry-run 이 네트워크에 안 닿음 |
| `monitor-runclass` | PASS 6/6 | type 분류 6 규칙 |
| `websummary` | PASS 10/10 | 게이트 · 잠금 · publish=1 가짜 스테이지 · cron 환경 · 격리 런 |
| `monitor-bgtrend` | PASS 4/4 | 6 쪽 PNG, schema 1 이면 SKIP |
| `monitor-bg` | PASS 12/12 | 합성 DST 로 Li/He 적합·역방향, 포화 사이드밴드, rate-곱, n-like, verify 판별 |
| `monitor-dst` | PASS 8/8 | 스키마 2 · 캐시 · 부분 히트 carry 되돌림 |
| `monitor-muons` | PASS 6/6 | 뮤온 수집이 single 을 안 바꾼다 |
| `monitor-pairing` | PASS 4/4 | 창 매개변수화 페어링 |
| `monitor-typetrend` | PASS | 기존 7 + 신규 4 PNG, PDF 11 쪽, 퇴화 경로 |
| `monitor-metrics` | PASS (run 4332, 25 s) | DST 경로 대 legacy `n_ibd`/`n_ibd_acci` 일치 |

재실행 로그 `/Data_ssd/LOG/monitor-tests-20260909.log`. 전부 mktemp 샌드박스 —
실 데이터는 읽기만 하고 구글 API 는 닿지 않는다.

---

## 6. 밖에서 접속해 이어서 보는 법

DAQ PC : `203.230.111.71` (ssh 포트 **50022**), 계정 `frontend`. 저장소 서버는 그 안에서 `ssh store`.

**지금 무엇이 도는가 — 전부 읽기 전용**

```bash
cat /Data/LOG/rcterm.hb                       # 수집 (phase= · run= · state=)
scripts/chainwatch.sh --status                # 후처리 사슬 · 계수율
tools/monitor/websummary.sh --status          # 게이트 · last_run · 새 완결 런
tail -20 /Data_ssd/LOG/websummary.log         # 마지막 회차가 어디까지 갔나
ls -la /scratch/RunSummary/web/               # 표·그림의 갱신 시각
```

**표를 보는 법.** 이 PC 에는 HTTP 서버가 없다. 발행(`publish=1`)을 켜기 전까지는 파일로 본다.

```bash
# 밖에서
scp -P 50022 frontend@203.230.111.71:/scratch/RunSummary/web/summary.html .      # 브라우저로 연다
scp -P 50022 'frontend@203.230.111.71:/scratch/RunSummary/web/*.png' .
# 또는 안에서 텍스트로
column -t -s $'\t' /scratch/RunSummary/metrics_summary.tsv | less -S
```

**한 바퀴 손으로 돌리기** (cron 이 아직 없으므로 지금은 이것이 유일한 갱신 수단이다)

```bash
tools/monitor/websummary.sh --dry-run     # 무엇을 할지만 (아무것도 안 바꾼다)
tools/monitor/websummary.sh               # 완결 런까지 1→2→3→과도기→4→4b→표. publish=0 이라 로컬까지
```

24 h 런 하나가 새로 완결되면 2 단계 약 35 분 + 과도기 페어링 몇 시간이 든다
(둘 다 `/scratch` 에서, 후처리와 동시에 돌아도 수집을 건드리지 않는다).
`nohup … &` 로 띄우고 로그를 보면 된다. 겹쳐 띄워도 `flock` 이 막는다.

**게이트가 안 자라면** — `--status` 의 "새 완결 런" 이 0 인데 런은 끝났다면 후처리가
덜 끝난 것이다. `scripts/runcheck.sh --run <런>` 으로 FADC/PRD 개수를 대조한다.
연속 규칙이라 **앞에 미완결 런이 하나 있으면 뒤가 전부 막힌다** — 그 런을 재처리하거나
(`scripts/postrun.sh <런> --from 0`) 원시 파일이 못 쓰는 것이면 격리한다
(`scripts/badrun.sh --scan --run <런> --quarantine`). 격리하면 게이트가 통과한다.

**지금 상태 (2026-09-09 13:30)** — 수집은 05:22 부터 정지 (FADC 보드 USB 이탈,
크레이트 전원 재투입 대기, `CLAUDE.md` §11.169). 모니터링은 완결 런까지만 처리하므로
이 상태에서 돌려도 안전하다. `last_run=4332`, 새 완결 런 4333 · 4334 · 4335 —
4335 는 서브런 하나짜리 빈 런(onlbit=0)이라 표에는 `test` 로 들어간다.

---

## 7. 열려 있는 것

| 무엇 | 누가 | 근거 |
|---|---|---|
| 구글 시트/드라이브 `--init` 과 cron 매시 27 분 `websummary.sh` 등록 | 사람 (자격증명·공유) | §11.157 · README 5 단계 |
| `metrics_source=dst` 승인 | 사람 — `--verify` 가 여러 런에서 반복 통과한 뒤 | §11.155 |
| 배경 레시피 v2 의 분석팀 검증 (웹의 '(예비)' 를 떼려면) | 분석팀 | v2 스펙 · §11.161 |
| DST 재생성 때 psd 꼬리 시작을 40 → 60 ns (`kRenePsdTailSamples` 20 → 30) | 다음 일괄 재생성 때 | `tools/psd/README.md` §2.5 |
| run 4237 의 legacy 페어링 (51 시간) — DST 값은 있고 교차 행만 없다 | 급하지 않다 | §11.155 |
| fast-n 지표가 08-26 뒤 4 배인 원인 | 미상. 패널 1 하강으로는 설명되지 않는다 | §11.166 · §11.167 |
| VETO 패널 9 · 10 무반응 (문턱과 무관) — 케이블·PMT 확인 | 현장 | `tools/psd/README.md` §6 |
| SADC 문턱 MIP/2 의 첫 적용 확인 (`/Data_ssd/LOG/veto-check-4335.sh` 가 대기 중) | 수집 재개 뒤 자동 | §11.168 |

---

## 8. 변경 이력 (관련 커밋만)

```
09-08  d510726 5795aaa      설계 스펙 · 구현 계획
       ae94fdb 7ff8e64      뮤온 시각 수집 · 창 매개변수화 페어링
       40e4b68 df87801      2 단계 DST (+ 부분 캐시 carry 되돌림)
       88c548c 408c212 44b18c7 d8a405c   3 단계 지표 + 패리티 게이트, Li/He·fast-n 예비, MeVToNpe 판정
       b29ac3f 11bc0ae      4 단계 종류별 추이 4 장
       712b789 1679d67      표 생성기
       ad44fef e2b15da b748a1b   구글 발행 (dry-run 불변 · 되대조)
       1544fe1 2ee8ca8 86dd223 0634ea6   5 단계 오케스트레이터 · README
       5044526 2a3aa2e      type 열 (R9)
       220a6f1 9ea92d1      배경 레시피 v2 스펙 · 스키마 2 DST
       374f20b fc254c2      격리 런의 게이트 통과
       2bb061e 256ae5d 27f19f5   4b 배경 추이 · run 4305 실측 기록
09-09  005b8bc 1d3fb7c      PSD 기준 (2025-11 선원 런 → Gd-LS 정본 런)
       f82db4a              웹 표의 fast-n · Li/He 를 n-Gd 행에서만
       f87ee12              VETO 패널 · 문턱 이력 도구
```
