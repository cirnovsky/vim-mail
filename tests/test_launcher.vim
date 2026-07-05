" The mailbox launcher: `:Mail` (no arg) opens a read-only list of mailboxes;
" <CR> enters one; `-` from a mailbox returns to the list; `:Mail <box>` still
" opens a mailbox directly. Each mailbox keeps its own buffer.
"
" Run:  vim -u NONE -N -es -S tests/test_launcher.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on

function! s:goto_line(text) abort
  call cursor(1, 1)
  let ln = search('\V\^' . a:text . '\$', 'cW')
  call assert_true(ln > 0, 'launcher lists ' . a:text)
endfunction

function! Test_launcher() abort
  let root = tempname() . '/Mail'
  call testmail#ingest(root, 'inbox', 'plain')
  call testmail#ingest(root, 'archive', 'html')
  call mkdir(root . '/sent', 'p')
  let g:mail_root = root

  " :Mail (no arg) -> the launcher, read-only, listing the mailboxes
  Mail
  call assert_equal('mail://[mailboxes]', bufname('%'), ':Mail opens the launcher')
  call assert_false(&modifiable, 'launcher is read-only (edits not allowed)')
  call s:goto_line('inbox')
  call s:goto_line('sent')
  call s:goto_line('archive')

  " <CR> on 'archive' enters that mailbox's own buffer
  call s:goto_line('archive')
  execute "normal \<CR>"
  call assert_equal('mail://archive', bufname('%'), '<CR> enters the mailbox')

  " `-` returns to the launcher
  execute 'normal -'
  call assert_equal('mail://[mailboxes]', bufname('%'), '- returns to the launcher')

  " :Mail <box> still opens a mailbox directly (skips the launcher)
  Mail inbox
  call assert_equal('mail://inbox', bufname('%'), ':Mail <box> opens it directly')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" A fresh :Mail creates the default folders (inbox/sent/archive) so the launcher
" isn't empty; TRASH stays virtual (never a real dir) but is listed.
function! Test_default_mailboxes() abort
  let root = tempname() . '/Mail'
  let g:mail_root = root
  Mail
  for name in ['inbox', 'sent', 'archive']
    call assert_true(isdirectory(root . '/' . name), name . ' created on :Mail')
  endfor
  call assert_false(isdirectory(root . '/TRASH'), 'TRASH is virtual, not a real dir')
  let lines = getline(1, '$')
  for name in ['inbox', 'sent', 'archive', 'TRASH']
    call assert_notequal(-1, index(lines, name), 'launcher lists ' . name)
  endfor
  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = ['Test_launcher', 'Test_default_mailboxes']
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
