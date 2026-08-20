# RENE DAQ — badrun 목록

문제가 있었던 런 전부. **이 파일은 생성물이다** — 정본은 현장의
`/Data_ssd/LOG/badrun_list.txt` 이고, `scripts/badrun.sh --export` 가 여기로 복사한다.
손으로 고치지 말 것. 고쳐야 하면 정본을 고치고 다시 내보낼 것.

격리된 원시 파일은 `<런>/badrun/` 에 있고 `/data` · `/scratch` ·
경희대 서버로 **같은 트리 구조 그대로** 따라간다.

```
# RENE DAQ badrun list — 문제가 있었던 런 전부. 한 줄에 한 런. 런 번호 오름차순.
#
# 갱신 : scripts/badrun.sh --scan --update-list
# 사본 : docs/BADRUNS.md  (scripts/badrun.sh --export)
# 생성 : 2026-08-21 03:59:08
#
# 범주
#   boot_failed     부팅 실패. 런이 시작되지 못했고 데이터가 없다
#   aborted         시작은 했으나 마감하지 못했다 (onlbit=0)
#   truncated_tail  원시 파일이 쓰기 도중 잘려 ROOT 가 열지 못한다.
#                   그 파일들은 <런>/badrun/ 으로 격리했다
#   prd_gap         원본은 멀쩡한데 PRD 가 빈다. 재처리하면 된다
#   not_processed   원본은 있는데 로컬에 PRD 가 하나도 없다. 후처리를 안 했거나
#                   산출물이 이 PC 에 없다 (경희대에는 있을 수 있다)
#   no_data         런 디렉터리는 있으나 안이 비었다
#
# 앞 네 필드는 고정, 나머지 전부가 메모다.  awk '{print $1,$2}' 로 뽑힌다.
#
# run  분류일시        범주                 서브런              메모
# ── 요약 ─────────────────────────────────────────────────────────
#  문제 런 631 개
#    not_processed             289
#    aborted                   254
#    boot_failed                27
#    prd_gap                    24
#    no_data                    19
#    truncated_tail             14
#    truncated_tail+prd_gap      4
#
#  ★ 사람이 손볼 것 — 원본이 죽어 격리가 필요하거나 이미 격리한 런
#    run 2466   truncated_tail           00038
#    run 2487   truncated_tail           00041
#    run 2547   truncated_tail           00032
#    run 2602   truncated_tail           00032
#    run 2614   truncated_tail           00031
#    run 2627   truncated_tail           00032
#    run 2651   truncated_tail           00036
#    run 2660   truncated_tail           00033
#    run 2664   truncated_tail           00036
#    run 2683   truncated_tail           00031
#    run 2957   truncated_tail           00035
#    run 3207   truncated_tail+prd_gap   01533,01534,01535,01536,01537,01538,01539,01540...외32개
#    run 3520   truncated_tail+prd_gap   00570,00571,00572,00573
#    run 3523   truncated_tail+prd_gap   00324,00325,00326
#    run 3855   truncated_tail           00010
#    run 3923   truncated_tail+prd_gap   00742,00743
#    run 4291   truncated_tail           00869
#    run 4293   truncated_tail           00091
# ─────────────────────────────────────────────────────────────────
#
  27   2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  28   2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  32   2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  33   2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  34   2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  35   2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  54   2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  68   2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  69   2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  103  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  104  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  118  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  130  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  160  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  162  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  196  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  198  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  199  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  218  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  254  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  259  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  260  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  299  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  305  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  378  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  382  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  384  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  467  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  468  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  469  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  473  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  526  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  535  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  537  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  539  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  541  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  551  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  554  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  555  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  556  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  558  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  559  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  560  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  562  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  563  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  564  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  570  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  572  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  573  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  576  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  577  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  580  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  581  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  583  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  585  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  587  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  590  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  604  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  605  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  607  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  618  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  619  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  620  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  621  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  623  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  645  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  652  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  655  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  659  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  661  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  662  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  687  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  688  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  690  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  743  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  747  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  751  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  753  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  757  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  758  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  812  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  813  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  814  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  815  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  816  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  817  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  818  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  819  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  820  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  821  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  822  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  823  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  826  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  827  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  828  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  831  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  832  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  833  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  834  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  836  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  837  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  838  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  839  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  840  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  853  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  854  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  855  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  859  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  861  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  862  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  863  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  864  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  866  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  867  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  868  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  912  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  918  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  923  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  995  2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1009 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1016 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1017 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1024 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1026 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1027 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1028 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1029 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1030 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1036 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1076 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1083 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1084 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1085 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1125 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1126 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1127 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1128 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1220 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1223 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1336 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1337 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1338 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1343 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1346 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1349 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1352 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1354 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1356 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1360 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1362 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1364 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1365 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1366 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1370 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1373 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1374 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1385 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1401 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1410 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1412 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1414 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1415 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1416 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1427 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1429 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1442 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1452 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1456 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1462 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1467 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1478 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1506 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1507 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1508 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1509 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1681 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1682 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1683 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1695 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1701 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1702 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1711 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1724 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1725 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1726 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1783 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1910 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1917 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1918 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1939 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  1951 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2008 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2026 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2041 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2042 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2043 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2044 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2057 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2058 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2070 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2078 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2079 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2085 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2162 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2172 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2181 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2224 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2250 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2409 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2411 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2412 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2413 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2414 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2415 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2416 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2417 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2418 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2419 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2420 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2421 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2422 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2423 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2424 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2425 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2426 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2427 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2428 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2429 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2430 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2431 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2432 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2433 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2434 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2435 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2441 2026-08-21 03:57:40 aborted                -                      DB onlbit=0
  2442 2026-08-21 03:57:40 prd_gap                08547,08548            FADC 8546 / PRD 8547. 서브런 08547 08548 은 원본이 멀쩡하다. 재처리하면 된다
  2443 2026-08-21 03:57:40 prd_gap                10641,10642            FADC 10643 / PRD 10641. 서브런 10641 10642 은 원본이 멀쩡하다. 재처리하면 된다
  2444 2026-08-21 03:57:40 prd_gap                05302,05303            FADC 5304 / PRD 5302. 서브런 05302 05303 은 원본이 멀쩡하다. 재처리하면 된다
  2445 2026-08-21 03:57:40 not_processed          -                      FADC 3 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2446 2026-08-21 03:57:40 not_processed          -                      FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2450 2026-08-21 03:57:40 not_processed          -                      FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2464 2026-08-21 03:57:40 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2466 2026-08-21 03:57:40 truncated_tail         00038                  FADC 39 / PRD 38. 격리 대상 서브런 00038 (원본이 ROOT 로 안 열린다)
  2472 2026-08-21 03:57:40 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  2473 2026-08-21 03:57:40 not_processed          -                      FADC 39 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2482 2026-08-21 03:57:40 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  2483 2026-08-21 03:57:40 not_processed          -                      FADC 40 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2485 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2487 2026-08-21 03:57:40 truncated_tail         00041                  FADC 42 / PRD 41. 격리 대상 서브런 00041 (원본이 ROOT 로 안 열린다)
  2495 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2499 2026-08-21 03:57:40 not_processed          -                      FADC 32 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2504 2026-08-21 03:57:40 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  2505 2026-08-21 03:57:40 not_processed          -                      FADC 35 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2511 2026-08-21 03:57:40 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  2512 2026-08-21 03:57:40 not_processed          -                      FADC 34 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2515 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2518 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2523 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2524 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2526 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2527 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2530 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2532 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2535 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2536 2026-08-21 03:57:40 not_processed          -                      FADC 33 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2537 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2538 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2541 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2542 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2545 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2547 2026-08-21 03:57:40 truncated_tail         00032                  FADC 33 / PRD 32. 격리 대상 서브런 00032 (원본이 ROOT 로 안 열린다)
  2549 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2551 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2554 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2556 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2560 2026-08-21 03:57:40 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2562 2026-08-21 03:57:40 not_processed          -                      aborted; FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2563 2026-08-21 03:57:40 not_processed          -                      aborted; FADC 3 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2564 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2565 2026-08-21 03:57:40 not_processed          -                      FADC 52 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2566 2026-08-21 03:57:40 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2567 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2568 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2569 2026-08-21 03:57:40 not_processed          -                      FADC 51 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2573 2026-08-21 03:57:40 not_processed          -                      FADC 39 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2574 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2582 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2583 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2600 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2601 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2602 2026-08-21 03:57:40 truncated_tail         00032                  FADC 33 / PRD 32. 격리 대상 서브런 00032 (원본이 ROOT 로 안 열린다)
  2604 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2614 2026-08-21 03:57:40 truncated_tail         00031                  FADC 32 / PRD 31. 격리 대상 서브런 00031 (원본이 ROOT 로 안 열린다)
  2616 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2617 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2619 2026-08-21 03:57:40 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2620 2026-08-21 03:57:40 not_processed          -                      FADC 30 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2621 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2622 2026-08-21 03:57:40 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2627 2026-08-21 03:57:40 truncated_tail         00032                  FADC 33 / PRD 32. 격리 대상 서브런 00032 (원본이 ROOT 로 안 열린다)
  2630 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2631 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2641 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2645 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2646 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2651 2026-08-21 03:57:40 truncated_tail         00036                  FADC 37 / PRD 36. 격리 대상 서브런 00036 (원본이 ROOT 로 안 열린다)
  2656 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2657 2026-08-21 03:57:40 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2658 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2660 2026-08-21 03:57:40 truncated_tail         00033                  FADC 34 / PRD 33. 격리 대상 서브런 00033 (원본이 ROOT 로 안 열린다)
  2664 2026-08-21 03:57:40 truncated_tail         00036                  FADC 37 / PRD 36. 격리 대상 서브런 00036 (원본이 ROOT 로 안 열린다)
  2683 2026-08-21 03:57:40 truncated_tail         00031                  FADC 32 / PRD 31. 격리 대상 서브런 00031 (원본이 ROOT 로 안 열린다)
  2699 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2711 2026-08-21 03:57:40 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2754 2026-08-21 03:57:40 aborted                -                      DB onlbit=0; 다만 후처리는 완결됐다 (FADC 1 = PRD 1)
  2768 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2785 2026-08-21 03:57:40 prd_gap                01830                  FADC 1831 / PRD 1830. 서브런 01830 은 원본이 멀쩡하다. 재처리하면 된다
  2789 2026-08-21 03:57:40 not_processed          -                      aborted; FADC 3 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2794 2026-08-21 03:57:40 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2803 2026-08-21 03:57:40 aborted                -                      DB onlbit=0; 다만 후처리는 완결됐다 (FADC 62 = PRD 62)
  2804 2026-08-21 03:57:40 prd_gap                00061                  FADC 62 / PRD 61. 서브런 00061 은 원본이 멀쩡하다. 재처리하면 된다
  2846 2026-08-21 03:57:40 not_processed          -                      aborted; FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2855 2026-08-21 03:57:40 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2918 2026-08-21 03:57:40 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  2928 2026-08-21 03:57:40 aborted                -                      DB onlbit=0; 다만 후처리는 완결됐다 (FADC 3 = PRD 3)
  2933 2026-08-21 03:57:40 not_processed          -                      FADC 31 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  2939 2026-08-21 03:57:40 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  2940 2026-08-21 03:57:40 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  2953 2026-08-21 03:57:40 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  2957 2026-08-21 03:57:40 truncated_tail         00035                  FADC 36 / PRD 35. 격리 대상 서브런 00035 (원본이 ROOT 로 안 열린다)
  2961 2026-08-21 03:57:40 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  2962 2026-08-21 03:57:40 aborted                -                      DB onlbit=0; 다만 후처리는 완결됐다 (FADC 2 = PRD 2)
  2963 2026-08-21 03:57:40 aborted                -                      DB onlbit=0; 다만 후처리는 완결됐다 (FADC 1 = PRD 1)
  2969 2026-08-21 03:57:40 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  2973 2026-08-21 03:57:40 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  2975 2026-08-21 03:57:40 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  2990 2026-08-21 03:57:40 aborted                -                      DB onlbit=0; 다만 후처리는 완결됐다 (FADC 6 = PRD 6)
  2991 2026-08-21 03:57:40 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  2995 2026-08-21 03:57:40 aborted                -                      DB onlbit=0; 다만 후처리는 완결됐다 (FADC 1 = PRD 1)
  3002 2026-08-21 03:57:40 not_processed          -                      FADC 7 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3011 2026-08-21 03:57:40 prd_gap                00001,00002,00003,00004,00005,00006,00007 FADC 8 / PRD 1. 서브런 00001 00002 00003 00004 00005 00006 00007 은 원본이 멀쩡하다. 재처리하면 된다
  3014 2026-08-21 03:57:40 aborted                -                      DB onlbit=0; 다만 후처리는 완결됐다 (FADC 1 = PRD 1)
  3051 2026-08-21 03:57:40 prd_gap                00676,00677,00678,00679,00680,00681,00682,00683...외32개 FADC 716 / PRD 1. 서브런 00676 00677 00678 00679 00680 00681 00682 00683 00684 00685 00686 00687 00688 00689 00690 00691 00692 00693 00694 00695 00696 00697 00698 00699 00700 00701 00702 00703 00704 00705 00706 00707 00708 00709 00710 00711 00712 00713 00714 00715 은 원본이 멀쩡하다. 재처리하면 된다; 빠진 서브런 715 개 중 뒤 40 개만 열어 봤다 (--max-check)
  3067 2026-08-21 03:57:40 not_processed          -                      FADC 636 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3074 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3076 2026-08-21 03:57:40 not_processed          -                      FADC 63 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3087 2026-08-21 03:57:40 not_processed          -                      FADC 6 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3103 2026-08-21 03:57:40 not_processed          -                      FADC 6 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3104 2026-08-21 03:57:40 not_processed          -                      FADC 6 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3112 2026-08-21 03:57:40 not_processed          -                      FADC 6 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3138 2026-08-21 03:57:40 not_processed          -                      FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3150 2026-08-21 03:57:40 not_processed          -                      aborted; FADC 4 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3164 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3179 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3207 2026-08-21 03:57:40 truncated_tail+prd_gap 01533,01534,01535,01536,01537,01538,01539,01540...외32개 FADC 1573 / PRD 1417. 격리 대상 서브런 01572 (원본이 ROOT 로 안 열린다); 서브런 01571 은 원본은 멀쩡하나 다음 SADC 가 죽어 merge 를 끝낼 수 없다. 부분 Merged 에서 PRD 복구 가능; 서브런 01533 01534 01535 01536 01537 01538 01539 01540 01541 01542 01543 01544 01545 01546 01547 01548 01549 01550 01551 01552 01553 01554 01555 01556 01557 01558 01559 01560 01561 01562 01563 01564 01565 01566 01567 01568 01569 01570 은 원본이 멀쩡하다. 재처리하면 된다; 빠진 서브런 156 개 중 뒤 40 개만 열어 봤다 (--max-check)
  3250 2026-08-21 03:57:40 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3251 2026-08-21 03:57:40 not_processed          -                      FADC 11 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3253 2026-08-21 03:57:40 not_processed          -                      FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3314 2026-08-21 03:57:41 not_processed          -                      FADC 16 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3422 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3440 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3460 2026-08-21 03:57:41 prd_gap                00009,00010            FADC 11 / PRD 9. 서브런 00009 00010 은 원본이 멀쩡하다. 재처리하면 된다
  3461 2026-08-21 03:57:41 prd_gap                00006,00007,00008,00009,00010 FADC 11 / PRD 6. 서브런 00006 00007 00008 00009 00010 은 원본이 멀쩡하다. 재처리하면 된다
  3466 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 13 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3467 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 27 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3468 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 3 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3469 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3470 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3473 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 32 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3474 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3475 2026-08-21 03:57:41 aborted                -                      DB onlbit=0; 다만 후처리는 완결됐다 (FADC 98 = PRD 98)
  3477 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 6 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3478 2026-08-21 03:57:41 prd_gap                00950,00951,00952,00953,00954,00955,00956,00957...외4개 FADC 962 / PRD 950. 서브런 00950 00951 00952 00953 00954 00955 00956 00957 00958 00959 00960 00961 은 원본이 멀쩡하다. 재처리하면 된다
  3479 2026-08-21 03:57:41 not_processed          -                      FADC 127 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3480 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3481 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3482 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 3 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3483 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3484 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 7 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3485 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3486 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3487 2026-08-21 03:57:41 not_processed          -                      FADC 3 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3492 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 65 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3493 2026-08-21 03:57:41 not_processed          -                      FADC 68 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3494 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 72 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3495 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 36 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3499 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 21 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3502 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 9 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3504 2026-08-21 03:57:41 not_processed          -                      FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3505 2026-08-21 03:57:41 not_processed          -                      FADC 5 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3506 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3507 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3508 2026-08-21 03:57:41 not_processed          -                      FADC 4 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3509 2026-08-21 03:57:41 not_processed          -                      FADC 4 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3510 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3511 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3512 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3513 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3514 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3515 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3517 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 3 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3518 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3519 2026-08-21 03:57:41 prd_gap                00678                  FADC 679 / PRD 678. 서브런 00678 은 원본이 멀쩡하다. 재처리하면 된다
  3520 2026-08-21 03:57:41 truncated_tail+prd_gap 00570,00571,00572,00573 FADC 574 / PRD 570. 격리 대상 서브런 00573 (원본이 ROOT 로 안 열린다); 서브런 00572 은 원본은 멀쩡하나 다음 SADC 가 죽어 merge 를 끝낼 수 없다. 부분 Merged 에서 PRD 복구 가능; 서브런 00570 00571 은 원본이 멀쩡하다. 재처리하면 된다
  3523 2026-08-21 03:57:41 truncated_tail+prd_gap 00324,00325,00326      FADC 327 / PRD 324. 격리 대상 서브런 00326 (원본이 ROOT 로 안 열린다); 서브런 00325 은 원본은 멀쩡하나 다음 SADC 가 죽어 merge 를 끝낼 수 없다. 부분 Merged 에서 PRD 복구 가능; 서브런 00324 은 원본이 멀쩡하다. 재처리하면 된다
  3525 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3526 2026-08-21 03:57:41 prd_gap                00081,00082,00083,00084,00085,00086,00087,00088...외28개 FADC 117 / PRD 81. 서브런 00081 00082 00083 00084 00085 00086 00087 00088 00089 00090 00091 00092 00093 00094 00095 00096 00097 00098 00099 00100 00101 00102 00103 00104 00105 00106 00107 00108 00109 00110 00111 00112 00113 00114 00115 00116 은 원본이 멀쩡하다. 재처리하면 된다
  3527 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3528 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3529 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3530 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3531 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3532 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3533 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3534 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3535 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3536 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3537 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3538 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3540 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3541 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3542 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3543 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3544 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3545 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3546 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3547 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3548 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3549 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3550 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3554 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3556 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3557 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3558 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3559 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3566 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3567 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3568 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3569 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3571 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3572 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3573 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3574 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3576 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3577 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3580 2026-08-21 03:57:41 not_processed          -                      FADC 11 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3581 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3586 2026-08-21 03:57:41 not_processed          -                      FADC 7 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3679 2026-08-21 03:57:41 not_processed          -                      FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3690 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3730 2026-08-21 03:57:41 not_processed          -                      FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3734 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3744 2026-08-21 03:57:41 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  3761 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3784 2026-08-21 03:57:41 not_processed          -                      FADC 3 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3786 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3787 2026-08-21 03:57:41 not_processed          -                      FADC 91 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3788 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3789 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3790 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3791 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3792 2026-08-21 03:57:41 aborted                -                      DB onlbit=0; 다만 후처리는 완결됐다 (FADC 1 = PRD 1)
  3793 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3794 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3796 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3797 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3798 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3799 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 4 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3800 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3801 2026-08-21 03:57:41 aborted                -                      DB onlbit=0; 다만 후처리는 완결됐다 (FADC 15 = PRD 15)
  3802 2026-08-21 03:57:41 not_processed          -                      FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3803 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3806 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3808 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3817 2026-08-21 03:57:41 not_processed          -                      FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3819 2026-08-21 03:57:41 not_processed          -                      FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3820 2026-08-21 03:57:41 not_processed          -                      FADC 10 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3821 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3822 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3824 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3825 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3826 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3827 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3828 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3829 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3830 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3832 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3833 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3834 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3836 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3837 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3838 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3839 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3840 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3841 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3855 2026-08-21 03:57:41 truncated_tail         00010                  FADC 11 / PRD 10. 격리 대상 서브런 00010 (원본이 ROOT 로 안 열린다)
  3862 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3873 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3874 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3875 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3876 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3877 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3878 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3879 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3880 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3885 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3886 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3887 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3888 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3889 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3890 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3891 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3892 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3894 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3896 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3897 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3898 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3899 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3902 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3909 2026-08-21 03:57:41 not_processed          -                      FADC 724 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3910 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3920 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3921 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3922 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3923 2026-08-21 03:57:41 truncated_tail+prd_gap 00742,00743            FADC 744 / PRD 742. 격리 대상 서브런 00743 (원본이 ROOT 로 안 열린다); 서브런 00742 은 원본은 멀쩡하나 다음 SADC 가 죽어 merge 를 끝낼 수 없다. 부분 Merged 에서 PRD 복구 가능
  3934 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3936 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3940 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3951 2026-08-21 03:57:41 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  3954 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3955 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3962 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3965 2026-08-21 03:57:41 not_processed          -                      FADC 84 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3976 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3978 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  3986 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4005 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4013 2026-08-21 03:57:41 not_processed          -                      FADC 10 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4014 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4026 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4041 2026-08-21 03:57:41 not_processed          -                      FADC 4 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4043 2026-08-21 03:57:41 not_processed          -                      FADC 4 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4044 2026-08-21 03:57:41 not_processed          -                      FADC 4 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4045 2026-08-21 03:57:41 not_processed          -                      FADC 5 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4047 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4048 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4073 2026-08-21 03:57:41 not_processed          -                      FADC 40 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4088 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4097 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 3 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4100 2026-08-21 03:57:41 not_processed          -                      FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4102 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4103 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4104 2026-08-21 03:57:41 not_processed          -                      FADC 18 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4109 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4110 2026-08-21 03:57:41 aborted                -                      DB onlbit=0; 다만 후처리는 완결됐다 (FADC 1 = PRD 1)
  4134 2026-08-21 03:57:41 prd_gap                00010                  FADC 11 / PRD 10. 서브런 00010 은 원본이 멀쩡하다. 재처리하면 된다
  4138 2026-08-21 03:57:41 prd_gap                00009                  FADC 10 / PRD 9. 서브런 00009 은 원본이 멀쩡하다. 재처리하면 된다
  4153 2026-08-21 03:57:41 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  4170 2026-08-21 03:57:41 not_processed          -                      FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4171 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4172 2026-08-21 03:57:41 not_processed          -                      FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4173 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 8 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4174 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4176 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4177 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4181 2026-08-21 03:57:41 prd_gap                03987                  FADC 5558 / PRD 5557. 서브런 03987 은 원본이 멀쩡하다. 재처리하면 된다
  4210 2026-08-21 03:57:41 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  4216 2026-08-21 03:57:41 prd_gap                01867                  FADC 3680 / PRD 3679. 서브런 01867 은 원본이 멀쩡하다. 재처리하면 된다
  4219 2026-08-21 03:57:41 prd_gap                06315,06316,06317,06318,06319,06320,06321,06322...외32개 FADC 6355 / PRD 320. 서브런 06315 06316 06317 06318 06319 06320 06321 06322 06323 06324 06325 06326 06327 06328 06329 06330 06331 06332 06333 06334 06335 06336 06337 06338 06339 06340 06341 06342 06343 06344 06345 06346 06347 06348 06349 06350 06351 06352 06353 06354 은 원본이 멀쩡하다. 재처리하면 된다; 빠진 서브런 6035 개 중 뒤 40 개만 열어 봤다 (--max-check)
  4220 2026-08-21 03:57:41 aborted                -                      DB onlbit=0; 다만 후처리는 완결됐다 (FADC 1 = PRD 1)
  4221 2026-08-21 03:57:41 prd_gap                04296,04297,04298,04299,04300,04301,04302,04303...외32개 FADC 4336 / PRD 4105. 서브런 04296 04297 04298 04299 04300 04301 04302 04303 04304 04305 04306 04307 04308 04309 04310 04311 04312 04313 04314 04315 04316 04317 04318 04319 04320 04321 04322 04323 04324 04325 04326 04327 04328 04329 04330 04331 04332 04333 04334 04335 은 원본이 멀쩡하다. 재처리하면 된다; 빠진 서브런 231 개 중 뒤 40 개만 열어 봤다 (--max-check)
  4224 2026-08-21 03:57:41 prd_gap                01376,01377,01378,01379,01380,01381,01382,01383...외32개 FADC 1416 / PRD 544. 서브런 01376 01377 01378 01379 01380 01381 01382 01383 01384 01385 01386 01387 01388 01389 01390 01391 01392 01393 01394 01395 01396 01397 01398 01399 01400 01401 01402 01403 01404 01405 01406 01407 01408 01409 01410 01411 01412 01413 01414 01415 은 원본이 멀쩡하다. 재처리하면 된다; 빠진 서브런 872 개 중 뒤 40 개만 열어 봤다 (--max-check)
  4225 2026-08-21 03:57:41 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  4229 2026-08-21 03:57:41 no_data                -                      런 디렉터리가 있으나 FADC 도 PRD 도 없다
  4231 2026-08-21 03:57:41 prd_gap                00926                  FADC 1323 / PRD 1322. 서브런 00926 은 원본이 멀쩡하다. 재처리하면 된다
  4233 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4235 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4236 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 1 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4237 2026-08-21 03:57:41 prd_gap                05697,10488            FADC 12722 / PRD 12720. 서브런 05697 10488 은 원본이 멀쩡하다. 재처리하면 된다
  4238 2026-08-21 03:57:41 prd_gap                05916,05938,06482,07742,08194,10711 FADC 11149 / PRD 11143. 서브런 05916 05938 06482 07742 08194 10711 은 원본이 멀쩡하다. 재처리하면 된다
  4239 2026-08-21 03:57:41 prd_gap                08577,10061            FADC 13020 / PRD 13018. 서브런 08577 10061 은 원본이 멀쩡하다. 재처리하면 된다
  4240 2026-08-21 03:57:41 prd_gap                11397,11398,11399,11400,11401,11402,11403,11404...외32개 FADC 11437 / PRD 9204. 서브런 11397 11398 11399 11400 11401 11402 11403 11404 11405 11406 11407 11408 11409 11410 11411 11412 11413 11414 11415 11416 11417 11418 11419 11420 11421 11422 11423 11424 11425 11426 11427 11428 11429 11430 11431 11432 11433 11434 11435 11436 은 원본이 멀쩡하다. 재처리하면 된다; 빠진 서브런 2233 개 중 뒤 40 개만 열어 봤다 (--max-check)
  4241 2026-08-21 03:57:41 not_processed          -                      FADC 804 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4242 2026-08-21 03:57:41 not_processed          -                      FADC 1586 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4243 2026-08-21 03:57:41 not_processed          -                      FADC 1782 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4244 2026-08-21 03:57:41 not_processed          -                      FADC 15589 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4245 2026-08-21 03:57:41 not_processed          -                      FADC 8017 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4246 2026-08-21 03:57:41 not_processed          -                      FADC 5104 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4247 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4248 2026-08-21 03:57:41 aborted                -                      aborted; not finalized (marked 20260815-033023)
  4249 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4250 2026-08-21 03:57:41 aborted                -                      aborted; not finalized (marked 20260815-033023)
  4251 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4252 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4253 2026-08-21 03:57:41 aborted                -                      aborted; not finalized (marked 20260815-033023)
  4254 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4255 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4256 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4257 2026-08-21 03:57:41 aborted                -                      aborted; not finalized (marked 20260815-033023)
  4258 2026-08-21 03:57:41 aborted                -                      aborted; not finalized (marked 20260815-033023)
  4259 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4260 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4261 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4262 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4263 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4264 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4265 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4266 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4267 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4268 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4269 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4270 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4271 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 3 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4272 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4273 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4274 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 4 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4275 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4276 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 19 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4277 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 2 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4278 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started (marked 20260815-033023)
  4279 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 3 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4280 2026-08-21 03:57:41 not_processed          -                      FADC 65 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4281 2026-08-21 03:57:41 not_processed          -                      aborted; FADC 5 / PRD 0. 로컬에 후처리 산출물이 없다 — 후처리를 안 했거나 산출물이 이 PC 에 없다
  4284 2026-08-21 03:57:41 aborted                -                      aborted; not finalized (marked 20260815-033023); 다만 후처리는 완결됐다 (FADC 12 = PRD 12)
  4291 2026-08-21 03:31:03 truncated_tail         00869                  원시 파일 2 개를 badrun/ 으로 격리했다. 나머지는 완결 (FADC 869 = PRD 869). 사유는 badrun/README.txt
  4293 2026-08-21 03:31:03 truncated_tail         00091                  원시 파일 2 개를 badrun/ 으로 격리했다. 나머지는 완결 (FADC 91 = PRD 91). 사유는 badrun/README.txt
  4295 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started
  4296 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started
  4297 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started
  4298 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started
  4299 2026-08-21 03:57:41 boot_failed            -                      boot failed; run never started
```
