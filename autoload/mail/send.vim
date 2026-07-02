" Assembling and sending the compose buffer.
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

" Inline images referenced by surviving '[img id]' markers in the body:
" returns [[id, path], …] for entries registered as inline.
function! mail#send#_inline_images(body_lines) abort
  let id2path = {}
  for a in get(b:, 'mail_attachments', [])
    if get(a, 'inline', 0) | let id2path[a.id] = a.path | endif
  endfor
  let ids = []
  call substitute(join(a:body_lines, "\n"), '\[img \(\d\+\)\]',
        \ '\=add(ids, str2nr(submatch(1)))', 'g')
  let found = []
  let seen = {}
  for n in ids
    if has_key(id2path, n) && !has_key(seen, n)
      let seen[n] = 1
      call add(found, [n, id2path[n]])
    endif
  endfor
  return found
endfunction

" Split a compose body into (body without the Attachments: footer, [paths]).
" Surviving footer ids are resolved against b:mail_attachments; the footer and
" any blank lines before it are removed so they aren't sent as literal text.
function! mail#send#_split_attachments(body_lines) abort
  let id2path = {}
  for a in get(b:, 'mail_attachments', [])
    let id2path[a.id] = a.path
  endfor
  let fstart = -1
  for i in range(len(a:body_lines))
    if a:body_lines[i] =~# '^Attachments:\s*$' | let fstart = i | endif
  endfor
  if fstart < 0
    return {'body': a:body_lines, 'paths': []}
  endif
  let paths = []
  for l in a:body_lines[fstart + 1 :]
    if l =~# '^\[\d\+\] '
      let n = str2nr(matchstr(l, '^\[\zs\d\+\ze\]'))
      if has_key(id2path, n) | call add(paths, id2path[n]) | endif
    endif
  endfor
  let endx = fstart
  while endx > 0 && a:body_lines[endx - 1] =~# '^\s*$'
    let endx -= 1
  endwhile
  return {'body': endx > 0 ? a:body_lines[: endx - 1] : [], 'paths': paths}
endfunction

function! mail#send#send() abort
  if !exists('b:mail_compose_to')
    echoerr 'Not a compose buffer'
    return
  endif

  " Collect user-written headers and body from the compose buffer
  let all_lines    = getline(1, '$')
  let user_hdrs    = []
  let body_lines   = []
  let past_headers = 0
  for l in all_lines
    if !past_headers && l ==# ''
      let past_headers = 1
      continue
    endif
    if past_headers
      call add(body_lines, l)
    else
      call add(user_hdrs, l)
    endif
  endfor

  " Resolve attachments: pull surviving 'Attachments:' footer ids -> paths and
  " strip the footer from the body (it's a compose-time affordance, not sent).
  let split = mail#send#_split_attachments(body_lines)
  let body_lines = split.body

  " Write compose file: From + Date prepended, then user headers + blank + body.
  " mail_store.py send reads this and sends the body as plain text. Control
  " headers (stripped by send): X-Forward-Dir / X-Forward-Inline for forwards,
  " X-Mail-Attach (one per file) for attachments.
  let msg = []
  if g:mail_from !=# ''
    call add(msg, 'From: ' . g:mail_from)
  endif
  call add(msg, 'Date: ' . strftime('%a, %d %b %Y %H:%M:%S %z'))
  let msg += user_hdrs
  if exists('b:mail_compose_forward')
    call add(msg, 'X-Forward-Dir: ' . b:mail_compose_forward)
  endif
  if exists('b:mail_compose_fwd_inline')
    call add(msg, 'X-Forward-Inline: 1')
  endif
  for p in split.paths
    call add(msg, 'X-Mail-Attach: ' . p)
  endfor
  for pair in mail#send#_inline_images(body_lines)
    call add(msg, 'X-Mail-Inline: ' . pair[0] . ' ' . pair[1])
  endfor
  let msg += [''] + body_lines

  let tmpfile = tempname()
  call writefile(msg, tmpfile)

  " Derive 'python3 /path/to/mail_store.py' from g:mail_store_cmd
  let py_cmd   = mail#util#py_cmd()
  let orig_arg = exists('b:mail_compose_orig_dir')
        \ ? ' ' . shellescape(b:mail_compose_orig_dir) : ' ""'
  let sent_dir = mail#mailbox#root() . '/sent'
  let result   = system(py_cmd . ' send ' . shellescape(tmpfile)
        \ . orig_arg . ' ' . shellescape(sent_dir))
  call delete(tmpfile)
  if v:shell_error != 0
    echoerr 'Send failed: ' . result
    return
  endif
  setlocal nomodified
  let to_hdr = filter(copy(user_hdrs), 'v:val =~? "^To:"')
  let to = empty(to_hdr) ? b:mail_compose_to
        \ : substitute(to_hdr[0], '^To:\s*', '', '')
  echo 'Sent to ' . to
endfunction
