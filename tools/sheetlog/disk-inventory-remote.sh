#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  disk-inventory-remote.sh - 저장소 서버에서 돈다. 마운트된 백업 하드를 훑어 런별 목록을 TSV 로 낸다.
#
#  사용 (DAQ PC 에서) :  ssh store bash -s -- /backup_hdd [/backup_hdd_2 ...] < tools/sheetlog/disk-inventory-remote.sh
#  보통은 scripts/backup-disk-inventory.sh 가 부른다.
#
#  ★ 읽기 전용. 하드도 서버도 바꾸지 않는다.
#
#  출력 (하드마다)
#     #disk	mount	device	uuid	model	serial	wwn	cap_bytes	used_bytes	fs_created	scanned_at
#     #cols	run	files	bytes	sub_lo	sub_hi	first_file	last_file	copied_from	copied_to	manifest_lines	n_fadc	n_sadc	n_prd	n_merged	n_png	n_other
#     000938	1	1102	...
#
#  copied_from / copied_to = 그 런 파일들의 ctime 최소/최대 (rsync -a 는 mtime 은 원본 것을 보존하지만
#  ctime 은 복사한 시각이다). 로그가 없는 옛 하드(2026-04)에서 백업 시각을 되찾는 유일한 단서다.
#  first/last_file 은 parts_index 와 같은 규칙(최상위 파일 이름순의 처음/끝). sub_lo/hi 는 최상위 FADC_ 파일의 서브런 번호 최소/최대.
# ---------------------------------------------------------------------
set -u
for M in "$@"; do
   mountpoint -q "$M" 2>/dev/null || { echo "#skip	$M	not-mounted"; continue; }
   DEV=$(findmnt -rno SOURCE "$M" 2>/dev/null); BASE=$(lsblk -no PKNAME "$DEV" 2>/dev/null); [ -z "$BASE" ] && BASE=$(basename "$DEV" | sed 's/[0-9]*$//')
   [ -e "$DEV" ] || { echo "#skip	$M	ghost-mount	$DEV"; continue; }
   UUID=$(lsblk -no UUID "$DEV" 2>/dev/null | head -1)
   PROP=$(udevadm info --query=property --name="/dev/$BASE" 2>/dev/null)
   MODEL=$(printf '%s\n' "$PROP" | sed -n 's/^ID_MODEL=//p'); SERIAL=$(printf '%s\n' "$PROP" | sed -n 's/^ID_SERIAL_SHORT=//p'); WWN=$(printf '%s\n' "$PROP" | sed -n 's/^ID_WWN=//p')
   read -r CAPB USEDB < <(df -B1 --output=size,used "$M" 2>/dev/null | tail -1)
   FSC=$(stat -c %w "$M/lost+found" 2>/dev/null | cut -c1-19); [ "$FSC" = "-" ] && FSC=""
   printf '#disk\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$M" "$DEV" "$UUID" "$MODEL" "$SERIAL" "$WWN" "${CAPB:-}" "${USEDB:-}" "$FSC" "$(date '+%F %T')"
   printf '#cols\trun\tfiles\tbytes\tsub_lo\tsub_hi\tfirst_file\tlast_file\tcopied_from\tcopied_to\tmanifest_lines\tn_fadc\tn_sadc\tn_prd\tn_merged\tn_png\tn_other\tlayout\n'
   ROOT="$M/RENE_data_backup"
   [ -d "$ROOT" ] || { echo "#note	$M	no RENE_data_backup"; continue; }
   #  * 런 폴더 없이 PRD/ · Merged/ 가 RENE_data_backup 바로 밑에 있는 하드 (2026-08-26, code7 시절의 002442). 파일 이름에서 런을 읽어
   #    런마다 한 줄로 낸다 (layout=loose). 경로가 'PRD/…' 꼴이라 시트에서는 런 폴더 안의 것과 같은 모양으로 읽힌다.
   LOOSE=$(cd "$ROOT" && ls -d */ 2>/dev/null | sed 's#/$##' | grep -vE '^[0-9]{6}(_[0-9]+)?$' | grep -E '^(PRD|Merged|PNG|FADC|SADC)' | tr '\n' ' ')
   if [ -n "$LOOSE" ]; then
      ( cd "$ROOT" && find $LOOSE -type f -printf '%s\t%C@\t%p\n' 2>/dev/null ) | awk -F'\t' '
         { p=$3; run="unknown"; if(match(p,/_[0-9][0-9][0-9][0-9][0-9][0-9][._]/)) run=substr(p,RSTART+1,6)
           n[run]++; b[run]+=$1; c=$2+0; if(!(run in cmin)||c<cmin[run])cmin[run]=c; if(c>cmax[run])cmax[run]=c
           if(p ~ /^PRD\//){np[run]++} else if(p ~ /^Merged\//){nm[run]++} else if(p ~ /^PNG\//){ng[run]++} else {no[run]++}
           if(!(run in first)||p<first[run])first[run]=p; if(p>last[run])last[run]=p }
         END { for(run in n) printf "%s\t%d\t%d\t\t\t%s\t%s\t%s\t%s\t0\t0\t0\t%d\t%d\t%d\t%d\tloose\n", run, n[run], b[run], first[run], last[run],
                  strftime("%Y-%m-%d %H:%M:%S",cmin[run]), strftime("%Y-%m-%d %H:%M:%S",cmax[run]), np[run]+0, nm[run]+0, ng[run]+0, no[run]+0 }'
   fi
   for R in "$ROOT"/*/; do
      [ -d "$R" ] || continue
      run=$(basename "$R")
      printf '%s' "$run" | grep -qE '^[0-9]{6}(_[0-9]+)?$' || continue
      ml=0; [ -f "$R/.part_manifest.txt" ] && ml=$(wc -l < "$R/.part_manifest.txt")
      #  한 번의 find 로 전부 : 크기 · ctime · 상대경로
      find "$R" -type f ! -name '.part_manifest.txt' -printf '%s\t%C@\t%P\n' 2>/dev/null | awk -F'\t' -v run="$run" -v ml="$ml" '
         { n++; b+=$1; c=$2+0; if(cmin==""||c<cmin)cmin=c; if(c>cmax)cmax=c; p=$3
           if(index(p,"/")==0){ top[p]=1
              if(p ~ /^FADC_/){ nf++; if(match(p,/\.root\.[0-9]{5}$/)){ s=substr(p,RSTART+6,5)+0; if(slo==""||s<slo)slo=s; if(s>shi)shi=s } }
              else if(p ~ /^SADC_/){ ns++ } else { no++ } }
           else if(p ~ /^PRD\//){ np++ } else if(p ~ /^Merged\//){ nm++ } else if(p ~ /^PNG\//){ ng++ } else { no++ } }
         END {
           first=""; last=""; for(k in top){ if(first==""||k<first)first=k; if(k>last)last=k }
           f1=(cmin!="")?strftime("%Y-%m-%d %H:%M:%S",cmin):""; f2=(cmax!="")?strftime("%Y-%m-%d %H:%M:%S",cmax):""
           printf "%s\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\trun-dir\n", run, n, b, (slo==""?"":sprintf("%05d",slo)), (shi==""?"":sprintf("%05d",shi)), first, last, f1, f2, ml, nf, ns, np, nm, ng, no }'
   done
done
