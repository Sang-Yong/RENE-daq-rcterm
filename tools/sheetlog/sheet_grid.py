"""구글 시트 탭의 그리드(행 수)가 범위 쓰기를 담을 만큼 큰지 보고, 모자라면 늘린다.

  ws.update(range_name="A359:S359", ...) 같은 '범위 쓰기' 는 그리드 밖이면
  APIError 400 'exceeds grid limits' 로 거부된다 (2026-10-16 13:07 부터 Y2026B 가
  358 행으로 꽉 차 sheetlog-auto 가 매시 실패했다).  ws.append_rows 와 insert_row 는
  스스로 그리드를 늘리므로 이 도우미가 필요 없다.

  commit=False 면 그리드를 건드리지 않고 무엇을 할지만 돌려준다.
"""


def ensure_rows(ws, last_row, commit, margin=20, log=print):
    """last_row (1-base) 까지 쓸 수 있게 한다.  늘린 (또는 늘릴) 행 수를 돌려준다."""
    have = int(getattr(ws, "row_count", 0) or 0)
    if have <= 0 or last_row <= have:
        return 0
    add = last_row - have + margin
    if not commit:
        log("그리드 %d행 < 필요 %d행 : --commit 이면 행 %d 개를 늘린다" % (have, last_row, add))
        return add
    ws.add_rows(add)
    log("그리드 늘림 : %d -> %d행 (필요 %d행 + 여유 %d)" % (have, have + add, last_row, margin))
    return add
