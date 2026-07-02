if exists('b:did_ftplugin_mail_mailboxes')
  finish
endif
let b:did_ftplugin_mail_mailboxes = 1

" Read-only launcher: mailboxes are too important to edit here. <CR> enters.
setlocal nomodifiable nowrap conceallevel=0
setlocal cursorline
highlight CursorLine cterm=underline gui=underline ctermbg=NONE guibg=NONE

" Multi-account tree: each account is a manual fold whose first line is the
" account name, so a closed fold shows just that name (a dropdown). render()
" builds and closes them; zo/zc/za and <CR> expand/collapse. foldtext shows the
" header line verbatim. (Single-account mode creates no folds — a flat list.)
setlocal foldmethod=manual foldtext=getline(v:foldstart)

nnoremap <buffer> <silent> <CR>          :call mail#mailboxlist#enter()<CR>
nnoremap <buffer> <silent> <2-LeftMouse> :call mail#mailboxlist#enter()<CR>
nnoremap <buffer> <silent> q             :bwipeout<CR>
