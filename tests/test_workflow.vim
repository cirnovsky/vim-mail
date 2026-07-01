" End-to-end staged-workflow suite: a cross-buffer move (dd in A, paste in B)
" performed ALONGSIDE independent staged read/unread marks in A, committed across
" two per-buffer :w's. Proves the pieces compose: the move lands on both the
" filesystem (F) and the index buffers (T), and the unrelated staged marks are
" neither lost nor corrupted by the cross-buffer dance.
"
" Flow (as a user would do it):
"   in A: mark one msg read (s), one unread (S)  -> staged
"         dd the msg to move                     -> staged delete, line yanked
"   :b B, p                                       -> paste the yanked line
"   :w   (B gains the label — a copy so far)
"   :b A, :w  (A drops its label — net move; and the read marks commit)
"
" Run:  vim -u NONE -N -es -S tests/test_workflow.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime! autoload/mail/*.vim

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
  let mb = a:root . '/' . a:mailbox
  call mkdir(mb, 'p')
  call system('ln -s ' . shellescape('../.store/' . a:id) . ' '
        \ . shellescape(mb . '/' . a:id))
endfunction

function! s:ftype(p) abort
  return getftype(a:p)
endfunction

" Locate the buffer line carrying <id> (buffer is reverse-sorted, so don't assume).
function! s:line_of(id) abort
  for ln in range(1, line('$'))
    let l = getline(ln)
    let tab = stridx(l, "\t")
    if tab >= 0 && l[:tab - 1] ==# a:id | return ln | endif
  endfor
  return -1
endfunction

" Is <id> present in the CURRENT buffer's disk baseline (T = what the index shows)?
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
  let id_read = '20260101T000000Z_bb22bb22'   " starts UNREAD; stage read (s)
  let id_keep = '20260101T000000Z_cc33cc33'   " starts READ;   stage unread (S)
  call s:mkcanon(root, id_move, 0)
  call s:mkcanon(root, id_read, 0)
  call s:mkcanon(root, id_keep, 1)
  call s:link(root, 'inbox', id_move)
  call s:link(root, 'inbox', id_read)
  call s:link(root, 'inbox', id_keep)
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  " --- in A (inbox): stage two read/unread changes, then dd the move target ---
  call mail#index#open('inbox')
  let inbox_buf = bufnr('%')

  call cursor(s:line_of(id_read), 1)
  call mail#actions#read(1)                    " stage: mark read
  call cursor(s:line_of(id_keep), 1)
  call mail#actions#read(0)                    " stage: mark unread
  call cursor(s:line_of(id_move), 1)
  normal! dd                                   " stage delete; line -> unnamed reg
  call assert_true(&modified, 'A has staged, uncommitted edits')

  " --- :b B (archive), paste, :w ---
  call mail#index#open('archive')              " refresh deletes into "_ , so the yank survives
  let arch_buf = bufnr('%')
  normal! p
  call mail#actions#write()                    " B gains the label

  " At this instant the message is labelled in BOTH mailboxes (a legal copy) —
  " A's dd is still uncommitted.
  call assert_equal('link', s:ftype(root . '/archive/' . id_move), 'B linked on :w')
  call assert_equal('link', s:ftype(root . '/inbox/' . id_move),
        \ 'A still linked until its own :w')

  " --- :b A, :w  -> commits the move AND the staged read marks ---
  execute 'buffer' inbox_buf
  call assert_true(&modified, "A's staged edits survived the round trip")
  call mail#actions#write()

  " ================= 1. mail moved to B, on F and T =================
  call assert_equal('link', s:ftype(root . '/archive/' . id_move),
        \ '1F: archive still has the symlink label')
  call assert_true(isdirectory(root . '/.store/' . id_move),
        \ '1F: canonical bytes intact (moved, not trashed)')
  execute 'buffer' arch_buf
  call assert_true(s:has_entry(id_move), '1T: message shows in B''s index (b:mail_entries)')

  " ================= 2. mail removed from A, on F and T =================
  execute 'buffer' inbox_buf
  call assert_equal('', s:ftype(root . '/inbox/' . id_move),
        \ '2F: inbox label unlinked')
  call assert_false(isdirectory(root . '/trash/' . id_move),
        \ '2F: not trashed — it was a move (still labelled in B)')
  call assert_false(s:has_entry(id_move), '2T: gone from A''s index (b:mail_entries)')

  " ================= 3. the OTHER staged changes are unaffected =================
  " read/unread committed to the shared canonical .read:
  call assert_true(filereadable(root . '/.store/' . id_read . '/.read'),
        \ '3: staged "mark read" committed (.read created)')
  call assert_false(filereadable(root . '/.store/' . id_keep . '/.read'),
        \ '3: staged "mark unread" committed (.read removed)')
  " and those two messages stayed put in A (neither moved nor deleted):
  call assert_equal('link', s:ftype(root . '/inbox/' . id_read), '3: id_read still in inbox')
  call assert_equal('link', s:ftype(root . '/inbox/' . id_keep), '3: id_keep still in inbox')
  call assert_true(s:has_entry(id_read), '3T: id_read still in A''s index')
  call assert_true(s:has_entry(id_keep), '3T: id_keep still in A''s index')

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
