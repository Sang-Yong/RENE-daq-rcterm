#!/usr/bin/env bash
# minerwatch.test.sh -- scripts/minerwatch.sh 시험. ps/ss/find 를 픽스처로 갈아끼우고 가짜 send_mail 로 메일을 센다. 실 시스템·실 메일 무접촉.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }; ng() { fail=$((fail+1)); echo "  FAIL $1"; }
chk() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }
cat > "$T/mail.py" <<'EOF'
import sys; open(sys.argv[sys.argv.index('--body-file')+1]).read(); open(__import__('os').environ['MW_MAILLOG'],'a').write(' '.join(sys.argv[1:])+'\n')
EOF
export MINERWATCH_MAIL="$T/mail.py" MW_MAILLOG="$T/mail.log" MINERWATCH_LOGDIR="$T/log"
# 픽스처 : 2026-09-10 실물 모양
printf '%s\n' "227242 sklee 535 2497403 ./sshd" "227835 sklee 536 2497403 ./rcu-sched" "1 root 0.1 99999 /usr/lib/systemd/systemd" "4321 frontend 400 99999 /home/frontend/DAQ/DAQ_cup/install/bin/daq -f" "777 ojk 350 1200 root.exe -l -b" > "$T/ps.bad"
printf '%s\n' "1 root 0.1 99999 /usr/lib/systemd/systemd" "4321 frontend 400 99999 /home/frontend/DAQ/DAQ_cup/install/bin/daq -f" "900 root 0 99 /usr/sbin/sshd -D" > "$T/ps.ok"
printf '%s\n' "0 0 203.230.111.71:51234 141.94.96.71:3333" "0 0 203.230.111.71:51235 141.94.96.71:3333" "0 0 10.0.0.11:2049 10.0.0.10:822" > "$T/ss.bad"
printf '%s\n' "0 0 10.0.0.11:2049 10.0.0.10:822" "0 0 203.230.111.71:443 160.79.104.10:443" > "$T/ss.ok"
printf '%s\n' "/dev/shm/.ICE-unix/rcu-sched" "/dev/shm/sshd" > "$T/find.bad"; : > "$T/find.ok"
run() { MINERWATCH_PS=$1 MINERWATCH_SS=$2 MINERWATCH_FIND=$3 "$DIR/scripts/minerwatch.sh" "${4:-}"; }

echo "[1] 깨끗한 시스템 : 징후 없음, 메일 없음"
out=$(run "$T/ps.ok" "$T/ss.ok" "$T/find.ok" --status); chk "status 가 '징후 없음'" "[[ \"\$out\" == *'징후 없음'* ]]"
run "$T/ps.ok" "$T/ss.ok" "$T/find.ok"; chk "메일 0" "[ ! -f $T/mail.log ]"
chk "상태 파일 sig 비어 있음" "grep -q '^sig=\$' $T/log/minerwatch.state"
echo "[2] 채굴기 모양 : A·B·C 셋 다 잡고 메일 1 통, D 는 참고"
out=$(run "$T/ps.bad" "$T/ss.bad" "$T/find.bad" --status)
chk "A ./sshd" "[[ \"\$out\" == *'./sshd'* ]]"; chk "A ./rcu-sched" "[[ \"\$out\" == *'./rcu-sched'* ]]"
chk "B /dev/shm 실행 파일" "[[ \"\$out\" == *'/dev/shm/.ICE-unix/rcu-sched'* ]]"; chk "C 3333 연결 x2" "[[ \"\$out\" == *'x2'* && \"\$out\" == *':3333'* ]]"
chk "D ojk 고 CPU 참고" "[[ \"\$out\" == *'[D]'* && \"\$out\" == *'ojk'* ]]"; chk "frontend 의 daq 400% 는 D 에 없음" "[[ \"\$out\" != *'daq -f'* ]]"
run "$T/ps.bad" "$T/ss.bad" "$T/find.bad"; chk "메일 1 통" "[ \$(wc -l < $T/mail.log) = 1 ]"
chk "제목에 [보안]" "grep -q '보안' $T/mail.log"; chk "routine(책임자) 로" "grep -q -- '--to routine' $T/mail.log"
chk "상태 sig 기록" "grep -q '^sig=A' $T/log/minerwatch.state"
echo "[3] 같은 징후 10 분 뒤 : 메일 생략"
run "$T/ps.bad" "$T/ss.bad" "$T/find.bad"; chk "여전히 1 통" "[ \$(wc -l < $T/mail.log) = 1 ]"; chk "로그에 생략" "grep -q '생략' $T/log/minerwatch.log"
echo "[4] 6 시간 지남 : 다시 1 통"
sed -i 's/^last_mail=.*/last_mail=1/' "$T/log/minerwatch.state"; run "$T/ps.bad" "$T/ss.bad" "$T/find.bad"; chk "2 통" "[ \$(wc -l < $T/mail.log) = 2 ]"
echo "[5] 징후가 바뀌면(연결만 남음) 곧바로 1 통"
run "$T/ps.ok" "$T/ss.bad" "$T/find.ok"; chk "3 통" "[ \$(wc -l < $T/mail.log) = 3 ]"
echo "[6] 해소 : 로그에 '해소', 메일 없음"
run "$T/ps.ok" "$T/ss.ok" "$T/find.ok"; chk "해소 기록" "grep -q '해소' $T/log/minerwatch.log"; chk "여전히 3 통" "[ \$(wc -l < $T/mail.log) = 3 ]"
echo "[7] --dry-run 은 본문을 찍고 보내지 않는다"
out=$(run "$T/ps.bad" "$T/ss.bad" "$T/find.bad" --dry-run); chk "본문에 cleanup-root.sh 안내" "[[ \"\$out\" == *'cleanup-root.sh'* ]]"; chk "여전히 3 통" "[ \$(wc -l < $T/mail.log) = 3 ]"
echo "[8] cron 환경 (env -i)"
env -i PATH=/usr/bin:/bin HOME=$HOME MINERWATCH_MAIL="$T/mail.py" MW_MAILLOG="$T/mail.log" MINERWATCH_LOGDIR="$T/log" MINERWATCH_PS="$T/ps.ok" MINERWATCH_SS="$T/ss.ok" MINERWATCH_FIND="$T/find.ok" "$DIR/scripts/minerwatch.sh"; chk "exit 0" "[ \$? = 0 ]"
rm -rf "$T"; echo "minerwatch : pass $pass / fail $fail"; [ $fail = 0 ]
