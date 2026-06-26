" REAL clipboard integration: put a PNG on the system clipboard, then verify the
" unstubbed mail#_clipboard_image actually captures it and that mail#paste_image
" inserts an [img] marker end to end. This is the test that would have caught the
" "relies on pngpaste, which isn't installed" breakage — the other tests stub the
" clipboard grab, so they cannot.
"
" Skips cleanly where the platform can't set/read an image clipboard (e.g. Linux
" CI with no display / no wl-copy/xclip). NOTE: it briefly replaces the system
" clipboard; on macOS the text clipboard is saved and restored.
"
" Run: vim -u NONE -N -es -S tests/test_clipboard.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime autoload/mail.vim

let s:png = s:repo . '/tests/fixtures/pixel.png'

function! s:can_run() abort
  if has('mac') | return executable('osascript') | endif
  return executable('wl-copy') || executable('xclip')
endfunction

function! s:set_clipboard_image(path) abort
  if has('mac')
    call system('osascript', 'set the clipboard to (read (POSIX file "'
          \ . a:path . '") as «class PNGf»)')
  elseif executable('wl-copy')
    call system('wl-copy --type image/png < ' . shellescape(a:path))
  else
    call system('xclip -selection clipboard -t image/png -i ' . shellescape(a:path))
  endif
endfunction

if !s:can_run()
  echo 'SKIP test_clipboard: no image-clipboard tool on this platform'
  qall!
endif

" Save the text clipboard so a normal `make test` doesn't lose it (macOS).
let s:saved = has('mac') ? system('pbpaste') : ''

let v:errors = []
try
  call s:set_clipboard_image(s:png)

  " 1. The real capture returns a readable, valid PNG.
  let p = mail#_clipboard_image()
  call assert_true(p !=# '' && filereadable(p), 'clipboard image captured: ' . p)
  if p !=# '' && filereadable(p)
    call assert_true(getfsize(p) > 0, 'captured file non-empty')
    call assert_equal(0z89504E470D0A1A0A, readblob(p)[0:7], 'captured bytes are a PNG')
    call delete(p)
  endif

  " 2. End-to-end: <leader>p path inserts an [img] marker, no stub.
  enew
  let b:mail_compose_to = ''
  call s:set_clipboard_image(s:png)
  call mail#paste_image()
  call assert_match('\[img 1\]', join(getline(1, '$'), "\n"),
        \ 'paste_image inserted a marker from the real clipboard')
  call assert_true(exists('b:mail_attachments') && len(b:mail_attachments) == 1,
        \ 'inline image tracked')
  bwipeout!

  " 3. Multiple clipboard FILES → multiple paths (macOS regression for the old
  " single-file «class furl» limitation). Sets two concrete file-url items.
  if has('mac')
    let f1 = tempname() | call writefile(['1'], f1)
    let f2 = tempname() | call writefile(['2'], f2)
    let setjs = "ObjC.import('AppKit'); var pb=$.NSPasteboard.generalPasteboard;"
          \ . " pb.clearContents; var items=$.NSMutableArray.alloc.init; ['"
          \ . f1 . "','" . f2 . "'].forEach(function(p){var it=$.NSPasteboardItem.alloc.init;"
          \ . " it.setStringForType($.NSURL.fileURLWithPath(p).absoluteString,'public.file-url');"
          \ . " items.addObject(it);}); pb.writeObjects(items);"
    call system('osascript -l JavaScript', setjs)
    call assert_equal(sort([f1, f2]), sort(mail#_clipboard_files()),
          \ 'both copied files are returned (not just one)')
    call delete(f1) | call delete(f2)
  endif
finally
  if has('mac') | call system('pbcopy', s:saved) | endif
endtry

if empty(v:errors)
  qall!
else
  for s:e in v:errors | echom s:e | endfor
  cquit!
endif
