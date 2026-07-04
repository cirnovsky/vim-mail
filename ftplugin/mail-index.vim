if exists('b:did_ftplugin_mail_index')
  finish
endif
let b:did_ftplugin_mail_index = 1

setlocal conceallevel=2 concealcursor=nvc

" Underline the message the cursor is on. cursorline is buffer-local (shows only
" in the index); CursorLine is restyled as a plain underline with no background
" box so it reads as an underline rather than a highlighted band.
setlocal cursorline
highlight CursorLine cterm=underline gui=underline ctermbg=NONE guibg=NONE

augroup mail_index
  autocmd! * <buffer>
  autocmd BufWriteCmd  <buffer> call mail#actions#write()
augroup END

nnoremap <buffer> <silent> <CR>  :call mail#view#open_message()<CR>
nnoremap <buffer> <silent> o    :call mail#view#preview(0)<CR>
nnoremap <buffer> <silent> v    :call mail#view#preview(1)<CR>
nnoremap <buffer> <silent> gm        :call mail#view#mimeview()<CR>
nnoremap <buffer> <silent> x          :call mail#view#open_html()<CR>
" Move = dd here + p there; copy = yy + p (committed on :w). `-` goes up to the
" mailbox launcher, so opening the destination to paste into is the natural gesture.
nnoremap <buffer> <silent> -    :call mail#mailboxlist#open()<CR>
nnoremap <buffer> <silent> r           :call mail#compose#reply()<CR>
nnoremap <buffer> <silent> f           :call mail#compose#forward()<CR>
nnoremap <buffer> <silent> F           :call mail#compose#forward_attach()<CR>
nnoremap <buffer> <silent> R           :call mail#index#refresh()<CR>
nnoremap <buffer> <silent> <leader>s   :call mail#view#search()<CR>
nnoremap <buffer> <silent> <leader>c   :call mail#compose#compose()<CR>
nnoremap <buffer> <silent> <leader>f   :call mail#fetch#fetch()<CR>

nnoremap <buffer> <silent> s  :call mail#actions#read(1)<CR>
nnoremap <buffer> <silent> S  :call mail#actions#read(0)<CR>
