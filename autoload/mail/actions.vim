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

" --- content store: labels are symlinks <mailbox>/<id> -> ../.store/<id> ---

function! mail#actions#_store_root() abort
  return mail#mailbox#root() . '/.store'
endfunction

" Add a mailbox label: <dest_dir>/<id> -> ../.store/<id> (relative, so the tree
" stays relocatable). Vim has no native symlink(), so shell out to `ln -s`.
" Returns 0 on success, nonzero on failure.
function! mail#actions#_make_link(id, dest_dir) abort
  if !isdirectory(a:dest_dir)
    call mkdir(a:dest_dir, 'p')
  endif
  call system('ln -s ' . shellescape('../.store/' . a:id) . ' '
        \ . shellescape(a:dest_dir . '/' . a:id))
  return v:shell_error
endfunction

" Remove a mailbox label. delete() with NO flags unlinks a file/symlink; it
" never follows a symlink into its target, so dropping a label can never rf
" through into .store and destroy the shared canonical bytes.
function! mail#actions#_unlink(dir) abort
  call delete(a:dir)
endfunction

" Link ids present in the buffer but absent from the disk baseline — lines
" pasted from another mailbox's index (native yy+p = copy, dd+p = move once the
" source buffer is also written). Each must resolve to a canonical object in
" .store; a line that resolves to nothing (stray yank / garbage) is ignored.
" Returns the count linked.
function! mail#actions#_add_pasted_labels(buf_ids, baseline, mbox_dir) abort
  let store = mail#actions#_store_root()
  let added = 0
  for id in a:buf_ids
    if has_key(a:baseline, id) | continue | endif
    if getftype(a:mbox_dir . '/' . id) !=# '' | continue | endif   " already linked here
    if isdirectory(store . '/' . id)
      if mail#actions#_make_link(id, a:mbox_dir) == 0 | let added += 1 | endif
    endif
  endfor
  return added
endfunction

" BufWriteCmd handler. `:w` commits the staged edits of the current index buffer
" AND every other modified index buffer — one write reconciles all mailboxes.
"
" One pass per buffer, order-independent: for each mailbox, drop labels for lines
" removed from the buffer (unlink only — NO trash, NO refcount), reconcile the
" read-mark of lines still present, and link lines pasted from another mailbox.
" A delete just removes this mailbox's symlink; if it was the message's last
" label the canon is left orphaned in .store (bytes kept — a future :MailGC frees
" it). Move (dd+p) = unlink source + link dest; the canon lives in .store the
" whole time, and with no trash/refcount there is nothing to sequence.
function! mail#actions#write() abort
  let cur  = bufnr('%')
  let bufs = [cur]
  for bnr in mail#index#_index_buffers()
    if bnr != cur && getbufvar(bnr, '&modified') | call add(bufs, bnr) | endif
  endfor

  let added   = 0
  let deleted = 0

  for bnr in bufs
    let mail_dir = getbufvar(bnr, 'mail_dir', '')
    if mail_dir ==# '' | continue | endif

    " {id -> read?} for every buffer line.
    let buf_state = {}
    for l in getbufline(bnr, 1, '$')
      let tab = stridx(l, "\t")
      if tab > 0 | let buf_state[l[:tab - 1]] = l[tab + 1] !=# 'N' | endif
    endfor

    " Baseline entry gone from the buffer -> drop this label (unlink, no trash).
    " Still present -> reconcile its read-mark to the shared canon .read.
    let baseline = {}
    for entry in getbufvar(bnr, 'mail_entries', [])
      let baseline[entry.id] = 1
      if !has_key(buf_state, entry.id)
        call mail#actions#_unlink(entry.dir)
        let deleted += 1
      else
        let buf_read  = buf_state[entry.id]
        let disk_read = filereadable(entry.dir . '/.read')
        if buf_read && !disk_read
          call writefile([], entry.dir . '/.read')
        elseif !buf_read && disk_read
          call delete(entry.dir . '/.read')
        endif
      endif
    endfor

    " Buffer ids absent from the baseline are pasted from another mailbox.
    let added += mail#actions#_add_pasted_labels(keys(buf_state), baseline, mail_dir)
  endfor

  if deleted > 0 | echom 'Deleted ' . deleted . ' message(s)' | endif
  if added > 0   | echom 'Linked '  . added   . ' message(s)' | endif

  " Post-commit each buffer already equals disk; re-baseline WITHOUT rewriting
  " lines (no destroy-recreate, no undolevels reset) so `u` survives `:w`.
  for bnr in bufs
    call mail#index#_resync_baseline(bnr)
  endfor
endfunction

" Move and copy are native buffer gestures now, committed on :w:
"   dd here + p in another mailbox buffer  = move  (source unlinked, dest linked)
"   yy      + p                            = copy  (source kept, dest linked)
" Both reconcile through write() -> _add_pasted_labels (the add) + an unlink
" (the drop). There is no :M/:Move/:Copy command; `-` opens the launcher so
" opening the destination to paste into is one keystroke.

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
