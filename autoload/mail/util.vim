" Small shared helpers.
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

" Base 'python3 /path/to/mail_store.py' command (g:mail_store_cmd minus the
" trailing ' ingest-stdin' that the fetchmail MDA needs).
function! mail#util#py_cmd() abort
  return substitute(g:mail_store_cmd, '\s\+ingest-stdin$', '', '')
endfunction
