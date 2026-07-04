if exists('g:loaded_mail_plugin')
  finish
endif
let g:loaded_mail_plugin = 1

" :Mail       -> the read-only mailbox launcher (list of all mailboxes)
" :Mail <box> -> open that mailbox directly
command! -nargs=? -complete=customlist,mail#mailbox#_complete_mailbox Mail call mail#mailboxlist#mail_cmd(<q-args>)

" g:mail_from: Full From header, e.g. 'Your Name <you@gmail.com>'. Set in vimrc.
let g:mail_from = get(g:, 'mail_from', '')

" Locate this plugin's own root (plugin/ -> repo root) so mail_store.py is found
" wherever the repo was cloned, with no hardcoded path.
let s:plugin_root = expand('<sfile>:p:h:h')

" g:mail_python:   python3 interpreter (resolved from PATH; override in vimrc).
" g:mail_store_py: path to mail_store.py (defaults to scripts/ in this repo).
let g:mail_python = get(g:, 'mail_python',
      \ exepath('python3') !=# '' ? exepath('python3') : 'python3')
let g:mail_store_py = get(g:, 'mail_store_py', s:plugin_root . '/scripts/mail_store.py')

" g:mail_store_cmd: base 'python3 mail_store.py ingest-stdin' command. Fetch no
" longer uses it (getmail's rc file carries the ingest MDA); it now only seeds
" mail#util#py_cmd() (which strips the trailing ' ingest-stdin'). Override if you
" need something custom.
let g:mail_store_cmd = get(g:, 'mail_store_cmd',
      \ g:mail_python . ' ' . g:mail_store_py . ' ingest-stdin')

" g:mail_getmail:    the getmail binary (override if not on PATH / named getmail6).
" g:mail_getmail_rc: path to your getmailrc — IMAP creds + the ingest MDA. Written
"                    by you/setup.sh (never the plugin), so the password stays in
"                    one user-owned file. See mail-setup.md.
let g:mail_getmail    = get(g:, 'mail_getmail', 'getmail')
let g:mail_getmail_rc = get(g:, 'mail_getmail_rc', '~/.getmail/getmailrc')

" g:mail_send_cmd: the sendmail-compatible send transport (passed to mail_store.py
" send via $MAIL_SENDMAIL). Default 'msmtp -t' — msmtp talks SMTP straight from
" ~/.msmtprc, no local Postfix. Set to 'sendmail -t' to relay through a local MTA.
let g:mail_send_cmd = get(g:, 'mail_send_cmd', 'msmtp -t')
