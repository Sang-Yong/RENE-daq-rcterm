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
MINFREE_GB=${DATAFLOW_MINFREE_GB:-700}   # /Data_ssd 여유가 이 아래면 경고 + ★압박 모드 (아래)
#  ★ 압박 모드 (2026-11-05) — /Data_ssd 여유가 MINFREE_GB 아래로 내려가면 1단계가
#    KEEP_SSD 를 무시하고, 다른 관문(수집 중 아님 · 후처리 완결 · 조용함 · 백업이
#    안 읽음 · 심볼릭 링크 아님)을 통과한 런을 오래된 것부터 옮긴다. 런을 하나
#    옮길 때마다 여유를 다시 재고, 회복되면 그 자리에서 보통 모드로 돌아간다.
#    왜 : 6.8 kHz 런은 하나가 1.7 T 라 KEEP_SSD=2 가 런 '수' 기준이면 3.7 T 가
#    두 런으로 찬다. 2026-11-05 에 실제로 100 % (13 G) 가 됐다.
#  ★ 조용함 관문 — 런 디렉터리 안 무엇이든 최근 QUIET_MIN 분 안에 바뀌었으면 옮기지
#    않는다. PRD 는 매크로가 최종 이름으로 바로 쓰므로, 마지막 PRD 가 쓰이는 도중에도
#    'PRD 개수 == FADC 개수' 가 성립한다. 직전 런을 KEEP 으로 보호하지 않을 때
#    (압박 모드 · keep_ssd=1) 그 틈을 막는다. 0 이면 끈다 (시험용).
QUIET_MIN=${DATAFLOW_QUIET_MIN:-10}
#  ★ 부팅 실패 잔재 — 최상위 FADC 파일이 MIN_SUBRUNS 개 미만인 런은 후처리 완결을
#    기다리지 않고 옮긴다 (지우지 않는다). 영영 PRD==FADC 가 될 수 없어 /Data_ssd 에
#    붙박이로 남기 때문이다 (실측 2026-11-05 : 4324 4342 4389 4424 4425 4428).
MIN_SUBRUNS=${DATAFLOW_MIN_SUBRUNS:-2}
RESIDUE_QUIET_MIN=${DATAFLOW_RESIDUE_QUIET_MIN:-2}   # 잔재 경로의 조용함 하한 [분] (quiet_min 이 0 이어도)
DROP_MERGED=${DATAFLOW_DROP_MERGED:-0}   # 3단계에서 Merged 를 버린다 (기본 아니오)
#  ★ Merged 보관 창 — 최근 이 개수의 런만 Merged 를 남기고 나머지는 지운다.
#    0 이면 청소하지 않는다 (기본).  --merged-keep N 또는 params 로 켠다.
#
#    왜 지워도 되나 : Merged 에는 PRD 에 없는 물리 정보가 없다. 2026-09-04 에
#    run 4322 서브런 100 으로 실측했다 — 이벤트 수(57,523) · FADC 채널 ID
#    · SADC 채널 ID 30종의 개수까지 같고, 파형 총합이 349,409.1 로 일치한다.
#    Merged 에만 있는 값은 fTrgTime 하나인데 그것은 TCB 시계를 풀어 놓은
#    것이라(되감김 4회분) PRD 의 TCBTRGTime 에서 복원된다.
#    나머지(fStartTime·fEndTime·fTrgType·fNHit)는 전 이벤트가 상수다.
#
#    그래서 Merged 는 물리 자료가 아니라 '재처리 캐시'다. 남겨 두는 값어치는
#    production 을 다시 돌릴 때 merge(서브런당 28초)를 건너뛰는 것뿐이다.
KEEP_MERGED=${DATAFLOW_KEEP_MERGED:-0}   # Merged 를 남길 최근 런 수 (0 = 청소 안 함)
#  ★ 한 주기에 지울 파일 수 상한.  M단계는 주기의 맨 끝에 도는데, 처음 켤 때는
#    지울 것이 20만 개가 넘어 12시간이 걸린다. 그동안 1·2·3 단계가 통째로 밀린다.
#    상한을 두면 매 주기 조금씩 지우고 나머지 단계는 제때 돈다.
#
#    ★ 런 수가 아니라 파일 수로 잰다. 런 하나가 3 GB ~ 1,331 GB 로 400배 차이라
#      런 수로는 걸리는 시간을 묶을 수 없다. 삭제는 NFS 메타데이터가 병목이라
#      (실측 4.6 파일/초) 파일 수가 곧 시간이다. 20000 이면 약 1.2 시간.
#
#    ★ 상한은 런을 시작하기 전에만 본다. 그래야 상한보다 큰 런(최대 38,795 개)도
#      언젠가 지워진다 -- 중간에 끊으면 그런 런은 영영 남는다.
MERGED_MAX_FILES=${DATAFLOW_MERGED_MAX_FILES:-20000}   # 0 = 무제한
VERIFY=${DATAFLOW_VERIFY:-1}             # 지우기 전에 체크섬으로 대조한다 (CLAUDE.md §8)
POLL=${DATAFLOW_POLL:-600}
NICE=${DATAFLOW_NICE:-10}
BACKUP_SH=${DATAFLOW_BACKUP_SH:-$REPO/scripts/backup-khu.sh}   # 시험에서 갈아끼운다
PARAMS=""

STAGE=0; ONCE=0; FOLLOW=0; DRYRUN=0
#  ★ 시험에서 갈아끼울 수 있어야 한다. 운영 중인 dataflow 와 잠금이 겹치면
#    시험이 조용히 exit 0 으로 끝나 아무것도 검증하지 못한다.
LOCK=${DATAFLOW_LOCK:-/tmp/.dataflow.$(id -u).lock}
#  ★ 2단계(외부 백업) 전용 잠금. --follow 에서는 2단계를 뒤에 띄우므로(아래 stage2)
#    dataflow 를 다시 띄웠을 때 옛 백업이 아직 돌면 두 번째를 띄우지 않게 한다.
LOCK2=${DATAFLOW_LOCK2:-$LOCK.stage2}
BK_PID=""        # --follow 에서 뒤에 띄운 2단계의 PID

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
  --merged-keep N      최근 N 개 런의 Merged 만 남기고 나머지는 지운다.
                       ssd · mid · nfs 세 곳을 모두 훑는다. 0 이면 청소하지 않는다(기본).
                       ★ Merged 에는 PRD 에 없는 물리 정보가 없다(실측, 위 주석).
                         재처리할 때 merge 를 건너뛰는 캐시일 뿐이다.
                       ★ --dry-run 이면 무엇이 지워질지 개수·용량만 보여준다.
  --merged-max N       한 주기에 지울 Merged 파일 수 상한 (기본 20000, 0 = 무제한).
                       ★ M단계는 주기의 맨 끝에 돌기 때문에, 상한이 없으면 처음 켤 때
                         1·2·3 단계가 몇 시간씩 밀린다. 런 수가 아니라 파일 수로 잰다.
  --stage M            Merged 청소만 한다 (1·2·3 단계를 건너뛴다).
  --drop-merged        3단계에서 Merged 를 옮기지 않고 지운다.
                       런당 115 GB 이고 RAW 에서 다시 만들 수 있다.
                       **데이터를 지우는 옵션이므로 기본은 꺼져 있다**
  --min-free-gb N      /Data_ssd 경고 임계 [GB]  (${MINFREE_GB})
                       ★ 이 아래면 1단계가 압박 모드로 keep-ssd 를 무시한다
  --quiet-min N        최근 N 분 안에 바뀐 런은 1단계에서 옮기지 않는다 (${QUIET_MIN}, 0 = 끔)
  --min-subruns N      FADC 파일이 N 개 미만인 부팅 실패 잔재는 후처리 완결 없이 옮긴다 (${MIN_SUBRUNS})
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
         QUIET_MIN)      QUIET_MIN=$v ;;
         MIN_SUBRUNS)    MIN_SUBRUNS=$v ;;
         DROP_MERGED)    DROP_MERGED=$v ;;
         KEEP_MERGED)    KEEP_MERGED=$v ;;
         MERGED_MAX_FILES) MERGED_MAX_FILES=$v ;;
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
      --merged-keep)  KEEP_MERGED=$2; shift 2 ;;
      --merged-max)   MERGED_MAX_FILES=$2; shift 2 ;;
      --no-verify)    VERIFY=0; shift ;;   # ★권장하지 않는다★
      --verify)       VERIFY=1; shift ;;
      --min-free-gb)  MINFREE_GB=$2; shift 2 ;;
      --quiet-min)    QUIET_MIN=$2; shift 2 ;;
      --min-subruns)  MIN_SUBRUNS=$2; shift 2 ;;
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
#  /Data_ssd 여유 [GB].  시험에서는 DATAFLOW_TEST_SSD_FREE_CMD (bash 한 줄, 숫자를 낸다)
#  로 갈아끼운다. 런을 옮길 때마다 다시 부르므로 '회복' 도 시험할 수 있다.
ssd_free_gb() {
   if [ -n "${DATAFLOW_TEST_SSD_FREE_CMD:-}" ]; then
      bash -c "$DATAFLOW_TEST_SSD_FREE_CMD" 2>/dev/null | tr -dc '0-9'
   else
      free_gb "$SSD"
   fi
}
#  /Data_ssd 가 압박 상태인가 (여유를 모르면 아니라고 본다)
ssd_pressure() {
   local f; f=$(ssd_free_gb)
   [ -n "$f" ] && [ "$f" -lt "$MINFREE_GB" ]
}

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

# 최상위 FADC 파일 개수
n_fadc() { find -L "$1" -maxdepth 1 -name 'FADC_*.root.*' 2>/dev/null | wc -l; }

# 부팅 실패 잔재인가 — 최상위 FADC 가 MIN_SUBRUNS 개 미만.
#  (수집 중 여부와 조용함은 호출자가 따로 본다)
is_residue() {            # run_dir
   [ "$(n_fadc "$1")" -lt "$MIN_SUBRUNS" ]
}

# 최근 QUIET_MIN 분 안에 바뀐 것이 있는가 (디렉터리 자신 포함). 0 이면 끈다.
recently_modified() {     # run_dir
   [ "${QUIET_MIN:-0}" -gt 0 ] || return 1
   [ -n "$(find "$1" -mmin "-$QUIET_MIN" -print -quit 2>/dev/null)" ]
}

# 예전 --outroot 구성이 남긴 심볼릭 링크가 있으면 통째로 옮길 수 없다.
#  rsync -a 는 링크를 링크째 복사하므로 목적지에서 깨진 링크가 된다.
has_symlink_subdir() {    # run_dir
   local s
   for s in Merged PRD PNG; do [ -L "$1/$s" ] && return 0; done
   return 1
}

# ---------------------------------------------------------------------
#  ★ 이 런의 Merged 를 지워도 되는가.  이유를 표준출력에 한 낱말로 남긴다.
#
#    관문이 둘로 갈리는 이유 —— 외장하드로 아카이브된 런은 RAW 가 없어서
#    is_processed() 가 영원히 거짓이다. 그 갈래를 따로 두지 않으면 정작
#    용량을 가장 많이 먹는 옛 런이 청소에서 통째로 빠진다.
# ---------------------------------------------------------------------
merged_droppable() {      # run_dir -> 0 지워도 된다 / 1 아니다
   local d=$1 f p empty
   [ -d "$d/Merged" ] || { echo "merged없음"; return 1; }
   #  옛 --outroot 구성의 심볼릭 링크는 건드리지 않는다. 지우면 실체가 날아간다.
   has_symlink_subdir "$d" && { echo "심볼릭링크"; return 1; }

   p=$(find -L "$d/PRD" -maxdepth 1 -name '*.root' 2>/dev/null | wc -l)
   [ "$p" -gt 0 ] || { echo "PRD없음"; return 1; }

   #  ★ 반쪽짜리 PRD 위에서 Merged 를 지우지 않는다. 0 바이트가 하나라도 있으면
   #    그 서브런은 다시 만들어야 하고, 그때 Merged 가 있으면 훨씬 싸다.
   empty=$(find -L "$d/PRD" -maxdepth 1 -name '*.root' -size 0 2>/dev/null | wc -l)
   [ "$empty" -eq 0 ] || { echo "PRD빈파일${empty}개"; return 1; }

   f=$(find -L "$d" -maxdepth 1 -name 'FADC_*.root.*' 2>/dev/null | wc -l)
   if [ "$f" -gt 0 ]; then
      #  RAW 가 아직 있다 -> 후처리 완결을 개수로 확인한다
      [ "$p" -eq "$f" ] || { echo "후처리미완료(PRD $p/FADC $f)"; return 1; }
      echo "완결"; return 0
   fi
   #  RAW 가 없다 -> 이미 아카이브된 런이다. PRD 가 산출물의 전부다.
   echo "아카이브됨"; return 0
}

# ---------------------------------------------------------------------
#  M단계 — Merged 청소.  최근 KEEP_MERGED 개 런만 남기고 나머지를 지운다.
#  세 뿌리를 모두 훑는다. 용량의 대부분은 nfs 에 쌓여 있다.
# ---------------------------------------------------------------------
stage_merged() {
   [ "${KEEP_MERGED:-0}" -gt 0 ] || {
      [ "$STAGE" = "M" ] && log "${C_Y}[M] KEEP_MERGED=0 이라 청소하지 않는다 (--merged-keep N 으로 켠다)${C_0}"
      return 0
   }
   local root rp d why keep n sz tot_n=0 tot_gb=0 capped=0
   #  ★ 보관 창은 '세 뿌리를 합친 전체 런 목록'의 뒤에서 센다. 뿌리마다 따로
   #    세면 뿌리가 셋이라 3배를 남기게 된다.
   keep=$( { runs_in "$SSD/RAW"; runs_in "$MID/RAW"; runs_in "$NFS/RAW"; } \
           | sort -n -u | tail -n "$KEEP_MERGED" )
   for root in "$SSD" "$MID" "$NFS"; do
      [ -d "$root/RAW" ] || continue
      #  nfs 가 빠져 있으면 손대지 않는다 (§11.135 와 같은 이유)
      if [ "$root" = "$NFS" ] && ! dest_mounted "$NFS"; then
         log "${C_Y}[M] $NFS 가 마운트돼 있지 않다. 건너뛴다${C_0}"; continue
      fi
      for rp in $(runs_in "$root/RAW"); do
         echo "$keep" | grep -qx "$rp" && continue          # 보관 창 안
         is_acquiring "$rp" && continue                     # 수집 중
         d="$root/RAW/$rp"
         [ -d "$d/Merged" ] || continue
         #  ★ 상한은 '런을 시작하기 전' 에만 본다. 시작한 런은 끝까지 지운다 --
         #    그래야 상한보다 큰 런도 언젠가 지워진다.
         if [ "${MERGED_MAX_FILES:-0}" -gt 0 ] && [ "$tot_n" -ge "$MERGED_MAX_FILES" ]; then
            log "${C_Y}[M] 이번 주기 상한 $MERGED_MAX_FILES 개에 닿았다. 나머지는 다음 주기에${C_0}"
            capped=1; break 2
         fi
         if ! why=$(merged_droppable "$d"); then
            log "${C_Y}[M] run $rp ($root) : Merged 를 두었다 — $why${C_0}"; continue
         fi
         n=$(find "$d/Merged" -type f 2>/dev/null | wc -l)
         sz=$(size_gb "$d/Merged")
         tot_n=$((tot_n + n)); tot_gb=$((tot_gb + ${sz:-0}))
         if [ "$DRYRUN" -eq 1 ]; then
            log "  [DRY] [M] run $rp ($root) : Merged $n 개 / ${sz:-?}G 를 지운다 ($why)"
         else
            log "${C_C}[M] run $rp ($root) : Merged $n 개 / ${sz:-?}G 삭제 ($why)${C_0}"
            rm -rf "$d/Merged"
         fi
      done
   done
   [ "$tot_n" -gt 0 ] && log "${C_C}[M] 합계 : Merged $tot_n 개 / 약 ${tot_gb}G $([ "$DRYRUN" -eq 1 ] && echo '(dry-run, 지우지 않았다)' || echo '삭제')$([ "$capped" = 1 ] && echo ' — 상한에서 멈췄다')${C_0}"
   return 0
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
# =====================================================================
#  밖에서 돌고 있는 백업이 이 런을 읽는 중인가
#
#  2026-08-21 에 실제로 부딪혔다. 손으로 띄운 backup-khu 가 run 4294 의 PRD 를
#  보내는 도중 1단계가 그 런을 /data 로 옮겨, rsync 가 rc=24(원본이 사라짐)로
#  죽었다. 그때는 RAW 가 이미 체크섬까지 통과한 뒤였고 마커가 이동을 따라가
#  피해가 없었지만, 순서가 반대였으면 **검증하지 않은 부분 전송이 완료로
#  남을 수 있었다.** 옮기기 전에 확인한다.
#
#  ★ backup-khu 는 --all 로도 돌아 명령줄에 런 번호가 없을 수 있다. 그래서
#    껍데기가 아니라 **실제로 파일을 읽는 rsync/ssh** 의 명령줄을 본다.
#  ★ pgrep -f 는 자기를 부른 셸까지 잡는다(§11.67 에서 두 번 밟았다).
#    자기 계보를 빼고, 프로그램 이름을 줄 맨 앞에서 확인한다.
# =====================================================================
backup_reading() {       # run_pad
   local rp=$1 mine=" $$ $PPID " p=$PPID i
   for i in 1 2 3 4 5 6; do
      p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
      { [ -n "$p" ] && [ "$p" != 0 ]; } || break
      mine="$mine$p "
   done
   ps -eo pid=,args= 2>/dev/null | while read -r pid args; do
      case "$mine" in *" $pid "*) continue ;; esac
      printf '%s\n' "$args"
   done | grep -Eq "^(/[^ ]*/)?(rsync|ssh) .*(/|^)$rp(/| |$)"
}

# ---------------------------------------------------------------------
#  목적지가 실제로 마운트돼 있는지 확인한다.  ★ 2026-09-01 추가
#
#  /scratch 가 빠진 채 3단계가 돌면 rsync 는 그것이 NFS 였다는 것을 모른다.
#  루트 파일시스템에 남아 있는 빈 디렉터리에 런 하나(약 330 GB)를 그대로
#  쏟아붓는다. 루트가 차면 DAQ 만이 아니라 시스템 전체가 멎는다.
#  저장소 서버가 죽어 /scratch 가 빠져 있는 상태를 실제로 겪었다 (§11.133).
#
#  목적지가 마운트가 아닌 구성을 일부러 쓰려면 DATAFLOW_ALLOW_UNMOUNTED=1.
# ---------------------------------------------------------------------
dest_mounted() {                     # $1 = 확인할 경로
   [ "${DATAFLOW_ALLOW_UNMOUNTED:-0}" = "1" ] && return 0
   mountpoint -q "$1" 2>/dev/null
}

stage1() {
   local keep rp src pressure=0 in_keep
   if ! dest_mounted "$MID"; then
      log "${C_R}[1] $MID 가 마운트돼 있지 않다. 1단계를 건너뛴다${C_0}"
      log "${C_R}    (그대로 옮기면 루트 파일시스템을 채운다)${C_0}"
      return 0
   fi
   if ssd_pressure; then
      pressure=1
      log "${C_R}[1] 압박 모드 : $SSD 여유 $(ssd_free_gb)G < ${MINFREE_GB}G — keep_ssd=${KEEP_SSD} 를 무시하고 오래된 런부터 옮긴다${C_0}"
   fi
   keep=$(runs_in "$SSD/RAW" | tail -n "$KEEP_SSD")
   for rp in $(runs_in "$SSD/RAW"); do
      in_keep=0; echo "$keep" | grep -qx "$rp" && in_keep=1
      if [ "$in_keep" = 1 ]; then
         [ "$pressure" = 1 ] || continue
         #  ★ 보관 창 안의 런은 압박이 '지금도' 이어질 때만 옮긴다.
         #    앞 런을 옮겨 여유가 돌아왔으면 그 자리에서 보통 모드로.
         if ! ssd_pressure; then
            pressure=0
            log "${C_G}[1] 압박 모드 해제 : $SSD 여유 $(ssd_free_gb)G >= ${MINFREE_GB}G${C_0}"
            continue
         fi
      fi
      is_acquiring "$rp" && { log "[1] run $rp : 수집 중. 건드리지 않는다"; continue; }
      src="$SSD/RAW/$rp"
      if has_symlink_subdir "$src"; then
         log "${C_Y}[1] run $rp : Merged/PRD 가 심볼릭 링크다. 손대지 않는다${C_0}"
         log "     예전 --outroot 구성의 잔재다. postrun.sh --archive-now 로 먼저 되돌릴 것"
         continue
      fi
      local why="후처리 완결"
      if ! is_processed "$src"; then
         if is_residue "$src"; then
            why="부팅 실패 잔재 (FADC $(n_fadc "$src") 개 < ${MIN_SUBRUNS}). 후처리 없이 그대로 옮긴다"
         else
            log "${C_Y}[1] run $rp : 후처리 미완료. 대기${C_0}"; continue
         fi
      fi
      local qm=$QUIET_MIN
      #  ★ 잔재 경로는 quiet 하한을 둔다. 런이 바뀌는 순간에는 새 디렉터리가 생겼는데
      #    heartbeat 는 아직 옛 런이라 is_acquiring 이 지켜 주지 못한다.
      if is_residue "$src" && [ "${qm:-0}" -lt "$RESIDUE_QUIET_MIN" ]; then qm=$RESIDUE_QUIET_MIN; fi
      if QUIET_MIN=$qm recently_modified "$src"; then
         log "${C_Y}[1] run $rp : 최근 ${qm}분 안에 바뀐 파일이 있다. 다음 주기에${C_0}"; continue
      fi
      if backup_reading "$rp"; then
         log "${C_Y}[1] run $rp : 백업이 읽는 중이다. 끝난 뒤에 옮긴다${C_0}"; continue
      fi
      #  (옮기는 중인 런은 backup-khu --all 이 집지 않는다 : 원본이 $SSD 에 남아 있으면 뺀다)
      log "${C_C}[1] run $rp : $SSD -> $MID${C_0} ($why$([ "$in_keep" = 1 ] && echo ', ★압박 모드로 보관 창 무시'))"
      if move_dir "$src" "$MID/RAW/$rp" "run $rp"; then
         move_side_files "$rp" "$SSD" "$MID"
      fi
   done
   [ "$pressure" = 1 ] && ssd_pressure && \
      log "${C_R}[1] 압박 모드가 이어진다 : 옮길 수 있는 런을 다 옮겼다. 남은 것은 수집 중이거나 후처리 미완료다${C_0}"
   return 0
}

# =====================================================================
#  2단계 : /data -> 경희대 서버 (카테고리별 rsync)
# =====================================================================
stage2_args() {
   BK_ARGS=(--mid "$MID" --all)
   [ -n "$PARAMS" ] && BK_ARGS=(--params "$PARAMS" "${BK_ARGS[@]}")
   [ "$DRYRUN" -eq 1 ] && BK_ARGS+=(--dry-run)
   return 0
}

# 뒤에 띄운 2단계가 아직 도는가 (우리 자식이거나, 잠금을 다른 누가 쥐었거나)
bk_running() {
   if [ -n "$BK_PID" ] && kill -0 "$BK_PID" 2>/dev/null; then return 0; fi
   [ -e "$LOCK2" ] || return 1
   ! flock -n "$LOCK2" true 2>/dev/null
}

#  ★ 2단계는 런당 수 시간 ~ 21 시간이 걸린다. --follow 에서 그것을 앞에 세우면
#    1단계(/Data_ssd 비우기)가 그동안 멎어 DAQ 가 멈출 수 있다. 그래서 --follow 에서는
#    뒤에 띄우고(자식 프로세스, 전용 잠금 LOCK2), 다음 주기에 아직 돌면 건너뛴다.
#    --once 와 --dry-run 은 예전처럼 끝날 때까지 기다린다 (한 바퀴의 뜻을 유지).
stage2() {
   if [ "$BACKUP_ENABLE" != "1" ]; then
      [ "$STAGE" = "2" ] && log "${C_Y}[2] 백업이 꺼져 있다 (--no-backup)${C_0}"
      return 0
   fi
   stage2_args
   if [ "$FOLLOW" -eq 1 ] && [ "$DRYRUN" -eq 0 ]; then
      if [ -n "$BK_PID" ] && ! kill -0 "$BK_PID" 2>/dev/null; then
         wait "$BK_PID" 2>/dev/null; local brc=$?
         case $brc in
            0)  log "${C_G}[2] 지난 외부 백업이 끝났다 (pid $BK_PID)${C_0}" ;;
            75) log "${C_Y}[2] 지난 주기 : 다른 백업이 잠금을 쥐고 있어 띄우지 않았다${C_0}" ;;
            *)  log "${C_Y}[2] 지난 외부 백업 rc=$brc. 일부 카테고리가 남았다. 이번에 재시도${C_0}" ;;
         esac
         BK_PID=""
      fi
      if bk_running; then
         log "${C_Y}[2] 외부 백업이 아직 돈다$([ -n "$BK_PID" ] && echo " (pid $BK_PID)"). 이번 주기는 건너뛰고 1·3 단계를 계속한다${C_0}"
         return 0
      fi
      log "${C_C}[2] 외부 백업을 뒤에서 시작한다${C_0}"
      #  ★ 9>&- : 본 잠금(fd 9)을 자식에게 물려주지 않는다. 물려주면 dataflow 를 다시 띄울 때
      #    살아 있는 백업이 본 잠금을 쥐고 있어 '이미 실행 중' 으로 끝난다.
      flock -n -E 75 "$LOCK2" "$BACKUP_SH" "${BK_ARGS[@]}" 9>&- &
      BK_PID=$!
      return 0
   fi
   if bk_running; then
      log "${C_Y}[2] 다른 외부 백업이 돌고 있다 ($LOCK2). 이번에는 건너뛴다${C_0}"
      return 0
   fi
   log "${C_C}[2] 외부 백업 시작${C_0}"
   local rc
   if [ "$DRYRUN" -eq 1 ]; then
      "$BACKUP_SH" "${BK_ARGS[@]}"; rc=$?      # 미리보기는 잠금 파일도 만들지 않는다
   else
      flock -n -E 75 "$LOCK2" "$BACKUP_SH" "${BK_ARGS[@]}"; rc=$?
   fi
   [ "$rc" -ne 0 ] && log "${C_Y}[2] 일부 카테고리가 남았다 (rc=$rc). 다음 주기에 재시도${C_0}"
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
   if ! dest_mounted "$NFS"; then
      log "${C_R}[3] $NFS 가 마운트돼 있지 않다. 3단계를 건너뛴다${C_0}"
      log "${C_R}    (그대로 옮기면 루트 파일시스템을 채운다. 저장소 서버부터 살릴 것)${C_0}"
      return 0
   fi
   keep=$(runs_in "$MID/RAW" | tail -n "$KEEP_MID")
   for rp in $(runs_in "$MID/RAW"); do
      [ "$KEEP_MID" -gt 0 ] && echo "$keep" | grep -qx "$rp" && continue
      is_acquiring "$rp" && continue
      if [ "$BACKUP_ENABLE" = "1" ] && ! backup_complete "$rp"; then
         log "${C_Y}[3] run $rp : 백업 미완료. 대기${C_0}"; continue
      fi
      src="$MID/RAW/$rp"
      if backup_reading "$rp"; then
         log "${C_Y}[3] run $rp : 백업이 읽는 중이다. 끝난 뒤에 옮긴다${C_0}"; continue
      fi

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
   f=$(ssd_free_gb); m=$(free_gb "$MID"); n=$(free_gb "$NFS")
   log "  여유 : ssd ${f:-?}G / mid ${m:-?}G / nfs ${n:-?}G"
   [ -z "$f" ] && return 0
   if [ "$f" -lt "$MINFREE_GB" ]; then
      log "${C_R}[!] /Data_ssd 여유 ${f}G < 임계 ${MINFREE_GB}G — 체인이 막히면 DAQ 가 멈춘다 (1단계는 압박 모드)${C_0}"
      log "${C_R}    1단계가 왜 진행되지 않는지 확인할 것 (후처리 미완료? 백업 실패?)${C_0}"
   fi
}

one_pass() {
   check_space
   case "$STAGE" in
      1) stage1 ;;
      2) stage2 ;;
      3) stage3 ;;
      M|m) stage_merged ;;
      *) stage1; stage2; stage3; stage_merged ;;
   esac
}

# flock 으로 동시 실행 방지. 같은 런을 두 프로세스가 옮기면 서로를 혼란시킨다.
exec 9>"$LOCK"
if ! flock -n 9; then
   log "${C_Y}이미 실행 중이다 ($LOCK). 종료${C_0}"; exit 0
fi

log "${C_C}dataflow 시작${C_0}  ssd=$SSD  mid=$MID  nfs=$NFS  backup=$([ "$BACKUP_ENABLE" = 1 ] && echo on || echo off)"

if [ "$FOLLOW" -eq 1 ]; then
   #  ★ 뒤에 띄운 2단계(BK_PID)는 세우지 않는다. 전용 잠금(LOCK2)을 쥐고 있어 다시
   #    띄운 dataflow 가 두 번째 백업을 띄우지 않는다. 세우려면 그 PID 에 따로 TERM.
   trap 'log "중단 요청$([ -n "$BK_PID" ] && kill -0 "$BK_PID" 2>/dev/null && echo " (외부 백업 pid $BK_PID 은 계속 돈다)")"; exit 130' INT TERM
   while true; do
      one_pass
      #  sleep 을 뒤에 두고 wait 로 기다린다. 앞에 두면 TERM 이 sleep 이 끝날 때까지
      #  미뤄진다 (§11.135). 2단계 자식은 wait 에 넣지 않는다.
      sleep "$POLL" 9>&- & wait $! 2>/dev/null
   done
else
   one_pass
   log "완료"
fi
