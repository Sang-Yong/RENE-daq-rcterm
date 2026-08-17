# 발표 자료 생성 스크립트

`.pptx` 는 저장소에 넣지 않는다. 바이너리라 diff 가 되지 않고 갱신할 때마다
저장소가 무거워진다. 대신 **만드는 스크립트를 두고 필요할 때 생성한다.**

```bash
pip install --user python-pptx        # 한 번만

python3 tools/slides/make_deck_en.py      ~/DAQ/presentations/RENE-run-control.pptx
python3 tools/slides/make_deck_ko.py      ~/DAQ/presentations/RENE-run-control-ko.pptx
python3 tools/slides/make_deck_ops_ko.py  ~/DAQ/presentations/RENE-daq-operations-ko.pptx
```

| 스크립트 | 내용 | 대상 |
|---|---|---|
| `make_deck_en.py` | 종합 23장 (영문) | 국제 협력자, 자료 공유 |
| `make_deck_ko.py` | 종합 23장 (한글) | 국내 협력자 |
| `make_deck_ops_ko.py` | 운영 중심 12장 (한글) | 실제로 DAQ 를 돌리는 사람 |

생성된 파일은 `~/DAQ/presentations/` 에 둔다(저장소 밖).

---

## 고칠 때

내용은 각 스크립트 아래쪽의 슬라이드 정의부에 순서대로 들어 있다.
`new(kicker, title)` 로 슬라이드를 열고 `bullets` / `codebox` / `table` /
`metric_row` 로 채운다. 위쪽 절반은 배치 헬퍼라 건드릴 일이 드물다.

**수치는 실측값만 쓴다.** 이 자료의 모든 숫자는 이 시스템에서 직접 측정한 것이고,
근거는 `CLAUDE.md` 와 `docs/POSTRUN.md` 에 있다. 값을 바꿀 때는 근거도 함께 갱신할 것.

## 한글 자료의 글꼴

python-pptx 는 기본적으로 latin 타이프페이스만 지정한다. 그대로 두면 PowerPoint 가
한글을 임의의 글꼴로 대체한다. `make_deck_ko.py` / `make_deck_ops_ko.py` 는
XML 에 East Asian(`a:ea`) 타이프페이스를 직접 넣어 **맑은 고딕**으로 고정한다.
`_set_font()` 가 그 일을 한다 — 한글이 들어가는 자료를 새로 만들 때 이 함수를 쓸 것.

## 배치 검증

이 환경에는 LibreOffice 가 없어 렌더링을 눈으로 확인할 수 없다. 대신 도형 좌표로
넘침과 겹침을 계산해 검사했다. 한글은 라틴 문자보다 넓으므로(약 1.8배) 줄 수
추정에 그 가중치가 들어가 있다. 문구를 크게 늘렸다면 생성 후 한 번 열어볼 것.
