" Headless suite for Stage 3: the link map L, :Copy (add a label, keep source),
" and the :Move <mailbox> command form (relink without the interactive prompt).
"
" Fixtures come from real .eml files via the shared generator (testmail#*). The
" legacy-migration case uses testmail#legacy — a faithful pre-store real dir with
" full production contents (ingest, then de-symlink).
"
" Run:  vim -u NONE -N -es -S tests/test_copy.vim
" Isolated temp store per test — never touches a real ~/Mail.

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on   " wire the <buffer> :Copy/:Move commands + BufWriteCmd

let g:test_move_dest = ''
function! mail#mailbox#_prompt_mailbox(prompt, default) abort
  return g:test_move_dest
endfunction

" --- the link map reflects disk: which mailboxes label each id ---
function! Test_link_map_reflects_disk() abort
  let root = tempname() . '/Mail'
  let id = testmail#ingest(root, 'inbox', 'plain')
  call testmail#ingest(root, 'archive', 'plain')      " same message, second label
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
  let id = testmail#ingest(root, 'inbox', 'plain')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('inbox')
  call cursor(1, 1)
  Copy archive

  call assert_equal('link', testmail#ftype(root . '/inbox/' . id), 'source label kept')
  call assert_equal('link', testmail#ftype(root . '/archive/' . id), 'dest label added')
  call assert_equal(1, len(readdir(root . '/.store')), 'still exactly one canon')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- :Copy of a LEGACY real dir migrates it into the store, then links both ---
function! Test_copy_migrates_legacy() abort
  let root = tempname() . '/Mail'
  let id = testmail#legacy(root, 'inbox', 'plain')    " faithful pre-store real dir
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('inbox')
  call cursor(1, 1)
  Copy archive

  call assert_true(isdirectory(root . '/.store/' . id), 'legacy dir migrated into the store')
  call assert_equal('link', testmail#ftype(root . '/inbox/' . id),
        \ 'source is now a symlink (migrated in place)')
  call assert_equal('link', testmail#ftype(root . '/archive/' . id), 'dest label added')
  call assert_true(filereadable(root . '/archive/' . id . '/body.txt'),
        \ 'dest link resolves to the migrated bytes (full production contents)')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- :Move <mailbox> relinks without prompting (command form of M) ---
function! Test_move_command_arg() abort
  let root = tempname() . '/Mail'
  let id = testmail#ingest(root, 'inbox', 'plain')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('inbox')
  call cursor(1, 1)
  let out = execute('Move archive')

  call assert_match('Moved 1 message', out, 'move_to reports success')
  call assert_equal('', testmail#ftype(root . '/inbox/' . id), 'source label gone')
  call assert_equal('link', testmail#ftype(root . '/archive/' . id), 'dest label present')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- copy then delete one label: the message survives via the other label ---
function! Test_copy_then_delete_one_survives() abort
  let root = tempname() . '/Mail'
  let id = testmail#ingest(root, 'inbox', 'plain')
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

  call assert_equal('', testmail#ftype(root . '/inbox/' . id), 'inbox label dropped')
  call assert_equal('link', testmail#ftype(root . '/archive/' . id), 'archive label survives')
  call assert_false(isdirectory(root . '/trash/' . id),
        \ 'not trashed — still labelled elsewhere')
  call assert_true(isdirectory(root . '/.store/' . id), 'canon kept')

  call testmail#wipe_buffers()
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
