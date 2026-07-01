" Underline-the-current-line feature: the index ftplugin turns on cursorline
" and restyles CursorLine as a plain (no-background) underline, so the message
" the cursor is on is marked with an underline.
"
" Run: vim -u NONE -N -es -S tests/test_underline.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime! autoload/mail/*.vim

let v:errors = []

enew
execute 'source ' . fnameescape(s:repo . '/ftplugin/mail-index.vim')

" cursorline must be on, and buffer-local (so it doesn't leak to other buffers).
call assert_true(&l:cursorline, 'cursorline enabled in the index buffer')

" CursorLine must carry the underline attribute and no background band.
call assert_equal('1', synIDattr(hlID('CursorLine'), 'underline', 'cterm'),
      \ 'CursorLine is underlined (cterm)')
call assert_equal('1', synIDattr(hlID('CursorLine'), 'underline', 'gui'),
      \ 'CursorLine is underlined (gui)')

bwipeout!

if empty(v:errors)
  qall!
else
  for s:e in v:errors | echom s:e | endfor
  cquit!
endif
