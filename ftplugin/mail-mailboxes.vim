if exists('b:did_ftplugin_mail_mailboxes')
  finish
endif
let b:did_ftplugin_mail_mailboxes = 1

" Read-only launcher: mailboxes are too important to edit here. vifm-style keys:
" j/k move between mailboxes, l/<CR> enters one, h does nothing (the launcher is
" the root — nothing to ascend to). No current-line underline (nocursorline).
setlocal nomodifiable nowrap conceallevel=0 nocursorline

nnoremap <buffer> <silent> <CR>          :call mail#mailboxlist#enter()<CR>
nnoremap <buffer> <silent> l             :call mail#mailboxlist#enter()<CR>
nnoremap <buffer> <silent> <2-LeftMouse> :call mail#mailboxlist#enter()<CR>
nnoremap <buffer> <silent> j :call mail#mailboxlist#jump(1)<CR>
nnoremap <buffer> <silent> k :call mail#mailboxlist#jump(-1)<CR>
nnoremap <buffer> <silent> h <Nop>
" R re-renders, picking the layout (boxed menu / plain list) for the CURRENT
" window width — handy after resizing the window.
nnoremap <buffer> <silent> R             :call mail#mailboxlist#render()<CR>
nnoremap <buffer> <silent> <leader>f     :call mail#fetch#fetch()<CR>
nnoremap <buffer> <silent> <leader>c     :call mail#compose#compose()<CR>
nnoremap <buffer> <silent> q             :bwipeout<CR>
