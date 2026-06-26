" Headless test suite for mail#move().
"
" Run:  vim -u NONE -N -es -S tests/test_move.vim
" Exit code 0 = all pass, 1 = failure. A summary + any assert failures are
" written to $TEST_MOVE_LOG (defaults to a tempname, path echoed at the end).
"
" Uses an isolated temp mail store per test — never touches a real ~/Mail.

" Locate the repo relative to this script so the test runs wherever cloned.
let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
" Force the autoload to load now, BEFORE we stub _prompt_mailbox below — else
" the first lazy mail#* call would re-source autoload and clobber the stub.
runtime autoload/mail.vim

" Build a minimal valid message directory (meta + raw.eml, both non-empty so
" a colliding rename() genuinely fails the way it does on a real store).
function! s:mkmsg(dir) abort
  call mkdir(a:dir, 'p')
  let id = fnamemodify(a:dir, ':t')
  call writefile([
        \ 'From: A <a@example.com>',
        \ 'Subject: test ' . id,
        \ 'Date: Tue, 23 Jun 2026 08:00:00 -0700',
        \ 'Message-ID: <' . id . '@example.com>',
        \ ], a:dir . '/meta')
  call writefile(['raw bytes'], a:dir . '/raw.eml')
endfunction

" Stub the mailbox prompt so move() runs without interactive input().
let g:test_move_dest = ''
function! mail#_prompt_mailbox(prompt, default) abort
  return g:test_move_dest
endfunction

" --- Test: move onto an existing id reports an error and keeps the message ---
function! Test_move_collision_reports_error() abort
  let root = tempname() . '/Mail'
  call s:mkmsg(root . '/inbox/20260623T153828Z_da68d5d7')
  call s:mkmsg(root . '/history/20260623T153828Z_da68d5d7')  " collision target
  let g:mail_root = root
  let g:test_move_dest = 'history'

  call mail#open('inbox')
  call cursor(1, 1)
  let out = execute('call mail#move()')

  call assert_match('could not move', out, 'collision must report an error')
  call assert_match('already exists in history', out, 'error names the cause')
  call assert_notmatch('Moved 1', out, 'must not falsely claim success')
  call assert_true(isdirectory(root . '/inbox/20260623T153828Z_da68d5d7'),
        \ 'message stays in inbox when move fails')
  call assert_equal(1, len(b:mail_entries), 'inbox still lists the message')

  bwipeout!
  call delete(root, 'rf')
endfunction

" --- Test: a clean move (empty/no collision) still succeeds ---
function! Test_move_clean_succeeds() abort
  let root = tempname() . '/Mail'
  call s:mkmsg(root . '/inbox/20260101T000000Z_aaaaaaaa')
  call mkdir(root . '/archive', 'p')                          " empty dest
  let g:mail_root = root
  let g:test_move_dest = 'archive'

  call mail#open('inbox')
  call cursor(1, 1)
  let out = execute('call mail#move()')

  call assert_match('Moved 1 message', out, 'clean move reports success')
  call assert_notmatch('could not move', out, 'no error on clean move')
  call assert_false(isdirectory(root . '/inbox/20260101T000000Z_aaaaaaaa'),
        \ 'message left the inbox')
  call assert_true(isdirectory(root . '/archive/20260101T000000Z_aaaaaaaa'),
        \ 'message arrived in archive')
  call assert_equal(0, len(b:mail_entries), 'inbox now empty')

  bwipeout!
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = ['Test_move_collision_reports_error', 'Test_move_clean_succeeds']
for s:t in s:tests
  try
    call call(s:t, [])
  catch
    call add(v:errors, s:t . ': threw ' . v:exception . ' @ ' . v:throwpoint)
  endtry
endfor

let s:logfile = $TEST_MOVE_LOG !=# '' ? $TEST_MOVE_LOG : tempname()
if empty(v:errors)
  call writefile(['PASS: ' . len(s:tests) . ' tests', 'log: ' . s:logfile], s:logfile)
  qall!
else
  call writefile(['FAIL: ' . len(v:errors) . ' assertion(s)'] + v:errors, s:logfile)
  cquit!
endif
