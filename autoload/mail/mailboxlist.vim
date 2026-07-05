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

" Mailbox basenames under g:mail_root (dirs, skipping the hidden .store), with
" inbox and sent floated to the top, the rest alphabetical.
function! mail#mailboxlist#_mailboxes() abort
  let root = mail#mailbox#root()
  let names = []
  for path in glob(root . '/*', 0, 1)
    if isdirectory(path) && fnamemodify(path, ':t') !~# '^\.'
      call add(names, fnamemodify(path, ':t'))
    endif
  endfor
  call sort(names)
  let front = filter(['inbox', 'sent'], 'index(names, v:val) >= 0')
  let rest  = filter(copy(names), 'index(front, v:val) < 0')
  return front + rest
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

function! mail#mailboxlist#render() abort
  " TRASH is a virtual read-only view (mail#trash), not a real dir — appended
  " here, never in _mailboxes() (so preload/completion never treat it as one).
  let names = mail#mailboxlist#_mailboxes() + ['TRASH']
  setlocal modifiable
  silent! 1,$delete _
  if !empty(names)
    call setline(1, names)
  endif
  setlocal nomodifiable nomodified
endfunction

" <CR>: open the mailbox named on the current line in its own index buffer.
function! mail#mailboxlist#enter() abort
  let name = trim(getline('.'))
  if name ==# '' | return | endif
  if name ==# 'TRASH'
    call mail#trash#open()
  else
    call mail#index#open(name)
  endif
endfunction

" `:Mail` dispatch: no arg -> the launcher; a name -> that mailbox directly.
function! mail#mailboxlist#mail_cmd(name) abort
  call mail#mailbox#ensure_defaults()    " inbox/sent/archive exist on first :Mail
  if a:name ==# 'TRASH'
    call mail#trash#open()
    return
  endif
  call mail#index#preload_all()          " every mailbox buffer live from startup
  if a:name ==# ''
    call mail#mailboxlist#open()
  else
    call mail#index#open(a:name)
  endif
endfunction
