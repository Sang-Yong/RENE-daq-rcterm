# 한빛 원전 호기별 출력 기록 — 운용 매뉴얼 (2026-09-15)

원자로 중성미자 기대량은 **핵분열 열출력**에 비례한다. KHNP 열린원전운영정보(https://npp.khnp.co.kr/ON004004002002002)가
호기마다 실시간으로 내는 '원자로 출력 %' 와 '발전기 출력 MW' 를 **매시 47 분**에 읽어 두 곳에 남긴다.

```
정본   /Data_ssd/LOG/reactor-power/reactor_power.tsv        (탭 구분, 26 열, 시간마다 한 줄 + 날짜마다 일일 평균 한 줄)
사본   구글 시트 'RENE Offline Data GoodRuns' 문서의 KHNP_daily_power 탭 (gid 748730312)
       https://docs.google.com/spreadsheets/d/1-8wPIg-Q-DpgsyBeSiwHezxM6QlcqhZ3qspAFGusqD0/edit?gid=748730312
로그   /Data_ssd/LOG/reactor-power/reactor-power-log.log    상태 : .../reactor-power-log.state
```

## 무엇을 기록하나

| 열 | 뜻 |
|---|---|
| `datetime` `type` | 기록 시각(KST) · `hour`(시간별) / `day`(지난 날짜의 시간별 평균) |
| `uN_status` `uN_reactor_pct` `uN_gen_MW` (N = 1~6) | 호기 상태(운전/정지) · **원자로 출력 %** · 발전기 출력 MW |
| `total_th_MW` | **열출력 합 = Σ 원자로 출력 % × 정격 열출력** (1·2 호기 2,775 MWth, 3~6 호기 2,815 MWth). 중성미자 계산의 정본 |
| `total_th_from_gen_MW` | 발전기 MW ÷ 정격 발전 효율(3~6 호기 1,040 MWe/2,815 MWth, 1·2 호기 1,000/2,775 가정)로 환산한 열출력 — 대조용 |
| `flux_nu_cm2_s` | 검출기 자리의 ν̄ flux (좌표·거리는 `tools/reactor/expected_ibd.py`) |
| `exp_ibd_per_day` | 기대 IBD/day (논문 24 m 300/day 로 역산한 선택 효율 0.29) |
| `exp_ibd_window_per_day` | 그 중 prompt 3~7 MeV 창 (× 0.576) — 날짜별 분석(그림 60~63)과 바로 비교하는 값 |
| `source` | `khnp`(실시간) / `fixture`(시험) / `mean of N hourly rows`(일일 행) |

★ **발전기 출력이 아니라 원자로 출력 % 를 쓴다.** 사이트의 '원자로 출력' 은 정격 열출력 대비 비율이라 그대로 열출력이 된다.
발전기 MW 는 터빈·발전기 효율이 끼어 있어 대조 열로만 둔다 (정상 운전이면 두 열출력이 1 % 안에서 같다).

## 자동으로 도는 방식

```
cron   47 * * * *  scripts/reactor-power-log.sh     매시 47 분
       @reboot     scripts/reactor-power-log.sh     재부팅 뒤 한 번 (망이 뜰 때까지 최대 20 분 기다린다)
```
cron 은 터미널·세션과 무관하게 돌고 재부팅 뒤에도 남는다. 스크립트는 `flock` 으로 겹쳐 돌지 않는다.

**실패하면** — 연속 2 회 실패에 책임자(`config/notify.params` 의 `mail_to`)에게 메일, 같은 사유는 6 시간에 한 번. 다시 성공하면 '복구' 메일 한 통.
메일에 종료 코드와 마지막 출력, 손으로 돌려 볼 명령이 들어 있다.

| rc | 뜻 | 먼저 볼 것 |
|---|---|---|
| 2 | KHNP 를 못 읽었다 (망·사이트 개편) | `curl -sI https://npp.khnp.co.kr/` · `--dry-run` 의 오류 줄 · 사이트가 바뀌었으면 `tools/reactor/expected_ibd.py` 의 `khnp_fetch_raw/khnp_parse` |
| 3 | 로컬 TSV 는 썼으나 구글 시트 실패 | 서비스 계정 json(`.config/rene/*.json`) · 탭 gid 748730312 가 있는가 · API 한도. **빠진 행은 다음 성공 때 스스로 메운다** |
| 4 | 로컬 TSV 도 못 썼다 | `/Data_ssd` 용량·권한 |

## 사람이 손으로 돌리는 법

```bash
cd /home/frontend/DAQ/RENE-daq-rcterm

scripts/reactor-power-log.sh --status        # 마지막 기록 5 줄 · 연속 실패 수 · 마지막 메일 · cron 등록 여부 (읽기 전용)
scripts/reactor-power-log.sh --dry-run       # KHNP 를 읽어 값·열출력·기대 IBD 를 보여 주기만 한다 (아무것도 안 쓴다)
scripts/reactor-power-log.sh                 # 지금 한 번 기록 (cron 이 부르는 것과 같다. 실패하면 메일 규칙도 같다)
scripts/reactor-power-log.sh --no-notify     # 기록하되 메일은 보내지 않는다 (시험할 때)
scripts/reactor-power-log.sh --install-cron  # crontab 에 두 줄을 넣는다 (이미 있으면 그대로). 재설치·새 PC 에서
tail -20 /Data_ssd/LOG/reactor-power/reactor-power-log.log
tail -3  /Data_ssd/LOG/reactor-power/reactor_power.tsv | cut -f1-2,21,24,25

# 파이썬 도구를 직접 (시트 없이 로컬만 · 시험용 값으로 · 지난 날짜 일일 행 강제)
python3 tools/reactor/reactor_power_log.py --commit --no-sheet
python3 tools/reactor/reactor_power_log.py --fixture tests/fixtures/khnp_hanbit_20260915.json --sheet-tsv /tmp/sheet.tsv --log-dir /tmp/rp --commit
python3 tools/reactor/expected_ibd.py        # 지금 출력으로 기대 IBD 표 (호기별 거리·flux·IBD/day)
```

`--dry-run` 이 정상인데 cron 기록이 없으면 `crontab -l | grep reactor` 로 등록을 확인하고, 없으면 `--install-cron`.
cron 이 아예 죽었으면(모든 cron 작업이 같이 멈춘다) `systemctl status crond`.

## 기대 IBD 를 분석에 넣는 법

`config/monitorcuts.params` 의 `daily_expected_ibd_per_day` 가 날짜별 그림 60/61 의 기대선(창 적용 전)이다. 호기 상태가 바뀌면
`tools/reactor/expected_ibd.py` 의 `EXPECTED_IBD_PER_DAY` 로 갱신한다. 시트의 `exp_ibd_per_day` 열이 같은 값이다.
2026-09-15 : 한빛 1 호기(2025-12-09 ~ 2027-03-31) · 2 호기(2026-09-11 ~ 2027-03-25) 계획예방정비로 정지, 3~6 호기 100 % → 0.345 /day.

## 시험

`tests/reactor-power-log.test.sh` (17 건) — fixture JSON · TSV 시트 대역 · 가짜 메일. 망·구글·메일에 닿지 않는다.
KHNP 가 실제로 읽히는지는 `--dry-run` 으로만 본다.
