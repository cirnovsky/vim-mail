" Shared test helpers: build a content-store from real .eml fixtures via the
" REAL backend (mail_store.py ingest-stdin) — no hand-shaped canons. Add
" tests/testlib to 'runtimepath' to load: `set rtp+=<repo>/tests/testlib`.
"
" Requires g:mail_python + g:mail_store_py (set by `runtime plugin/mail.vim`).

let s:tests    = expand('<sfile>:p:h:h:h')          " .../tests
let s:fixtures = s:tests . '/fixtures/mail'

" Absolute path to a corpus fixture (name without the .eml suffix).
function! testmail#eml(name) abort
  return s:fixtures . '/' . a:name . '.eml'
endfunction

" Ingest fixture <name>.eml into <root>/<mailbox> via the real backend and
" return the message id (store-dir basename). The same fixture ingested into a
" second mailbox just adds another symlink (dedup) — labels.
function! testmail#ingest(root, mailbox, name) abort
  let mb = a:root . '/' . a:mailbox
  call mkdir(mb, 'p')
  let before = {}
  for e in glob(mb . '/*', 0, 1) | let before[fnamemodify(e, ':t')] = 1 | endfor
  call system(g:mail_python . ' ' . shellescape(g:mail_store_py)
        \ . ' ingest-stdin ' . shellescape(mb)
        \ . ' < ' . shellescape(testmail#eml(a:name)))
  for e in glob(mb . '/*', 0, 1)
    let id = fnamemodify(e, ':t')
    if !has_key(before, id) | return id | endif
  endfor
  throw 'testmail: ingest produced no new entry in ' . mb . ' for ' . a:name
endfunction

" Ingest a message with an arbitrary <subject> (msgid derived from it) into
" <root>/<mailbox> via the real backend. For scenario tests that search the
" subject text (e.g. :g/pat/). Returns the id.
function! testmail#ingest_subject(root, mailbox, subject) abort
  let mb = a:root . '/' . a:mailbox
  call mkdir(mb, 'p')
  let before = {}
  for e in glob(mb . '/*', 0, 1) | let before[fnamemodify(e, ':t')] = 1 | endfor
  let msgid = substitute(a:subject, '[^A-Za-z0-9]', '', 'g')
  let raw = join(['From: X <x@example.com>', 'To: me@example.com',
        \ 'Subject: ' . a:subject, 'Date: Mon, 01 Jun 2026 09:00:00 +0000',
        \ 'Message-ID: <' . msgid . '@example.com>', '', 'body', ''], "\n")
  call system(g:mail_python . ' ' . shellescape(g:mail_store_py)
        \ . ' ingest-stdin ' . shellescape(mb), raw)
  for e in glob(mb . '/*', 0, 1)
    let id = fnamemodify(e, ':t')
    if !has_key(before, id) | return id | endif
  endfor
  throw 'testmail: no new entry for subject ' . a:subject
endfunction

" Declarative store builder. spec = list of dicts:
"   {'name': <fixture>, 'in': [<mailbox>...], 'read': 0|1}
" Ingests each fixture into its first mailbox and links it into the rest;
" 'read' drops the shared .read marker into the canon. Returns {name -> id}.
function! testmail#build(root, spec) abort
  let ids = {}
  for item in a:spec
    let id = ''
    for mb in item.in
      let id = testmail#ingest(a:root, mb, item.name)
    endfor
    if get(item, 'read', 0)
      call writefile([], a:root . '/.store/' . id . '/.read')
    endif
    let ids[item.name] = id
  endfor
  return ids
endfunction

" --- buffer/utility helpers shared by the index suites ---

" Wipe every index buffer (they're named by mailbox basename, so leftovers would
" collide on name and leave the next buffer unnamed, breaking :w). Call between tests.
function! testmail#wipe_buffers() abort
  for b in range(1, bufnr('$'))
    if bufexists(b) && bufname(b) =~# '^mail://'
      execute 'bwipeout!' b
    endif
  endfor
endfunction

" Put the cursor on the buffer line carrying <id> (buffer order is not assumed).
function! testmail#goto(id) abort
  for ln in range(1, line('$'))
    let l = getline(ln)
    let tab = stridx(l, "\t")
    if tab >= 0 && l[:tab - 1] ==# a:id | call cursor(ln, 1) | return | endif
  endfor
  throw 'testmail: id not found in buffer: ' . a:id
endfunction

function! testmail#ftype(path) abort
  return getftype(a:path)
endfunction

function! testmail#has_entry(id) abort
  if !exists('b:mail_entries') | return 0 | endif
  for e in b:mail_entries
    if e.id ==# a:id | return 1 | endif
  endfor
  return 0
endfunction
