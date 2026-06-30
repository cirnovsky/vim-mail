" Reading messages: preview, full open, HTML/mime view, search.
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

let s:preview_bufnr   = -1

function! mail#view#open_html() abort
  let idx = mail#index#_current_index()
  if idx == -1
    return
  endif
  let dir = b:mail_entries[idx].dir
  if !filereadable(dir . '/body.html')
    echo 'No HTML body'
    return
  endif
  let opener = has('mac') ? 'open' : 'xdg-open'
  " Build a viewable copy with cid: images inlined as data: URIs — cid refs
  " don't resolve from a file:// page. External images load via the browser.
  let py_cmd = mail#util#py_cmd()
  let view = system(py_cmd . ' viewhtml ' . shellescape(dir))
  if v:shell_error == 0 && view !=# ''
    let tmp = tempname() . '.html'
    call writefile(split(view, "\n", 1), tmp)
    call job_start([opener, tmp])
  else
    call job_start([opener, dir . '/body.html'])
  endif
endfunction

function! mail#view#mimeview() abort
  let idx = mail#index#_current_index()
  if idx == -1
    return
  endif
  let dir = b:mail_entries[idx].dir . '/attachments'
  if !isdirectory(dir)
    echo 'No attachments'
    return
  endif

  let target_winid = -1
  for w in range(1, winnr('$'))
    if gettabwinvar(tabpagenr(), w, 'mail_mimeview_win', 0) == 1
      let target_winid = win_getid(w)
    endif
  endfor
  if target_winid != -1
    call win_gotoid(target_winid)
    execute 'edit ' . fnameescape(dir)
  else
    execute 'botright split ' . fnameescape(dir)
    let w:mail_mimeview_win = 1
  endif
endfunction

function! mail#view#_open_preview_window(vertical) abort
  if s:preview_bufnr != -1 && bufexists(s:preview_bufnr)
    let winid = bufwinid(s:preview_bufnr)
    if winid != -1
      call win_gotoid(winid)
      return
    endif
    execute (a:vertical ? 'botright vsplit' : 'botright split')
    execute 'buffer ' . s:preview_bufnr
    return
  endif
  execute (a:vertical ? 'botright vsplit' : 'botright split')
  enew
  setlocal buftype=nofile bufhidden=hide noswapfile nobuflisted
  setlocal syntax=mail              " builtin mail syntax: colored quotes + headers
  silent! file [Mail\ Preview]
  let s:preview_bufnr = bufnr('%')
endfunction

" o / v in the index: quick body-only preview (shared split, reused buffer).
" a:vertical=0 → botright split, 1 → botright vsplit (only matters on first open).
function! mail#view#preview(vertical) abort
  let idx = mail#index#_current_index()
  if idx == -1
    return
  endif
  let entry = b:mail_entries[idx]

  " Mark as read now, while index buffer is still active
  if !entry.read
    call mail#actions#_set_read(idx, 1)
  endif

  let bodyfile = entry.dir . '/body.txt'
  let raw = filereadable(bodyfile) ? readfile(bodyfile) : ['(no body.txt)']

  " Strip quoted lines (>) and their attribution lines ("On ... wrote:"),
  " then collapse runs of blank lines to a single blank.
  let lines = []
  let prev_blank = 0
  for i in range(len(raw))
    let l = raw[i]
    if l =~# '^>'
      continue
    endif
    " Attribution line: doesn't start with > but the next non-empty line does
    if l =~# '\<wrote:\s*$' && i + 1 < len(raw) && raw[i + 1] =~# '^>'
      continue
    endif
    let is_blank = l =~# '^\s*$'
    if is_blank && prev_blank
      continue
    endif
    call add(lines, l)
    let prev_blank = is_blank
  endfor

  call mail#view#_open_preview_window(a:vertical)
  setlocal modifiable
  silent! 1,$delete _
  call setline(1, lines)
  setlocal nomodifiable nomodified
endfunction

" <CR> in the index: full message view with thread history.
" If the message has In-Reply-To / References, ancestors found in the same
" mailbox are appended below a divider (newest on top, oldest at bottom).
" buftype=nofile + nomodifiable means :q never prompts; :w <file> exports.
function! mail#view#open_message() abort
  let idx = mail#index#_current_index()
  if idx == -1 | return | endif
  let entry = b:mail_entries[idx]

  if !entry.read
    call mail#actions#_set_read(idx, 1)
  endif

  let rawfile = entry.dir . '/raw.eml'

  let headers = mail#view#_filtered_headers(rawfile)

  let bodyfile = entry.dir . '/body.txt'
  let body = filereadable(bodyfile) ? readfile(bodyfile) : ['(no body)']

  let lines = headers + [''] + body

  " Thread reconstruction: follow References then In-Reply-To
  let refs_raw = mail#view#_extract_header(rawfile, 'References')
  let irt      = mail#view#_extract_header(rawfile, 'In-Reply-To')
  if refs_raw !=# '' || irt !=# ''
    let msgid_idx = mail#thread#_build_msgid_index()
    " References lists ancestors oldest→newest; we append them newest→oldest
    " (i.e. reverse) so the oldest ends up at the bottom of the buffer.
    let ref_ids = reverse(split(refs_raw))
    if irt !=# ''
      let irt_n = substitute(irt, '[<> ]', '', 'g')
      if index(map(copy(ref_ids), 'substitute(v:val,"[<> ]","","g")'), irt_n) == -1
        call insert(ref_ids, irt, 0)
      endif
    endif
    for ref in ref_ids
      let ref_n = substitute(ref, '[<> ]', '', 'g')
      if !has_key(msgid_idx, ref_n) | continue | endif
      let adir = msgid_idx[ref_n]
      let a_hdrs = mail#view#_filtered_headers(adir . '/raw.eml')
      let a_body = filereadable(adir . '/body.txt')
            \ ? readfile(adir . '/body.txt') : ['(no body)']
      let lines += ['', repeat('─', 72), ''] + a_hdrs + [''] + a_body
    endfor
  endif

  execute 'botright split'
  wincmd _                       " maximize height: full-screen read, :q returns
  enew
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal syntax=mail              " builtin mail syntax: colored quotes + headers
  execute 'silent! file ' . fnameescape('[Mail] ' . entry.meta.subject)
  call setline(1, lines)
  setlocal nomodifiable nomodified
  call cursor(len(headers) + 2, 1)
endfunction

" Return filtered reader-relevant headers from rawfile as a list of strings.
function! mail#view#_filtered_headers(rawfile) abort
  let want = ['from', 'to', 'cc', 'reply-to', 'date', 'subject']
  let seen    = {}
  let headers = []
  if !filereadable(a:rawfile)
    return headers
  endif
  let folded = ''
  for line in readfile(a:rawfile)
    if line ==# ''
      break
    elseif line =~# '^\s' && folded !=# ''
      let folded .= ' ' . trim(line)
    else
      if folded !=# ''
        let key = tolower(split(folded, ':')[0])
        if index(want, key) >= 0 && !has_key(seen, key)
          let seen[key] = 1
          if key ==# 'reply-to'
            let rt = trim(substitute(folded, '^[^:]*:\s*', '', ''))
            let fr = trim(substitute(get(filter(copy(headers),
                  \ 'v:val =~? "^From:"'), 0, ''), '^[^:]*:\s*', '', ''))
            if rt !=# fr | call add(headers, folded) | endif
          else
            call add(headers, folded)
          endif
        endif
      endif
      let folded = line
    endif
  endfor
  return headers
endfunction

" Extract a single header value from an raw.eml file, handling RFC5322
" folded headers (continuation lines starting with whitespace).
function! mail#view#_extract_header(rawfile, hname) abort
  let result = ''
  let found = 0
  if !filereadable(a:rawfile)
    return ''
  endif
  for line in readfile(a:rawfile)
    if line ==# ''
      break
    endif
    if found && line =~# '^\s'
      let result .= ' ' . trim(line)
    else
      let found = 0
      if line =~? '^' . a:hname . '\s*:'
        let result = substitute(line, '^[^:]*:\s*', '', '')
        let found = 1
      endif
    endif
  endfor
  return trim(result)
endfunction

function! mail#view#search() abort
  let pattern = input('Search mail: ')
  redraw
  if pattern ==# ''
    return
  endif
  let root = mail#mailbox#_normdir(get(g:, 'mail_root', '~/Mail'))
  try
    noautocmd execute 'vimgrep /' . escape(pattern, '/') . '/j ' . root . '/**/body.txt'
  catch /E480/
    echo 'No matches: ' . pattern
    return
  endtry
  " Replace raw file paths with From — Subject | matched line
  let updated = []
  for item in getqflist()
    let msg_dir = fnamemodify(bufname(item.bufnr), ':h')
    let from = '' | let subject = ''
    for mline in filereadable(msg_dir . '/meta') ? readfile(msg_dir . '/meta') : []
      if mline =~? '^From:'    | let from    = trim(substitute(mline, '^From:\s*',    '', 'i'))
      elseif mline =~? '^Subject:' | let subject = trim(substitute(mline, '^Subject:\s*', '', 'i'))
      endif
    endfor
    let item.text = from . ' — ' . subject . ' | ' . trim(item.text)
    call add(updated, item)
  endfor
  call setqflist(updated, 'r')
  copen
endfunction
