" Headless test: mail#compose#reply() builds a plain-text, threading-friendly compose
" buffer — To/Subject/In-Reply-To/References headers, an attribution line, and
" '> '-quoted original body. Run: vim -u NONE -N -es -S tests/test_compose.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime! autoload/mail/*.vim

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

  call mail#index#open('inbox')
  call cursor(1, 1)
  call mail#compose#reply()

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

" Both forward modes build a new-thread compose buffer: empty To, 'Fwd:'
" subject, no In-Reply-To/References, a forwarded-header block. Inline (f) records
" orig_dir + fwd_inline; as-attachment (F) records b:mail_compose_forward.
function! s:check_forward_common(text, lines) abort
  call assert_equal('To: ', a:lines[0], 'To is empty for forward')
  call assert_match('\nSubject: Fwd: Hello', a:text, 'Subject gets Fwd: prefix')
  call assert_notmatch('In-Reply-To', a:text, 'forward starts a new thread')
  call assert_notmatch('References', a:text, 'no References on a forward')
  call assert_match('---------- Forwarded message ----------', a:text, 'forwarded marker')
  call assert_match('From: Alice <alice@example.com>', a:text, 'forwarded From shown')
  call assert_equal('mail-compose', &filetype, 'compose buffer filetype')
endfunction

function! Test_forward_inline_buffer() abort
  let root = tempname() . '/Mail'
  call s:mkmsg(root . '/inbox/20260101T000000Z_aabbccdd')
  let g:mail_root = root
  let g:mail_from = 'Me <me@example.com>'
  call mail#index#open('inbox')
  call cursor(1, 1)
  call mail#compose#forward()
  call s:check_forward_common(join(getline(1, '$'), "\n"), getline(1, '$'))
  call assert_true(exists('b:mail_compose_fwd_inline'), 'inline forward flagged')
  call assert_match('20260101T000000Z_aabbccdd$', b:mail_compose_orig_dir,
        \ 'orig_dir points at the original (for embed + re-attach)')
  bwipeout!
  call delete(root, 'rf')
endfunction

function! Test_forward_attach_buffer() abort
  let root = tempname() . '/Mail'
  call s:mkmsg(root . '/inbox/20260101T000000Z_aabbccdd')
  let g:mail_root = root
  let g:mail_from = 'Me <me@example.com>'
  call mail#index#open('inbox')
  call cursor(1, 1)
  call mail#compose#forward_attach()
  call s:check_forward_common(join(getline(1, '$'), "\n"), getline(1, '$'))
  call assert_true(exists('b:mail_compose_forward'), 'attach forward dir recorded')
  call assert_match('20260101T000000Z_aabbccdd$', b:mail_compose_forward,
        \ 'forward dir points at the original message')
  bwipeout!
  call delete(root, 'rf')
endfunction

" Attachments: registering a file adds it to b:mail_attachments and writes an
" Attachments: footer; mail#send#_split_attachments resolves surviving footer ids to
" paths and strips the footer from the body (deleted line => file dropped).
function! Test_attach_footer_and_split() abort
  let root = tempname() . '/Mail'
  call s:mkmsg(root . '/inbox/20260101T000000Z_aabbccdd')
  let g:mail_root = root
  let g:mail_from = 'Me <me@example.com>'
  call mail#index#open('inbox')
  call cursor(1, 1)
  call mail#compose#compose()

  let f1 = tempname() | call writefile(['x'], f1)
  let f2 = tempname() | call writefile(['y'], f2)
  call mail#attach#attach(f1)
  call mail#attach#attach(f2)

  let text = join(getline(1, '$'), "\n")
  call assert_match('\nAttachments:\n', text, 'Attachments: footer created')
  call assert_match('\[1\] ' . fnamemodify(f1, ':t'), text, 'first file listed')
  call assert_match('\[2\] ' . fnamemodify(f2, ':t'), text, 'second file listed')
  call assert_equal(2, len(b:mail_attachments), 'both tracked')

  " Resolve the whole body: both surviving -> both paths, footer stripped.
  let body = getline(1, '$')[index(getline(1,'$'), '') + 1 :]  " body after header blank
  let r = mail#send#_split_attachments(body)
  call assert_equal([fnamemodify(f1, ':p'), fnamemodify(f2, ':p')], r.paths,
        \ 'both paths resolved')
  call assert_notmatch('Attachments:', join(r.body, "\n"), 'footer stripped from body')

  " Drop the [1] entry from the footer -> only the second file is sent.
  call filter(body, 'v:val !~# "^\\[1\\] "')
  let r2 = mail#send#_split_attachments(body)
  call assert_equal([fnamemodify(f2, ':p')], r2.paths, 'deleted footer line drops file')

  bwipeout!
  call delete(root, 'rf')
  call delete(f1) | call delete(f2)
endfunction

" Inline images: mail#attach#_register_inline tags entries inline=1 (no footer); a
" surviving '[img id]' marker in the body resolves to [id, path] via
" mail#send#_inline_images; deleting the marker drops it.
function! Test_inline_images_resolve() abort
  let root = tempname() . '/Mail'
  call s:mkmsg(root . '/inbox/20260101T000000Z_aabbccdd')
  let g:mail_root = root
  let g:mail_from = 'Me <me@example.com>'
  call mail#index#open('inbox')
  call cursor(1, 1)
  call mail#compose#compose()

  let img = tempname() . '.png' | call writefile(['x'], img)
  let id = mail#attach#_register_inline(img)
  call assert_equal(1, id, 'first inline id')
  call assert_equal(1, b:mail_attachments[0].inline, 'tagged inline')

  let body = ['look:', '[img 1]', 'bye']
  call assert_equal([[1, fnamemodify(img, ':p')]], mail#send#_inline_images(body),
        \ 'surviving marker resolves to [id, path]')
  call assert_equal([], mail#send#_inline_images(['no marker here']),
        \ 'no marker -> nothing (deleted image dropped)')

  bwipeout!
  call delete(root, 'rf') | call delete(img)
endfunction

" Stub the clipboard-image grab (the only part needing pngpaste/xclip) so we can
" test mail#attach#paste_image's flow headlessly. Defined after 'runtime autoload' so it
" overrides the real one.
function! mail#attach#_clipboard_image() abort
  return get(g:, 'test_clip_img', '')
endfunction

function! Test_paste_image_inserts_marker() abort
  let root = tempname() . '/Mail'
  call s:mkmsg(root . '/inbox/20260101T000000Z_aabbccdd')
  let g:mail_root = root
  let g:mail_from = 'Me <me@example.com>'
  call mail#index#open('inbox')
  call cursor(1, 1)
  call mail#compose#compose()

  let g:test_clip_img = tempname() . '.png' | call writefile(['x'], g:test_clip_img)
  " cursor on the empty body line; paste the (stubbed) clipboard image
  call cursor(line('$'), 1)
  call mail#attach#paste_image()

  call assert_match('\[img 1\]', join(getline(1, '$'), "\n"), '[img 1] marker inserted')
  call assert_equal(1, len(b:mail_attachments), 'one inline image tracked')
  call assert_equal(1, b:mail_attachments[0].inline, 'tagged inline')

  unlet g:test_clip_img
  bwipeout!
  call delete(root, 'rf')
endfunction

let v:errors = []
let s:tests = ['Test_reply_builds_plain_threading_buffer',
      \ 'Test_forward_inline_buffer', 'Test_forward_attach_buffer',
      \ 'Test_attach_footer_and_split', 'Test_inline_images_resolve',
      \ 'Test_paste_image_inserts_marker']
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
