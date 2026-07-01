" Headless suite for the content-store link operations (Stage 2):
"   move   = relink  (add dest symlink, drop source symlink; bytes untouched)
"   delete = unlink  (last label falls -> trash; from trash -> permanent rm of
"            the canonical bytes; a still-labelled message just loses one label)
" The critical invariant: a delete must NEVER rf through a symlink into .store.
"
" Fixtures are built with the REAL engine (mail_store.py ingest-stdin), so the
" canonical .store/<id>/ is exactly what production ingest produces — no
" hand-shaped canon that could drift from the real layout.
"
" Run:  vim -u NONE -N -es -S tests/test_store_ops.vim
" Isolated temp store per test — never touches a real ~/Mail.

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on   " wire the <buffer> keymaps + BufWriteCmd we drive below

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

" Ingest a deterministic message (built from <seed>) into <mailbox> via the REAL
" backend. Same seed -> same message -> same canon, so a second mailbox just gets
" another link (labels). Returns the message id (store-dir basename).
function! s:mkmsg(root, mailbox, seed) abort
  let mb = a:root . '/' . a:mailbox
  call mkdir(mb, 'p')
  let before = {}
  for e in glob(mb . '/*', 0, 1) | let before[fnamemodify(e, ':t')] = 1 | endfor
  let raw = join([
        \ 'From: ' . a:seed . ' <' . a:seed . '@example.com>',
        \ 'To: me@example.com', 'Subject: ' . a:seed,
        \ 'Date: Tue, 23 Jun 2026 08:00:00 -0700',
        \ 'Message-ID: <' . a:seed . '@example.com>', '', 'Body ' . a:seed, ''], "\n")
  call system(g:mail_python . ' ' . shellescape(g:mail_store_py)
        \ . ' ingest-stdin ' . shellescape(mb), raw)
  for e in glob(mb . '/*', 0, 1)
    let id = fnamemodify(e, ':t')
    if !has_key(before, id) | return id | endif
  endfor
  throw 'ingest produced no new entry in ' . mb . ' for seed ' . a:seed
endfunction

function! s:ftype(path) abort
  return getftype(a:path)
endfunction

" --- move relinks: source link gone, dest link present, canon intact ---
function! Test_move_relinks() abort
  let root = tempname() . '/Mail'
  let id = s:mkmsg(root, 'inbox', 'a')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root
  let g:test_move_dest = 'archive'

  call mail#index#open('inbox')
  call cursor(1, 1)
  let out = execute('normal M')

  call assert_match('Moved 1 message', out, 'relink reports success')
  call assert_equal('', s:ftype(root . '/inbox/' . id), 'source symlink removed')
  call assert_equal('link', s:ftype(root . '/archive/' . id),
        \ 'dest is a symlink (relink, not a copy of bytes)')
  call assert_true(isdirectory(root . '/.store/' . id),
        \ 'canonical bytes still live in .store')
  call assert_true(filereadable(root . '/archive/' . id . '/raw.eml'),
        \ 'dest link resolves to the bytes')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- delete the last label -> message goes to trash (recoverable), canon kept ---
function! Test_delete_last_link_to_trash() abort
  let root = tempname() . '/Mail'
  let id = s:mkmsg(root, 'inbox', 'b')
  let g:mail_root = root

  call mail#index#open('inbox')
  call cursor(1, 1)
  normal! dd
  silent write

  call assert_equal('', s:ftype(root . '/inbox/' . id), 'inbox label removed')
  call assert_equal('link', s:ftype(root . '/trash/' . id),
        \ 'last label falls into trash as a symlink')
  call assert_true(isdirectory(root . '/.store/' . id),
        \ 'canonical bytes preserved (recoverable)')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- delete one of two labels -> just drops the label; NOT trashed, canon kept ---
function! Test_delete_one_of_two_labels() abort
  let root = tempname() . '/Mail'
  let id = s:mkmsg(root, 'inbox', 'c')
  call s:mkmsg(root, 'archive', 'c')          " same message, second label
  let g:mail_root = root

  call mail#index#open('inbox')
  call cursor(1, 1)
  normal! dd
  silent write

  call assert_equal('', s:ftype(root . '/inbox/' . id), 'inbox label removed')
  call assert_equal('link', s:ftype(root . '/archive/' . id), 'other label survives')
  call assert_false(isdirectory(root . '/trash/' . id),
        \ 'still-labelled message does NOT go to trash')
  call assert_true(isdirectory(root . '/.store/' . id),
        \ 'canon kept (message survives elsewhere)')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- delete from trash, last label -> PERMANENT: canonical bytes removed ---
function! Test_permanent_delete_from_trash() abort
  let root = tempname() . '/Mail'
  let id = s:mkmsg(root, 'trash', 'd')
  let g:mail_root = root

  call mail#index#open('trash')
  call cursor(1, 1)
  normal! dd
  silent write

  call assert_equal('', s:ftype(root . '/trash/' . id), 'trash label removed')
  call assert_false(isdirectory(root . '/.store/' . id),
        \ 'canonical bytes permanently removed (was the last label, in trash)')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- delete from trash while ALSO in inbox -> only unlinks trash; canon kept ---
function! Test_delete_from_trash_keeps_canon_if_linked_elsewhere() abort
  let root = tempname() . '/Mail'
  let id = s:mkmsg(root, 'trash', 'e')
  call s:mkmsg(root, 'inbox', 'e')            " same message, also in inbox
  let g:mail_root = root

  call mail#index#open('trash')
  call cursor(1, 1)
  normal! dd
  silent write

  call assert_equal('', s:ftype(root . '/trash/' . id), 'trash label removed')
  call assert_equal('link', s:ftype(root . '/inbox/' . id), 'inbox label survives')
  call assert_true(isdirectory(root . '/.store/' . id),
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
