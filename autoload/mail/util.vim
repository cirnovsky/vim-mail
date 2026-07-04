" Small shared helpers.
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

" Base 'python3 /path/to/mail_store.py' command (g:mail_store_cmd minus its
" trailing ' ingest-stdin' — that suffix is the ingest-MDA form the getmailrc
" uses; py_cmd strips it for the send/quote/viewhtml subcommands).
function! mail#util#py_cmd() abort
  return substitute(g:mail_store_cmd, '\s\+ingest-stdin$', '', '')
endfunction
