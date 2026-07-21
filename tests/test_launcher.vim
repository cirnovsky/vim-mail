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

" Headless -es pins winwidth to 80; force a wide layout so the boxed menu (the
" primary tier) renders. The narrow-fallback tests override this.
let g:mail_launcher_width = 200

" Box rows capitalize the name (inbox -> Inbox), so match it case-insensitively.
function! s:goto_line(text) abort
  call cursor(1, 1)
  let ln = search('\c\V' . a:text, 'cW')
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

" When the window is too narrow even for the boxed menu, fall back to the plain
" one-per-line list, and hjkl/<CR> still navigate it.
function! Test_launcher_fallback() abort
  let root = tempname() . '/Mail'
  call testmail#ingest(root, 'inbox', 'plain')
  for d in ['sent', 'archive'] | call mkdir(root . '/' . d, 'p') | endfor
  let g:mail_root = root
  let g:mail_launcher_width = 20             " too narrow even for the 32-wide box
  Mail
  call assert_equal(['inbox', 'sent', 'archive', 'TRASH'], getline(1, '$'),
        \ 'very narrow window falls back to a plain mailbox list')
  " j (jump) moves down a mailbox; <CR> opens the one under the cursor
  call cursor(1, 1)
  call mail#mailboxlist#jump(1)
  call assert_equal('sent', getline('.'), 'jump lands on the next mailbox line')
  call mail#mailboxlist#enter()
  call assert_equal('mail://sent', bufname('%'), '<CR> opens the mailbox in list mode')
  let g:mail_launcher_width = 200             " restore for the remaining tests
  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

function! s:build(root, extra) abort
  call testmail#ingest(a:root, 'inbox', 'plain')
  for d in a:extra | call mkdir(a:root . '/' . d, 'p') | endfor
  let g:mail_root = a:root
endfunction

" (1) A window too narrow for the scene but wide enough for the box falls back to
" the boxed menu (first tier), not the scene and not the plain list.
function! Test_launcher_box_fallback() abort
  let root = tempname() . '/Mail'
  call s:build(root, ['sent', 'archive', 'history'])
  let g:mail_launcher_width = 50              " < scene (~87), >= box (32)
  Mail
  let lines = getline(1, '$')
  call assert_true(!empty(filter(copy(lines), 'v:val =~# "╔"')), 'boxed menu top border')
  call assert_true(!empty(filter(copy(lines), 'v:val =~# "▸  Inbox"')), 'boxed mailbox row')
  call assert_true(empty(filter(copy(lines), 'v:val =~# "_||____"')), 'not the ASCII scene')
  let g:mail_launcher_width = 200
  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" (2) The boxed menu renders exactly as tests/fixtures/launcher-2.txt.
function! Test_launcher_box_render() abort
  let root = tempname() . '/Mail'
  call s:build(root, ['sent', 'archive', 'history'])
  let g:mail_launcher_width = 50
  Mail
  let got  = s:normalize(getline(1, '$'))
  let want = s:normalize(readfile(s:repo . '/tests/fixtures/launcher-2.txt'))
  call assert_equal(want, got, 'boxed menu matches tests/fixtures/launcher-2.txt')
  let g:mail_launcher_width = 200
  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" (3) The box adapts to the number of mailboxes: one ▸ row (and one cell) per
" mailbox, box width unchanged.
function! Test_launcher_box_adaptive() abort
  let root = tempname() . '/Mail'
  call s:build(root, ['sent', 'archive', 'history', 'work', 'clients'])
  let g:mail_launcher_width = 50
  Mail
  " inbox/sent/archive/history/work/clients + TRASH = 7
  let brows = filter(getline(1, '$'), 'v:val =~# "║.*▸"')
  call assert_equal(7, len(brows), 'one boxed row per mailbox')
  call assert_equal(7, len(b:mailbox_cells), 'one navigable cell per mailbox')
  let border = trim(filter(copy(getline(1, '$')), 'v:val =~# "╔"')[0])
  call assert_equal(32, strchars(border), 'box width fixed regardless of count')
  let g:mail_launcher_width = 200
  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" (4) R re-renders for the CURRENT width: wide enough -> boxed menu, narrower ->
" plain list.
function! Test_launcher_refresh() abort
  let root = tempname() . '/Mail'
  call s:build(root, ['sent', 'archive', 'history'])
  let g:mail_launcher_width = 50
  Mail
  call assert_true(!empty(filter(copy(getline(1, '$')), 'v:val =~# "╔"')), 'wide enough -> box')
  let g:mail_launcher_width = 20
  call mail#mailboxlist#render()              " R
  call assert_equal(['inbox', 'sent', 'archive', 'history', 'TRASH'], getline(1, '$'),
        \ 'narrower + R -> plain list')
  let g:mail_launcher_width = 200
  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = ['Test_launcher', 'Test_default_mailboxes',
      \ 'Test_launcher_fallback', 'Test_launcher_box_fallback', 'Test_launcher_box_render',
      \ 'Test_launcher_box_adaptive', 'Test_launcher_refresh']
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
