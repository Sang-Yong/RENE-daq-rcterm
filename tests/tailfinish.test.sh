#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  scripts/tailfinish.sh 시험 (2026-11-06) -- 비정상 런 꼬리 자동 마감
#     판정 : 수집 중 제외 · FADC>=2 · FADC>PRD · quiet · 시도 상한/간격 · 멈춤 파일 · 손 작업 ps
#     처리 : badrun -> carry 확보(임시 merge) -> postrun --from/--to -> runcheck --fix -> 알림
#     dry-run · status 무접촉, cron 환경(env -i), 뒤에서 띄우기, chainwatch 연동
#  ★ 실데이터·ROOT·실메일·실 postrun 무접촉. postrun · runcheck · badrun · daq-notify · merge 를
#    전부 가짜로 갈아끼운다. heartbeat 는 실물(tests/fixtures/rcterm_hb_ended_20261105.txt) 형식.
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
TF=$DIR/scripts/tailfinish.sh
FX=$DIR/tests/fixtures
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$T/bin" "$T/RAW" "$T/prod/LOG/Merge_log" "$T/prod/Code"
#  가짜 postrun : 인자를 적고, --from..--to 의 Merged·PRD 를 만든다 (postrun_noop 이 있으면 아무것도 안 만든다)
cat > "$T/bin/postrun" <<'PR'
#!/bin/bash
echo "$*" >> "$TFT/postrun.calls"
[ -e "$TFT/postrun_noop" ] && exit 1
rn=$1; shift; from=0; to=0; raw=""
while [ $# -gt 0 ]; do case "$1" in --from) from=$2; shift 2;; --to) to=$2; shift 2;; --rawroot) raw=$2; shift 2;; *) shift;; esac; done
rp=$(printf '%06d' "$rn")
for ((n=from;n<=to;n++)); do s=$(printf '%05d' $n); [ -f "$raw/$rp/FADC_$rp.root.$s" ] || continue
  mkdir -p "$raw/$rp/Merged" "$raw/$rp/PRD"; echo m > "$raw/$rp/Merged/MERGED_$rp.root.$s"; echo p > "$raw/$rp/PRD/PRD_$rp.$s.root"; done
exit 0
PR
printf '#!/bin/bash\necho "$*" >> "$TFT/runcheck.calls"\nexit 0\n' > "$T/bin/runcheck"
#  가짜 badrun : 인자를 적고, $TFT/quar_<런> 에 적힌 서브런을 badrun/ 으로 옮긴다 (--dry-run 이면 안 옮긴다)
cat > "$T/bin/badrun" <<'BR'
#!/bin/bash
echo "HB=$BADRUN_HB $*" >> "$TFT/badrun.calls"
case " $* " in *" --dry-run "*) echo "[DRY] would quarantine"; exit 0;; esac
rn=""; while [ $# -gt 0 ]; do case "$1" in --run) rn=$2; shift 2;; *) shift;; esac; done
rp=$(printf '%06d' "$rn"); d="$TFT/RAW/$rp"
[ -r "$TFT/quar_$rn" ] || exit 0
mkdir -p "$d/badrun"; for s in $(cat "$TFT/quar_$rn"); do mv "$d/FADC_$rp.root.$s" "$d/SADC_$rp.root.$s" "$d/badrun/" 2>/dev/null; done
exit 0
BR
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$TFT/notify.calls"\nexit 0\n' > "$T/bin/notify"
#  가짜 merge : rn maxarg sub S E T datadir -> 실물 merge 로그 모양의 carry 세 줄 (S+1, E+10, T+1000)
cat > "$T/bin/merge" <<'MG'
#!/bin/bash
echo "$*" >> "$TFT/merge.calls"
[ -e "$TFT/merge_fail" ] && { echo "Error in <TFile::TFile>"; exit 1; }
[ -d "$7/Merged" ] || exit 3
echo big > "$7/Merged/MERGED_x.root.$(printf '%05d' $3)"
echo "final before_FADC_trgnum = $(( $6 + 1000 ))"
echo "final SADC = $(( $4 + 1 ))"
echo "final SADC_evt = $(( $5 + 10 ))"
echo "final before_SADC_trgnum = $(( $6 + 1000 ))"
MG
chmod +x "$T"/bin/*
export TFT=$T
export TAILFINISH_POSTRUN=$T/bin/postrun TAILFINISH_RUNCHECK=$T/bin/runcheck TAILFINISH_BADRUN=$T/bin/badrun \
       TAILFINISH_NOTIFY=$T/bin/notify TAILFINISH_MERGE=$T/bin/merge TAILFINISH_PS=$T/ps.txt \
       TAILFINISH_STATE=$T/state TAILFINISH_LOG=$T/tf.log TAILFINISH_RUNLOGDIR=$T/runlogs TAILFINISH_TMPROOT=$T/tmp \
       TAILFINISH_LOCKDIR=$T TAILFINISH_RAWROOT=$T/RAW TAILFINISH_HB=$T/rcterm.hb TAILFINISH_HOLD=$T/hold \
       TAILFINISH_PRODDIR=$T/prod
P=$T/notify.params; : > "$P"
ML=$T/prod/LOG/Merge_log

hb() {   # run phase [나이 초]
   sed -e "s/^time=.*/time=$(( $(date +%s) - ${3:-0} ))/" -e "s/^phase=.*/phase=$2/" -e "s/^run=.*/run=$1/" \
       "$FX/rcterm_hb_ended_20261105.txt" > "$T/rcterm.hb"
}
mklog() { # rn sub  -- 실물 merge 로그 모양 (carry 세 줄)
   printf 'final before_FADC_trgnum = 789678\nfinal SADC = %s\nfinal SADC_evt = 261\nfinal before_SADC_trgnum = 789678\n' "$(( $2 + 1 ))" \
      > "$ML/log_merge_FADC_SADC_v3_5v_run$1_subrun$2.txt"
}
#  런 만들기 : rn nfadc ndone  -- FADC·SADC 0..nfadc-1, 0..ndone-1 은 Merged+PRD 있음. 파일은 1 시간 전
mkrun() {
   local rn=$1 nf=$2 nd=$3 rp d s n
   rp=$(printf '%06d' "$rn"); d=$T/RAW/$rp
   mkdir -p "$d/Merged" "$d/PRD" "$d/PNG"
   for ((n=0;n<nf;n++)); do s=$(printf '%05d' $n); echo f > "$d/FADC_$rp.root.$s"; echo s > "$d/SADC_$rp.root.$s"; done
   for ((n=0;n<nd;n++)); do s=$(printf '%05d' $n); echo m > "$d/Merged/MERGED_$rp.root.$s"; echo p > "$d/PRD/PRD_$rp.$s.root"; done
   echo dly > "$d/PRD/Run${rp}_DLY_THR.log"
   find "$d" -type f -exec touch -d '1 hour ago' {} +
}
reset() {
   rm -rf "${T:?}/RAW" "${T:?}/state" "${T:?}/tf.log" "${T:?}/runlogs" "${T:?}/tmp" "${T:?}/hold" \
          "${T:?}/postrun_noop" "${T:?}/merge_fail" "${T:?}/prod/LOG/Merge_log"
   rm -f "${T:?}"/*.calls "${T:?}"/quar_*
   mkdir -p "$T/RAW" "$ML"; : > "$T/ps.txt"; hb 9999 running
}
nfadc() { ls "$T/RAW/$(printf '%06d' "$1")" | grep -c '^FADC_'; }
nprd()  { ls "$T/RAW/$(printf '%06d' "$1")/PRD" | grep -c '^PRD_.*\.root$'; }
run() { "$TF" --params "$P" "$@" > "$T/out" 2>&1; }

echo "[1] 대상 런을 마감한다 (carry 있음)"
reset; mkrun 4434 6 3; mklog 4434 2
run --foreground
check "postrun --from 3 --to 5 --heartbeat /dev/null"  'grep -q "^4434 --from 3 --to 5 --heartbeat /dev/null --rawroot $T/RAW" "$T/postrun.calls"'
check "runcheck --run 4434 --heartbeat /dev/null --fix" 'grep -q -- "--run 4434 --heartbeat /dev/null --fix" "$T/runcheck.calls"'
check "badrun --quarantine --run 4434 (HB 비움)"        'grep -q "^HB=/dev/null --quarantine --run 4434" "$T/badrun.calls"'
check "FADC == PRD"                                     '[ "$(nfadc 4434)" -eq 6 ] && [ "$(nprd 4434)" -eq 6 ]'
check "tail_finish 알림"                                'grep -q "^--params $P tail_finish --run 4434" "$T/notify.calls"'
check "merge 재실행 없음 (carry 있음)"                   '[ ! -s "$T/merge.calls" ]'
check "상태 done_4434"                                  'grep -q "^done_4434=" "$T/state"'
rm -f "${T:?}/postrun.calls"; run --foreground
check "다시 돌려도 대상 아님 (완결)"                     '[ ! -e "$T/postrun.calls" ]'

echo "[2] 수집 중 판정"
reset; mkrun 4434 6 3; mklog 4434 2; hb 4434 running 5
run --foreground
check "heartbeat run=4434 running(신선) -> 손대지 않음"  '[ ! -e "$T/postrun.calls" ]'
hb 4434 ended 5; run --foreground
check "phase=ended -> 대상"                              '[ -s "$T/postrun.calls" ]'
reset; mkrun 4434 6 3; mklog 4434 2; hb 4434 running 3600
run --foreground
check "heartbeat 가 1 시간 묵음(정전·kill -9) -> 대상"   '[ -s "$T/postrun.calls" ]'

echo "[3] 대상 아님 : FADC 1 · 최근 변경 · 손 작업 · 멈춤 파일 · 로그 루트 없음"
reset; mkrun 4424 1 0; run --foreground
check "FADC 1 개 (부팅 실패 잔재) -> 손대지 않음"         '[ ! -e "$T/postrun.calls" ] && [ ! -e "$T/badrun.calls" ]'
reset; mkrun 4434 6 3; mklog 4434 2; touch "$T/RAW/004434/PRD/PRD_004434.00002.root"; run --foreground
check "최근 600 초 안에 PRD 가 바뀜 -> 손대지 않음"       '[ ! -e "$T/postrun.calls" ]'
reset; mkrun 4434 6 3; mklog 4434 2; echo "777 bash scripts/postrun.sh 4434 --from 3 --to 5 --heartbeat /dev/null" > "$T/ps.txt"; run --foreground
check "postrun 4434 손 작업 -> 손대지 않음"              '[ ! -e "$T/postrun.calls" ]'
echo "778 bash scripts/runcheck.sh --run 4434 --fix" > "$T/ps.txt"; run --foreground
check "runcheck --run 4434 손 작업 -> 손대지 않음"       '[ ! -e "$T/postrun.calls" ]'
echo "780 root -l -b -q merge_FADC_SADC_v3_5v.cc(4434,12,2,2,0,0,\"/Data_ssd/RAW/004434\")" > "$T/ps.txt"; run --foreground
check "손 merge 4434 -> 손대지 않음"                     '[ ! -e "$T/postrun.calls" ]'
echo "779 bash scripts/postrun.sh 44345 --from 0" > "$T/ps.txt"; run --foreground
check "다른 런(44345) 은 막지 않는다"                    '[ -s "$T/postrun.calls" ]'
reset; mkrun 4434 6 3; mklog 4434 2; touch "$T/hold"; run --foreground
check "멈춤 파일 -> 아무것도 안 함"                       '[ ! -e "$T/postrun.calls" ] && [ ! -e "$T/badrun.calls" ] && [ ! -e "$T/state" ]'
reset; mkrun 4434 6 3; mklog 4434 2; mv "$T/prod/LOG" "$T/prod/LOG.x"; run --foreground
check "로그 루트 없음(/scratch 빠짐) -> 시도 안 셈"       '[ ! -e "$T/postrun.calls" ] && [ ! -e "$T/state" ]'
mv "$T/prod/LOG.x" "$T/prod/LOG"

echo "[4] 시도 상한 · 재시도 간격 · 실패 알림 1 회"
reset; mkrun 4434 6 3; mklog 4434 2; touch "$T/postrun_noop"
run --foreground
check "1 회차 : 시도 1, 실패 알림 아직 없음"              'grep -q "^try_4434=1" "$T/state" && ! grep -q tail_finish_failed "$T/notify.calls" 2>/dev/null'
rm -f "${T:?}/postrun.calls"; run --foreground
check "곧바로 다시 : 재시도 대기 (postrun 안 부름)"        '[ ! -e "$T/postrun.calls" ]'
sed -i "s/^last_4434=.*/last_4434=$(( $(date +%s) - 7200 ))/" "$T/state"; run --foreground
check "2 시간 뒤 2 회차 : tail_finish_failed 1 통"        '[ "$(grep -c tail_finish_failed "$T/notify.calls")" -eq 1 ] && grep -q "^gaveup_4434=" "$T/state"'
check "실패 메일에 상세 파일을 넘긴다"                     'grep tail_finish_failed "$T/notify.calls" | grep -q -- "--detail-file"'
sed -i "s/^last_4434=.*/last_4434=0/" "$T/state"; rm -f "${T:?}/postrun.calls"; run --foreground
check "포기한 런은 다시 안 함"                             '[ ! -e "$T/postrun.calls" ] && [ "$(grep -c tail_finish_failed "$T/notify.calls")" -eq 1 ]'
run --run 4434 --foreground --force
check "--force 로는 다시 한다"                            '[ -s "$T/postrun.calls" ]'

echo "[5] 격리만으로 완결 (꼬리 짝이 badrun/ 으로)"
reset; mkrun 4392 5 4; mklog 4392 3; echo 00004 > "$T/quar_4392"
run --foreground
check "postrun 안 부름 (결손 없음)"                        '[ ! -e "$T/postrun.calls" ]'
check "FADC 4 = PRD 4 로 tail_finish"                     'grep -q "tail_finish --run 4392 .*FADC 4 = PRD 4" "$T/notify.calls"'

echo "[6] carry 확보 : 직전 로그가 없으면 임시 디렉터리에서 다시 merge"
reset; mkrun 4434 6 3; mklog 4434 1        # sub 2 의 로그 없음, sub 1 의 로그 있음
run --foreground
check "merge 1 회 (sub 2, carry 2,261,789678)"             '[ "$(wc -l < "$T/merge.calls")" -eq 1 ] && grep -q "^4434 5 2 2 261 789678 $T/tmp/004434\." "$T/merge.calls"'
check "sub 2 로그에 carry 3 줄"                            'grep -q "final SADC = 3" "$ML/log_merge_FADC_SADC_v3_5v_run4434_subrun2.txt" && grep -q "final before_SADC_trgnum = 790678" "$ML/log_merge_FADC_SADC_v3_5v_run4434_subrun2.txt"'
check "이미 있는 Merged 는 안 건드림"                       '[ "$(cat "$T/RAW/004434/Merged/MERGED_004434.root.00002")" = m ]'
check "임시 디렉터리 지움"                                 '[ -z "$(ls -A "$T/tmp" 2>/dev/null)" ]'
check "그 뒤 postrun --from 3"                             'grep -q "^4434 --from 3 --to 5" "$T/postrun.calls"'
reset; mkrun 4434 6 3                       # 로그가 하나도 없다 -> sub 0 부터 (0,0,0)
run --foreground
check "로그 없음 : sub 0,1,2 를 차례로 다시 merge"          '[ "$(cut -d" " -f3 "$T/merge.calls" | paste -sd,)" = "0,1,2" ] && grep -q "^4434 5 0 0 0 0 " "$T/merge.calls"'
check "carry 가 이어진다 (sub 2 는 S=2)"                   'grep -q "^4434 5 2 2 20 2000 " "$T/merge.calls"'
reset; mkrun 4434 6 3; printf 'Error\n' > "$ML/log_merge_FADC_SADC_v3_5v_run4434_subrun2.txt"; mklog 4434 1
run --foreground
check "carry 없는 로그는 옆으로 비키고 새로 쓴다"           'ls "$ML" | grep -q "subrun2.txt.nocarry." && grep -q "final SADC = 3" "$ML/log_merge_FADC_SADC_v3_5v_run4434_subrun2.txt"'
reset; mkrun 4434 6 3; touch "$T/merge_fail"
run --foreground
check "merge 재실행 실패 -> postrun 을 부르지 않는다"        '[ ! -e "$T/postrun.calls" ]'
reset; mkrun 4434 40 35; printf 'tail_carry_back = 5\ntail_max_try = 1\n' > "$P"
run --foreground
check "5 개 안에 carry 없음 -> merge·postrun 안 함"          '[ ! -e "$T/merge.calls" ] && [ ! -e "$T/postrun.calls" ]'
check "  ... 실패 알림에 carry 사유 (시도 상한 1)"           'grep tail_finish_failed "$T/notify.calls" | grep -q "carry"'
: > "$P"

echo "[7] 결손 경계가 둘 : 각 경계마다 carry"
reset; mkrun 4434 8 3; mklog 4434 2
#  sub 5 도 끝나 있다 (3,4 결손 / 5 끝 / 6,7 결손). sub 4·5 의 로그 없음 -> 6 의 carry 를 위해 3..5 를 다시 merge
d=$T/RAW/004434; echo m > "$d/Merged/MERGED_004434.root.00005"; echo p > "$d/PRD/PRD_004434.00005.root"; touch -d '1 hour ago' "$d"/Merged/* "$d"/PRD/*
run --foreground
check "sub 5 경계에서 merge 재실행 (sub 3,4,5 from log 2)"  '[ "$(cut -d" " -f3 "$T/merge.calls" | paste -sd,)" = "3,4,5" ]'

echo "[8] --dry-run · --status 는 아무것도 안 바꾼다"
reset; mkrun 4434 6 3
run --dry-run
check "dry-run : postrun·runcheck·notify·merge 안 부름"     '[ ! -e "$T/postrun.calls" ] && [ ! -e "$T/runcheck.calls" ] && [ ! -e "$T/notify.calls" ] && [ ! -e "$T/merge.calls" ]'
check "dry-run : badrun 은 --dry-run 으로만"               'grep -q -- "--dry-run" "$T/badrun.calls" && ! grep -v -- "--dry-run" "$T/badrun.calls" | grep -q .'
check "dry-run : 상태·로그·임시 파일 없음"                  '[ ! -e "$T/state" ] && [ ! -e "$T/tf.log" ] && [ ! -e "$T/runlogs" ] && [ ! -e "$T/tmp" ]'
check "dry-run : 계획을 찍는다"                             'grep -q "postrun.* 4434 --from 3 --to 5" "$T/out" && grep -q "carry : 서브런 2" "$T/out"'
rm -f "${T:?}"/*.calls; run --status
check "status : 대상 표시, 아무것도 안 부름"                 'grep -q "run 4434 .*★ 대상" "$T/out" && [ ! -e "$T/badrun.calls" ] && [ ! -e "$T/state" ]'

echo "[9] 뒤에서 띄우기 (chainwatch 가 부르는 꼴)"
reset; mkrun 4434 6 3; mklog 4434 2
t0=$(date +%s); "$TF" --params "$P" > "$T/out" 2>&1; t1=$(date +%s)
for i in $(seq 1 50); do grep -q tail_finish "$T/notify.calls" 2>/dev/null && break; sleep 0.2; done
check "곧바로 돌아온다 (2 초 안)"                         '[ $(( t1 - t0 )) -le 2 ]'
check "뒤의 일꾼이 마감했다"                               'grep -q "tail_finish --run 4434" "$T/notify.calls"'
reset; "$TF" --params "$P" > "$T/out" 2>&1; sleep 1
check "대상 없으면 일꾼을 안 띄운다"                        '[ ! -e "$T/tf.log" ]'

echo "[10] cron 환경 (env -i)"
reset; mkrun 4434 6 3; mklog 4434 2
env -i PATH=/usr/bin:/bin HOME="$HOME" TFT="$T" TAILFINISH_POSTRUN="$TAILFINISH_POSTRUN" TAILFINISH_RUNCHECK="$TAILFINISH_RUNCHECK" \
   TAILFINISH_BADRUN="$TAILFINISH_BADRUN" TAILFINISH_NOTIFY="$TAILFINISH_NOTIFY" TAILFINISH_MERGE="$TAILFINISH_MERGE" \
   TAILFINISH_PS="$T/ps.txt" TAILFINISH_STATE="$T/state" TAILFINISH_LOG="$T/tf.log" TAILFINISH_RUNLOGDIR="$T/runlogs" \
   TAILFINISH_TMPROOT="$T/tmp" TAILFINISH_LOCKDIR="$T" TAILFINISH_RAWROOT="$T/RAW" TAILFINISH_HB="$T/rcterm.hb" \
   TAILFINISH_HOLD="$T/hold" TAILFINISH_PRODDIR="$T/prod" bash -c "cd / && '$TF' --params '$P' --foreground" > "$T/out" 2>&1
check "cd / · env -i 에서도 마감"                          'grep -q "tail_finish --run 4434" "$T/notify.calls"'

echo "[11] chainwatch 연동"
CW=$DIR/scripts/chainwatch.sh
printf '#!/bin/bash\necho "$*" >> "%s/tfkick.calls"\n[ -e /proc/self/fd/9 ] && echo fd9 >> "%s/tfkick.fd"\nexit 0\n' "$T" "$T" > "$T/bin/tfkick"; chmod +x "$T/bin/tfkick"
printf '#!/bin/bash\nexit 1\n' > "$T/bin/false"; chmod +x "$T/bin/false"
cwrun() { CHAINWATCH_TAILFINISH=$T/bin/tfkick CHAINWATCH_LOCK=$T/.cwlock CHAINWATCH_TMUX=$T/bin/false CHAINWATCH_PGREP=$T/bin/false \
          CHAINWATCH_MOUNTPOINT=$T/bin/false CHAINWATCH_PS=$T/ps.txt CHAINWATCH_DF_FILE=$T/df.txt CHAINWATCH_SUPLOG=$T/sup.log \
          CHAINWATCH_HOLD=$T/hold CHAINWATCH_BTIME=0 NOTIFY_LOG=$T/notify.log NETSYNC_STATE=$T/netsync.state \
          "$CW" --params "$1" --gate on --heartbeat "$T/rcterm.hb" --state "$T/cwstate" --log "$T/cw.log" --dbfile /nonexistent.db \
          --notify "$T/bin/notify" "${@:2}" > "$T/cwout" 2>&1; }
: > "$T/df.txt"; : > "$T/sup.log"; rm -f "${T:?}/tfkick.calls"
cwrun "$P"
check "chain_tailfinish 없음 -> 부르지 않는다 (기본 0)"     '[ ! -e "$T/tfkick.calls" ]'
printf 'chain_tailfinish = 1\n' > "$T/cw1.params"
cwrun "$T/cw1.params"
check "chain_tailfinish = 1 -> --params 로 부른다"          'grep -qx -- "--params $T/cw1.params" "$T/tfkick.calls"'
check "chainwatch 잠금(fd 9)을 물려주지 않는다"             '[ ! -e "$T/tfkick.fd" ]'
rm -f "${T:?}/tfkick.calls"; cwrun "$T/cw1.params" --dry-run
check "chainwatch --dry-run -> tailfinish --dry-run"        'grep -qx -- "--params $T/cw1.params --dry-run" "$T/tfkick.calls"'
rm -f "${T:?}/tfkick.calls"; cwrun "$T/cw1.params" --gate off
check "gate off -> 부르지 않는다"                           '[ ! -e "$T/tfkick.calls" ]'

echo
echo "결과 : $PASS 통과 / $FAIL 실패"
[ "$FAIL" -eq 0 ]
