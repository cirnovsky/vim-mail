" Mailbox path resolution, completion, and prompting.
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

function! mail#mailbox#_normdir(dir) abort
  let dir = fnamemodify(expand(a:dir), ':p')
  if dir =~# '/$'
    let dir = dir[:-2]
  endif
  return dir
endfunction

" Resolve a user-supplied mailbox string to a full path.
" Bare names (no leading / or ~) are joined under g:mail_root.
function! mail#mailbox#_resolve_mailbox(name) abort
  let root = mail#mailbox#_normdir(get(g:, 'mail_root', '~/Mail'))
  let raw  = a:name =~# '^[/~]' ? a:name : root . '/' . a:name
  return mail#mailbox#_normdir(raw)
endfunction

function! mail#mailbox#_complete_mailbox(arglead, cmdline, cursorpos) abort
  let root = mail#mailbox#_normdir(get(g:, 'mail_root', '~/Mail'))
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
