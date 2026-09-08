#!/usr/bin/env bash
# gen-summary-html.sh <tsvdir> <out.html> <legacy|dst> <refresh_s>
#
# run_summary.tsv + pair_summary.tsv (+ metrics_summary.tsv, dst 모드) 를 읽어
# 런당 1줄 표 페이지를 만든다. 스펙 §5. 순수 소비자다 -- 어느 런을 실을지는
# run-summary.sh / ibd-summary.sh / metrics.sh 가 TSV 를 쓸 때 이미 걸러
# 두었다(완결 게이트, 수집 중인 런 제외). 여기서는 다시 거르지 않는다.
#
# 열 16개(Run 다음이 type), run_summary.tsv/pair_summary.tsv/
# metrics_summary.tsv 의 1-based 열 번호는 각 파일의 WriteTsv() 가
# 정본이다(BuildRunSummary.C/BuildPairSummary.C/BuildMetrics.C):
#   run_summary  run(1) n_subrun(2) n_bad(3) epoch_start(4) epoch_end(5)
#                wall_s(6) span_s(7) live_s(8) dead_s(9) n_type1(10)
#                n_type2(11) n_type3(12) source(13)
#   pair_summary run(1) tag(2) src(3) live_s(4) n_paired(5) n_paired_acci(6)
#                n_ibd(7) n_ibd_acci(8) ... n_single(16) r_ll(17) n_subrun(18)
#   metrics_summary(=pair_summary 와 앞 11열이 같은 자리) ... 뒤에
#                n_mu(12) n_mu_shower(13) n_lihe(14) e_lihe(15) lihe_stat(16)
#                n_fn_side(17) n_fn_side_scaled(18) ...
#   runclass     run(1) type(2) -- gen-runclass.sh 가 만든다(physics/
#                calibration/test/-, 컨트롤러 판정 R9). 이 스크립트는 순수
#                소비자로 그 파일을 키 조회만 한다 -- 분류 규칙을 여기서
#                다시 판단하지 않는다. 파일이 없거나 그 안에 이 런이 없으면
#                '-' 다.
#
# metrics_source=dst 일 때만 fast-n·Li/He 를 채운다 -- 그것도 Li/He 는
# lihe_stat=="ok" 일 때만, fast-n 은 n_fn_side_scaled>=0 (음수는 '그 정보
# 없음' 관례, BuildMetrics.C) 일 때만이다. 레시피가 ★예비이기 때문에 값
# 옆에 '(예비)' 를 단다(BuildMetrics.C 머리말 -- "웹은 검증 전까지 이 값을
# '(예비)' 로 표시한다"). legacy 모드거나 값이 없으면 '—'(em dash) 로 둔다.
#
# 그 밖의 열이 없으면 '-'(hyphen) 다 -- 열이 밀리는 일은 절대 없다. 언제나
# 16열을 낸다.
#
# R_LL·선원(src) 은 run 만으로 키를 잡는다(태그별이 아니다) -- 표에 R_LL
# 열이 하나뿐이라서다. 같은 런에 _nGd/_nH 두 행이 있으면 TSV 안에서 나중에
# 나오는 쪽(정렬상 '_nGd' < '_nH' 라 '_nH') 이 이긴다. 두 태그의 R_LL 이
# 다를 수 있음을 알고 쓴 단순화다.
set -u

USAGE='사용법 : gen-summary-html.sh <TSV디렉터리> <출력.html> <legacy|dst> <refresh_s>'
TSV=${1:?$USAGE}
OUTF=${2:?$USAGE}
SRC=${3:-legacy}
REFRESH=${4:-600}

case "$SRC" in
   legacy|dst) ;;
   *) echo "metrics_source 는 legacy 또는 dst 라야 한다 : '$SRC'"; exit 1 ;;
esac

RS="$TSV/run_summary.tsv"
PS="$TSV/pair_summary.tsv"
MS="$TSV/metrics_summary.tsv"
RC="$TSV/runclass.tsv"

[ -r "$RS" ] && [ -r "$PS" ] || { echo "표의 입력이 없다 : $RS / $PS"; exit 1; }
[ "$SRC" = dst ] && [ ! -r "$MS" ] && { echo "metrics_source=dst 인데 $MS 가 없다"; exit 1; }

#  legacy 모드에서는 MS 를 awk 인자로 넘기지 않는다. 넘기면 파일이 없을 때
#  awk 가 그 자리에서 죽는다 -- 그리고 legacy 갈래는 애초에 그 내용을
#  쓰지도 않는다. runclass.tsv(RC) 는 두 모드 모두에서 선택 사항이다 --
#  gen-runclass.sh 가 실패해도(websummary.sh 는 WARN 으로만 다룬다) 이
#  스크립트는 죽지 않고 type 열을 전부 '-' 로 낸다.
AWK_FILES=("$RS" "$PS")
[ "$SRC" = dst ] && AWK_FILES+=("$MS")
HAVE_RC=0
[ -r "$RC" ] && { AWK_FILES+=("$RC"); HAVE_RC=1; }

mkdir -p "$(dirname "$OUTF")" 2>/dev/null

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT

awk -F'\t' -v RSF="$RS" -v PSF="$PS" -v MSF="$MS" -v RCF="$RC" -v SRC="$SRC" '
   #  TSV 에서 온 문자열을 HTML 에 넣기 전에 반드시 거친다. 지금 이 표에서
   #  그런 열은 선원(src)과 type 둘이다 -- 나머지 14열은 이 스크립트가 직접
   #  만든 숫자/고정 문자열(strftime·sprintf·"-"·"—")이라 &·<·> 를 담을 수
   #  없다. src 도 지금은 ibd-summary.sh 의 정규식이 AmBe/Cs137/Co60/Na22/
   #  Zn65/Cf252/none/? 로만 좁혀 두어(닫힌 집합) 위험이 없고, type 도
   #  gen-runclass.sh 가 physics/calibration/test/- 로만 낸다(위험이 없다).
   #  다만 그 규칙이 나중에 느슨해지거나 다른 열이 문자열을 그대로 옮기게
   #  바뀔 수 있으므로 여기서 한 번 더 막아 둔다. ".src"/".pre" 로 감싸는
   #  신뢰된 마크업 자체는
   #  이스케이프하지 않는다 -- TSV 값을 감싸기 *전에* 이 함수를 거치기
   #  때문이다. 순서 중요 : &(먼저) -> < -> > . 나중에 하면 방금 만든
   #  &lt;/&gt; 의 & 까지 다시 이스케이프되어 "&amp;lt;" 처럼 이중으로
   #  깨진다(실측 확인).
   function html_escape(s) {
      gsub(/&/, "\\&amp;", s)
      gsub(/</, "\\&lt;", s)
      gsub(/>/, "\\&gt;", s)
      return s
   }
   /^#/ { next }
   NF < 2 { next }

   FILENAME==RSF {
      r = $1
      have[r] = 1
      es[r]   = $4
      wall[r] = $6
      live[r] = $8
      t1[r]   = $10
      t2[r]   = $11
      t3[r]   = $12
      next
   }

   FILENAME==PSF {
      if (SRC != "legacy") next
      ibd[$1 $2] = $7
      acc[$1 $2] = $8
      rll[$1]    = $17
      src[$1]    = $3
      next
   }

   FILENAME==MSF {
      if (SRC != "dst") next
      ibd[$1 $2]   = $7
      acc[$1 $2]   = $8
      rll[$1]      = $10
      src[$1]      = $3
      lihe[$1]     = $14
      lihestat[$1] = $16
      fns[$1]      = $18
      next
   }

   #  RCF 는 legacy/dst 어느 쪽이든 같다 -- gen-runclass.sh 의 출력에 모드
   #  구분이 없다(그 스크립트는 SRC 인자를 아예 모른다). 파일이 안 열렸으면
   #  (runclass.tsv 가 없으면) 이 블록은 한 번도 안 불린다 -- typ[] 가 비면
   #  END 에서 전부 '-' 로 내려간다.
   FILENAME==RCF {
      typ[$1] = $2
      next
   }

   END {
      PROCINFO["sorted_in"] = "@ind_num_desc"        # 최신(큰 run) 이 위
      for (r in have) {
         start = (es[r]+0 > 0)   ? strftime("%Y-%m-%d %H:%M", es[r]) : "-"
         lw    = (wall[r]+0 > 0) ? sprintf("%.1f/%.1f", live[r]/3600, wall[r]/3600) : "-"
         total = t1[r] + t2[r] + t3[r]
         typev = (r in typ) ? html_escape(typ[r]) : "-"

         ibdgd = ((r "_nGd") in ibd) ? ibd[r "_nGd"] : "-"
         accgd = ((r "_nGd") in acc) ? acc[r "_nGd"] : "-"
         ibdh  = ((r "_nH")  in ibd) ? ibd[r "_nH"]  : "-"
         acch  = ((r "_nH")  in acc) ? acc[r "_nH"]  : "-"
         rllv  = (r in rll) ? sprintf("%.2f", rll[r]) : "-"

         fnv = "—"; lhv = "—"
         if (SRC == "dst") {
            if ((r in fns) && fns[r]+0 >= 0)
               fnv = sprintf("%.1f <span class=\"pre\">(예비)</span>", fns[r])
            if ((r in lihestat) && lihestat[r] == "ok")
               lhv = sprintf("%.1f <span class=\"pre\">(예비)</span>", lihe[r])
         }

         #  선원이 '?'(모름) 나 'none'(선원 없음 -- 보통의 물리 런. 뜻은
         #  BuildPairSummary.C:92 의 주석 "AmBe | Cs137 | ... | none | ?"
         #  이 정본이다) 이면 강조하지 않는다. AmBe 등 진짜 선원 런만
         #  .src 로 눈에 띄게 한다 -- 강조를 다 걸면 안전장치가 무뎌진다.
         srcv = (r in src) ? html_escape(src[r]) : "-"
         if (srcv != "-" && srcv != "?" && srcv != "none")
            srcv = "<span class=\"src\">" srcv "</span>"

         printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                r, typev, start, lw, total, t1[r], t2[r], t3[r], \
                ibdgd, accgd, ibdh, acch, rllv, fnv, lhv, srcv
      }
   }
' "${AWK_FILES[@]}" > "$TMP"

NOWSTR=$(date '+%F %T')
if [ "$SRC" = dst ]; then
   CAPTION="갱신 : $NOWSTR  ·  출처 : $SRC  ·  fast-n·Li/He 는 분석팀 검증 전 <span class=\"pre\">(예비)</span>"
else
   CAPTION="갱신 : $NOWSTR  ·  출처 : $SRC"
fi

{
cat <<HTML
<!DOCTYPE html><html lang="ko"><head><meta charset="utf-8">
<meta http-equiv="refresh" content="$REFRESH">
<title>RENE Run Summary</title>
<style>
 body{font-family:sans-serif;margin:16px;background:#fafafa}
 table{border-collapse:collapse;font-size:13px;white-space:nowrap}
 th,td{border:1px solid #ccc;padding:3px 8px;text-align:right}
 th{background:#eef;position:sticky;top:0}
 td:first-child,th:first-child{text-align:center;font-weight:bold}
 .src{color:#a50}  .pre{color:#888;font-size:11px}
</style></head><body>
<h2>RENE Run Summary</h2>
<p>$CAPTION</p>
<table><tr><th>Run</th><th>Type</th><th>시작</th><th>live/wall [h]</th><th>전체</th>
<th>Target only</th><th>VETO only</th><th>V+T</th><th>IBD nGd</th><th>acci nGd</th>
<th>IBD nH</th><th>acci nH</th><th>R_LL [Hz]</th><th>fast-n</th><th>Li/He</th><th>선원</th></tr>
HTML
awk -F'\t' '{ printf "<tr>"; for (i=1;i<=NF;i++) printf "<td>%s</td>", $i; print "</tr>" }' "$TMP"
echo "</table></body></html>"
} > "$OUTF"

echo "[SAVED] $OUTF ($(grep -c '<tr>' "$OUTF") 행)"
