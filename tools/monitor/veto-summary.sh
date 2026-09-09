#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  veto-summary.sh - 런마다 VETO 패널 반응·veto 계수율을 표에 싣는다 (증분).
#
#  사용 :
#     veto-summary.sh [--list 4340,4341] [--missing] [--force] [--dry-run]
#
#     --list     이 런들만. 없으면 --missing 과 같다
#     --missing  run_summary.tsv 에 있는데 veto_summary.tsv 에 없는 런 전부
#     --force    이미 있어도 다시 잰다
#
#  무엇을 하나 (2026-09-09 §11.173 의 개선 3)
#     tools/psd/veto-history.sh 는 손으로 돌리는 도구였고 부를 때마다 범위 전체를
#     다시 훑었다. 여기서는 런마다 서브런 표본(10·100·600·1200)의 트리거 비트를
#     한 번만 읽어 $OUT/veto/thr_history.tsv 에 **누적**하고, 그것을 런당 1행으로
#     모아 $OUT/veto_summary.tsv 를 다시 만든 뒤 추이 그림 veto_*.png 를 그린다.
#     표(gen-summary-html.sh)는 veto_summary.tsv 의 패널 % 로 '살아 있는 패널 수' 를,
#     run_summary.tsv 의 종류별 이벤트 수로 FADC/VETO 계수율을 낸다.
#
#  스키마 (veto_summary.tsv = tools/psd/veto_history.tsv 와 같다. VetoHistoryPlot.C 가 그대로 읽는다)
#     run epoch date n_sub rate_fadc_hz rate_veto_hz sthr_ch2 sthr_ch3 sthr_ch9 ch2_pct ch3_pct panel0_pct..panel14_pct
#
#  환경
#     RUNSUM_OUT      산출물 루트. 기본 /scratch/RunSummary
#     VETO_SCAN_CMD   시험용. 런 번호·서브런 목록·출력 파일을 받아 thr_history 줄을 덧붙이는 명령
#     VETO_PLOT_CMD   시험용. veto_summary.tsv 와 출력 디렉터리를 받는다
#
#  ★ 실패로 죽지 않는다. PRD 가 없는 런은 건너뛰고, ROOT 가 없으면 그림만 빠진다.
#    (websummary.sh 는 이 단계를 WARN 으로만 다룬다)
# ---------------------------------------------------------------------
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$DIR/../.." && pwd)
OUT=${RUNSUM_OUT:-/scratch/RunSummary}
RS=$OUT/run_summary.tsv
H=$OUT/veto/thr_history.tsv
V=$OUT/veto_summary.tsv
SUBS=${VETO_SUBS:-10,100,600,1200}
LIST=""; MISSING=0; FORCE=0; DRY=0
while [ $# -gt 0 ]; do
   case "$1" in
      --list)    LIST=$2; shift 2 ;;
      --missing) MISSING=1; shift ;;
      --force)   FORCE=1; shift ;;
      --dry-run) DRY=1; shift ;;
      -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) echo "모르는 옵션 : $1" >&2; exit 2 ;;
   esac
done
[ -n "$LIST" ] || MISSING=1

have_root() { command -v root >/dev/null 2>&1 && return 0; [ -r /usr/local/bin/thisroot.sh ] && . /usr/local/bin/thisroot.sh; command -v root >/dev/null 2>&1; }

scan_run() {         # $1=run  -> thr_history 에 줄을 덧붙인다
   local r=$1
   if [ -n "${VETO_SCAN_CMD:-}" ]; then "$VETO_SCAN_CMD" "$r" "$SUBS" "$H"; return $?; fi
   have_root || { echo "ROOT 가 없어 run $r 을 잴 수 없다"; return 1; }
   nice -n 15 root -l -b -q "$REPO/tools/psd/VetoHistoryScan.C+($r, \"$SUBS\", \"$H\")" >/dev/null 2>&1
}
plot() {
   if [ -n "${VETO_PLOT_CMD:-}" ]; then "$VETO_PLOT_CMD" "$V" "$OUT/"; return $?; fi
   have_root || { echo "[WARN] ROOT 가 없어 그림을 못 그린다"; return 0; }
   nice -n 15 root -l -b -q "$REPO/tools/psd/VetoHistoryPlot.C+(\"$V\", \"$OUT/\")" 2>&1 | grep SAVED
}

mkdir -p "$OUT/veto" 2>/dev/null
if [ ! -s "$H" ]; then
   { printf '#run\tsub\tlive_s\tnev\trate_fadc_hz\trate_veto_hz\tF_THR0\tF_THR1'
     for j in $(seq 0 29); do printf '\tS_THR%d' $j; done
     for j in $(seq 0 29); do printf '\tch%d_pct' $j; done
     for q in $(seq 0 14); do printf '\tpanel%d_pct' $q; done; printf '\n'; } > "$H"
fi

# ---- 어느 런을 잴 것인가 ---------------------------------------------
runs=""
if [ "$MISSING" -eq 1 ]; then
   [ -r "$RS" ] || { echo "run_summary.tsv 가 없다 ($RS). 잴 런을 고를 수 없다"; exit 0; }
   runs=$(grep -v '^#' "$RS" | cut -f1 | sort -n -u)
fi
[ -n "$LIST" ] && runs="$runs $(printf '%s' "$LIST" | tr ',' ' ')"
done_runs=$(grep -v '^#' "$H" 2>/dev/null | cut -f1 | sort -n -u)
todo=""
for r in $runs; do
   case "$r" in ''|*[!0-9]*) continue ;; esac
   if [ "$FORCE" -eq 0 ] && printf '%s\n' "$done_runs" | grep -qx "$r"; then continue; fi
   todo="$todo $r"
done
todo=$(printf '%s\n' $todo | sort -n -u | tr '\n' ' ')
if [ -z "${todo// /}" ]; then
   echo "[veto] 새로 잴 런이 없다 (thr_history $(printf '%s\n' "$done_runs" | grep -c .) 런)"
   [ "$DRY" -eq 1 ] && exit 0
else
   echo "[veto] 잴 런 : $todo"
   [ "$DRY" -eq 1 ] && { echo "[DRY] 서브런 $SUBS -> $H ; 표 $V ; 그림 $OUT/veto_*.png"; exit 0; }
   for r in $todo; do
      if [ "$FORCE" -eq 1 ]; then grep -v "^$r	" "$H" > "$H.tmp" 2>/dev/null && mv -f "$H.tmp" "$H"; fi
      if scan_run "$r"; then echo "  run $r : $(grep -c "^$r	" "$H") 서브런"; else echo "  run $r : ★ 실패 (건너뜀)"; fi
   done
fi

# ---- 런당 1행으로 모은다 (veto-history.sh 와 같은 계산) -----------------
python3 - "$H" "$V" "$RS" <<'PY'
import sys,collections,os,datetime,statistics as st
H,V,RS=sys.argv[1:4]
rows=[[float(x) for x in l.rstrip('\n').split('\t')] for l in open(H) if not l.startswith('#') and l.strip()]
by=collections.defaultdict(list)
for r in rows: by[int(r[0])].append(r)
ep={}
if os.path.exists(RS):
    for l in open(RS):
        if l.startswith('#'): continue
        p=l.split('\t')
        try: ep[int(p[0])]=float(p[3])
        except: pass
for run in by:
    if run not in ep:
        for d in ('/scratch/CONFIG','/Data_ssd/CONFIG','/data/CONFIG'):
            f=f'{d}/{run:06d}.config'
            if os.path.exists(f): ep[run]=os.path.getmtime(f); break
tmp=V+'.tmp'
with open(tmp,'w') as out:
    out.write('#run\tepoch\tdate\tn_sub\trate_fadc_hz\trate_veto_hz\tsthr_ch2\tsthr_ch3\tsthr_ch9\tch2_pct\tch3_pct\t'+'\t'.join(f'panel{q}_pct' for q in range(15))+'\n')
    for run in sorted(by):
        rs_=by[run]; m=lambda i: st.mean(x[i] for x in rs_); e=ep.get(run,0)
        d=datetime.datetime.fromtimestamp(e).strftime('%m-%d %H:%M') if e else '-'
        out.write(f"{run}\t{e:.0f}\t{d}\t{len(rs_)}\t{m(4):.1f}\t{m(5):.1f}\t{rs_[0][10]:.0f}\t{rs_[0][11]:.0f}\t{rs_[0][17]:.0f}\t{m(40):.2f}\t{m(41):.2f}\t"+'\t'.join(f'{m(68+q):.3f}' for q in range(15))+'\n')
os.replace(tmp,V)
print(f"[SAVED] {V} ({len(by)} 런)")
PY
plot
exit 0
