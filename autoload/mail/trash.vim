" TRASH: a virtual, read-only view of orphaned canons — messages whose LAST
" mailbox label was dropped by dd, so no mailbox references them. Nothing is
" written on delete (dd stays a pure unlink); this view is rebuilt from a full
" .store scan on every entry. Recover by yanking a line (yy) and pasting it into
" a real mailbox buffer — the normal paste path (mail#actions#_label) links the
" orphan canon back in, and it leaves TRASH on the next scan. Orphans live until
" a future :MailGC permanently empties them. No memory of the old location.
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

let s:trash_bufnr = -1
let s:trash_name  = 'mail://TRASH'

function! mail#trash#name() abort
  return s:trash_name
endfunction

" Every .store canon whose id is not a symlink-name in any mailbox dir. The
" referenced set is the union of entry NAMES across mailboxes — a label's
" filename IS its canon id — so no readlink is needed, just directory listings.
" O(whole store), so it's scanned lazily on entry, never preloaded.
function! mail#trash#_orphans() abort
  let root  = mail#mailbox#root()
  let store = root . '/.store'
  let referenced = {}
  for path in glob(root . '/*', 0, 1)
    if isdirectory(path) && fnamemodify(path, ':t') !~# '^\.'
      for e in glob(path . '/*', 0, 1)
        let referenced[fnamemodify(e, ':t')] = 1
      endfor
    endif
  endfor
  let orphans = []
  for c in glob(store . '/*', 0, 1)
    let id = fnamemodify(c, ':t')
    if isdirectory(c) && id !~# '^\.' && !has_key(referenced, id)
      call add(orphans, id)
    endif
  endfor
  call sort(orphans)
  call reverse(orphans)                 " newest-first (id = <UTC-timestamp>_<hash>)
  return orphans
endfunction

" Open (or return to) the TRASH view and (re)scan it.
function! mail#trash#open() abort
  if s:trash_bufnr > 0 && bufexists(s:trash_bufnr) && bufname(s:trash_bufnr) ==# s:trash_name
    let winid = bufwinid(s:trash_bufnr)
    if winid != -1 | call win_gotoid(winid) | else | execute 'buffer ' . s:trash_bufnr | endif
  else
    noautocmd enew
    setlocal buftype=nofile bufhidden=hide noswapfile nowrap nobuflisted
    silent! noautocmd execute 'file ' . fnameescape(s:trash_name)
    let s:trash_bufnr = bufnr('%')
  endif
  setlocal filetype=mail-trash
  call mail#trash#refresh()
endfunction

" Rescan orphans and repaint. Each entry's dir is the canon itself
" (.store/<id>), so <CR>/o/reply/forward read straight from it (view/compose use
" b:mail_entries[idx].dir). Read-only: nomodifiable after the paint.
function! mail#trash#refresh() abort
  if bufname('%') !=# s:trash_name | return | endif
  let store = mail#mailbox#root() . '/.store'
  let entries = []
  for id in mail#trash#_orphans()
    let dir = store . '/' . id
    call add(entries, {'dir': dir, 'id': id,
          \ 'read': filereadable(dir . '/.read'), 'meta': mail#index#_read_meta(dir)})
  endfor
  let b:mail_entries = entries
  let lines = []
  for e in entries
    call add(lines, mail#index#_format_line(e.id, e.meta, e.read))
  endfor
  setlocal modifiable
  silent! 1,$delete _
  if !empty(lines) | call setline(1, lines) | endif
  setlocal nomodifiable nomodified
endfunction
