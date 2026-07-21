" Small shared helpers.
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

" Base 'python3 /path/to/mail_store.py' command (g:mail_store_cmd minus its
" trailing ' ingest-stdin' — that suffix is the ingest-MDA form the getmailrc
" uses; py_cmd strips it for the send/quote/viewhtml subcommands).
function! mail#util#py_cmd() abort
  return substitute(g:mail_store_cmd, '\s\+ingest-stdin$', '', '')
endfunction

" vifm-style top path bar, rendered into the tabline (a global option, so it's
" wired app-side in muaa-init.vim rather than an ftplugin — enabling it in a
" normal Vim would clobber the user's own tabline). `%!mail#util#tabline()`
" gets called for the active window's buffer, so &filetype / b: vars are its.
function! mail#util#tabline() abort
  let root = fnamemodify(mail#mailbox#root(), ':~')
  let ft   = &filetype
  if ft ==# 'mail-index'
    let where = root . '/' . fnamemodify(get(b:, 'mail_dir', ''), ':t')
  elseif ft ==# 'mail-mailboxes'
    let where = root
  elseif ft ==# 'mail-trash'
    let where = root . '/TRASH'
  elseif ft ==# 'mail-view'
    let where = root . '  ›  reading'
  elseif ft ==# 'mail-compose'
    let sub   = get(b:, 'mail_compose_subject', '')
    let where = 'compose' . (sub ==# '' ? '' : '  ›  ' . sub)
  else
    let where = root
  endif
  return '%#TabLineSel# ✉ ' . where . ' %#TabLineFill#%T'
endfunction
