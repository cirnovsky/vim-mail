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

" Names are drawn inside an ASCII mailbox/trash-bin block now, so match the name
" within its box line (the name row maps to that mailbox in b:mailbox_lines).
function! s:goto_line(text) abort
  call cursor(1, 1)
  let ln = search('\V' . a:text, 'cW')
  call assert_true(ln > 0, 'launcher shows ' . a:text)
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
  let shown = map(copy(b:mailbox_cells), 'v:val.name')
  for name in ['inbox', 'sent', 'archive', 'TRASH']
    call assert_notequal(-1, index(shown, name), 'launcher shows ' . name)
  endfor
  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" Normalize a rendered launcher for a golden compare: drop leading/trailing blank
" lines and strip the common leading indent, so the fixture is independent of the
" window size (render() centers itself via winwidth/winheight).
function! s:normalize(lines) abort
  let ls = copy(a:lines)
  while !empty(ls) && ls[0] =~# '^\s*$' | call remove(ls, 0) | endwhile
  while !empty(ls) && ls[-1] =~# '^\s*$' | call remove(ls, -1) | endwhile
  let m = 999
  for l in ls
    if l =~# '\S' | let m = min([m, strlen(matchstr(l, '^ *'))]) | endif
  endfor
  return map(ls, 'v:val[m :]')
endfunction

" Four user boxes (inbox/sent/archive/history) + TRASH: the rendered launcher
" scene matches the golden tests/fixtures/launcher.txt.
function! Test_launcher_render() abort
  let root = tempname() . '/Mail'
  call testmail#ingest(root, 'inbox', 'plain')
  for d in ['sent', 'archive', 'history'] | call mkdir(root . '/' . d, 'p') | endfor
  let g:mail_root = root
  Mail
  let got  = s:normalize(getline(1, '$'))
  let want = s:normalize(readfile(s:repo . '/tests/fixtures/launcher.txt'))
  call assert_equal(want, got, 'launcher render matches tests/fixtures/launcher.txt')
  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = ['Test_launcher', 'Test_default_mailboxes', 'Test_launcher_render']
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
