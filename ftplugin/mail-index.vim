if exists('b:did_ftplugin_mail_index')
  finish
endif
let b:did_ftplugin_mail_index = 1

setlocal conceallevel=2 concealcursor=nvc

augroup mail_index
  autocmd! * <buffer>
  autocmd BufWriteCmd  <buffer> call mail#write()
augroup END

nnoremap <buffer> <silent> <CR>  :call mail#open_message()<CR>
nnoremap <buffer> <silent> o    :call mail#preview(0)<CR>
nnoremap <buffer> <silent> v    :call mail#preview(1)<CR>
nnoremap <buffer> <silent> gm        :call mail#mimeview()<CR>
nnoremap <buffer> <silent> x          :call mail#open_html()<CR>
nnoremap <buffer> <expr>   t    mail#_set_mark_opfunc()
nmap     <buffer>          tt   t_
nnoremap <buffer> <silent> T    :call mail#clear_marks()<CR>
nnoremap <buffer> <silent> M    :call mail#move()<CR>
nnoremap <buffer> <silent> r           :call mail#reply()<CR>
nnoremap <buffer> <silent> f           :call mail#forward()<CR>
nnoremap <buffer> <silent> F           :call mail#forward_attach()<CR>
nnoremap <buffer> <silent> R           :call mail#refresh()<CR>
nnoremap <buffer> <silent> <leader>s   :call mail#search()<CR>
nnoremap <buffer> <silent> <leader>c   :call mail#compose()<CR>
nnoremap <buffer> <silent> <leader>f   :call mail#fetch()<CR>
nnoremap <buffer> <silent> q    :bwipeout<CR>

nnoremap <buffer> <silent> s  :call mail#read(1)<CR>
nnoremap <buffer> <silent> S  :call mail#read(0)<CR>
