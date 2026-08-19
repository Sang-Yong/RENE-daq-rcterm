#!/bin/bash
# 로컬에 없는 런을 경희대 서버에서 실측한다. ssh 는 한 번만 연다.
#   사용법 : khu_scan.sh <런번호...>       또는  stdin 으로 런 번호 목록
# 출력    : run<TAB>khu<TAB>prd_count<TAB>raw_bytes<TAB>prd_bytes
set -u
R="${*:-$(cat)}"
[ -z "$R" ] && exit 0
ssh -o BatchMode=yes khu "bash -s" <<REMOTE
B=/store/cpnr-data/RENE
for r in $R; do
  rr=\$(printf "%06d" "\$r")
  raw=\$(find -L "\$B/RAW/\$rr" -maxdepth 1 -type f \\( -name "FADC_\${rr}.root*" -o -name "SADC_\${rr}.root*" \\) -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}')
  # 원격 PRD 는 평면(PRD/<run>/)과 한 겹 더 들어간 것(PRD/<run>/PRD/)이 섞여 있다 (CLAUDE.md 11.14)
  set -- \$(find -L "\$B/PRD/\$rr" -maxdepth 2 -type f -name "*\${rr}*.root" -printf '%s\n' 2>/dev/null | awk '{n++; s+=\$1} END{print n+0, s+0}')
  printf "%s\tkhu\t%s\t%s\t%s\n" "\$r" "\$1" "\$raw" "\$2"
done
REMOTE
