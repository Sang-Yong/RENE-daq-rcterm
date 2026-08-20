#!/usr/bin/env bash
# =====================================================================
#  badrun.sh - 문제가 있었던 런을 찾아 분류하고, 못 쓰는 원시 파일을 격리한다.
#
#  왜 필요한가
#    런이 쓰기 도중 죽으면 마지막 서브런 파일이 안 닫힌 채 남는다. ROOT 는
#    그것을 열지 못하고(no keys recovered) merge 도 production 도 못 한다.
#    그러면 그 런은 **PRD 개수 == FADC 개수** 를 영원히 만족하지 못하고,
#    dataflow 의 is_processed() 가 통과시키지 않아 /Data_ssd 에 붙박이가 된다.
#
#    못 쓰는 원시 파일을 <런>/badrun/ 으로 옮기면 그 조건이 자연히 풀린다.
#    dataflow 의 move_dir 은 재귀라 badrun/ 을 함께 옮기고, backup-khu 의
#    bk_RAW 는 Merged/PRD/PNG 만 제외하므로 badrun/ 을 그대로 보낸다.
#    즉 **이동·백업 쪽은 고칠 것이 없다.** 같은 트리 구조로 따라간다.
#
#       /Data_ssd/RAW/004293/badrun/  ->  /data  ->  /scratch
#                                     ->  khu:/store/cpnr-data/RENE/RAW/004293/badrun/
#
#  ★ 안전 규칙 — 열리는 파일은 절대 격리하지 않는다
#    원본이 멀쩡한데 PRD 만 없는 것은 '다시 돌리면 되는 것'이지 badrun 이
#    아니다. 실제로 run 4291 서브런 30 이 그랬고, 격리했으면 멀쩡한 61,140
#    이벤트를 묻을 뻔했다. 격리 대상은 ROOT 가 열지 못하는 원시 파일뿐이다.
#
#  서브런별 판정 (한 런 안에 여러 종류가 섞일 수 있다)
#    bad_raw   자기 FADC 또는 SADC 가 안 열린다        -> 격리 대상
#    blocked   자기 원본은 멀쩡한데 다음 SADC 가 죽어  -> 격리하지 않는다.
#              merge 를 끝낼 수 없다. 다만 부분 Merged    부분 복구가 가능하다
#              가 정상 ROOT 파일로 남아 있으면 거기서       (CLAUDE.md §11.64)
#              PRD 를 만들 수 있다
#    gap       전부 잘 열린다                          -> 격리하지 않는다.
#                                                        재처리하면 된다
#
#  분류 (런 단위)
#    boot_failed     DB runlog 가 그렇게 말한다. 데이터가 없다
#    aborted         onlbit=0. 시작은 했으나 마감 못 했다
#    truncated_tail  bad_raw 서브런이 있다
#    prd_gap         gap / blocked 서브런만 있다
#    no_data         런 디렉터리는 있는데 안이 비었다
#
#    ★ onlbit 이 NULL 인 행은 싣지 않는다. 약 1,000건이 있고 rc.py 시절의
#      역사적 정상이라(회귀가 아니다) 그것까지 실으면 목록이 쓸모없어진다.
#      디스크에 실제 결함이 있으면 아래 개수 대조에서 따로 잡힌다.
#
#  비용
#    1단계  런마다 readdir 로 개수만 센다                     (전 구간 수 분)
#    2단계  PRD == FADC 이고 FADC > 0 이면 정상. 끝
#    3단계  나머지만 ROOT 로 열어 본다                        (소수)
#    /scratch 는 100 Mb NFS 라 파일마다 stat 을 거는 find -printf 를
#    쓰면 못 쓴다(CLAUDE.md §11.5). 여기서는 ls -U(readdir) 만 쓴다.
#
#  사용
#    scripts/badrun.sh --scan                   읽기 전용. 무엇이 문제인지만
#    scripts/badrun.sh --scan --update-list     목록 갱신 (데이터는 안 건드림)
#    scripts/badrun.sh --quarantine --run 4293 --dry-run
#    scripts/badrun.sh --quarantine --run 4293
#    scripts/badrun.sh --export                 docs/BADRUNS.md 사본 갱신
# =====================================================================
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)

ROOTS=${BADRUN_ROOTS:-/Data_ssd/RAW:/data/RAW:/scratch/RAW}
DB=${BACKUP_DBFILE:-/Data_ssd/runcatalog.db}
LIST=${BADRUN_LIST:-/Data_ssd/LOG/badrun_list.txt}
EXPORT_MD=${BADRUN_EXPORT:-$REPO/docs/BADRUNS.md}
HB=${BADRUN_HB:-/Data/LOG/rcterm.hb}

MODE=scan; UPDATE=0; DRYRUN=0; RUNS=""; FROM=""; TO=""; QUIET=0
TOUCHED=0
MAXCHK=${BADRUN_MAX_CHECK:-40}   # 런 하나에서 ROOT 로 열어 볼 서브런 상한

C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'; C_C='\033[1;36m'; C_0='\033[0m'
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { [ "$QUIET" -eq 1 ] || printf '%b\n' "$*"; }
logt(){ [ "$QUIET" -eq 1 ] || printf '[%s] %b\n' "$(ts)" "$*"; }
die() { printf "%b\n" "${C_R}[FATAL]${C_0} $*" >&2; exit 1; }

usage() { sed -n '2,62p' "$0" | sed 's/^# \{0,1\}//'; cat <<EOF

옵션
  --scan               문제 런을 찾아 화면에 낸다 (기본, 읽기 전용)
  --update-list        찾은 결과로 목록 파일을 갱신한다. 데이터는 안 건드린다
  --quarantine         못 쓰는 원시 파일을 <런>/badrun/ 으로 옮긴다
  --export             목록을 docs/BADRUNS.md 로 내보낸다
  --run N[,N...]       대상 런. 없으면 전부
  --from N / --to N    런 번호 구간
  --roots A:B:C        런 디렉터리 검색 경로 (${ROOTS})
  --db FILE            런 카탈로그 (${DB})
  --list FILE          목록 파일 (${LIST})
  --params FILE        config/dataflow.params 에서 경로를 읽는다
  --max-check N        런 하나에서 ROOT 로 열어 볼 서브런 상한 (${MAXCHK}).
                       잘림은 언제나 런의 끝에서 일어나므로 꼬리부터 본다
  --dry-run            무엇을 할지만 출력
  -q, --quiet
  -h, --help
EOF
}

load_params() {
   local f=$1 line k v ssd=/Data_ssd mid=/data nfs=/scratch
   [ -r "$f" ] || die "설정 파일을 읽을 수 없다 : $f"
   while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      case "$line" in *=*) ;; *) continue ;; esac
      k=${line%%=*}; v=${line#*=}
      k=$(printf '%s' "$k" | tr -d ' \t' | tr 'a-z-' 'A-Z_')
      v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      case "$k" in
         SSD_ROOT|SSD) ssd=$v ;;
         MID_ROOT|MID) mid=$v ;;
         NFS_ROOT|NFS) nfs=$v ;;
         HEARTBEAT)    HB=$v ;;
         BACKUP_DBFILE) DB=$v ;;
         BADRUN_LIST)  LIST=$v ;;
         *) : ;;
      esac
   done < "$f"
   ROOTS="$ssd/RAW:$mid/RAW:$nfs/RAW"
}

while [ $# -gt 0 ]; do
   case "$1" in
      --scan)        MODE=scan; shift ;;
      --update-list) UPDATE=1; shift ;;
      --quarantine)  MODE=quarantine; shift ;;
      --export)      MODE=export; shift ;;
      --run)         RUNS=$(printf '%s' "$2" | tr ',' ' '); shift 2 ;;
      --from)        FROM=$2; shift 2 ;;
      --to)          TO=$2; shift 2 ;;
      --roots)       ROOTS=$2; shift 2 ;;
      --db)          DB=$2; shift 2 ;;
      --list)        LIST=$2; shift 2 ;;
      --params)      load_params "$2"; shift 2 ;;
      --max-check)   MAXCHK=$2; shift 2 ;;
      --dry-run)     DRYRUN=1; shift ;;
      -q|--quiet)    QUIET=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      *)             die "알 수 없는 인자 : $1  (--help)" ;;
   esac
done

IFS=':' read -r -a ROOT_ARR <<< "$ROOTS"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/badrun.XXXXXX") || die "임시 디렉터리를 만들 수 없다"
trap 'rm -rf "$TMP"' EXIT

# =====================================================================
#  런 디렉터리 찾기 — RAW 와 PRD 는 서로 다른 root 에 있을 수 있다
#    실제로 run 4290/4291 은 RAW 가 /scratch, 산출물이 /Data_ssd 다.
#    한 root 만 보고 둘 다 세면 RAW 를 0 으로 읽는다 (CLAUDE.md §11.47).
# =====================================================================
find_raw_dir() {         # run_pad
   local rp=$1 r d
   for r in "${ROOT_ARR[@]}"; do
      d="$r/$rp"
      [ -d "$d" ] || continue
      if ls -U "$d" 2>/dev/null | grep -q "^FADC_${rp}\.root\."; then echo "$d"; return 0; fi
   done
   return 1
}
find_prd_dir() {         # run_pad
   local rp=$1 r d
   for r in "${ROOT_ARR[@]}"; do
      d="$r/$rp/PRD"
      [ -e "$d" ] || continue
      if ls -U "$d" 2>/dev/null | grep -q "^PRD_${rp}\..*\.root$"; then echo "$d"; return 0; fi
   done
   return 1
}
find_merged_dir() {      # run_pad
   local rp=$1 r d
   for r in "${ROOT_ARR[@]}"; do
      d="$r/$rp/Merged"
      [ -e "$d" ] || continue
      if ls -U "$d" 2>/dev/null | grep -q "^MERGED_${rp}\.root\."; then echo "$d"; return 0; fi
   done
   return 1
}
any_dir() {              # run_pad — 어느 root 에든 런 디렉터리가 있나
   local rp=$1 r
   for r in "${ROOT_ARR[@]}"; do [ -d "$r/$rp" ] && { echo "$r/$rp"; return 0; }; done
   return 1
}

subs_of() {              # dir prefix run_pad suffix_style
   #  fadc : FADC_<rp>.root.<sub>      prd : PRD_<rp>.<sub>.root
   case "$4" in
      raw) ls -U "$1" 2>/dev/null | sed -n "s/^$2_$3\.root\.\([0-9]\{1,\}\)$/\1/p" | sort -u ;;
      prd) ls -U "$1" 2>/dev/null | sed -n "s/^PRD_$3\.\([0-9]\{1,\}\)\.root$/\1/p" | sort -u ;;
   esac
}

# =====================================================================
#  ROOT 로 열어 본다 — 한 런에 한 번만 부른다
#    "열린다" = Zombie 가 아니고 키가 하나 이상 있다. 잘린 파일은 ROOT 가
#    recover 를 시도하고 'no keys recovered' 로 Zombie 를 만든다.
# =====================================================================
cat > "$TMP/chk.C" <<'MACRO'
#include <fstream>
#include <string>
void chk() {
   const char* lf = gSystem->Getenv("BADRUN_CHECK_LIST");
   if (!lf) return;
   std::ifstream in(lf);
   std::string s;
   while (std::getline(in, s)) {
      if (s.empty()) continue;
      TFile* f = TFile::Open(s.c_str());
      bool ok = (f && !f->IsZombie() && f->GetListOfKeys() && f->GetListOfKeys()->GetSize() > 0);
      printf("BADRUNCHK %s %s\n", ok ? "OK" : "BAD", s.c_str());
      if (f) { f->Close(); delete f; }
   }
}
MACRO

declare -A OPENOK
#  ★ 파이프라인으로 부르지 말 것. 파이프의 각 단계는 서브셸이라 OPENOK 에 넣은
#    것이 통째로 사라지고, 조회가 전부 실패해 멀쩡한 파일이 'bad_raw' 로
#    떨어진다. 목록은 파일로 건네고 이 함수는 파이프 없이 부른다.
check_files() {          # $TMP/list.txt 를 읽어 OPENOK[path]=OK|BAD 를 채운다
   local lf="$TMP/list.txt" st path
   [ -s "$lf" ] || return 0
   BADRUN_CHECK_LIST="$lf" root -l -b -q "$TMP/chk.C" 2>/dev/null \
      | sed -n 's/^BADRUNCHK \([A-Z]*\) \(.*\)$/\1|\2/p' > "$TMP/res.txt"
   while IFS='|' read -r st path; do
      [ -n "$path" ] && OPENOK["$path"]=$st
   done < "$TMP/res.txt"
}

# =====================================================================
#  런 카탈로그
# =====================================================================
#  수집 중인 런 번호. heartbeat 가 없거나 못 읽으면 비워 둔다.
HB_RUN=""
load_hb() {
   [ -r "$HB" ] || return 0
   local r; r=$(sed -n 's/^run=//p' "$HB" | head -1)
   [ -n "$r" ] && HB_RUN=$((10#$r))
   #  런이 이미 끝났으면 잠글 이유가 없다
   grep -q '^phase=ended' "$HB" 2>/dev/null && HB_RUN=""
   return 0
}

declare -A DB_ONL DB_LOG
load_db() {
   [ -r "$DB" ] || { logt "${C_Y}[WARN]${C_0} 런 카탈로그를 읽을 수 없다 : $DB"; return 0; }
   command -v sqlite3 >/dev/null 2>&1 || { logt "${C_Y}[WARN]${C_0} sqlite3 가 없다. DB 근거 없이 디스크만 본다"; return 0; }
   local rn onl lg
   while IFS='|' read -r rn onl lg; do
      [ -n "$rn" ] || continue
      DB_ONL[$rn]=$onl
      DB_LOG[$rn]=$lg
   done < <(sqlite3 -separator '|' "$DB" \
      "select runnum, coalesce(onlbit,''), coalesce(replace(replace(runlog,'|',' '),char(10),' '),'') from runcatalog;" 2>/dev/null)
}

# =====================================================================
#  한 런을 분류한다
#    결과는 전역으로 : R_CAT R_SUBS R_MEMO R_QUAR(격리할 파일, 개행 구분)
# =====================================================================
classify() {             # run_num
   local rn=$1 rp; rp=$(printf '%06d' "$rn")
   R_CAT=""; R_SUBS="-"; R_MEMO=""; R_QUAR=""
   local rawdir prddir dir onl lg
   onl=${DB_ONL[$rn]:-}
   lg=${DB_LOG[$rn]:-}

   #  ★ 지금 수집 중인 런은 절대 싣지 않는다. postrun 은 --lag 3 으로 따라오므로
   #    가동 중에는 언제나 PRD 가 서너 개 적고, 기록 중인 마지막 SADC 는 아직
   #    안 닫혀 ROOT 가 열지 못한다. 그대로 두면 멀쩡한 런이 매 훑기마다
   #    prd_gap 으로 잡힌다(실측: run 4302 FADC 1263 / PRD 1260).
   if [ -n "${HB_RUN:-}" ] && [ "$HB_RUN" -eq "$rn" ]; then return 1; fi

   rawdir=$(find_raw_dir "$rp") || rawdir=""
   prddir=$(find_prd_dir "$rp") || prddir=""

   # ---- 데이터가 아예 없다 -------------------------------------------
   if [ -z "$rawdir" ] && [ -z "$prddir" ]; then
      dir=$(any_dir "$rp") || dir=""
      if [ "$onl" = "0" ]; then
         case "$lg" in
            *"boot failed"*) R_CAT=boot_failed ;;
            *)               R_CAT=aborted ;;
         esac
         R_MEMO="${lg:-DB onlbit=0}"
         [ -n "$dir" ] && R_MEMO="$R_MEMO; 런 디렉터리는 있으나 비었다"
         return 0
      fi
      if [ -n "$dir" ]; then
         R_CAT=no_data; R_MEMO="런 디렉터리가 있으나 FADC 도 PRD 도 없다"
         return 0
      fi
      return 1        # 로컬에 없고 DB 도 문제라 하지 않는다 -> 목록에서 뺀다
   fi

   # ---- RAW 를 못 찾으면 완결성을 판단할 수 없다 ----------------------
   if [ -z "$rawdir" ]; then
      if [ "$onl" = "0" ]; then
         case "$lg" in *"boot failed"*) R_CAT=boot_failed ;; *) R_CAT=aborted ;; esac
         R_MEMO="${lg:-DB onlbit=0}; RAW 가 로컬에 없어 개수 대조는 못 했다"
         return 0
      fi
      return 1
   fi

   #  ★ 이미 격리한 런은 개수가 맞아떨어져도 **언제나 목록에 남긴다.**
   #    격리하면 PRD 개수 == FADC 개수 가 되어 '정상'으로 보이는데, 그대로
   #    떨어뜨리면 문제가 있었다는 사실 자체가 목록에서 사라진다. 이 목록의
   #    존재 이유가 'DAQ 시작부터 지금까지 무엇이 문제였나' 이므로 그러면 안 된다.
   local qdir="$rawdir/badrun" q_subs="" q_n=0
   if [ -d "$qdir" ]; then
      q_subs=$(ls -U "$qdir" 2>/dev/null \
               | sed -n "s/^[FS]ADC_$rp\.root\.\([0-9]\{1,\}\)$/\1/p" | sort -u | tr '\n' ' ')
      q_n=$(ls -U "$qdir" 2>/dev/null | grep -c "^[FS]ADC_$rp\.root\.")
   fi

   local f_subs p_subs n_f n_p missing
   f_subs=$(subs_of "$rawdir" FADC "$rp" raw)
   n_f=$(printf '%s\n' "$f_subs" | grep -c '[0-9]')
   if [ -n "$prddir" ]; then
      p_subs=$(subs_of "$prddir" PRD "$rp" prd)
   else
      p_subs=""
   fi
   n_p=$(printf '%s\n' "$p_subs" | grep -c '[0-9]')

   # ---- 개수가 맞으면 정상. 여기서 대부분이 걸러진다 -------------------
   if [ "$n_f" -gt 0 ] && [ "$n_p" -eq "$n_f" ]; then
      if [ "$q_n" -gt 0 ]; then
         R_CAT=truncated_tail
         R_SUBS=$(printf '%s' "$q_subs" | sed 's/ *$//;s/ /,/g')
         R_MEMO="원시 파일 $q_n 개를 badrun/ 으로 격리했다. 나머지는 완결 (FADC $n_f = PRD $n_p). 사유는 badrun/README.txt"
         return 0
      fi
      if [ "$onl" = "0" ]; then
         case "$lg" in *"boot failed"*) R_CAT=boot_failed ;; *) R_CAT=aborted ;; esac
         R_MEMO="${lg:-DB onlbit=0}; 다만 후처리는 완결됐다 (FADC $n_f = PRD $n_p)"
         return 0
      fi
      return 1
   fi

   # ---- 가드 : PRD 가 하나도 없으면 열어 볼 것도 없다 ------------------
   #    옛 런은 후처리를 안 했거나 산출물이 경희대에만 있다. 그런 런에서
   #    빠진 서브런을 전부 열면 한 런에 수천 번 ROOT 를 띄우게 된다.
   if [ "$n_p" -eq 0 ]; then
      R_CAT=not_processed
      R_SUBS="-"
      R_MEMO="FADC $n_f / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다"
      if [ "$q_n" -gt 0 ]; then
         R_CAT="truncated_tail+not_processed"
         R_SUBS=$(printf '%s' "$q_subs" | sed 's/ *$//;s/ /,/g')
         R_MEMO="원시 파일 $q_n 개 격리됨. $R_MEMO"
      fi
      if [ "$onl" = "0" ]; then
         case "$lg" in *"boot failed"*) R_MEMO="boot failed; $R_MEMO" ;; *) R_MEMO="aborted; $R_MEMO" ;; esac
      fi
      return 0
   fi

   # ---- 빠진 서브런을 추린다 -----------------------------------------
   printf '%s\n' "$f_subs" | grep '[0-9]' | sort > "$TMP/f.txt"
   printf '%s\n' "$p_subs" | grep '[0-9]' | sort > "$TMP/p.txt"
   missing=$(comm -23 "$TMP/f.txt" "$TMP/p.txt")
   if [ -z "$missing" ]; then
      # PRD 가 FADC 보다 많다 — 이상하지만 결손은 아니다
      R_CAT=prd_gap; R_MEMO="PRD($n_p) 가 FADC($n_f) 보다 많다. 확인 필요"
      return 0
   fi

   # ---- 빠진 서브런과 그 다음 SADC 만 ROOT 로 열어 본다 ---------------
   #    ★ 상한을 두되 **꼬리부터** 본다. 파일이 잘리는 것은 런이 죽는 순간
   #      뿐이라 언제나 마지막 서브런 근처다. 앞쪽 결손은 후처리 문제이고
   #      원본은 멀쩡한 것이 보통이다.
   local s nx sadcdir n_miss checked
   sadcdir=$rawdir
   n_miss=$(printf '%s\n' $missing | grep -c '[0-9]')
   checked=$missing
   if [ "$n_miss" -gt "$MAXCHK" ]; then
      checked=$(printf '%s\n' $missing | sort -r | head -n "$MAXCHK" | sort | tr '\n' ' ')
   fi
   {
      for s in $checked; do
         [ -f "$rawdir/FADC_$rp.root.$s" ] && echo "$rawdir/FADC_$rp.root.$s"
         [ -f "$sadcdir/SADC_$rp.root.$s" ] && echo "$sadcdir/SADC_$rp.root.$s"
         nx=$(printf '%05d' $((10#$s + 1)))
         [ -f "$sadcdir/SADC_$rp.root.$nx" ] && echo "$sadcdir/SADC_$rp.root.$nx"
      done
   } | sort -u > "$TMP/list.txt"
   check_files

   #  ★ 판정을 셋으로 나눈다. 조회에 실패했으면(UNKNOWN) **격리하지 않는다** —
   #    확신이 없을 때 멀쩡한 원본을 묻는 것보다 목록에 남기는 편이 안전하다.
   local bad_raw="" blocked="" gap="" v_f v_s v_n nofile
   for s in $checked; do
      nofile=0
      if [ -f "$rawdir/FADC_$rp.root.$s" ]; then
         v_f=${OPENOK["$rawdir/FADC_$rp.root.$s"]:-UNKNOWN}
      else v_f=NOFILE; nofile=1; fi
      if [ -f "$sadcdir/SADC_$rp.root.$s" ]; then
         v_s=${OPENOK["$sadcdir/SADC_$rp.root.$s"]:-UNKNOWN}
      else v_s=NOFILE; nofile=1; fi
      nx=$(printf '%05d' $((10#$s + 1)))
      if [ -f "$sadcdir/SADC_$rp.root.$nx" ]; then
         v_n=${OPENOK["$sadcdir/SADC_$rp.root.$nx"]:-UNKNOWN}
      else v_n=NONE; fi

      if [ "$v_f" = BAD ] || [ "$v_s" = BAD ] || [ "$nofile" -eq 1 ]; then
         #  ★ 한쪽만 죽어도 **그 서브런의 양쪽을 함께** 격리한다. 짝 없는
         #    FADC 는 혼자서는 merge 도 production 도 못 하므로 최상위에
         #    남겨 두면 PRD 개수와 영원히 어긋나 런이 옮겨지지 않는다.
         bad_raw="$bad_raw $s"
         [ -f "$rawdir/FADC_$rp.root.$s" ] && R_QUAR="$R_QUAR$rawdir/FADC_$rp.root.$s"$'\n'
         [ -f "$sadcdir/SADC_$rp.root.$s" ] && R_QUAR="$R_QUAR$sadcdir/SADC_$rp.root.$s"$'\n'
      elif [ "$v_f" = UNKNOWN ] || [ "$v_s" = UNKNOWN ]; then
         gap="$gap $s"
      elif [ "$v_n" = BAD ]; then
         blocked="$blocked $s"
      else
         gap="$gap $s"
      fi
   done

   local cats="" memo=""
   [ -n "$bad_raw" ] && { cats="truncated_tail"; memo="격리 대상 서브런$bad_raw (원본이 ROOT 로 안 열린다)"; }
   if [ -n "$blocked" ]; then
      [ -n "$cats" ] && cats="$cats+prd_gap" || cats="prd_gap"
      memo="${memo:+$memo; }서브런$blocked 은 원본은 멀쩡하나 다음 SADC 가 죽어 merge 를 끝낼 수 없다. 부분 Merged 에서 PRD 복구 가능"
   fi
   if [ -n "$gap" ]; then
      [ -n "$cats" ] && { case "$cats" in *prd_gap*) : ;; *) cats="$cats+prd_gap" ;; esac; } || cats="prd_gap"
      memo="${memo:+$memo; }서브런$gap 은 원본이 멀쩡하다. 재처리하면 된다"
   fi

   if [ "$q_n" -gt 0 ]; then
      case "$cats" in *truncated_tail*) : ;; *) cats="truncated_tail${cats:++$cats}" ;; esac
      memo="원시 파일 $q_n 개 격리됨(서브런 $(printf '%s' "$q_subs" | sed 's/ *$//;s/ /,/g')). ${memo}"
   fi
   R_CAT=$cats
   R_SUBS=$(printf '%s\n' $q_subs $bad_raw $blocked $gap | sort -u | tr '\n' ',' | sed 's/,$//')
   [ -n "$R_SUBS" ] || R_SUBS="-"
   R_MEMO="FADC $n_f / PRD $n_p. $memo"
   if [ "$n_miss" -gt "$MAXCHK" ]; then
      R_MEMO="$R_MEMO; 빠진 서브런 $n_miss 개 중 뒤 $MAXCHK 개만 열어 봤다 (--max-check)"
   fi
   if [ "$onl" = "0" ]; then
      case "$lg" in *"boot failed"*) R_MEMO="boot failed; $R_MEMO" ;; *) R_MEMO="aborted; $R_MEMO" ;; esac
   fi
   return 0
}

# 서브런 목록이 길어지면 줄이 못 읽게 된다. 앞 8개만 보이고 나머지는 수로 센다.
short_subs() {           # "a,b,c,..."
   local s=$1 n
   [ "$s" = "-" ] && { echo "-"; return; }
   n=$(printf '%s' "$s" | tr ',' '\n' | grep -c '[0-9]')
   if [ "$n" -le 8 ]; then echo "$s"; else
      echo "$(printf '%s' "$s" | cut -d, -f1-8)...외$((n-8))개"
   fi
}

# =====================================================================
#  대상 런 목록
# =====================================================================
enumerate_runs() {
   local r rp
   {
      for r in "${ROOT_ARR[@]}"; do
         [ -d "$r" ] || continue
         ls -1U "$r" 2>/dev/null | grep -E '^[0-9]{6}$'
      done
      for rp in "${!DB_ONL[@]}"; do
         [ "${DB_ONL[$rp]}" = "0" ] && printf '%06d\n' "$rp"
      done
   } | sort -u | sed 's/^0*//' | sort -n | uniq
}

filter_runs() {          # stdin: 런 번호
   local n
   while read -r n; do
      [ -n "$n" ] || continue
      [ -n "$FROM" ] && [ "$n" -lt "$FROM" ] && continue
      [ -n "$TO" ]   && [ "$n" -gt "$TO" ]   && continue
      echo "$n"
   done
}

# =====================================================================
#  훑기
# =====================================================================
FOUND=0
scan() {
   local list n rp total=0 seen=0
   load_hb
   load_db
   if [ -n "$RUNS" ]; then
      list=$(printf '%s\n' $RUNS | filter_runs)
   else
      list=$(enumerate_runs | filter_runs)
   fi
   total=$(printf '%s\n' "$list" | grep -c '[0-9]')
   logt "${C_C}훑는 중${C_0} : 런 $total 개  (roots=$ROOTS)"
   : > "$TMP/found.tsv"
   for n in $list; do
      seen=$((seen+1))
      if [ "$QUIET" -eq 0 ] && [ $((seen % 200)) -eq 0 ]; then
         printf '  ... %d/%d\n' "$seen" "$total" >&2
      fi
      unset OPENOK; declare -A OPENOK
      if classify "$n"; then
         rp=$(printf '%06d' "$n")
         printf '%s\t%s\t%s\t%s\n' "$n" "$R_CAT" "$(short_subs "$R_SUBS")" "$R_MEMO" >> "$TMP/found.tsv"
         printf '%s\n' "$R_QUAR" | grep -v '^$' > "$TMP/quar.$n" 2>/dev/null || true
         FOUND=$((FOUND+1))
      fi
   done
   logt "${C_C}끝${C_0} : 문제 런 ${FOUND} 개 / 훑은 런 ${total} 개"
}

print_found() {
   [ -s "$TMP/found.tsv" ] || { log "  문제 런이 없다."; return; }
   log ""
   printf '  %-6s %-22s %-22s %s\n' "run" "범주" "서브런" "메모"
   printf '  %s\n' "$(printf '%.0s-' $(seq 1 100))"
   awk -F'\t' '{printf "  %-6s %-22s %-22s %s\n",$1,$2,$3,substr($4,1,120)}' "$TMP/found.tsv"
   log ""
   log "  범주별 :"
   awk -F'\t' '{print $2}' "$TMP/found.tsv" | sort | uniq -c | sort -rn | sed 's/^/    /'
}

# =====================================================================
#  목록 파일
#    이미 있는 줄은 분류일시를 보존한다. 매번 오늘 날짜로 덮으면
#    '언제부터 문제였나'를 잃는다.
# =====================================================================
#  목록이 631 줄쯤 되면 열어도 '한눈에' 가 아니다. 맨 위에 범주별 수와
#  조치가 필요한 런을 요약해 둔다. 데이터 줄에서 그때그때 계산한다.
list_summary() {         # 데이터줄 파일
   local f=$1 n
   n=$(grep -c '^  [0-9]' "$f" 2>/dev/null || echo 0)
   echo "# ── 요약 ─────────────────────────────────────────────────────────"
   echo "#  문제 런 $n 개"
   #  줄 모양 : run  YYYY-MM-DD HH:MM:SS  범주  서브런  메모
   #  분류일시가 두 토큰이므로 범주는 $4 다. $3 으로 세면 시각이 세어진다.
   awk '{print $4}' "$f" 2>/dev/null | sort | uniq -c | sort -rn \
      | awk '{printf "#    %-24s %4d\n", $2, $1}'
   echo "#"
   echo "#  ★ 사람이 손볼 것 — 원본이 죽어 격리가 필요하거나 이미 격리한 런"
   awk '$4 ~ /truncated_tail/ {printf "#    run %-6s %-24s %s\n", $1, $4, $5}' "$f" 2>/dev/null | head -30
   echo "# ─────────────────────────────────────────────────────────────────"
   echo "#"
}

list_header() {
      echo "# RENE DAQ badrun list — 문제가 있었던 런 전부. 한 줄에 한 런. 런 번호 오름차순."
      echo "#"
      echo "# 갱신 : scripts/badrun.sh --scan --update-list"
      echo "# 사본 : docs/BADRUNS.md  (scripts/badrun.sh --export)"
      echo "# 생성 : $(ts)"
      echo "#"
      echo "# 범주"
      echo "#   boot_failed     부팅 실패. 런이 시작되지 못했고 데이터가 없다"
      echo "#   aborted         시작은 했으나 마감하지 못했다 (onlbit=0)"
      echo "#   truncated_tail  원시 파일이 쓰기 도중 잘려 ROOT 가 열지 못한다."
      echo "#                   그 파일들은 <런>/badrun/ 으로 격리했다"
      echo "#   prd_gap         원본은 멀쩡한데 PRD 가 빈다. 재처리하면 된다"
      echo "#   not_processed   원본은 있는데 로컬에 PRD 가 하나도 없다. 후처리를 안 했거나"
      echo "#                   산출물이 이 PC 에 없다 (경희대에는 있을 수 있다)"
      echo "#   no_data         런 디렉터리는 있으나 안이 비었다"
      echo "#"
      echo "# 앞 네 필드는 고정, 나머지 전부가 메모다.  awk '{print \$1,\$2}' 로 뽑힌다."
      echo "#"
      printf '# %-4s %-19s %-22s %-22s %s\n' "run" "분류일시" "범주" "서브런" "메모"
}

write_list() {
   local out="$TMP/list.new" n cat subs memo when
   declare -A OLDWHEN
   if [ -r "$LIST" ]; then
      while read -r n when1 when2 rest; do
         case "$n" in ''|'#'*) continue ;; esac
         OLDWHEN[$n]="$when1 $when2"
      done < "$LIST"
   fi
   while IFS=$'\t' read -r n cat subs memo; do
      when=${OLDWHEN[$n]:-$(ts)}
      printf '  %-4s %-19s %-22s %-22s %s\n' "$n" "$when" "$cat" "$subs" "$memo"
   done < "$TMP/found.tsv" | sort -k1,1n > "$TMP/data.txt"
   { list_header; list_summary "$TMP/data.txt"; cat "$TMP/data.txt"; } > "$out"
   local d; d=$(dirname "$LIST"); [ -d "$d" ] || mkdir -p "$d" || die "목록 디렉터리를 만들 수 없다 : $d"
   if [ "$DRYRUN" -eq 1 ]; then
      logt "${C_C}[DRY]${C_0} 목록 $(grep -c '^  [0-9]' "$out") 줄 -> $LIST"
      return 0
   fi
   #  같은 파일시스템 안 rename 이라 원자적이다. 읽는 쪽이 반쪽 파일을 보지 않는다.
   mv -f "$out" "$LIST" || die "목록을 쓰지 못했다 : $LIST"
   logt "${C_G}목록 갱신${C_0} : $LIST  ($(grep -c '^  [0-9]' "$LIST") 런)"
}

#  목록의 일부 런만 다시 쓴다. 나머지 줄은 손대지 않는다.
update_list_for() {      # run_num...
   local n keep="$TMP/keep.txt" out="$TMP/list.new" when
   declare -A OLDWHEN OLDLINE
   if [ -r "$LIST" ]; then
      while read -r a b c rest; do
         case "$a" in ''|'#'*) continue ;; esac
         OLDWHEN[$a]="$b $c"; OLDLINE[$a]="  $a $b $c $rest"
      done < "$LIST"
   fi
   for n in "$@"; do
      unset OPENOK; declare -A OPENOK
      if classify "$n"; then
         when=${OLDWHEN[$n]:-$(ts)}
         OLDLINE[$n]=$(printf '  %-4s %-19s %-22s %-22s %s' "$n" "$when" "$R_CAT" "$(short_subs "$R_SUBS")" "$R_MEMO")
      else
         unset 'OLDLINE[$n]'
      fi
   done
   for n in "${!OLDLINE[@]}"; do printf '%s\n' "${OLDLINE[$n]}"; done | sort -k1,1n > "$TMP/data.txt"
   { list_header; list_summary "$TMP/data.txt"; cat "$TMP/data.txt"; } > "$out"
   mv -f "$out" "$LIST" || die "목록을 쓰지 못했다 : $LIST"
   logt "${C_G}목록 갱신${C_0} : $LIST  ($(grep -c '^  [0-9]' "$LIST") 런)"
}

export_md() {
   [ -r "$LIST" ] || die "목록 파일이 없다 : $LIST  (먼저 --scan --update-list)"
   local out="$TMP/BADRUNS.md"
   {
      echo "# RENE DAQ — badrun 목록"
      echo
      echo "문제가 있었던 런 전부. **이 파일은 생성물이다** — 정본은 현장의"
      echo "\`$LIST\` 이고, \`scripts/badrun.sh --export\` 가 여기로 복사한다."
      echo "손으로 고치지 말 것. 고쳐야 하면 정본을 고치고 다시 내보낼 것."
      echo
      echo "격리된 원시 파일은 \`<런>/badrun/\` 에 있고 \`/data\` · \`/scratch\` ·"
      echo "경희대 서버로 **같은 트리 구조 그대로** 따라간다."
      echo
      echo '```'
      cat "$LIST"
      echo '```'
   } > "$out"
   [ "$DRYRUN" -eq 1 ] && { logt "${C_C}[DRY]${C_0} -> $EXPORT_MD"; return 0; }
   mkdir -p "$(dirname "$EXPORT_MD")"
   mv -f "$out" "$EXPORT_MD" || die "내보내지 못했다 : $EXPORT_MD"
   logt "${C_G}내보냄${C_0} : $EXPORT_MD"
}

# =====================================================================
#  안전 게이트 — 하나라도 걸리면 격리하지 않는다
#    격리는 파일을 옮긴다. 지금 그 런을 읽거나 쓰는 것이 있으면 깨진다.
# =====================================================================
#  ★ 자기 자신과 조상 프로세스를 뺀다. pgrep -af rsync 는 'rsync' 와 런 번호가
#    함께 들어 있는 **호출한 셸의 명령줄**까지 잡아서, 아무것도 안 하고 있는데
#    "rsync 가 이 런을 옮기는 중" 으로 막아 버린다(실측). 그리고 프로그램 이름을
#    줄 맨 앞에서 확인해 bash 래퍼가 걸리지 않게 한다.
proc_touching() {        # 확장정규식
   local pat=$1 mine=" $$ $PPID " p=$PPID i
   for i in 1 2 3 4 5 6; do
      p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
      { [ -n "$p" ] && [ "$p" != 0 ]; } || break
      mine="$mine$p "
   done
   ps -eo pid=,args= 2>/dev/null | while read -r pid args; do
      case "$mine" in *" $pid "*) continue ;; esac
      printf '%s\n' "$args"
   done | grep -Eq "$pat"
}

safe_to_quarantine() {   # run_num run_pad
   local rn=$1 rp=$2
   if [ -n "${HB_RUN:-}" ] && [ "$HB_RUN" -eq "$rn" ]; then
      log "  ${C_R}거부${C_0} : 지금 수집 중인 런이다 (heartbeat run=$HB_RUN)"; return 1
   fi
   if proc_touching "^(/[^ ]*/)?(rsync|ssh) .*(/|^)$rp(/| |$)"; then
      log "  ${C_R}거부${C_0} : rsync/ssh 가 이 런을 옮기거나 보내는 중이다"; return 1
   fi
   if proc_touching "backup-khu\.sh .*--run[= ]+$rn( |,|$)"; then
      log "  ${C_R}거부${C_0} : backup-khu.sh 가 이 런을 보내는 중이다"; return 1
   fi
   if proc_touching "postrun\.sh( .*)? $rn( |$)"; then
      log "  ${C_R}거부${C_0} : postrun.sh 가 이 런을 처리하는 중이다"; return 1
   fi
   return 0
}

quarantine_run() {       # run_num
   local rn=$1 rp bd f n=0 when
   rp=$(printf '%06d' "$rn")
   if ! classify "$rn"; then
      log "  run $rp : 문제 없음. 건너뜀"; return 0
   fi
   if [ -z "$R_QUAR" ]; then
      log "  run $rp : ${C_Y}격리할 파일이 없다${C_0} (범주 $R_CAT). 원본이 전부 열린다 — 재처리 대상이지 badrun 이 아니다"
      return 0
   fi
   local rawdir; rawdir=$(find_raw_dir "$rp") || { log "  run $rp : RAW 를 찾을 수 없다"; return 1; }
   bd="$rawdir/badrun"

   log "${C_C}  run $rp${C_0} : 범주 $R_CAT"
   printf '%s\n' "$R_QUAR" | grep -v '^$' | while read -r f; do
      printf '      %s  (%s bytes)\n' "$(basename "$f")" "$(stat -c %s "$f" 2>/dev/null || echo '?')"
   done
   n=$(printf '%s\n' "$R_QUAR" | grep -c '[^[:space:]]')

   if [ "$DRYRUN" -eq 1 ]; then
      log "      ${C_C}[DRY]${C_0} $n 개 -> $bd/"
      return 0
   fi
   safe_to_quarantine "$rn" "$rp" || return 1

   mkdir -p "$bd" || die "badrun 디렉터리를 만들 수 없다 : $bd"
   when=$(ts)
   {
      echo "이 폴더의 파일들은 격리된 것이다. 지우지 말 것."
      echo
      echo "런        : $rp"
      echo "격리 시각 : $when"
      echo "범주      : $R_CAT"
      echo "서브런    : $R_SUBS"
      echo "사유      : $R_MEMO"
      echo
      echo "이 파일들은 런이 쓰기 도중 끝나 제대로 닫히지 않았다. ROOT 가 열지"
      echo "못하므로(no keys recovered) merge 도 production 도 할 수 없다."
      echo "런 디렉터리 최상위에 두면 dataflow 의 is_processed() 가 'PRD 개수 =="
      echo "FADC 개수' 를 영원히 만족하지 못해 그 런이 옮겨지지 않는다."
      echo "그래서 여기로 옮겼다. 원본은 버리지 않는다 — 장애의 증거이고,"
      echo "/data · /scratch · 경희대 서버로 같은 트리 구조 그대로 따라간다."
      echo
      echo "판정 : scripts/badrun.sh --scan"
      echo "목록 : $LIST"
      echo
      echo "격리된 파일"
      printf '%s\n' "$R_QUAR" | grep -v '^$' | while read -r f; do
         printf '  %-34s %12s bytes\n' "$(basename "$f")" "$(stat -c %s "$f" 2>/dev/null || echo '?')"
      done
   } > "$bd/README.txt"

   #  ★ 같은 파일시스템 안의 이름 바꾸기다. CLAUDE.md §8 이 명시한 예외 —
   #    자료가 움직이지 않는 원자적 연산이라 rsync + 체크섬 절차가 필요 없다.
   local moved=0
   while read -r f; do
      [ -n "$f" ] || continue
      [ -f "$f" ] || continue
      mv -n -T "$f" "$bd/$(basename "$f")" || { log "  ${C_R}실패${C_0} : $f"; return 1; }
      moved=$((moved+1))
   done < <(printf '%s\n' "$R_QUAR" | grep -v '^$')
   log "      ${C_G}격리 완료${C_0} : $moved 개 -> $bd/"
   TOUCHED=$((TOUCHED+1))
   return 0
}

# =====================================================================
#  main
# =====================================================================
case "$MODE" in
   export)
      export_md
      ;;
   scan)
      scan
      print_found
      [ "$UPDATE" -eq 1 ] && write_list
      ;;
   quarantine)
      [ -n "$RUNS" ] || [ -n "$FROM" ] || die "--quarantine 은 --run 또는 --from/--to 가 필요하다. 전부를 한 번에 옮기지 않는다"
      load_hb
      load_db
      if [ -n "$RUNS" ]; then LIST_RUNS=$(printf '%s\n' $RUNS | filter_runs)
      else LIST_RUNS=$(enumerate_runs | filter_runs); fi
      rc=0; TOUCHED=0
      for n in $LIST_RUNS; do
         unset OPENOK; declare -A OPENOK
         quarantine_run "$n" || rc=1
      done
      #  ★ 격리한 런만 목록에 반영한다. 예전에는 여기서 전체를 다시 훑었는데,
      #    1,972 개 런을 다시 도느라 --quarantine 한 번이 수십 분씩 매달렸다.
      #    다른 줄은 기존 목록에서 그대로 옮겨 온다.
      if [ "$DRYRUN" -eq 0 ] && [ "$TOUCHED" -gt 0 ]; then
         update_list_for $LIST_RUNS
      fi
      exit $rc
      ;;
esac
exit 0
