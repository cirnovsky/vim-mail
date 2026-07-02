" Headless suite for content-store delete on :w:
"   delete = unlink (last label falls -> trash; from trash -> canon orphaned but
"            KEPT; a still-labelled message just loses one label).
" The critical invariant: a delete must NEVER destroy bytes — no rm/rf of a canon
" (orphans are freed later by a future :MailGC), and never rf through a symlink.
"
" Fixtures come from real .eml files ingested through the real backend, via the
" shared generator in tests/testlib (testmail#*). No hand-shaped canons.
"
" Run:  vim -u NONE -N -es -S tests/test_store_ops.vim
" Isolated temp store per test — never touches a real ~/Mail.

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on   " wire the <buffer> keymaps + BufWriteCmd we drive below

" --- delete the last label -> message goes to trash (recoverable), canon kept ---
function! Test_delete_last_link_to_trash() abort
  let root = tempname() . '/Mail'
  let id = testmail#ingest(root, 'inbox', 'plain')
  let g:mail_root = root

  call mail#index#open('inbox')
  call cursor(1, 1)
  normal! dd
  silent write

  call assert_equal('', testmail#ftype(root . '/inbox/' . id), 'inbox label removed')
  call assert_equal('link', testmail#ftype(root . '/trash/' . id),
        \ 'last label falls into trash as a symlink')
  call assert_true(isdirectory(root . '/.store/' . id),
        \ 'canonical bytes preserved (recoverable)')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- delete one of two labels -> just drops the label; NOT trashed, canon kept ---
function! Test_delete_one_of_two_labels() abort
  let root = tempname() . '/Mail'
  let id = testmail#ingest(root, 'inbox', 'plain')
  call testmail#ingest(root, 'archive', 'plain')      " same message, second label
  let g:mail_root = root

  call mail#index#open('inbox')
  call cursor(1, 1)
  normal! dd
  silent write

  call assert_equal('', testmail#ftype(root . '/inbox/' . id), 'inbox label removed')
  call assert_equal('link', testmail#ftype(root . '/archive/' . id), 'other label survives')
  call assert_false(isdirectory(root . '/trash/' . id),
        \ 'still-labelled message does NOT go to trash')
  call assert_true(isdirectory(root . '/.store/' . id),
        \ 'canon kept (message survives elsewhere)')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" delete from trash (last label) -> the canon is ORPHANED, not destroyed. Bytes
" are never rm'd by the plugin (a future :MailGC frees orphans), so undo stays
" recoverable.
function! Test_trash_delete_orphans_canon() abort
  let root = tempname() . '/Mail'
  let id = testmail#ingest(root, 'trash', 'plain')
  let g:mail_root = root

  call mail#index#open('trash')
  call cursor(1, 1)
  normal! dd
  silent write

  call assert_equal('', testmail#ftype(root . '/trash/' . id), 'trash label removed')
  call assert_true(isdirectory(root . '/.store/' . id),
        \ 'canonical bytes KEPT (orphaned) — never permanently destroyed')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- delete from trash while ALSO in inbox -> only unlinks trash; canon kept ---
function! Test_delete_from_trash_keeps_canon_if_linked_elsewhere() abort
  let root = tempname() . '/Mail'
  let id = testmail#ingest(root, 'trash', 'plain')
  call testmail#ingest(root, 'inbox', 'plain')        " same message, also in inbox
  let g:mail_root = root

  call mail#index#open('trash')
  call cursor(1, 1)
  normal! dd
  silent write

  call assert_equal('', testmail#ftype(root . '/trash/' . id), 'trash label removed')
  call assert_equal('link', testmail#ftype(root . '/inbox/' . id), 'inbox label survives')
  call assert_true(isdirectory(root . '/.store/' . id),
        \ 'canon kept — NOT rf-ed through the symlink into .store')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = [
      \ 'Test_delete_last_link_to_trash',
      \ 'Test_delete_one_of_two_labels',
      \ 'Test_trash_delete_orphans_canon',
      \ 'Test_delete_from_trash_keeps_canon_if_linked_elsewhere',
      \ ]
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
