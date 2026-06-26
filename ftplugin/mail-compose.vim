if exists('b:did_ftplugin_mail_compose')
  finish
endif
let b:did_ftplugin_mail_compose = 1

augroup mail_compose
  autocmd! * <buffer>
  autocmd BufWriteCmd <buffer> call mail#send()
augroup END
