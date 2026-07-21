" Selection-bar feature: the index ftplugin turns on cursorline and restyles
" CursorLine as a solid cyan bar (vifm-style), so the message the cursor is on is
" marked with a highlighted band rather than a plain underline.
"
" Run: vim -u NONE -N -es -S tests/test_cursorline.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime! autoload/mail/*.vim

let v:errors = []

enew
execute 'source ' . fnameescape(s:repo . '/ftplugin/mail-index.vim')

" cursorline must be on, and buffer-local (so it doesn't leak to other buffers).
call assert_true(&l:cursorline, 'cursorline enabled in the index buffer')

" CursorLine must carry a background colour (the cyan bar), not an underline.
call assert_notequal('', synIDattr(hlID('CursorLine'), 'bg', 'cterm'),
      \ 'CursorLine has a background colour (the cyan selection bar)')
call assert_notequal('1', synIDattr(hlID('CursorLine'), 'underline', 'cterm'),
      \ 'CursorLine is a solid bar, not an underline')

bwipeout!

if empty(v:errors)
  qall!
else
  for s:e in v:errors | echom s:e | endfor
  cquit!
endif
