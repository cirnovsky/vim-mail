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
nnoremap <buffer> <expr>   t    mail#actions#_set_mark_opfunc()
nmap     <buffer>          tt   t_
nnoremap <buffer> <silent> T    :call mail#actions#clear_marks()<CR>
nnoremap <buffer> <silent> M    :call mail#actions#move()<CR>
" :Move/:M <mailbox> — relink move without the interactive prompt; :Copy adds a
" label (keeps the source). Both tab-complete a mailbox name under g:mail_root.
command! -buffer -nargs=1 -complete=customlist,mail#mailbox#_complete_mailbox Move
      \ call mail#actions#move_to(<q-args>)
command! -buffer -nargs=1 -complete=customlist,mail#mailbox#_complete_mailbox M
      \ call mail#actions#move_to(<q-args>)
command! -buffer -nargs=1 -complete=customlist,mail#mailbox#_complete_mailbox Copy
      \ call mail#actions#copy(<q-args>)
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
