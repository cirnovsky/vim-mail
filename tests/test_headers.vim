" Headless test suite for mail#view#_filtered_headers().
"
" Run:  vim -u NONE -N -es -S tests/test_headers.vim
" Exit code 0 = all pass, 1 = failure (assert_* collect into v:errors).
"
" Guards the RFC2047 fix: the header view must read the *decoded* `meta`,
" never the raw.eml headers (which are encoded like =?utf-8?Q?...?=).

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime! autoload/mail/*.vim

" Build a message dir: decoded `meta` + an `raw.eml` whose headers are
" RFC2047-ENCODED (and deliberately different), so a test that passes proves
" _filtered_headers read meta and ignored raw.eml.
function! s:mkmsg(dir, meta_lines) abort
  call mkdir(a:dir, 'p')
  call writefile(a:meta_lines, a:dir . '/meta')
  call writefile([
        \ 'Subject: =?utf-8?Q?ENCODED=20GIBBERISH?=',
        \ 'From: =?utf-8?B?ZW5jb2RlZA==?= <enc@example.com>',
        \ '',
        \ 'body',
        \ ], a:dir . '/raw.eml')
endfunction

let s:tmp = tempname()

" --- Decoded meta is used; encoded raw.eml is ignored; empty Cc skipped ---
function! Test_reads_decoded_meta_not_raweml() abort
  let d = s:tmp . '/m1'
  call s:mkmsg(d, [
        \ 'From: The Download <newsletters@technologyreview.com>',
        \ 'Reply-To: ',
        \ 'To: wang2443@e.ntu.edu.sg',
        \ 'Cc: ',
        \ 'Subject: AI agents are not your “coworkers”',
        \ 'Date: Tue, 30 Jun 2026 12:03:22 +0000',
        \ ])
  let h = mail#view#_filtered_headers(d . '/raw.eml')
  call assert_equal([
        \ 'From: The Download <newsletters@technologyreview.com>',
        \ 'To: wang2443@e.ntu.edu.sg',
        \ 'Subject: AI agents are not your “coworkers”',
        \ 'Date: Tue, 30 Jun 2026 12:03:22 +0000',
        \ ], h)
endfunction

" --- Reply-To suppressed when identical to From ---
function! Test_replyto_suppressed_when_equal_from() abort
  let d = s:tmp . '/m2'
  call s:mkmsg(d, [
        \ 'From: List <list@x.com>',
        \ 'Reply-To: List <list@x.com>',
        \ 'Subject: hi',
        \ 'Date: D',
        \ ])
  let h = mail#view#_filtered_headers(d . '/raw.eml')
  call assert_equal(-1, index(h, 'Reply-To: List <list@x.com>'),
        \ 'Reply-To equal to From should be suppressed')
endfunction

" --- Reply-To shown (right after From) when it differs ---
function! Test_replyto_shown_when_differs() abort
  let d = s:tmp . '/m3'
  call s:mkmsg(d, [
        \ 'From: Alice <a@x.com>',
        \ 'Reply-To: List <list@x.com>',
        \ 'Subject: hi',
        \ 'Date: D',
        \ ])
  let h = mail#view#_filtered_headers(d . '/raw.eml')
  call assert_equal('From: Alice <a@x.com>', h[0])
  call assert_equal('Reply-To: List <list@x.com>', h[1])
endfunction

" --- Missing meta returns empty (no crash) ---
function! Test_missing_meta_empty() abort
  call assert_equal([], mail#view#_filtered_headers(s:tmp . '/nope/raw.eml'))
endfunction

call Test_reads_decoded_meta_not_raweml()
call Test_replyto_suppressed_when_equal_from()
call Test_replyto_shown_when_differs()
call Test_missing_meta_empty()

call delete(s:tmp, 'rf')

if empty(v:errors)
  qall!
else
  for s:e in v:errors | echom s:e | endfor
  cquit!
endif
