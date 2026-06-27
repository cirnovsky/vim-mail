" Composing: new message, reply, forward.
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

function! mail#compose#_extract_address(from) abort
  let addr = matchstr(a:from, '<\zs[^>]*\ze>')
  return addr !=# '' ? addr : a:from
endfunction

function! mail#compose#compose() abort
  execute 'botright split'
  enew
  setlocal buftype=acwrite bufhidden=wipe noswapfile
  setlocal filetype=mail-compose
  execute 'silent! file ' . fnameescape('mail-compose://new-' . localtime())
  call setline(1, ['To: ', 'Subject: ', ''])
  call cursor(1, 5)
  setlocal nomodified
  let b:mail_compose_to = ''
  let b:mail_compose_subject = ''
endfunction

" Clean plain text of a message for quoting, via mail_store.py (prefers the
" sender's own text/plain, else a footnote-free html render). Never reads the
" annotated body.txt. Returns a list of lines.
function! mail#compose#_quote_lines(dir) abort
  let py_cmd = mail#util#py_cmd()
  let out    = system(py_cmd . ' quote ' . shellescape(a:dir))
  if v:shell_error != 0
    return []
  endif
  let lines = split(out, "\n", 1)
  while !empty(lines) && lines[-1] ==# ''
    call remove(lines, -1)
  endwhile
  return lines
endfunction

function! mail#compose#reply() abort
  let idx = mail#index#_current_index()
  if idx == -1
    return
  endif
  let meta    = b:mail_entries[idx].meta
  let to      = mail#compose#_extract_address(meta.from)
  let subject = meta.subject =~? '^re:' ? meta.subject : 'Re: ' . meta.subject

  " Capture everything we need from the index buffer BEFORE enew switches b:
  let entry_dir = b:mail_entries[idx].dir
  let rawfile   = entry_dir . '/raw.eml'
  let orig_mid  = mail#view#_extract_header(rawfile, 'Message-ID')
  let orig_ref  = mail#view#_extract_header(rawfile, 'References')
  let new_refs  = (orig_ref !=# '' ? orig_ref . ' ' : '') . orig_mid
  " Quote the clean original (sender's text/plain, or footnote-free html) via
  " mail_store.py — never the annotated body.txt with its Links:/[N] footers.
  let body      = mail#compose#_quote_lines(entry_dir)

  execute 'botright split'
  enew
  setlocal buftype=acwrite bufhidden=wipe noswapfile
  setlocal filetype=mail-compose
  execute 'silent! file ' . fnameescape('mail-compose://reply-' . localtime())

  " Build Cc: all original Cc recipients minus our own address
  let own = tolower(mail#compose#_extract_address(get(g:, 'mail_from', '')))
  let cc_parts = []
  for addr in split(meta.cc, ',')
    let addr = trim(addr)
    if addr !=# '' && tolower(mail#compose#_extract_address(addr)) !=# own
      call add(cc_parts, addr)
    endif
  endfor

  let hdr_lines = ['To: ' . to]
  if !empty(cc_parts)
    call add(hdr_lines, 'Cc: ' . join(cc_parts, ', '))
  endif
  call add(hdr_lines, 'Subject: ' . subject)
  if orig_mid !=# ''
    call add(hdr_lines, 'In-Reply-To: ' . orig_mid)
  endif
  if new_refs !=# ''
    call add(hdr_lines, 'References: ' . new_refs)
  endif
  call add(hdr_lines, '')

  " Body: an empty line for the user's reply (cursor lands here), then an
  " 'On <date>, <sender> wrote:' attribution, then the '> '-quoted original.
  " The message is sent plain-text verbatim, so this is exactly what ships.
  let lines = copy(hdr_lines)
  call add(lines, '')
  if meta.from !=# '' || meta.date !=# ''
    call add(lines, 'On ' . meta.date . ', ' . meta.from . ' wrote:')
  endif
  for l in body
    call add(lines, '> ' . l)
  endfor
  call setline(1, lines)
  call cursor(len(hdr_lines) + 1, 1)
  setlocal nomodified

  let b:mail_compose_to      = to
  let b:mail_compose_subject = subject
  let b:mail_compose_orig_dir = entry_dir
endfunction

" Shared compose-buffer setup for both forward modes. Returns the entry dir.
function! s:_forward_buffer(label) abort
  let idx = mail#index#_current_index()
  if idx == -1
    return ''
  endif
  let entry     = b:mail_entries[idx]
  let meta      = entry.meta
  let entry_dir = entry.dir
  let subject   = meta.subject =~? '^fwd\?:' ? meta.subject : 'Fwd: ' . meta.subject

  execute 'botright split'
  enew
  setlocal buftype=acwrite bufhidden=wipe noswapfile
  setlocal filetype=mail-compose
  execute 'silent! file ' . fnameescape('mail-compose://' . a:label . '-' . localtime())

  let hdr_lines = ['To: ', 'Subject: ' . subject, '']
  let lines = copy(hdr_lines)
  call add(lines, '')
  call add(lines, '---------- Forwarded message ----------')
  call add(lines, 'From: ' . meta.from)
  call add(lines, 'Date: ' . meta.date)
  call add(lines, 'Subject: ' . meta.subject)
  if meta.to !=# ''
    call add(lines, 'To: ' . meta.to)
  endif
  call setline(1, lines)
  call cursor(len(hdr_lines) + 1, 1)
  setlocal nomodified

  let b:mail_compose_to      = ''
  let b:mail_compose_subject = subject
  return entry_dir
endfunction

" Forward inline (f): the original's body is shown inline below the forwarded
" header block — HTML embedded (with images), plain appended unquoted, and the
" original's real attachments re-attached. A re-render, like Gmail/Outlook.
" The original body is appended at send time (mail_store.py), not put in the
" buffer, so it isn't duplicated against the embedded HTML. New thread.
function! mail#compose#forward() abort
  let dir = s:_forward_buffer('forward')
  if dir ==# '' | return | endif
  let b:mail_compose_orig_dir  = dir   " send embeds body.html + re-attaches files
  let b:mail_compose_fwd_inline = 1
endfunction

" Forward as attachment (F): the whole original rides along as a message/rfc822
" .eml — byte-exact and lossless, opened by the recipient. New thread.
function! mail#compose#forward_attach() abort
  let dir = s:_forward_buffer('forward')
  if dir ==# '' | return | endif
  let b:mail_compose_forward = dir     " send attaches <dir>/raw.eml as rfc822
endfunction
