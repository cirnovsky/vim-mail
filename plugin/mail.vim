if exists('g:loaded_mail_plugin')
  finish
endif
let g:loaded_mail_plugin = 1

command! -nargs=? -complete=customlist,mail#mailbox#_complete_mailbox Mail call mail#index#open(<q-args>)

" g:mail_from: Full From header, e.g. 'Your Name <you@gmail.com>'. Set in vimrc.
let g:mail_from = get(g:, 'mail_from', '')

" Locate this plugin's own root (plugin/ -> repo root) so mail_store.py is found
" wherever the repo was cloned, with no hardcoded path.
let s:plugin_root = expand('<sfile>:p:h:h')

" g:mail_python:   python3 interpreter (resolved from PATH; override in vimrc).
" g:mail_store_py: path to mail_store.py (defaults to the copy in this repo).
let g:mail_python = get(g:, 'mail_python',
      \ exepath('python3') !=# '' ? exepath('python3') : 'python3')
let g:mail_store_py = get(g:, 'mail_store_py', s:plugin_root . '/mail_store.py')

" g:mail_store_cmd: base command used to build the --mda arg for fetchmail.
" Derived from the two above; override directly if you need something custom.
let g:mail_store_cmd = get(g:, 'mail_store_cmd',
      \ g:mail_python . ' ' . g:mail_store_py . ' ingest-stdin')
