" Linux file-manager copy → <leader>p inline-image paste, per desktop.
"
" Major desktops put a copied file on the clipboard under different MIME types:
"   - KDE/Dolphin + freedesktop standard : text/uri-list
"   - GNOME/GTK (Nautilus, Nemo, Caja, Thunar) : x-special/gnome-copied-files
"     (a 'copy'/'cut' line followed by file:// URIs)
" mail#attach#_clipboard_files() must read both so paste_image embeds the real
" file. Runs only on Linux with a display + xclip (e.g. `make test-linux-clip`
" under xvfb); skips on macOS and on headless CI (no $DISPLAY).
"
" Run: vim -u NONE -N -es -S tests/test_clipboard_linux.vim

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime! autoload/mail/*.vim

let s:png = s:repo . '/tests/fixtures/pixel.png'
let s:uri = 'file://' . s:png

function! s:can_run() abort
  return !has('mac') && $DISPLAY !=# '' && executable('xclip')
endfunction

if !s:can_run()
  echo 'SKIP test_clipboard_linux: needs Linux + $DISPLAY + xclip'
  qall!
endif

" Own the clipboard for one MIME target via xclip (forks a server to serve it).
" Redirect the server's stdout/stderr to /dev/null so it can't hold this run's
" stdout pipe open (which would hang `docker run` under make test-linux-clip).
function! s:set_clip(ctype, data) abort
  call system('xclip -selection clipboard -t ' . a:ctype . ' -i >/dev/null 2>&1', a:data)
  call system('sleep 0.15')   " let the xclip server take ownership before we read
endfunction

let v:errors = []

" 1. KDE / Dolphin / freedesktop standard: text/uri-list
call s:set_clip('text/uri-list', s:uri . "\r\n")
call assert_equal([s:png], mail#attach#_clipboard_files(),
      \ 'text/uri-list (KDE/Dolphin) resolves the file')

" 2. GNOME / GTK family: x-special/gnome-copied-files ('copy' line + URIs)
call s:set_clip('x-special/gnome-copied-files', "copy\n" . s:uri)
call assert_equal([s:png], mail#attach#_clipboard_files(),
      \ 'x-special/gnome-copied-files (Nautilus/Nemo/Caja/Thunar) resolves the file')

" 3. End-to-end: a GNOME-format copy of an image -> <leader>p embeds the real file
"    (the format text/uri-list path can't reach, so this also guards the fix).
call s:set_clip('x-special/gnome-copied-files', "copy\n" . s:uri)
enew
let b:mail_compose_to = ''
call cursor(line('$'), 1)
call mail#attach#paste_image()
call assert_match('\[img 1\]', join(getline(1, '$'), "\n"),
      \ 'paste_image inserted a marker from a GNOME file copy')
call assert_true(exists('b:mail_attachments') && len(b:mail_attachments) == 1,
      \ 'one inline image tracked')
if exists('b:mail_attachments') && len(b:mail_attachments) == 1
  call assert_equal(s:png, b:mail_attachments[0].path,
        \ 'embeds the copied FILE, not clipboard data')
endif
bwipeout!

if empty(v:errors)
  qall!
else
  for s:e in v:errors | echom s:e | endfor
  cquit!
endif
