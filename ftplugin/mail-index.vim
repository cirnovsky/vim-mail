if exists('b:did_ftplugin_mail_index')
  finish
endif
let b:did_ftplugin_mail_index = 1

setlocal conceallevel=2 concealcursor=nvc

" vifm-style selection: a solid cyan bar on the message the cursor is on (black
" text on cyan). cursorline is buffer-local (shows only in the index); CursorLine
" is global but only paints where cursorline is set, so your editing windows are
" untouched. Retune the shade in your ~/.config/muaa/config.vim if you like.
setlocal cursorline
highlight CursorLine cterm=NONE ctermbg=Cyan ctermfg=Black gui=NONE guibg=#34c6d4 guifg=#04222a

" vifm-style bottom bar: mailbox + counts on the left, the message under the
" cursor (from · date) and position i/N on the right. Buffer-local, so it only
" skins the message list — your editing Vim's statusline is untouched.
let &l:statusline = ' %{mail#index#_sl_left()} %= %{mail#index#_sl_cur()}  %l/%L '

augroup mail_index
  autocmd! * <buffer>
  autocmd BufWriteCmd  <buffer> call mail#actions#write()
augroup END

" vifm-style: l opens the message (descend), h returns to the launcher (ascend).
" <CR> (open) and `-` (up) are kept as aliases.
nnoremap <buffer> <silent> <CR>  :call mail#view#open_message()<CR>
nnoremap <buffer> <silent> l     :call mail#view#open_message()<CR>
nnoremap <buffer> <silent> o    :call mail#view#preview(0)<CR>
nnoremap <buffer> <silent> v    :call mail#view#preview(1)<CR>
nnoremap <buffer> <silent> gm        :call mail#view#mimeview()<CR>
nnoremap <buffer> <silent> x          :call mail#view#open_html()<CR>
" Move = dd here + p there; copy = yy + p (committed on :w). h/- go up to the
" mailbox launcher, so opening the destination to paste into is the natural gesture.
nnoremap <buffer> <silent> h    :call mail#mailboxlist#open()<CR>
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
