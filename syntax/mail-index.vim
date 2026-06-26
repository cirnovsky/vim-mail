if exists('b:current_syntax')
  finish
endif

" Each line is "<message-id>\t<visible text>" - hide the id, it's only
" there so dd/d3j/:g//d can be diffed against on :w.
syntax match MailIndexId /^[^\t]*\t/ conceal

let b:current_syntax = 'mail-index'
