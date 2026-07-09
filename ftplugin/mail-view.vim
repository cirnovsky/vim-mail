if exists('b:did_ftplugin_mail_view')
  finish
endif
let b:did_ftplugin_mail_view = 1

" Read-only message view (full <CR> open + o/v preview). body.txt placeholders
" are actionable here:
"   gx  open the URL / attachment under the cursor
"   gd  jump from an inline [N] / [img N] down to its Links:/Attachments: footer
"   gD  jump from a footer entry back up to the inline placeholder
nnoremap <buffer> <silent> gx :call mail#view#open_marker()<CR>
nnoremap <buffer> <silent> gd :call mail#view#jump_to_footer()<CR>
nnoremap <buffer> <silent> gD :call mail#view#jump_to_inline()<CR>
