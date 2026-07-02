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

" Find a mailbox (other than exclude_dir) that physically holds an entry named
" <id> — the source of a pasted, not-yet-migrated legacy message.
function! mail#actions#_find_source(id, exclude_dir) abort
  let root = mail#mailbox#_normdir(get(g:, 'mail_root', '~/Mail'))
  let excl = mail#mailbox#_normdir(a:exclude_dir)
  for mbox in glob(root . '/*', 0, 1)
    if !isdirectory(mbox) || fnamemodify(mbox, ':t') ==# '.store' | continue | endif
    if mail#mailbox#_normdir(mbox) ==# excl | continue | endif
    if getftype(mbox . '/' . a:id) !=# '' | return mbox . '/' . a:id | endif
  endfor
  return ''
endfunction

" Link ids present in the buffer but absent from the disk baseline — lines
" pasted from another mailbox's index (native yy+p = copy, dd+p = move once the
" source buffer is also written). Each must resolve to a canonical object (or a
" legacy source dir, migrated on touch); a line that resolves to nothing (stray
" yank / garbage) is ignored. Returns the count linked.
function! mail#actions#_add_pasted_labels(buf_ids, baseline, mbox_dir) abort
  let store = mail#actions#_store_root()
  let added = 0
  for id in a:buf_ids
    if has_key(a:baseline, id) | continue | endif
    if getftype(a:mbox_dir . '/' . id) !=# '' | continue | endif   " already linked here
    if isdirectory(store . '/' . id)
      if mail#actions#_make_link(id, a:mbox_dir) == 0 | let added += 1 | endif
    else
      " Maybe a legacy real dir for this id lives in another mailbox — migrate it
      " into the store, then link. Otherwise the id is unresolvable: ignore it.
      let src = mail#actions#_find_source(id, a:mbox_dir)
      if src !=# ''
        call mail#actions#_ensure_canonical(src)
        if mail#actions#_make_link(id, a:mbox_dir) == 0 | let added += 1 | endif
      endif
    endif
  endfor
  return added
endfunction

" Commit one staged delete of <entry> from mailbox <mbox_dir>.
"   symlink label  -> unlink; if it was the last label, fall to trash (or, when
"                     already in trash, permanently rm the canonical bytes).
"   legacy real dir -> old physical semantics (rename to trash / rf in trash),
"                     so pre-content-store mail still deletes safely.
function! mail#actions#_delete_entry(entry, mbox_dir, trash_root) abort
  let id  = a:entry.id
  let dir = a:entry.dir
  let in_trash = (mail#mailbox#_normdir(a:mbox_dir) ==# a:trash_root)

  if getftype(dir) !=# 'link'
    " Legacy real directory (not yet migrated into the store).
    if in_trash
      call delete(dir, 'rf')
    else
      if !isdirectory(a:trash_root) | call mkdir(a:trash_root, 'p') | endif
      call rename(dir, a:trash_root . '/' . id)
    endif
    return
  endif

  " Symlink label: drop it, then decide by remaining label count. count_others
  " reads the link map snapshot rebuilt at the top of write(); it excludes this
  " mailbox, so the just-done unlink doesn't affect the answer.
  call mail#actions#_unlink(dir)
  if mail#link#count_others(id, fnamemodify(a:mbox_dir, ':t')) > 0
    " Still labelled by another mailbox — the message survives; no trash.
    return
  endif
  if in_trash
    call delete(mail#actions#_store_root() . '/' . id, 'rf')   " permanent
  else
    call mail#actions#_make_link(id, a:trash_root)             " recoverable
  endif
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
  call mail#index#refresh()
  for bnr in bufs
    if bnr != cur | call mail#index#_resync_baseline(bnr) | endif
  endfor
endfunction

" Ensure <dir> is a content-store symlink. A store symlink is left as-is; a
" legacy real message dir is moved into <root>/.store/<id> and replaced by a
" symlink (migrate-on-touch), so copy/link ops can share one canonical copy
" instead of duplicating bytes.
function! mail#actions#_ensure_canonical(dir) abort
  if getftype(a:dir) ==# 'link'
    return
  endif
  let id    = fnamemodify(a:dir, ':t')
  let mbox  = fnamemodify(a:dir, ':h')
  let store = mail#actions#_store_root()
  let canon = store . '/' . id
  if isdirectory(canon)
    " Canon already known (from another mailbox) — drop this legacy duplicate.
    call delete(a:dir, 'rf')
  else
    if !isdirectory(store) | call mkdir(store, 'p') | endif
    call rename(a:dir, canon)
  endif
  call mail#actions#_make_link(id, mbox)
endfunction

" Move and copy are native buffer gestures now, committed on :w:
"   dd here + p in another mailbox buffer  = move  (source unlinked, dest linked)
"   yy      + p                            = copy  (source kept, dest linked)
" Both reconcile through write() -> _add_pasted_labels (the add) + the delete
" pass (the drop). There is no :M/:Move/:Copy command; `-` opens the launcher so
" opening the destination to paste into is one keystroke.

" :MailMigrate — convert the existing flat store under g:mail_root into the
" content-store layout (.store/<id> + symlinks). Shells out to the Python
" migrate_store (safe + resumable), then rebuilds L and repaints the index.
function! mail#actions#migrate_store() abort
  let root = mail#mailbox#_normdir(get(g:, 'mail_root', '~/Mail'))
  if !isdirectory(root)
    echohl ErrorMsg | echom 'mail: no such mail root: ' . root | echohl None
    return
  endif
  if confirm("Migrate " . root . " to the content-store layout?\n"
        \ . "(.store/<id> + symlinks; non-destructive & resumable)",
        \ "&Yes\n&No", 2) != 1
    echo 'Migration cancelled'
    return
  endif
  echo 'Migrating ' . root . ' ...'
  let out = system(g:mail_python . ' ' . shellescape(g:mail_store_py)
        \ . ' migrate-store ' . shellescape(root))
  if v:shell_error
    echohl ErrorMsg | echom 'mail: migration failed: ' . trim(out) | echohl None
    return
  endif
  call mail#link#rebuild()
  if exists('b:mail_dir') | call mail#index#refresh() | endif
  echom 'Migration done — ' . trim(out)
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
