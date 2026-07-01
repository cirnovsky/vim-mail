" The index buffer: rendering, batched redraws, line<->entry resolution.
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

let s:index_bufnrs    = {}
let s:pending_redraws = {}   " {bufnr: {idx: 1}} — lines queued for redraw
let s:pending_syncs   = {}   " {bufnr: 1}        — buffers needing modified sync
let s:batch_timer     = -1

function! mail#index#open(dir) abort
  let dir = a:dir ==# '' ? mail#mailbox#_resolve_mailbox('inbox') : mail#mailbox#_resolve_mailbox(a:dir)
  if !isdirectory(dir)
    echoerr 'Not a directory: ' . dir
    return
  endif

  " Reuse only a live buffer that is genuinely our index for this dir — a stale
  " map entry (buffer wiped by `q`, or its number reused) must fall through.
  let nr = get(s:index_bufnrs, dir, -1)
  let reused = 0
  if nr > 0 && bufexists(nr) && getbufvar(nr, 'mail_dir', '') ==# dir
    let winid = bufwinid(nr)
    if winid != -1
      call win_gotoid(winid)
    else
      execute 'buffer ' . nr
    endif
    let reused = 1
  else
    " New index buffer. The name must NOT look like a filesystem path: the old
    " 'mail://' . dir produced 'mail:///Users/…/inbox', which Vim parses as a URL
    " whose path is a real directory ("[New DIRECTORY]") — netrw/Vim then hijacks
    " the buffer and b:mail_dir is gone before refresh runs. Use 'mail://<name>'
    " (basename only) and create with noautocmd so no directory handler fires.
    noautocmd enew
    setlocal buftype=acwrite bufhidden=hide noswapfile nowrap nobuflisted
    silent! noautocmd execute 'file ' . fnameescape('mail://' . fnamemodify(dir, ':t'))
    let b:mail_dir = dir
    let s:index_bufnrs[dir] = bufnr('%')
    setlocal filetype=mail-index
  endif
  " Build the link map L from readdirs (names only) — the refcount source for
  " last-label delete decisions across all loaded mailboxes.
  call mail#link#rebuild()
  " Refresh from disk on first open, or when returning to an UNMODIFIED buffer
  " (picks up newly-fetched mail). But NEVER refresh a reused buffer that has
  " staged, uncommitted edits: navigating away and back with :Mail must not
  " silently discard a pending dd / paste / read-toggle (that turned dd+p moves
  " into accidental copies). Use R to refresh from disk on purpose.
  if !reused || !&modified
    call mail#index#refresh()
  endif
endfunction

function! mail#index#refresh() abort
  if !exists('b:mail_dir')
    echoerr 'Not a mail index buffer'
    return
  endif
  call mail#thread#invalidate()

  let raw = glob(b:mail_dir . '/*', 0, 1)
  let dirs = []
  for path in raw
    if isdirectory(path) && fnamemodify(path, ':t') !~# '^\.'
      call add(dirs, path)
    endif
  endfor
  call sort(dirs)
  call reverse(dirs)

  let entries = []
  let lines = []
  for d in dirs
    let meta = mail#index#_read_meta(d)
    let read = filereadable(d . '/.read')
    let id = fnamemodify(d, ':t')
    call add(entries, {'dir': d, 'id': id, 'read': read, 'meta': meta})
    call add(lines, mail#index#_format_line(id, meta, read, 0))
  endfor

  let b:mail_entries = entries

  let ul = &undolevels
  set undolevels=-1
  silent! 1,$delete _
  if !empty(lines)
    call setline(1, lines)
  endif
  let &undolevels = ul
  " A just-refreshed buffer matches disk → no staged changes. Clear &modified
  " synchronously (the _sync_modified timer is async and may not have run yet,
  " e.g. in headless -es mode), so the staged-edit guard reads it reliably.
  call mail#index#_sync_modified()
  setlocal nomodified
endfunction

function! mail#index#_read_meta(dir) abort
  let result = {'from': '', 'to': '', 'cc': '', 'subject': '', 'date': '', 'message_id': '', 'in_reply_to': ''}
  let path = a:dir . '/meta'
  if !filereadable(path)
    return result
  endif
  for line in readfile(path)
    let idx = stridx(line, ':')
    if idx ==# -1
      continue
    endif
    let key = tolower(line[:idx - 1])
    let value = trim(line[idx + 1:])
    if key ==# 'from'
      let result.from = value
    elseif key ==# 'to'
      let result.to = value
    elseif key ==# 'cc'
      let result.cc = value
    elseif key ==# 'subject'
      let result.subject = value
    elseif key ==# 'date'
      let result.date = value
    elseif key ==# 'message-id'
      let result.message_id = value
    elseif key ==# 'in-reply-to'
      let result.in_reply_to = value
    endif
  endfor
  return result
endfunction

function! mail#index#_short_date(date) abort
  " 'Wed, 24 Jun 2026 13:44:28 +0800' -> 'Wed 24 Jun 2026 13:44'
  let parts = split(a:date, ' ')
  if len(parts) >= 5
    return parts[0] . ' ' . parts[1] . ' ' . parts[2] . ' ' . parts[3] . ' ' . parts[4][:4]
  endif
  return a:date
endfunction

function! mail#index#_trunc(s, width) abort
  if strchars(a:s) > a:width
    return strcharpart(a:s, 0, a:width - 1) . '…'
  endif
  return a:s . repeat(' ', a:width - strchars(a:s))
endfunction

function! mail#index#_format_line(id, meta, read, marked) abort
  let r = a:read ? ' ' : 'N'
  let m = a:marked ? '*' : ' '
  return a:id . "\t" . r . m . ' ' . mail#index#_short_date(a:meta.date) . '  '
        \ . mail#index#_trunc(a:meta.from, 28) . '  ' . a:meta.subject
endfunction

function! mail#index#_redraw_line(idx) abort
  let bnr = bufnr('%')
  if !has_key(s:pending_redraws, bnr)
    let s:pending_redraws[bnr] = {}
  endif
  let s:pending_redraws[bnr][a:idx] = 1
  call s:_schedule_flush()
endfunction

" True buffer "modified" should mean "there are staged changes" (staged
" deletes or read/unread state that differs from disk), not merely "we
" last called setline()" - this resyncs &modified to that.
function! mail#index#_sync_modified() abort
  let s:pending_syncs[bufnr('%')] = 1
  call s:_schedule_flush()
endfunction

function! s:_schedule_flush() abort
  if s:batch_timer != -1
    call timer_stop(s:batch_timer)
  endif
  let s:batch_timer = timer_start(0, function('mail#index#_flush_pending'))
endfunction

function! mail#index#_flush_pending(timer) abort
  let s:batch_timer = -1
  let all_bnrs = {}
  for k in keys(s:pending_redraws) | let all_bnrs[k] = 1 | endfor
  for k in keys(s:pending_syncs)   | let all_bnrs[k] = 1 | endfor
  let s:pending_redraws = {}
  let s:pending_syncs   = {}

  for bnr_str in keys(all_bnrs)
    let bnr     = str2nr(bnr_str)
    if !bufexists(bnr) | continue | endif
    let entries = getbufvar(bnr, 'mail_entries', [])
    if empty(entries) | continue | endif

    " Rebuild only EXISTING buffer lines by ID — never restore lines deleted by dd.
    let id_to_entry = {}
    for e in entries | let id_to_entry[e.id] = e | endfor

    let buf_lines = getbufline(bnr, 1, '$')
    let new_lines = []
    for l in buf_lines
      let tab = stridx(l, "\t")
      if tab >= 0 && has_key(id_to_entry, l[:tab - 1])
        let e = id_to_entry[l[:tab - 1]]
        call add(new_lines, mail#index#_format_line(e.id, e.meta,
              \ l[tab + 1] !=# 'N', l[tab + 2] ==# '*'))
      else
        call add(new_lines, l)
      endif
    endfor
    call setbufline(bnr, 1, new_lines)

    " Sync modified: pending if any entry is missing (staged delete)
    " or its read state in the buffer differs from disk baseline.
    let buf_id_read = {}
    for l in buf_lines
      let tab = stridx(l, "\t")
      if tab > 0 | let buf_id_read[l[:tab-1]] = l[tab + 1] !=# 'N' | endif
    endfor
    let pending = 0
    for entry in entries
      if !has_key(buf_id_read, entry.id)
        let pending = 1 | break
      elseif buf_id_read[entry.id] !=# entry.read
        let pending = 1 | break
      endif
    endfor
    call setbufvar(bnr, '&modified', pending)
  endfor
endfunction

function! mail#index#_id_to_idx() abort
  let map = {}
  for i in range(len(b:mail_entries))
    let map[b:mail_entries[i].id] = i
  endfor
  return map
endfunction

function! mail#index#_current_index() abort
  if !exists('b:mail_entries')
    return -1
  endif
  let l   = getline('.')
  let tab = stridx(l, "\t")
  if tab < 0
    return -1
  endif
  let id  = l[:tab - 1]
  let map = mail#index#_id_to_idx()
  return get(map, id, -1)
endfunction

function! mail#index#_target_indexes() abort
  if !exists('b:mail_entries')
    return []
  endif
  let map  = mail#index#_id_to_idx()
  let idxs = []
  for ln in range(1, line('$'))
    let l   = getline(ln)
    let tab = stridx(l, "\t")
    if tab >= 0 && l[tab + 2] ==# '*'
      let eidx = get(map, l[:tab - 1], -1)
      if eidx >= 0 | call add(idxs, eidx) | endif
    endif
  endfor
  if !empty(idxs) | return idxs | endif
  let idx = mail#index#_current_index()
  return idx == -1 ? [] : [idx]
endfunction

" Core batch primitive: apply Fn(read, marked) -> [new_read, new_marked]
" targets: {entry_idx: 1}; empty = all lines.
" Looks up entries by ID from each line — safe after dd.
function! mail#index#_patch_lines(targets, Fn) abort
  let apply_all  = empty(a:targets)
  let entries    = b:mail_entries
  let id_to_idx  = mail#index#_id_to_idx()
  let new_lines  = []
  for ln in range(1, line('$'))
    let l   = getline(ln)
    let tab = stridx(l, "\t")
    if tab >= 0
      let id   = l[:tab - 1]
      let eidx = get(id_to_idx, id, -1)
      if eidx >= 0 && (apply_all || has_key(a:targets, eidx))
        let result = a:Fn(l[tab + 1] !=# 'N', l[tab + 2] ==# '*')
        let e = entries[eidx]
        call add(new_lines, mail#index#_format_line(e.id, e.meta, result[0], result[1]))
        continue
      endif
    endif
    call add(new_lines, l)
  endfor
  noautocmd call setline(1, new_lines)
  call mail#index#_sync_modified()
endfunction

" Refresh the index buffer showing <dir>, if one is open (used after fetch).
function! mail#index#refresh_for(dir) abort
  if has_key(s:index_bufnrs, a:dir) && bufexists(s:index_bufnrs[a:dir])
    let winid = bufwinid(s:index_bufnrs[a:dir])
    if winid != -1
      let cur = win_getid()
      call win_gotoid(winid)
      call mail#index#refresh()
      call win_gotoid(cur)
    endif
  endif
endfunction
