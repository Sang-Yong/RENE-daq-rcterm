#!/usr/bin/env bash
# =====================================================================
#  runcheck.sh - 끝난 런의 산출물이 다 있는지 대조하고, 빈 것의 사유를 밝힌다.
#
#  왜 필요한가
#    /scratch/LOG 의 깨진 dirent 때문에 런마다 서브런 두어 개가 조용히 빈다
#    (CLAUDE.md §11.52 · §11.68 · §11.89 · §11.95 — 네 번 겪었다). 껍데기
#    스크립트가 `date > $LOG` 로 로그를 먼저 만드는데 그것이 EIO 로 실패하면
#    **매크로가 아예 실행되지 않는다.** postrun 은 `(0초)` 한 줄만 내고 넘어간다.
#    원본 데이터는 멀쩡하다.
#
#    그러면 그 런은 PRD 개수 != FADC 개수 가 되어 dataflow 의 is_processed()
#    를 통과하지 못하고 /Data_ssd 에 붙박이가 된다. 서버 쪽 fsck 가 되기
#    전까지는 **런이 끝날 때마다 사람이 대조하는 것이 가장 값싼 방어**다.
#    그 대조와 진단, 복구 명령 조립까지를 이 스크립트가 대신한다.
#
#  하는 일
#    1) FADC / SADC / Merged / PRD 개수를 센다 (ls -U = readdir 만. §11.5)
#    2) 빈 서브런을 찾아 사유를 가른다
#         no_merge    Merged 가 없다        -> merge 부터 다시
#         no_prd      Merged 는 있다        -> production 만 다시
#         empty_merged  Merged 파일은 있는데 AbsEvent 트리가 없다 (§11.85)
#                                            -> 껍데기다. merge 부터 다시
#    3) 로그 이름이 EIO 인지 본다. **이미 있는 로그는 절대 건드리지 않는다**
#       (§11.82 에서 성공한 merge 로그를 덮어써 carry 를 날릴 뻔했다)
#    4) 직전 서브런 merge 로그에서 carry 를 읽어 복구 명령을 그대로 찍는다
#
#  ★ 안전 규칙
#    - 기본이 읽기 전용이다. --fix 라야 매크로를 부른다
#    - carry 를 못 읽으면 --fix 도 그 서브런을 건너뛴다. carry 를 0 으로
#      초기화하면 개수는 맞는데 내용이 조용히 부족할 수 있다 (§11.68)
#    - 수집 중인 런은 대상이 아니다. postrun 이 --lag 만큼 뒤따라오므로
#      언제나 서너 개가 비어 보인다 (§5.9)
# =====================================================================
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)

ROOTS=${RUNCHECK_ROOTS:-/Data_ssd/RAW:/data/RAW:/scratch/RAW}
PRODDIR=${RUNCHECK_PRODDIR:-/home/frontend/DAQ/DAQ_cup/production}
DB=${RUNCHECK_DB:-/Data_ssd/runcatalog.db}
HB=${RUNCHECK_HEARTBEAT:-/Data/LOG/rcterm.hb}
RUNARG=""; DOFIX=0; QUIET=0; MAXFIX=20; MAXDIAG=40; PARAMS=""

usage() {
cat <<EOF
사용
  scripts/runcheck.sh                    가장 최근에 끝난 런을 본다 (읽기 전용)
  scripts/runcheck.sh --run 4305         런을 지정한다
  scripts/runcheck.sh --run 4303,4304    여러 개
  scripts/runcheck.sh --last 5           최근에 끝난 런 5개
  scripts/runcheck.sh --run 4305 --fix   빈 것을 실제로 다시 만든다

옵션
  --run N[,N...]   대상 런
  --last N         최근에 끝난 런 N 개 (기본 1)
  --fix            빠진 Merged/PRD 를 실제로 만든다. carry 가 없으면 건너뛴다
  --max-fix N      --fix 로 한 번에 처리할 서브런 상한 (${MAXFIX})
  --max-diag N     한 런에서 사유를 밝힐 서브런 상한 (${MAXDIAG}).
                   결손이 수천 개인 옛 런을 상한 없이 훑으면 몇 시간이 걸린다
  --roots A:B:C    런 디렉터리 검색 경로 (${ROOTS})
  --prod-dir DIR   production 트리 (${PRODDIR})
  --db FILE        런 카탈로그 (${DB})
  --heartbeat F    수집 중인 런을 알아내는 데 쓴다 (${HB})
  --params FILE    config/dataflow.params 에서 경로를 읽는다
  -q, --quiet
  -h, --help

종료코드
  0  대상 런이 전부 완결됐다
  1  빈 것이 있다 (또는 --fix 로 다 채우지 못했다)
  2  쓸 수 없는 인자 / 대상 런을 찾지 못했다
EOF
}

while [ $# -gt 0 ]; do
   case "$1" in
      --run)       RUNARG=$2; shift 2 ;;
      --last)      LASTN=$2; shift 2 ;;
      --fix)       DOFIX=1; shift ;;
      --max-fix)   MAXFIX=$2; shift 2 ;;
      --max-diag)  MAXDIAG=$2; shift 2 ;;
      --roots)     ROOTS=$2; shift 2 ;;
      --prod-dir)  PRODDIR=$2; shift 2 ;;
      --db)        DB=$2; shift 2 ;;
      --heartbeat) HB=$2; shift 2 ;;
      --params)    PARAMS=$2; shift 2 ;;
      -q|--quiet)  QUIET=1; shift ;;
      -h|--help)   usage; exit 0 ;;
      *)           echo "unknown option : $1" >&2; usage; exit 2 ;;
   esac
done
LASTN=${LASTN:-1}

# dataflow.params 에서 읽을 수 있는 것만 읽는다 (경로가 한 곳에서 나오게)
if [ -n "$PARAMS" ]; then
   [ -r "$PARAMS" ] || { echo "params 를 읽을 수 없다 : $PARAMS" >&2; exit 2; }
   while IFS= read -r line; do
      line=${line%%#*}
      key=$(echo "$line" | awk -F= '{gsub(/ /,"",$1); print $1}')
      val=$(echo "$line" | awk -F= '{sub(/^[^=]*=/,""); gsub(/^[ \t]+|[ \t]+$/,""); print}')
      [ -n "$key" ] || continue
      case "$key" in
         heartbeat)     HB=$val ;;
         backup_dbfile) DB=$val ;;
         ssd_root)      SSD=$val ;;
         mid_root)      MID=$val ;;
         nfs_root)      NFS=$val ;;
      esac
   done < "$PARAMS"
   [ -n "${SSD:-}" ] && ROOTS="${SSD}/RAW:${MID:-/data}/RAW:${NFS:-/scratch}/RAW"
fi

CODEDIR=$PRODDIR/Code
LOGDIR=$PRODDIR/LOG
MERGE_MACRO=merge_FADC_SADC_v3_5v.cc
PROD_MACRO=production_from_merged_v3_5v.cc

C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'; C_C='\033[1;36m'; C_0='\033[0m'
say()  { [ "$QUIET" -eq 1 ] || printf '%b\n' "$*"; }
warn() { printf '%b\n' "$*" >&2; }

# ---------------------------------------------------------------------
#  런 디렉터리 찾기 — 앞의 root 가 이긴다 (dataflow 가 옮기므로 한 곳만 보면 놓친다)
# ---------------------------------------------------------------------
run_dir() {              # run_num
   local rp; rp=$(printf '%06d' "$1")
   local IFS=:; local r
   for r in $ROOTS; do [ -d "$r/$rp" ] && { echo "$r/$rp"; return 0; }; done
   return 1
}

# 수집 중인 런 (heartbeat 의 run=)
running_run() {
   [ -r "$HB" ] || return 1
   local r; r=$(awk -F= '/^run=/{print $2+0; exit}' "$HB" 2>/dev/null)
   [ -n "$r" ] && [ "$r" -gt 0 ] && echo "$r"
}

# 대상 런 정하기
runs_to_check() {
   if [ -n "$RUNARG" ]; then echo "${RUNARG//,/ }"; return 0; fi
   [ -r "$DB" ] || { warn "런 카탈로그를 읽을 수 없다 : $DB"; return 1; }
   sqlite3 "$DB" "select runnum from runcatalog
                  where etime is not null and onlbit=1
                  order by runnum desc limit $LASTN;" 2>/dev/null | sort -n
}

# ---------------------------------------------------------------------
#  개수 세기 — ls -U(readdir) 만. /scratch 는 100 Mb NFS 라 stat 을 걸면 못 쓴다
# ---------------------------------------------------------------------
list_idx() {             # dir prefix suffix   ->  서브런 번호 목록
   ls -U "$1" 2>/dev/null | sed -n "s/^$2\([0-9]\{5\}\)$3\$/\1/p"
}

# ---------------------------------------------------------------------
#  로그 이름이 쓸 수 있는 이름인가
#    ★ 이미 있는 로그는 절대 건드리지 않는다. 그 안의 carry 가 다음 서브런의
#      재처리에 쓰인다 (§11.82 에서 한 번 날릴 뻔했다)
#    없는 이름만 실제로 만들어 보고, 만들어졌으면 흔적을 지운다
# ---------------------------------------------------------------------
log_state() {            # 로그 경로  ->  exists | ok | EIO:<사유>
   local f=$1
   [ -e "$f" ] && { echo exists; return; }
   local err
   #  ★ 그룹으로 감싸야 리다이렉션 실패 메시지까지 잡힌다. `: > "$f" 2>&1` 로
   #    쓰면 `> "$f"` 가 먼저 실패하고 그때는 2>&1 이 아직 적용되기 전이라
   #    사유가 화면으로 새면서 EIO: 뒤는 비어 버린다
   if err=$( { : > "$f"; } 2>&1 ); then rm -f "$f" 2>/dev/null; echo ok
   else echo "EIO:$(echo "$err" | tail -1 | sed 's/.*: //')"; fi
}

# Merged 가 껍데기인지 — 파일이 있다고 온전한 것은 아니다 (§11.85)
merged_ok() {            # 파일 경로
   [ -s "$1" ] || return 1
   local n
   n=$(root -l -b -q -e "TFile*f=TFile::Open(\"$1\");
        if(!f||f->IsZombie()){printf(\"RC=-1\\n\");}else{
          TTree*t=(TTree*)f->Get(\"AbsEvent\");
          printf(\"RC=%lld\\n\", t? (long long)t->GetEntries() : -1LL);}" 2>/dev/null \
        | sed -n 's/^RC=//p' | tail -1)
   [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null
}

# production 매크로는 <런>/PRD/Run<런>_DLY_THR.log 를 읽는다
#   (variables_for_production.hh:98 reading_DLY_THR). 없으면 벡터가 비어
#   std::out_of_range 로 죽는데, 메시지만 봐서는 데이터 문제로 보인다.
#   postrun 은 구간 시작 전에 TCB 로그에서 한 번 만든다. 여기서도 같게 한다.
ensure_dly_thr() {       # 런 디렉터리 run_pad
   local dd=$1 rp=$2
   local uselog="$dd/PRD/Run${rp}_DLY_THR.log"
   [ -s "$uselog" ] && return 0
   local tcblog="$(dirname "$dd")/../LOG/TCB_${rp}.log"
   if [ -r "$tcblog" ]; then
      mkdir -p "$dd/PRD"
      grep WJ "$tcblog" > "$uselog" 2>/dev/null
      [ -s "$uselog" ] && return 0
      rm -f "$uselog"
   fi
   return 1
}

# 직전 서브런 merge 로그에서 carry 를 읽는다
CARRY_SADC=""; CARRY_EVT=""; CARRY_TRG=""
load_carry() {           # run_num subrun
   CARRY_SADC=""; CARRY_EVT=""; CARRY_TRG=""
   local rn=$1 n=$2
   [ "$n" -eq 0 ] && { CARRY_SADC=0; CARRY_EVT=0; CARRY_TRG=0; return 0; }
   local f="$LOGDIR/log_merge_FADC_SADC_v3_5v_run${rn}_subrun$(( n - 1 )).txt"
   [ -r "$f" ] || return 1
   CARRY_SADC=$(grep -m1 "final SADC "              "$f" 2>/dev/null | awk '{print $4}')
   CARRY_EVT=$( grep -m1 "final SADC_evt"           "$f" 2>/dev/null | awk '{print $4}')
   CARRY_TRG=$( grep -m1 "final before_SADC_trgnum" "$f" 2>/dev/null | awk '{print $4}')
   [ -n "$CARRY_SADC" ] && [ -n "$CARRY_EVT" ] && [ -n "$CARRY_TRG" ]
}

# ---------------------------------------------------------------------
#  런 하나
# ---------------------------------------------------------------------
NGAP_TOTAL=0; NFIXED_TOTAL=0; NLEFT_TOTAL=0; NCMD_TOTAL=0
check_run() {            # run_num
   local rn=$1 rp dd
   rp=$(printf '%06d' "$rn")
   dd=$(run_dir "$rn") || { warn "run $rp : 런 디렉터리가 없다 ($ROOTS)"; return 2; }

   local cur; cur=$(running_run || true)
   if [ -n "$cur" ] && [ "$cur" -eq "$rn" ]; then
      say "${C_Y}run $rp : 수집 중이다. 대조하지 않는다${C_0} (postrun 이 --lag 만큼 뒤따른다)"
      return 0
   fi

   local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN

   list_idx "$dd"          "FADC_${rp}\.root\."   ""       | sort > "$tmp/fadc"
   list_idx "$dd"          "SADC_${rp}\.root\."   ""       | sort > "$tmp/sadc"
   list_idx "$dd/Merged"   "MERGED_${rp}\.root\." ""       | sort > "$tmp/merged"
   list_idx "$dd/PRD"      "PRD_${rp}\."          "\.root" | sort > "$tmp/prd"
   local nf ns nm np nb
   nf=$(wc -l < "$tmp/fadc"); ns=$(wc -l < "$tmp/sadc")
   nm=$(wc -l < "$tmp/merged"); np=$(wc -l < "$tmp/prd")
   nb=$(ls -U "$dd/badrun" 2>/dev/null | grep -c '\.root\.') || true

   local head="run $rp  ($dd)"
   local counts="FADC $nf / SADC $ns / Merged $nm / PRD $np"
   [ "$nb" -gt 0 ] && counts="$counts / badrun $nb"

   if [ "$nf" -eq 0 ]; then
      say "${C_Y}$head${C_0}\n   $counts — 이 디스크에 원시 파일이 없다. 대조하지 않는다"
      return 0
   fi
   if [ "$np" -eq "$nf" ] && [ "$nm" -eq "$nf" ]; then
      say "${C_G}$head  완결${C_0}\n   $counts"
      return 0
   fi

   say "${C_R}$head  빈 곳이 있다${C_0}\n   $counts"

   # 빠진 서브런 = FADC 에는 있는데 PRD 나 Merged 에 없는 것
   comm -23 "$tmp/fadc" "$tmp/prd"    > "$tmp/miss_prd"
   comm -23 "$tmp/fadc" "$tmp/merged" > "$tmp/miss_merged"
   sort -u "$tmp/miss_prd" "$tmp/miss_merged" > "$tmp/miss"
   local nmiss; nmiss=$(wc -l < "$tmp/miss")
   NGAP_TOTAL=$((NGAP_TOTAL + nmiss))
   say "   빠진 서브런 $nmiss 개"

   #  ★ 서브런마다 로그 이름을 시험하고 carry 를 읽는다. /scratch 는 100 Mb NFS 라
   #    (§11.12) 그것이 서브런당 수십 초다. 결손이 수천 개인 옛 런에 상한 없이
   #    들어가면 몇 시간을 먹는다 — §5.9 에서 밟은 것과 같은 함정이다
   if [ "$nmiss" -gt "$MAXDIAG" ]; then
      say "   ${C_Y}앞 $MAXDIAG 개만 사유를 밝힌다${C_0} (나머지 $((nmiss - MAXDIAG)) 개는 보지 않았다. --max-diag 로 늘린다)"
      head -n "$MAXDIAG" "$tmp/miss" > "$tmp/miss.head" && mv "$tmp/miss.head" "$tmp/miss"
      NLEFT_TOTAL=$((NLEFT_TOTAL + nmiss - MAXDIAG))
   fi

   local n idx kind mlog plog ms ps carry cmd nfix=0
   while read -r n; do
      [ -n "$n" ] || continue
      idx=$((10#$n))
      mlog="$LOGDIR/log_merge_FADC_SADC_v3_5v_run${rn}_subrun${idx}.txt"
      plog="$LOGDIR/log_production_v3_5v_run${rn}_subrun${idx}.txt"
      local mfile="$dd/Merged/MERGED_${rp}.root.$n"

      if grep -qx "$n" "$tmp/miss_merged"; then kind=no_merge
      elif merged_ok "$mfile";              then kind=no_prd
      else                                       kind=empty_merged; fi

      ms=$(log_state "$mlog"); ps=$(log_state "$plog")
      carry=no; load_carry "$rn" "$idx" && carry=yes

      printf '   %b\n' "${C_C}sub $n${C_0}  $kind   merge로그=$ms  prod로그=$ps  carry=$carry"

      if [ "$kind" = no_prd ]; then
         cmd="root -l -b -q '$PROD_MACRO($rn,$idx,\"$dd\")'"
      elif [ "$carry" = yes ]; then
         cmd="root -l -b -q '$MERGE_MACRO($rn,$((10#$(tail -1 "$tmp/fadc"))),$idx,$CARRY_SADC,$CARRY_EVT,$CARRY_TRG,\"$dd\")' && \\
        root -l -b -q '$PROD_MACRO($rn,$idx,\"$dd\")'"
      else
         cmd=""
      fi

      if [ -z "$cmd" ]; then
         say "      ${C_Y}carry 를 못 읽는다. 손대지 않는다${C_0} (0 으로 초기화하면 내용이 조용히 부족할 수 있다 — §11.68)"
         NLEFT_TOTAL=$((NLEFT_TOTAL+1))
         continue
      fi

      if [ "$DOFIX" -eq 0 ]; then
         [ -s "$dd/PRD/Run${rp}_DLY_THR.log" ] || \
            say "      ${C_Y}PRD/Run${rp}_DLY_THR.log 이 없다${C_0} — production 이 이것을 읽는다. --fix 는 TCB 로그에서 만들어 준다"
         say "      (cd $CODEDIR && $cmd)"
         NCMD_TOTAL=$((NCMD_TOTAL+1)); NLEFT_TOTAL=$((NLEFT_TOTAL+1))
         continue
      fi

      if [ "$nfix" -ge "$MAXFIX" ]; then
         say "      ${C_Y}--max-fix $MAXFIX 에 걸려 여기서 멈춘다${C_0}"
         NLEFT_TOTAL=$((NLEFT_TOTAL+1))
         continue
      fi

      if ! ensure_dly_thr "$dd" "$rp"; then
         say "      ${C_R}PRD/Run${rp}_DLY_THR.log 이 없고 TCB 로그에서도 만들 수 없다${C_0}"
         say "         production 매크로가 이것을 읽는다. 없으면 std::out_of_range 로 죽는다"
         NLEFT_TOTAL=$((NLEFT_TOTAL+1))
         continue
      fi
      say "      ${C_C}복구 중 ...${C_0}"
      if ( cd "$CODEDIR" && eval "$cmd" ) >"$tmp/fixlog" 2>&1; then
         if [ -s "$dd/PRD/PRD_${rp}.$n.root" ]; then
            say "      ${C_G}복구 완료${C_0}"
            nfix=$((nfix+1)); NFIXED_TOTAL=$((NFIXED_TOTAL+1))
         else
            say "      ${C_R}매크로는 끝났는데 PRD 가 없다${C_0}"; tail -5 "$tmp/fixlog" | sed 's/^/         /'
            NLEFT_TOTAL=$((NLEFT_TOTAL+1))
         fi
      else
         say "      ${C_R}실패${C_0}"; tail -5 "$tmp/fixlog" | sed 's/^/         /'
         NLEFT_TOTAL=$((NLEFT_TOTAL+1))
      fi
   done < "$tmp/miss"

   return 1
}

# ---------------------------------------------------------------------
RUNS=$(runs_to_check) || exit 2
[ -n "$RUNS" ] || { warn "대상 런이 없다"; exit 2; }

RC=0
for r in $RUNS; do
   check_run "$((10#$r))"
   case $? in
      0) ;;
      2) RC=2 ;;                                   # 대상을 찾지 못했다
      *) [ "$RC" -eq 0 ] && RC=1 ;;                # 빈 곳이 있다
   esac
done

if [ "$NGAP_TOTAL" -gt 0 ]; then
   say ""
   if [ "$DOFIX" -eq 1 ]; then
      say "빠진 서브런 $NGAP_TOTAL 개 : 복구 $NFIXED_TOTAL / 남음 $NLEFT_TOTAL"
      [ "$NLEFT_TOTAL" -eq 0 ] && RC=0
   else
      if [ "$NCMD_TOTAL" -gt 0 ]; then
         say "빠진 서브런 $NGAP_TOTAL 개 (복구 명령을 낸 것 $NCMD_TOTAL 개). 위 명령을 그대로 쓰거나 --fix 를 붙인다"
      else
         say "빠진 서브런 $NGAP_TOTAL 개. 전부 carry 를 못 읽어 손대지 않았다 (§11.68)"
      fi
   fi
fi
exit $RC
