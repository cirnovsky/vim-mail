" Link map L: {id -> set of mailboxes labelling it}, built from readdirs. The
" refcount source for last-label delete decisions.
"
" Run:  vim -u NONE -N -es -S tests/test_link.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim

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

" --- runner ---
let v:errors = []
let s:tests = ['Test_link_map_reflects_disk']
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
