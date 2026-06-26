if exists('b:did_ftplugin_mail_compose')
  finish
endif
let b:did_ftplugin_mail_compose = 1

augroup mail_compose
  autocmd! * <buffer>
  autocmd BufWriteCmd <buffer> call mail#send()
augroup END

" Attachments (buffer-local). :Attach takes one or more paths/globs.
" <leader>A is a quick prefilled :Attach; <leader>a attaches clipboard file(s).
command! -buffer -nargs=* -complete=file Attach call mail#attach(<f-args>)
" <leader>A: prefill ':Attach ' so you just type/Tab-complete the path.
nnoremap <buffer> <leader>A :Attach <Space>
nnoremap <buffer> <silent> <leader>a :call mail#attach_clipboard()<CR>
nnoremap <buffer> <silent> <leader>p :call mail#paste_image()<CR>
