" TRASH: a virtual read-only view of orphaned canons (last-label deletes). A
" message still referenced by another mailbox is NOT trash. Recover via yy in
" TRASH + paste into a real mailbox (the normal paste path relinks the canon).
"
" Run:  vim -u NONE -N -es -S tests/test_trash.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on

" ids currently shown in the TRASH buffer (from b:mail_entries)
function! s:trash_ids() abort
  return exists('b:mail_entries') ? map(copy(b:mail_entries), 'v:val.id') : []
endfunction

" --- a last-label delete shows up in TRASH, and yy+paste recovers it ---
function! Test_orphan_shows_and_recovers() abort
  let root = tempname() . '/Mail'
  let a = testmail#ingest(root, 'inbox', 'plain')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  " dd A out of inbox (its only label) -> orphaned canon on :w
  call mail#index#open('inbox')
  call testmail#goto(a) | normal! dd
  silent write
  call assert_equal('', testmail#ftype(root . '/inbox/' . a), 'A unlinked from inbox')
  call assert_true(isdirectory(root . '/.store/' . a), 'A canon kept (orphan)')

  " TRASH shows the orphan, read-only
  call mail#trash#open()
  call assert_equal('mail://TRASH', bufname('%'), 'TRASH buffer open')
  call assert_false(&modifiable, 'TRASH is read-only')
  call assert_notequal(-1, index(s:trash_ids(), a), 'A appears in TRASH')

  " recover: yank the orphan line, paste into archive, commit
  call testmail#goto(a) | normal! yy
  call mail#index#open('archive')
  normal! p
  silent write
  call assert_equal('link', testmail#ftype(root . '/archive/' . a), 'A recovered into archive')

  " rescanning TRASH: A is referenced again -> gone
  call mail#trash#open()
  call assert_equal(-1, index(s:trash_ids(), a), 'A gone from TRASH after recovery')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- the launcher lists TRASH and <CR> opens the read-only view ---
function! Test_launcher_routes_to_trash() abort
  let root = tempname() . '/Mail'
  let a = testmail#ingest(root, 'inbox', 'plain')
  let g:mail_root = root
  call mail#index#open('inbox')
  call cursor(1, 1)
  normal! dd
  silent write                                          " orphan it

  call mail#mailboxlist#open()
  call assert_notequal(-1, index(map(copy(b:mailbox_cells), 'v:val.name'), 'TRASH'), 'launcher lists TRASH')
  call cursor(1, 1)
  call search('\VTRASH', 'cW')
  call mail#mailboxlist#enter()
  call assert_equal('mail://TRASH', bufname('%'), '<CR> on TRASH opens the view')
  call assert_false(&modifiable, 'TRASH read-only via launcher')
  call assert_notequal(-1, index(map(copy(b:mail_entries), 'v:val.id'), a), 'orphan shown')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- a message still labelled elsewhere is NOT in TRASH ---
function! Test_multi_label_not_trashed() abort
  let root = tempname() . '/Mail'
  let b = testmail#ingest(root, 'inbox', 'html')
  call testmail#ingest(root, 'archive', 'html')      " same message, second label
  let g:mail_root = root

  call mail#index#open('inbox')
  call testmail#goto(b) | normal! dd
  silent write
  call assert_equal('', testmail#ftype(root . '/inbox/' . b), 'B dropped from inbox')
  call assert_equal('link', testmail#ftype(root . '/archive/' . b), 'B still in archive')

  call mail#trash#open()
  call assert_equal(-1, index(s:trash_ids(), b), 'B not in TRASH (still referenced)')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- an (unread) orphan opens for reading despite TRASH being nomodifiable ---
" Regression: open/preview staged a read-mark via setline(), which throws on a
" nomodifiable buffer and aborted the open — so unread orphans wouldn't open.
function! Test_open_in_trash() abort
  let root = tempname() . '/Mail'
  let a = testmail#ingest(root, 'inbox', 'plain')       " ingested => unread
  let g:mail_root = root

  call mail#index#open('inbox')
  call testmail#goto(a) | normal! dd
  silent write                                          " orphan it

  call mail#trash#open()
  call testmail#goto(a)
  call mail#view#open_message()
  call assert_match('^\[Mail\]', bufname('%'), 'unread orphan opens in a [Mail] view')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = ['Test_orphan_shows_and_recovers', 'Test_launcher_routes_to_trash',
      \ 'Test_multi_label_not_trashed', 'Test_open_in_trash']
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
