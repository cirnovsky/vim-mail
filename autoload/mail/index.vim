" The index buffer: rendering, batched redraws, line<->entry resolution.
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

let s:index_bufnrs  = {}
let s:pending_syncs = {}   " {bufnr: 1} — buffers needing a modified/line resync
let s:batch_timer   = -1

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
  " First open, or returning to an UNMODIFIED buffer: full refresh (picks up
  " newly-fetched mail). Returning to a buffer with staged edits: DON'T
  " full-refresh (it would discard the pending dd/paste/read-toggle — the bug that
  " turned dd+p moves into accidental copies) — instead merge in only the mail
  " that appeared on disk, leaving edited lines untouched. R still full-refreshes.
  if !reused
    call mail#index#refresh()                     " first open: full render
  elseif !&modified
    " Reused, clean: pick up newly-fetched mail incrementally and re-baseline,
    " WITHOUT a destroy-recreate — so undo survives navigation.
    call mail#index#_merge_new()
    call mail#index#_resync_baseline(bufnr('%'))
  else
    " Reused, staged edits: merge new mail, keep the edits (and undo).
    call mail#index#_merge_new()
  endif
endfunction

" Eagerly create + render an index buffer for EVERY mailbox under the root, so
" each mailbox buffer is live from startup: staged fetch always has a buffer to
" stage into, and cross-mailbox :w and dd+p/yy+p paste always find every endpoint
" loaded. Reuses open()'s render path per mailbox — each enew hides the previous
" buffer but keeps it loaded (bufhidden=hide) — then restores the starting view.
" Idempotent: already-loaded mailboxes are skipped, so repeat :Mail calls only
" pay for newly-appeared mailboxes. One meta read per message, once.
function! mail#index#preload_all() abort
  let start   = bufnr('%')
  let save_lz = &lazyredraw
  set lazyredraw
  try
    for name in mail#mailboxlist#_mailboxes()
      let dir = mail#mailbox#_resolve_mailbox(name)
      let nr  = get(s:index_bufnrs, dir, -1)
      if nr > 0 && bufexists(nr) && getbufvar(nr, 'mail_dir', '') ==# dir
        continue                                       " already loaded
      endif
      call mail#index#open(name)
    endfor
  finally
    if bufexists(start) | execute 'buffer ' . start | endif
    let &lazyredraw = save_lz
  endtry
endfunction

" Insert mail that appeared on disk (e.g. a background fetch) but is in neither
" this buffer's baseline nor its current lines, in newest-first order, WITHOUT
" touching existing lines — so staged edits (reads, deletes, pastes) survive
" while new mail still shows. No-op when there's nothing new. Called when
" returning to a modified buffer; a staged-deleted message stays in the baseline
" so it is NOT resurrected.
function! mail#index#_merge_new() abort
  let baseline_ids = {}
  for e in b:mail_entries | let baseline_ids[e.id] = 1 | endfor
  let buf_ids = {}
  for ln in range(1, line('$'))
    let l = getline(ln)
    let tab = stridx(l, "\t")
    if tab > 0 | let buf_ids[l[:tab - 1]] = 1 | endif
  endfor
  for e in mail#index#_read_entries(b:mail_dir)
    if has_key(baseline_ids, e.id) || has_key(buf_ids, e.id) | continue | endif
    let line = mail#index#_format_line(e.id, e.meta, e.read)
    let placed = 0
    for ln in range(1, line('$'))
      let l = getline(ln)
      let tab = stridx(l, "\t")
      if tab > 0 && l[:tab - 1] <# e.id    " newest-first: before the first smaller id
        call append(ln - 1, line)
        let placed = 1
        break
      endif
    endfor
    if !placed | call append(line('$'), line) | endif
    call add(b:mail_entries, e)            " it's disk truth now, not a staged add
  endfor
endfunction

" Read a mailbox dir from disk into the entry baseline list (sorted newest-first,
" .store/.tmp_* skipped). Shared by refresh() and _resync_baseline().
function! mail#index#_read_entries(dir) abort
  let dirs = []
  for path in glob(a:dir . '/*', 0, 1)
    if isdirectory(path) && fnamemodify(path, ':t') !~# '^\.'
      call add(dirs, path)
    endif
  endfor
  call sort(dirs)
  call reverse(dirs)
  let entries = []
  for d in dirs
    call add(entries, {'dir': d, 'id': fnamemodify(d, ':t'),
          \ 'read': filereadable(d . '/.read'), 'meta': mail#index#_read_meta(d)})
  endfor
  return entries
endfunction

" Live index buffers (bufnr list), for cross-mailbox :w reconciliation.
function! mail#index#_index_buffers() abort
  let bufs = []
  for [dir, nr] in items(s:index_bufnrs)
    if bufexists(nr) && getbufvar(nr, 'mail_dir', '') ==# dir
      call add(bufs, nr)
    endif
  endfor
  return bufs
endfunction

" After :w commits another (non-current) buffer's staged edits, re-read its
" mailbox into the baseline and clear &modified — WITHOUT rewriting its lines
" (they already show the committed state; _flush_pending canonicalises later).
function! mail#index#_resync_baseline(bnr) abort
  let dir = getbufvar(a:bnr, 'mail_dir', '')
  if dir ==# '' | return | endif
  call setbufvar(a:bnr, 'mail_entries', mail#index#_read_entries(dir))
  call setbufvar(a:bnr, '&modified', 0)
endfunction

function! mail#index#refresh() abort
  if !exists('b:mail_dir')
    echoerr 'Not a mail index buffer'
    return
  endif
  call mail#thread#invalidate()

  let entries = mail#index#_read_entries(b:mail_dir)
  let lines = []
  for e in entries
    call add(lines, mail#index#_format_line(e.id, e.meta, e.read))
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

function! mail#index#_format_line(id, meta, read) abort
  let r = a:read ? ' ' : 'N'
  return a:id . "\t" . r . ' ' . mail#index#_short_date(a:meta.date) . '  '
        \ . mail#index#_trunc(a:meta.from, 28) . '  ' . a:meta.subject
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
  for k in keys(s:pending_syncs) | let all_bnrs[k] = 1 | endfor
  let s:pending_syncs = {}

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
        call add(new_lines, mail#index#_format_line(e.id, e.meta, l[tab + 1] !=# 'N'))
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
  let idx = mail#index#_current_index()
  return idx == -1 ? [] : [idx]
endfunction

" Core batch primitive: apply Fn(read) -> new_read.
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
        let e = entries[eidx]
        call add(new_lines, mail#index#_format_line(e.id, e.meta, a:Fn(l[tab + 1] !=# 'N')))
        continue
      endif
    endif
    call add(new_lines, l)
  endfor
  noautocmd call setline(1, new_lines)
  call mail#index#_sync_modified()
endfunction

" Refresh the index buffer showing <dir>, if one is open (used after fetch).
" Repaint <dir>'s index after a fetch. A clean buffer is fully refreshed (shows
" the new mail); a MODIFIED buffer is merged instead — new mail inserted, staged
" edits untouched — so fetching never needs to prompt to discard them. A hidden
" buffer (no window) is left for the next navigation, where open() does the same.
function! mail#index#refresh_for(dir) abort
  let nr = get(s:index_bufnrs, a:dir, -1)
  if nr <= 0 || !bufexists(nr) | return | endif
  let winid = bufwinid(nr)
  if winid == -1 | return | endif
  let cur = win_getid()
  call win_gotoid(winid)
  " Merge new mail incrementally (undo-preserving). A clean buffer is then
  " re-baselined; a modified one keeps its staged edits.
  let was_modified = &modified
  call mail#index#_merge_new()
  if !was_modified | call mail#index#_resync_baseline(bufnr('%')) | endif
  call win_gotoid(cur)
endfunction
