" The mailbox launcher: a read-only, netrw-style index of all mailboxes under
" g:mail_root. `:Mail` (no arg) opens it; <CR> enters a mailbox; `-` in a mailbox
" returns here. Edits are NOT allowed — deleting/renaming a whole mailbox is too
" destructive to leave to a stray `dd`. Each mailbox still opens in its own
" persistent buffer (a launcher, not a single reused netrw buffer), so staged
" edits and cross-mailbox dd+p moves survive navigation.
"
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

let s:list_bufnr = -1
let s:list_name  = 'mail://[mailboxes]'

" Mailbox basenames under <root> (dirs, skipping the hidden .store), with inbox
" and sent floated to the top, the rest alphabetical.
function! mail#mailboxlist#_mailboxes_in(root) abort
  let names = []
  for path in glob(a:root . '/*', 0, 1)
    if isdirectory(path) && fnamemodify(path, ':t') !~# '^\.'
      call add(names, fnamemodify(path, ':t'))
    endif
  endfor
  call sort(names)
  let front = filter(['inbox', 'sent'], 'index(names, v:val) >= 0')
  let rest  = filter(copy(names), 'index(front, v:val) < 0')
  return front + rest
endfunction

" Mailboxes of the active account (or the single root).
function! mail#mailboxlist#_mailboxes() abort
  return mail#mailboxlist#_mailboxes_in(mail#mailbox#root())
endfunction

function! mail#mailboxlist#open() abort
  if s:list_bufnr > 0 && bufexists(s:list_bufnr) && bufname(s:list_bufnr) ==# s:list_name
    let winid = bufwinid(s:list_bufnr)
    if winid != -1
      call win_gotoid(winid)
    else
      execute 'buffer ' . s:list_bufnr
    endif
  else
    noautocmd enew
    setlocal buftype=nofile bufhidden=hide noswapfile nowrap nobuflisted
    silent! noautocmd execute 'file ' . fnameescape(s:list_name)
    let s:list_bufnr = bufnr('%')
  endif
  setlocal filetype=mail-mailboxes
  call mail#mailboxlist#render()
endfunction

" Render the list. Single-account: a flat mailbox list (one name per line).
" Multi-account: a tree — each account name at column 0 (a fold header) with its
" mailboxes indented under it; foldmethod=indent (set in the ftplugin) makes them
" native folds (zo/zc/za). b:mail_launcher runs parallel to the lines so <CR>
" resolves a line to {kind, account, mailbox} without reparsing text.
function! mail#mailboxlist#render() abort
  let lines  = []
  let ranges = []          " [start, end] line ranges to fold (one per account)
  let b:mail_launcher = []
  if mail#account#is_multi()
    for acct in mail#account#names()
      call add(lines, acct)
      call add(b:mail_launcher, {'kind': 'account', 'account': acct})
      let start = len(lines)                 " account header line (1-based)
      for mbox in mail#mailboxlist#_mailboxes_in(mail#mailbox#_normdir(mail#account#root(acct)))
        call add(lines, '  ' . mbox)
        call add(b:mail_launcher, {'kind': 'mailbox', 'account': acct, 'mailbox': mbox})
      endfor
      if len(lines) > start                  " header + at least one mailbox
        call add(ranges, [start, len(lines)])
      endif
    endfor
  else
    for name in mail#mailboxlist#_mailboxes()
      call add(lines, name)
      call add(b:mail_launcher, {'kind': 'mailbox', 'account': '', 'mailbox': name})
    endfor
  endif
  setlocal modifiable
  silent! normal! zE                         " drop stale folds before re-rendering
  silent! 1,$delete _
  if !empty(lines)
    call setline(1, lines)
  endif
  " Manual fold per account, header line first -> closed fold shows just the
  " account name; za / zo / zc / <CR> expand it. (Creating a fold also closes it.)
  for [s, e] in ranges
    execute s . ',' . e . 'fold'
  endfor
  setlocal nomodifiable nomodified
endfunction

" <CR>: on a mailbox line, switch to its account (if any) and open it; on an
" account header, toggle its fold.
function! mail#mailboxlist#enter() abort
  let entry = get(get(b:, 'mail_launcher', []), line('.') - 1, {})
  if empty(entry) | return | endif
  if entry.kind ==# 'account'
    normal! za
    return
  endif
  if entry.account !=# ''
    call mail#account#apply(entry.account)
    call mail#link#rebuild()
  endif
  call mail#index#open(entry.mailbox)
endfunction

" `:Mail` dispatch: no arg -> the launcher; a name -> that mailbox directly.
function! mail#mailboxlist#mail_cmd(name) abort
  if a:name ==# ''
    call mail#mailboxlist#open()
  else
    call mail#index#open(a:name)
  endif
endfunction
