" End-to-end staged-workflow suite, driven like a HUMAN (headless): real keymaps
" and real :w — no calling the action functions directly, no fabricated buffer
" lines. It presses s/S to mark read/unread, dd to cut, p to paste, and :w to
" commit, exactly as you would at the keyboard. This exercises the ftplugin
" keymap wiring and the BufWriteCmd path, not just the functions underneath.
"
" Fixtures come from real .eml files via the shared generator (testmail#build);
" 'read' drops the shared .read marker into the canon.
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
execute 'set rtp+=' . fnameescape(s:repo . '/tests/testlib')
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
filetype plugin on

function! Test_staged_move_with_read_marks() abort
  let root = tempname() . '/Mail'
  let ids = testmail#build(root, [
        \ {'name': 'plain',     'in': ['inbox']},
        \ {'name': 'html',      'in': ['inbox']},
        \ {'name': 'multipart', 'in': ['inbox'], 'read': 1},
        \ ])
  let id_move = ids.plain          " move inbox -> archive
  let id_read = ids.html           " starts UNREAD; press s (read)
  let id_keep = ids.multipart      " starts READ;   press S (unread)
  call mkdir(root . '/archive', 'p')
  let g:mail_root = root

  " --- in inbox: press s / S to stage marks, dd to cut the move target ---
  call mail#index#open('inbox')
  let inbox_buf = bufnr('%')
  call assert_true(!empty(maparg('s', 'n')), 's is mapped in the index buffer')

  call testmail#goto(id_read) | normal s        " keymap: mark read (staged)
  call testmail#goto(id_keep) | normal S        " keymap: mark unread (staged)
  call testmail#goto(id_move) | normal! dd      " cut the line (native dd)
  call assert_true(&modified, 'inbox has staged, uncommitted edits')

  " --- :b archive, paste the cut line (staged; do NOT :w yet) ---
  call mail#index#open('archive')               " refresh cuts into "_ , yank survives
  let arch_buf = bufnr('%')
  normal! p                                     " paste the cut line (native p)

  " --- navigate back to inbox with :Mail (like a human!); staged edits survive ---
  call mail#index#open('inbox')
  call assert_equal(inbox_buf, bufnr('%'), ':Mail returned to the same inbox buffer')
  call assert_true(&modified, 'staged edits survived :Mail navigation (not refreshed away)')

  " --- ONE :w commits ALL modified buffers: inbox (reads + cut) AND archive (paste) ---
  silent write

  " ===== 1. moved to archive, on F and T =====
  call assert_equal('link', testmail#ftype(root . '/archive/' . id_move),
        \ '1F: archive keeps the symlink label')
  call assert_true(isdirectory(root . '/.store/' . id_move),
        \ '1F: canonical bytes intact (moved, not trashed)')
  execute 'buffer' arch_buf
  call assert_true(testmail#has_entry(id_move), '1T: shows in archive index (b:mail_entries)')

  " ===== 2. removed from inbox, on F and T =====
  execute 'buffer' inbox_buf
  call assert_equal('', testmail#ftype(root . '/inbox/' . id_move), '2F: inbox label unlinked')
  call assert_false(isdirectory(root . '/trash/' . id_move),
        \ '2F: not trashed — a move (still labelled in archive)')
  call assert_false(testmail#has_entry(id_move), '2T: gone from inbox index')

  " ===== 3. the OTHER staged marks are unaffected =====
  call assert_true(filereadable(root . '/.store/' . id_read . '/.read'),
        \ '3: pressed-s "read" committed to the shared .read')
  call assert_false(filereadable(root . '/.store/' . id_keep . '/.read'),
        \ '3: pressed-S "unread" committed (.read removed)')
  call assert_equal('link', testmail#ftype(root . '/inbox/' . id_read), '3: id_read still in inbox')
  call assert_equal('link', testmail#ftype(root . '/inbox/' . id_keep), '3: id_keep still in inbox')
  call assert_true(testmail#has_entry(id_read), '3T: id_read still in inbox index')
  call assert_true(testmail#has_entry(id_keep), '3T: id_keep still in inbox index')

  call testmail#wipe_buffers()
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
