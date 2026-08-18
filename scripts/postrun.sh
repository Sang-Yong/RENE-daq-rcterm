#!/usr/bin/env bash
# =====================================================================
#  postrun.sh - DAQ 수집 뒤에 붙는 merge + production 파이프라인 드라이버
#
#  DAQ_cup/production 의 merge_FADC_SADC_v3_5v.cc 와
#  production_from_merged_v3_5v.cc 를 그대로 호출한다.
#  물리 코드는 한 줄도 복제하지 않는다. 이 스크립트가 하는 일은 세 가지다:
#    1) 어떤 서브런을 처리해도 안전한지 판단하고 (수집 중인 파일은 건드리지 않음)
#    2) merge 를 직렬로 돌리며 SADC 위치 상태를 다음 서브런에 넘기고
#    3) production 을 병렬로 돌린다
#
#  왜 이렇게 나누는가 (실측 33,357 서브런, run 4238/4239/4240):
#      merge      28초  <- SADC 위치를 다음 서브런에 넘기므로 직렬일 수밖에 없다
#      production 15초  <- 서브런마다 완전 독립. 병렬 가능
#      합계       43초  <- 서브런 1개가 60초 분량이니 여유 28%
#  production 을 병렬로 빼면 임계경로가 merge 28초로 내려가 여유가 2.1배가 된다.
#  경합이 생기면 43초가 86초까지 늘어지는 것을 실측했으므로(run 4287),
#  이 여유는 선택이 아니라 필수다.
#
#  사용 :
#    postrun.sh --follow              수집을 뒤따라가며 계속 처리 (기본)
#    postrun.sh 4288                  run 4288 을 한 번만 처리
#    postrun.sh 4288 --from 100 --to 200
#    postrun.sh --follow --jobs 4 --lag 3
#
#  기존 로그 파일명을 그대로 쓰므로 production/Shell/audit_run.sh 가
#  이 스크립트의 결과에도 그대로 동작한다.
# =====================================================================
set -u

# ---- 기본값 ---------------------------------------------------------
PRODDIR=${POSTRUN_PRODDIR:-/home/frontend/DAQ/DAQ_cup/production}
# 수집이 로컬 NVMe 로 옮겨졌다(rcterm.params 의 rawdatadir = /Data_ssd).
# 끝난 런을 /data 와 /scratch 로 넘기는 것은 scripts/dataflow.sh 가 한다.
RAWROOT=${POSTRUN_RAWROOT:-/Data_ssd/RAW}
# 산출물(Merged/PRD)을 RAW 와 다른 저장소에 두고 싶을 때. 비우면 RAW 안에 만든다.
#  병목이 NFS I/O 이므로 로컬 디스크를 지정하면 눈에 띄게 빨라진다(실측 41초 -> 28초).
#  RAW 쪽에는 심볼릭 링크를 걸어 두므로 매크로와 기존 도구는 경로를 그대로 쓴다.
OUTROOT=${POSTRUN_OUTROOT:-}
OUTROOT_WARN=0                 # --outroot 는 폐기됐다. 쓰면 알린다
HB=${POSTRUN_HEARTBEAT:-/Data/LOG/rcterm.hb}
JOBS=3                 # production 동시 실행 개수
# 기록 중인 서브런에서 몇 개 뒤까지만 손대는가.
#  3 = 실시간 수집보다 약 3분 뒤에서 따라간다(서브런 1개 = 1분).
#  이 여유가 필요한 이유:
#   - heartbeat 의 subrun 은 '지금 기록 중인' 파일이다. 그 파일은 아직 안 닫혔다.
#   - NFS 서버 시계가 로컬보다 약 28초 앞선다(실측). mtime 만으로는 완료를 못 믿는다.
#   - merger/DAQ 가 파일을 닫고 flush 하는 시간이 필요하다.
LAG=3
POLL=20                # --follow 에서 heartbeat 확인 주기 [초]
NICE=10                # 수집을 방해하지 않도록 낮은 우선순위
MAXRETRY=2             # 좀비 파일 재시도 (원본은 5회 x 60초 = 5분 낭비)
RETRY_WAIT=10
# --outroot(로컬 디스크)에 최근 몇 개 런의 산출물을 남길지. 0 = 정리하지 않음.
#  로컬은 빠르지만 좁다 — 런당 산출물이 217 GB 이고 여유가 1.5 TB 라 약 7일이면 찬다.
#  끝나고 검증된 런은 RAW 트리(NFS)로 되돌린다.
KEEPLOCAL=0
RUNARG=""; FOLLOW=0; FROM=-1; TO=-1; DRYRUN=0; ONCE=0; ARCHNOW=0; NORSYNC=0

usage() {
   cat <<EOF
postrun.sh - DAQ 수집 뒤에 붙는 merge + production 파이프라인 드라이버

  DAQ_cup/production 의 merge_FADC_SADC_v3_5v.cc 와
  production_from_merged_v3_5v.cc 를 그대로 호출한다. 물리 코드는 복제하지 않는다.
  merge 는 직렬(SADC 위치를 다음 서브런에 넘겨야 한다), production 은 병렬.

사용
  postrun.sh --follow                 수집을 뒤따라가며 계속 처리
  postrun.sh 4288                     run 4288 을 한 번만 처리
  postrun.sh 4288 --from 100 --to 200
  postrun.sh --once --dry-run         지금 무엇을 처리할지만 확인

옵션
  --follow            heartbeat 를 읽어 수집을 뒤따라가며 계속 처리
  --once              --follow 없이 한 바퀴만 (추적 모드의 1회 실행)
  --jobs N            production 병렬 개수                (${JOBS})
  --lag N             기록 중인 서브런에서 N 개 뒤까지만  (${LAG})
                      3 이면 실시간 수집보다 약 3분 뒤를 따라간다
  --poll SEC          heartbeat 확인 주기                 (${POLL})
  --nice N            처리 프로세스 nice 값               (${NICE})
  --from N --to N     서브런 범위 지정 (일회 처리용)
  --max-retry N       좀비 파일 재시도 횟수               (${MAXRETRY})
  --prod-dir DIR      production 트리                     (${PRODDIR})
  --rawroot DIR       RAW 상위 디렉터리                   (${RAWROOT})
  --outroot DIR       ★폐기됨★ Merged/PRD 를 여기에 두고 RAW 에는 심볼릭 링크를 건다.
                      병목이 NFS 이므로 로컬 디스크를 주면 빨라진다
                      (예: --outroot /Data_ssd/RAW)
  --keep-local N      --outroot 에 최근 N 개 런만 남기고 나머지 산출물을
                      RAW 트리로 되돌린다. 0 = 정리하지 않음        (${KEEPLOCAL})
                      완료·검증된 런만, 수집 중이 아닐 때만 옮긴다
  --archive-now       정리만 한 번 수행하고 끝낸다 (처리는 하지 않음)
                      수백 GB 를 옮기므로 시간이 걸린다. ionice 로 우선순위를
                      낮출 때 -c3(유휴)까지 내리면 후처리에 밀려 굶는다.
                      낮추려면 -c2 -n7 정도가 적당하다
  --no-rsync          rsync 대신 mv 로 옮긴다 (기본은 rsync 가 있으면 rsync)
  --heartbeat FILE    rcterm heartbeat                    (${HB})
  --dry-run           무엇을 할지만 출력
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
   case "$1" in
      --follow)     FOLLOW=1; shift ;;
      --once)       ONCE=1; shift ;;
      --jobs)       JOBS=$2; shift 2 ;;
      --lag)        LAG=$2; shift 2 ;;
      --poll)       POLL=$2; shift 2 ;;
      --nice)       NICE=$2; shift 2 ;;
      --from)       FROM=$2; shift 2 ;;
      --to)         TO=$2; shift 2 ;;
      --max-retry)  MAXRETRY=$2; shift 2 ;;
      --prod-dir)   PRODDIR=$2; shift 2 ;;
      --rawroot)    RAWROOT=$2; shift 2 ;;
      --outroot)    OUTROOT=$2; OUTROOT_WARN=1; shift 2 ;;
      --keep-local) KEEPLOCAL=$2; shift 2 ;;
      --archive-now) ARCHNOW=1; shift ;;
      --no-rsync)   NORSYNC=1; shift ;;
      --heartbeat)  HB=$2; shift 2 ;;
      --dry-run)    DRYRUN=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      -*)           echo "unknown option : $1" >&2; usage; exit 1 ;;
      *)            RUNARG=$1; shift ;;
   esac
done

# 산출물 이동에 rsync 를 쓴다. 없으면 mv 로 떨어진다(--no-rsync 로 강제 가능).
USE_RSYNC=0
if [ "${NORSYNC:-0}" -eq 0 ] && command -v rsync >/dev/null 2>&1; then USE_RSYNC=1; fi

CODEDIR=$PRODDIR/Code
SHELLDIR=$PRODDIR/Shell
LOGDIR=$PRODDIR/LOG
MERGE_MACRO=merge_FADC_SADC_v3_5v.cc
PROD_SCRIPT=production_from_merged_v3_5v.sh

# 색상 코드는 원본 merge_FADC_SADC_v3_5v.sh 와 동일하게 맞춘다.
C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'
C_C='\033[1;36m'; C_P='\033[1;35m'; C_0='\033[0m'

ts()   { date '+%Y-%m-%d %H:%M:%S'; }
say()  { printf '%b\n' "$*"; }                       # 배너 (시각 없음)
sayt() { printf '[%s] %b\n' "$(ts)" "$*"; }          # 시각이 붙는 줄
log()  { sayt "$*"; }
die()  { sayt "${C_R}[FATAL ERROR]${C_0} $*"; exit 1; }

# 원본의 [Data Dashboard] / [Pre-Check] 블록. 런마다 한 번만 찍는다.
dashboard() {            # run_num data_dir
   local rn=$1 dd=$2 fc sc maxs empty
   fc=$(find "$dd" -maxdepth 1 -name 'FADC*.root.*' 2>/dev/null | wc -l)
   sc=$(find "$dd" -maxdepth 1 -name 'SADC*.root.*' 2>/dev/null | wc -l)
   maxs=$(( fc - 1 )); [ "$maxs" -lt 0 ] && maxs=0
   say ""
   say "${C_C}==========================================================${C_0}"
   say "${C_C} [Data Dashboard] Scanning storage for Run ${rn}...${C_0}"
   say "  > 발견된 FADC 서브런 파일 : ${C_G}${fc} 개${C_0}"
   say "  > 발견된 SADC 서브런 파일 : ${C_G}${sc} 개${C_0}"
   say "  > Max 서브런 번호 (Max #) : ${C_Y}${maxs}${C_0}"
   [ "$fc" != "$sc" ] && \
      say "  ${C_R}[!] 주의: FADC와 SADC 파일 개수가 다릅니다! 데이터 누락 의심.${C_0}"
   say "${C_C}==========================================================${C_0}"
   say "${C_C} [Pre-Check] Checking for 0-byte (broken) files...${C_0}"
   empty=$(find "$dd" -maxdepth 1 -type f -name '*.root.*' -size 0 2>/dev/null)
   if [ -n "$empty" ]; then
      say "${C_Y} [WARNING] 0-byte (손상) 파일 발견됨!${C_0}"
      say "${C_Y}${empty}${C_0}"
   else
      say "${C_G} [Pre-Check] 0-byte 파일 없음. 양호.${C_0}"
   fi
   say "${C_C}==========================================================${C_0}"
}

# ---- 사전 점검 ------------------------------------------------------
#  --outroot 는 폐기됐다. 조용히 되살아나면 심볼릭 링크가 다시 생긴다.
if [ "$OUTROOT_WARN" -eq 1 ]; then
   log "${C_Y}[DEPRECATED]${C_0} --outroot 는 폐기된 옵션이다 (2026-08-19)."
   log "${C_Y}   RAW/Merged/PRD/PNG 는 전부 /Data_ssd 에 두고, 경희대 백업과 체크섬"
   log "   대조가 끝난 뒤에 scripts/relocate-run.sh 로 /scratch 로 옮긴다."
   log "   --outroot 를 주면 RAW 트리에 심볼릭 링크가 생겨 그 흐름이 깨진다.${C_0}"
fi

[ -d "$CODEDIR" ]  || die "Code 디렉터리 없음 : $CODEDIR"
[ -d "$SHELLDIR" ] || die "Shell 디렉터리 없음 : $SHELLDIR"
[ -f "$CODEDIR/$MERGE_MACRO" ]   || die "매크로 없음 : $CODEDIR/$MERGE_MACRO"
[ -x "$SHELLDIR/$PROD_SCRIPT" ]  || die "production 스크립트 없음 : $SHELLDIR/$PROD_SCRIPT"
mkdir -p "$LOGDIR" 2>/dev/null || true
[ -d "$LOGDIR" ] || die "LOG 디렉터리 없음 : $LOGDIR"

# ROOT 환경. 이미 잡혀 있으면 건드리지 않는다.
if ! command -v root >/dev/null 2>&1; then
   [ -f /usr/local/bin/thisroot.sh ] && . /usr/local/bin/thisroot.sh
fi
if [ -z "${ONLDAQ_DIR:-}" ] && [ -f /home/frontend/DAQ/DAQ_cup/cupdaq_env.sh ]; then
   . /home/frontend/DAQ/DAQ_cup/cupdaq_env.sh
fi
command -v root >/dev/null 2>&1 || die "root 를 찾을 수 없다. thisroot.sh 를 source 할 것"

# ---- heartbeat ------------------------------------------------------
hb_field() { [ -r "$HB" ] && grep -m1 "^$1=" "$HB" 2>/dev/null | cut -d= -f2- ; }
hb_age()   { local t; t=$(hb_field time); [ -n "$t" ] && echo $(( $(date +%s) - t )) || echo 999999; }

# ---- 서브런 상태 ----------------------------------------------------
pad6() { printf '%06d' "$1"; }
pad5() { printf '%05d' "$1"; }

# 서브런이 끝났는지 판정.
#
#  원본은 로그 두 개를 grep 한다(merge 로그의 final..., production 로그의 SUCCESS).
#  그런데 /scratch/LOG 에는 로그가 7만 개가 넘게 쌓여 있고 NFS 위에 있어서,
#  **400 서브런을 훑는 데 5분이 넘게 걸리는 것을 실측했다.** 재개 지점을 찾으려고
#  수백 번 grep 하면 스크립트가 시작조차 못 한다.
#
#  그래서 산출물 파일 stat 으로 판정한다. production_from_merged_v3_5v.sh 는
#  ROOT 종료코드가 0 이고 PRD 파일이 비어있지 않을 때만 SUCCESS 를 찍으므로,
#  'PRD 파일이 존재하고 크기가 0 이 아니다' 는 그 SUCCESS 와 같은 뜻이다.
#  MERGED 는 그보다 앞 단계이니 함께 확인한다. open+read 없이 stat 만 하므로
#  grep 대비 수십 배 빠르다.
subrun_done() {          # run_num subrun
   local rn=$1 n=$2 rp
   rp=$(printf '%06d' "$rn")
   local merged prd
   merged=$(printf '%s/%s/Merged/MERGED_%06d.root.%05d' "$RAWROOT" "$rp" "$rn" "$n")
   prd=$(printf    '%s/%s/PRD/PRD_%06d.%05d.root'       "$RAWROOT" "$rp" "$rn" "$n")
   [ -s "$merged" ] || return 1
   [ -s "$prd" ]    || return 1
   return 0
}

# merge 매크로가 다음 서브런에 넘기라고 찍어 주는 SADC 위치
ST_SADC=0; ST_EVT=0; ST_TRG=0
NEXT_RUN=""; NEXT_SUB=-1        # 추적 모드에서 재스캔을 피하기 위한 진행 지점
DASH_RUN=""                     # [Data Dashboard] 를 이미 찍은 런
load_state() {           # merge 로그 파일
   local f=$1 a b c
   a=$(grep -m1 "final SADC "              "$f" 2>/dev/null | awk '{print $4}')
   b=$(grep -m1 "final SADC_evt"           "$f" 2>/dev/null | awk '{print $4}')
   c=$(grep -m1 "final before_SADC_trgnum" "$f" 2>/dev/null | awk '{print $4}')
   [ -n "$a" ] && ST_SADC=$a; [ -n "$b" ] && ST_EVT=$b; [ -n "$c" ] && ST_TRG=$c
}

# 현재 파일 개수 기준 마지막 서브런 번호
max_file_index() {       # run_pad
   local d="$RAWROOT/$1" last
   last=$(find "$d" -maxdepth 1 -name 'FADC_*.root.*' -printf '%f\n' 2>/dev/null \
          | sed 's/.*\.//' | sort -n | tail -1)
   [ -n "$last" ] && echo $((10#$last)) || echo -1
}

# 산출물 디렉터리 준비.
#  --outroot 가 있으면 거기에 만들고 RAW 쪽에는 심볼릭 링크를 건다.
#  매크로는 "$DataDir/Merged/..." 를 그대로 쓰므로 코드를 고칠 필요가 없고,
#  audit_run.sh 같은 기존 도구도 경로가 그대로다.
#
#  ★ --outroot 는 폐기됐다. 쓰지 말 것. (2026-08-19)
#     이것이 있었던 이유는 오직 하나 — 예전에는 RAW 가 /scratch 에 있어서
#     산출물만이라도 로컬 NVMe 에 만들려 했기 때문이다(서브런당 41.0 -> 27.7초,
#     CLAUDE.md §5.8). 매크로가 "$DataDir/Merged/..." 를 경로로 박아 쓰므로
#     매크로를 고치지 않으려고 기대하는 자리에 링크를 걸었다.
#
#     2026-08-17 (§11.13) 부터 수집 자체가 /Data_ssd 로 오면서 그 이유가
#     사라졌다. 지금 설계는 이렇다 :
#         /Data_ssd 에서 수집하고 후처리한다 (RAW · Merged · PRD · PNG 전부)
#            -> 경희대 백업, 체크섬 대조
#               -> 대조를 통과한 것만 /scratch 로 옮긴다
#     어느 단계에도 심볼릭 링크가 낄 자리가 없다.
ensure_outdirs() {       # data_dir run_pad
   local dd=$1 rp=$2 sub
   # dry-run 은 파일시스템을 건드리지 않는다. 예전에는 여기서 빈 디렉터리를
   # 만들어 두어, 나중에 정리 기능이 그것을 '미완료 런'으로 보고했다.
   [ "$DRYRUN" -eq 1 ] && return 0
   mkdir -p "$dd/PNG" 2>/dev/null
   for sub in Merged PRD; do
      if [ -z "$OUTROOT" ]; then
         mkdir -p "$dd/$sub" 2>/dev/null
         continue
      fi
      mkdir -p "$OUTROOT/$rp/$sub" 2>/dev/null
      if [ -L "$dd/$sub" ]; then
         :                                    # 이미 링크. 그대로 둔다
      elif [ -d "$dd/$sub" ]; then
         # 실제 디렉터리가 이미 있다. 데이터를 임의로 옮기지 않고 알리기만 한다.
         log "${C_Y}[WARN]${C_0} $dd/$sub 이 실제 디렉터리다. --outroot 를 적용하려면"
         log "        먼저 mv 로 옮기고 심볼릭 링크를 걸 것 (docs/POSTRUN.md 참조)"
      else
         ln -s "$OUTROOT/$rp/$sub" "$dd/$sub" && \
            log "  $sub -> $OUTROOT/$rp/$sub (심볼릭 링크 생성)"
      fi
   done
}

# =====================================================================
#  산출물 정리 — 로컬 디스크(--outroot)에서 RAW 트리로 되돌린다
#
#  물리 데이터를 옮기는 작업이므로 다음 조건을 모두 만족할 때만 손댄다.
#   1) --outroot 와 --keep-local 이 둘 다 설정돼 있다
#   2) 그 런이 수집 중이 아니다 (heartbeat 의 run 과 다르다)
#   3) 처리가 완료됐다 — PRD 개수 == FADC 개수 이고 0 이 아니다
#   4) RAW 쪽이 심볼릭 링크다 (이미 실제 디렉터리면 건드릴 것이 없다)
#   5) 목적지에 충분한 여유가 있다
#
#  옮기는 방법 : 파일 단위 mv 로 임시 디렉터리에 모은 뒤, 개수를 확인하고
#  링크를 치우고 이름을 바꾼다. mv 는 파일마다 복사 후 원본을 지우므로
#  중간에 끊겨도 파일이 사라지는 구간이 없고, 다시 실행하면 이어서 된다.
# =====================================================================
archive_one() {          # run_num  ->  0 정리함 / 1 건너뜀
   local rn=$1 rp sub src dst tmp n_src n_dst need avail
   rp=$(pad6 "$rn")
   local raw="$RAWROOT/$rp"
   local out="$OUTROOT/$rp"

   [ -d "$out" ] || return 1

   # (2) 수집 중인 런은 손대지 않는다
   local hbrun; hbrun=$(hb_field run)
   if [ -n "$hbrun" ] && [ "$hbrun" = "$rn" ] && [ "$(hb_age)" -lt 120 ]; then
      return 1
   fi

   # 파일이 하나도 없는 껍데기면 조용히 치운다 (예전 dry-run 이 남긴 것 등)
   if [ -z "$(find "$out" -type f -print -quit 2>/dev/null)" ]; then
      [ "$DRYRUN" -eq 1 ] || { rmdir "$out"/* "$out" 2>/dev/null; }
      return 1
   fi

   # (3) 완료 확인. 하나라도 모자라면 아직 옮길 때가 아니다.
   #  중단된 정리를 다시 돌릴 때를 위해 staging(.arch_PRD)에 이미 옮겨진 것도
   #  함께 센다. 로컬만 세면 중간에 끊긴 정리는 '미완료'로 판정되어
   #  영영 재개할 수 없다(실측으로 겪었다).
   local n_fadc n_prd
   n_fadc=$(find "$raw" -maxdepth 1 -name 'FADC_*.root.*' 2>/dev/null | wc -l)
   n_prd=$( { ls "$out/PRD"/*.root 2>/dev/null; ls "$raw/.arch_PRD"/*.root 2>/dev/null; } \
            | sed 's#.*/##' | sort -u | wc -l )
   if [ "$n_fadc" -eq 0 ] || [ "$n_prd" -ne "$n_fadc" ]; then
      log "${C_Y}[정리 보류]${C_0} run=$rn 미완료 (FADC $n_fadc / PRD $n_prd)"
      return 1
   fi

   # (5) 여유 공간
   need=$(du -s -BM "$out" 2>/dev/null | cut -f1 | tr -dc '0-9')
   avail=$(df --output=avail -BM "$raw" 2>/dev/null | tail -1 | tr -dc '0-9')
   if [ -n "$need" ] && [ -n "$avail" ] && [ "$avail" -lt "$((need + 10240))" ]; then
      log "${C_R}[정리 중단]${C_0} run=$rn 목적지 여유 부족 (필요 ${need}M / 여유 ${avail}M)"
      return 1
   fi

   log "${C_C}[정리]${C_0} run=$rn 산출물을 $raw 로 되돌린다 (약 $((need/1024)) GB)"
   [ "$DRYRUN" -eq 1 ] && { log "  ${C_C}[DRY]${C_0} mv $out/{Merged,PRD} -> $raw/"; return 0; }

   for sub in Merged PRD; do
      src="$out/$sub"; dst="$raw/$sub"; tmp="$raw/.arch_$sub"
      [ -d "$src" ] || continue
      # (4) RAW 쪽이 심볼릭 링크가 아니면 이미 실제 데이터가 있다는 뜻이다. 덮지 않는다.
      if [ -e "$dst" ] && [ ! -L "$dst" ]; then
         log "${C_Y}  $dst 이 실제 디렉터리다. 건너뛴다${C_0}"
         continue
      fi
      mkdir -p "$tmp" || { log "${C_R}  $tmp 생성 실패${C_0}"; return 1; }

      n_src=$(ls -1 "$src" 2>/dev/null | wc -l)

      if [ "$USE_RSYNC" -eq 1 ]; then
         # rsync 는 임시 이름(.파일명.XXXXXX)으로 받아 다 받은 뒤에 최종 이름으로
         # rename 한다. 그래서 중간에 끊겨도 **잘린 파일이 최종 이름을 차지하는
         # 일이 없다.** 파일마다 전송 후 체크섬을 검증하고, 통과한 것만
         # --remove-source-files 로 원본을 지운다. 다시 실행하면 크기·시각이
         # 다른 것만 골라 재전송하므로, 예전에 mv 로 옮기다 남은 잘린 파일도
         # 알아서 고쳐진다.
         rsync -a --remove-source-files --info=progress2 "$src"/ "$tmp"/ 2>&1 \
            | tail -1 | sed 's/^/    /'
      else
         # rsync 가 없을 때의 대안. mv 는 최종 이름으로 바로 쓰므로 끊기면
         # 잘린 파일이 남을 수 있어, 양쪽에 다 있는 파일을 끊긴 복사로 보고 버린다.
         local f b dropped=0
         for f in "$tmp"/*; do
            [ -f "$f" ] || continue
            b=$(basename "$f")
            if [ -f "$src/$b" ]; then rm -f "$f"; dropped=$((dropped+1)); fi
         done
         [ "$dropped" -gt 0 ] && log "  ${C_Y}끊긴 복사 $dropped 개를 버리고 다시 옮긴다${C_0}"
         find "$src" -maxdepth 1 -type f -exec mv -n -t "$tmp" {} + 2>/dev/null
      fi
      n_dst=$(ls -1 "$tmp" 2>/dev/null | wc -l)
      if [ "$n_dst" -lt "$n_src" ]; then
         log "${C_R}  $sub 이동 불완전 ($n_dst / $n_src). 링크를 그대로 둔다${C_0}"
         return 1
      fi
      rmdir "$src" 2>/dev/null
      rm -f "$dst"                       # 심볼릭 링크 제거
      mv "$tmp" "$dst"                   # 같은 파일시스템이라 원자적
      log "  ${C_G}$sub${C_0} $n_dst 개 이동 완료"
   done

   rmdir "$out" 2>/dev/null && log "  ${C_G}run=$rn 정리 끝${C_0}"
   return 0
}

# --keep-local N : outroot 에 최근 N 개 런만 남기고 나머지를 되돌린다
archive_sweep() {
   [ -n "$OUTROOT" ] || return 0
   [ "$KEEPLOCAL" -gt 0 ] || return 0
   [ -d "$OUTROOT" ] || return 0

   local runs keep r
   runs=$(ls -1 "$OUTROOT" 2>/dev/null | grep -E '^[0-9]{6}$' | sort -n)
   [ -z "$runs" ] && return 0
   keep=$(echo "$runs" | tail -n "$KEEPLOCAL")

   for r in $runs; do
      echo "$keep" | grep -qx "$r" && continue
      archive_one "$((10#$r))"
   done
   return 0
}

# ---- production 병렬 풀 ---------------------------------------------
NRUNNING=0
prod_launch() {          # run_pad subrun data_dir
   local rp=$1 n=$2 dd=$3
   while [ "$NRUNNING" -ge "$JOBS" ]; do wait -n 2>/dev/null || break; NRUNNING=$((NRUNNING-1)); done
   # 원본은 production 을 직렬로 돌리고 끝난 뒤 결과를 찍는다. 여기서는 병렬이므로
   # 자식이 스스로 시작/종료 줄을 찍는다. 형식과 색은 원본과 같다.
   (
      local t0 rc el
      t0=$(date +%s)
      sayt "${C_P} -> Producing Subrun ${n} (병렬 슬롯 최대 ${JOBS})${C_0}"
      cd "$SHELLDIR" && nice -n "$NICE" ./"$PROD_SCRIPT" "$rp" "$n" "$dd" >/dev/null 2>&1
      rc=$?; el=$(( $(date +%s) - t0 ))
      if [ $rc -eq 0 ]; then
         sayt "${C_G} [OK] Producing Done : Subrun ${n} (총 처리시간: ${el}초)${C_0}"
      else
         sayt "${C_R} [FAIL] Producing FAILED : Subrun ${n} (총 처리시간: ${el}초)${C_0}"
      fi
   ) &
   NRUNNING=$((NRUNNING+1))
}
prod_drain() { while [ "$NRUNNING" -gt 0 ]; do wait -n 2>/dev/null || break; NRUNNING=$((NRUNNING-1)); done; }

# =====================================================================
#  한 서브런 처리
# =====================================================================
do_subrun() {            # run_pad run_num subrun maxarg data_dir
   local rp=$1 rn=$2 n=$3 maxarg=$4 dd=$5
   local ml="$LOGDIR/log_merge_FADC_SADC_v3_5v_run${rn}_subrun${n}.txt"
   local rl="$LOGDIR/log_merge_prod_v3_5v_run${rn}_subrun${n}.txt"

   if [ "$DRYRUN" -eq 1 ]; then
      log "${C_C}[DRY]${C_0} merge run=$rn sub=$n max=$maxarg state=($ST_SADC,$ST_EVT,$ST_TRG)"
      return 0
   fi

   date > "$rl"; date > "$ml"

   sayt "${C_C}Merging FADC Subrun ${n} ...${C_0}"

   local try=0 rc=1
   while [ $try -le "$MAXRETRY" ]; do
      ( cd "$CODEDIR" && nice -n "$NICE" root -l -b -q \
          "$MERGE_MACRO($rn,$maxarg,$n,$ST_SADC,$ST_EVT,$ST_TRG,\"$dd\")" ) >> "$ml" 2>&1
      rc=$?
      [ $rc -eq 0 ] && break
      try=$((try+1))
      [ $try -le "$MAXRETRY" ] && { log "${C_Y}[RETRY]${C_0} sub=$n merge 실패(rc=$rc) ${try}/${MAXRETRY}"; sleep "$RETRY_WAIT"; }
   done

   if [ $rc -ne 0 ]; then
      say "${C_R} [CORRUPTION DETECTED] ZOMBIE FILE AT SUBRUN ${n} (Skip)${C_0}"
      echo " Skipped subrun $n due to corruption." >> "$rl"
      # 상태를 이 서브런 기준으로 리셋한다. 원본이 비연속 점프에서 하는 것과 같다.
      ST_SADC=$((n+1)); ST_EVT=0; ST_TRG=0
      return 1
   fi

   # merge 가 남긴 SADC 위치를 다음 서브런으로 넘긴다
   load_state "$ml"
   echo " Merging Done : Run${rn}.${n}" >> "$rl"

   prod_launch "$rp" "$n" "$dd"
   return 0
}

# =====================================================================
#  한 런의 [from..to] 구간 처리
# =====================================================================
process_range() {        # run_pad run_num from to maxarg
   local rp=$1 rn=$2 from=$3 to=$4 maxarg=$5
   local dd="$RAWROOT/$rp"
   local n done_cnt=0 skip_cnt=0 fail_cnt=0 t0 el

   [ "$from" -gt "$to" ] && return 0

   ensure_outdirs "$dd" "$rp"

   # [경쟁 상태 수정] production_from_merged_v3_5v.sh 는
   #   if [ ! -f "$UseLog" ]; then cat TCBLOG | grep WJ > $UseLog; fi
   # 을 하는데, 병렬로 돌리면 여러 프로세스가 동시에 이 파일을 쓴다.
   # 미리 한 번만 만들어 두면 그 창이 사라진다.
   local uselog="$dd/PRD/Run${rp}_DLY_THR.log"
   local tcblog="$RAWROOT/../LOG/TCB_${rp}.log"
   if [ ! -s "$uselog" ] && [ -r "$tcblog" ] && [ "$DRYRUN" -eq 0 ]; then
      grep WJ "$tcblog" > "$uselog" 2>/dev/null && log "  DLY_THR 로그 생성 : $(basename "$uselog")"
   fi

   t0=$(date +%s)
   local need_state=0
   for (( n=from; n<=to; n++ )); do
      if subrun_done "$rn" "$n"; then
         # 이미 끝난 것. 로그를 읽는 것은 NFS grep 이라 비싸므로 여기서는 건너뛰기만
         # 하고, 실제로 merge 를 돌리기 직전에 딱 한 번 직전 로그에서 상태를 읽는다.
         skip_cnt=$((skip_cnt+1)); need_state=1
         continue
      fi
      if [ "$need_state" -eq 1 ]; then
         need_state=0
         if [ "$n" -gt 0 ]; then
            local prevlog="$LOGDIR/log_merge_FADC_SADC_v3_5v_run${rn}_subrun$(( n - 1 )).txt"
            if [ -f "$prevlog" ]; then load_state "$prevlog"
            else ST_SADC=$n; ST_EVT=0; ST_TRG=0; fi
         fi
      fi
      if do_subrun "$rp" "$rn" "$n" "$maxarg" "$dd"; then
         done_cnt=$((done_cnt+1))
      else
         fail_cnt=$((fail_cnt+1))
      fi
   done
   el=$(( $(date +%s) - t0 ))

   # 다음 주기에 처음부터 다시 훑지 않도록 진행 지점을 기억한다.
   NEXT_RUN=$rn; NEXT_SUB=$((to+1))

   if [ $((done_cnt+fail_cnt)) -gt 0 ]; then
      say "${C_G}==========================================================${C_0}"
      say "${C_G} [완료] run ${rn} [${from}..${to}] : merge ${done_cnt} / 건너뜀 ${skip_cnt} / 실패 ${fail_cnt}  (${el}초)${C_0}"
      say "${C_G}==========================================================${C_0}"
   fi
   return 0
}

# 재개 지점 : 앞에서부터 훑어 아직 안 끝난 첫 서브런을 찾는다.
#  원본은 이진 탐색을 쓰는데, 중간에 실패한 서브런이 있으면 단조성이 깨져
#  엉뚱한 지점에서 재개한다. 여기서는 선형으로 훑는다(파일 stat 뿐이라 충분히 빠르다).
resume_point() {         # run_num upto  -> 첫 미완료 서브런
   local rn=$1 upto=$2 n
   for (( n=0; n<=upto; n++ )); do
      subrun_done "$rn" "$n" || { echo "$n"; return; }
   done
   echo $((upto+1))
}

# =====================================================================
#  일회 처리
# =====================================================================
run_once() {             # run_num
   local rn=$1
   local rp; rp=$(pad6 "$rn")
   local dd="$RAWROOT/$rp"
   # 추적 모드에서는 die 하지 않는다. scripts/dataflow.sh 가 끝난 런을 다른
   # 저장소로 옮기고 나면 여기가 사라지는데, 그 때문에 후처리 전체가 죽으면
   # 수집을 뒤따라가던 것이 멈춰 버린다. 한 줄 알리고 다음 주기로 넘긴다.
   if [ ! -d "$dd" ]; then
      [ "$FOLLOW" -eq 1 ] && { log "${C_Y}[SKIP]${C_0} run=$rn : $dd 없음 (이미 옮겨졌나?)"; return 0; }
      die "데이터 디렉터리 없음 : $dd"
   fi

   local nf ns maxidx
   nf=$(find "$dd" -maxdepth 1 -name 'FADC_*.root.*' | wc -l)
   ns=$(find "$dd" -maxdepth 1 -name 'SADC_*.root.*' | wc -l)
   maxidx=$(max_file_index "$rp")
   if [ "$maxidx" -lt 0 ]; then
      [ "$FOLLOW" -eq 1 ] && { log "${C_Y}[SKIP]${C_0} run=$rn : FADC 파일 없음"; return 0; }
      die "FADC 파일이 없다 : $dd"
   fi
   [ "$nf" -ne "$ns" ] && log "${C_Y}[WARN]${C_0} FADC($nf) 와 SADC($ns) 개수가 다르다"

   # 이 런이 지금 수집 중인가?
   local hbrun hbsub age active=0 lastc targetmax
   hbrun=$(hb_field run); hbsub=$(hb_field subrun); age=$(hb_age)
   if [ -n "$hbrun" ] && [ "$hbrun" = "$rn" ] && [ "$age" -lt 120 ]; then
      active=1
      # heartbeat 의 subrun 은 '지금 기록 중인' 파일 번호다(실측 확인).
      #   완료된 마지막 서브런  lastc     = subrun - 1
      #   손대도 되는 마지막    targetmax = subrun - LAG
      # LAG=3 이면 기록 중인 것보다 3개(=약 3분) 뒤까지만 처리한다.
      lastc=$(( hbsub - 1 ))
      targetmax=$(( lastc - LAG + 1 ))
   else
      lastc=$maxidx
      targetmax=$maxidx
   fi
   [ "$targetmax" -gt "$maxidx" ] && targetmax=$maxidx
   [ "$lastc" -gt "$maxidx" ] && lastc=$maxidx

   # 재개 지점. 추적 모드에서 매 주기마다 전체를 다시 훑으면 NFS 에 수천 번
   # grep 하게 되므로, 같은 런을 계속 보는 동안에는 진행 지점을 이어 쓴다.
   local from to
   if   [ "$FROM" -ge 0 ]; then from=$FROM
   elif [ "$NEXT_RUN" = "$rn" ] && [ "$NEXT_SUB" -ge 0 ]; then from=$NEXT_SUB
   else from=$(resume_point "$rn" "$targetmax")
        log "  재개 지점 탐색 완료 -> subrun $from"
   fi
   if [ "$TO"   -ge 0 ]; then to=$TO;     else to=$targetmax; fi
   [ "$to" -gt "$targetmax" ] && to=$targetmax

   if [ "$from" -gt "$to" ]; then
      [ "$active" -eq 1 ] || log "run=$rn : 처리할 서브런 없음 (모두 완료)"
      return 0
   fi

   # [Data Dashboard] / [Pre-Check] 는 런마다 한 번만. 추적 모드에서 20초마다
   # 다시 찍으면 화면이 배너로 뒤덮인다.
   if [ "$DASH_RUN" != "$rn" ]; then
      dashboard "$rn" "$dd"
      DASH_RUN=$rn
   fi
   say "${C_C} [Resume Check] Subrun ${from} 부터 이어서 처리합니다."\
"  (수집 $([ $active -eq 1 ] && echo '진행 중' || echo '종료') / 상한 ${to} / lag ${LAG} / jobs ${JOBS})${C_0}"

   # 재개일 때는 직전 서브런의 상태를 이어받는다
   if [ "$from" -gt 0 ]; then
      local prev="$LOGDIR/log_merge_FADC_SADC_v3_5v_run${rn}_subrun$(( from - 1 )).txt"
      if [ -f "$prev" ]; then load_state "$prev"
      else ST_SADC=$from; ST_EVT=0; ST_TRG=0
           log "  ${C_Y}직전 로그 없음 -> SADC 상태를 $from 부터 새로 시작${C_0}"
      fi
   else
      ST_SADC=0; ST_EVT=0; ST_TRG=0
   fi

   process_range "$rp" "$rn" "$from" "$to" "$lastc"
}

# =====================================================================
#  추적 모드
# =====================================================================
follow_loop() {
   local cur=""
   log "${C_C}추적 모드 시작${C_0}  heartbeat=$HB  lag=$LAG  jobs=$JOBS  poll=${POLL}초"
   while true; do
      local hbrun age
      hbrun=$(hb_field run); age=$(hb_age)

      if [ -z "$hbrun" ] || [ "$age" -ge 120 ]; then
         # DAQ 가 안 돌고 있다. 마지막으로 보던 런의 남은 것만 마저 끝낸다.
         if [ -n "$cur" ]; then
            log "heartbeat 정지(age=${age}s). run=$cur 잔여분 마무리"
            FROM=-1; TO=-1; run_once "$cur"; prod_drain; cur=""
         fi
         sleep "$POLL"; continue
      fi

      if [ -n "$cur" ] && [ "$cur" != "$hbrun" ]; then
         # 런이 넘어갔다. 이전 런은 이제 전부 완료된 상태이므로 끝까지 처리한다.
         log "${C_Y}런 전환 $cur -> $hbrun${C_0}. 이전 런 마무리"
         FROM=-1; TO=-1; run_once "$cur"; prod_drain
         # 처리가 끝난 뒤에 정리한다. 이 시점이 가장 안전하다 —
         # 직전 런은 완료됐고 새 런은 아직 산출물이 거의 없다.
         archive_sweep
      fi
      cur=$hbrun

      FROM=-1; TO=-1
      run_once "$hbrun"
      sleep "$POLL"
   done
}

# =====================================================================
trap 'echo; log "중단 요청. 진행 중인 production 을 기다린다..."; prod_drain; exit 130' INT TERM

if [ "$ARCHNOW" -eq 1 ]; then
   [ -n "$OUTROOT" ] || die "--archive-now 는 --outroot 가 있어야 한다"
   if [ -n "$RUNARG" ]; then
      archive_one "$((10#$RUNARG))" && log "완료" || log "옮기지 않았다 (위 사유 참조)"
   else
      [ "$KEEPLOCAL" -gt 0 ] || die "--archive-now 에는 --keep-local N 또는 run 번호가 필요하다"
      archive_sweep; log "완료"
   fi
   exit 0
fi

if [ -n "$RUNARG" ]; then
   case "$RUNARG" in
      *[!0-9]*) die "run 번호가 숫자가 아니다 : $RUNARG" ;;
   esac
   run_once "$((10#$RUNARG))"      # 004288 / 4288 둘 다 받는다
   prod_drain
   log "완료"
elif [ "$ONCE" -eq 1 ]; then
   r=$(hb_field run); [ -n "$r" ] || die "heartbeat 에서 run 을 읽을 수 없다 : $HB"
   run_once "$r"; prod_drain; log "완료"
else
   FOLLOW=1
   follow_loop
fi
