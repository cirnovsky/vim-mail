" Actionable placeholders in the message view: gx opens the URL/attachment under
" the cursor; gd/gD jump between an inline placeholder and its footer entry.
" Reads the existing body.txt markers (no stored-format change). Resolution is
" section-relative (an inline [N] binds to the nearest matching footer below it).
"
" Run:  vim -u NONE -N -es -S tests/test_markers.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on

" --- html mail: inline [1] and the Links: footer resolve to the URL ---
function! Test_link_marker() abort
  let root = tempname() . '/Mail'
  call testmail#ingest(root, 'inbox', 'html')
  let g:mail_root = root
  call mail#index#open('inbox')
  call cursor(1, 1)
  call mail#view#open_message()
  call assert_match('^\[Mail\]', bufname('%'), 'full view opened')
  call assert_equal('mail-view', &filetype, 'view buffer is mail-view')

  " footer entry '[1] https://example.com' resolves as a url
  let fl = search('^\[1\] https', 'cnw')
  call assert_true(fl > 0, 'Links footer present')
  call assert_equal('https://example.com', get(mail#view#_resolve_at(fl, 1), 'target', ''), 'footer url')

  " inline placeholder [1] resolves to the same url
  let il = search('link \[1\]', 'cnw')
  call assert_true(il > 0, 'inline placeholder present')
  let col = match(getline(il), '\[1\]') + 2
  call assert_equal('https://example.com', get(mail#view#_resolve_at(il, col), 'target', ''), 'inline resolves')

  " gd inline -> footer, gD footer -> back to placeholder
  call cursor(il, col)
  call mail#view#jump_to_footer()
  call assert_equal(fl, line('.'), 'gd jumps to footer')
  call mail#view#jump_to_inline()
  call assert_equal(il, line('.'), 'gD jumps back to placeholder')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- attachment mail: Attachments: footer resolves to the file on disk ---
function! Test_attachment_marker() abort
  let root = tempname() . '/Mail'
  call testmail#ingest(root, 'inbox', 'attachment')
  let g:mail_root = root
  call mail#index#open('inbox')
  call cursor(1, 1)
  call mail#view#open_message()

  let fl = search('^\[1\] note.txt', 'cnw')
  call assert_true(fl > 0, 'Attachments footer present')
  let t = mail#view#_resolve_at(fl, 1)
  call assert_equal('file', get(t, 'type', ''), 'footer resolves as file')
  call assert_match('/attachments/note\.txt$', get(t, 'target', ''), 'file path')
  call assert_true(filereadable(t.target), 'resolved attachment exists on disk')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- plain body with no markers: cursor resolves to nothing (no false hits) ---
function! Test_no_marker() abort
  let root = tempname() . '/Mail'
  call testmail#ingest(root, 'inbox', 'plain')
  let g:mail_root = root
  call mail#index#open('inbox')
  call cursor(1, 1)
  call mail#view#open_message()
  call assert_equal({}, mail#view#_resolve_at(line('$'), 1), 'no marker -> {}')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = ['Test_link_marker', 'Test_attachment_marker', 'Test_no_marker']
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
