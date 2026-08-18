#!/usr/bin/env bash
# =====================================================================
#  dataflow.sh - 런 데이터를 단계별로 옮긴다.
#
#    수집 + 후처리          백업 대기            외부 백업          장기 보관
#    /Data_ssd  ──1──►      /data      ──2──►    khu 서버
#    (로컬 NVMe 3.7T)       (로컬 32T)     └──3──►  /scratch (NFS 140T)
#
#  왜 이렇게 하나
#    * 스토리지(/scratch)로 가는 링크가 100 Mb 다 — 실측 7.7 MB/s. 수집과
#      후처리를 그 위에서 하면 링크가 포화되어 DAQ 기록까지 밀린다.
#      그래서 수집도 후처리도 로컬에서 끝내고, 완료된 런만 한 번에 옮긴다.
#    * 경희대 서버로 가는 길은 **다른 랜카드(1 Gb)** 다 — 실측 15.7 MB/s.
#      그래서 2단계(외부 백업)와 3단계(/scratch 이동)는 서로 대역을 뺏지 않는다.
#    * /Data_ssd 는 3.7T 뿐이라 런 9개면 찬다. **여기가 차면 DAQ 가 멈춘다.**
#      1단계를 제때 돌리는 것이 이 스크립트의 가장 중요한 임무다.
#
#  단계
#    1) ssd → mid    후처리 완료(PRD 개수 == FADC 개수)이고 수집 중이 아닌 런.
#                    RAW 런 디렉터리 + LOG/*<run>* + CONFIG/<run>.config 를 함께
#    2) mid → khu    scripts/backup-khu.sh 가 카테고리별로 rsync
#                    (RAW / PRD / PNG / DAQLOG / config / db)
#    3) mid → nfs    백업이 끝난 런만 /scratch 로. 여기가 최종 보관이다
#
#  안전 규칙
#    * 이동은 rsync -a --remove-source-files. 임시 이름으로 받아 완료 후
#      rename 하므로 끊겨도 잘린 파일이 최종 이름을 차지하지 않는다.
#    * 각 단계는 개수를 확인한 뒤에만 원본을 정리하고 다음으로 넘어간다.
#    * 수집 중인 런은 어느 단계에서도 건드리지 않는다.
#    * 백업이 안 끝난 런은 3단계로 넘어가지 않는다. 순서가 뒤집히면
#      아직 안 보낸 데이터를 느린 NFS 에서 다시 읽어 보내게 된다.
#    * flock 으로 동시 실행을 막는다.
#
#  사용
#    scripts/dataflow.sh --params config/dataflow.params --once --dry-run
#    scripts/dataflow.sh --params config/dataflow.params --once
#    scripts/dataflow.sh --params config/dataflow.params --follow
#    scripts/dataflow.sh --stage 1 --once        특정 단계만
# =====================================================================
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)

# ---- 기본값 ---------------------------------------------------------
SSD=${DATAFLOW_SSD_ROOT:-/Data_ssd}      # 수집·후처리 (rcterm 의 rawdatadir)
MID=${DATAFLOW_MID_ROOT:-/data}          # 백업 대기
NFS=${DATAFLOW_NFS_ROOT:-/scratch}       # 장기 보관
HB=${DAQ_HEARTBEAT:-/Data/LOG/rcterm.hb}
BACKUP_ENABLE=${DATAFLOW_BACKUP:-1}      # 0 이면 2단계를 건너뛴다
KEEP_SSD=${DATAFLOW_KEEP_SSD:-2}         # ssd 에 남길 런 수 (수집 중인 것 포함)
KEEP_MID=${DATAFLOW_KEEP_MID:-0}         # 백업 뒤에도 mid 에 남길 런 수
MINFREE_GB=${DATAFLOW_MINFREE_GB:-700}   # /Data_ssd 여유가 이 아래면 경고
DROP_MERGED=${DATAFLOW_DROP_MERGED:-0}   # 3단계에서 Merged 를 버린다 (기본 아니오)
VERIFY=${DATAFLOW_VERIFY:-1}             # 지우기 전에 체크섬으로 대조한다 (CLAUDE.md §8)
POLL=${DATAFLOW_POLL:-600}
NICE=${DATAFLOW_NICE:-10}
BACKUP_SH=$REPO/scripts/backup-khu.sh
PARAMS=""

STAGE=0; ONCE=0; FOLLOW=0; DRYRUN=0
LOCK=/tmp/.dataflow.$(id -u).lock

C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'; C_C='\033[1;36m'; C_0='\033[0m'
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %b\n' "$(ts)" "$*"; }
die() { log "${C_R}[FATAL]${C_0} $*"; exit 1; }

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; cat <<EOF

옵션
  --params FILE        설정 파일 (config/dataflow.params)
  --once / --follow    한 바퀴 / 계속 (${POLL}초 주기)
  --stage N            1, 2, 3 중 하나만 수행
  --ssd DIR            수집·후처리 최상위        (${SSD})
  --mid DIR            백업 대기 최상위          (${MID})
  --nfs DIR            장기 보관 최상위          (${NFS})
  --no-backup          2단계(외부 백업)를 건너뛴다. 3단계는 바로 진행한다
  --keep-ssd N         ssd 에 남길 런 수         (${KEEP_SSD})
  --keep-mid N         백업 뒤 mid 에 남길 런 수 (${KEEP_MID})
  --drop-merged        3단계에서 Merged 를 옮기지 않고 지운다.
                       런당 115 GB 이고 RAW 에서 다시 만들 수 있다.
                       **데이터를 지우는 옵션이므로 기본은 꺼져 있다**
  --min-free-gb N      /Data_ssd 경고 임계 [GB]  (${MINFREE_GB})
  --poll SEC           --follow 주기            (${POLL})
  --heartbeat FILE     rcterm heartbeat         (${HB})
  --dry-run            무엇을 할지만 출력
  -h, --help
EOF
}

# ---- 설정 파일 파서 ('key = value') ----------------------------------
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
         SSD_ROOT|SSD)   SSD=$v ;;
         MID_ROOT|MID)   MID=$v ;;
         NFS_ROOT|NFS)   NFS=$v ;;
         HEARTBEAT)      HB=$v ;;
         KEEP_SSD)       KEEP_SSD=$v ;;
         KEEP_MID)       KEEP_MID=$v ;;
         MIN_FREE_GB)    MINFREE_GB=$v ;;
         DROP_MERGED)    DROP_MERGED=$v ;;
         VERIFY|verify)  VERIFY=$v ;;
         POLL)           POLL=$v ;;
         NICE)           NICE=$v ;;
         BACKUP_ENABLE)  BACKUP_ENABLE=$v ;;
         *)              : ;;   # backup-khu.sh 전용 키는 여기서 무시한다
      esac
   done < "$f"
}

while [ $# -gt 0 ]; do
   case "$1" in
      --params)       PARAMS=$2; load_params "$2"; shift 2 ;;
      --once)         ONCE=1; shift ;;
      --follow)       FOLLOW=1; shift ;;
      --stage)        STAGE=$2; shift 2 ;;
      --ssd)          SSD=$2; shift 2 ;;
      --mid)          MID=$2; shift 2 ;;
      --nfs)          NFS=$2; shift 2 ;;
      --no-backup)    BACKUP_ENABLE=0; shift ;;
      --keep-ssd)     KEEP_SSD=$2; shift 2 ;;
      --keep-mid)     KEEP_MID=$2; shift 2 ;;
      --drop-merged)  DROP_MERGED=1; shift ;;
      --no-verify)    VERIFY=0; shift ;;   # ★권장하지 않는다★
      --verify)       VERIFY=1; shift ;;
      --min-free-gb)  MINFREE_GB=$2; shift 2 ;;
      --poll)         POLL=$2; shift 2 ;;
      --heartbeat)    HB=$2; shift 2 ;;
      --dry-run)      DRYRUN=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      *)              echo "unknown option : $1" >&2; usage; exit 1 ;;
   esac
done

command -v rsync >/dev/null || die "rsync 가 필요하다"
[ "$BACKUP_ENABLE" = "1" ] && [ ! -x "$BACKUP_SH" ] && die "실행할 수 없다 : $BACKUP_SH"

hb_field() { [ -r "$HB" ] && grep -m1 "^$1=" "$HB" 2>/dev/null | cut -d= -f2- ; }
hb_age()   { local t; t=$(hb_field time); [ -n "$t" ] && echo $(( $(date +%s) - t )) || echo 999999; }
runs_in()  { ls -1 "$1" 2>/dev/null | grep -E '^[0-9]{6}$' | sort -n; }
free_gb()  { df --output=avail -BG "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }
size_gb()  { du -s -BG "$1" 2>/dev/null | cut -f1 | tr -dc '0-9'; }

# 지금 수집 중인 런인가. heartbeat 가 살아 있고 run 이 같으면 손대지 않는다.
is_acquiring() {          # run_pad
   local r; r=$(hb_field run)
   [ -n "$r" ] && [ "$(printf '%06d' "$r")" = "$1" ] && [ "$(hb_age)" -lt 120 ]
}

# 후처리가 끝났는가 — PRD 개수 == FADC 개수 이고 0 이 아니다.
#  postrun.sh 의 완료 판정과 같은 기준이다(PRD 파일 존재 = production SUCCESS).
is_processed() {          # run_dir
   local f p
   f=$(find -L "$1" -maxdepth 1 -name 'FADC_*.root.*' 2>/dev/null | wc -l)
   p=$(find -L "$1/PRD" -maxdepth 1 -name '*.root' 2>/dev/null | wc -l)
   [ "$f" -gt 0 ] && [ "$p" -eq "$f" ]
}

# 예전 --outroot 구성이 남긴 심볼릭 링크가 있으면 통째로 옮길 수 없다.
#  rsync -a 는 링크를 링크째 복사하므로 목적지에서 깨진 링크가 된다.
has_symlink_subdir() {    # run_dir
   local s
   for s in Merged PRD PNG; do [ -L "$1/$s" ] && return 0; done
   return 1
}

# ---------------------------------------------------------------------
#  디렉터리 통째 이동. rsync 로 옮기고 개수를 확인한 뒤 빈 디렉터리를 지운다.
# ---------------------------------------------------------------------
move_dir() {              # src dst 이름표 [추가 rsync 인자...]
   local src=$1 dst=$2 what=$3; shift 3
   local n_src n_dst need avail rc
   n_src=$(find "$src" -type f 2>/dev/null | wc -l)
   [ "$n_src" -eq 0 ] && { log "  $what : 파일 없음, 건너뜀"; return 0; }

   need=$(size_gb "$src"); avail=$(free_gb "$(dirname "$dst")")
   if [ -n "$need" ] && [ -n "$avail" ] && [ "$avail" -lt "$((need + 50))" ]; then
      log "${C_R}  $what : 목적지 여유 부족 (필요 ${need}G / 여유 ${avail}G)${C_0}"
      return 1
   fi

   log "${C_C}  $what${C_0} : ${n_src} 파일 / 약 ${need:-?}G  $src -> $dst"
   [ "$DRYRUN" -eq 1 ] && { log "    [DRY] rsync -a --remove-source-files $src/ $dst/"; return 0; }

   mkdir -p "$dst" || return 1

   #  ★ 세 걸음으로 나눈다 : 보낸다 -> 체크섬으로 대조한다 -> 그제서야 지운다.
   #     예전에는 --remove-source-files 로 보내면서 지웠는데, 그러면 내용이
   #     깨졌는지 알기 전에 원본이 사라진다 (CLAUDE.md §8).
   # shellcheck disable=SC2086
   nice -n "$NICE" rsync -a --partial-dir=.rsync-partial \
        --info=progress2 "$@" "$src"/ "$dst"/ 2>&1 | tail -1 | sed 's/^/    /'
   rc=${PIPESTATUS[0]}
   if [ "$rc" -ne 0 ]; then
      log "${C_R}  $what : rsync 실패 (rc=$rc). 원본을 남긴다${C_0}"
      return 1
   fi

   n_dst=$(find "$dst" -type f 2>/dev/null | wc -l)
   if [ "$n_dst" -lt "$n_src" ]; then
      log "${C_R}  $what : 불완전 ($n_dst / $n_src). 원본을 남긴다${C_0}"
      return 1
   fi

   #  대조. -c -n -i 는 양쪽에서 각자 체크섬을 계산해 다른 파일만 한 줄씩 낸다.
   if [ "$VERIFY" = "1" ]; then
      local out n_diff
      log "    체크섬 대조 중 ($n_src 개)..."
      # shellcheck disable=SC2086
      out=$(nice -n "$NICE" rsync -a -c -n -i "$@" "$src"/ "$dst"/ 2>&1) || {
         log "${C_R}  $what : 체크섬 대조 실행 실패. 원본을 남긴다${C_0}"; return 1; }
      n_diff=$(printf '%s\n' "$out" | grep -cE '^[<>]f|^\*deleting') || true
      if [ "${n_diff:-0}" -ne 0 ]; then
         log "${C_R}  $what : 체크섬 불일치 $n_diff 개. 원본을 남긴다${C_0}"
         printf '%s\n' "$out" | grep -E '^[<>]f|^\*deleting' | head -5 | sed 's/^/      /'
         return 1
      fi
      log "${C_G}    체크섬 일치${C_0}"
   fi

   #  이제 지운다. --remove-source-files 는 '이미 목적지와 같은' 파일도
   #  전송 성공으로 보고 지우므로, 위에서 준 제외 규칙을 그대로 지킨다.
   # shellcheck disable=SC2086
   nice -n "$NICE" rsync -a --remove-source-files "$@" "$src"/ "$dst"/ >/dev/null 2>&1 || {
      log "${C_R}  $what : 원본 삭제 단계 실패. 사람이 볼 것${C_0}"; return 1; }
   find "$src" -depth -type d -empty -delete 2>/dev/null
   log "${C_G}  $what : 완료 ($n_dst 파일, 체크섬 대조함)${C_0}"
   return 0
}

# 런에 딸린 로그 / config 를 함께 옮긴다. RAW 만 옮기면 나중에 짝을 못 찾는다.
move_side_files() {       # run_pad src_root dst_root
   local rp=$1 s=$2 d=$3 f base moved=0
   [ "$DRYRUN" -eq 1 ] && {
      log "    [DRY] LOG/*_${rp}.log, CONFIG/${rp}.config -> $d"; return 0; }
   mkdir -p "$d/LOG" "$d/CONFIG" 2>/dev/null
   for f in "$s"/LOG/*"${rp}"*; do
      [ -f "$f" ] || continue
      base=$(basename "$f")
      #  -c 로 보내고, 다시 -c -n 으로 대조가 깨끗할 때만 원본을 지운다.
      if rsync -a -c "$f" "$d/LOG/$base" 2>/dev/null \
         && [ -z "$(rsync -a -c -n -i "$f" "$d/LOG/$base" 2>/dev/null | grep -E '^[<>]f')" ]; then
         rm -f "$f" && moved=$((moved+1))
      fi
   done
   if [ -f "$s/CONFIG/${rp}.config" ]; then
      if rsync -a -c "$s/CONFIG/${rp}.config" "$d/CONFIG/" 2>/dev/null \
         && [ -z "$(rsync -a -c -n -i "$s/CONFIG/${rp}.config" "$d/CONFIG/" 2>/dev/null | grep -E '^[<>]f')" ]; then
         rm -f "$s/CONFIG/${rp}.config" && moved=$((moved+1))
      fi
   fi
   [ "$moved" -gt 0 ] && log "  ${C_G}부속 파일${C_0} : $moved 개 (LOG / CONFIG)"
   return 0
}

# =====================================================================
#  1단계 : /Data_ssd -> /data
#     여기가 막히면 /Data_ssd 가 차고 DAQ 가 멈춘다. 가장 급한 단계다.
# =====================================================================
stage1() {
   local keep rp src
   keep=$(runs_in "$SSD/RAW" | tail -n "$KEEP_SSD")
   for rp in $(runs_in "$SSD/RAW"); do
      echo "$keep" | grep -qx "$rp" && continue
      is_acquiring "$rp" && { log "[1] run $rp : 수집 중. 건드리지 않는다"; continue; }
      src="$SSD/RAW/$rp"
      if has_symlink_subdir "$src"; then
         log "${C_Y}[1] run $rp : Merged/PRD 가 심볼릭 링크다. 손대지 않는다${C_0}"
         log "     예전 --outroot 구성의 잔재다. postrun.sh --archive-now 로 먼저 되돌릴 것"
         continue
      fi
      if ! is_processed "$src"; then
         log "${C_Y}[1] run $rp : 후처리 미완료. 대기${C_0}"; continue
      fi
      log "${C_C}[1] run $rp : $SSD -> $MID${C_0}"
      if move_dir "$src" "$MID/RAW/$rp" "run $rp"; then
         move_side_files "$rp" "$SSD" "$MID"
      fi
   done
}

# =====================================================================
#  2단계 : /data -> 경희대 서버 (카테고리별 rsync)
# =====================================================================
stage2() {
   if [ "$BACKUP_ENABLE" != "1" ]; then
      [ "$STAGE" -eq 2 ] && log "${C_Y}[2] 백업이 꺼져 있다 (--no-backup)${C_0}"
      return 0
   fi
   local args=(--mid "$MID" --all)
   [ -n "$PARAMS" ] && args=(--params "$PARAMS" "${args[@]}")
   [ "$DRYRUN" -eq 1 ] && args+=(--dry-run)
   log "${C_C}[2] 외부 백업 시작${C_0}"
   "$BACKUP_SH" "${args[@]}"
   local rc=$?
   [ "$rc" -ne 0 ] && log "${C_Y}[2] 일부 카테고리가 남았다. 다음 주기에 재시도${C_0}"
   return 0
}

# 이 런의 백업이 끝났는가. backup-khu.sh 가 남긴 마커를 본다.
backup_complete() {       # run_pad
   local m="$MID/RAW/$1/.backup_done" c
   [ -f "$m" ] || return 1
   for c in RAW PRD PNG DAQLOG config; do
      grep -q "^$c " "$m" || return 1
   done
   return 0
}

# =====================================================================
#  3단계 : /data -> /scratch (최종 보관)
# =====================================================================
stage3() {
   local keep rp src
   keep=$(runs_in "$MID/RAW" | tail -n "$KEEP_MID")
   for rp in $(runs_in "$MID/RAW"); do
      [ "$KEEP_MID" -gt 0 ] && echo "$keep" | grep -qx "$rp" && continue
      is_acquiring "$rp" && continue
      if [ "$BACKUP_ENABLE" = "1" ] && ! backup_complete "$rp"; then
         log "${C_Y}[3] run $rp : 백업 미완료. 대기${C_0}"; continue
      fi
      src="$MID/RAW/$rp"

      local extra=()
      if [ "$DROP_MERGED" = "1" ] && [ -d "$src/Merged" ]; then
         local nm; nm=$(find "$src/Merged" -type f 2>/dev/null | wc -l)
         log "${C_Y}[3] run $rp : Merged $nm 개를 옮기지 않고 지운다 (--drop-merged)${C_0}"
         extra=(--exclude='/Merged')
         [ "$DRYRUN" -eq 1 ] || rm -rf "$src/Merged"
      fi

      # 백업 마커는 이동 대상에서 빼 둔다. 같이 rsync 하면 개수 검증이 어긋나고,
      # 이동에 실패했을 때 마커만 사라져 다음 주기에 런 전체를 다시 백업하게 된다.
      local marker="$src/.backup_done" saved=""
      if [ -f "$marker" ] && [ "$DRYRUN" -eq 0 ]; then
         saved=$(mktemp "${TMPDIR:-/tmp}/backup_done.XXXXXX")
         cp -f "$marker" "$saved" && rm -f "$marker"
      fi

      log "${C_C}[3] run $rp : $MID -> $NFS${C_0}"
      if move_dir "$src" "$NFS/RAW/$rp" "run $rp" "${extra[@]+"${extra[@]}"}"; then
         move_side_files "$rp" "$MID" "$NFS"
         if [ -n "$saved" ]; then
            mkdir -p "$NFS/RAW/$rp" 2>/dev/null
            mv -f "$saved" "$NFS/RAW/$rp/.backup_done"
         fi
         [ "$DRYRUN" -eq 1 ] || rmdir "$src" 2>/dev/null
      else
         # 실패했으면 마커를 제자리에 돌려놓는다
         [ -n "$saved" ] && mv -f "$saved" "$marker"
      fi
   done
}

# =====================================================================
#  /Data_ssd 여유 감시 — 여기가 차면 DAQ 가 데이터를 못 써서 멈춘다.
# =====================================================================
check_space() {
   local f m n
   f=$(free_gb "$SSD"); m=$(free_gb "$MID"); n=$(free_gb "$NFS")
   log "  여유 : ssd ${f:-?}G / mid ${m:-?}G / nfs ${n:-?}G"
   [ -z "$f" ] && return 0
   if [ "$f" -lt "$MINFREE_GB" ]; then
      log "${C_R}[!] /Data_ssd 여유 ${f}G < 임계 ${MINFREE_GB}G — 체인이 막히면 DAQ 가 멈춘다${C_0}"
      log "${C_R}    1단계가 왜 진행되지 않는지 확인할 것 (후처리 미완료? 백업 실패?)${C_0}"
   fi
}

one_pass() {
   check_space
   case "$STAGE" in
      1) stage1 ;;
      2) stage2 ;;
      3) stage3 ;;
      *) stage1; stage2; stage3 ;;
   esac
}

# flock 으로 동시 실행 방지. 같은 런을 두 프로세스가 옮기면 서로를 혼란시킨다.
exec 9>"$LOCK"
if ! flock -n 9; then
   log "${C_Y}이미 실행 중이다 ($LOCK). 종료${C_0}"; exit 0
fi

log "${C_C}dataflow 시작${C_0}  ssd=$SSD  mid=$MID  nfs=$NFS  backup=$([ "$BACKUP_ENABLE" = 1 ] && echo on || echo off)"

if [ "$FOLLOW" -eq 1 ]; then
   trap 'log "중단 요청"; exit 130' INT TERM
   while true; do one_pass; sleep "$POLL"; done
else
   one_pass
   log "완료"
fi
