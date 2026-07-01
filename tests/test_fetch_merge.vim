" Fetch into a mailbox that has STAGED edits and is currently hidden, then
" navigate back: the newly-fetched mail must appear AND the staged read-mark must
" survive. i.e. returning to a modified buffer should MERGE new disk mail
" incrementally, not skip the refresh wholesale (today it skips -> new mail is
" invisible) and not full-rebuild (that would discard the staged edit).
"
"   inbox: A (unread), B (unread)
"   s on A                 -> A read (staged)
"   :Mail archive          -> inbox now hidden + modified
"   <fetch a new message into inbox>   (mimicked: ingest to disk + refresh_for)
"   :Mail inbox            -> expect:  New (N)  /  A (read)  /  B (N)
"
" Run:  vim -u NONE -N -es -S tests/test_fetch_merge.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on

" Read-flag for <id> from the CURRENT buffer lines: 1 read, 0 unread, -1 absent.
function! s:buf_read(id) abort
  for ln in range(1, line('$'))
    let l = getline(ln)
    let tab = stridx(l, "\t")
    if tab >= 0 && l[:tab - 1] ==# a:id
      return l[tab + 1] ==# 'N' ? 0 : 1
    endif
  endfor
  return -1
endfunction

function! Test_fetch_into_modified_hidden_inbox() abort
  let root = tempname() . '/Mail'
  let a = testmail#ingest(root, 'inbox', 'plain')     " A
  let b = testmail#ingest(root, 'inbox', 'html')      " B
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  " inbox: mark A read (staged), then leave for archive -> inbox hidden+modified
  Mail inbox
  call testmail#goto(a) | normal s
  call assert_true(&modified, 'inbox modified by the staged read on A')
  Mail archive

  " fetch mimic: a new message lands in inbox on disk; fire the fetch callback
  let c = testmail#ingest_subject(root, 'inbox', 'New Mail')
  call mail#index#refresh_for(root . '/inbox')
  call assert_true(isdirectory(root . '/.store/' . c), 'new mail delivered to disk')

  " navigate back to inbox
  Mail inbox

  call assert_equal(3, len(getline(1, '$')), 'inbox shows three messages (new + A + B)')
  call assert_equal(0, s:buf_read(c), 'new mail shown, unread')
  call assert_equal(1, s:buf_read(a), 'A still read (staged edit preserved)')
  call assert_equal(0, s:buf_read(b), 'B still unread')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = ['Test_fetch_into_modified_hidden_inbox']
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
