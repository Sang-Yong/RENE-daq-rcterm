#!/usr/bin/env bash
# =====================================================================
#  logrotate-daq.sh — 후처리 로그를 종류별 폴더로 나누고, 한 폴더가 커지지 않게
#                     지킨다.
#
#  왜 필요한가
#    로그를 한 폴더에 계속 쌓으면 그 **디렉터리 자신**이 상한다. 2026-08 에
#    /scratch/LOG 가 369,657 개에서 그렇게 됐다 — 특정 이름만 EIO 가 되어
#    껍데기가 로그를 못 만들고, 그러면 매크로가 아예 실행되지 않아 산출물이
#    조용히 빈다 (CLAUDE.md §11.52 · §11.68 · §11.89 · §11.95 · §11.101).
#
#    그래서 두 가지를 한다 — 종류별로 나누고, 한 폴더가 상한에 이르면
#    **폴더째 이름을 바꿔 빼내고** 새 빈 폴더를 놓는다.
#
#  구조
#    <루트>/Merge_log/        log_merge_FADC_SADC_* · log_merge_prod_*
#    <루트>/PRD_log/          log_production_*
#    <루트>/RAW_log/          TCB_* · FADCDAQ_* · SADCDAQ_* · MERGER_*
#    <루트>/Merge_log.old001/ 가득 차서 빠진 것. 번호는 오래된 것이 작다
#
#  ★ 롤오버는 파일을 옮기지 않는다. 폴더 이름만 바꾸고(rename) 새것을 놓는다.
#    자료가 움직이지 않으므로 §8 의 rsync 규칙이 적용되지 않는 예외다.
#
#  ★ 상한보다 조금 일찍 자른다. 검사와 다음 검사 사이에 몇 개가 더 쌓이므로
#    정확히 상한에서 자르면 이미 늦다. 기본은 10000 - 100 = 9900 에서 자른다.
# =====================================================================
set -u

ROOT=${DAQLOG_ROOT:-}
PRODDIR=${DAQLOG_PRODDIR:-/home/frontend/DAQ/DAQ_cup/production}
HB=${DAQLOG_HEARTBEAT:-/Data/LOG/rcterm.hb}
RAWLOGSRC=${DAQLOG_RAWSRC:-/Data_ssd/LOG}
MAXFILES=10000
MARGIN=100
DRY=0; QUIET=0
DO_STATUS=0; DO_ROTATE=0; DO_COLLECT=0; IMPORT_FROM=""

KINDS="Merge_log PRD_log RAW_log"

usage() {
cat <<EOF
사용
  scripts/logrotate-daq.sh --status              어느 폴더에 몇 개인지 본다
  scripts/logrotate-daq.sh --rotate --dry-run    무엇을 빼낼지만 본다
  scripts/logrotate-daq.sh --rotate              상한에 이른 폴더를 빼낸다
  scripts/logrotate-daq.sh --collect-raw         끝난 런의 DAQ 로그를 RAW_log 로
  scripts/logrotate-daq.sh --import-old DIR      옛 평면 디렉터리를 종류별로 나눈다

옵션
  --root DIR       로그 루트 (기본 : <prod-dir>/LOG 를 따라간다)
  --prod-dir DIR   production 트리 (${PRODDIR})
  --max-files N    한 폴더의 상한 (${MAXFILES})
  --margin N       상한보다 얼마나 일찍 자를지 (${MARGIN})
  --raw-src DIR    DAQ 로그가 쌓이는 곳 (${RAWLOGSRC})
  --heartbeat F    수집 중인 런을 알아내는 데 쓴다 (${HB})
  --dry-run / -q / -h

종료코드
  0 정상 (또는 할 일이 없었다)   1 일부를 하지 못했다   2 쓸 수 없는 상태
EOF
}

while [ $# -gt 0 ]; do
   case "$1" in
      --status)      DO_STATUS=1; shift ;;
      --rotate)      DO_ROTATE=1; shift ;;
      --collect-raw) DO_COLLECT=1; shift ;;
      --import-old)  IMPORT_FROM=$2; shift 2 ;;
      --root)        ROOT=$2; shift 2 ;;
      --prod-dir)    PRODDIR=$2; shift 2 ;;
      --max-files)   MAXFILES=$2; shift 2 ;;
      --margin)      MARGIN=$2; shift 2 ;;
      --raw-src)     RAWLOGSRC=$2; shift 2 ;;
      --heartbeat)   HB=$2; shift 2 ;;
      --dry-run|-n)  DRY=1; shift ;;
      -q|--quiet)    QUIET=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      *) echo "unknown option : $1" >&2; usage; exit 2 ;;
   esac
done

[ -n "$ROOT" ] || ROOT=$(readlink -f "$PRODDIR/LOG" 2>/dev/null)
[ -n "$ROOT" ] || { echo "로그 루트를 정할 수 없다" >&2; exit 2; }

TRIGGER=$(( MAXFILES - MARGIN ))
if [ "$TRIGGER" -le 0 ]; then
   #  상한을 작게 주면 기본 여유(100)가 그보다 커진다. 멈추는 대신 여유를
   #  상한의 10% 로 낮춘다 — 상한 자체는 준 값을 그대로 지킨다
   MARGIN=$(( MAXFILES / 10 )); TRIGGER=$(( MAXFILES - MARGIN ))
   [ "$TRIGGER" -gt 0 ] || { MARGIN=0; TRIGGER=$MAXFILES; }
   echo "여유를 $MARGIN 으로 낮췄다 (상한 $MAXFILES 보다 컸다)" >&2
fi

C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'; C_C='\033[1;36m'; C_0='\033[0m'
say()  { [ "$QUIET" -eq 1 ] || printf '%b\n' "$*"; }
#  실제로 무엇이 바뀌었을 때 쓴다. -q 로 불려도 알린다 — postrun 이 주기마다
#  부르므로 평소에는 조용해야 하지만, 폴더를 빼내거나 로그를 옮긴 것은
#  나중에 무슨 일이 있었는지 아는 데 필요하다
sayc() { printf '%b\n' "$*"; }
warn() { printf '%b\n' "$*" >&2; }

#  파일 이름 -> 어느 폴더로 가는가
classify() {
   case "$1" in
      log_merge_*)               echo Merge_log ;;
      log_production_*)          echo PRD_log ;;
      TCB_*|*DAQ_*|MERGER_*)     echo RAW_log ;;
      *)                         echo "" ;;
   esac
}

count_dir() { ls -U "$1" 2>/dev/null | wc -l; }        # readdir 만 (§11.5)

#  다음 old 번호 — 기존 최대 + 1
next_old() {             # 종류
   local k=$1 n max=0 b
   for d in "$ROOT/$k".old*; do
      [ -d "$d" ] || continue
      b=${d##*.old}
      case "$b" in ''|*[!0-9]*) continue ;; esac
      n=$((10#$b)); [ "$n" -gt "$max" ] && max=$n
   done
   printf '%03d' $(( max + 1 ))
}

ensure_dirs() {
   local k
   for k in $KINDS; do
      [ -d "$ROOT/$k" ] && continue
      [ "$DRY" -eq 1 ] && { say "   (dry-run) mkdir $ROOT/$k"; continue; }
      mkdir -p "$ROOT/$k" || return 1
   done
   return 0
}

# ---------------------------------------------------------------------
#  상태
# ---------------------------------------------------------------------
do_status() {
   say "${C_C}로그 루트${C_0}  $ROOT"
   say "   상한 $MAXFILES / 여유 $MARGIN  ->  $TRIGGER 개에서 빼낸다"
   local k n olds
   for k in $KINDS; do
      if [ -d "$ROOT/$k" ]; then
         n=$(count_dir "$ROOT/$k")
         if [ "$n" -ge "$TRIGGER" ]; then say "   ${C_Y}$k${C_0}  $n 개  ${C_Y}<- 빼낼 때다${C_0}"
         else say "   ${C_G}$k${C_0}  $n 개"; fi
      else
         say "   ${C_Y}$k${C_0}  없다"
      fi
      olds=$(ls -dU "$ROOT/$k".old* 2>/dev/null | wc -l)
      [ "$olds" -gt 0 ] && say "      빼낸 폴더 $olds 개  ($(ls -dU "$ROOT/$k".old* 2>/dev/null | sed "s|.*/||" | sort | tr '\n' ' '))"
   done
   #  분류되지 않은 채 루트에 있는 것 (껍데기가 막 쓴 production 로그가 여기 잠깐 있다)
   local loose; loose=$(ls -U "$ROOT" 2>/dev/null | grep -c '^log_\|^TCB_\|DAQ_\|^MERGER_')
   [ "$loose" -gt 0 ] && say "   ${C_Y}루트에 아직 분류되지 않은 파일 $loose 개${C_0} (--rotate 가 쓸어담는다)"
   return 0
}

# ---------------------------------------------------------------------
#  루트에 흩어진 것을 종류별 폴더로 쓸어담는다
#    껍데기(production_from_merged_v3_5v.sh)가 ../LOG 평면에 쓰기 때문에 필요하다.
#    원본 스크립트는 고치지 않는 것이 이 프로젝트의 원칙이다 (§5.8)
#    ★ 같은 파일시스템 안 rename 이라 자료가 움직이지 않는다
# ---------------------------------------------------------------------
sweep_root() {
   local moved=0 failed=0 f k
   local list; list=$(ls -U "$ROOT" 2>/dev/null | grep '^log_\|^TCB_\|DAQ_\|^MERGER_')
   [ -n "$list" ] || return 0
   while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$ROOT/$f" ] || continue
      k=$(classify "$f"); [ -n "$k" ] || continue
      if [ "$DRY" -eq 1 ]; then moved=$((moved+1)); continue; fi
      mkdir -p "$ROOT/$k" 2>/dev/null
      if mv -f "$ROOT/$f" "$ROOT/$k/$f" 2>/dev/null; then moved=$((moved+1)); else failed=$((failed+1)); fi
   done <<EOF
$list
EOF
   [ "$moved" -gt 0 ] && say "   루트에서 쓸어담았다 : $moved 개$([ "$failed" -gt 0 ] && echo " / 실패 $failed")"
   [ "$failed" -gt 0 ] && return 1
   return 0
}

# ---------------------------------------------------------------------
#  상한에 이른 폴더를 빼낸다
#    ★ 폴더 이름만 바꾸고 새 빈 폴더를 놓는다. 파일은 하나도 움직이지 않는다
# ---------------------------------------------------------------------
do_rotate() {
   ensure_dirs || { warn "폴더를 만들 수 없다"; return 1; }
   sweep_root || true
   local k n num dst rc=0
   for k in $KINDS; do
      [ -d "$ROOT/$k" ] || continue
      n=$(count_dir "$ROOT/$k")
      [ "$n" -ge "$TRIGGER" ] || continue
      num=$(next_old "$k"); dst="$ROOT/$k.old$num"
      if [ "$DRY" -eq 1 ]; then
         say "   ${C_Y}(dry-run)${C_0} $k ($n 개) -> $k.old$num  그리고 빈 $k 를 새로"
         continue
      fi
      if mv -T "$ROOT/$k" "$dst" 2>/dev/null; then
         mkdir -p "$ROOT/$k" || { warn "새 $k 를 만들지 못했다"; rc=1; }
         sayc "   ${C_G}빼냈다${C_0}  $k ($n 개) -> $k.old$num"
      else
         warn "$k 를 빼내지 못했다"; rc=1
      fi
   done
   return $rc
}

# ---------------------------------------------------------------------
#  끝난 런의 DAQ 로그를 RAW_log 로
#    ★ 수집 중인 런은 절대 건드리지 않는다. DAQ 가 그 파일에 쓰고 있다
#    ★ 파일시스템을 넘으므로 §8 대로 rsync -> 체크섬 대조 -> 삭제 순서다
# ---------------------------------------------------------------------
do_collect_raw() {
   [ -d "$RAWLOGSRC" ] || { say "   $RAWLOGSRC 이 없다. 건너뛴다"; return 0; }
   local cur=0
   [ -r "$HB" ] && cur=$(awk -F= '/^run=/{print $2+0; exit}' "$HB" 2>/dev/null)
   [ -n "$cur" ] || cur=0

   #  이름에서 런 번호를 뽑아, 수집 중인 런보다 작은 것만 고른다
   local f rn picked=0 list=""
   while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in TCB_*|*DAQ_*|MERGER_*) ;; *) continue ;; esac
      rn=$(printf '%s' "$f" | sed -n 's/.*_0*\([0-9][0-9]*\)\.log$/\1/p')
      [ -n "$rn" ] || continue
      [ "$cur" -gt 0 ] && [ "$rn" -ge "$cur" ] && continue      # 수집 중이거나 그 뒤
      list="$list$f
"; picked=$((picked+1))
   done <<EOF
$(ls -U "$RAWLOGSRC" 2>/dev/null)
EOF

   [ "$picked" -gt 0 ] || { say "   옮길 DAQ 로그가 없다 (수집 중인 run $cur 은 건드리지 않는다)"; return 0; }
   say "   끝난 런의 DAQ 로그 $picked 개 (수집 중인 run $cur 은 뺐다)"
   if [ "$DRY" -eq 1 ]; then
      say "   ${C_Y}(dry-run)${C_0} rsync -> 체크섬 대조 -> 원본 삭제"
      printf '%s' "$list" | head -5 | sed 's/^/      /'
      return 0
   fi

   mkdir -p "$ROOT/RAW_log" || return 1
   local tmp; tmp=$(mktemp); printf '%s' "$list" > "$tmp"
   #  보낸다
   if ! rsync -a --files-from="$tmp" "$RAWLOGSRC/" "$ROOT/RAW_log/" 2>/dev/null; then
      warn "   rsync 실패"; rm -f "$tmp"; return 1
   fi
   #  대조한다 — 다른 것이 하나라도 있으면 지우지 않는다 (§8)
   local diff
   diff=$(rsync -c -n -i --files-from="$tmp" "$RAWLOGSRC/" "$ROOT/RAW_log/" 2>/dev/null | grep -c '^[<>*]')
   if [ "$diff" -ne 0 ]; then
      warn "   체크섬 대조에서 $diff 건이 다르다. 원본을 지우지 않는다"; rm -f "$tmp"; return 1
   fi
   #  통과한 것만 지운다
   local del=0
   while IFS= read -r f; do
      [ -n "$f" ] || continue
      rm -f "$RAWLOGSRC/$f" && del=$((del+1))
   done < "$tmp"
   rm -f "$tmp"
   sayc "   ${C_G}DAQ 로그 $del 개를 RAW_log 로 옮겼다${C_0} (체크섬 대조 통과 후 원본 삭제)"
   return 0
}

# ---------------------------------------------------------------------
#  옛 평면 디렉터리를 종류별로 나눠 old 폴더에 채운다
#    한 폴더에 상한만큼 담고 다음 번호로 넘어간다
#    ★ 손상된 디렉터리라 일부가 EIO 로 안 옮겨질 수 있다. 건너뛰고 보고한다
# ---------------------------------------------------------------------
do_import_old() {
   local src=$1
   [ -d "$src" ] || { warn "$src 이 없다"; return 2; }
   [ "$(readlink -f "$src")" = "$(readlink -f "$ROOT")" ] && { warn "루트 자신은 가져올 수 없다"; return 2; }

   say "${C_C}옛 로그 가져오기${C_0}  $src  ->  $ROOT"
   local total; total=$(count_dir "$src")
   say "   대상 $total 개. 종류별로 나눠 한 폴더에 $MAXFILES 개씩 담는다"

   local tmp; tmp=$(mktemp -d)
   ls -U "$src" 2>/dev/null > "$tmp/all"

   #  ★ 한 줄씩 셸 함수로 분류하면 36만 개에서 몇 분이 걸린다. 한 번에 가른다
   grep    '^log_merge_'         "$tmp/all" > "$tmp/Merge_log" 2>/dev/null || true
   grep    '^log_production_'    "$tmp/all" > "$tmp/PRD_log"   2>/dev/null || true
   grep -E '^TCB_|DAQ_|^MERGER_' "$tmp/all" > "$tmp/RAW_log"   2>/dev/null || true
   cat "$tmp/Merge_log" "$tmp/PRD_log" "$tmp/RAW_log" 2>/dev/null | sort > "$tmp/known"
   sort "$tmp/all" > "$tmp/all.sorted"
   comm -23 "$tmp/all.sorted" "$tmp/known" > "$tmp/unknown"

   local k
   for k in $KINDS; do
      say "   $k : $(wc -l < "$tmp/$k") 개"
   done
   say "   분류 불가 : $(wc -l < "$tmp/unknown") 개 (그대로 둔다)"

   if [ "$DRY" -eq 1 ]; then
      for k in $KINDS; do
         local c; c=$(wc -l < "$tmp/$k")
         [ "$c" -gt 0 ] && say "   ${C_Y}(dry-run)${C_0} $k -> old 폴더 $(( (c + MAXFILES - 1) / MAXFILES )) 개"
      done
      rm -rf "$tmp"; return 0
   fi

   #  ★ mv 를 파일마다 부르지 않는다. 상한 개수로 잘라 청크마다 한 번씩 부른다.
   #    같은 파일시스템 안 rename 이라 자료는 움직이지 않는다 (§8 의 예외)
   local moved=0 failed=0
   for k in $KINDS; do
      local c; c=$(wc -l < "$tmp/$k")
      [ "$c" -gt 0 ] || continue
      rm -f "$tmp/chunk.$k."* 2>/dev/null
      split -l "$MAXFILES" -d -a 4 "$tmp/$k" "$tmp/chunk.$k." 2>/dev/null
      local ch num dst before after
      for ch in "$tmp/chunk.$k."*; do
         [ -f "$ch" ] || continue
         num=$(next_old "$k"); dst="$ROOT/$k.old$num"
         mkdir -p "$dst" || { failed=$((failed + $(wc -l < "$ch"))); continue; }
         before=$(count_dir "$dst")
         sed "s|^|$src/|" "$ch" | xargs -d '\n' -r mv -t "$dst" -- 2>/dev/null
         after=$(count_dir "$dst")
         moved=$(( moved + after - before ))
         failed=$(( failed + $(wc -l < "$ch") - (after - before) ))
         say "      $k.old$num : $(( after - before )) 개"
      done
   done
   rm -rf "$tmp"
   say "   ${C_G}옮긴 것 $moved 개${C_0}$([ "$failed" -gt 0 ] && echo " / ${C_R}옮기지 못한 것 $failed 개 (그대로 남아 있다)${C_0}")"
   [ "$failed" -gt 0 ] && return 1
   return 0
}

# ---------------------------------------------------------------------
RC=0
[ "$DO_STATUS" -eq 1 ] && { do_status || RC=1; }
if [ "$DO_ROTATE" -eq 1 ]; then
   say "${C_C}롤오버 검사${C_0}  $ROOT  (상한 $MAXFILES, $TRIGGER 개에서 빼낸다)"
   do_rotate || RC=1
fi
[ "$DO_COLLECT" -eq 1 ] && { say "${C_C}끝난 런의 DAQ 로그${C_0}"; do_collect_raw || RC=1; }
[ -n "$IMPORT_FROM" ] && { do_import_old "$IMPORT_FROM" || RC=$?; }

if [ "$DO_STATUS$DO_ROTATE$DO_COLLECT" = "000" ] && [ -z "$IMPORT_FROM" ]; then
   do_status
fi
exit $RC
