" :w commits the staged edits of EVERY modified index buffer, not just the
" current one. Here inbox has a staged delete and archive a staged read-mark;
" a single :w (issued from archive) must commit both.
"
" Run:  vim -u NONE -N -es -S tests/test_write_all.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on

function! Test_w_commits_all_modified_buffers() abort
  let root = tempname() . '/Mail'
  let x = testmail#ingest(root, 'inbox', 'plain')     " will be deleted in inbox
  let y = testmail#ingest(root, 'archive', 'html')    " will be marked read in archive
  let g:mail_root = root

  " stage a delete in inbox
  call mail#index#open('inbox')
  let inbox_buf = bufnr('%')
  call testmail#goto(x) | normal! dd
  call assert_true(&modified, 'inbox has a staged delete')

  " stage a read-mark in archive, then :w from HERE (archive is current)
  call mail#index#open('archive')
  call testmail#goto(y) | normal s
  call assert_true(&modified, 'archive has a staged read-mark')
  silent write

  " inbox's delete committed even though we :w-rote from archive
  call assert_equal('', testmail#ftype(root . '/inbox/' . x), 'inbox delete committed')
  call assert_equal('link', testmail#ftype(root . '/trash/' . x),
        \ 'X was the last label -> fell to trash')

  " archive's read-mark committed to the shared canon
  call assert_true(filereadable(root . '/.store/' . y . '/.read'), 'archive read committed')
  call assert_equal('link', testmail#ftype(root . '/archive/' . y), 'Y still labelled in archive')

  " both buffers are now unmodified
  call assert_false(getbufvar(inbox_buf, '&modified'), 'inbox buffer no longer modified')
  call assert_false(&modified, 'archive buffer no longer modified')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = ['Test_w_commits_all_modified_buffers']
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
