" Regression guard for keymap wiring.
"
" The autoload modularization once emptied the ftplugin files (a write-truncation
" bug in the generator), killing EVERY mapping — yet the unit tests stayed green
" because they call mail#...# functions directly, never through keymaps. This
" suite asserts the wiring itself: the ftplugin/plugin files exist, every
" mail#<topic># they reference is a real loaded function, and the mappings
" (including <leader>f) actually bind when the ftplugin is sourced.
"
" Run: vim -u NONE -N -es -S tests/test_keymaps.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime! autoload/mail/*.vim

let v:errors = []
let s:files = ['ftplugin/mail-index.vim', 'ftplugin/mail-compose.vim', 'plugin/mail.vim']

" 1. The files must be non-empty (directly guards the truncation regression).
for s:f in s:files
  call assert_true(getfsize(s:repo . '/' . s:f) > 0, s:f . ' is non-empty')
endfor

" 2. Every mail#<topic>#<fn> referenced in those files must be a defined function.
let s:seen = {}
for s:f in s:files
  for s:line in readfile(s:repo . '/' . s:f)
    let s:start = 0
    while 1
      let s:m = matchstrpos(s:line, 'mail#\a\+#\w\+', s:start)
      if s:m[1] < 0 | break | endif
      let s:seen[s:m[0]] = 1
      let s:start = s:m[2]
    endwhile
  endfor
endfor
for s:fn in keys(s:seen)
  call assert_true(exists('*' . s:fn), s:fn . ' is defined')
endfor
call assert_true(len(s:seen) >= 18, 'expected many refs, found ' . len(s:seen))

" 3. Index ftplugin actually binds its mappings (default leader '\' under -u NONE).
enew
execute 'source ' . fnameescape(s:repo . '/ftplugin/mail-index.vim')
for s:key in ['<CR>', 'o', 'v', 'r', 'f', 'F', '-', 'R', 's', 'S',
      \ '\f', '\c', '\s']
  call assert_true(maparg(s:key, 'n') !=# '', 'index map ' . s:key . ' bound')
endfor
bwipeout!

" 4. Compose ftplugin binds its mappings + the :Attach command.
enew
execute 'source ' . fnameescape(s:repo . '/ftplugin/mail-compose.vim')
for s:key in ['\a', '\p', '\A']
  call assert_true(maparg(s:key, 'n') !=# '', 'compose map ' . s:key . ' bound')
endfor
call assert_equal(2, exists(':Attach'), ':Attach command defined')
bwipeout!

if empty(v:errors)
  qall!
else
  for s:e in v:errors | echom s:e | endfor
  cquit!
endif
