if exists('g:loaded_mail_plugin')
  finish
endif
let g:loaded_mail_plugin = 1

command! -nargs=? -complete=customlist,mail#_complete_mailbox Mail call mail#open(<q-args>)
