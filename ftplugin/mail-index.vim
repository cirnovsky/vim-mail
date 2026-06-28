if exists('b:did_ftplugin_mail_index')
  finish
endif
let b:did_ftplugin_mail_index = 1

setlocal conceallevel=2 concealcursor=nvc

augroup mail_index
  autocmd! * <buffer>
  autocmd BufWriteCmd  <buffer> call mail#actions#write()
augroup END

nnoremap <buffer> <silent> <CR>  :call mail#view#open_message()<CR>
nnoremap <buffer> <silent> o    :call mail#view#preview(0)<CR>
nnoremap <buffer> <silent> v    :call mail#view#preview(1)<CR>
nnoremap <buffer> <silent> gm        :call mail#view#mimeview()<CR>
nnoremap <buffer> <silent> x          :call mail#view#open_html()<CR>
nnoremap <buffer> <expr>   t    mail#actions#_set_mark_opfunc()
nmap     <buffer>          tt   t_
nnoremap <buffer> <silent> T    :call mail#actions#clear_marks()<CR>
nnoremap <buffer> <silent> M    :call mail#actions#move()<CR>
nnoremap <buffer> <silent> r           :call mail#compose#reply()<CR>
nnoremap <buffer> <silent> f           :call mail#compose#forward()<CR>
nnoremap <buffer> <silent> F           :call mail#compose#forward_attach()<CR>
nnoremap <buffer> <silent> R           :call mail#index#refresh()<CR>
nnoremap <buffer> <silent> <leader>s   :call mail#view#search()<CR>
nnoremap <buffer> <silent> <leader>c   :call mail#compose#compose()<CR>
nnoremap <buffer> <silent> <leader>f   :call mail#fetch#fetch()<CR>
nnoremap <buffer> <silent> q    :bwipeout<CR>

nnoremap <buffer> <silent> s  :call mail#actions#read(1)<CR>
nnoremap <buffer> <silent> S  :call mail#actions#read(0)<CR>
