#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  backup-audit.sh - 로컬과 경희대 서버를 대조해 '어긋난 런' 을 찾아낸다.
#
#  로컬이 우선이고 경희대는 크로스체크용이다. 그래서 두 가지를 본다.
#     ① 로컬에 있는데 원격에 없는 런   -> 아직 백업이 안 됐다 (급하다)
#     ② 원격에 있는데 로컬에 없는 런   -> 로컬에서 정리된 옛 런 (정상일 수 있다)
#     ③ 양쪽에 다 있는데 개수가 다른 런 -> 전송이 덜 끝났다 (--deep)
#
#  사용 :
#     backup-audit.sh                      화면으로 본다
#     backup-audit.sh --mail               결과를 메일로 보낸다 (daq-notify 경유)
#     backup-audit.sh --deep 20            최근 20개 런은 파일 개수까지 대조
#     backup-audit.sh --from 4200 --to 4300  구간을 좁힌다
#
#  ★ 읽기만 한다. 아무것도 옮기거나 지우지 않는다. 수집 중에 돌려도 안전하다.
#  ★ 원격 목록은 ssh 한 번으로 통째로 받는다 -- 런마다 붙으면 몇 시간이 걸린다.
# ---------------------------------------------------------------------
set -u

DIR=$(cd "$(dirname "$0")/.." && pwd)
PARAMS=$DIR/config/notify.params
NOTIFY=$DIR/scripts/daq-notify.sh

LOCAL_ROOTS="/Data_ssd/RAW /data/RAW /scratch/RAW"
REMOTE=khu
RBASE=/store/cpnr-data/RENE
FROM=0; TO=999999; DEEP=0; MAIL=0
OUT=$(mktemp /tmp/backup-audit-XXXXXX.txt)

die() { echo "backup-audit: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
   case "$1" in
      --params) PARAMS=$2; shift 2 ;;
      --remote) REMOTE=$2; shift 2 ;;
      --rbase)  RBASE=$2; shift 2 ;;
      --from)   FROM=$2; shift 2 ;;
      --to)     TO=$2; shift 2 ;;
      --deep)   DEEP=${2:-20}; shift 2 ;;
      --mail)   MAIL=1; shift ;;
      -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) die "모르는 인자 : $1" ;;
   esac
done

TMP=$(mktemp -d /tmp/backup-audit-XXXXXX) || die "임시 디렉터리 실패"
trap 'rm -rf "$TMP"' EXIT

# ---- 로컬 목록 ------------------------------------------------------
: > "$TMP/local"
for r in $LOCAL_ROOTS; do
   [ -d "$r" ] || continue
   ls -1U "$r" 2>/dev/null | grep -E '^[0-9]{6}$' >> "$TMP/local"
done
sort -u "$TMP/local" -o "$TMP/local"

# ---- 원격 목록 (ssh 한 번) ------------------------------------------
if ! timeout 180 ssh -o ConnectTimeout=20 -o BatchMode=yes "$REMOTE" \
        "ls -1U $RBASE/RAW $RBASE/PRD 2>/dev/null" \
        | grep -E '^[0-9]{6}$' | sort -u > "$TMP/remote"; then
   echo "원격 목록을 받지 못했다 ($REMOTE)" | tee "$OUT"
   [ "$MAIL" -eq 1 ] && "$NOTIFY" --params "$PARAMS" backup_audit \
        --msg "경희대 서버에 접속하지 못했다" --detail-file "$OUT" >/dev/null 2>&1
   exit 1
fi

inrange() { awk -v a="$FROM" -v b="$TO" '{ n=$1+0; if (n>=a && n<=b) print }' ; }
comm -23 "$TMP/local"  "$TMP/remote" | inrange > "$TMP/only_local"
comm -13 "$TMP/local"  "$TMP/remote" | inrange > "$TMP/only_remote"
comm -12 "$TMP/local"  "$TMP/remote" | inrange > "$TMP/both"

NL=$(wc -l < "$TMP/local"); NR=$(wc -l < "$TMP/remote")
OL=$(wc -l < "$TMP/only_local"); OR=$(wc -l < "$TMP/only_remote"); NB=$(wc -l < "$TMP/both")

{
  echo "백업 대조  $(date '+%F %T')   $(hostname)  <->  $REMOTE:$RBASE"
  echo "범위 : run $FROM ~ $TO"
  echo
  printf "  로컬 %d개 / 원격 %d개 / 양쪽 %d개\n" "$NL" "$NR" "$NB"
  echo
  echo "== ① 로컬에만 있다 = 아직 백업 안 됨 : ${OL}개 =="
  if [ "$OL" -eq 0 ]; then echo "   (없음)"; else
     # 한 줄에 10개씩. paste + fold 로 접으면 들여쓰기가 들쭉날쭉해진다
     awk '{ printf "%s%s", (c%10==0 ? "   " : " "), $1; c++;
            if (c%10==0) printf "\n" } END { if (c%10) printf "\n" }' "$TMP/only_local"
  fi
  echo
  echo "== ② 원격에만 있다 = 로컬에서 정리된 옛 런 : ${OR}개 =="
  if [ "$OR" -eq 0 ]; then echo "   (없음)"; else
     echo "   가장 최근 20개 : $(tail -20 "$TMP/only_remote" | paste -sd' ' -)"
  fi
} > "$OUT"

# ---- ③ 개수까지 대조 (--deep) ---------------------------------------
if [ "$DEEP" -gt 0 ] && [ "$NB" -gt 0 ]; then
   TARGETS=$(tail -"$DEEP" "$TMP/both")
   {
     echo
     echo "== ③ 양쪽에 있으나 파일 개수가 다르다 (최근 ${DEEP}개 런) =="
   } >> "$OUT"
   # 원격 개수는 한 번에 받는다
   timeout 300 ssh -o ConnectTimeout=20 -o BatchMode=yes "$REMOTE" \
      "for d in $TARGETS; do printf '%s %s\n' \"\$d\" \"\$(ls -1U $RBASE/RAW/\$d 2>/dev/null | wc -l)\"; done" \
      > "$TMP/rcount" 2>/dev/null
   diffs=0
   while read -r d rn; do
      [ -n "${d:-}" ] || continue
      ln=0
      for r in $LOCAL_ROOTS; do
         [ -d "$r/$d" ] || continue
         n=$(ls -1U "$r/$d" 2>/dev/null | grep -c '^FADC_.*\.root\.')
         [ "${n:-0}" -gt "$ln" ] && ln=$n
      done
      # 원격 RAW 에는 FADC+SADC 가 함께 있으므로 로컬 FADC 의 2배가 기준이다
      exp=$(( ln * 2 ))
      if [ "$ln" -gt 0 ] && [ "${rn:-0}" -lt "$exp" ]; then
         printf "   run %s : 로컬 FADC %d (원격 기대 %d) / 원격 %s\n" "$d" "$ln" "$exp" "${rn:-0}" >> "$OUT"
         diffs=$((diffs+1))
      fi
   done < "$TMP/rcount"
   [ "$diffs" -eq 0 ] && echo "   (어긋난 런 없음)" >> "$OUT"
   echo "   어긋남 ${diffs}건" >> "$OUT"
fi

{
  echo
  echo "-- 무엇을 하면 되나 --"
  if [ "$OL" -gt 0 ]; then
     echo "   ① 이 런들은 아직 원격에 없다. 옛 런이면 다음으로 천천히 보낸다 :"
     echo "        scripts/backup-trickle.sh --from <시작> --to <끝>"
     echo "      최근 런이면 dataflow 가 알아서 보낸다. 막혀 있는지 확인할 것."
  else
     echo "   백업이 밀린 런이 없다."
  fi
} >> "$OUT"

cat "$OUT"

if [ "$MAIL" -eq 1 ]; then
   MSG="백업 안 된 런 ${OL}개"
   "$NOTIFY" --params "$PARAMS" backup_audit --msg "$MSG" --detail-file "$OUT" \
      >/dev/null 2>&1 && echo && echo "메일로 보냈다 : $MSG"
fi
rm -f "$OUT"
