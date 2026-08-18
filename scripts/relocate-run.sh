#!/usr/bin/env bash
#
#  relocate-run.sh — 끝난 런의 산출물을 로컬 NVMe 에서 장기보관(NFS)으로 옮긴다.
#
#  ★ 이동은 언제나 rsync 다. mv 를 쓰지 않는다.
#     복사 -> 체크섬 대조 -> 대조를 통과한 것만 원본 삭제. 이 순서를 바꾸지 말 것.
#     근거 : 옮기는 것이 되돌릴 수 없는 원시/가공 데이터이고, /scratch 가
#     100 Mb 링크에 붙어 있어(CLAUDE.md §11.12) 전송이 길고 끊기기 쉽다.
#     개수만 맞추면 예전에 끊긴 전송의 잔재를 성공으로 오인한다.
#
#  왜 dataflow.sh 로 안 되나 — 예전 `--outroot` 구성으로 받은 런은
#  <nfs>/RAW/<run>/{Merged,PRD} 가 <ssd> 를 가리키는 심볼릭 링크다.
#  목적지가 곧 원본이라 그대로 rsync 하면 자기 자신에게 복사한다.
#  그래서 스테이징 디렉터리로 받은 뒤 링크와 바꿔 끼운다.
#
#  사용
#     scripts/relocate-run.sh --run 4290 --dry-run
#     scripts/relocate-run.sh --run 4290 --run 4291
#     scripts/relocate-run.sh --run 4291 --only PRD
#
set -u

SRC=${RELOC_SRC:-/Data_ssd/RAW}
DST=${RELOC_DST:-/scratch/RAW}
HB=${RELOC_HB:-/Data/LOG/rcterm.hb}
SUBS="Merged PRD PNG"
RUNS=""; DRYRUN=0; VERIFY=1; FORCE=0; NICE=10

C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'; C_C='\033[1;36m'; C_0='\033[0m'
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '[%s] %b\n' "$(ts)" "$*"; }
warn() { printf '[%s] %b\n' "$(ts)" "${C_Y}$*${C_0}"; }
err()  { printf '[%s] %b\n' "$(ts)" "${C_R}$*${C_0}"; }
die()  { err "[FATAL] $*"; exit 1; }

usage() {
   sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
   cat <<EOF

옵션
  --run N          옮길 런 (여러 번 줄 수 있다)
  --src DIR        원본 뿌리            (${SRC})
  --dst DIR        목적지 뿌리          (${DST})
  --only A,B       이 하위 디렉터리만   (${SUBS// /,})
  --dry-run        무엇을 할지만 보여준다
  --no-verify      체크섬 대조를 건너뛴다 ★권장하지 않는다★
  --force          수집 중인 런이어도 진행한다 ★위험★
EOF
}

while [ $# -gt 0 ]; do
   case "$1" in
      --run)       RUNS="$RUNS $2"; shift 2 ;;
      --src)       SRC=$2; shift 2 ;;
      --dst)       DST=$2; shift 2 ;;
      --only)      SUBS=$(printf '%s' "$2" | tr ',' ' '); shift 2 ;;
      --dry-run|-n) DRYRUN=1; shift ;;
      --no-verify) VERIFY=0; shift ;;
      --force)     FORCE=1; shift ;;
      --nice)      NICE=$2; shift 2 ;;
      -h|--help)   usage; exit 0 ;;
      *)           usage; die "모르는 옵션 : $1" ;;
   esac
done

[ -n "${RUNS// /}" ] || { usage; die "--run 이 필요하다"; }
command -v rsync >/dev/null || die "rsync 가 필요하다"

pad6() { printf '%06d' "$((10#$1))"; }

# 수집 중인 런은 절대 건드리지 않는다. heartbeat 가 정본이다.
running_run() {
   [ -f "$HB" ] || return 1
   awk -F= '$1=="run"{print $2}' "$HB" 2>/dev/null | head -1
}

# ---- 체크섬 대조 ----------------------------------------------------
#  -c -n -i : 양쪽에서 각자 체크섬을 계산해 다른 파일만 한 줄씩 낸다.
#  '>f'/'<f' 는 아직 옮겨야 할 파일, '*deleting' 은 목적지의 여분이다.
verify_pair() {          # src dst
   local out n
   out=$(nice -n "$NICE" rsync -a -c -n -i "$1"/ "$2"/ 2>&1) || {
      err "    체크섬 대조 실행 실패"; return 1; }
   n=$(printf '%s\n' "$out" | grep -cE '^[<>]f|^\*deleting') || true
   if [ "${n:-0}" -ne 0 ]; then
      err "    체크섬 불일치 $n 개 — 원본을 지우지 않는다"
      printf '%s\n' "$out" | grep -E '^[<>]f|^\*deleting' | head -10 | sed 's/^/      /'
      return 1
   fi
   return 0
}

move_sub() {             # run_pad sub
   local rp=$1 sub=$2
   local src="$SRC/$rp/$sub" dst="$DST/$rp/$sub" stage="$DST/$rp/.$sub.incoming"
   local n_src n_dst

   if [ ! -d "$src" ] || [ -L "$src" ]; then
      log "  $sub : $src 가 실제 디렉터리가 아니다. 건너뜀"; return 2
   fi
   n_src=$(find "$src" -maxdepth 1 -type f | wc -l)
   [ "$n_src" -eq 0 ] && { log "  $sub : 비어 있다. 건너뜀"; return 2; }

   #  목적지가 원본을 가리키는 링크인가 (예전 --outroot 구성)
   local islink=0 tgt=""
   if [ -L "$dst" ]; then
      islink=1; tgt=$(readlink -f "$dst")
      if [ "$tgt" != "$(readlink -f "$src")" ]; then
         err "  $sub : $dst 가 원본이 아닌 곳을 가리킨다 ($tgt). 사람이 볼 것"; return 1
      fi
   elif [ -d "$dst" ]; then
      warn "  $sub : $dst 가 이미 실제 디렉터리다. 그 안으로 합친다"
   fi

   log "  ${C_C}$sub${C_0} : $n_src 개  $src -> $dst"
   if [ "$DRYRUN" -eq 1 ]; then
      log "    [DRY] rsync -a $src/ $stage/"
      log "    [DRY] 체크섬 대조 뒤 링크 교체, 그 다음 rm -rf $src"
      return 0
   fi

   mkdir -p "$stage" || { err "    $stage 를 만들 수 없다"; return 1; }
   #  --remove-source-files 를 쓰지 않는다. 대조가 끝나기 전에 원본이 사라진다.
   nice -n "$NICE" rsync -a --partial-dir=.rsync-partial --info=progress2 \
        "$src"/ "$stage"/ 2>&1 | tail -1 | sed 's/^/    /'
   [ "${PIPESTATUS[0]}" -ne 0 ] && { err "    rsync 실패. 원본을 남긴다"; return 1; }

   n_dst=$(find "$stage" -maxdepth 1 -type f | wc -l)
   [ "$n_dst" -lt "$n_src" ] && { err "    개수 부족 ($n_dst / $n_src). 원본을 남긴다"; return 1; }

   if [ "$VERIFY" -eq 1 ]; then
      log "    체크섬 대조 중 ($n_src 개)..."
      verify_pair "$src" "$stage" || return 1
      log "    ${C_G}체크섬 일치${C_0}"
   else
      warn "    체크섬 대조를 건너뛰었다"
   fi

   #  자리 바꾸기. 여기의 mv 는 같은 파일시스템 안의 이름 바꾸기(원자적)라
   #  자료를 옮기는 것이 아니다. 위 지침의 'mv 금지' 와 어긋나지 않는다.
   if [ "$islink" -eq 1 ]; then
      rm -f "$dst" || { err "    링크 $dst 를 지울 수 없다"; return 1; }
   elif [ -d "$dst" ]; then
      rsync -a "$stage"/ "$dst"/ && rm -rf "$stage" || return 1
      rm -rf "$src"; log "    ${C_G}$sub 완료${C_0} (합침, 원본 삭제)"; return 0
   fi
   mv -T "$stage" "$dst" || { err "    $stage -> $dst 이름 바꾸기 실패"; return 1; }

   rm -rf "$src" || { err "    원본 $src 를 지우지 못했다. 사람이 볼 것"; return 1; }
   log "    ${C_G}$sub 완료${C_0} (원본 삭제, $n_dst 개)"
   return 0
}

RUNNING=$(running_run || true)
FAILED=0
for r in $RUNS; do
   rp=$(pad6 "$r")
   if [ "$FORCE" -eq 0 ] && [ -n "$RUNNING" ] && [ "$((10#$rp))" -eq "$((10#$RUNNING))" ]; then
      err "run $rp 은 지금 수집 중이다 (heartbeat). 건너뛴다"; FAILED=1; continue
   fi
   [ -d "$SRC/$rp" ] || { warn "run $rp : $SRC/$rp 없음. 건너뜀"; continue; }
   log "${C_C}=== run $rp : $SRC -> $DST ===${C_0}"
   fail=0
   for sub in $SUBS; do
      move_sub "$rp" "$sub"; rc=$?
      [ "$rc" -eq 1 ] && fail=1
   done
   if [ "$fail" -eq 0 ]; then
      #  하위를 다 옮겼으면 빈 껍데기를 치운다. 비어 있을 때만 지운다.
      if [ "$DRYRUN" -eq 0 ] && [ -d "$SRC/$rp" ]; then
         rmdir "$SRC/$rp" 2>/dev/null \
            && log "${C_G}=== run $rp 완료. $SRC/$rp 제거 ===${C_0}" \
            || { log "${C_G}=== run $rp 완료 ===${C_0}"
                 warn "    $SRC/$rp 에 남은 것이 있어 지우지 않았다:"
                 ls -A "$SRC/$rp" | head -5 | sed 's/^/      /'; }
      else
         log "${C_G}=== run $rp 완료 ===${C_0}"
      fi
   else
      err "=== run $rp 미완료. 원본을 남겼다 ==="; FAILED=1
   fi
done
exit $FAILED
