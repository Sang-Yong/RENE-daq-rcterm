# trend-xmin.sh — 추이 그림의 x 축 시작 날짜를 monitorcuts.params 에서 읽어 환경변수로 넘긴다 (2026-10-18). source 해서 쓴다.
#
#   키 (config/monitorcuts.params, 없으면 지금처럼 자동 범위)
#      trend_xmin_date = 2026-08-15     rate-trend(01~17) · bg-trend(18~28) · veto-summary(29~31) 의 x 축 시작
#      daily_xmin_date = 2026-08-15     daily(32~36 · 62/63) 의 x 축 시작. 없으면 trend_xmin_date 를 같이 쓴다
#   값은 YYYY-MM-DD 또는 'YYYY-MM-DD HH:MM', 지역 시각(KST). 자료는 버리지 않는다 — 축 범위만 바뀐다.
#   이미 환경에 RENE_TREND_XMIN / RENE_DAILY_XMIN 이 있으면 키가 없을 때 그 값을 쓴다 (시험·별도 OUT 용).
#   MONITORCUTS 로 params 파일을 갈아끼울 수 있다 (기본 <저장소>/config/monitorcuts.params).
_rene_xmin_get() {    # _rene_xmin_get <파일> <키>   -> 값 (없으면 빈 줄)
   [ -r "$1" ] || return 0
   awk -F= -v k="$2" '$1 ~ "^[ \t]*"k"[ \t]*$" { v = $2; sub(/^[ \t]+/, "", v); sub(/[ \t]*#.*$/, "", v); sub(/[ \t]+$/, "", v); if (v != "") r = v }
      END { if (r != "") print r }' "$1" 2>/dev/null
}
rene_trend_xmin_export() {    # rene_trend_xmin_export <저장소 루트>
   local cuts=${MONITORCUTS:-$1/config/monitorcuts.params} t d
   t=$(_rene_xmin_get "$cuts" trend_xmin_date); d=$(_rene_xmin_get "$cuts" daily_xmin_date)
   [ -n "$t" ] || t=${RENE_TREND_XMIN:-}
   [ -n "$d" ] || d=${RENE_DAILY_XMIN:-$t}
   if [ -n "$t" ]; then export RENE_TREND_XMIN="$t"; else unset RENE_TREND_XMIN; fi
   if [ -n "$d" ]; then export RENE_DAILY_XMIN="$d"; else unset RENE_DAILY_XMIN; fi
}
