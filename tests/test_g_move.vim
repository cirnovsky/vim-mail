" Bulk-move by pattern: collect every /world/ match into an APPEND register and
" paste them into another mailbox. Driven like a human (real keymaps + :g + p +
" :w). See README "Tricks".
"
"   inbox: A "hello world" (N)   B "hello WORLD" (N)   C "HELLO world" (N)
"   s on A                       -> A read (staged)
"   :g/world/d A                 -> delete each /world/ match (A, C; B's "WORLD"
"                                   doesn't match, noignorecase), APPENDING to
"                                   register a. (Plain :g/world/d would leave
"                                   only the last match in the unnamed register.)
"   :Mail archive, "ap           -> paste both collected lines
"   check: A and C present; A shows read, C unread
"   :w                           -> commit; the move lands on disk
"
" A read-mark staged in the SAME :w as a move survives: the pasted line carries
" its read indicator and write() reconciles read state for pasted lines, so A
" lands READ on disk. (test_read_move.vim is the minimal case.)
"
" Run:  vim -u NONE -N -es -S tests/test_g_move.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on
set noignorecase

" ids in the current buffer, top to bottom
function! s:ids() abort
  let r = []
  for ln in range(1, line('$'))
    let l = getline(ln)
    let t = stridx(l, "\t")
    if t >= 0 | call add(r, l[:t - 1]) | endif
  endfor
  return r
endfunction

" read-flag of <id> in the current buffer: 1 read, 0 unread, -1 absent
function! s:read(id) abort
  for ln in range(1, line('$'))
    let l = getline(ln)
    let t = stridx(l, "\t")
    if t >= 0 && l[:t - 1] ==# a:id | return l[t + 1] ==# 'N' ? 0 : 1 | endif
  endfor
  return -1
endfunction

function! Test_g_move() abort
  let root = tempname() . '/Mail'
  let a = testmail#ingest_subject(root, 'inbox', 'hello world')
  let b = testmail#ingest_subject(root, 'inbox', 'hello WORLD')
  let c = testmail#ingest_subject(root, 'inbox', 'HELLO world')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  " inbox: mark A read, then collect the /world/ lines (A and C) into register a
  " via the capital (append) register — a plain :g/world/d would carry only the
  " last match in the unnamed register.
  Mail inbox
  call testmail#goto(a) | normal s
  let @a = ''
  silent g/world/d A
  call assert_equal([b], s:ids(), 'inbox: only B remains (WORLD did not match /world/)')

  " paste both collected lines into archive
  Mail archive
  normal! "ap
  call assert_notequal(-1, index(s:ids(), a), 'archive: A present after paste')
  call assert_notequal(-1, index(s:ids(), c), 'archive: C present after paste')
  call assert_equal(1, s:read(a), 'archive buffer: A shows read (carried by the paste)')
  call assert_equal(0, s:read(c), 'archive buffer: C shows unread')

  " commit; the move lands on disk
  silent write

  call assert_equal('link', testmail#ftype(root . '/archive/' . a), 'A linked into archive')
  call assert_equal('link', testmail#ftype(root . '/archive/' . c), 'C linked into archive')
  call assert_equal('', testmail#ftype(root . '/inbox/' . a), 'A gone from inbox')
  call assert_equal('', testmail#ftype(root . '/inbox/' . c), 'C gone from inbox')
  call assert_equal('link', testmail#ftype(root . '/inbox/' . b), 'B still in inbox')

  " A's read-mark, staged in the same :w as the move, survives — the pasted line
  " carried its read indicator. C was never marked, so it stays unread.
  call assert_true(filereadable(root . '/.store/' . a . '/.read'),
        \ 'A read on disk (staged read-mark survived the move)')
  call assert_false(filereadable(root . '/.store/' . c . '/.read'), 'C unread on disk')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = ['Test_g_move']
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
