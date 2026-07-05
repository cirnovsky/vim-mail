if exists('b:did_ftplugin_mail_trash')
  finish
endif
let b:did_ftplugin_mail_trash = 1

" Read-only view of orphaned (fully-deleted) messages. No dd / s / p here —
" nomodifiable makes it a pure viewer. Recover a message with yy (native yank),
" then p into a real mailbox buffer.
setlocal conceallevel=2 concealcursor=nvc nomodifiable nowrap
setlocal cursorline
highlight CursorLine cterm=underline gui=underline ctermbg=NONE guibg=NONE

" Read/nav (same as the index): open, preview, mime, html, reply, forward, search.
nnoremap <buffer> <silent> <CR> :call mail#view#open_message()<CR>
nnoremap <buffer> <silent> o    :call mail#view#preview(0)<CR>
nnoremap <buffer> <silent> v    :call mail#view#preview(1)<CR>
nnoremap <buffer> <silent> gm   :call mail#view#mimeview()<CR>
nnoremap <buffer> <silent> x    :call mail#view#open_html()<CR>
nnoremap <buffer> <silent> r    :call mail#compose#reply()<CR>
nnoremap <buffer> <silent> f    :call mail#compose#forward()<CR>
nnoremap <buffer> <silent> F    :call mail#compose#forward_attach()<CR>
nnoremap <buffer> <silent> <leader>s :call mail#view#search()<CR>
" R rescans (orphans change as you delete/recover); - returns to the launcher.
nnoremap <buffer> <silent> R    :call mail#trash#refresh()<CR>
nnoremap <buffer> <silent> -    :call mail#mailboxlist#open()<CR>
