" Headless suite for Stage 4: native cross-buffer move/copy.
"   yy + p into another mailbox  = copy  (source keeps its label)
"   dd + p into another mailbox  = move  (once BOTH buffers are written)
" Mechanism: a buffer line whose id is absent from that buffer's disk baseline is
" a pasted label -> link it into this mailbox at :w. Copy is a legal intermediate
" state, so every per-buffer :w lands F valid. Garbage/unresolvable pasted lines
" are ignored.
"
" Run:  vim -u NONE -N -es -S tests/test_paste.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime! autoload/mail/*.vim

function! s:mkcanon(root, id) abort
  let d = a:root . '/.store/' . a:id
  call mkdir(d, 'p')
  call writefile(['From: A <a@example.com>', 'Subject: test ' . a:id,
        \ 'Date: Tue, 23 Jun 2026 08:00:00 -0700',
        \ 'Message-ID: <' . a:id . '@example.com>'], d . '/meta')
  call writefile(['raw bytes for ' . a:id], d . '/raw.eml')
endfunction

function! s:link(root, mailbox, id) abort
  let mb = a:root . '/' . a:mailbox
  call mkdir(mb, 'p')
  call system('ln -s ' . shellescape('../.store/' . a:id) . ' '
        \ . shellescape(mb . '/' . a:id))
endfunction

function! s:mkrealdir(root, mailbox, id) abort
  let d = a:root . '/' . a:mailbox . '/' . a:id
  call mkdir(d, 'p')
  call writefile(['Subject: legacy ' . a:id, 'Message-ID: <' . a:id . '>'], d . '/meta')
  call writefile(['raw'], d . '/raw.eml')
endfunction

function! s:ftype(p) abort
  return getftype(a:p)
endfunction

" --- yy + p = copy: pasting a foreign line into a mailbox links it there,
"     source label untouched, one canon ---
function! Test_paste_is_copy() abort
  let root = tempname() . '/Mail'
  let id = '20260101T000000Z_aaaaaaaa'
  call s:mkcanon(root, id)
  call s:link(root, 'inbox', id)
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('archive')       " empty buffer
  " Simulate a paste of inbox's index line into archive.
  call append(line('$'), id . "\tN Tue 23 Jun 2026 08:00  A  test")
  call mail#actions#write()

  call assert_equal('link', s:ftype(root . '/archive/' . id), 'archive got the label')
  call assert_equal('link', s:ftype(root . '/inbox/' . id), 'inbox label untouched (copy)')
  call assert_equal(1, len(readdir(root . '/.store')), 'still one canon')

  bwipeout!
  call delete(root, 'rf')
endfunction

" --- dd + p across buffers = move once BOTH buffers are written ---
function! Test_dd_paste_is_move() abort
  let root = tempname() . '/Mail'
  let id = '20260101T000000Z_bbbbbbbb'
  call s:mkcanon(root, id)
  call s:link(root, 'inbox', id)
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('inbox')
  let inbox_buf = bufnr('%')
  call cursor(1, 1)
  normal! dd                             " staged delete in inbox; line -> unnamed reg
  " refresh() deletes into the black-hole register, so the yanked line survives.
  call mail#index#open('archive')
  normal! p                              " paste the inbox line into archive
  call mail#actions#write()              " archive :w -> gains the label (copy so far)

  call assert_equal('link', s:ftype(root . '/archive/' . id), 'archive gained the label')
  call assert_equal('link', s:ftype(root . '/inbox/' . id),
        \ 'inbox still labelled until its buffer is written')

  " Commit the inbox buffer's staged delete WITHOUT refreshing it away.
  execute 'buffer' inbox_buf
  call mail#actions#write()

  call assert_equal('', s:ftype(root . '/inbox/' . id), 'inbox label dropped -> net move')
  call assert_equal('link', s:ftype(root . '/archive/' . id), 'archive label remains')
  call assert_true(isdirectory(root . '/.store/' . id), 'canon intact through the move')

  execute 'bwipeout!' inbox_buf
  call delete(root, 'rf')
endfunction

" --- garbage / unresolvable pasted lines are ignored (register clobber guard) ---
function! Test_paste_garbage_ignored() abort
  let root = tempname() . '/Mail'
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('archive')
  call append(line('$'), 'this is not an index line at all')
  call append(line('$'), "20260101T000000Z_ffffffff\tN bogus  X  never ingested")
  call mail#actions#write()

  call assert_equal('', s:ftype(root . '/archive/20260101T000000Z_ffffffff'),
        \ 'unresolvable id is not linked')
  call assert_false(isdirectory(root . '/.store'), 'no phantom canon created')

  bwipeout!
  call delete(root, 'rf')
endfunction

" --- pasting a LEGACY (un-migrated) message links it, migrating the source ---
function! Test_paste_migrates_legacy_source() abort
  let root = tempname() . '/Mail'
  let id = '20260101T000000Z_cccccccc'
  call s:mkrealdir(root, 'inbox', id)     " legacy real dir, not in .store
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('archive')
  call append(line('$'), id . "\tN Tue 23 Jun 2026 08:00  A  legacy")
  call mail#actions#write()

  call assert_true(isdirectory(root . '/.store/' . id),
        \ 'legacy source migrated into the store on paste')
  call assert_equal('link', s:ftype(root . '/archive/' . id), 'archive linked to the canon')
  call assert_equal('link', s:ftype(root . '/inbox/' . id),
        \ 'source became a symlink (migrate-on-touch)')
  call assert_true(filereadable(root . '/archive/' . id . '/raw.eml'),
        \ 'archive link resolves to the migrated bytes')

  bwipeout!
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = [
      \ 'Test_paste_is_copy',
      \ 'Test_dd_paste_is_move',
      \ 'Test_paste_garbage_ignored',
      \ 'Test_paste_migrates_legacy_source',
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
