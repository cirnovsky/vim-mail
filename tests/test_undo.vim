" Undo must survive :w (and navigation). Drive a dd+p move plus a read-mark,
" commit it, then `u` all the way back and re-commit — the store returns to the
" original state.
"
"   inbox: A (unread)   archive: B (unread)
"   in inbox: s on A (read), dd on A
"   :Mail archive, p, :w         -> A moved to archive
"   u                            -> archive: only B (unread)
"   :Mail inbox                  -> inbox: nothing
"   u                            -> inbox: A (read)     [undo the dd]
"   u                            -> inbox: A (unread)   [undo the s]
"   :w                           -> F matches T (back to the original)
"
" Run:  vim -u NONE -N -es -S tests/test_undo.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on

" ids in the current buffer, top to bottom
function! s:ids() abort
  let r = []
  for ln in range(1, line('$'))
    let l = getline(ln)
    let t = stridx(l, "\t")
    if t >= 0 | call add(r, l[:t - 1]) | endif
  endfor
  return r
endfunction

" read-flag of <id> in the current buffer: 1 read, 0 unread, -1 absent
function! s:read(id) abort
  for ln in range(1, line('$'))
    let l = getline(ln)
    let t = stridx(l, "\t")
    if t >= 0 && l[:t - 1] ==# a:id | return l[t + 1] ==# 'N' ? 0 : 1 | endif
  endfor
  return -1
endfunction

function! Test_undo_after_write() abort
  let root = tempname() . '/Mail'
  let a = testmail#ingest(root, 'inbox', 'plain')
  let b = testmail#ingest(root, 'archive', 'html')
  let g:mail_root = root

  " in inbox: mark A read, then cut it. Headless note: consecutive programmatic
  " changes share one undo block (no keystroke to close it), so force an undo
  " boundary between s and dd to mirror what real typing gives — otherwise one
  " `u` would revert both at once.
  Mail inbox
  call testmail#goto(a) | normal s
  let &undolevels = &undolevels
  call testmail#goto(a) | normal! dd

  " paste into archive and commit the move
  Mail archive
  normal! p
  silent write

  " u in archive undoes the paste -> only B remains
  normal! u
  call assert_equal([b], s:ids(), 'archive shows only B after undo of the paste')
  call assert_equal(0, s:read(b), 'B unread')

  " inbox is empty (A moved out)
  Mail inbox
  call assert_equal([], s:ids(), 'inbox shows nothing')

  " u undoes the dd -> A back, still read (the staged s)
  normal! u
  call assert_equal([a], s:ids(), 'inbox: A restored by undo of dd')
  call assert_equal(1, s:read(a), 'A is read (the s-mark survived)')

  " u undoes the s -> A unread
  normal! u
  call assert_equal([a], s:ids(), 'inbox: A still present after undo of s')
  call assert_equal(0, s:read(a), 'A now unread')

  " commit the fully-undone state; disk (F) must match the buffers (T)
  silent write
  call assert_equal('link', testmail#ftype(root . '/inbox/' . a), 'A re-linked into inbox')
  call assert_equal('', testmail#ftype(root . '/archive/' . a), 'A not in archive')
  call assert_equal('link', testmail#ftype(root . '/archive/' . b), 'B still in archive')
  call assert_false(filereadable(root . '/.store/' . a . '/.read'), 'A unread on disk')
  call assert_false(filereadable(root . '/.store/' . b . '/.read'), 'B unread on disk')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = ['Test_undo_after_write']
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
