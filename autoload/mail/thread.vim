" Thread reconstruction: the cross-mailbox message-id index.
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

let s:msgid_index     = {}   " cross-mailbox cache; invalidated on refresh/write
let s:msgid_index_ok  = 0

" Build {stripped-message-id → dir-path} across ALL mailboxes under g:mail_root.
" For the current mailbox, entries are already in b:mail_entries (no disk I/O).
" For other mailboxes, reads each message's meta file (fast: 6 lines vs full
" raw.eml). Messages whose meta has no Message-ID are skipped (no raw.eml
" fallback — too expensive at scale).
function! mail#thread#_build_msgid_index() abort
  if s:msgid_index_ok
    return s:msgid_index
  endif
  let index = {}
  let root = mail#mailbox#_normdir(get(g:, 'mail_root', '~/Mail'))
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

" Drop the cached msgid index; rebuilt lazily on next thread lookup.
function! mail#thread#invalidate() abort
  let s:msgid_index_ok = 0
endfunction
