" A read-mark staged in the SAME :w as a move SURVIVES. Mark A read, cut it from
" inbox, paste into archive, one :w -> A must be read on disk. The pasted line
" carries its read indicator, and write() reconciles read state for pasted lines
" (not just baseline ones), committing the shared canon .read.
"
"   inbox: A "hello world!" (N)
"   s on A            -> A read (staged)
"   dd on A           -> cut A (register holds the read-version line)
"   :Mail archive, p  -> paste A (line shows read)
"   :w                -> commit: A linked in archive, unlinked from inbox, READ
"
" Run:  vim -u NONE -N -es -S tests/test_read_move.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on

function! Test_read_survives_move() abort
  let root = tempname() . '/Mail'
  let a = testmail#ingest_subject(root, 'inbox', 'hello world!')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  " mark A read, then cut it (register holds the read-version line)
  Mail inbox
  call testmail#goto(a) | normal s
  call testmail#goto(a) | normal! dd

  " paste into archive and commit both buffers
  Mail archive
  normal! p
  silent write

  call assert_equal('link', testmail#ftype(root . '/archive/' . a), 'A linked into archive')
  call assert_equal('', testmail#ftype(root . '/inbox/' . a), 'A gone from inbox')
  call assert_true(filereadable(root . '/.store/' . a . '/.read'),
        \ 'A is READ on disk — the staged read-mark survived the move')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = ['Test_read_survives_move']
for s:t in s:tests
  try
    call call(s:t, [])
  catch
    call add(v:errors, s:t . ': threw ' . v:exception . ' @ ' . v:throwpoint)
  endtry
endfor

if empty(v:errors)
  qall!
else
  for s:e in v:errors | echom s:e | endfor
  cquit!
endif
