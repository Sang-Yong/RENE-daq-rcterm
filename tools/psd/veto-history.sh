#!/usr/bin/env bash
# veto-history.sh - 런별 SADC/FADC 문턱값(PRD 에 기록된 S_THR/F_THR)과 VETO 패널별 반응,
#   veto 계수율을 훑어 표와 그림을 만든다. 읽기 전용. 런마다 서브런 10·100·600·1200 표본.
#   사용 : veto-history.sh <run_from> <run_to>      -> $PSD_OUT/thr_history.tsv · veto_history.tsv · veto_*.png
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=${PSD_OUT:-/scratch/RunSummary/psd}
[ $# -ge 2 ] || { sed -n '2,5p' "$0"; exit 1; }
command -v root >/dev/null 2>&1 || . /usr/local/bin/thisroot.sh
mkdir -p "$OUT"
H=$OUT/thr_history.tsv
{ printf '#run\tsub\tlive_s\tnev\trate_fadc_hz\trate_veto_hz\tF_THR0\tF_THR1'; for j in $(seq 0 29); do printf '\tS_THR%d' $j; done
  for j in $(seq 0 29); do printf '\tch%d_pct' $j; done; for q in $(seq 0 14); do printf '\tpanel%d_pct' $q; done; printf '\n'; } > "$H"
for r in $(seq "$1" "$2"); do
   rr=$(printf %06d "$r"); ok=0
   for root in /Data_ssd/RAW /data/RAW /scratch/RAW; do [ -d "$root/$rr/PRD" ] && ok=1 && break; done
   [ $ok = 1 ] || continue
   nice -n 15 root -l -b -q "$DIR/VetoHistoryScan.C+($r, \"10,100,600,1200\", \"$H\")" > /dev/null 2>&1
done
python3 - "$H" "$OUT/veto_history.tsv" <<'PY'
import sys,collections,os,datetime,statistics as st
H,V=sys.argv[1],sys.argv[2]
rows=[[float(x) for x in l.rstrip('\n').split('\t')] for l in open(H) if not l.startswith('#')]
by=collections.defaultdict(list)
for r in rows: by[int(r[0])].append(r)
ep={}
rs='/scratch/RunSummary/run_summary.tsv'
if os.path.exists(rs):
    for l in open(rs):
        if l.startswith('#'): continue
        p=l.split('\t'); ep[int(p[0])]=float(p[3])
for run in by:
    if run not in ep:
        for d in ('/scratch/CONFIG','/Data_ssd/CONFIG','/data/CONFIG'):
            f=f'{d}/{run:06d}.config'
            if os.path.exists(f): ep[run]=os.path.getmtime(f); break
with open(V,'w') as out:
    out.write('#run\tepoch\tdate\tn_sub\trate_fadc_hz\trate_veto_hz\tsthr_ch2\tsthr_ch3\tsthr_ch9\tch2_pct\tch3_pct\t'+'\t'.join(f'panel{q}_pct' for q in range(15))+'\n')
    for run in sorted(by):
        rs_=by[run]; m=lambda i: st.mean(x[i] for x in rs_); e=ep.get(run,0)
        d=datetime.datetime.fromtimestamp(e).strftime('%m-%d %H:%M') if e else '-'
        out.write(f"{run}\t{e:.0f}\t{d}\t{len(rs_)}\t{m(4):.1f}\t{m(5):.1f}\t{rs_[0][10]:.0f}\t{rs_[0][11]:.0f}\t{rs_[0][17]:.0f}\t{m(40):.2f}\t{m(41):.2f}\t"+'\t'.join(f'{m(68+q):.3f}' for q in range(15))+'\n')
PY
root -l -b -q "$DIR/VetoHistoryPlot.C+(\"$OUT/veto_history.tsv\", \"$OUT/\")" 2>&1 | grep SAVED
