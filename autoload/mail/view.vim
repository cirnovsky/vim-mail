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
  " Build a viewable copy with cid: images inlined as data: URIs — cid refs
  " don't resolve from a file:// page. External images load via the browser.
  let py_cmd = mail#util#py_cmd()
  let view = system(py_cmd . ' viewhtml ' . shellescape(dir))
  if v:shell_error == 0 && view !=# ''
    let tmp = tempname() . '.html'
    call writefile(split(view, "\n", 1), tmp)
    call mail#view#_open_external(tmp)
  else
    call mail#view#_open_external(dir . '/body.html')
  endif
endfunction

" --- actionable markers in the message view (full open + preview) ----------
"
" body.txt carries inert markers this view makes actionable (no stored-format
" change — it reads the markers already there):
"   inline  [N]            a hyperlink, listed in the trailing "Links:" footer
"   inline  [img N]/[..N]  an inline part, listed in the "Attachments:" footer
"   footer  [N] href       (under Links:)        -> open the URL in a browser
"   footer  [N] filename   (under Attachments:)  -> open <dir>/attachments/<file>
" Link-[N] and attachment-[N] are independent 1-based sequences. Resolution is
" section-relative — an inline placeholder binds to the nearest matching footer
" BELOW it — so a threaded view (several messages, each with its own footers)
" stays correct. Keys live in ftplugin/mail-view.vim: gx open, gd placeholder->
" footer, gD footer->placeholder.

function! mail#view#_open_external(target) abort
  let opener = has('mac') ? 'open' : 'xdg-open'
  call job_start([opener, a:target])
endfunction

" Nearest footer section a line sits under, scanning upward: 'link'|'attach'|''.
function! s:section_at(lnum) abort
  let l = a:lnum
  while l >= 1
    let t = getline(l)
    if t ==# 'Links:'       | return 'link'   | endif
    if t ==# 'Attachments:' | return 'attach' | endif
    let l -= 1
  endwhile
  return ''
endfunction

" Marker under the cursor: {} or {kind:'link'|'attach', n, footer:0|1, lnum}.
function! s:marker_at(lnum, col) abort
  let line = getline(a:lnum)
  let fm = matchlist(line, '^\[\(\d\+\)\] \(.*\)$')
  if !empty(fm)
    let sect = s:section_at(a:lnum)
    if sect !=# ''
      return {'kind': sect, 'n': fm[1], 'footer': 1, 'lnum': a:lnum}
    endif
  endif
  let start = 0
  while 1
    let mp = matchstrpos(line, '\[\%(\a\+ \)\?\d\+\]', start)
    if mp[1] < 0 | break | endif
    if a:col - 1 >= mp[1] && a:col - 1 < mp[2]
      let ml = matchlist(mp[0], '^\[\%(\(\a\+\) \)\?\(\d\+\)\]$')
      return {'kind': empty(ml[1]) ? 'link' : 'attach', 'n': ml[2], 'footer': 0, 'lnum': a:lnum}
    endif
    let start = mp[2]
  endwhile
  return {}
endfunction

" First footer entry line for (kind, n) whose section header is at/after `from`.
function! s:footer_line(kind, n, from) abort
  let header = a:kind ==# 'link' ? 'Links:' : 'Attachments:'
  let last = line('$')
  let l = a:from
  while l <= last && getline(l) !=# header | let l += 1 | endwhile
  if l > last | return 0 | endif
  let l += 1
  while l <= last && getline(l) =~# '^\[\d\+\] '
    if getline(l) =~# '^\[' . a:n . '\] ' | return l | endif
    let l += 1
  endwhile
  return 0
endfunction

function! s:target(kind, rest) abort
  if a:rest ==# '' | return {} | endif
  if a:kind ==# 'link'
    return {'type': 'url', 'target': a:rest}
  endif
  return {'type': 'file', 'target': get(b:, 'mail_view_dir', '') . '/attachments/' . a:rest}
endfunction

" Resolve the marker under (lnum,col) to {type,target}, or {} if none/unresolved.
function! mail#view#_resolve_at(lnum, col) abort
  let m = s:marker_at(a:lnum, a:col)
  if empty(m) | return {} | endif
  if m.footer
    return s:target(m.kind, matchstr(getline(m.lnum), '^\[\d\+\] \zs.*$'))
  endif
  let fl = s:footer_line(m.kind, m.n, m.lnum)
  if fl == 0 | return {} | endif
  return s:target(m.kind, matchstr(getline(fl), '^\[\d\+\] \zs.*$'))
endfunction

" gx: open the URL / attachment under the cursor.
function! mail#view#open_marker() abort
  let t = mail#view#_resolve_at(line('.'), col('.'))
  if !empty(t)
    call mail#view#_open_external(t.target)
    return
  endif
  " No [N]/attachment marker: fall back to a bare URL under the cursor (plain-
  " text links carry no marker). netrw's gx would open it, but this buffer's gx
  " mapping shadows netrw — so replicate that behaviour here.
  let url = mail#view#_url_at(line('.'), col('.'))
  if url !=# ''
    call mail#view#_open_external(url)
    return
  endif
  echo 'No link, attachment, or URL under cursor'
endfunction

" A bare URL under the cursor (byte column a:col on line a:lnum), or '' — gx's
" fallback when there's no marker. Finds the URL-match span covering the cursor
" and trims trailing sentence punctuation (e.g. a period the body put right after
" the link, as in a plain-text 'see https://…/programme.').
function! mail#view#_url_at(lnum, col) abort
  let line  = getline(a:lnum)
  let pat   = '\%(https\?\|ftp\)://[^[:space:]]\+\|mailto:[^[:space:]]\+'
  let start = 0
  while 1
    let m = matchstrpos(line, pat, start)
    if m[1] < 0 | break | endif
    if a:col - 1 >= m[1] && a:col - 1 < m[2]
      return substitute(m[0], '[.,;:!?)\]}>''"]\+$', '', '')
    endif
    let start = m[2]
  endwhile
  return ''
endfunction

" gd: from an inline placeholder jump down to its footer entry.
function! mail#view#jump_to_footer() abort
  let m = s:marker_at(line('.'), col('.'))
  if empty(m) || m.footer | return | endif
  let fl = s:footer_line(m.kind, m.n, m.lnum)
  if fl > 0
    call cursor(fl, 1)
  else
    echo 'No footer entry for [' . m.n . ']'
  endif
endfunction

" gD: from a footer entry jump back up to the inline placeholder above it.
function! mail#view#jump_to_inline() abort
  let m = s:marker_at(line('.'), col('.'))
  if empty(m) || !m.footer | return | endif
  let header = m.kind ==# 'link' ? 'Links:' : 'Attachments:'
  let hl = m.lnum
  while hl >= 1 && getline(hl) !=# header | let hl -= 1 | endwhile
  if hl < 1 | return | endif
  let pat = m.kind ==# 'link' ? '\[' . m.n . '\]' : '\[\a\+\s' . m.n . '\]'
  let save = getcurpos()
  call cursor(hl, 1)
  if search(pat, 'bW') == 0
    call setpos('.', save)
    echo 'No placeholder for [' . m.n . ']'
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
  setlocal filetype=mail-view       " marker keymaps + syntax (loads builtin mail)
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
  " Staged read-mark is committed on :w, so skip it in read-only views (TRASH):
  " setline() would throw on a nomodifiable buffer and abort the open.
  if !entry.read && &modifiable
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
  let b:mail_view_dir = entry.dir
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

  " Staged read-mark is committed on :w, so skip it in read-only views (TRASH):
  " setline() would throw on a nomodifiable buffer and abort the open.
  if !entry.read && &modifiable
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
  execute 'silent! file ' . fnameescape('[Mail] ' . entry.meta.subject)
  let b:mail_view_dir = entry.dir
  call setline(1, lines)
  setlocal filetype=mail-view       " marker keymaps + syntax (loads builtin mail)
  setlocal nomodifiable nomodified
  call cursor(len(headers) + 2, 1)
endfunction

" Return filtered reader-relevant headers as a list of strings.
"
" Read from the sibling `meta` file, NOT raw.eml: raw.eml headers are
" RFC2047-encoded (e.g. Subject: =?utf-8?Q?...?=), which renders as gibberish;
" the backend already decoded them into `meta` at ingest. a:rawfile is the
" dir's raw.eml — we derive meta from it (keeps the signature for callers).
" Reply-To only appears for mail ingested after it was added to _write_meta;
" older mail simply won't show it.
function! mail#view#_filtered_headers(rawfile) abort
  let meta = fnamemodify(a:rawfile, ':h') . '/meta'
  if !filereadable(meta)
    return []
  endif
  let vals = {}
  for line in readfile(meta)
    let c = stridx(line, ':')
    if c > 0
      let vals[tolower(line[: c - 1])] = trim(line[c + 1 :])
    endif
  endfor
  " Fixed display order; skip empty values; suppress Reply-To when == From.
  let order = [['From', 'from'], ['Reply-To', 'reply-to'], ['To', 'to'],
        \ ['Cc', 'cc'], ['Subject', 'subject'], ['Date', 'date']]
  let headers = []
  for [label, key] in order
    let v = get(vals, key, '')
    if v ==# '' | continue | endif
    if key ==# 'reply-to' && v ==# get(vals, 'from', '') | continue | endif
    call add(headers, label . ': ' . v)
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
  let root = mail#mailbox#root()
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
