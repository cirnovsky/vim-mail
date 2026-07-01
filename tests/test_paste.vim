" Native cross-buffer move/copy, driven like a HUMAN (headless): real yy / dd /
" p and real :w through the index buffer's keymaps + BufWriteCmd — no append()
" of fabricated lines, no direct call to write().
"   yy + p into another mailbox  = copy  (source keeps its label)
"   dd + p into another mailbox  = move  (once BOTH buffers are :w-ritten)
" A pasted line whose id resolves to nothing (stray register paste) is ignored.
"
" Store-backed fixtures use the REAL engine (mail_store.py ingest-stdin); the
" legacy-source case hand-builds a pre-store real dir (not producible by ingest).
"
" Run:  vim -u NONE -N -es -S tests/test_paste.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on   " wire the <buffer> keymaps + BufWriteCmd we drive below

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

function! s:mkrealdir(root, mailbox, id) abort
  let d = a:root . '/' . a:mailbox . '/' . a:id
  call mkdir(d, 'p')
  call writefile(['Subject: legacy ' . a:id, 'Message-ID: <' . a:id . '>'], d . '/meta')
  call writefile(['raw'], d . '/raw.eml')
endfunction

function! s:ftype(p) abort
  return getftype(a:p)
endfunction

function! s:goto(id) abort
  for ln in range(1, line('$'))
    let l = getline(ln)
    let tab = stridx(l, "\t")
    if tab >= 0 && l[:tab - 1] ==# a:id | call cursor(ln, 1) | return | endif
  endfor
  throw 'id not found in buffer: ' . a:id
endfunction

function! s:wipe_index_buffers() abort
  for b in range(1, bufnr('$'))
    if bufexists(b) && bufname(b) =~# '^mail://'
      execute 'bwipeout!' b
    endif
  endfor
endfunction

" --- yy + p = copy: yank a line in one mailbox, paste + :w in another ---
function! Test_yy_paste_is_copy() abort
  let root = tempname() . '/Mail'
  let id = s:mkmsg(root, 'inbox', 'a')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('inbox')
  call s:goto(id) | normal! yy          " yank the index line
  call mail#index#open('archive')
  normal! p                             " paste it
  silent write                          " :w -> archive gains the label

  call assert_equal('link', s:ftype(root . '/archive/' . id), 'archive got the label')
  call assert_equal('link', s:ftype(root . '/inbox/' . id), 'inbox label untouched (copy)')
  call assert_equal(1, len(readdir(root . '/.store')), 'still one canon')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- dd + p = move once BOTH buffers are :w-ritten ---
function! Test_dd_paste_is_move() abort
  let root = tempname() . '/Mail'
  let id = s:mkmsg(root, 'inbox', 'b')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('inbox')
  let inbox_buf = bufnr('%')
  call s:goto(id) | normal! dd            " cut the line
  call mail#index#open('archive')
  normal! p                              " paste into archive
  silent write                           " archive gains the label (copy so far)

  call assert_equal('link', s:ftype(root . '/archive/' . id), 'archive gained the label')
  call assert_equal('link', s:ftype(root . '/inbox/' . id),
        \ 'inbox still labelled until its buffer is written')

  call mail#index#open('inbox')          " navigate back with :Mail, like a human
  call assert_true(&modified, 'staged dd survives :Mail navigation back to source')
  silent write                           " commit inbox's cut -> net move

  call assert_equal('', s:ftype(root . '/inbox/' . id), 'inbox label dropped -> net move')
  call assert_equal('link', s:ftype(root . '/archive/' . id), 'archive label remains')
  call assert_true(isdirectory(root . '/.store/' . id), 'canon intact through the move')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- a stray register paste (unresolvable / non-index lines) is ignored ---
function! Test_paste_garbage_ignored() abort
  let root = tempname() . '/Mail'
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('archive')
  " Simulate the clipboard/register holding junk, then paste it for real.
  call setreg('"', ['this is not an index line',
        \ "20260101T000000Z_ffffffff\tN never ingested"], 'l')
  normal! p
  silent write

  call assert_equal('', s:ftype(root . '/archive/20260101T000000Z_ffffffff'),
        \ 'unresolvable id is not linked')
  call assert_false(isdirectory(root . '/.store'), 'no phantom canon created')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- pasting a LEGACY (un-migrated) message links it, migrating the source ---
function! Test_paste_migrates_legacy_source() abort
  let root = tempname() . '/Mail'
  let id = '20260101T000000Z_cccccccc'
  call s:mkrealdir(root, 'inbox', id)     " legacy real dir, not in .store
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('inbox')
  call s:goto(id) | normal! yy
  call mail#index#open('archive')
  normal! p
  silent write

  call assert_true(isdirectory(root . '/.store/' . id),
        \ 'legacy source migrated into the store on paste')
  call assert_equal('link', s:ftype(root . '/archive/' . id), 'archive linked to the canon')
  call assert_equal('link', s:ftype(root . '/inbox/' . id),
        \ 'source became a symlink (migrate-on-touch)')
  call assert_true(filereadable(root . '/archive/' . id . '/raw.eml'),
        \ 'archive link resolves to the migrated bytes')

  call s:wipe_index_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = [
      \ 'Test_yy_paste_is_copy',
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
