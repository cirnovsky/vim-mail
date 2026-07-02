" Multi-account mode (g:mail_accounts). Each account is its own store root; the
" launcher shows accounts as manual folds (dropdowns) with their mailboxes
" inside; <CR> on a mailbox switches account + opens it; buffers are qualified
" (mail://<account>/<mailbox>); and :w stays scoped to one account's store.
"
" Run:  vim -u NONE -N -es -S tests/test_account.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on

" line (1-based) of the launcher entry matching kind/account/mailbox, or -1
function! s:findline(kind, acct, mbox) abort
  let i = 0
  for e in get(b:, 'mail_launcher', [])
    let i += 1
    if e.kind ==# a:kind && get(e, 'account', '') ==# a:acct
          \ && get(e, 'mailbox', '') ==# a:mbox
      return i
    endif
  endfor
  return -1
endfunction

function! Test_account_model() abort
  let root_g = tempname() . '/gmail'
  let root_o = tempname() . '/outlook'
  call testmail#ingest(root_g, 'inbox', 'plain')
  call testmail#ingest(root_o, 'inbox', 'plain')
  let g:mail_accounts = {
        \ 'gmail':   {'root': root_g, 'from': 'G <g@x.com>'},
        \ 'outlook': {'root': root_o, 'from': 'O <o@x.com>'},
        \ }

  call assert_true(mail#account#is_multi(), 'multi-account mode active')
  call assert_equal(['gmail', 'outlook'], mail#account#names(), 'names sorted')

  call assert_equal(1, mail#account#apply('gmail'), 'apply gmail')
  call assert_equal(mail#mailbox#_normdir(root_g), mail#mailbox#root(), 'root -> gmail')
  call assert_equal('G <g@x.com>', g:mail_from, 'from -> gmail')

  call assert_equal(1, mail#account#apply('outlook'), 'apply outlook')
  call assert_equal(mail#mailbox#_normdir(root_o), mail#mailbox#root(), 'root -> outlook')
  call assert_equal('O <o@x.com>', g:mail_from, 'from -> outlook')

  call assert_equal(0, mail#account#apply('nope'), 'unknown account rejected')

  unlet g:mail_accounts
  call delete(root_g, 'rf') | call delete(root_o, 'rf')
endfunction

function! Test_launcher_tree_and_enter() abort
  let root_g = tempname() . '/gmail'
  let root_o = tempname() . '/outlook'
  let g_in = testmail#ingest(root_g, 'inbox', 'plain')
  call testmail#ingest(root_g, 'archive', 'html')
  let o_in = testmail#ingest(root_o, 'inbox', 'plain')
  call mkdir(root_o . '/sent', 'p')
  let g:mail_accounts = {
        \ 'gmail':   {'root': root_g, 'from': 'G <g@x.com>'},
        \ 'outlook': {'root': root_o, 'from': 'O <o@x.com>'},
        \ }

  " :Mail -> the launcher tree: both accounts + their mailboxes
  Mail
  call assert_equal('mail://[mailboxes]', bufname('%'), ':Mail opens the launcher')
  call assert_true(s:findline('account', 'gmail', '')   > 0, 'lists gmail')
  call assert_true(s:findline('account', 'outlook', '') > 0, 'lists outlook')
  call assert_true(s:findline('mailbox', 'gmail', 'inbox')   > 0, 'gmail/inbox listed')
  call assert_true(s:findline('mailbox', 'gmail', 'archive') > 0, 'gmail/archive listed')
  call assert_true(s:findline('mailbox', 'outlook', 'inbox') > 0, 'outlook/inbox listed')
  " gmail's archive must NOT show under outlook (per-account mailbox sets)
  call assert_equal(-1, s:findline('mailbox', 'outlook', 'archive'), 'no cross-account leak')

  " accounts start folded (dropdowns) — the mailbox line hides inside a closed fold
  call assert_true(foldclosed(s:findline('mailbox', 'gmail', 'inbox')) > 0,
        \ 'account folds start closed')

  " <CR> on the gmail header opens its fold, then <CR> on inbox enters it
  call cursor(s:findline('account', 'gmail', ''), 1)
  execute "normal \<CR>"
  call assert_equal(-1, foldclosed(s:findline('mailbox', 'gmail', 'inbox')),
        \ '<CR> on account header expands the fold')
  call cursor(s:findline('mailbox', 'gmail', 'inbox'), 1)
  execute "normal \<CR>"
  call assert_equal('mail://gmail/inbox', bufname('%'), 'buffer name is account-qualified')
  call assert_equal('gmail', mail#account#current(), 'active account switched to gmail')
  call assert_true(testmail#has_entry(g_in), 'gmail inbox shows its message')

  " enter outlook/inbox -> a DISTINCT buffer (same mailbox basename, no collision)
  Mail
  call cursor(s:findline('account', 'outlook', ''), 1)
  execute "normal \<CR>"
  call cursor(s:findline('mailbox', 'outlook', 'inbox'), 1)
  execute "normal \<CR>"
  call assert_equal('mail://outlook/inbox', bufname('%'), 'outlook inbox is its own buffer')
  call assert_equal('outlook', mail#account#current(), 'active account switched to outlook')
  call assert_true(testmail#has_entry(o_in), 'outlook inbox shows its message')

  unlet g:mail_accounts
  call testmail#wipe_buffers()
  call delete(root_g, 'rf') | call delete(root_o, 'rf')
endfunction

function! Test_write_is_per_account() abort
  let root_g = tempname() . '/gmail'
  let root_o = tempname() . '/outlook'
  let g_in = testmail#ingest(root_g, 'inbox', 'plain')
  let o_in = testmail#ingest(root_o, 'inbox', 'plain')
  let g:mail_accounts = {
        \ 'gmail':   {'root': root_g, 'from': 'G <g@x.com>'},
        \ 'outlook': {'root': root_o, 'from': 'O <o@x.com>'},
        \ }

  " delete the outlook message and commit; gmail's store must be untouched
  call mail#account#apply('outlook')
  call mail#link#rebuild()
  call mail#index#open('inbox')
  call testmail#goto(o_in) | normal! dd
  silent write

  call assert_equal('', testmail#ftype(root_o . '/inbox/' . o_in), 'outlook msg unlinked')
  call assert_equal('link', testmail#ftype(root_o . '/trash/' . o_in), 'outlook msg -> outlook trash')
  call assert_true(isdirectory(root_g . '/.store/' . g_in), 'gmail canon intact')
  call assert_equal('link', testmail#ftype(root_g . '/inbox/' . g_in), 'gmail inbox untouched')
  call assert_false(isdirectory(root_g . '/trash'), 'gmail got no trash from an outlook delete')

  unlet g:mail_accounts
  call testmail#wipe_buffers()
  call delete(root_g, 'rf') | call delete(root_o, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = ['Test_account_model', 'Test_launcher_tree_and_enter', 'Test_write_is_per_account']
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
