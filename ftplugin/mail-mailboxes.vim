if exists('b:did_ftplugin_mail_mailboxes')
  finish
endif
let b:did_ftplugin_mail_mailboxes = 1

" Read-only launcher: mailboxes are too important to edit here. <CR> enters.
setlocal nomodifiable nowrap conceallevel=0
setlocal cursorline
highlight CursorLine cterm=underline gui=underline ctermbg=NONE guibg=NONE

nnoremap <buffer> <silent> <CR>          :call mail#mailboxlist#enter()<CR>
nnoremap <buffer> <silent> <2-LeftMouse> :call mail#mailboxlist#enter()<CR>
nnoremap <buffer> <silent> q             :bwipeout<CR>
