#!/usr/bin/env bash
# status.sh -- daq-status-check 스킬의 항목을 순서대로 찍는다. 읽기 전용. 어느 항목이 실패해도 끝까지 간다.
set -u
DIR=${RENE_DAQ_DIR:-/home/frontend/DAQ/RENE-daq-rcterm}
sec() { printf '\n=== %s\n' "$*"; }
run=$(sed -n 's/^run=//p' /Data/LOG/rcterm.hb 2>/dev/null); rr=$(printf %06d "${run:-0}")
sec "수집 heartbeat ($(date '+%F %T'), hb time 차 $(( $(date +%s) - $(sed -n 's/^time=//p' /Data/LOG/rcterm.hb 2>/dev/null || echo 0) )) s)"; grep -E 'phase=|run=|subrun=|error=|ar=' /Data/LOG/rcterm.hb 2>/dev/null || echo "heartbeat 없음"
sec "감시자"; printf 'rcsupervisor pid: %s\n' "$(pgrep -x rcsupervisor | tr '\n' ' ')"; tail -3 /Data/LOG/rcsupervisor.log 2>/dev/null | cut -c1-140
sec "DRAM·USB (run $run)"; printf 'aligned=%s fail=%s libusb=%s\n' "$(grep -c 'is aligned' /Data_ssd/LOG/TCB_$rr.log 2>/dev/null)" "$(grep -c 'Fail to align' /Data_ssd/LOG/TCB_$rr.log 2>/dev/null)" "$(cat /Data_ssd/LOG/{TCB,FADCDAQ,SADCDAQ}_$rr.log 2>/dev/null | grep -c LIBUSB)"
sec "프로세스·포트"; printf 'rcterm %s · daq %s · tcb %s · merger %s · 포트 %s\n' "$(pgrep -x rcterm|wc -l)" "$(pgrep -x daq|wc -l)" "$(pgrep -x tcb|wc -l)" "$(pgrep -x merger|wc -l)" "$(ss -ltn 2>/dev/null | grep -cE ':780[9]|:781[45]')"
sec "tmux"; tmux list-panes -t daq:1 -F '#{pane_index} #{pane_current_command}' 2>&1 | tr '\n' ' '; echo
sec "후처리 사슬 (chainwatch --status)"; timeout 60 "$DIR/scripts/chainwatch.sh" --status 2>&1 | head -15
sec "cron"; crontab -l 2>/dev/null | grep -vE '^#|^\s*$' | awk '{print $1,$2,$6}' | sed "s|$DIR/||"
sec "cron 로그 마지막 줄"; for f in chainwatch sheetlog-auto websummary backup-sheetlog minerwatch reactor-power/reactor-power-log; do printf '%-28s ' "$f"; tail -1 /Data_ssd/LOG/$f.log 2>/dev/null | cut -c1-100 || echo "-"; echo; done
sec "웹 서머리"; timeout 60 "$DIR/tools/monitor/websummary.sh" --status 2>&1 | head -6
sec "메일 큐"; timeout 30 "$DIR/scripts/mailq-send.sh" --status 2>&1 | head -4
sec "백업 세션 (store)"; timeout 20 ssh -o ConnectTimeout=8 store 'printf "lock holder: %s\n" "$(fuser ~/sykim/backup_log/.backup.lock 2>/dev/null)"; tail -c 300 ~/sykim/backup_log/code9.log 2>/dev/null | tr "\r" "\n" | tail -2; findmnt -no SOURCE,TARGET /backup_hdd /backup_hdd_2 2>/dev/null' 2>&1 | cut -c1-140
sec "용량"; df -h /Data_ssd /data /scratch 2>/dev/null | awk 'NR>1{print $6, $4" 여유", $5}'; timeout 15 ssh -o ConnectTimeout=8 khu 'df -h /store 2>/dev/null | tail -1' 2>/dev/null | awk '{print "khu /store", $4" 여유", $5}'
sec "보안·부하"; timeout 60 "$DIR/scripts/minerwatch.sh" --status 2>&1 | head -8; printf 'load %s\n' "$(cut -d' ' -f1-3 /proc/loadavg)"; ps -eo user,pcpu,rss,comm --sort=-pcpu 2>/dev/null | head -4
sec "메모리"; free -g | head -2; printf 'OOM 기록 %s 건\n' "$(dmesg -T 2>/dev/null | grep -c 'Out of memory')"
sec "원자로 출력 기록"; timeout 30 "$DIR/scripts/reactor-power-log.sh" --status 2>&1 | tail -3
sec "직전 완결 런 대조"; prev=$(sqlite3 /Data_ssd/runcatalog.db "select max(runnum) from runcatalog where runnum<${run:-0} and onlbit=1" 2>/dev/null); [ -n "$prev" ] && timeout 120 "$DIR/scripts/runcheck.sh" --run "$prev" 2>&1 | grep -E 'FADC|빠진|완결' | head -3
exit 0
