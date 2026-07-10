if exists('b:did_ftplugin_mail_mailboxes')
  finish
endif
let b:did_ftplugin_mail_mailboxes = 1

" Read-only launcher: mailboxes are too important to edit here. <CR> enters.
" No current-line underline (nocursorline); hjkl jump whole mailboxes, not chars.
setlocal nomodifiable nowrap conceallevel=0 nocursorline

nnoremap <buffer> <silent> <CR>          :call mail#mailboxlist#enter()<CR>
nnoremap <buffer> <silent> <2-LeftMouse> :call mail#mailboxlist#enter()<CR>
nnoremap <buffer> <silent> j :call mail#mailboxlist#jump(1)<CR>
nnoremap <buffer> <silent> k :call mail#mailboxlist#jump(-1)<CR>
nnoremap <buffer> <silent> l :call mail#mailboxlist#jump(1)<CR>
nnoremap <buffer> <silent> h :call mail#mailboxlist#jump(-1)<CR>
nnoremap <buffer> <silent> <leader>f     :call mail#fetch#fetch()<CR>
nnoremap <buffer> <silent> <leader>c     :call mail#compose#compose()<CR>
nnoremap <buffer> <silent> q             :bwipeout<CR>
