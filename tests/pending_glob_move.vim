" PENDING — not auto-discovered by run.sh (name is not test_*).
" Target for the move refactor: make :M an in-place staged annotation so
" :g/love/M archive moves every match. Red until move stops full-refreshing.
"
" Scenario, all keyboard-driven (headless): mark two messages read, then
" :g/love/M archive to move every 'love' message, and verify the split + read
" states across both mailboxes.
"
"   inbox: A "Hello World!", B "I love Java!", C "I love Python!" (all unread)
"   s on A, s on B                      -> A, B staged read
"   :g/love/M archive                   -> move B and C to archive
"   :Mail archive  => B (read) + C (unread)
"   :Mail inbox    => A (read), nothing else
"
" Run:  vim -u NONE -N -es -S tests/test_glob_move.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on

" :g/love/M runs :M (move) while the s-marks are still staged, so the move guard
" fires once — answer Save so the read-marks commit, then the moves proceed.
let g:test_confirm = 'save'
function! mail#actions#_confirm(msg) abort
  return g:test_confirm
endfunction

function! s:read(root, id) abort
  return filereadable(a:root . '/.store/' . a:id . '/.read')
endfunction

function! Test_glob_move_with_read_marks() abort
  let root = tempname() . '/Mail'
  let a = testmail#ingest_subject(root, 'inbox', 'Hello World!')
  let b = testmail#ingest_subject(root, 'inbox', 'I love Java!')
  let c = testmail#ingest_subject(root, 'inbox', 'I love Python!')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  " --- in inbox: press s on A and B (mark read, staged) ---
  call mail#index#open('inbox')
  call testmail#goto(a) | normal s
  call testmail#goto(b) | normal s

  " --- :g/love/M archive : move every 'love' message to archive ---
  silent execute 'g/love/M archive'

  " --- archive: exactly B and C; B read, C unread ---
  call mail#index#open('archive')
  call assert_true(testmail#has_entry(b), 'B (Java) moved to archive')
  call assert_true(testmail#has_entry(c), 'C (Python) moved to archive')
  call assert_equal(2, len(b:mail_entries), 'archive has exactly two messages')
  call assert_true(s:read(root, b),  'B is read in archive')
  call assert_false(s:read(root, c), 'C is unread in archive')

  " --- inbox: only A remains, read ---
  call mail#index#open('inbox')
  call assert_true(testmail#has_entry(a), 'A (Hello) still in inbox')
  call assert_equal(1, len(b:mail_entries), 'inbox has exactly one message')
  call assert_true(s:read(root, a), 'A is read')
  call assert_equal('', testmail#ftype(root . '/inbox/' . b), 'B left inbox')
  call assert_equal('', testmail#ftype(root . '/inbox/' . c), 'C left inbox')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = ['Test_glob_move_with_read_marks']
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
