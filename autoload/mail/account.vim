" Multi-account model. Opt-in: define g:mail_accounts to enable it; leave it
" unset and vim-mail stays single-account (g:mail_root / g:mail_from), unchanged.
"
"   let g:mail_accounts = {
"     \ 'gmail':   {'root': '~/Mail/gmail',   'from': 'Me <me@gmail.com>'},
"     \ 'outlook': {'root': '~/Mail/outlook', 'from': 'Me <me@outlook.com>'},
"     \ }
"   let g:mail_account = 'gmail'       " optional: which one is active at startup
"
" Each account has its OWN store root (its own .store, symlink labels, link map).
" Switching accounts just repoints the active root/identity; all operations stay
" within one account (cross-account move/merge is a later 'ALL' feature).
"
" Per account, optional 'send' = the sendmail-compatible transport command for
" that identity (default 'sendmail -t'), e.g. 'msmtp -a gmail -t' — see
" scripts/oauth_token.py and mail-setup.md.
"
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

let s:current = ''

function! mail#account#_accounts() abort
  return get(g:, 'mail_accounts', {})
endfunction

" True when multi-account mode is configured.
function! mail#account#is_multi() abort
  return !empty(mail#account#_accounts())
endfunction

" Account names, sorted.
function! mail#account#names() abort
  return sort(keys(mail#account#_accounts()))
endfunction

" Apply <name> as the active account: repoint g:mail_from (and g:mail_root, so
" every g:mail_root reader picks it up). Returns 1 on success, 0 if unknown.
function! mail#account#apply(name) abort
  let accts = mail#account#_accounts()
  if !has_key(accts, a:name)
    return 0
  endif
  let s:current = a:name
  let acct = accts[a:name]
  if has_key(acct, 'root') | let g:mail_root = acct.root | endif
  if has_key(acct, 'from') | let g:mail_from = acct.from | endif
  return 1
endfunction

" The active account name (applies the default the first time). '' single-account.
function! mail#account#current() abort
  let accts = mail#account#_accounts()
  if empty(accts)
    return ''
  endif
  if s:current ==# '' || !has_key(accts, s:current)
    call mail#account#apply(get(g:, 'mail_account', mail#account#names()[0]))
  endif
  return s:current
endfunction

" Store root of the active (or named) account, '' if none.
function! mail#account#root(...) abort
  let name = a:0 ? a:1 : mail#account#current()
  let accts = mail#account#_accounts()
  return has_key(accts, name) ? get(accts[name], 'root', '') : ''
endfunction

" Sendmail-compatible transport command for the active (or named) account.
function! mail#account#send_cmd(...) abort
  let name = a:0 ? a:1 : mail#account#current()
  let accts = mail#account#_accounts()
  return has_key(accts, name) ? get(accts[name], 'send', 'sendmail -t') : 'sendmail -t'
endfunction

" :MailAccount <name> — switch the active account and reopen the launcher.
function! mail#account#switch(name) abort
  if !mail#account#apply(a:name)
    echohl ErrorMsg | echom 'mail: no such account: ' . a:name | echohl None
    return
  endif
  call mail#link#rebuild()
  call mail#mailboxlist#open()
  echo 'account: ' . a:name
endfunction

function! mail#account#_complete(arglead, cmdline, cursorpos) abort
  return filter(mail#account#names(), 'v:val =~# "^" . a:arglead')
endfunction
