" Staged actions on the index: marks, read/unread, delete (:w), move.
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

function! mail#actions#_set_mark_opfunc() abort
  let &operatorfunc = 'mail#actions#ToggleMarkOperator'
  return 'g@'
endfunction

function! mail#actions#clear_marks() abort
  call mail#index#_patch_lines({}, {r, m -> [r, 0]})
endfunction

function! mail#actions#ToggleMarkOperator(type) abort
  let targets    = {}
  let id_to_idx  = mail#index#_id_to_idx()
  for ln in range(line("'["), line("']"))
    let l   = getline(ln)
    let tab = stridx(l, "\t")
    if tab >= 0
      let eidx = get(id_to_idx, l[:tab - 1], -1)
      if eidx >= 0 | let targets[eidx] = 1 | endif
    endif
  endfor
  call mail#index#_patch_lines(targets, {r, m -> [r, !m]})
endfunction

" BufWriteCmd handler: dd/d3j/:g//d etc. only remove lines from the
" buffer; this is where that staged delete actually hits disk. Messages
" deleted from a normal mailbox move to ~/Mail/trash (recoverable);
" deleting from inside ~/Mail/trash itself is permanent.
function! mail#actions#write() abort
  " Parse surviving buffer lines into {id: read_bool}
  let buf_state = {}
  for l in getline(1, '$')
    let tab = stridx(l, "\t")
    if tab > 0
      let buf_state[l[:tab - 1]] = l[tab + 1] !=# 'N'
    endif
  endfor

  let trash_root = mail#mailbox#_normdir(get(g:, 'mail_root', '~/Mail')) . '/trash'
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
  call mail#index#refresh()
  setlocal nomodified
endfunction

" Three-way confirm for the staged-edit guard. Returns 'save' | 'discard' |
" 'cancel'. Wrapped as its own function so tests can stub it (interactive
" confirm() can't be driven in batch mode).
function! mail#actions#_confirm(msg) abort
  let n = confirm(a:msg, "&Save\n&Discard\n&Cancel", 3)
  return n == 1 ? 'save' : (n == 2 ? 'discard' : 'cancel')
endfunction

" Disk actions that refresh the index (move, fetch) rebuild the buffer from disk,
" discarding staged-but-unwritten edits (dd deletes, s/S read toggles). Guard
" them: when the buffer has staged changes, ask. 1 = proceed (after optionally
" writing them), 0 = abort. NOTE: 'Save' calls mail#actions#write(), which rebuilds
" b:mail_entries — callers that pre-resolved targets must re-resolve by id after.
function! mail#actions#_ok_to_refresh(action) abort
  if !&modified
    return 1
  endif
  let choice = mail#actions#_confirm(a:action
        \ . ' will refresh the index and lose unwritten changes. Save them first?')
  if choice ==# 'save'
    call mail#actions#write()
    return 1
  endif
  return choice ==# 'discard'
endfunction

function! mail#actions#move() abort
  " Capture targets by id BEFORE the guard — a 'Save' there rebuilds b:mail_entries.
  let target_ids = map(mail#index#_target_indexes(), 'b:mail_entries[v:val].id')
  if empty(target_ids)
    return
  endif
  if !mail#actions#_ok_to_refresh('Move')
    return
  endif
  " Re-resolve ids → current indices (b:mail_entries may have just been rebuilt).
  let id2idx = mail#index#_id_to_idx()
  let idxs = []
  for tid in target_ids
    if has_key(id2idx, tid) | call add(idxs, id2idx[tid]) | endif
  endfor
  if empty(idxs)
    return
  endif
  let dest_dir = mail#mailbox#_prompt_mailbox('Move to mailbox', '')
  if dest_dir ==# ''
    return
  endif
  let dest_dir = mail#mailbox#_resolve_mailbox(dest_dir)
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
  call mail#index#refresh()
  if moved > 0
    echom 'Moved ' . moved . ' message(s) to ' . dest_name
  endif
  if !empty(failed)
    echohl ErrorMsg
    echom 'mail: could not move ' . len(failed) . ' message(s): ' . join(failed, '; ')
    echohl None
  endif
endfunction

function! mail#actions#read(read) abort
  let targets = {}
  for idx in mail#index#_target_indexes() | let targets[idx] = 1 | endfor
  call mail#index#_patch_lines(targets, {r, m -> [a:read, m]})
endfunction

function! mail#actions#_set_read(idx, read) abort
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
          \ mail#index#_format_line(e.id, e.meta, a:read, l[tab + 2] ==# '*'))
  endif
  call mail#index#_sync_modified()
endfunction
