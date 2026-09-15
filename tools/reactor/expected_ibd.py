#!/usr/bin/env python3
"""RENE 검출기(현 위치 = RENO 원거리 터널)에 기대되는 원자로 ν̄_e flux 와 IBD 사건 수 (2026-09-15, 사용자 지시).

    tools/reactor/expected_ibd.py            KHNP 열린원전운영정보에서 한빛 1~6 호기 원자로 출력(%)을 읽어 계산
    tools/reactor/expected_ibd.py --offline  현장 값을 못 받으면 전 호기 100 % 로 계산 (--power 0,0,100,100,100,100 으로 직접 줄 수도)

좌표(m, 사용자 제공) : 검출기 vDet[1], 원자로 vRct[0..5] = 한빛 1~6 호기.  호기별 열출력 : 1·2 호기 2,775 MWth (WH 3-loop 950 MWe),
3~6 호기 2,815 MWth (OPR-1000). 타겟 : Gd-LAB 270 L (RENE PTEP 2025, arXiv:2507.22376), 밀도 0.86 g/cm³, H 질량비 0.123 → 양성자 1.71e28.
핵분열 3.05e19 /s/GWth (205 MeV/fission), σ_f = 5.9e-43 cm²/fission (Daya Bay 실측, Huber–Mueller 급), flux 는 6 ν̄/fission 으로 환산.
효율 : 논문의 '24 m 에서 하루 ~300 IBD' 를 같은 식으로 역산한 0.29 (NEOS 관측률로 맞춘 선택 효율 · 부피비). 검출기 창 3~7 MeV 는 별도(그림 60/61).
KHNP : POST https://npp.khnp.co.kr/branch-operation-info-by-plant {branchCd:BR0303, branchCd2:<2311..2336>, branchCd3:<호기>} →
       unitInfoList[0].status (KH1201 운전 / KH1202 정지) · unitDetailOutput.NO_1.VALUE = 원자로 출력 % · NO_8 = 발전기 출력 MW (관찰로 추정)
"""
import argparse, json, math, sys, time, urllib.request

DET = (-1276.152, 1086.739, 28.928)
RCT = [(-580.5237, -313.7868, 31.9872), (-431.818, -105.361, 31.9872), (-283.2894, 102.8167, 28.0087),
       (-134.5838, 311.2425, 28.0087), (14.1219, 519.6683, 28.0087), (162.8276, 728.0941, 28.0087)]
P_GW = [2.775, 2.775, 2.815, 2.815, 2.815, 2.815]
UNIT_CD = ["2311", "2312", "2323", "2324", "2335", "2336"]
NP = 270e3 * 0.86 * 0.123 / 1.00794 * 6.022e23
FIS = 1e9 / (205e6 * 1.602e-19)
SIG = 5.9e-43
NU_PER_FIS = 6.0
EFF_PAPER = 300.0 / (P_GW[2] * FIS * SIG * NP / (4 * math.pi * 2400.0 ** 2) * 86400)

KHNP_URL = "https://npp.khnp.co.kr/branch-operation-info-by-plant"
RATED_GROSS_MWE = [1000.0, 1000.0, 1040.0, 1040.0, 1040.0, 1040.0]   # 발전기 출력 → 열출력 환산용 (3~6 호기 = 100 % 때 실측 1,034~1,041 MW. 1·2 호기는 가정)

def khnp_fetch_raw(timeout=30, fixture=None):
    """호기별 원본 JSON 여섯 개. fixture(파일 경로)를 주면 거기서 읽는다(시험용). 실패하면 예외."""
    if fixture:
        with open(fixture, encoding="utf-8") as f: return json.load(f)
    out = []
    for i, cd in enumerate(UNIT_CD, 1):
        body = json.dumps({"branchCd": "BR0303", "branchCd2": cd, "branchCd3": str(i)}).encode()
        req = urllib.request.Request(KHNP_URL, data=body, method="POST",
                                     headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0",
                                              "X-Requested-With": "XMLHttpRequest",
                                              "Referer": f"https://npp.khnp.co.kr/ON004004002002002?unitCd={cd}"})
        last = None
        for attempt in range(3):                      # DNS·망 순간 실패는 세 번까지 (2026-09-15 첫 실행이 'Name or service not known' 한 번)
            try:
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    out.append(json.loads(r.read().decode("utf-8", "ignore"))); last = None; break
            except Exception as e:
                last = e; time.sleep(10)
        if last is not None: raise last
    return out

def khnp_parse(raw):
    """원본 JSON 여섯 개 → 호기별 dict(unit, status, pct, mwe, time). 값이 없으면 None."""
    units = []
    for i, d in enumerate(raw, 1):
        ui = (d.get("unitInfoList") or [{}])[0]; det = d.get("unitDetailOutput") or {}
        pct = det.get("NO_1", {}).get("VALUE"); mw = det.get("NO_8", {}).get("VALUE"); t = det.get("NO_1", {}).get("TIME")
        st = {"KH1201": "운전", "KH1202": "정지"}.get(ui.get("status"), ui.get("status"))
        try: pct = float(pct)
        except Exception: pct = None
        try: mw = float(mw)
        except Exception: mw = None
        units.append({"unit": i, "status": st, "pct": pct, "mwe": mw, "time": t})
    return units

def khnp_live(timeout=30):
    """호기별 (출력 %, 상태, 발전기 MW, 시각). 실패하면 None."""
    try: raw = khnp_fetch_raw(timeout)
    except Exception as e:
        print(f"[WARN] KHNP : {e}", file=sys.stderr); return None
    return [(u["pct"], u["status"], u["mwe"], u["time"]) for u in khnp_parse(raw)]

def baselines():
    return [math.dist(DET, r) for r in RCT]

def expected(pct, eff=None):
    """호기별 출력 %(6 개) → dict(flux, ibd_noeff, ibd, per_unit=[(flux, ibd_noeff, ibd)]). 창 3~7 MeV 몫은 부르는 쪽이 곱한다."""
    eff = EFF_PAPER if eff is None else eff
    L = baselines(); per = []; tf = tr = 0.0
    for i in range(6):
        p = P_GW[i] * (pct[i] or 0.0) / 100.0
        flux = p * FIS * NU_PER_FIS / (4 * math.pi * (L[i] * 100) ** 2)
        r = p * FIS * SIG * NP / (4 * math.pi * (L[i] * 100) ** 2) * 86400
        per.append((flux, r, r * eff)); tf += flux; tr += r
    return {"flux": tf, "ibd_noeff": tr, "ibd": tr * eff, "per_unit": per, "eff": eff}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--offline", action="store_true"); ap.add_argument("--power", help="호기별 출력 %% 6 개, 쉼표")
    ap.add_argument("--eff", type=float, default=EFF_PAPER)
    a = ap.parse_args()
    live = None
    if a.power: pct = [float(x) for x in a.power.split(",")]; src = "--power"
    elif a.offline: pct = [100.0] * 6; src = "offline(100 %)"
    else:
        live = khnp_live()
        if live is None: pct = [100.0] * 6; src = "KHNP 실패 → 100 %"
        else: pct = [p if p is not None else 0.0 for p, *_ in live]; src = "KHNP 실시간"
    L = [math.dist(DET, r) for r in RCT]
    print(f"# 출처 {src} · N_p {NP:.2e} · σ_f {SIG:.1e} cm² · 효율(논문 24 m 300/day 역산) {a.eff:.3f}")
    print("호기  L[m]    열출력[GW]  출력%  상태  발전기MW  시각                  flux[ν/cm²/s]  IBD/day(효율전)  ×효율")
    tot_f = tot_r = 0.0
    for i in range(6):
        p = P_GW[i] * pct[i] / 100.0
        flux = p * FIS * NU_PER_FIS / (4 * math.pi * (L[i] * 100) ** 2)
        r = p * FIS * SIG * NP / (4 * math.pi * (L[i] * 100) ** 2) * 86400
        tot_f += flux; tot_r += r
        st, mw, t = (live[i][1], live[i][2], live[i][3]) if live else ("-", "-", "-")
        print(f"{i+1:>2}   {L[i]:7.1f}   {P_GW[i]:.3f}      {pct[i]:5.1f}  {st:<4} {str(mw):>7}  {str(t):<20} {flux:.3e}     {r:.3f}          {r*a.eff:.3f}")
    print(f"합계                                                                 {tot_f:.3e}     {tot_r:.3f}          {tot_r*a.eff:.3f}")
    print(f"EXPECTED_IBD_PER_DAY {tot_r*a.eff:.3f}")

if __name__ == "__main__":
    main()
