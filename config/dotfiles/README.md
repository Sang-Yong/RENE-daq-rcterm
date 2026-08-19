# 터미널 / 편집기 설정

DAQ 운영 PC 의 터미널·편집기 환경. 홈 디렉터리에 흩어져 있어 버전 관리가
안 되던 것들을 여기 모았다. PC 를 다시 세팅하거나 다른 운영 PC 를 같은 환경으로
맞출 때 `install.sh` 하나로 끝난다.

```bash
config/dotfiles/install.sh --all      # 설정 + 폰트 + 터미널 프로파일
config/dotfiles/install.sh            # 설정 파일만
config/dotfiles/install.sh --dry-run  # 무엇을 할지만 확인
```

기존 파일은 덮어쓰기 전에 `~/dotfiles-backup-<날짜>/` 로 옮긴다.
`.bashrc` 만은 통째로 덮지 않고, 블록이 없을 때만 끝에 덧붙인다.

---

## 파일

| 파일 | 설치 위치 | 내용 |
|---|---|---|
| `tmux.conf` | `~/.tmux.conf` | 256색, pane 테두리·이름표, 단축키 |
| `dircolors` | `~/.dircolors` | `ls` 색상표 |
| `vimrc` | `~/.vimrc` | vim 설정 |
| `vim/colors/rene.vim` | `~/.vim/colors/rene.vim` | vim 색 테마 |
| `fontconfig/fonts.conf` | `~/.config/fontconfig/fonts.conf` | 한글 대체 폰트 규칙 |
| `bashrc.snippet` | `~/.bashrc` 끝에 추가 | `vi`→`vim` 별칭, `ls` 별칭, 프롬프트 |
| `gnome-terminal-profile.sh` | (실행) | 폰트·색·창 크기 |

폰트 자체(Hack, Cascadia Code)는 저장소에 넣지 않는다. 13 MB 짜리 바이너리이고
공식 배포처가 있다. `install.sh --fonts` 가 내려받아
`~/.local/share/fonts/` 에 설치한다(root 불필요).

---

## 왜 이렇게 되어 있는가

각 설정에는 이유가 있다. 되돌리기 전에 읽을 것.

**`tmux.conf` 의 `default-terminal "tmux-256color"`** — 이게 없으면 tmux 가
pane 안 `TERM` 을 `screen` 으로 주고 색이 8색으로 뭉개진다. 그러면 디렉터리
파랑이 터미널 팔레트의 4번(`#12488b`, 짙은 남색)으로 찍혀 어두운 배경에서
읽을 수 없다. **원래 이 문제 때문에 시작한 설정이다.**

**`escape-time 10`** — 기본 500 ms 는 vim 에서 Esc 가 눈에 띄게 굼뜨다.

**`dircolors` 가 256색 번호(`38;5;N`)를 직접 쓰는 이유** — 터미널 16색 팔레트에
의존하지 않기 위해서다. 색만이 아니라 **글자 속성으로도 구분**한다:
디렉터리는 굵게, 심볼릭 링크는 밑줄, 빌드 산출물·로그는 흐리게.
`OTHER_WRITABLE` 의 기본값(초록 바탕에 파란 글씨)은 거의 읽을 수 없어 바꿨다.
이 사이트에서는 `/Data_ssd` 가 여기 해당한다.

**`bashrc.snippet` 의 `alias vi=vim`** — `/usr/bin/vi` 는 vim-minimal 이라
`-syntax` 다. 구문 강조 기능이 **아예 없다**. `vim` 은 vim-enhanced 라 있다.
`vi` 를 치는 습관을 그대로 두고 제대로 된 편집기가 뜨게 한다.
(`sudo vi` 는 root 설정을 읽으므로 여전히 최소판이다.)

**`vimrc` 의 `fileencodings=ucs-bom,utf-8,cp949,euc-kr,latin1`** — 이 저장소는
주석과 문서가 한글이고, 과거에 인코딩이 깨져 글자가 망가진 적이 있다.
상태줄에 파일 인코딩을 항상 띄우는 것도 같은 이유다.

**`vimrc` 의 `set mouse=`** — 일부러 끈다. 켜져 있으면 마우스로 드래그해도
vim 이 가로채서 터미널 복사가 안 된다. RHEL 기본 `defaults.vim` 이 켜는 경우가 있다.

**`vimrc` 의 `directory`/`backupdir`/`undodir`** — 기본값이면 편집하는 자리에
`.swp` 가 생긴다. `/scratch` 나 저장소에 쓰레기를 남기지 않도록 홈으로 모은다.

**`fontconfig/fonts.conf`** — Hack 과 Cascadia Code 에는 한글 글리프가 없다.
그대로 두면 시스템 기본 대체 폰트인 `Noto Sans CJK JP`(**가변폭, 일본어판**)가
잡혀서 한글이 섞인 줄의 열이 어긋나고 자형도 일본어판이 된다.
고정폭 한국어판(`Noto Sans Mono CJK KR`)을 명시적으로 앞세운다.

**`vim/colors/rene.vim` 이 `Normal` 의 배경을 지정하지 않는 이유** — 터미널
배경을 그대로 쓰기 위해서다. 그래야 터미널 테마를 바꿔도 색이 어긋나지 않고
검은 띠도 생기지 않는다. 색 번호는 `dircolors` 와 맞춰 두었다.
셸에서 디렉터리가 117번 하늘색이면 vim 의 `Directory` 도 117번이다.

---

## 알아둘 점

- **pane 마다 글꼴 크기를 다르게 할 수 없다.** 폰트는 터미널 에뮬레이터가 창
  단위로 갖는 속성이고 tmux 에는 폰트 옵션 자체가 없다. 한 화면만 크게 보려면
  큰 글꼴 프로파일로 터미널 창을 하나 더 띄워 `scripts/rcmon.sh` 를 돌린다.
  heartbeat 파일을 읽기만 하므로 몇 개를 띄워도 무방하다.
- `gnome-terminal-profile.sh` 의 프로파일 UUID 는 PC 마다 다르다.
  인자를 주지 않으면 기본 프로파일을 찾아 쓴다.
- `tmux.conf` 의 `bind =` 는 `scripts/daq-layout.sh` 를 부른다.
  저장소 경로가 `/home/frontend/DAQ/RENE-daq-rcterm` 이 아니면 그 줄을 고칠 것.
- **`pane-border-format` 이 보여 주는 pane 제목은 장식이 아니다.**
  `daq-layout.sh` 가 제목 안의 열쇠말로 pane 을 찾는다 — `monitor` ·
  `supervisor` · `postrun` · `work space` · `dataflow`. 제목을 바꾸는 것은
  자유지만 해당 낱말은 남겨 둘 것. 빼면 레이아웃 복원이 pane 을 못 찾는다.

---

## `bin/claude-transcript` — 화면 대신 원본을 파일로 받는다

Claude Code 의 TUI 는 **마우스 추적을 켠다.** 그러면 터미널이 드래그를
'글자 선택'이 아니라 '앱에 보낼 마우스 이벤트'로 넘기기 때문에, 화면을 끌어
복사하면 제대로 잡히지 않는다. tmux 와는 무관하다 — tmux 없이 SSH 로 붙어도
똑같다.

**당장 필요하면 `Shift` 를 누른 채 드래그**한다. Shift 는 마우스 추적을 우회해
터미널 자신의 선택을 강제한다(macOS Terminal.app 은 `Fn`). 다만 긴 표나 코드
블록은 줄바꿈과 테두리가 함께 딸려 와 여전히 지저분하다.

대화는 `~/.claude/projects/<경로>/…jsonl` 에 그대로 쌓이므로, 화면과 씨름하는
대신 원본을 뽑는 편이 확실하다.

```bash
claude-transcript --list                 이 디렉터리의 대화 목록
claude-transcript --last 1               마지막 답변 하나만 (화면으로)
claude-transcript --last 3 -o 답변.txt   파일로
claude-transcript --all -o 전체.txt      내 질문까지 함께
```

작업 디렉터리에 맞는 프로젝트를 스스로 찾는다. 생각 과정과 도구 호출은 빼고
**화면에 낸 글만** 뽑으므로 그대로 문서에 붙여넣을 수 있는 마크다운이 나온다.

> **⚠️ 대화에 오간 것은 전부 들어간다.** 비밀번호나 키를 주고받았다면 그것도
> 딸려 나온다 — 어시스턴트가 인용만 해도 그렇다. 실제로 2026-08-20 에 뽑아
> 보니 앱 비밀번호가 섞여 있었다. 남에게 넘기기 전에 반드시 훑어볼 것.
> 아는 비밀은 가릴 수 있다.
>
> ```bash
> claude-transcript --redact '앱비밀번호' --redact '계정비밀번호' -o 답변.txt
> ```

`~/bin/` 에 설치된다. Rocky/RHEL 기본 `.bashrc` 가 `~/bin` 을 PATH 에 넣어
주지만, 다른 배포판이면 `install.sh` 가 없다고 알려 준다.
