" End-to-end staged-workflow suite, driven like a HUMAN (headless): real keymaps
" and real :w — no calling the action functions directly, no fabricated buffer
" lines. It presses s/S to mark read/unread, dd to cut, p to paste, and :w to
" commit, exactly as you would at the keyboard. This exercises the ftplugin
" keymap wiring and the BufWriteCmd path, not just the functions underneath.
"
" Fixtures are built with the REAL engine (mail_store.py ingest-stdin); a message
" marked read gets its .read marker dropped into the canon (the same 0-byte
" marker mail#actions#write() writes).
"
" Flow:
"   in inbox: `s` mark one read, `S` mark one unread   -> staged
"             `dd` the message to move                 -> staged delete, line cut
"   :b archive, `p`                                     -> paste the cut line
"   :w   (archive gains the label — a copy so far)
"   :Mail inbox, :w  (inbox drops its label — net move; the read marks commit too)
"
" Run:  vim -u NONE -N -es -S tests/test_workflow.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on

" Ingest a deterministic message (from <seed>) into <mailbox> via the REAL
" backend. read=1 drops the .read marker into the canon. Returns the id.
function! s:mkmsg(root, mailbox, seed, read) abort
  let mb = a:root . '/' . a:mailbox
  call mkdir(mb, 'p')
  let before = {}
  for e in glob(mb . '/*', 0, 1) | let before[fnamemodify(e, ':t')] = 1 | endfor
  let raw = join([
        \ 'From: ' . a:seed . ' <' . a:seed . '@example.com>',
        \ 'To: me@example.com', 'Subject: ' . a:seed,
        \ 'Date: Tue, 23 Jun 2026 08:00:00 -0700',
        \ 'Message-ID: <' . a:seed . '@example.com>', '', 'Body ' . a:seed, ''], "\n")
  call system(g:mail_python . ' ' . shellescape(g:mail_store_py)
        \ . ' ingest-stdin ' . shellescape(mb), raw)
  let id = ''
  for e in glob(mb . '/*', 0, 1)
    let n = fnamemodify(e, ':t')
    if !has_key(before, n) | let id = n | break | endif
  endfor
  if id ==# '' | throw 'ingest produced no new entry for ' . a:seed | endif
  if a:read | call writefile([], a:root . '/.store/' . id . '/.read') | endif
  return id
endfunction

function! s:ftype(p) abort
  return getftype(a:p)
endfunction

" Put the cursor on the buffer line carrying <id> (buffer is reverse-sorted).
function! s:goto(id) abort
  for ln in range(1, line('$'))
    let l = getline(ln)
    let tab = stridx(l, "\t")
    if tab >= 0 && l[:tab - 1] ==# a:id
      call cursor(ln, 1)
      return
    endif
  endfor
  throw 'id not found in buffer: ' . a:id
endfunction

function! s:has_entry(id) abort
  if !exists('b:mail_entries') | return 0 | endif
  for e in b:mail_entries
    if e.id ==# a:id | return 1 | endif
  endfor
  return 0
endfunction

function! Test_staged_move_with_read_marks() abort
  let root = tempname() . '/Mail'
  let id_move = s:mkmsg(root, 'inbox', 'move', 0)   " move inbox -> archive
  let id_read = s:mkmsg(root, 'inbox', 'read', 0)   " starts UNREAD; press s
  let id_keep = s:mkmsg(root, 'inbox', 'keep', 1)   " starts READ;   press S
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  " --- in inbox: press s / S to stage marks, dd to cut the move target ---
  call mail#index#open('inbox')
  let inbox_buf = bufnr('%')
  call assert_true(!empty(maparg('s', 'n')), 's is mapped in the index buffer')

  call s:goto(id_read) | normal s               " keymap: mark read (staged)
  call s:goto(id_keep) | normal S               " keymap: mark unread (staged)
  call s:goto(id_move) | normal! dd             " cut the line (native dd)
  call assert_true(&modified, 'inbox has staged, uncommitted edits')

  " --- :b archive, p, :w ---
  call mail#index#open('archive')               " refresh cuts into "_ , yank survives
  let arch_buf = bufnr('%')
  normal! p                                     " paste the cut line (native p)
  silent write                                  " :w -> BufWriteCmd -> archive gains label

  call assert_equal('link', s:ftype(root . '/archive/' . id_move), 'archive linked on :w')
  call assert_equal('link', s:ftype(root . '/inbox/' . id_move),
        \ 'inbox still linked until its own :w')

  " --- navigate back to inbox with :Mail (like a human!), then :w ---
  call mail#index#open('inbox')
  call assert_equal(inbox_buf, bufnr('%'), ':Mail returned to the same inbox buffer')
  call assert_true(&modified, 'staged edits survived :Mail navigation (not refreshed away)')
  silent write                                  " :w -> BufWriteCmd -> write()

  " ===== 1. moved to archive, on F and T =====
  call assert_equal('link', s:ftype(root . '/archive/' . id_move),
        \ '1F: archive keeps the symlink label')
  call assert_true(isdirectory(root . '/.store/' . id_move),
        \ '1F: canonical bytes intact (moved, not trashed)')
  execute 'buffer' arch_buf
  call assert_true(s:has_entry(id_move), '1T: shows in archive index (b:mail_entries)')

  " ===== 2. removed from inbox, on F and T =====
  execute 'buffer' inbox_buf
  call assert_equal('', s:ftype(root . '/inbox/' . id_move), '2F: inbox label unlinked')
  call assert_false(isdirectory(root . '/trash/' . id_move),
        \ '2F: not trashed — a move (still labelled in archive)')
  call assert_false(s:has_entry(id_move), '2T: gone from inbox index')

  " ===== 3. the OTHER staged marks are unaffected =====
  call assert_true(filereadable(root . '/.store/' . id_read . '/.read'),
        \ '3: pressed-s "read" committed to the shared .read')
  call assert_false(filereadable(root . '/.store/' . id_keep . '/.read'),
        \ '3: pressed-S "unread" committed (.read removed)')
  call assert_equal('link', s:ftype(root . '/inbox/' . id_read), '3: id_read still in inbox')
  call assert_equal('link', s:ftype(root . '/inbox/' . id_keep), '3: id_keep still in inbox')
  call assert_true(s:has_entry(id_read), '3T: id_read still in inbox index')
  call assert_true(s:has_entry(id_keep), '3T: id_keep still in inbox index')

  execute 'bwipeout!' inbox_buf
  execute 'bwipeout!' arch_buf
  call delete(root, 'rf')
endfunction

" --- runner ---
let v:errors = []
let s:tests = ['Test_staged_move_with_read_marks']
for s:t in s:tests
  try
    call call(s:t, [])
  catch
    call add(v:errors, s:t . ': threw ' . v:exception . ' @ ' . v:throwpoint)
  endtry
endfor

if empty(v:errors)
  qall!
else
  for s:e in v:errors | echom s:e | endfor
  cquit!
endif
