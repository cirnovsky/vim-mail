" mail#fetch#_progress parses getmail's per-message 'N/M' lines into
" [done, total], and ignores everything else (retriever banner, version line,
" the 'N messages retrieved' summary, a subject with a stray '1/2').
"
" Run:  vim -u NONE -N -es -S tests/test_fetch_progress.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime! autoload/mail/*.vim

function! Test_progress_parse() abort
  " Real getmail 6.x per-message lines (verified against getmail 6.20 in
  " tests/system/): '  [<mailbox>] msg <N>/<M> (<bytes>) delivered'.
  call assert_equal([1, 3],   mail#fetch#_progress('  [INBOX] msg 1/3 (7 bytes) delivered'))
  call assert_equal([2, 200], mail#fetch#_progress('  [INBOX] msg 2/200 (5678 bytes) delivered'))
  call assert_equal([17, 17], mail#fetch#_progress('  [Some/Folder] msg 17/17 (42 bytes) delivered to MDA_external'))

  " everything else -> []
  call assert_equal([], mail#fetch#_progress('SimpleIMAPRetriever:test@localhost@127.0.0.1:3143:'))
  call assert_equal([], mail#fetch#_progress('  3 messages (21 bytes) retrieved, 0 skipped'))
  call assert_equal([], mail#fetch#_progress('getmail version 6.20.00'))
  call assert_equal([], mail#fetch#_progress(''))
  call assert_equal([], mail#fetch#_progress('Subject: sale 1/2 off today'))
endfunction

let v:errors = []
try
  call Test_progress_parse()
catch
  call add(v:errors, 'Test_progress_parse: threw ' . v:exception . ' @ ' . v:throwpoint)
endtry

if empty(v:errors)
  qall!
else
  for s:e in v:errors | echom s:e | endfor
  cquit!
endif
