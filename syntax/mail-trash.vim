if exists('b:current_syntax')
  finish
endif

" Same line format as the index: "<message-id>\t<visible text>" — hide the id.
" (yy still yanks the full line incl. the concealed id, so a paste recovers it.)
syntax match MailTrashId /^[^\t]*\t/ conceal

let b:current_syntax = 'mail-trash'
