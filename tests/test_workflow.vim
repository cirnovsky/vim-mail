" End-to-end staged-workflow suite, driven like a HUMAN (headless): real keymaps
" and real :w — no calling the action functions directly, no fabricated buffer
" lines. It presses s/S to mark read/unread, dd to cut, p to paste, and :w to
" commit, exactly as you would at the keyboard. This exercises the ftplugin
" keymap wiring and the BufWriteCmd path, not just the functions underneath.
"
" Flow:
"   in inbox: `s` mark one read, `S` mark one unread   -> staged
"             `dd` the message to move                 -> staged delete, line cut
"   :b archive, `p`                                     -> paste the cut line
"   :w   (archive gains the label — a copy so far)
"   :b inbox, :w  (inbox drops its label — net move; the read marks commit too)
"
" Run:  vim -u NONE -N -es -S tests/test_workflow.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
" Load real ftplugins so the index buffer's <buffer> keymaps and BufWriteCmd are
" wired — the test drives THOSE, like a human, not the functions directly.
filetype plugin on

function! s:mkcanon(root, id, read) abort
  let d = a:root . '/.store/' . a:id
  call mkdir(d, 'p')
  call writefile(['From: A <a@example.com>', 'Subject: test ' . a:id,
        \ 'Date: Tue, 23 Jun 2026 08:00:00 -0700',
        \ 'Message-ID: <' . a:id . '@example.com>'], d . '/meta')
  call writefile(['raw ' . a:id], d . '/raw.eml')
  if a:read | call writefile([], d . '/.read') | endif
endfunction

function! s:link(root, mailbox, id) abort
  " Build the fixture with the REAL production linker so setup exercises the
  " same code the tests check — not a duplicate hand-rolled ln -s.
  call mail#actions#_make_link(a:id, a:root . '/' . a:mailbox)
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
  let id_move = '20260101T000000Z_aa11aa11'   " will move inbox -> archive
  let id_read = '20260101T000000Z_bb22bb22'   " starts UNREAD; press s (read)
  let id_keep = '20260101T000000Z_cc33cc33'   " starts READ;   press S (unread)
  call s:mkcanon(root, id_move, 0)
  call s:mkcanon(root, id_read, 0)
  call s:mkcanon(root, id_keep, 1)
  call s:link(root, 'inbox', id_move)
  call s:link(root, 'inbox', id_read)
  call s:link(root, 'inbox', id_keep)
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  " --- in inbox: press s / S to stage marks, dd to cut the move target ---
  call mail#index#open('inbox')
  let inbox_buf = bufnr('%')
  " sanity: the ftplugin really wired the buffer keymaps we're about to press
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
  " Regression: :Mail reused the buffer and refresh()ed it, silently discarding
  " the staged dd -> the move degraded to a copy. Returning here must preserve
  " the staged edits.
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
