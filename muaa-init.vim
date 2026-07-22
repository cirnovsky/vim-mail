" muaa-init.vim — boots Vim as a standalone modal mail client (vim-mail only).
" Loaded via `vim -u muaa-init.vim -c Mail` (the `muaa` launcher does this), so
" your ~/.vimrc and other plugins are NOT sourced — this is a clean mail app that
" happens to be Vim, which is exactly why gx/gf/marks/registers/:cmds all work.

set nocompatible

" Clean runtimepath: just Vim's own runtime (keeps netrw, so `gx` works) plus
" this repo. Drops ~/.vim and your other plugins for a dedicated environment.
let &runtimepath = $VIMRUNTIME
let s:repo = expand('<sfile>:p:h')
execute 'set runtimepath^=' . fnameescape(s:repo)

filetype plugin indent on
syntax on

" App feel: no editor-chrome noise, no swap clutter, window titled 'muaa'.
set hidden noswapfile nobackup nowritebackup
set laststatus=2 noshowmode belloff=all mouse=
set shortmess+=I
set title titlestring=muaa

" vifm-style frame: a top path bar (tabline — always shown) to go with the
" bottom status bar the mail buffers already set. Global here on purpose; muaa
" is a dedicated mail app, so owning the tabline is fine.
set showtabline=2
set tabline=%!mail#util#tabline()

" --- Mail store + identity ------------------------------------------------
" Store: defaults to the plugin's ~/Mail; override with $MUAA_MAIL_ROOT or in
" ~/.config/muaa/config.vim. Identity: read from ~/.msmtprc (single source of
" truth) when present, so the From isn't duplicated.
if $MUAA_MAIL_ROOT !=# ''
  let g:mail_root = $MUAA_MAIL_ROOT
endif
if filereadable(expand('~/.msmtprc'))
  let s:from = trim(system("awk '$1==\"from\" {print $2; exit}' " . expand('~/.msmtprc')))
  if s:from !=# '' | let g:mail_from = s:from | endif
endif

" Personal overrides: paths, a From with a display name, extra keymaps, colours.
if filereadable(expand('~/.config/muaa/config.vim'))
  source ~/.config/muaa/config.vim
endif

" vifm-style chrome: the top path bar (tabline), bottom status bar, and current-
" line selection are all vifm's grey-white (terminal white = a light grey) with
" dark text. Applied AFTER config.vim so it wins over a colorscheme set there, and
" re-applied on :colorscheme so a later theme change doesn't wipe it. Override the
" shade by re-issuing :highlight in config.vim's own ColorScheme autocmd.
function! s:MuaaSkin() abort
  " One grey for every bar — tabline, active AND inactive statuslines, and the
  " selection — so nothing reads as a different shade when a split is open.
  let l:g = 'cterm=NONE ctermbg=Grey ctermfg=Black gui=NONE guibg=#c6c6c6 guifg=#1c1c1c'
  execute 'highlight StatusLine '   . l:g
  execute 'highlight StatusLineNC ' . l:g
  execute 'highlight TabLine '      . l:g
  execute 'highlight TabLineSel '   . l:g
  execute 'highlight TabLineFill '  . l:g
  execute 'highlight CursorLine '   . l:g
  " A Cursor that matches the bar: dark text on the same grey, so the block is
  " indistinguishable from a normal cell of the selection bar — the cursor
  " vanishes without blanking the character under it.
  execute 'highlight MailBlendCursor ' . l:g
endfunction
augroup muaa_skin
  autocmd!
  autocmd ColorScheme * call s:MuaaSkin()
augroup END
call s:MuaaSkin()

" Hide the cursor only on the pages that have a grey selection bar (index +
" trash) — the bar already marks the current line, so the block is just noise.
" The launcher has no bar (nocursorline), so it KEEPS its cursor as the sole
" position indicator. Primary method is t_ve= : emptying the 'cursor visible'
" termcap makes Vim stop re-showing the cursor after a redraw's t_vi, a termcap-
" level hide that works even when the terminal ignores cursor colour (the
" guicursor colour-blend is kept only as a fallback). Scoped by filetype — the
" launcher, compose (you type) and view (you navigate the body) keep a normal
" cursor; restored on any other buffer AND on exit, so the shell never inherits a
" hidden cursor.
let s:cursor_default = &guicursor
let s:t_ve_saved     = &t_ve
function! s:MuaaCursor() abort
  if index(['mail-index', 'mail-trash'], &filetype) >= 0
    " capture the real 'show cursor' sequence before blanking it (it may not be
    " populated until the terminal is fully set up, after this file is sourced)
    if &t_ve !=# '' | let s:t_ve_saved = &t_ve | endif
    set t_ve=
    set guicursor=a:block-MailBlendCursor
  else
    let &t_ve      = s:t_ve_saved
    let &guicursor = s:cursor_default
  endif
endfunction
augroup muaa_cursor
  autocmd!
  autocmd FileType,BufEnter,WinEnter * call s:MuaaCursor()
  autocmd VimLeave * let &t_ve = s:t_ve_saved
augroup END

" The plugin (plugin/mail.vim) auto-loads at startup from the runtimepath above;
" the launcher's `-c Mail` then opens the mailbox list.
