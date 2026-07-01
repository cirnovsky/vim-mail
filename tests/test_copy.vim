" Headless suite for Stage 3: the link map L, :Copy (add a label, keep source),
" and the :Move <mailbox> command form (relink without the interactive prompt).
"
" Store-backed fixtures are built with the REAL engine (mail_store.py
" ingest-stdin); the legacy-migration case still hand-builds a pre-store real dir
" (that format is exactly what ingest replaced, so it can't come from ingest).
"
" Run:  vim -u NONE -N -es -S tests/test_copy.vim
" Isolated temp store per test — never touches a real ~/Mail.

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on   " wire the <buffer> :Copy/:Move commands + BufWriteCmd

function! s:wipe_index_buffers() abort
  for b in range(1, bufnr('$'))
    if bufexists(b) && bufname(b) =~# '^mail://'
      execute 'bwipeout!' b
    endif
  endfor
endfunction

let g:test_move_dest = ''
function! mail#mailbox#_prompt_mailbox(prompt, default) abort
  return g:test_move_dest
endfunction

" Ingest a deterministic message (from <seed>) into <mailbox> via the REAL
" backend; same seed -> same canon (second mailbox = another link). Returns id.
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

" A legacy (pre content-store) real message directory living in a mailbox.
function! s:mkrealdir(root, mailbox, id) abort
  let d = a:root . '/' . a:mailbox . '/' . a:id
  call mkdir(d, 'p')
  call writefile(['Subject: legacy ' . a:id, 'Message-ID: <' . a:id . '>'], d . '/meta')
  call writefile(['raw'], d . '/raw.eml')
endfunction

function! s:ftype(p) abort
  return getftype(a:p)
endfunction

" --- the link map reflects disk: which mailboxes label each id ---
function! Test_link_map_reflects_disk() abort
  let root = tempname() . '/Mail'
  let id = s:mkmsg(root, 'inbox', 'a')
  call s:mkmsg(root, 'archive', 'a')          " same message, second label
  let g:mail_root = root

  call mail#link#rebuild()
  call assert_equal(['archive', 'inbox'], mail#link#labels(id), 'both labels seen')
  call assert_equal(1, mail#link#count_others(id, 'inbox'), 'one other label besides inbox')
  call assert_equal(0, mail#link#count_others('20260101T000000Z_zzzzzzzz', 'inbox'),
        \ 'unknown id has no labels')

  call delete(root, 'rf')
endfunction

" --- :Copy adds a label to dest and KEEPS the source (one canon, two links) ---
function! Test_copy_keeps_source() abort
  let root = tempname() . '/Mail'
  let id = s:mkmsg(root, 'inbox', 'b')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('inbox')
  call cursor(1, 1)
  Copy archive

  call assert_equal('link', s:ftype(root . '/inbox/' . id), 'source label kept')
  call assert_equal('link', s:ftype(root . '/archive/' . id), 'dest label added')
  call assert_equal(1, len(readdir(root . '/.store')), 'still exactly one canon')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- :Copy of a LEGACY real dir migrates it into the store, then links both ---
function! Test_copy_migrates_legacy() abort
  let root = tempname() . '/Mail'
  let id = '20260101T000000Z_cccccccc'
  call s:mkrealdir(root, 'inbox', id)
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('inbox')
  call cursor(1, 1)
  Copy archive

  call assert_true(isdirectory(root . '/.store/' . id), 'legacy dir migrated into the store')
  call assert_equal('link', s:ftype(root . '/inbox/' . id),
        \ 'source is now a symlink (migrated in place)')
  call assert_equal('link', s:ftype(root . '/archive/' . id), 'dest label added')
  call assert_true(filereadable(root . '/archive/' . id . '/raw.eml'),
        \ 'dest link resolves to the migrated bytes')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- :Move <mailbox> relinks without prompting (command form of M) ---
function! Test_move_command_arg() abort
  let root = tempname() . '/Mail'
  let id = s:mkmsg(root, 'inbox', 'd')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('inbox')
  call cursor(1, 1)
  let out = execute('Move archive')

  call assert_match('Moved 1 message', out, 'move_to reports success')
  call assert_equal('', s:ftype(root . '/inbox/' . id), 'source label gone')
  call assert_equal('link', s:ftype(root . '/archive/' . id), 'dest label present')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- copy then delete one label: the message survives via the other label ---
function! Test_copy_then_delete_one_survives() abort
  let root = tempname() . '/Mail'
  let id = s:mkmsg(root, 'inbox', 'e')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('inbox')
  call cursor(1, 1)
  " :Copy is a -nargs=1 user command — a trailing " comment would be swallowed
  " into the mailbox arg, so keep the command line bare.
  Copy archive

  " now labelled inbox + archive; drop the inbox label
  call cursor(1, 1)
  normal! dd
  silent write

  call assert_equal('', s:ftype(root . '/inbox/' . id), 'inbox label dropped')
  call assert_equal('link', s:ftype(root . '/archive/' . id), 'archive label survives')
  call assert_false(isdirectory(root . '/trash/' . id),
        \ 'not trashed — still labelled elsewhere')
  call assert_true(isdirectory(root . '/.store/' . id), 'canon kept')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = [
      \ 'Test_link_map_reflects_disk',
      \ 'Test_copy_keeps_source',
      \ 'Test_copy_migrates_legacy',
      \ 'Test_move_command_arg',
      \ 'Test_copy_then_delete_one_survives',
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
