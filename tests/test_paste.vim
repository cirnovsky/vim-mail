" Native cross-buffer move/copy, driven like a HUMAN (headless): real yy / dd /
" p and real :w through the index buffer's keymaps + BufWriteCmd — no append()
" of fabricated lines, no direct call to write().
"   yy + p into another mailbox  = copy  (source keeps its label)
"   dd + p into another mailbox  = move  (one :w commits both the add and the drop)
" A pasted line whose id resolves to nothing (stray register paste) is ignored.
"
" Fixtures come from real .eml files via the shared generator (testmail#*).
"
" Run:  vim -u NONE -N -es -S tests/test_paste.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on   " wire the <buffer> keymaps + BufWriteCmd we drive below

" --- yy + p = copy: yank a line in one mailbox, paste + :w in another ---
function! Test_yy_paste_is_copy() abort
  let root = tempname() . '/Mail'
  let id = testmail#ingest(root, 'inbox', 'plain')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('inbox')
  call testmail#goto(id) | normal! yy       " yank the index line
  call mail#index#open('archive')
  normal! p                                 " paste it
  silent write                              " :w -> archive gains the label

  call assert_equal('link', testmail#ftype(root . '/archive/' . id), 'archive got the label')
  call assert_equal('link', testmail#ftype(root . '/inbox/' . id), 'inbox label untouched (copy)')
  call assert_equal(1, len(readdir(root . '/.store')), 'still one canon')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- dd + p = move, committed by a SINGLE :w (which commits all modified bufs) ---
function! Test_dd_paste_is_move() abort
  let root = tempname() . '/Mail'
  let id = testmail#ingest(root, 'inbox', 'plain')
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  call mail#index#open('inbox')
  call testmail#goto(id) | normal! dd        " cut the line (staged delete in inbox)
  call mail#index#open('archive')
  normal! p                                  " paste into archive (staged add)
  silent write                               " ONE :w commits both -> net move

  call assert_equal('', testmail#ftype(root . '/inbox/' . id),
        \ 'inbox label dropped by the same :w -> net move')
  call assert_equal('link', testmail#ftype(root . '/archive/' . id), 'archive label present')
  call assert_false(isdirectory(root . '/trash/' . id),
        \ 'not trashed — the add commits before the drop, so the refcount sees the dest')
  call assert_true(isdirectory(root . '/.store/' . id), 'canon intact through the move')

  call testmail#wipe_buffers()
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

  call assert_equal('', testmail#ftype(root . '/archive/20260101T000000Z_ffffffff'),
        \ 'unresolvable id is not linked')
  call assert_false(isdirectory(root . '/.store'), 'no phantom canon created')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = [
      \ 'Test_yy_paste_is_copy',
      \ 'Test_dd_paste_is_move',
      \ 'Test_paste_garbage_ignored',
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
