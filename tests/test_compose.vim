" Headless test: mail#reply() builds a plain-text, threading-friendly compose
" buffer — To/Subject/In-Reply-To/References headers, an attribution line, and
" '> '-quoted original body. Run: vim -u NONE -N -es -S tests/test_compose.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime autoload/mail.vim

function! s:mkmsg(dir) abort
  call mkdir(a:dir, 'p')
  call writefile([
        \ 'From: Alice <alice@example.com>',
        \ 'To: Bob <bob@example.com>',
        \ 'Subject: Hello',
        \ 'Date: Wed, 01 Jan 2026 00:00:00 +0000',
        \ 'Message-ID: <orig@test>',
        \ ], a:dir . '/meta')
  " Plain-text original (no body.html → class 1). The reply quote is sourced
  " from raw.eml's text/plain via `mail_store.py quote`, so both body lines live
  " here.
  call writefile([
        \ 'From: Alice <alice@example.com>',
        \ 'Subject: Hello',
        \ 'Message-ID: <orig@test>',
        \ 'References: <older@test>',
        \ 'Content-Type: text/plain',
        \ '',
        \ 'How are you?',
        \ 'Second line',
        \ ], a:dir . '/raw.eml')
  call writefile(['How are you?', 'Second line'], a:dir . '/body.txt')
endfunction

function! Test_reply_builds_plain_threading_buffer() abort
  let root = tempname() . '/Mail'
  call s:mkmsg(root . '/inbox/20260101T000000Z_aabbccdd')
  let g:mail_root = root
  let g:mail_from = 'Me <me@example.com>'

  call mail#open('inbox')
  call cursor(1, 1)
  call mail#reply()

  let lines = getline(1, '$')
  let text  = join(lines, "\n")

  " Headers
  call assert_match('^To: alice@example.com', text, 'To: addresses the sender')
  call assert_match('\nSubject: Re: Hello', text, 'Subject gets Re: prefix')
  call assert_match('\nIn-Reply-To: <orig@test>', text, 'In-Reply-To set (threading)')
  call assert_match('\nReferences: <older@test> <orig@test>', text,
        \ 'References chain extended (threading)')

  " Attribution + quoted body
  call assert_match('On Wed, 01 Jan 2026 00:00:00 +0000, Alice <alice@example.com> wrote:',
        \ text, 'attribution line present')
  call assert_match('\n> How are you?', text, 'original body quoted with > ')
  call assert_match('\n> Second line', text, 'all body lines quoted')

  " It is a compose buffer (so :w sends), no HTML anywhere
  call assert_equal('mail-compose', &filetype, 'compose buffer filetype')
  call assert_notmatch('<html', text, 'no HTML in compose buffer')

  bwipeout!
  call delete(root, 'rf')
endfunction

" mail#forward() builds a new-thread compose buffer: empty To, 'Fwd:' subject,
" no In-Reply-To/References, a forwarded-header block in the body, and
" b:mail_compose_forward pointing at the original (so :w attaches its .eml).
function! Test_forward_builds_buffer() abort
  let root = tempname() . '/Mail'
  call s:mkmsg(root . '/inbox/20260101T000000Z_aabbccdd')
  let g:mail_root = root
  let g:mail_from = 'Me <me@example.com>'

  call mail#open('inbox')
  call cursor(1, 1)
  call mail#forward()

  let lines = getline(1, '$')
  let text  = join(lines, "\n")
  call assert_equal('To: ', lines[0], 'To is empty for forward')
  call assert_match('\nSubject: Fwd: Hello', text, 'Subject gets Fwd: prefix')
  call assert_notmatch('In-Reply-To', text, 'forward starts a new thread')
  call assert_notmatch('References', text, 'no References on a forward')
  call assert_match('---------- Forwarded message ----------', text, 'forwarded marker')
  call assert_match('From: Alice <alice@example.com>', text, 'forwarded From shown')
  call assert_equal('mail-compose', &filetype, 'compose buffer filetype')
  call assert_true(exists('b:mail_compose_forward'), 'forward dir recorded')
  call assert_match('20260101T000000Z_aabbccdd$', b:mail_compose_forward,
        \ 'forward dir points at the original message')

  bwipeout!
  call delete(root, 'rf')
endfunction

let v:errors = []
let s:tests = ['Test_reply_builds_plain_threading_buffer', 'Test_forward_builds_buffer']
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
