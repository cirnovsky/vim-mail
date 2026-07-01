" The link map L: {id -> {mailbox-name -> 1}} — which mailboxes label each
" message. Built from readdirs (entry NAMES only, no meta reads) so it's cheap
" enough to rebuild at :Mail and before each disk operation. It is the refcount
" source: "is this the last label?" is an in-memory lookup, not a filesystem
" walk per delete.
"
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

let s:map = {}

" Rebuild L from disk. Scans every mailbox under g:mail_root (skipping the hidden
" content store) for its entry names. Cheap: readdir(), no stat/meta reads.
function! mail#link#rebuild() abort
  let s:map = {}
  let root = mail#mailbox#_normdir(get(g:, 'mail_root', '~/Mail'))
  for mbox in glob(root . '/*', 0, 1)
    if !isdirectory(mbox) | continue | endif
    let name = fnamemodify(mbox, ':t')
    if name ==# '.store' | continue | endif
    for id in readdir(mbox)
      if id[0] ==# '.' | continue | endif
      if !has_key(s:map, id) | let s:map[id] = {} | endif
      let s:map[id][name] = 1
    endfor
  endfor
  return s:map
endfunction

function! mail#link#map() abort
  return s:map
endfunction

" How many mailboxes OTHER than exclude_name currently label <id>, per the last
" rebuild(). Delete decisions call rebuild() first, then ask this to learn
" whether dropping *this* mailbox's label leaves the message stranded.
function! mail#link#count_others(id, exclude_name) abort
  let labels = get(s:map, a:id, {})
  let n = len(labels)
  if has_key(labels, a:exclude_name) | let n -= 1 | endif
  return n
endfunction

" Names of the mailboxes labelling <id> (per the last rebuild()).
function! mail#link#labels(id) abort
  return sort(keys(get(s:map, a:id, {})))
endfunction
