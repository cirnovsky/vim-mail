" Index buffer open invariants.
"
" Regression guard for the ':Mail -> "[New DIRECTORY]" -> Not a mail index buffer'
" crash: the index buffer name must NOT embed the absolute mailbox path. The old
" name 'mail://' . dir was 'mail:///Users/…/inbox', which Vim parses as a URL
" whose path is a real directory, so netrw/Vim hijacks the buffer and b:mail_dir
" is gone before refresh runs. Also: a stale index_bufnrs entry (buffer wiped by
" `q`) must not be reused.
"
" Run: vim -u NONE -N -es -S tests/test_index.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime! autoload/mail/*.vim

function! s:mkmsg(dir) abort
  call mkdir(a:dir, 'p')
  call writefile([
        \ 'From: A <a@example.com>',
        \ 'Subject: s',
        \ 'Date: Tue, 23 Jun 2026 08:00:00 -0700',
        \ 'Message-ID: <' . fnamemodify(a:dir, ':t') . '@example.com>',
        \ ], a:dir . '/meta')
  call writefile(['raw'], a:dir . '/raw.eml')
endfunction

" The buffer name must not contain the absolute mailbox path, and must not itself
" be a real directory — either makes Vim/netrw treat it as a directory.
function! Test_index_name_is_not_a_path() abort
  let root = tempname() . '/Mail'
  call s:mkmsg(root . '/inbox/20260101T000000Z_aaaaaaaa')
  let g:mail_root = root

  call mail#index#open('inbox')
  call assert_true(exists('b:mail_dir'), 'b:mail_dir set after open')
  call assert_equal('mail-index', &filetype, 'filetype is mail-index')
  call assert_true(stridx(bufname('%'), root) < 0,
        \ 'index buffer name must not embed the absolute mailbox path: ' . bufname('%'))
  call assert_equal(0, isdirectory(bufname('%')), 'name is not a real directory')

  bwipeout!
  call delete(root, 'rf')
endfunction

" A stale index_bufnrs entry (buffer wiped by `q`) must not be reused; reopen
" must rebuild a real index buffer.
function! Test_index_reopen_after_wipe() abort
  let root = tempname() . '/Mail'
  call s:mkmsg(root . '/inbox/20260101T000000Z_aaaaaaaa')
  let g:mail_root = root

  call mail#index#open('inbox')
  bwipeout!                         " like the `q` keymap
  enew                              " consume a buffer
  call mail#index#open('inbox')
  call assert_true(exists('b:mail_dir'), 'reopen after wipe sets b:mail_dir')
  call assert_equal('mail-index', &filetype, 'reopen has index filetype')

  bwipeout!
  call delete(root, 'rf')
endfunction

let v:errors = []
for s:t in ['Test_index_name_is_not_a_path', 'Test_index_reopen_after_wipe']
  try
    call call(s:t, [])
  catch
    call add(v:errors, s:t . ': ' . v:exception . ' @ ' . v:throwpoint)
  endtry
endfor
if empty(v:errors)
  qall!
else
  for s:e in v:errors | echom s:e | endfor
  cquit!
endif
