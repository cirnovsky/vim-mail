" Headless suite for the content-store link operations (Stage 2):
"   move   = relink  (add dest symlink, drop source symlink; bytes untouched)
"   delete = unlink  (last label falls -> trash; from trash -> permanent rm of
"            the canonical bytes; a still-labelled message just loses one label)
" The critical invariant: a delete must NEVER rf through a symlink into .store.
"
" Run:  vim -u NONE -N -es -S tests/test_store_ops.vim
" Isolated temp store per test — never touches a real ~/Mail.

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on   " wire the <buffer> keymaps + BufWriteCmd we drive below

" Wipe every index buffer between tests — they're named by mailbox basename
" (mail://inbox, …), so leftovers would collide on name and leave the next
" buffer unnamed (breaking :w).
function! s:wipe_index_buffers() abort
  for b in range(1, bufnr('$'))
    if bufexists(b) && bufname(b) =~# '^mail://'
      execute 'bwipeout!' b
    endif
  endfor
endfunction

" Stub the mailbox prompt + confirm so actions run without interactive input.
let g:test_move_dest = ''
function! mail#mailbox#_prompt_mailbox(prompt, default) abort
  return g:test_move_dest
endfunction
let g:test_confirm = 'discard'
function! mail#actions#_confirm(msg) abort
  return g:test_confirm
endfunction

" Canonical message dir under <root>/.store/<id>/ (meta + raw.eml).
function! s:mkcanon(root, id) abort
  let d = a:root . '/.store/' . a:id
  call mkdir(d, 'p')
  call writefile([
        \ 'From: A <a@example.com>',
        \ 'Subject: test ' . a:id,
        \ 'Date: Tue, 23 Jun 2026 08:00:00 -0700',
        \ 'Message-ID: <' . a:id . '@example.com>',
        \ ], d . '/meta')
  call writefile(['raw bytes for ' . a:id], d . '/raw.eml')
endfunction

" A mailbox membership: <root>/<mailbox>/<id> -> ../.store/<id> (relative symlink).
function! s:link(root, mailbox, id) abort
  " Build the fixture with the REAL production linker so setup exercises the
  " same code the tests check — not a duplicate hand-rolled ln -s.
  call mail#actions#_make_link(a:id, a:root . '/' . a:mailbox)
endfunction

function! s:ftype(path) abort
  return getftype(a:path)
endfunction

" --- move relinks: source link gone, dest link present, canon intact ---
function! Test_move_relinks() abort
  let root = tempname() . '/Mail'
  call s:mkcanon(root, '20260101T000000Z_aaaaaaaa')
  call s:link(root, 'inbox', '20260101T000000Z_aaaaaaaa')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root
  let g:test_move_dest = 'archive'

  call mail#index#open('inbox')
  call cursor(1, 1)
  let out = execute('normal M')          " press M (keymap); prompt stubbed -> archive

  call assert_match('Moved 1 message', out, 'relink reports success')
  call assert_equal('', s:ftype(root . '/inbox/20260101T000000Z_aaaaaaaa'),
        \ 'source symlink removed')
  call assert_equal('link', s:ftype(root . '/archive/20260101T000000Z_aaaaaaaa'),
        \ 'dest is a symlink (relink, not a copy of bytes)')
  call assert_true(isdirectory(root . '/.store/20260101T000000Z_aaaaaaaa'),
        \ 'canonical bytes still live in .store')
  call assert_true(filereadable(root . '/archive/20260101T000000Z_aaaaaaaa/raw.eml'),
        \ 'dest link resolves to the bytes')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- delete the last label -> message goes to trash (recoverable), canon kept ---
function! Test_delete_last_link_to_trash() abort
  let root = tempname() . '/Mail'
  call s:mkcanon(root, '20260101T000000Z_bbbbbbbb')
  call s:link(root, 'inbox', '20260101T000000Z_bbbbbbbb')
  let g:mail_root = root

  call mail#index#open('inbox')
  call cursor(1, 1)
  normal! dd
  silent write

  call assert_equal('', s:ftype(root . '/inbox/20260101T000000Z_bbbbbbbb'),
        \ 'inbox label removed')
  call assert_equal('link', s:ftype(root . '/trash/20260101T000000Z_bbbbbbbb'),
        \ 'last label falls into trash as a symlink')
  call assert_true(isdirectory(root . '/.store/20260101T000000Z_bbbbbbbb'),
        \ 'canonical bytes preserved (recoverable)')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- delete one of two labels -> just drops the label; NOT trashed, canon kept ---
function! Test_delete_one_of_two_labels() abort
  let root = tempname() . '/Mail'
  call s:mkcanon(root, '20260101T000000Z_cccccccc')
  call s:link(root, 'inbox', '20260101T000000Z_cccccccc')
  call s:link(root, 'archive', '20260101T000000Z_cccccccc')
  let g:mail_root = root

  call mail#index#open('inbox')
  call cursor(1, 1)
  normal! dd
  silent write

  call assert_equal('', s:ftype(root . '/inbox/20260101T000000Z_cccccccc'),
        \ 'inbox label removed')
  call assert_equal('link', s:ftype(root . '/archive/20260101T000000Z_cccccccc'),
        \ 'other label survives')
  call assert_false(isdirectory(root . '/trash/20260101T000000Z_cccccccc'),
        \ 'still-labelled message does NOT go to trash')
  call assert_true(isdirectory(root . '/.store/20260101T000000Z_cccccccc'),
        \ 'canon kept (message survives elsewhere)')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- delete from trash, last label -> PERMANENT: canonical bytes removed ---
function! Test_permanent_delete_from_trash() abort
  let root = tempname() . '/Mail'
  call s:mkcanon(root, '20260101T000000Z_dddddddd')
  call s:link(root, 'trash', '20260101T000000Z_dddddddd')
  let g:mail_root = root

  call mail#index#open('trash')
  call cursor(1, 1)
  normal! dd
  silent write

  call assert_equal('', s:ftype(root . '/trash/20260101T000000Z_dddddddd'),
        \ 'trash label removed')
  call assert_false(isdirectory(root . '/.store/20260101T000000Z_dddddddd'),
        \ 'canonical bytes permanently removed (was the last label, in trash)')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- delete from trash while ALSO in inbox -> only unlinks trash; canon kept ---
function! Test_delete_from_trash_keeps_canon_if_linked_elsewhere() abort
  let root = tempname() . '/Mail'
  call s:mkcanon(root, '20260101T000000Z_eeeeeeee')
  call s:link(root, 'trash', '20260101T000000Z_eeeeeeee')
  call s:link(root, 'inbox', '20260101T000000Z_eeeeeeee')
  let g:mail_root = root

  call mail#index#open('trash')
  call cursor(1, 1)
  normal! dd
  silent write

  call assert_equal('', s:ftype(root . '/trash/20260101T000000Z_eeeeeeee'),
        \ 'trash label removed')
  call assert_equal('link', s:ftype(root . '/inbox/20260101T000000Z_eeeeeeee'),
        \ 'inbox label survives')
  call assert_true(isdirectory(root . '/.store/20260101T000000Z_eeeeeeee'),
        \ 'canon kept — NOT rf-ed through the symlink into .store')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = [
      \ 'Test_move_relinks',
      \ 'Test_delete_last_link_to_trash',
      \ 'Test_delete_one_of_two_labels',
      \ 'Test_permanent_delete_from_trash',
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
