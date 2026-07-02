" Mailbox path resolution, completion, and prompting.
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

" Fallback mail store when the user hasn't set g:mail_root. Single source of
" truth — every module resolves the root through mail#mailbox#root(), never a
" bare literal.
let s:DEFAULT_ROOT = '~/Mail'

function! mail#mailbox#_normdir(dir) abort
  let dir = fnamemodify(expand(a:dir), ':p')
  if dir =~# '/$'
    let dir = dir[:-2]
  endif
  return dir
endfunction

" The resolved, normalised mail-store root. In multi-account mode (g:mail_accounts
" set) it's the active account's root; otherwise g:mail_root, else the default.
function! mail#mailbox#root() abort
  if mail#account#is_multi()
    let r = mail#account#root()
    if r !=# '' | return mail#mailbox#_normdir(r) | endif
  endif
  return mail#mailbox#_normdir(get(g:, 'mail_root', s:DEFAULT_ROOT))
endfunction

" Resolve a user-supplied mailbox string to a full path.
" Bare names (no leading / or ~) are joined under g:mail_root.
function! mail#mailbox#_resolve_mailbox(name) abort
  let root = mail#mailbox#root()
  let raw  = a:name =~# '^[/~]' ? a:name : root . '/' . a:name
  return mail#mailbox#_normdir(raw)
endfunction

function! mail#mailbox#_complete_mailbox(arglead, cmdline, cursorpos) abort
  let root = mail#mailbox#root()
  let names = map(filter(glob(root . '/*', 0, 1), 'isdirectory(v:val)'),
        \ 'fnamemodify(v:val, ":t")')
  return filter(names, 'v:val =~# "^" . a:arglead')
endfunction

function! mail#mailbox#_complete_mailbox_str(arglead, cmdline, cursorpos) abort
  return join(mail#mailbox#_complete_mailbox(a:arglead, a:cmdline, a:cursorpos), "\n")
endfunction

" Prompt for a mailbox name with Tab completion. Returns '' on cancel.
" a:prompt   — prompt text (no trailing space needed)
" a:default  — pre-filled text ('' for none)
function! mail#mailbox#_prompt_mailbox(prompt, default) abort
  let result = input(a:prompt . ': ', a:default, 'custom,mail#mailbox#_complete_mailbox_str')
  redraw
  return result
endfunction
