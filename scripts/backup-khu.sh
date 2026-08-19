#!/usr/bin/env bash
# =====================================================================
#  backup-khu.sh - 끝난 런을 경희대 서버로 rsync 백업한다.
#
#  파일의 '성격'마다 목적지가 다르다. 원격 트리가 이미 그렇게 나뉘어 있고
#  (RAW / PRD / PNG / DAQLOG / config / db), 이 스크립트는 그 관례를 따른다.
#
#     로컬 (기본 --mid /data)                     khu:/store/cpnr-data/RENE
#     ---------------------------------------    -------------------------
#     RAW/<run>/{FADC,SADC}_*.root.*        ──►  RAW/<run>/
#     RAW/<run>/PRD/PRD_*.root              ──►  PRD/<run>/
#     RAW/<run>/PNG/*.png                   ──►  PNG/<run>/
#     LOG/{TCB,FADCDAQ,SADCDAQ}_<run>.log   ──►  DAQLOG/<종류>/<이름>.log.gz
#     CONFIG/<run>.config                   ──►  config/<run>.config
#     <db 파일>                             ──►  db/runcatalog.<날짜>.db
#
#     RAW/<run>/Merged/  는 백업하지 않는다.  ★의도적★
#        런당 115 GB 인데 RAW 로부터 언제든 다시 만들 수 있는 중간 산출물이고,
#        원격 트리에도 Merged 카테고리가 아예 없다(실측 확인).
#        굳이 보내려면 --with-merged 를 줄 것.
#
#  접속
#     ~/.ssh/config 의 'khu' 별칭을 쓴다 -> renecomm@hep.khu.ac.kr:2223, 키 인증.
#     이 계정은 위 7개 디렉터리에 **전부 쓰기 권한이 있다**(실측 확인).
#     비밀번호를 파일에 적지 않는다. 다른 계정을 쓰려면 --host 로 넘길 것.
#
#  진행 표시 / 재개
#     카테고리마다 성공하면 <mid>/RAW/<run>/.backup_done 에 한 줄을 남긴다.
#       RAW 2026-08-18 01:23:45 2880
#     다시 실행하면 이미 끝난 카테고리는 건너뛴다. 전송이 끊겨도 --partial-dir
#     로 이어받고, 잘린 파일이 최종 이름을 차지하는 일이 없다.
#
#  사용
#     scripts/backup-khu.sh --run 4290 --dry-run     무엇을 보낼지만 확인
#     scripts/backup-khu.sh --run 4290               한 런 백업
#     scripts/backup-khu.sh --all                    백업 안 된 런 전부
#     scripts/backup-khu.sh --db-only                런 카탈로그만
#     scripts/backup-khu.sh --run 4290 --only PRD,PNG
# =====================================================================
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)

# ---- 기본값 (config/dataflow.params 로 덮어쓸 수 있다) ---------------
MID=${DATAFLOW_MID_ROOT:-/data}          # 백업 대기 위치. 이 밑에 RAW/LOG/CONFIG
HOST=${BACKUP_HOST:-khu}                 # ssh 별칭 또는 user@host
DEST=${BACKUP_DEST:-/store/cpnr-data/RENE}
DBFILE=${BACKUP_DBFILE:-/Data_ssd/runcatalog.db}
DATA_SRC=${BACKUP_DATA_SRC:-}            # 원격 Data/ 로 보낼 잡다한 경로. 비우면 안 함
BWLIMIT=${BACKUP_BWLIMIT:-0}             # KB/s. 0 = 제한 없음
NICE=${BACKUP_NICE:-10}
PARAMS=""

CATS_ALL="RAW PRD PNG DAQLOG config db Data"
CATS_DEF="RAW PRD PNG DAQLOG config db"  # Data 는 DATA_SRC 가 있을 때만
ONLY=""; SKIP=""
RUNS=""; ALL=0; DBONLY=0; DRYRUN=0; WITH_MERGED=0; FORCE=0; QUIET=0
VERIFY=${BACKUP_VERIFY:-1}   # 보낸 뒤 체크섬으로 대조한다. 0 이면 개수만 본다

C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'; C_C='\033[1;36m'; C_0='\033[0m'
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { [ "$QUIET" -eq 1 ] || printf '[%s] %b\n' "$(ts)" "$*"; }
warn() { printf '[%s] %b\n' "$(ts)" "${C_Y}$*${C_0}"; }
err()  { printf '[%s] %b\n' "$(ts)" "${C_R}$*${C_0}"; }
die()  { err "[FATAL] $*"; exit 1; }

usage() { sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; cat <<EOF

옵션
  --run N            런 하나 (여러 번 줄 수 있다)
  --all              --mid 밑에서 아직 백업 안 된 런을 전부
  --db-only          런 카탈로그 DB 만 보낸다
  --no-verify        보낸 뒤 체크섬 대조를 건너뛴다 (개수만 확인)
  --only  A,B        이 카테고리만   (${CATS_ALL// /,})
  --skip  A,B        이 카테고리 제외
  --with-merged      Merged 도 보낸다 (런당 +115 GB. 기본은 보내지 않는다)
  --force            .backup_done 을 무시하고 다시 보낸다
  --host  H          ssh 별칭 또는 user@host          (${HOST})
  --dest  DIR        원격 최상위                      (${DEST})
  --mid   DIR        로컬 원본 최상위                 (${MID})
  --dbfile F         런 카탈로그 DB                   (${DBFILE})
  --bwlimit KB/s     rsync 대역 제한. 0 = 무제한      (${BWLIMIT})
  --params FILE      config/dataflow.params 형식 설정 파일
  --dry-run          무엇을 보낼지만 출력
  --quiet            요약만
  -h, --help
EOF
}

# ---- config/dataflow.params 파서 -------------------------------------
#  'key = value' 형식. rcterm.params 와 같은 모양으로 맞췄다.
#  eval 을 쓰지 않고 아는 키만 case 로 받는다.
load_params() {
   local f=$1 line k v
   [ -r "$f" ] || die "설정 파일을 읽을 수 없다 : $f"
   while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      case "$line" in *=*) ;; *) continue ;; esac
      k=${line%%=*}; v=${line#*=}
      k=$(printf '%s' "$k" | tr -d ' \t' | tr 'a-z-' 'A-Z_')
      v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [ -n "$k" ] || continue
      case "$k" in
         MID_ROOT|MID)   MID=$v ;;
         BACKUP_HOST)    HOST=$v ;;
         BACKUP_DEST)    DEST=$v ;;
         BACKUP_DBFILE)  DBFILE=$v ;;
         BACKUP_DATA_SRC) DATA_SRC=$v ;;
         BACKUP_BWLIMIT) BWLIMIT=$v ;;
         BACKUP_SKIP)    SKIP=$v ;;
         NICE)           NICE=$v ;;
         *)              : ;;   # dataflow.sh 전용 키는 여기서 무시한다
      esac
   done < "$f"
}

# --params 는 위치 기반이다(§5.6 과 같은 규칙). 뒤에 오는 것이 이긴다.
while [ $# -gt 0 ]; do
   case "$1" in
      --params)       PARAMS=$2; load_params "$2"; shift 2 ;;
      --run)          RUNS="$RUNS $2"; shift 2 ;;
      --all)          ALL=1; shift ;;
      --db-only)      DBONLY=1; shift ;;
      --verify)       VERIFY=1; shift ;;
      --no-verify)    VERIFY=0; shift ;;
      --only)         ONLY=$(printf '%s' "$2" | tr ',' ' '); shift 2 ;;
      --skip)         SKIP=$(printf '%s' "$2" | tr ',' ' '); shift 2 ;;
      --with-merged)  WITH_MERGED=1; shift ;;
      --force)        FORCE=1; shift ;;
      --host)         HOST=$2; shift 2 ;;
      --dest)         DEST=$2; shift 2 ;;
      --mid)          MID=$2; shift 2 ;;
      --dbfile)       DBFILE=$2; shift 2 ;;
      --bwlimit)      BWLIMIT=$2; shift 2 ;;
      --nice)         NICE=$2; shift 2 ;;
      --dry-run)      DRYRUN=1; shift ;;
      --quiet)        QUIET=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      *)              echo "unknown option : $1" >&2; usage; exit 1 ;;
   esac
done

command -v rsync >/dev/null || die "rsync 가 필요하다"
command -v ssh   >/dev/null || die "ssh 가 필요하다"

SKIP=$(printf '%s' "$SKIP" | tr ',' ' ')

RSH="ssh -o BatchMode=yes -o ConnectTimeout=20"
RSYNC_BASE="-a --partial-dir=.rsync-partial --mkpath"
[ "$BWLIMIT" != "0" ] && RSYNC_BASE="$RSYNC_BASE --bwlimit=$BWLIMIT"
[ "$QUIET" -eq 1 ] || RSYNC_BASE="$RSYNC_BASE --info=progress2"
VERIFY_C=""; [ "$VERIFY" -eq 1 ] && VERIFY_C="-c"   # 파일 하나짜리는 전송에 바로 붙인다

pad6() { printf '%06d' "$((10#$1))"; }

want_cat() {             # 카테고리 이름
   local c=$1 x
   for x in $SKIP;  do [ "$x" = "$c" ] && return 1; done
   if [ -n "$ONLY" ]; then
      for x in $ONLY; do [ "$x" = "$c" ] && return 0; done
      return 1
   fi
   return 0
}

# ---- 접속 확인 -------------------------------------------------------
#  키 인증이 안 되면 rsync 가 런마다 매달린다. 시작할 때 한 번에 걸러낸다.
check_host() {
   local out
   out=$($RSH "$HOST" "test -d '$DEST' && echo OK-$(id -un 2>/dev/null)" 2>&1) || {
      err "[FATAL] $HOST 접속 실패. ssh 키와 ~/.ssh/config 를 확인할 것"
      err "        $out"
      return 1
   }
   case "$out" in
      OK*) log "백업 대상 ${C_C}${HOST}:${DEST}${C_0} 접속 확인" ;;
      *)   err "[FATAL] $HOST 에 $DEST 가 없다 : $out"; return 1 ;;
   esac
   return 0
}

# ---- 진행 기록 -------------------------------------------------------
marker_of() { echo "$MID/RAW/$1/.backup_done"; }

cat_done() {             # run_pad cat  -> 0 이면 이미 끝났다
   [ "$FORCE" -eq 1 ] && return 1
   local m; m=$(marker_of "$1")
   [ -f "$m" ] && grep -q "^$2 " "$m"
}
mark_cat() {             # run_pad cat n
   [ "$DRYRUN" -eq 1 ] && return 0
   local m; m=$(marker_of "$1")
   mkdir -p "$(dirname "$m")" 2>/dev/null
   sed -i "/^$2 /d" "$m" 2>/dev/null
   printf '%s %s %s\n' "$2" "$(ts)" "$3" >> "$m"
}

# ---- 원격 개수 세기 (전송 검증) --------------------------------------
remote_count() {         # 원격 디렉터리
   $RSH "$HOST" "ls -1 '$1' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'
}

# ---- 체크섬 대조 ------------------------------------------------------
#  왜 개수로 부족한가 : rsync 는 자기가 보낸 파일은 검사하지만, 이미 원격에
#  있던 파일(예전에 끊긴 전송의 잔재)은 크기·시각만 같으면 손대지 않는다.
#  원본을 지울 것이므로 내용까지 대조한다.
#
#  -c -n -i 로 다시 훑으면 rsync 가 양쪽에서 각자 체크섬을 계산해 결과만
#  주고받는다. 링크 부담은 작고 비싼 것은 디스크 읽기다. 차이가 있는 파일만
#  한 줄씩 나오므로, 나온 줄이 0 이면 내용이 같다는 뜻이다.
verify_dir() {           # 이름표 로컬디렉터리 원격상대경로 [추가 rsync 인자...]
   local what=$1 src=$2 rel=$3; shift 3
   local out rc n_diff
   log "  $what : 체크섬 대조 중..."
   # shellcheck disable=SC2086
   out=$(nice -n "$NICE" rsync -a -c -n -i "$@" -e "$RSH" \
         "$src"/ "$HOST:$DEST/$rel"/ 2>&1); rc=$?
   if [ "$rc" -ne 0 ]; then
      err "  $what : 체크섬 대조 실행 실패 (rc=$rc). 미완료로 둔다"
      return 1
   fi
   #  '>f' = 원격으로 보내야 할 파일, '<f' = 받아야 할 파일, '*deleting' = 여분.
   #  디렉터리(.d, cd)와 시각만 다른 것은 내용이 같으므로 세지 않는다.
   n_diff=$(printf '%s\n' "$out" | grep -cE '^[<>]f|^\*deleting') || true
   if [ "${n_diff:-0}" -ne 0 ]; then
      err "  $what : 체크섬 불일치 $n_diff 개. 원본을 지우면 안 된다"
      printf '%s\n' "$out" | grep -E '^[<>]f|^\*deleting' | head -10 | sed 's/^/      /'
      return 1
   fi
   log "  ${C_G}$what${C_0} : 체크섬 일치"
   return 0
}

# ---- 한 덩어리 전송 --------------------------------------------------
#  성공하면 로컬 개수를 돌려주고 0, 실패하면 1.
push_dir() {             # 이름표 로컬디렉터리 원격상대경로 [추가 rsync 인자...]
   local what=$1 src=$2 rel=$3; shift 3
   local n_src n_dst rc
   # -L 로 심볼릭 링크를 따라간다. 예전 --outroot 구성에서는 RAW/<run>/PRD 가
   # /Data_ssd 를 가리키는 링크다. 안 따라가면 '파일 없음'으로 건너뛴다(실측).
   #  ★ 점파일을 빼고 센다. 호출자가 모두 --exclude='.*' 를 주므로 rsync 는
   #     점파일을 보내지 않는데, 여기서 세면 원격보다 항상 하나 많아진다.
   #     하필 그 점파일이 이 스크립트가 만드는 마커(.backup_done)라, 두 번째
   #     카테고리부터 "원격 개수 부족" 으로 매번 실패했다 (run 4290/4291 실측:
   #     400/401, 1740/1741 — 실제로는 전부 전송돼 있었다).
   n_src=$(find -L "$src" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l)
   if [ "$n_src" -eq 0 ]; then
      log "  $what : 파일 없음, 건너뜀"
      return 2
   fi
   log "  ${C_C}$what${C_0} : ${n_src} 개 -> $HOST:$DEST/$rel/"
   if [ "$DRYRUN" -eq 1 ]; then
      log "    [DRY] rsync $* $src/ $HOST:$DEST/$rel/"
      echo "$n_src" > /dev/null
      LAST_N=$n_src
      return 0
   fi
   # shellcheck disable=SC2086
   nice -n "$NICE" rsync $RSYNC_BASE "$@" -e "$RSH" \
        "$src"/ "$HOST:$DEST/$rel"/ 2>&1 | tail -1 | sed 's/^/    /'
   rc=${PIPESTATUS[0]}
   if [ "$rc" -ne 0 ]; then
      err "  $what : rsync 실패 (rc=$rc). 다음 주기에 재시도"
      return 1
   fi
   n_dst=$(remote_count "$DEST/$rel")
   if [ -z "$n_dst" ] || [ "$n_dst" -lt "$n_src" ]; then
      err "  $what : 원격 개수 부족 ($n_dst / $n_src). 미완료로 둔다"
      return 1
   fi
   #  개수가 맞아도 내용이 같다는 보장은 없다. 원본을 지울 것이므로 대조한다.
   if [ "$VERIFY" -eq 1 ]; then
      verify_dir "$what" "$src" "$rel" "$@" || return 1
   fi
   log "  ${C_G}$what${C_0} : 완료 (원격 $n_dst 개)"
   LAST_N=$n_src
   return 0
}

# =====================================================================
#  카테고리별 백업
# =====================================================================

# RAW : 런 디렉터리 최상위의 FADC/SADC 파일만. Merged/PRD/PNG 는 각자 카테고리다.
bk_RAW() {               # run_pad
   local rp=$1 src="$MID/RAW/$1"
   [ -d "$src" ] || { log "  RAW : $src 없음, 건너뜀"; return 2; }
   # 슬래시를 붙이지 않는다. 예전 구성에서 Merged/PRD 는 디렉터리가 아니라
   # 심볼릭 링크라서 '/PRD/' 로는 걸러지지 않고 깨진 링크가 원격에 생긴다.
   local ex=(--exclude='/Merged' --exclude='/PRD' --exclude='/PNG' --exclude='.*')
   [ "$WITH_MERGED" -eq 1 ] && ex=(--exclude='/PRD' --exclude='/PNG' --exclude='.*')
   push_dir "RAW" "$src" "RAW/$rp" "${ex[@]}"
}

bk_PRD() {               # run_pad
   local rp=$1 src="$MID/RAW/$1/PRD"
   [ -d "$src" ] || { log "  PRD : $src 없음, 건너뜀"; return 2; }
   push_dir "PRD" "$src" "PRD/$rp" --exclude='.*'
}

bk_PNG() {               # run_pad
   local rp=$1 src="$MID/RAW/$1/PNG"
   [ -d "$src" ] || { log "  PNG : $src 없음, 건너뜀"; return 2; }
   push_dir "PNG" "$src" "PNG/$rp" --exclude='.*'
}

# DAQLOG : 원격은 종류별 디렉터리에 .log.gz 로 쌓여 있다(실측).
#  원본 로그를 그 자리에서 압축하지 않는다 — /scratch 쪽 관례가 평문이고,
#  나중에 사람이 tail 로 열어 보는 파일이기 때문이다. 보낼 것만 임시로 만든다.
bk_DAQLOG() {            # run_pad
   local rp=$1 kind f stage n=0 rc any=0
   for kind in TCB FADCDAQ SADCDAQ; do
      f="$MID/LOG/${kind}_${rp}.log"
      [ -f "$f" ] || continue
      any=1
      stage=$(mktemp -d "${TMPDIR:-/tmp}/bkgz.XXXXXX") || return 1
      if [ "$DRYRUN" -eq 1 ]; then
         log "    [DRY] gzip $f -> $HOST:$DEST/DAQLOG/$kind/${kind}_${rp}.log.gz"
         rmdir "$stage"; n=$((n+1)); continue
      fi
      gzip -c "$f" > "$stage/${kind}_${rp}.log.gz" 2>/dev/null || {
         err "  DAQLOG : $f 압축 실패"; rm -rf "$stage"; return 1; }
      # shellcheck disable=SC2086
      nice -n "$NICE" rsync $RSYNC_BASE -e "$RSH" \
           "$stage"/ "$HOST:$DEST/DAQLOG/$kind"/ >/dev/null 2>&1
      rc=$?
      [ "$rc" -ne 0 ] && { rm -rf "$stage"; err "  DAQLOG/$kind : rsync 실패 (rc=$rc)"; return 1; }
      #  대조가 끝난 뒤에 스테이지를 지운다. 먼저 지우면 대조할 원본이 없다.
      if [ "$VERIFY" -eq 1 ]; then
         verify_dir "DAQLOG/$kind" "$stage" "DAQLOG/$kind" || { rm -rf "$stage"; return 1; }
      fi
      rm -rf "$stage"
      n=$((n+1))
   done
   [ "$any" -eq 0 ] && { log "  DAQLOG : ${MID}/LOG 에 run $rp 로그 없음, 건너뜀"; return 2; }
   log "  ${C_G}DAQLOG${C_0} : 완료 ($n 종)"
   LAST_N=$n
   return 0
}

bk_config() {            # run_pad
   local rp=$1 f="$MID/CONFIG/${rp}.config" rc
   [ -f "$f" ] || { log "  config : $f 없음, 건너뜀"; return 2; }
   if [ "$DRYRUN" -eq 1 ]; then
      log "    [DRY] rsync $f $HOST:$DEST/config/"; LAST_N=1; return 0
   fi
   # shellcheck disable=SC2086
   nice -n "$NICE" rsync $RSYNC_BASE $VERIFY_C -e "$RSH" "$f" "$HOST:$DEST/config"/ >/dev/null 2>&1
   rc=$?
   [ "$rc" -ne 0 ] && { err "  config : rsync 실패 (rc=$rc)"; return 1; }
   log "  ${C_G}config${C_0} : ${rp}.config 완료"
   LAST_N=1
   return 0
}

# db : 살아있는 sqlite 파일을 그대로 복사하면 쓰기 도중의 반쪽 상태가 갈 수 있다.
#  sqlite3 .backup 은 잠금을 잡고 일관된 스냅샷을 뜬다. 원격 이름은 날짜를 붙여
#  기존 관례(runcatalog.<YYYY-MM-DD>.db)를 따른다.
bk_db() {
   local tmp rc name
   [ -f "$DBFILE" ] || { log "  db : $DBFILE 없음, 건너뜀"; return 2; }
   name="runcatalog.$(date '+%Y-%m-%d').db"
   if [ "$DRYRUN" -eq 1 ]; then
      log "    [DRY] sqlite3 .backup $DBFILE -> $HOST:$DEST/db/$name"; LAST_N=1; return 0
   fi
   tmp=$(mktemp "${TMPDIR:-/tmp}/runcatalog.XXXXXX.db") || return 1
   if command -v sqlite3 >/dev/null 2>&1; then
      sqlite3 "$DBFILE" ".backup '$tmp'" 2>/dev/null || {
         warn "  db : sqlite3 .backup 실패. 파일 복사로 대체한다"
         cp -f "$DBFILE" "$tmp" || { rm -f "$tmp"; return 1; }; }
   else
      cp -f "$DBFILE" "$tmp" || { rm -f "$tmp"; return 1; }
   fi
   # mktemp 는 0600 으로 만든다. 그대로 보내면 원격에서 다른 사람이 못 읽는다.
   chmod 644 "$tmp" 2>/dev/null
   # shellcheck disable=SC2086
   nice -n "$NICE" rsync $RSYNC_BASE $VERIFY_C -e "$RSH" "$tmp" "$HOST:$DEST/db/$name" >/dev/null 2>&1
   rc=$?
   rm -f "$tmp"
   [ "$rc" -ne 0 ] && { err "  db : rsync 실패 (rc=$rc)"; return 1; }
   log "  ${C_G}db${C_0} : $name 완료"
   LAST_N=1
   return 0
}

# Data : 원격 Data/ 는 런 단위가 아니라 잡다한 보관함이다. 무엇을 보낼지는
#  사이트가 정해야 하므로 기본은 비활성이고, dataflow.params 에서 지정한다.
bk_Data() {
   [ -n "$DATA_SRC" ] || { log "  Data : BACKUP_DATA_SRC 미설정, 건너뜀"; return 2; }
   [ -e "$DATA_SRC" ] || { warn "  Data : $DATA_SRC 없음, 건너뜀"; return 2; }
   if [ "$DRYRUN" -eq 1 ]; then
      log "    [DRY] rsync $DATA_SRC -> $HOST:$DEST/Data/"; LAST_N=1; return 0
   fi
   # shellcheck disable=SC2086
   nice -n "$NICE" rsync $RSYNC_BASE -e "$RSH" "$DATA_SRC" "$HOST:$DEST/Data"/ 2>&1 \
      | tail -1 | sed 's/^/    /'
   [ "${PIPESTATUS[0]}" -ne 0 ] && { err "  Data : rsync 실패"; return 1; }
   log "  ${C_G}Data${C_0} : 완료"
   LAST_N=1
   return 0
}

# =====================================================================
#  런 하나
#    0 = 필요한 카테고리가 전부 끝났다 (dataflow 3단계로 넘어가도 된다)
#    1 = 하나라도 실패. 다음 주기에 재시도
# =====================================================================
backup_run() {           # run_num
   local rn=$1 rp c rc fail=0 didany=0
   rp=$(pad6 "$rn")
   [ -d "$MID/RAW/$rp" ] || { warn "run $rp : $MID/RAW/$rp 없음. 건너뜀"; return 1; }

   log "${C_C}=== run $rp 백업 -> $HOST:$DEST ===${C_0}"
   for c in $CATS_DEF; do
      want_cat "$c" || continue
      [ "$c" = "db" ] && continue          # db 는 런 단위가 아니다. 아래에서 따로
      if cat_done "$rp" "$c"; then
         log "  $c : 이미 백업됨 (건너뜀)"
         continue
      fi
      LAST_N=0
      "bk_$c" "$rp"; rc=$?
      case $rc in
         0) mark_cat "$rp" "$c" "$LAST_N"; didany=1 ;;
         2) mark_cat "$rp" "$c" "0" ;;     # 보낼 것이 없다. 끝난 것으로 본다
         *) fail=1 ;;
      esac
   done

   if [ "$fail" -eq 0 ]; then
      log "${C_G}=== run $rp 백업 완료 ===${C_0}"
      [ "$didany" -eq 0 ] && log "    (새로 보낸 것 없음)"
      return 0
   fi
   err "=== run $rp 백업 미완료. 다음 주기에 재시도 ==="
   return 1
}

# 아직 백업이 안 끝난 런 목록
pending_runs() {
   local rp m c ok
   for rp in $(ls -1 "$MID/RAW" 2>/dev/null | grep -E '^[0-9]{6}$' | sort -n); do
      m=$(marker_of "$rp"); ok=1
      for c in $CATS_DEF; do
         [ "$c" = "db" ] && continue
         want_cat "$c" || continue
         { [ -f "$m" ] && grep -q "^$c " "$m"; } || { ok=0; break; }
      done
      [ "$ok" -eq 0 ] && echo "$((10#$rp))"
   done
}

# =====================================================================
[ -n "$DATA_SRC" ] && CATS_DEF="$CATS_DEF Data"

check_host || exit 1

FAILED=0

if [ "$DBONLY" -eq 1 ]; then
   LAST_N=0; bk_db; exit $?
fi

if [ "$ALL" -eq 1 ]; then
   RUNS=$(pending_runs)
   [ -z "$RUNS" ] && { log "백업할 런이 없다 ($MID/RAW)"; }
fi

[ -z "${RUNS// /}" ] && [ "$ALL" -eq 0 ] && { usage; die "--run 또는 --all 이 필요하다"; }

for r in $RUNS; do
   backup_run "$r" || FAILED=1
done

# db 는 런과 무관하게 하루 한 번 갱신되면 충분하다. 런 백업 뒤에 한 번만 보낸다.
if want_cat db && [ -n "${RUNS// /}" ]; then
   LAST_N=0; bk_db || FAILED=1
fi

exit $FAILED
