---
name: veto-threshold-change
description: "RENE DAQ 의 SADC(veto) 또는 FADC 문턱값을 바꾸고 수집을 다시 시작하는 절차. 값 계산(기준 런 × 비율, 채널별 반올림, PMT ID 대응), 새 설정 파일 작성(덮어쓰기 금지), rcterm.params 전환, 감시자 재시작, 새 런 TCB 로그 검증, veto-check·daqerr-watch 걸기, 세 곳 기록을 다룬다. '문턱값 바꿔서 다시 받자', 'X 의 80 % 로', 'run NNNN 설정으로' 에 쓴다. 현재 값 조회·비교만은 run-summary-analysis 에서 한다."
---

# 문턱값 변경 — 새 파일, 재시작, 검증, 기록

`threshold-change-operator` 가 따른다. 2026-09-09 ~ 10-08 의 변경 여섯 번(§11.168 · 11.175 · 11.178 · 11.196 · 11.197 · 11.207)에서 굳어진 절차다.

## 왜 이렇게 하나
- **설정 파일을 덮어쓰지 않는다** — 사용자 지시(2026-10-08). 옛 파일은 그 시절 런의 기록이고, 덮어쓰면 "어느 런이 어떤 값이었나" 가 설정 파일에서 사라진다. 데이터(PRD `S_THR`)가 정본이지만 설정 파일도 남겨야 한다.
- **재시작 뒤 TCB 로그를 글자 단위로 대조한다** — rcterm 이 파일을 `/Data_ssd/CONFIG/<런>.config` 로 복사해 DAQ 가 보드에 쓴다. 다른 경로로 넣은 값은 그때 덮인다(§11.167).
- **낮은 트리거율에서 DAQ 오류 이력** — 이벤트가 너무 적으면 USB 오류가 났다. 48 시간 감시를 붙인다.

## 1. 값 정하기

1. 기준값 표 `docs/VETO-THRESHOLD-REFERENCE.md` (REF = run 4183~4221 원래 값, 채널→PMT ID 는 2025-10 부터 불변 `38 27 9 24 15 30 4 5 2 18 1 3 12 33 7 10 19 8 29 28 11 26 23 25 13 21 17 16 6 20`).
2. 특정 런의 값이 기준이면 PRD 에서 읽는다: `/scratch/RunSummary/psd/thr_by_run.tsv` 또는 `tools/psd/thr-history.sh`. 2026-04-14 · 05-28 에 채널 순서가 재배치됐으므로 옛 런은 채널 순서가 다를 수 있다 — 값을 채널 번호 그대로 옮기지 말고 "그 런의 채널 k 값" 임을 명시한다.
3. 비율을 곱하고 채널별 반올림. 결과 30 개를 표(ch · PMT · 옛 · 새 · 비율)로 사용자에게 보여 준다.
4. 1,000 을 넘는 채널은 MIP 위라 그 패널이 뮤온을 거의 못 세고, 200 안팎은 MIP/2 아래라 잡음을 100 Hz 넘게 센다(§11.195·11.197). 이것을 보고에 한 줄 적되 결정은 사용자 몫이다.

## 2. 설정 파일

```bash
OLD=/home/frontend/ConfigFiles/<지금 rcterm.params 가 가리키는 파일>
NEW=/home/frontend/ConfigFiles/DataTaking_IBD_sykim_2026_<꼬리표>.config      # 예: _thr4067x80
cp -p $OLD $NEW                       # 새 파일. OLD 는 그대로
# NEW 의 머리에 유래 주석(날짜 · 누가 · 왜 · 기준 · 적용 예정 런), SADCT THR 의 옛 줄은 '#' 으로 남기고 새 줄 + 날짜 주석
cp -p config/rcterm.params config/rcterm.params.bak-$(date +%Y%m%d)
sed -i "s|^config *=.*|config     = $NEW|" config/rcterm.params
install/bin/rcterm --params config/rcterm.params --dry-run 2>&1 | grep -E 'config|INSERT|cp -f'   # NEW 가 잡히는지
```
threshold-changes.log 에 한 줄(시각 · 누가 · 적용 런 · 내용 30 값 · 왜 · 파일 · 백업)을 지금 붙인다 — append-only.

## 3. 재시작 (지금 적용할 때)

`daq-incident-playbook` §3 의 1·4·5 단계와 같다 (usbreset 은 필요 없다). 감시자 TERM → 런 정상 마감 확인(exit 0, phase=ended, 고아 0, 포트 0) → 같은 명령으로 재기동 → 45 초 뒤 검증.
다음 로테이션에 적용할 때는 재시작 없이 2 까지만 하고 적용 예정 시각을 적는다 — rcterm 이 런 시작 때 파일을 읽는다.

## 4. 검증 (새 런)

```bash
R=<새 런>; L=/Data_ssd/LOG/TCB_00$R.log
sed -n '/SADCT/,/DLY/p' $L | grep -A3 'THR'              # 30 값이 새 값과 글자 단위로 같은가 (8 개씩 네 줄)
grep -c 'is aligned' $L; cat /Data_ssd/LOG/{TCB,FADCDAQ,SADCDAQ}_00$R.log | grep -c LIBUSB
grep -E '^ *THR' /Data_ssd/CONFIG/00$R.config | tail -1
sqlite3 /Data_ssd/runcatalog.db "select runnum,config from runcatalog where runnum=$R"
grep -E 'ar=' /Data/LOG/rcterm.hb                        # 직전 런 평균(nfadc/tfadc)과 비교
```
합격이 아니면 재시작하지 말고 보고한다.

## 5. 감시 걸기

```bash
sed -e "s/<옛 런>/$R/g" /Data_ssd/LOG/veto-check-<옛 런>.sh > /Data_ssd/LOG/veto-check-$R.sh      # PRD 12 개 뒤 패널 반응
sed -e "s/<옛 런>/$R/g; s|<옛 설정 파일>|$NEW|" /Data_ssd/LOG/daqerr-watch-<옛 런>.sh > /Data_ssd/LOG/daqerr-watch-$R.sh   # 48 h USB/DRAM 오류
setsid nohup bash /Data_ssd/LOG/veto-check-$R.sh >/dev/null 2>&1 < /dev/null &
setsid nohup bash /Data_ssd/LOG/daqerr-watch-$R.sh >/dev/null 2>&1 < /dev/null &
```
sed 로 만든 스크립트는 `grep -c $R` 와 `bash -n` 으로 치환이 다 됐는지 본다 — 안 바뀐 런 번호가 남아 다른 런을 기다린 적이 있다(§11.208 의 s600 스크립트).

## 6. 기록 (ops-scribe 에 넘길 것)

세 곳: ① 설정 파일 주석(이미 함) ② `/Data_ssd/LOG/threshold-changes.log` (사본 `docs/threshold-changes.log`, `git add -f`) ③ `docs/THRESHOLD-HISTORY.md` 는 PRD 가 생긴 뒤 `tools/psd/thr-history.sh` 로 재생. 시트 Description 접두어 `비토 문턱값 변경(증가|감소)` 은 `append_runs.py` 가 PRD 로 자동. CLAUDE.md §11.x 와 메모리 `veto-threshold-reference` 갱신. 메일은 정상 교체이므로 책임자만.

## 7. 비교표

서브런 10·100 이 생기면 `PSD_OUT=/scratch/RunSummary/psd/check<R> tools/psd/veto-history.sh R R` → `monitor-analyst` 가 직전 런과 패널별 절대 Hz 표(% × 합계)를 만든다. 600 서브런 뒤 한 번 더.
