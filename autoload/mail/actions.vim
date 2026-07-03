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

" A label IS a symlink <mbox_dir>/<id> -> ../.store/<id>. Deleting a message and
" pasting one in are the two directions of the SAME operation: set message <id>'s
" membership in mailbox <mbox_dir>.
"   on=1  add the label: `ln -s ../.store/<id>` (relative, so the tree stays
"         relocatable; Vim has no native symlink()). No-op if the label already
"         exists here or <id> resolves to no canon in .store (a stray yank).
"   on=0  drop the label: flagless delete() unlinks the symlink and NEVER follows
"         it into .store, so a drop can't rf through and destroy the shared bytes.
" Returns 1 if it changed disk, 0 for a no-op (redundant add / absent-label drop).
function! mail#actions#_label(id, mbox_dir, on) abort
  let link = a:mbox_dir . '/' . a:id
  let here = getftype(link) !=# ''
  if a:on
    if here | return 0 | endif
    if !isdirectory(mail#actions#_store_root() . '/' . a:id) | return 0 | endif
    if !isdirectory(a:mbox_dir) | call mkdir(a:mbox_dir, 'p') | endif
    call system('ln -s ' . shellescape('../.store/' . a:id) . ' ' . shellescape(link))
    return v:shell_error == 0 ? 1 : 0
  endif
  if !here | return 0 | endif
  call delete(link)
  return 1
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

    " deletion
    let baseline = {}
    for entry in getbufvar(bnr, 'mail_entries', [])
      let baseline[entry.id] = 1
      if !has_key(buf_state, entry.id)
        let deleted += mail#actions#_label(entry.id, mail_dir, 0)
      endif
    endfor

    " addition
    for id in keys(buf_state)
      if !has_key(baseline, id)
        let added += mail#actions#_label(id, mail_dir, 1)
      endif
    endfor

    " resolve read state
    for [id, buf_read] in items(buf_state)
      let dir = mail_dir . '/' . id
      if getftype(dir) ==# '' | continue | endif
      let disk_read = filereadable(dir . '/.read')
      if buf_read && !disk_read
        call writefile([], dir . '/.read')
      elseif !buf_read && disk_read
        call delete(dir . '/.read')
      endif
    endfor
  endfor

  let parts = []
  if deleted > 0 | call add(parts, 'Deleted ' . deleted) | endif
  if added > 0   | call add(parts, 'Linked '  . added) | endif
  if !empty(parts) | echom join(parts, ', ') . ' message(s)' | endif

  " Post-commit each buffer already equals disk; re-baseline WITHOUT rewriting
  " lines (no destroy-recreate, no undolevels reset) so `u` survives `:w`.
  for bnr in bufs
    call mail#index#_resync_baseline(bnr)
  endfor
endfunction

" Move and copy are native buffer gestures now, committed on :w:
"   dd here + p in another mailbox buffer  = move  (source unlinked, dest linked)
"   yy      + p                            = copy  (source kept, dest linked)
" Both reconcile through write() -> _label(id, dir, 1) for the paste (add) and
" _label(id, dir, 0) for the source drop. There is no :M/:Move/:Copy command;
" `-` opens the launcher so opening the destination to paste into is one keystroke.

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
