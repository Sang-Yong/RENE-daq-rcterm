#!/usr/bin/env bash
# =====================================================================
#  swap-logdir.sh — postrun 로그 디렉터리를 새것으로 갈아끼운다
#
#  왜 필요한가
#    /scratch/LOG 의 디렉터리 인덱스가 손상돼 **특정 이름만** EIO 다. 그러면
#    껍데기가 로그를 만들지 못하고 **매크로가 아예 실행되지 않아** 산출물이
#    조용히 빈다 (CLAUDE.md §11.52 · §11.68 · §11.89 · §11.95 — 네 번 겪었다).
#
#    ★ 같은 이름이 '새로 만든 디렉터리'에서는 그냥 만들어진다 (2026-08-25 실측).
#      손상된 것은 파일이 아니라 **그 디렉터리 자신**이다 (항목 369,603개).
#      그래서 갈아끼우면 서버 fsck 없이도 재발이 멎는다.
#
#  ★ 런 경계에서 하는 것이 가장 안전하다
#    carry 는 직전 서브런의 merge 로그에서 읽는다. 런 도중에 갈면 그 로그가
#    옛 디렉터리에 있어 못 찾고, 0 으로 초기화하면 개수는 맞아도 내용이
#    조용히 부족해진다 (§11.68). 서브런 0 은 carry 가 (0,0,0) 이라 필요 없다.
#
#    로테이션 직후에도 postrun 은 **직전 런의 남은 서브런**을 마저 처리한다.
#    그래서 교체 뒤에는 postrun 을 반드시
#        --log-fallback <옛 디렉터리>
#    로 다시 띄운다. 그러면 옛 런의 carry 를 옛 자리에서 찾는다.
#
#  하는 일
#    1) 링크와 대상을 확인한다 (심볼릭 링크가 아니면 멈춘다)
#    2) 지금이 런 경계인지 본다 (heartbeat 의 subrun)
#    3) 새 디렉터리를 만들고 **그동안 EIO 였던 이름들로 실제 쓰기 시험**을 한다
#    4) 원자적으로 갈아끼운다 (임시 링크 -> mv -T = rename)
#    5) 되확인하고, postrun 을 어떻게 다시 띄울지 그대로 찍어 준다
#
#  ★ 옛 디렉터리는 지우지 않는다. 읽기는 되고, 옛 런 재처리의 carry 원천이다.
# =====================================================================
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)

PRODDIR=${SWAP_PRODDIR:-/home/frontend/DAQ/DAQ_cup/production}
NEWDIR=""
HB=${SWAP_HEARTBEAT:-/Data/LOG/rcterm.hb}
MAXSUB=30
DRY=0; VERIFY=0; FORCE=0

usage() {
cat <<EOF
사용
  scripts/swap-logdir.sh --dry-run        무엇을 할지만 보여 준다 (아무것도 안 바꾼다)
  scripts/swap-logdir.sh                  갈아끼운다
  scripts/swap-logdir.sh --verify         지금 상태만 확인한다

옵션
  --new DIR        새 로그 디렉터리 (기본 : /scratch/LOG.<올해-이달>)
  --prod-dir DIR   production 트리 (${PRODDIR}). 그 밑의 LOG 가 갈아끼울 링크다
  --heartbeat F    런 경계 판정에 쓴다 (${HB})
  --max-subrun N   이 값보다 서브런이 크면 런 도중으로 보고 멈춘다 (${MAXSUB})
  --force          위 게이트를 무시한다. carry 를 잃을 수 있다
  --dry-run / --verify / -h

종료코드
  0 성공 (또는 dry-run/verify 가 정상)   1 하지 않았다 (게이트에 걸렸다)   2 쓸 수 없는 상태
EOF
}

while [ $# -gt 0 ]; do
   case "$1" in
      --new)         NEWDIR=$2; shift 2 ;;
      --prod-dir)    PRODDIR=$2; shift 2 ;;
      --heartbeat)   HB=$2; shift 2 ;;
      --max-subrun)  MAXSUB=$2; shift 2 ;;
      --force)       FORCE=1; shift ;;
      --dry-run|-n)  DRY=1; shift ;;
      --verify)      VERIFY=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      *) echo "unknown option : $1" >&2; usage; exit 2 ;;
   esac
done

LINK=$PRODDIR/LOG
[ -n "$NEWDIR" ] || NEWDIR="/scratch/LOG.$(date +%Y-%m)"

C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'; C_C='\033[1;36m'; C_0='\033[0m'
say()  { printf '%b\n' "$*"; }
die()  { printf '%b\n' "${C_R}$*${C_0}" >&2; exit 2; }

#  그동안 EIO 였던 이름들 — 새 디렉터리가 쓸 만한지 이걸로 시험한다
PROBE_NAMES="
log_merge_FADC_SADC_v3_5v_run4305_subrun401.txt
log_merge_FADC_SADC_v3_5v_run4305_subrun573.txt
log_merge_FADC_SADC_v3_5v_run4304_subrun362.txt
log_production_v3_5v_run4304_subrun572.txt
"

probe_dir() {            # 디렉터리  ->  실패한 개수를 낸다
   local d=$1 n bad=0 err
   for n in $PROBE_NAMES; do
      [ -n "$n" ] || continue
      if [ -e "$d/$n" ]; then continue; fi                 # 있는 것은 건드리지 않는다 (§11.82)
      if err=$( { : > "$d/$n"; } 2>&1 ); then rm -f "$d/$n" 2>/dev/null
      else bad=$((bad+1)); say "      ${C_R}$n -> ${err##*: }${C_0}"; fi
   done
   return "$bad"
}

show_state() {
   say "${C_C}지금 상태${C_0}"
   if [ -L "$LINK" ]; then
      say "   링크      $LINK -> $(readlink "$LINK")"
   elif [ -d "$LINK" ]; then
      say "   ${C_Y}$LINK 는 심볼릭 링크가 아니라 진짜 디렉터리다${C_0}"
   else
      say "   ${C_R}$LINK 이 없다${C_0}"
   fi
   local cur; cur=$(readlink -f "$LINK" 2>/dev/null)
   [ -n "$cur" ] && say "   실제 경로 $cur   (항목 $(ls -U "$cur" 2>/dev/null | wc -l) 개)"
   say "   쓰기 시험 (그동안 EIO 였던 이름들)"
   if probe_dir "$cur"; then say "      ${C_G}4개 전부 만들어진다${C_0}"
   else say "      ${C_R}위 이름들이 막혀 있다 — 갈아끼울 때다${C_0}"; fi
}

[ "$VERIFY" -eq 1 ] && { show_state; exit 0; }

# ---------------------------------------------------------------------
[ -e "$LINK" ] || die "$LINK 이 없다"
[ -L "$LINK" ] || die "$LINK 이 심볼릭 링크가 아니다. 이 스크립트는 링크만 갈아끼운다"
OLDDIR=$(readlink -f "$LINK")
[ -d "$OLDDIR" ] || die "링크가 가리키는 곳이 디렉터리가 아니다 : $OLDDIR"
[ "$OLDDIR" = "$(readlink -f "$NEWDIR" 2>/dev/null)" ] && die "이미 그 디렉터리를 쓰고 있다 : $NEWDIR"

show_state
say ""

#  런 경계인가 --------------------------------------------------------
RUN=""; SUB=""
if [ -r "$HB" ]; then
   RUN=$(awk -F= '/^run=/{print $2+0; exit}'    "$HB" 2>/dev/null)
   SUB=$(awk -F= '/^subrun=/{print $2+0; exit}' "$HB" 2>/dev/null)
fi
if [ -n "$SUB" ]; then
   say "${C_C}런 경계 판정${C_0}"
   say "   수집 중 : run $RUN  서브런 $SUB"
   if [ "$SUB" -gt "$MAXSUB" ]; then
      if [ "$FORCE" -eq 1 ] || [ "$DRY" -eq 1 ]; then
         #  dry-run 은 아무것도 바꾸지 않으므로 게이트에서 멈추지 않는다.
         #  로테이션을 기다리는 동안 계획을 미리 보려면 이래야 쓸모가 있다
         say "   ${C_Y}서브런이 $SUB 이라 런 도중이다$([ "$DRY" -eq 1 ] && echo " (dry-run 이라 계속 보여 준다)" || echo ". --force 라 그대로 간다")${C_0}"
      else
         say "   ${C_R}서브런이 $SUB > $MAXSUB — 런 도중이다. 하지 않는다${C_0}"
         say "   로테이션 직후(서브런이 $MAXSUB 이하)에 다시 부르거나 --force 를 준다."
         say "   ${C_Y}지금 해도 잃지는 않는다${C_0} — postrun 을 --log-fallback '$OLDDIR' 로"
         say "   다시 띄우면 옛 carry 를 찾는다. 다만 경계에서 하는 편이 깔끔하다."
         exit 1
      fi
   else
      say "   ${C_G}런 경계다. 갈아끼우기 좋다${C_0}"
   fi
else
   say "${C_Y}heartbeat 를 읽지 못했다 ($HB). 런 경계인지 확인하지 못한다${C_0}"
fi
say ""

#  새 디렉터리 --------------------------------------------------------
say "${C_C}새 로그 디렉터리${C_0}"
say "   $NEWDIR"
if [ "$DRY" -eq 1 ]; then
   say "   ${C_Y}dry-run : 만들지 않는다${C_0}"
   say ""
   say "${C_C}할 일${C_0}"
   say "   1) mkdir -p $NEWDIR"
   say "   2) $LINK -> $NEWDIR  (임시 링크를 mv -T 로 끼운다. 원자적이다)"
   say "   3) postrun 을 다시 띄운다 —  --log-fallback $OLDDIR  를 붙여서"
   say "   ${C_G}옛 디렉터리 $OLDDIR 는 지우지 않는다${C_0}"
   exit 0
fi

mkdir -p "$NEWDIR" || die "새 디렉터리를 만들 수 없다 : $NEWDIR"
say "   만들었다. 쓰기 시험"
if probe_dir "$NEWDIR"; then
   say "      ${C_G}그동안 EIO 였던 이름 4개가 전부 만들어진다${C_0}"
else
   die "새 디렉터리에서도 막힌다. 갈아끼우지 않는다 — 원인이 디렉터리가 아닐 수 있다"
fi
say ""

#  원자적 교체 --------------------------------------------------------
TMPLINK=$(dirname "$LINK")/.LOG.swap.$$
ln -s "$NEWDIR" "$TMPLINK" || die "임시 링크를 만들 수 없다"
if mv -T "$TMPLINK" "$LINK"; then
   say "${C_G}갈아끼웠다${C_0}   $LINK -> $(readlink "$LINK")"
else
   rm -f "$TMPLINK"; die "교체 실패. 아무것도 바뀌지 않았다"
fi
say ""

#  되확인 -------------------------------------------------------------
say "${C_C}되확인${C_0}"
NOW=$(readlink -f "$LINK")
[ "$NOW" = "$(readlink -f "$NEWDIR")" ] || die "링크가 새 디렉터리를 가리키지 않는다 : $NOW"
say "   링크      $LINK -> $NOW"
if probe_dir "$NOW"; then say "   쓰기 시험 ${C_G}통과${C_0}"; else die "새 자리에서 쓰기가 막힌다"; fi
say ""

say "${C_C}이제 postrun 을 다시 띄운다${C_0}  (돌고 있는 것은 옛 코드·옛 경로를 붙들고 있다)"
PRUN=$(pgrep -af 'postrun\.sh' 2>/dev/null | grep -v swap-logdir | head -1)
if [ -n "$PRUN" ]; then
   PID=${PRUN%% *}; CMD=${PRUN#* }
   say "   지금 돌고 있는 것 : pid $PID"
   say "     $CMD"
   say "   ${C_Y}멈추고${C_0}  다음으로 다시 띄운다 :"
   say "     ${CMD} --log-fallback $OLDDIR"
else
   say "   ${C_Y}돌고 있는 postrun 이 없다${C_0}. 다음에 띄울 때 --log-fallback $OLDDIR 를 붙인다"
fi
say ""
say "${C_G}옛 디렉터리는 그대로 둔다${C_0}   $OLDDIR   (읽기는 된다. 옛 런 재처리의 carry 원천)"
exit 0
