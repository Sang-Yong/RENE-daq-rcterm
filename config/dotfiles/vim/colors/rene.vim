" ---------------------------------------------------------------------
"  rene.vim  -  어두운 배경용 256색 vim 테마
"
"  ~/.dircolors 와 같은 색을 쓴다. 셸에서 디렉터리가 파란색 117번이면
"  vim 의 Directory 도 117번이다. 터미널 전체가 한 벌로 보이게 한 것.
"
"  Normal 의 배경을 지정하지 않는다(NONE). 터미널 배경을 그대로 쓰므로
"  tmux/터미널 테마를 바꿔도 색이 어긋나지 않고, 검은 띠도 생기지 않는다.
"
"  cterm(256색)과 gui(24bit) 값을 함께 정의한다.
"  termguicolors 를 켜지 않아도 동작하고, 켜도 동작한다.
" ---------------------------------------------------------------------

hi clear
if exists("syntax_on")
  syntax reset
endif
set background=dark
let g:colors_name = "rene"

" ---- 기본 ----
hi Normal       ctermfg=253 ctermbg=NONE guifg=#dadada guibg=NONE
hi NonText      ctermfg=243 ctermbg=NONE guifg=#767676 guibg=NONE
hi SpecialKey   ctermfg=243 ctermbg=NONE guifg=#767676 guibg=NONE
hi Conceal      ctermfg=247 ctermbg=NONE guifg=#9e9e9e guibg=NONE

" ---- 구문 ----
"  주석은 흐리게, 문자열은 초록, 키워드는 주황.
"  세 가지가 서로 확실히 다른 밝기를 갖도록 골랐다.
hi Comment      ctermfg=247 guifg=#9e9e9e
hi Constant     ctermfg=216 guifg=#ffaf87
hi String       ctermfg=120 guifg=#87ff87
hi Character    ctermfg=120 guifg=#87ff87
hi Number       ctermfg=216 guifg=#ffaf87
hi Boolean      ctermfg=216 guifg=#ffaf87
hi Float        ctermfg=216 guifg=#ffaf87
hi Identifier   ctermfg=153 guifg=#afd7ff cterm=NONE gui=NONE
hi Function     ctermfg=123  guifg=#87ffff
hi Statement    ctermfg=222 guifg=#ffd787 cterm=bold gui=bold
hi Conditional  ctermfg=222 guifg=#ffd787 cterm=bold gui=bold
hi Repeat       ctermfg=222 guifg=#ffd787 cterm=bold gui=bold
hi Label        ctermfg=222 guifg=#ffd787
hi Operator     ctermfg=253 guifg=#dadada
hi Keyword      ctermfg=222 guifg=#ffd787 cterm=bold gui=bold
hi Exception    ctermfg=210 guifg=#ff8787 cterm=bold gui=bold
hi PreProc      ctermfg=183 guifg=#d7afff
hi Include      ctermfg=183 guifg=#d7afff
hi Define       ctermfg=183 guifg=#d7afff
hi Macro        ctermfg=183 guifg=#d7afff
hi PreCondit    ctermfg=183 guifg=#d7afff
hi Type         ctermfg=158 guifg=#afffd7 cterm=NONE gui=NONE
hi StorageClass ctermfg=158 guifg=#afffd7
hi Structure    ctermfg=158 guifg=#afffd7
hi Typedef      ctermfg=158 guifg=#afffd7
hi Special      ctermfg=223 guifg=#ffd7af
hi SpecialComment ctermfg=223 guifg=#ffd7af
hi Delimiter    ctermfg=253 guifg=#dadada
hi Underlined   ctermfg=117  guifg=#87d7ff cterm=underline gui=underline
hi Ignore       ctermfg=243 guifg=#767676
hi Error        ctermfg=231 ctermbg=160 guifg=#ffffff guibg=#d70000
hi Todo         ctermfg=16  ctermbg=226 guifg=#000000 guibg=#ffff00 cterm=bold gui=bold

" ---- 커서 / 줄번호 ----
hi Cursor       ctermfg=16  ctermbg=117   guifg=#000000 guibg=#87d7ff
hi CursorLine   ctermbg=236 cterm=NONE   guibg=#303030 gui=NONE
hi CursorColumn ctermbg=236 guibg=#303030
hi LineNr       ctermfg=244 ctermbg=NONE guifg=#808080 guibg=NONE
hi CursorLineNr ctermfg=220 ctermbg=NONE guifg=#ffd700 guibg=NONE cterm=bold gui=bold
hi ColorColumn  ctermbg=52  guibg=#5f0000
hi SignColumn   ctermfg=247 ctermbg=NONE guifg=#9e9e9e guibg=NONE

" ---- 검색 / 선택 ----
hi Search       ctermfg=16  ctermbg=222 guifg=#000000 guibg=#ffd787
hi IncSearch    ctermfg=16  ctermbg=210 guifg=#000000 guibg=#ff8787
hi Visual       ctermbg=238 cterm=NONE  guibg=#444444 gui=NONE
hi MatchParen   ctermfg=226 ctermbg=238 guifg=#ffff00 guibg=#444444 cterm=bold gui=bold

" ---- 상태줄 / 창 분할 ----
"  활성 창은 파랑 바탕, 비활성은 어두운 회색. 어느 창에 있는지 즉시 보인다.
hi StatusLine   ctermfg=234 ctermbg=153 guifg=#1c1c1c guibg=#afd7ff cterm=bold gui=bold
hi StatusLineNC ctermfg=247 ctermbg=236 guifg=#9e9e9e guibg=#303030 cterm=NONE gui=NONE
hi VertSplit    ctermfg=238 ctermbg=NONE guifg=#444444 guibg=NONE cterm=NONE gui=NONE
hi TabLine      ctermfg=247 ctermbg=236 guifg=#9e9e9e guibg=#303030 cterm=NONE gui=NONE
hi TabLineFill  ctermbg=236 guibg=#303030
hi TabLineSel   ctermfg=16  ctermbg=117  guifg=#000000 guibg=#87d7ff cterm=bold gui=bold

" ---- 팝업 메뉴 ----
hi Pmenu        ctermfg=253 ctermbg=238 guifg=#dadada guibg=#444444
hi PmenuSel     ctermfg=16  ctermbg=153 guifg=#000000 guibg=#afd7ff cterm=bold gui=bold
hi PmenuSbar    ctermbg=243 guibg=#767676
hi PmenuThumb   ctermbg=117  guibg=#87d7ff
hi WildMenu     ctermfg=16  ctermbg=222 guifg=#000000 guibg=#ffd787 cterm=bold gui=bold

" ---- 접기 ----
hi Folded       ctermfg=247 ctermbg=237 guifg=#9e9e9e guibg=#3a3a3a
hi FoldColumn   ctermfg=247 ctermbg=NONE guifg=#9e9e9e guibg=NONE

" ---- 메시지 ----
hi Directory    ctermfg=117  guifg=#87d7ff cterm=bold gui=bold
hi Title        ctermfg=222 guifg=#ffd787 cterm=bold gui=bold
hi WarningMsg   ctermfg=220 guifg=#ffd700
hi ErrorMsg     ctermfg=210 guifg=#ff8787 cterm=bold gui=bold
hi ModeMsg      ctermfg=120 guifg=#87ff87 cterm=bold gui=bold
hi MoreMsg      ctermfg=120 guifg=#87ff87
hi Question     ctermfg=120 guifg=#87ff87

" ---- diff ----
hi DiffAdd      ctermfg=NONE ctermbg=22 guibg=#005f00
hi DiffDelete   ctermfg=160  ctermbg=52 guifg=#d70000 guibg=#5f0000
hi DiffChange   ctermfg=NONE ctermbg=17 guibg=#00005f
hi DiffText     ctermfg=NONE ctermbg=24 guibg=#005f87 cterm=bold gui=bold

" ---- 맞춤법 ----
hi SpellBad     ctermfg=210 cterm=underline guifg=#ff8787 gui=undercurl guisp=#ff8787
hi SpellCap     ctermfg=220 cterm=underline guifg=#ffd700 gui=undercurl guisp=#ffd700
hi SpellRare    ctermfg=183 cterm=underline guifg=#d7afff gui=undercurl guisp=#d7afff
hi SpellLocal   ctermfg=158 cterm=underline guifg=#afffd7 gui=undercurl guisp=#afffd7

" ---- 눈에 띄어야 하는 것 : 줄 끝 공백 ----
hi ExtraWhitespace ctermbg=52 guibg=#5f0000
