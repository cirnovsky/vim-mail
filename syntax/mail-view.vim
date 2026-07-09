if exists('b:current_syntax')
  finish
endif

" Base coloring: the builtin mail syntax (quotes + headers), same as before this
" buffer had its own filetype.
runtime! syntax/mail.vim
unlet! b:current_syntax

" Actionable placeholders, highlighted so they read as clickable (gx opens,
" gd/gD jump): inline [N] / [img N] and the Links:/Attachments: footer keys [N].
syntax match mailViewMarker    /\[\%(\a\+ \)\?\d\+\]/
syntax match mailViewFooterKey /^\[\d\+\]/
highlight default link mailViewMarker    Underlined
highlight default link mailViewFooterKey Special

let b:current_syntax = 'mail-view'
