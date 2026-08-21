# -*- coding: utf-8 -*-
"""운용자용 발표자료 (한글) — 매일 보는 화면, 해야 할 일, 문제가 생겼을 때."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from deck import *
from pptx.enum.text import PP_ALIGN

d = Deck()

# ============================================================ 표지
d.title("RENE / CUPDAQ",
        "DAQ 운용 안내",
        "화면을 어떻게 읽고, 무엇을 하고, 문제가 생기면 어떻게 하는가.\n"
        "명령을 외울 필요는 없다 — 이 자료를 열어 두고 따라 하면 된다.",
        ["영광 사이트  ·  tmux 세션 'daq'  ·  2026년 8월",
         "자세한 것은 저장소의 docs/MANUAL.md · docs/ALARM.md"])

# ============================================================ 한눈에
s = d.head("한눈에", "평소에는 볼 것이 셋뿐이다")
for i, (t, what, how, kind) in enumerate([
        ("① 수집이 도는가", "상태 화면의 heartbeat 나이", "몇 초 안쪽이면 정상", "ok"),
        ("② 계수율이 정상인가", "FADC · SADC 의 Average", "둘 다 약 1,000 Hz", "ok"),
        ("③ 알람이 떠 있는가", "화면 맨 위의 붉은 띠", "없으면 정상", "ok")]):
    y = 2.15 + i * 1.18
    d.box(s, M, y, CW, 1.02, fill=PANEL)
    d.box(s, M, y, 0.05, 1.02, fill=ACCENT)
    d.text(s, M + 0.28, y + 0.20, 3.3, 0.34, [[(t, {"size": 18, "bold": True, "color": INK})]])
    d.text(s, M + 3.75, y + 0.24, 4.2, 0.3, [[(what, {"size": 15, "color": INK2})]])
    d.text(s, M + 8.1, y + 0.24, CW - 8.4, 0.3,
           [[(how, {"font": MONO, "size": 14, "color": OK})]])
d.note(s, M, 5.80, CW, 1.05, "이 셋이 멀쩡하면 손댈 것이 없다",
       "후처리 · 백업 · 이동 · 모니터링은 알아서 돈다. 막히면 알람이 울리거나 메일이 온다.",
       "info")

# ============================================================ 화면
s = d.head("화면", "붙는 법과 배치")
d.code(s, M, 2.10, 5.6, 0.95, [
    "tmux attach -t daq",
    ("Ctrl-B 뒤 D    떨어지기 (DAQ 는 계속 돈다)", MUTED),
    ("Ctrl-B 뒤 =    배치가 어긋났을 때 복원", MUTED),
], size=13)
# tmux 배치 그림
gx, gy, gw, gh = 7.9, 2.10, CW - (7.9 - M), 3.55
lw = gw * 0.46
d.node(s, gx, gy, lw, gh * 0.62, "상태 화면", "rcmon.sh", "ok", tsize=13, ssize=10)
d.node(s, gx, gy + gh * 0.64, lw, gh * 0.17, "감시자", "", "info", tsize=12)
d.node(s, gx, gy + gh * 0.83, lw, gh * 0.17, "후처리", "", "info", tsize=12)
d.node(s, gx + lw + 0.12, gy, gw - lw - 0.12, gh * 0.66, "작업용 셸", "여기서 명령을 친다", "info", tsize=13, ssize=10)
d.node(s, gx + lw + 0.12, gy + gh * 0.68, gw - lw - 0.12, gh * 0.32,
       "데이터 이동", "백업 · 보관", "info", tsize=12, ssize=10)
d.text(s, gx, gy + gh + 0.10, gw, 0.3,
       [[("창 1 — 수집", {"font": MONO, "size": 11.5, "color": MUTED})]], align=PP_ALIGN.CENTER)
d.bullets(s, M, 3.30, 6.6, [
    "창 2 에는 모니터링 따라잡기가 돈다 (Ctrl-B 뒤 2)",
    "pane 제목의 낱말로 배치를 복원하므로 제목을 바꿀 때 그 낱말은 남길 것",
    "pane 마다 글꼴 크기를 다르게 할 수는 없다 — 크게 보려면 창을 따로 띄운다",
], size=14, gap=8)
d.note(s, M, 5.95, CW, 0.88, "세션이 이미 있으면 다시 짜지 않는다",
       "살아 있는 런을 실수로 흔들지 않기 위해서다. daq-tmux.sh 는 그냥 붙기만 한다.", "info")

# ============================================================ 상태 화면 읽기
s = d.head("화면", "상태 화면 읽는 법")
d.code(s, M, 2.05, CW, 3.05, [
    "======================================================================",
    "  RENE / CUPDAQ   Run Monitor   (heartbeat viewer, read-only)",
    "======================================================================",
    "        Current Time : 2026-08-20 07:01:23",
    ("          Run Number : 4302 / 67          ← 런 번호 / 지금 쓰는 서브런", ACC2),
    ("           DAQ State : Running            ← Running 이면 정상", OK),
    "            DAQ Time : 00:47:12",
    "        Total Events : 5,215,616",
    "  --------------------------------------------------------------",
    "        DAQ        Events      Rate[Hz]    Average[Hz]",
    ("      FADCDAQ   2731160       981.5        997.1     ← 약 1000 이면 정상", OK),
    ("      SADCDAQ   2730112      1004.6        997.1", OK),
    "  --------------------------------------------------------------",
    ("  heartbeat 1 초 전                        ← 이 값이 커지면 이상", WARN),
], size=11.5)
d.bullets(s, M, 5.72, CW, [
    ("heartbeat 나이가 핵심이다. ", "이것이 몇 분씩 벌어지면 수집이 멎은 것이다. 감시자가 알아서 개입하지만 화면에서 먼저 보인다."),
    ("Rate 는 순간값, Average 는 런 전체 평균. ", "순간값은 900~1100 사이를 오간다 — 정상이다."),
    ("이 화면은 읽기만 한다. ", "Ctrl-C 로 꺼도 DAQ 는 계속 돈다."),
], size=14)

# ============================================================ 기동/정지
s = d.head("조작", "세우고 다시 띄우기")
d.text(s, M, 2.08, CW, 0.3,
       [[("정상 기동", {"font": MONO, "size": 12, "bold": True, "color": ACCENT})]])
d.code(s, M, 2.42, CW, 0.92, [
    "cd ~/DAQ/RENE-daq-rcterm",
    "scripts/daq-tmux.sh --start",
    ("  → 화면을 짜고 감시자를 띄운다. 인자 없이 실행하면 화면만 만든다(하드웨어 무접촉)", MUTED),
], size=12.5)
d.text(s, M, 3.55, CW, 0.3,
       [[("정상 정지 — 현재 런을 제대로 마감시킨다", {"font": MONO, "size": 12, "bold": True, "color": ACCENT})]])
d.code(s, M, 3.89, CW, 0.92, [
    "pkill -TERM -x rcsupervisor",
    ("  → 감시자가 현재 런을 정상 종료시키고, 카탈로그에 기록한 뒤 물러난다", MUTED),
    ("  → 끝났는지 확인 :  pgrep -x rcsupervisor   (아무것도 안 나오면 끝)", MUTED),
], size=12.5)
d.note(s, M, 5.05, CW, 1.0, "기동 로그에서 이 줄을 확인할 것",
       "[SUP] notify=.../daq-notify.sh  recover=.../usb-recover.sh  (params set)  —  "
       "(off) 로 나오면 알람과 자동 복구가 꺼진 채로 뜬 것이다.", "warn")
d.note(s, M, 6.20, CW, 0.85, "런 교체 사이의 공백 10~40초는 없앨 수 없다",
       "프로토콜에 '실행 중 런 번호 변경' 이 없다. 공백이 싫으면 런을 나누지 말고 서브런만 쓴다.", "info")

# ============================================================ 알람
s = d.head("알람", "소리가 나면 이렇게 한다")
d.flow(s, 2.12, [("소리가 난다", "화면 위 붉은 띠", "crit"),
                 ("--status", "왜 울리는지 본다", "warn"),
                 ("메일 확인", "본문에 진단이 있다", "info"),
                 ("조치 후 --silence", "끄는 것은 마지막", "ok")],
       h=0.92, labels=["", "", ""])
d.code(s, M, 3.30, CW, 1.15, [
    "scripts/daq-alarm.sh --status     왜 울리는가, 언제부터인가",
    "scripts/daq-alarm.sh --silence    끈다 — '사람이 인지했다' 는 뜻이다",
], size=13)
d.table(s, M, 4.62, CW, ["사건", "무슨 뜻", "가야 하나"],
        [["restart", "런 하나가 실패해 새 번호로 재시작했다", ("아니오", {"color": OK})],
         ["stale", "런이 쓰기 도중 멈춰 감시자가 개입했다", ("아니오", {"color": OK})],
         ["recovered", "USB 보드를 자동으로 되살렸다", ("아니오", {"color": OK})],
         ["recovery_failed", "자동 복구가 실패했다", ("예 — 현장으로", {"color": CRIT, "bold": True})],
         ["fatal", "감시자가 포기하고 종료했다", ("예 — 현장으로", {"color": CRIT, "bold": True})]],
        widths=[2.6, 6.4, CW - 9.0], rh=0.40, size=13.5)
d.foot(s, "소리를 끄는 것과 문제를 고치는 것은 다르다. 끄기 전에 사유를 먼저 볼 것")

# ============================================================ 자동 복구
s = d.head("알람", "USB 보드가 걸렸을 때 — 기계가 먼저 시도한다")
d.text(s, M, 2.08, CW, 0.45,
       [[("2026-08-20 새벽, FADC 보드가 걸려 런 다섯 개가 연속 실패하고 수집이 2시간 9분 "
          "멎었다. 그때 사람이 한 일을 그대로 코드로 옮겨 두었다.",
          {"size": 15.5, "color": INK2})]])
d.flow(s, 2.75, [("연속 5회 실패", "", "crit"),
                 ("안전 확인", "수집 중이면 중단", "warn"),
                 ("진단", "USB 오류인가", "warn"),
                 ("usbreset ×2", "매번 3분 확인 런", "info"),
                 ("결과", "복구 / 호출", "ok")], h=0.92)
d.bullets(s, M, 3.95, CW, [
    ("복구되면 수집이 그대로 이어진다. ", "실패 카운터를 되돌리고 다음 런으로 간다. 메일만 한 통 온다."),
    ("끝내 안 되면 알람이 울리고 전문가에게 메일이 간다. ", "그때가 사람이 갈 때다."),
    ("살아 있는 런은 절대 건드리지 않는다. ", "복구 스크립트는 맨 처음에 프로세스와 포트를 확인하고, 하나라도 살아 있으면 아무것도 하지 않고 물러난다."),
], size=15)
d.note(s, M, 6.05, CW, 0.85, "손으로 확인해 보고 싶으면",
       "scripts/usb-recover.sh --diagnose  —  읽기만 하므로 수집 중에 돌려도 안전하다.", "ok")

# ============================================================ 데이터
s = d.head("데이터", "지금 어디에 있나")
d.flow(s, 2.15, [("/Data_ssd", "수집 · 후처리", "ok"),
                 ("/data", "백업 대기", "info"),
                 ("경희대", "외부 백업", "info"),
                 ("/scratch", "장기 보관", "warn")], h=0.95, labels=["1", "2", "3"])
d.code(s, M, 3.40, CW, 1.45, [
    "런 하나를 찾을 때는 이 순서로 본다 (앞이 이긴다)",
    ("  /Data_ssd/RAW/<런>   →   /data/RAW/<런>   →   /scratch/RAW/<런>", ACC2),
    "",
    "  <런>/FADC_*.root.*   원시      <런>/Merged/   중간 산출물",
    "  <런>/PRD/*.root      분석 입력  <런>/PNG/      점검 그림",
], size=12.5)
d.bullets(s, M, 5.05, CW, [
    "이동은 자동이다. 후처리가 끝나고 백업이 끝난 런만 다음 단계로 넘어간다",
    ("옮기기 전에 백업한다. ", "산출물이 로컬에 있을 때 보내면 6배 빠르다"),
    ("절대 mv 로 옮기지 말 것. ", "복사 → 체크섬 대조 → 통과한 것만 삭제. 스크립트가 그렇게 한다"),
], size=14.5)

# ============================================================ 대처
s = d.head("복구", "런이 비정상 종료했을 때")
d.text(s, M, 2.08, CW, 0.42,
       [[("런이 쓰다 죽으면 마지막 파일이 닫히지 않는다. 그대로 두면 그 런은 후처리도 이동도 "
          "되지 않고 로컬 디스크에 붙박이로 남는다. 아래 순서대로 하면 된다.",
          {"size": 15.5, "color": INK2})]])
d.code(s, M, 2.54, CW, 2.12, [
    ("1  무엇이 문제인지 본다   — 읽기 전용. 아무것도 옮기지 않는다", OK),
    "     scripts/badrun.sh --scan --run 4293",
    ("2  격리할 것을 미리 본다", OK),
    "     scripts/badrun.sh --quarantine --run 4293 --dry-run",
    ("3  못 쓰는 원시 파일만 <런>/badrun/ 으로 옮긴다", WARN),
    "     scripts/badrun.sh --quarantine --run 4293",
    ("4  목록과 저장소 사본을 갱신한다", OK),
    "     scripts/badrun.sh --scan --update-list  &&  scripts/badrun.sh --export",
])
d.note(s, M, 4.74, CW, 0.95, "격리하면 나머지는 저절로 풀린다",
       "이동과 백업이 격리 폴더를 그대로 함께 가져가므로 고칠 것이 없다. "
       "완결 판정이 통과로 바뀌어 그 런이 다시 흐르기 시작한다.", "ok")
d.note(s, M, 5.78, CW, 1.02, "★ 열리는 파일은 절대 격리하지 않는다",
       "원본이 멀쩡한데 PRD 만 없는 것은 '다시 돌리면 되는 것'이지 못 쓰는 파일이 아니다. "
       "격리 대상은 ROOT 가 열지 못하는 원시 파일뿐이고, 짝은 언제나 함께 옮긴다.", "crit")
d.foot(s, "무엇이 문제였는지는 /Data_ssd/LOG/badrun_list.txt 하나만 보면 된다 (저장소 사본 docs/BADRUNS.md)")

s = d.head("대처", "증상별로 무엇을 볼까")
d.table(s, M, 2.12, CW, ["증상", "먼저 볼 것", "대개의 원인"],
        [["화면이 갱신되지 않는다", "heartbeat 나이 · pgrep -x rcterm", "런컨트롤이 멎었다. 감시자가 곧 재시작한다"],
         ["계수율이 0 이거나 절반", "FADCDAQ/SADCDAQ 로그의 USB 오류", "보드 한 장이 걸렸다 → 자동 복구가 돈다"],
         ["감시자가 FATAL 로 끝났다", "usb-recover 기록 · 메일 본문", "하드웨어. 재기동만 하면 런 번호만 태운다"],
         ["후처리가 0초 만에 실패", "그 이름의 로그를 만들 수 있는지", "로그 경로가 깨진 것이다. 데이터 문제가 아니다"],
         ["끝난 런이 계속 '대기'", "원시 개수와 PRD 개수", "쓰다 죽은 런이다. badrun.sh 로 격리하면 풀린다"],
         ["디스크가 찬다", "df -h /Data_ssd", "이동 체인이 막혔다. dataflow 화면을 본다"],
         ["백업이 느리다", "무엇을 어디서 읽는가", "/scratch 에서 읽으면 6배 느리다"]],
        widths=[3.5, 4.0, CW - 7.5], rh=0.50, size=13.5)
d.note(s, M, 6.20, CW, 0.85, "막히면 순서대로",
       "① 상태 화면  ② 감시자 로그  ③ DAQ 로그  ④ 저장소의 docs/MANUAL.md 디버그 순서", "info")

# ============================================================ 점검 주기
s = d.head("점검", "언제 무엇을 보나")
for i, (when, cost, items, cmds, kind) in enumerate([
        ("매일", "1분", "heartbeat 나이 · 계수율 · 알람 띠 · 디스크 여유",
         ["tmux attach -t daq", "df -h /Data_ssd"], "ok"),
        ("런이 끝나면", "5분", "원시와 PRD 개수가 같은가 · 구글시트에 등재",
         ["scripts/badrun.sh --scan --run <런>",
          "tools/sheetlog/append_runs.py --from <런>"], "info"),
        ("주 1회", "10분", "백업이 밀리지 않았는가 · 문제 런이 늘지 않았는가 · 추이가 이상하지 않은가",
         ["scripts/backup-audit.sh", "tools/monitor/run-summary.sh --show"], "info")]):
    y = 2.08 + i * 1.36
    d.box(s, M, y, CW, 1.24, fill=PANEL)
    d.box(s, M, y, 0.05, 1.24, fill=ACCENT if kind != "ok" else OK)
    d.text(s, M + 0.26, y + 0.18, 2.0, 0.32,
           [[(when, {"size": 18, "bold": True, "color": INK})]])
    d.chip(s, M + 0.26, y + 0.64, 0.95, 0.30, cost, kind, size=11)
    d.text(s, M + 2.45, y + 0.20, 5.1, 0.9,
           [[(items, {"size": 13.5, "color": INK2})]], line_spacing=1.2)
    d.code(s, M + 7.75, y + 0.16, CW - 7.75, 0.92, cmds, size=11.5)
d.note(s, M, 6.12, CW, 1.05, "이 셋 말고는 볼 것이 없다",
       "나머지는 알아서 돌고, 막히면 알람이 울리거나 메일이 온다. 점검은 고장을 찾는 일이 "
       "아니라 조용히 밀리고 있는 것을 보는 일이다.", "info")

# ============================================================ 금지
s = d.head("주의", "수집 중에는 절대 하지 말 것")
for i, (t, why) in enumerate([
        ("src/usbreset 를 실행하지 말 것",
         "보드를 리셋한다. 진행 중인 런이 그 자리에서 깨진다. --help 도 없어서 인자 없이 "
         "돌리면 곧바로 리셋한다. 복구가 필요하면 usb-recover.sh 가 안전 확인 후에 부른다."),
        ("src/NOTICE_CODE_RUN.sh 를 실행하지 말 것",
         "벤더 점검 매크로를 부른다. 보드를 설정하고 돌렸다 세우므로 진행 중인 런이 깨진다."),
        ("pkill · killall · kill -9 를 임의로 쓰지 말 것",
         "DAQ 가 쓰기 도중 죽으면 마지막 파일이 상한다. 정상 정지는 감시자에게 TERM 을 보내는 것이다."),
        ("운영 디렉터리에서 소스를 고치지 말 것",
         "돌고 있는 스크립트를 제자리에서 고치면 셸이 바이트 위치로 이어 읽다 엉뚱한 것을 실행한다. "
         "별도 클론에서 고치고 운영 쪽은 git pull 만 한다.")]):
    d.note(s, M, 2.12 + i * 1.22, CW, 1.12, t, why, "crit")

# ============================================================ 치트시트
s = d.head("정리", "한 장으로")
col = (CW - 0.4) / 2.0
d.text(s, M, 2.10, col, 0.3, [[("매일", {"font": MONO, "size": 12, "bold": True, "color": ACCENT})]])
d.code(s, M, 2.44, col, 1.75, [
    "tmux attach -t daq        화면 붙기",
    "  Ctrl-B 뒤 D             떨어지기",
    "  Ctrl-B 뒤 1 / 2         창 이동",
    "  Ctrl-B 뒤 =             배치 복원",
    "",
    "heartbeat 나이 · 계수율 · 알람 띠",
], size=12.5)
d.text(s, M, 4.35, col, 0.3, [[("알람이 울리면", {"font": MONO, "size": 12, "bold": True, "color": CRIT})]])
d.code(s, M, 4.69, col, 1.35, [
    "scripts/daq-alarm.sh --status",
    "  ... 메일 본문의 진단을 읽는다 ...",
    "scripts/daq-alarm.sh --silence",
], size=12.5)
d.text(s, M + col + 0.4, 2.10, col, 0.3,
       [[("기동 · 정지", {"font": MONO, "size": 12, "bold": True, "color": ACCENT})]])
d.code(s, M + col + 0.4, 2.44, col, 1.75, [
    "scripts/daq-tmux.sh --start",
    "pkill -TERM -x rcsupervisor",
    "",
    "확인 :",
    "  pgrep -x rcsupervisor",
    "  tail -5 /Data/LOG/rcsupervisor.log",
], size=12.5)
d.text(s, M + col + 0.4, 4.35, col, 0.3,
       [[("점검 (읽기만 한다)", {"font": MONO, "size": 12, "bold": True, "color": ACCENT})]])
d.code(s, M + col + 0.4, 4.69, col, 1.55, [
    "scripts/usb-recover.sh --diagnose",
    "scripts/dataflow.sh --once --dry-run",
    "scripts/badrun.sh --scan --run <런>",
    "tools/monitor/run-summary.sh --show",
], size=12.5)
d.text(s, M, 6.30, CW, 0.4,
       [[("자세한 것은  docs/MANUAL.md  ·  docs/ALARM.md  ·  docs/DATAFLOW.md",
          {"font": MONO, "size": 13, "color": MUTED})]], align=PP_ALIGN.CENTER)

OUT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   "..", "..", "docs", "RENE-daq-2026-08-operations-ko.pptx"))
d.save(OUT)
print("저장 : %s  (%d장)" % (OUT, len(d.p.slides._sldIdLst)))
