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

" Commit one staged delete of <entry> from mailbox <mbox_dir>. Drop-label
" semantics (see CLAUDE.md "delete lattice"):
"   unlink the label; last label -> fall to trash; last label AND in trash ->
"   the canon is left orphaned in .store (bytes KEPT, never rm'd — the delete
"   stays undoable; a future :MailGC frees orphans).
function! mail#actions#_delete_entry(entry, mbox_dir, trash_root) abort
  let id  = a:entry.id
  let dir = a:entry.dir
  let in_trash = (mail#mailbox#_normdir(a:mbox_dir) ==# a:trash_root)

  " Drop this mailbox's label. Bytes are NEVER destroyed — the canon in .store
  " stays; count_others reads the link-map snapshot from the top of write() (it
  " excludes this mailbox, so the just-done unlink doesn't skew the answer).
  call mail#actions#_unlink(dir)
  if mail#link#count_others(id, fnamemodify(a:mbox_dir, ':t')) > 0
    " still labelled by another mailbox — survives; no trash
    return
  endif
  if !in_trash
    call mail#actions#_make_link(id, a:trash_root)   " last label -> trash (recoverable)
  endif
  " last label AND in trash -> the canon is now an orphan in .store (kept; a
  " future :MailGC frees orphans). We never rm bytes here.
endfunction

" BufWriteCmd handler. `:w` commits the staged edits of the current index buffer
" AND every other modified index buffer — one write reconciles all mailboxes.
"
" Reconciliation runs in two phases across all those buffers, because a
" dd-here / paste-there move must add the destination label BEFORE dropping the
" source one: otherwise the refcount sees the source as the message's last label
" and sends it to trash. Phase 1 does read-marks + pasted-label ADDS and collects
" the deletes; phase 2 executes the deletes once every add is on disk.
function! mail#actions#write() abort
  let cur  = bufnr('%')
  let bufs = [cur]
  for bnr in mail#index#_index_buffers()
    if bnr != cur && getbufvar(bnr, '&modified') | call add(bufs, bnr) | endif
  endfor

  let trash_root = mail#mailbox#root() . '/trash'
  let pending = []      " [ [entry, mail_dir], ... ] deletes deferred to phase 2
  let added   = 0

  " --- Phase 1: reconcile reads + add pasted labels; collect deletes ---
  for bnr in bufs
    let mail_dir = getbufvar(bnr, 'mail_dir', '')
    if mail_dir ==# '' | continue | endif
    let buf_state = {}
    for l in getbufline(bnr, 1, '$')
      let tab = stridx(l, "\t")
      if tab > 0 | let buf_state[l[:tab - 1]] = l[tab + 1] !=# 'N' | endif
    endfor
    let baseline = {}
    for entry in getbufvar(bnr, 'mail_entries', [])
      let baseline[entry.id] = 1
      if !has_key(buf_state, entry.id)
        call add(pending, [entry, mail_dir])                 " staged delete
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
    let added += mail#actions#_add_pasted_labels(keys(buf_state), baseline, mail_dir)
  endfor

  " --- Phase 2: execute deletes; the link map now reflects every add, so a
  "     moved message's dest label is counted and the source isn't trashed. ---
  call mail#link#rebuild()
  for [entry, mail_dir] in pending
    call mail#actions#_delete_entry(entry, mail_dir, trash_root)
  endfor

  if len(pending) > 0 | echom 'Deleted ' . len(pending) . ' message(s)' | endif
  if added > 0        | echom 'Linked ' . added . ' message(s)' | endif

  " Refresh the current buffer (it ends with nomodified); resync the others'
  " baselines + clear &modified.
  " Post-commit, every committed buffer already equals disk, so re-baseline
  " WITHOUT rewriting lines (no destroy-recreate, no undolevels reset) — this is
  " what lets `u` survive `:w`.
  for bnr in bufs
    call mail#index#_resync_baseline(bnr)
  endfor
endfunction

" Move and copy are native buffer gestures now, committed on :w:
"   dd here + p in another mailbox buffer  = move  (source unlinked, dest linked)
"   yy      + p                            = copy  (source kept, dest linked)
" Both reconcile through write() -> _add_pasted_labels (the add) + the delete
" pass (the drop). There is no :M/:Move/:Copy command; `-` opens the launcher so
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
