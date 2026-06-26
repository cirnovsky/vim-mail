" netrw-style frontend over the one-folder-per-message mail store produced
" by mail_store.py. Index buffer lists messages; body/MIME decoding is
" never done here, only in mail_store.py.

let s:index_bufnrs    = {}
let s:preview_bufnr   = -1
let s:fetch_job       = v:null
let s:fetch_dir       = ''
let s:fetch_before    = {}
let s:pending_redraws = {}   " {bufnr: {idx: 1}} — lines queued for redraw
let s:pending_syncs   = {}   " {bufnr: 1}        — buffers needing modified sync
let s:batch_timer     = -1
let s:msgid_index     = {}   " cross-mailbox cache; invalidated on refresh/write
let s:msgid_index_ok  = 0

function! mail#_normdir(dir) abort
  let dir = fnamemodify(expand(a:dir), ':p')
  if dir =~# '/$'
    let dir = dir[:-2]
  endif
  return dir
endfunction

" Resolve a user-supplied mailbox string to a full path.
" Bare names (no leading / or ~) are joined under g:mail_root.
function! mail#_resolve_mailbox(name) abort
  let root = mail#_normdir(get(g:, 'mail_root', '~/Mail'))
  let raw  = a:name =~# '^[/~]' ? a:name : root . '/' . a:name
  return mail#_normdir(raw)
endfunction

function! mail#_complete_mailbox(arglead, cmdline, cursorpos) abort
  let root = mail#_normdir(get(g:, 'mail_root', '~/Mail'))
  let names = map(filter(glob(root . '/*', 0, 1), 'isdirectory(v:val)'),
        \ 'fnamemodify(v:val, ":t")')
  return filter(names, 'v:val =~# "^" . a:arglead')
endfunction

function! mail#_complete_mailbox_str(arglead, cmdline, cursorpos) abort
  return join(mail#_complete_mailbox(a:arglead, a:cmdline, a:cursorpos), "\n")
endfunction

" Prompt for a mailbox name with Tab completion. Returns '' on cancel.
" a:prompt   — prompt text (no trailing space needed)
" a:default  — pre-filled text ('' for none)
function! mail#_prompt_mailbox(prompt, default) abort
  let result = input(a:prompt . ': ', a:default, 'custom,mail#_complete_mailbox_str')
  redraw
  return result
endfunction

" ---- index buffer -----------------------------------------------------

function! mail#open(dir) abort
  let dir = a:dir ==# '' ? mail#_resolve_mailbox('inbox') : mail#_resolve_mailbox(a:dir)
  if !isdirectory(dir)
    echoerr 'Not a directory: ' . dir
    return
  endif

  if has_key(s:index_bufnrs, dir) && bufexists(s:index_bufnrs[dir])
    let winid = bufwinid(s:index_bufnrs[dir])
    if winid != -1
      call win_gotoid(winid)
    else
      execute 'buffer ' . s:index_bufnrs[dir]
    endif
  else
    enew
    setlocal buftype=acwrite bufhidden=hide noswapfile nowrap nobuflisted
    silent! execute 'file ' . fnameescape('mail://' . dir)
    let b:mail_dir = dir
    let s:index_bufnrs[dir] = bufnr('%')
  endif
  setlocal filetype=mail-index
  call mail#refresh()
endfunction

function! mail#refresh() abort
  if !exists('b:mail_dir')
    echoerr 'Not a mail index buffer'
    return
  endif
  let s:msgid_index_ok = 0

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
    let meta = mail#_read_meta(d)
    let read = filereadable(d . '/.read')
    let id = fnamemodify(d, ':t')
    call add(entries, {'dir': d, 'id': id, 'read': read, 'meta': meta})
    call add(lines, mail#_format_line(id, meta, read, 0))
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
  call mail#_sync_modified()
  setlocal nomodified
endfunction

function! mail#_read_meta(dir) abort
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

function! mail#_short_date(date) abort
  " 'Wed, 24 Jun 2026 13:44:28 +0800' -> 'Wed 24 Jun 2026 13:44'
  let parts = split(a:date, ' ')
  if len(parts) >= 5
    return parts[0] . ' ' . parts[1] . ' ' . parts[2] . ' ' . parts[3] . ' ' . parts[4][:4]
  endif
  return a:date
endfunction

function! mail#_trunc(s, width) abort
  if strchars(a:s) > a:width
    return strcharpart(a:s, 0, a:width - 1) . '…'
  endif
  return a:s . repeat(' ', a:width - strchars(a:s))
endfunction

function! mail#_format_line(id, meta, read, marked) abort
  let r = a:read ? ' ' : 'N'
  let m = a:marked ? '*' : ' '
  return a:id . "\t" . r . m . ' ' . mail#_short_date(a:meta.date) . '  '
        \ . mail#_trunc(a:meta.from, 28) . '  ' . a:meta.subject
endfunction

function! mail#_redraw_line(idx) abort
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
function! mail#_sync_modified() abort
  let s:pending_syncs[bufnr('%')] = 1
  call s:_schedule_flush()
endfunction

function! s:_schedule_flush() abort
  if s:batch_timer != -1
    call timer_stop(s:batch_timer)
  endif
  let s:batch_timer = timer_start(0, function('mail#_flush_pending'))
endfunction

function! mail#_flush_pending(timer) abort
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
        call add(new_lines, mail#_format_line(e.id, e.meta,
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


function! mail#_id_to_idx() abort
  let map = {}
  for i in range(len(b:mail_entries))
    let map[b:mail_entries[i].id] = i
  endfor
  return map
endfunction

function! mail#_current_index() abort
  if !exists('b:mail_entries')
    return -1
  endif
  let l   = getline('.')
  let tab = stridx(l, "\t")
  if tab < 0
    return -1
  endif
  let id  = l[:tab - 1]
  let map = mail#_id_to_idx()
  return get(map, id, -1)
endfunction

function! mail#_target_indexes() abort
  if !exists('b:mail_entries')
    return []
  endif
  let map  = mail#_id_to_idx()
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
  let idx = mail#_current_index()
  return idx == -1 ? [] : [idx]
endfunction

" ---- actions -----------------------------------------------------------

" Core batch primitive: apply Fn(read, marked) -> [new_read, new_marked]
" targets: {entry_idx: 1}; empty = all lines.
" Looks up entries by ID from each line — safe after dd.
function! mail#_patch_lines(targets, Fn) abort
  let apply_all  = empty(a:targets)
  let entries    = b:mail_entries
  let id_to_idx  = mail#_id_to_idx()
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
        call add(new_lines, mail#_format_line(e.id, e.meta, result[0], result[1]))
        continue
      endif
    endif
    call add(new_lines, l)
  endfor
  noautocmd call setline(1, new_lines)
  call mail#_sync_modified()
endfunction

function! mail#_set_mark_opfunc() abort
  let &operatorfunc = 'mail#ToggleMarkOperator'
  return 'g@'
endfunction

function! mail#clear_marks() abort
  call mail#_patch_lines({}, {r, m -> [r, 0]})
endfunction

function! mail#ToggleMarkOperator(type) abort
  let targets    = {}
  let id_to_idx  = mail#_id_to_idx()
  for ln in range(line("'["), line("']"))
    let l   = getline(ln)
    let tab = stridx(l, "\t")
    if tab >= 0
      let eidx = get(id_to_idx, l[:tab - 1], -1)
      if eidx >= 0 | let targets[eidx] = 1 | endif
    endif
  endfor
  call mail#_patch_lines(targets, {r, m -> [r, !m]})
endfunction

function! mail#open_html() abort
  let idx = mail#_current_index()
  if idx == -1
    return
  endif
  let html = b:mail_entries[idx].dir . '/body.html'
  if !filereadable(html)
    echo 'No HTML body'
    return
  endif
  call job_start([has('mac') ? 'open' : 'xdg-open', html])
endfunction

function! mail#mimeview() abort
  let idx = mail#_current_index()
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

" BufWriteCmd handler: dd/d3j/:g//d etc. only remove lines from the
" buffer; this is where that staged delete actually hits disk. Messages
" deleted from a normal mailbox move to ~/Mail/trash (recoverable);
" deleting from inside ~/Mail/trash itself is permanent.
function! mail#write() abort
  " Parse surviving buffer lines into {id: read_bool}
  let buf_state = {}
  for l in getline(1, '$')
    let tab = stridx(l, "\t")
    if tab > 0
      let buf_state[l[:tab - 1]] = l[tab + 1] !=# 'N'
    endif
  endfor

  let trash_root = mail#_normdir(get(g:, 'mail_root', '~/Mail')) . '/trash'
  let in_trash   = (b:mail_dir ==# trash_root)
  let removed = 0

  for entry in b:mail_entries
    if !has_key(buf_state, entry.id)
      " Staged delete
      if in_trash
        call delete(entry.dir, 'rf')
      else
        if !isdirectory(trash_root)
          call mkdir(trash_root, 'p')
        endif
        call rename(entry.dir, trash_root . '/' . entry.id)
      endif
      let removed += 1
    else
      " Reconcile read state: buffer is authoritative, align disk to it
      let buf_read  = buf_state[entry.id]
      let disk_read = filereadable(entry.dir . '/.read')
      if buf_read && !disk_read
        call writefile([], entry.dir . '/.read')
      elseif !buf_read && disk_read
        call delete(entry.dir . '/.read')
      endif
    endif
  endfor

  if removed > 0
    echom 'Deleted ' . removed . ' message(s)'
          \ . (in_trash ? ' permanently' : ' to ~/Mail/trash')
  endif
  call mail#refresh()
  setlocal nomodified
endfunction

" Three-way confirm for the staged-edit guard. Returns 'save' | 'discard' |
" 'cancel'. Wrapped as its own function so tests can stub it (interactive
" confirm() can't be driven in batch mode).
function! mail#_confirm(msg) abort
  let n = confirm(a:msg, "&Save\n&Discard\n&Cancel", 3)
  return n == 1 ? 'save' : (n == 2 ? 'discard' : 'cancel')
endfunction

" Disk actions that refresh the index (move, fetch) rebuild the buffer from disk,
" discarding staged-but-unwritten edits (dd deletes, s/S read toggles). Guard
" them: when the buffer has staged changes, ask. 1 = proceed (after optionally
" writing them), 0 = abort. NOTE: 'Save' calls mail#write(), which rebuilds
" b:mail_entries — callers that pre-resolved targets must re-resolve by id after.
function! mail#_ok_to_refresh(action) abort
  if !&modified
    return 1
  endif
  let choice = mail#_confirm(a:action
        \ . ' will refresh the index and lose unwritten changes. Save them first?')
  if choice ==# 'save'
    call mail#write()
    return 1
  endif
  return choice ==# 'discard'
endfunction

function! mail#move() abort
  " Capture targets by id BEFORE the guard — a 'Save' there rebuilds b:mail_entries.
  let target_ids = map(mail#_target_indexes(), 'b:mail_entries[v:val].id')
  if empty(target_ids)
    return
  endif
  if !mail#_ok_to_refresh('Move')
    return
  endif
  " Re-resolve ids → current indices (b:mail_entries may have just been rebuilt).
  let id2idx = mail#_id_to_idx()
  let idxs = []
  for tid in target_ids
    if has_key(id2idx, tid) | call add(idxs, id2idx[tid]) | endif
  endfor
  if empty(idxs)
    return
  endif
  let dest_dir = mail#_prompt_mailbox('Move to mailbox', '')
  if dest_dir ==# ''
    return
  endif
  let dest_dir = mail#_resolve_mailbox(dest_dir)
  if !isdirectory(dest_dir)
    echohl ErrorMsg | echom 'mail: not a directory: ' . dest_dir | echohl None
    return
  endif
  let dest_name = fnamemodify(dest_dir, ':t')
  let moved  = 0
  let failed = []
  for idx in idxs
    let entry  = b:mail_entries[idx]
    let id     = fnamemodify(entry.dir, ':t')
    let target = dest_dir . '/' . id
    if isdirectory(target)
      " A dir with this id already lives in dest — rename() would clobber or
      " (for non-empty dirs) fail silently. Refuse and report.
      call add(failed, '"' . id . '" already exists in ' . dest_name)
    elseif rename(entry.dir, target) != 0
      call add(failed, '"' . id . '" rename failed')
    else
      let moved += 1
    endif
  endfor
  call mail#refresh()
  if moved > 0
    echom 'Moved ' . moved . ' message(s) to ' . dest_name
  endif
  if !empty(failed)
    echohl ErrorMsg
    echom 'mail: could not move ' . len(failed) . ' message(s): ' . join(failed, '; ')
    echohl None
  endif
endfunction

" ---- preview -------------------------------------------------------------

function! mail#_open_preview_window(vertical) abort
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
  silent! file [Mail\ Preview]
  let s:preview_bufnr = bufnr('%')
endfunction

" o / v in the index: quick body-only preview (shared split, reused buffer).
" a:vertical=0 → botright split, 1 → botright vsplit (only matters on first open).
function! mail#preview(vertical) abort
  let idx = mail#_current_index()
  if idx == -1
    return
  endif
  let entry = b:mail_entries[idx]

  " Mark as read now, while index buffer is still active
  if !entry.read
    call mail#_set_read(idx, 1)
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

  call mail#_open_preview_window(a:vertical)
  setlocal modifiable
  silent! 1,$delete _
  call setline(1, lines)
  setlocal nomodifiable nomodified
endfunction

" <CR> in the index: full message view with thread history.
" If the message has In-Reply-To / References, ancestors found in the same
" mailbox are appended below a divider (newest on top, oldest at bottom).
" buftype=nofile + nomodifiable means :q never prompts; :w <file> exports.
function! mail#open_message() abort
  let idx = mail#_current_index()
  if idx == -1 | return | endif
  let entry = b:mail_entries[idx]

  if !entry.read
    call mail#_set_read(idx, 1)
  endif

  let rawfile = entry.dir . '/raw.eml'

  let headers = mail#_filtered_headers(rawfile)

  let bodyfile = entry.dir . '/body.txt'
  let body = filereadable(bodyfile) ? readfile(bodyfile) : ['(no body)']

  let lines = headers + [''] + body

  " Thread reconstruction: follow References then In-Reply-To
  let refs_raw = mail#_extract_header(rawfile, 'References')
  let irt      = mail#_extract_header(rawfile, 'In-Reply-To')
  if refs_raw !=# '' || irt !=# ''
    let msgid_idx = mail#_build_msgid_index()
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
      let a_hdrs = mail#_filtered_headers(adir . '/raw.eml')
      let a_body = filereadable(adir . '/body.txt')
            \ ? readfile(adir . '/body.txt') : ['(no body)']
      let lines += ['', repeat('─', 72), ''] + a_hdrs + [''] + a_body
    endfor
  endif

  execute 'botright split'
  enew
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  execute 'silent! file ' . fnameescape('[Mail] ' . entry.meta.subject)
  call setline(1, lines)
  setlocal nomodifiable nomodified
  call cursor(len(headers) + 2, 1)
endfunction

" ---- read/unread ---------------------------------------------------------

function! mail#read(read) abort
  let targets = {}
  for idx in mail#_target_indexes() | let targets[idx] = 1 | endfor
  call mail#_patch_lines(targets, {r, m -> [a:read, m]})
endfunction

function! mail#_set_read(idx, read) abort
  let e = b:mail_entries[a:idx]
  let lnum = -1
  for ln in range(1, line('$'))
    let l   = getline(ln)
    let tab = stridx(l, "\t")
    if tab >= 0 && l[:tab - 1] ==# e.id
      let lnum = ln | break
    endif
  endfor
  if lnum == -1 | return | endif
  let l   = getline(lnum)
  let tab = stridx(l, "\t")
  if tab >= 0
    noautocmd call setline(lnum,
          \ mail#_format_line(e.id, e.meta, a:read, l[tab + 2] ==# '*'))
  endif
  call mail#_sync_modified()
endfunction


" ---- raw header helpers ---------------------------------------------------

" Return filtered reader-relevant headers from rawfile as a list of strings.
function! mail#_filtered_headers(rawfile) abort
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
function! mail#_extract_header(rawfile, hname) abort
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

" Build {stripped-message-id → dir-path} across ALL mailboxes under g:mail_root.
" For the current mailbox, entries are already in b:mail_entries (no disk I/O).
" For other mailboxes, reads each message's meta file (fast: 6 lines vs full
" raw.eml); falls back to raw.eml header extraction for pre-index messages
" whose meta predates the Message-ID field.
function! mail#_build_msgid_index() abort
  if s:msgid_index_ok
    return s:msgid_index
  endif
  let index = {}
  let root = mail#_normdir(get(g:, 'mail_root', '~/Mail'))
  let cur_dir = exists('b:mail_dir') ? b:mail_dir : ''

  " Current mailbox: already loaded into b:mail_entries — zero extra reads
  if exists('b:mail_entries')
    for entry in b:mail_entries
      if entry.meta.message_id !=# ''
        let index[substitute(entry.meta.message_id, '[<> ]', '', 'g')] = entry.dir
      endif
    endfor
  endif

  " All other mailboxes: read meta only (never raw.eml — too expensive at scale)
  for mbox in glob(root . '/*', 0, 1)
    if !isdirectory(mbox) || mbox ==# cur_dir | continue | endif
    for path in glob(mbox . '/*', 0, 1)
      if !isdirectory(path) | continue | endif
      let metafile = path . '/meta'
      if !filereadable(metafile) | continue | endif
      for mline in readfile(metafile)
        if mline =~? '^Message-ID:'
          let mid = trim(substitute(mline, '^Message-ID:\s*', '', 'i'))
          if mid !=# ''
            let index[substitute(mid, '[<> ]', '', 'g')] = path
          endif
          break
        endif
      endfor
    endfor
  endfor
  let s:msgid_index    = index
  let s:msgid_index_ok = 1
  return index
endfunction

" ---- reply / send ---------------------------------------------------------

function! mail#_extract_address(from) abort
  let addr = matchstr(a:from, '<\zs[^>]*\ze>')
  return addr !=# '' ? addr : a:from
endfunction

function! mail#search() abort
  let pattern = input('Search mail: ')
  redraw
  if pattern ==# ''
    return
  endif
  let root = mail#_normdir(get(g:, 'mail_root', '~/Mail'))
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

function! mail#compose() abort
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
function! mail#_quote_lines(dir) abort
  let py_cmd = substitute(g:mail_store_cmd, '\s\+ingest-stdin$', '', '')
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

function! mail#reply() abort
  let idx = mail#_current_index()
  if idx == -1
    return
  endif
  let meta    = b:mail_entries[idx].meta
  let to      = mail#_extract_address(meta.from)
  let subject = meta.subject =~? '^re:' ? meta.subject : 'Re: ' . meta.subject

  " Capture everything we need from the index buffer BEFORE enew switches b:
  let entry_dir = b:mail_entries[idx].dir
  let rawfile   = entry_dir . '/raw.eml'
  let orig_mid  = mail#_extract_header(rawfile, 'Message-ID')
  let orig_ref  = mail#_extract_header(rawfile, 'References')
  let new_refs  = (orig_ref !=# '' ? orig_ref . ' ' : '') . orig_mid
  " Quote the clean original (sender's text/plain, or footnote-free html) via
  " mail_store.py — never the annotated body.txt with its Links:/[N] footers.
  let body      = mail#_quote_lines(entry_dir)

  execute 'botright split'
  enew
  setlocal buftype=acwrite bufhidden=wipe noswapfile
  setlocal filetype=mail-compose
  execute 'silent! file ' . fnameescape('mail-compose://reply-' . localtime())

  " Build Cc: all original Cc recipients minus our own address
  let own = tolower(mail#_extract_address(get(g:, 'mail_from', '')))
  let cc_parts = []
  for addr in split(meta.cc, ',')
    let addr = trim(addr)
    if addr !=# '' && tolower(mail#_extract_address(addr)) !=# own
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
  let idx = mail#_current_index()
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
function! mail#forward() abort
  let dir = s:_forward_buffer('forward')
  if dir ==# '' | return | endif
  let b:mail_compose_orig_dir  = dir   " send embeds body.html + re-attaches files
  let b:mail_compose_fwd_inline = 1
endfunction

" Forward as attachment (F): the whole original rides along as a message/rfc822
" .eml — byte-exact and lossless, opened by the recipient. New thread.
function! mail#forward_attach() abort
  let dir = s:_forward_buffer('forward')
  if dir ==# '' | return | endif
  let b:mail_compose_forward = dir     " send attaches <dir>/raw.eml as rfc822
endfunction

" ---- attachments ---------------------------------------------------------
"
" b:mail_attachments = [{id, path}], keyed by a monotonic id. Each attachment
" shows in the compose buffer as a line in a trailing 'Attachments:' footer
" ('[id] basename'), matching the ingestion footer. The buffer is the source of
" truth: delete a footer line and that file won't be sent. On :w, mail#send
" resolves surviving footer ids to paths, strips the footer from the body, and
" passes each path to mail_store.py via an 'X-Mail-Attach' control header.

" Register a readable file as an attachment + add its footer line. Returns 1/0.
function! mail#_register_attachment(path) abort
  let p = fnamemodify(expand(a:path), ':p')
  if !filereadable(p)
    echohl ErrorMsg | echom 'mail: file not readable: ' . a:path | echohl None
    return 0
  endif
  if !exists('b:mail_attachments')
    let b:mail_attachments = []
    let b:mail_attach_seq  = 0
  endif
  let b:mail_attach_seq += 1
  call add(b:mail_attachments, {'id': b:mail_attach_seq, 'path': p, 'inline': 0})
  call mail#_append_footer_line(b:mail_attach_seq, fnamemodify(p, ':t'))
  return 1
endfunction

" Inline image: register the file and return its id (for the '[img id]' marker).
" Unlike attachments these don't go in the footer — the marker lives in the body.
function! mail#_register_inline(path) abort
  let p = fnamemodify(expand(a:path), ':p')
  if !filereadable(p)
    echohl ErrorMsg | echom 'mail: file not readable: ' . a:path | echohl None
    return 0
  endif
  if !exists('b:mail_attachments')
    let b:mail_attachments = []
    let b:mail_attach_seq  = 0
  endif
  let b:mail_attach_seq += 1
  call add(b:mail_attachments, {'id': b:mail_attach_seq, 'path': p, 'inline': 1})
  return b:mail_attach_seq
endfunction

function! mail#_is_image(path) abort
  return fnamemodify(a:path, ':e') =~? '^\%(png\|jpe\?g\|gif\|bmp\|webp\|tiff\?\|heic\)$'
endfunction

" Save clipboard image *data* (e.g. a screenshot) to a temp PNG; '' if none.
" macOS uses built-in osascript (coerce the clipboard to PNG) — no extra tools.
" Linux uses wl-paste / xclip (no universal built-in there).
function! mail#_clipboard_image() abort
  let tmp = tempname() . '.png'
  if has('mac')
    let script = join([
          \ 'try',
          \ '  set png to the clipboard as «class PNGf»',
          \ 'on error',
          \ '  return',
          \ 'end try',
          \ 'set fh to open for access (POSIX file "' . tmp . '") with write permission',
          \ 'set eof fh to 0',
          \ 'write png to fh',
          \ 'close access fh',
          \ ], "\n")
    call system('osascript', script)
  elseif executable('wl-paste')
    call system('wl-paste --type image/png > ' . shellescape(tmp) . ' 2>/dev/null')
  elseif executable('xclip')
    call system('xclip -selection clipboard -t image/png -o > ' . shellescape(tmp) . ' 2>/dev/null')
  else
    return ''
  endif
  if filereadable(tmp) && getfsize(tmp) > 0
    return tmp
  endif
  call delete(tmp)
  return ''
endfunction

" <leader>p — insert inline image(s) from the clipboard: raw image data
" (screenshot) or copied image file(s). All-or-nothing: if any clipboard file
" isn't an image, warn and add nothing. Each image inserts an '[img id]' marker.
function! mail#paste_image() abort
  if !exists('b:mail_compose_to')
    echohl ErrorMsg | echom 'mail: not a compose buffer' | echohl None
    return
  endif
  let data = mail#_clipboard_image()
  if data !=# ''
    let imgs = [data]
  else
    let files = mail#_clipboard_files()
    if empty(files)
      echohl WarningMsg | echom 'mail: no image in clipboard' | echohl None
      return
    endif
    for f in files
      if !mail#_is_image(f)
        echohl ErrorMsg
        echom 'mail: not an image: ' . fnamemodify(f, ':t') . ' — <leader>p needs all images (use <leader>a)'
        echohl None
        return
      endif
    endfor
    let imgs = files
  endif
  let markers = []
  for img in imgs
    let id = mail#_register_inline(img)
    if id > 0 | call add(markers, '[img ' . id . ']') | endif
  endfor
  if !empty(markers)
    execute 'normal! a' . join(markers, ' ')
    echo 'Inserted ' . len(markers) . ' inline image(s)'
  endif
endfunction

" Inline images referenced by surviving '[img id]' markers in the body:
" returns [[id, path], …] for entries registered as inline.
function! mail#_inline_images(body_lines) abort
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

" Append '[id] name' to the trailing Attachments: footer (creating it if none).
function! mail#_append_footer_line(id, name) abort
  let entry = '[' . a:id . '] ' . a:name
  let fstart = -1
  for i in range(1, line('$'))
    if getline(i) =~# '^Attachments:\s*$' | let fstart = i | endif
  endfor
  if fstart < 0
    call append(line('$'), ['', 'Attachments:', entry])
  else
    let last = fstart
    let i = fstart + 1
    while i <= line('$') && getline(i) =~# '^\[\d\+\] '
      let last = i | let i += 1
    endwhile
    call append(last, entry)
  endif
endfunction

" Split a compose body into (body without the Attachments: footer, [paths]).
" Surviving footer ids are resolved against b:mail_attachments; the footer and
" any blank lines before it are removed so they aren't sent as literal text.
function! mail#_split_attachments(body_lines) abort
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

" :Attach {paths…} / <leader>A — attach file(s) by path (globs expanded).
function! mail#attach(...) abort
  if !exists('b:mail_compose_to')
    echohl ErrorMsg | echom 'mail: not a compose buffer' | echohl None
    return
  endif
  let args = copy(a:000)
  if empty(args)
    let p = input('Attach file: ', '', 'file')
    redraw
    if p ==# '' | return | endif
    let args = [p]
  endif
  let added = 0
  for a in args
    let matches = glob(expand(a), 0, 1)
    if empty(matches)
      echohl WarningMsg | echom 'mail: no file matches: ' . a | echohl None
      continue
    endif
    for m in matches
      if mail#_register_attachment(m) | let added += 1 | endif
    endfor
  endfor
  if added > 0 | echo 'Attached ' . added . ' file(s)' | endif
endfunction

" <leader>a — attach file(s) copied to the system clipboard.
function! mail#attach_clipboard() abort
  if !exists('b:mail_compose_to')
    echohl ErrorMsg | echom 'mail: not a compose buffer' | echohl None
    return
  endif
  let files = mail#_clipboard_files()
  if empty(files)
    echohl WarningMsg | echom 'mail: no file(s) in clipboard' | echohl None
    return
  endif
  let added = 0
  for f in files
    if mail#_register_attachment(f) | let added += 1 | endif
  endfor
  if added > 0 | echo 'Attached ' . added . ' file(s) from clipboard' | endif
endfunction

" File paths currently on the system clipboard (Finder-copied files etc.).
" macOS reads ALL file URLs from the pasteboard via the AppKit bridge (JXA) —
" built-in, and handles multiple files (plain osascript «class furl» only ever
" returns one). Linux uses wl-paste / xclip text/uri-list.
function! mail#_clipboard_files() abort
  if has('mac')
    let js = join([
          \ "ObjC.import('AppKit');",
          \ "var pb=$.NSPasteboard.generalPasteboard;",
          \ "var cls=$.NSMutableArray.alloc.init; cls.addObject($.NSURL.class);",
          \ "var arr=pb.readObjectsForClassesOptions(cls,$.NSDictionary.dictionary);",
          \ "var out=[];",
          \ "if(arr && !arr.isNil()){for(var i=0;i<arr.count;i++){var u=arr.objectAtIndex(i); if(u.isFileURL) out.push(ObjC.unwrap(u.path));}}",
          \ "out.join('\\n');",
          \ ], "\n")
    let raw = system('osascript -l JavaScript', js)
  elseif executable('wl-paste')
    let raw = system('wl-paste --type text/uri-list 2>/dev/null')
  elseif executable('xclip')
    let raw = system('xclip -selection clipboard -t text/uri-list -o 2>/dev/null')
  else
    return []
  endif
  let files = []
  for l in split(raw, "\n")
    let l = substitute(l, '\r$', '', '')
    if l =~# '^file://'
      let l = substitute(l, '^file://[^/]*', '', '')                       " scheme+host
      let l = substitute(l, '%\(\x\x\)', '\=nr2char(str2nr(submatch(1), 16))', 'g')  " %20 etc.
    endif
    if l !=# '' && filereadable(l)
      call add(files, l)
    endif
  endfor
  return files
endfunction

" g:mail_from: Full From header, e.g. 'Your Name <you@gmail.com>'. Set in vimrc.
let g:mail_from = get(g:, 'mail_from', '')

function! mail#send() abort
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
  let split = mail#_split_attachments(body_lines)
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
  for pair in mail#_inline_images(body_lines)
    call add(msg, 'X-Mail-Inline: ' . pair[0] . ' ' . pair[1])
  endfor
  let msg += [''] + body_lines

  let tmpfile = tempname()
  call writefile(msg, tmpfile)

  " Derive 'python3 /path/to/mail_store.py' from g:mail_store_cmd
  let py_cmd   = substitute(g:mail_store_cmd, '\s\+ingest-stdin$', '', '')
  let orig_arg = exists('b:mail_compose_orig_dir')
        \ ? ' ' . shellescape(b:mail_compose_orig_dir) : ' ""'
  let sent_dir = mail#_normdir(get(g:, 'mail_root', '~/Mail')) . '/sent'
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

" ---- fetch ----------------------------------------------------------------

function! mail#_snapshot_dirs(dir) abort
  let result = {}
  for path in glob(a:dir . '/*', 0, 1)
    if isdirectory(path) && fnamemodify(path, ':t') !~# '^\.'
      let result[path] = 1
    endif
  endfor
  return result
endfunction

" Locate this plugin's own root (autoload/ -> repo root) so mail_store.py is
" found wherever the repo was cloned, with no hardcoded path.
let s:plugin_root = expand('<sfile>:p:h:h')

" g:mail_python:   python3 interpreter (resolved from PATH; override in vimrc).
" g:mail_store_py: path to mail_store.py (defaults to the copy in this repo).
let g:mail_python = get(g:, 'mail_python',
      \ exepath('python3') !=# '' ? exepath('python3') : 'python3')
let g:mail_store_py = get(g:, 'mail_store_py', s:plugin_root . '/mail_store.py')

" g:mail_store_cmd: base command used to build the --mda arg for fetchmail.
" Derived from the two above; override directly if you need something custom.
let g:mail_store_cmd = get(g:, 'mail_store_cmd',
      \ g:mail_python . ' ' . g:mail_store_py . ' ingest-stdin')

" Runs fetchmail asynchronously; prompts for target inbox dir (default:
" current index buffer's dir, or ~/Mail/inbox). Passes --mda on the CLI so
" each inbox can be fetched into a different directory without editing
" ~/.fetchmailrc. New-mail count is echoed on completion; no quickfix.
function! mail#fetch() abort
  if s:fetch_job isnot v:null && job_status(s:fetch_job) ==# 'run'
    echo 'A fetch is already in progress'
    return
  endif
  if !mail#_ok_to_refresh('Fetch')
    return
  endif
  let default_dir = exists('b:mail_dir') ? b:mail_dir : mail#_resolve_mailbox('inbox')
  let default_name = fnamemodify(default_dir, ':t')
  let chosen = mail#_prompt_mailbox('Fetch into mailbox [' . default_name . ']', '')
  let target = chosen ==# '' ? default_dir : mail#_resolve_mailbox(chosen)
  if !isdirectory(target)
    echohl ErrorMsg | echom 'Not a directory: ' . target | echohl None
    return
  endif
  let s:fetch_dir = target
  let s:fetch_before = mail#_snapshot_dirs(target)
  let mda = g:mail_store_cmd . ' ' . shellescape(target)
  echo 'Fetching into ' . target . ' ...'
  let s:fetch_job = job_start(['fetchmail', '-v', '-N', '--mda', mda], {
        \ 'exit_cb': 'mail#_fetch_exit_cb',
        \ })
endfunction

function! mail#_fetch_exit_cb(job, status) abort
  let after = mail#_snapshot_dirs(s:fetch_dir)
  let new_dirs = []
  for path in keys(after)
    if !has_key(s:fetch_before, path)
      call add(new_dirs, path)
    endif
  endfor

  " fetchmail exit 1 = no messages (normal); anything else is a real error
  if a:status != 0 && a:status != 1
    echohl ErrorMsg
    echom 'fetchmail exited with status ' . a:status
    echohl None
  endif

  if empty(new_dirs)
    echom 'No new mail.'
  else
    echom len(new_dirs) . ' new message(s) in ' . fnamemodify(s:fetch_dir, ':~')
  endif

  if has_key(s:index_bufnrs, s:fetch_dir) && bufexists(s:index_bufnrs[s:fetch_dir])
    let winid = bufwinid(s:index_bufnrs[s:fetch_dir])
    if winid != -1
      let cur = win_getid()
      call win_gotoid(winid)
      call mail#refresh()
      call win_gotoid(cur)
    endif
  endif
endfunction
