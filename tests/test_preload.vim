" :Mail preloads a live index buffer for EVERY mailbox at startup, so each is
" ready for staged fetch / cross-mailbox :w / dd+p paste without navigating there
" first. The launcher is still what's displayed; the rest sit loaded + hidden.
"
" Run:  vim -u NONE -N -es -S tests/test_preload.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on

function! Test_mail_preloads_all_mailboxes() abort
  let root = tempname() . '/Mail'
  call testmail#ingest(root, 'inbox', 'plain')
  call testmail#ingest(root, 'archive', 'html')
  call mkdir(root . '/sent', 'p')                    " empty mailbox, still preloaded
  let g:mail_root = root

  " :Mail (launcher) warms every mailbox buffer
  call mail#mailboxlist#mail_cmd('')

  let loaded = {}
  for nr in mail#index#_index_buffers()
    let loaded[getbufvar(nr, 'mail_dir', '')] = nr
  endfor
  for name in ['inbox', 'archive', 'sent']
    let dir = mail#mailbox#_resolve_mailbox(name)
    call assert_true(has_key(loaded, dir), name . ' buffer preloaded + registered')
  endfor

  " a non-empty mailbox is actually rendered (baseline populated), not just created
  call assert_false(empty(getbufvar(loaded[mail#mailbox#_resolve_mailbox('inbox')],
        \ 'mail_entries', [])), 'inbox baseline rendered')

  " and the launcher is what's displayed after the preload
  call assert_equal('mail://[mailboxes]', bufname('%'), 'launcher shown after preload')

  " a second :Mail is idempotent — no new buffers for already-loaded mailboxes
  let n1 = len(mail#index#_index_buffers())
  call mail#mailboxlist#mail_cmd('')
  call assert_equal(n1, len(mail#index#_index_buffers()), 'repeat :Mail adds no buffers')

  call testmail#wipe_buffers()
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = ['Test_mail_preloads_all_mailboxes']
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
