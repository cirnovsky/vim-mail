" Headless suite for legacy (pre content-store) real-dir moves + the staged-edit
" guard, driven via the real M keymap.
"
" Fixtures are FAITHFUL legacy real dirs (testmail#legacy = real ingest, then
" de-symlink), so these exercise the physical rename/rf fallback for old-format
" mail. Move is driven through the M keymap (filetype plugin on).
"
" Run:  vim -u NONE -N -es -S tests/test_move.vim
" Uses an isolated temp mail store per test — never touches a real ~/Mail.

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on   " wire the index buffer's M keymap

" Stub the mailbox prompt so the M keymap runs without interactive input().
let g:test_move_dest = ''
function! mail#mailbox#_prompt_mailbox(prompt, default) abort
  return g:test_move_dest
endfunction

" Stub the 3-way confirm ('save'/'discard'/'cancel') so the staged-edit guard is
" testable in batch mode.
let g:test_confirm = 'discard'
function! mail#actions#_confirm(msg) abort
  return g:test_confirm
endfunction

" --- Test: move onto an existing id reports an error and keeps the message ---
function! Test_move_collision_reports_error() abort
  let root = tempname() . '/Mail'
  let id = testmail#legacy(root, 'inbox', 'plain')
  call testmail#legacy(root, 'history', 'plain')   " same id already in history -> collision
  let g:mail_root = root
  let g:test_move_dest = 'history'

  call mail#index#open('inbox')
  call cursor(1, 1)
  let out = execute('normal M')

  call assert_match('could not move', out, 'collision must report an error')
  call assert_match('already exists in history', out, 'error names the cause')
  call assert_notmatch('Moved 1', out, 'must not falsely claim success')
  call assert_true(isdirectory(root . '/inbox/' . id), 'message stays in inbox when move fails')
  call assert_equal(1, len(b:mail_entries), 'inbox still lists the message')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- Test: a clean move (empty/no collision) still succeeds ---
function! Test_move_clean_succeeds() abort
  let root = tempname() . '/Mail'
  let id = testmail#legacy(root, 'inbox', 'plain')
  call mkdir(root . '/archive', 'p')               " empty dest
  let g:mail_root = root
  let g:test_move_dest = 'archive'

  call mail#index#open('inbox')
  call cursor(1, 1)
  let out = execute('normal M')

  call assert_match('Moved 1 message', out, 'clean move reports success')
  call assert_notmatch('could not move', out, 'no error on clean move')
  call assert_false(isdirectory(root . '/inbox/' . id), 'message left the inbox')
  call assert_true(isdirectory(root . '/archive/' . id), 'message arrived in archive')
  call assert_equal(0, len(b:mail_entries), 'inbox now empty')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- Test: with staged (unwritten) edits, cancelling the guard aborts move ---
function! Test_move_guard_cancel() abort
  let root = tempname() . '/Mail'
  let id_a = testmail#legacy(root, 'inbox', 'plain')
  let id_b = testmail#legacy(root, 'inbox', 'html')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root
  let g:test_move_dest = 'archive'

  call mail#index#open('inbox')
  call assert_false(&modified, 'fresh buffer is unmodified after open')
  call testmail#goto(id_b) | normal! dd            " stage a delete of b (not :w)
  call assert_true(&modified, 'dd staged a change')

  let g:test_confirm = 'cancel'                     " user picks Cancel at the guard
  call testmail#goto(id_a)
  normal M

  call assert_equal([], glob(root . '/archive/*', 0, 1), 'nothing moved (cancelled)')
  call assert_true(isdirectory(root . '/inbox/' . id_a), 'A kept')
  call assert_true(isdirectory(root . '/inbox/' . id_b), 'B kept')
  call assert_true(&modified, 'staged delete still pending after cancel')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- Test: 'Discard' proceeds AND throws the staged edit away (vs 'Save') ---
function! Test_move_guard_discard() abort
  let root = tempname() . '/Mail'
  let id_a = testmail#legacy(root, 'inbox', 'plain')
  let id_b = testmail#legacy(root, 'inbox', 'html')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root
  let g:test_move_dest = 'archive'

  call mail#index#open('inbox')
  call testmail#goto(id_b) | normal! dd             " stage a REAL delete of B
  call assert_true(&modified, 'dd staged a change')

  let g:test_confirm = 'discard'                    " user picks Discard
  call testmail#goto(id_a)
  normal M

  " A moved; B's staged delete was DISCARDED (write() never ran), so it stays in
  " inbox and never reaches trash — the opposite of guard_save.
  call assert_true(isdirectory(root . '/archive/' . id_a), 'move proceeds after Discard')
  call assert_true(isdirectory(root . '/inbox/' . id_b),
        \ 'staged delete discarded — message still in inbox')
  call assert_false(isdirectory(root . '/trash/' . id_b),
        \ 'discarded delete was NOT committed to trash')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- Test: 'Save' commits staged edits, then the move proceeds ---
function! Test_move_guard_save() abort
  let root = tempname() . '/Mail'
  let id_a = testmail#legacy(root, 'inbox', 'plain')
  let id_b = testmail#legacy(root, 'inbox', 'html')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root
  let g:test_move_dest = 'archive'

  call mail#index#open('inbox')
  call testmail#goto(id_b) | normal! dd             " stage delete of B
  call assert_true(&modified, 'dd staged a change')

  let g:test_confirm = 'save'                        " commit staged, then move
  call testmail#goto(id_a)
  normal M

  " A moved to archive; B's staged delete committed to trash
  call assert_true(isdirectory(root . '/archive/' . id_a), 'target moved')
  call assert_true(isdirectory(root . '/trash/' . id_b),
        \ 'staged delete was saved (to trash), not lost')
  call assert_false(isdirectory(root . '/inbox/' . id_a), 'A left inbox')
  call assert_false(isdirectory(root . '/inbox/' . id_b), 'B left inbox')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = ['Test_move_collision_reports_error', 'Test_move_clean_succeeds',
      \ 'Test_move_guard_cancel', 'Test_move_guard_discard', 'Test_move_guard_save']
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
