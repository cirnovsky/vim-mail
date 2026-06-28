" Attachments and inline images (compose buffer + clipboard).
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

" Register a readable file as an attachment + add its footer line. Returns 1/0.
function! mail#attach#_register_attachment(path) abort
  let p = fnamemodify(expand(a:path), ':p')
  if !filereadable(p)
    echohl ErrorMsg | echom 'mail: file not readable: ' . a:path | echohl None
    return 0
  endif
  if !exists('b:mail_attachments')
    let b:mail_attachments = []
    let b:mail_attach_seq  = 0
  endif
  let b:mail_attach_seq += 1
  call add(b:mail_attachments, {'id': b:mail_attach_seq, 'path': p, 'inline': 0})
  call mail#attach#_append_footer_line(b:mail_attach_seq, fnamemodify(p, ':t'))
  return 1
endfunction

" Inline image: register the file and return its id (for the '[img id]' marker).
" Unlike attachments these don't go in the footer — the marker lives in the body.
function! mail#attach#_register_inline(path) abort
  let p = fnamemodify(expand(a:path), ':p')
  if !filereadable(p)
    echohl ErrorMsg | echom 'mail: file not readable: ' . a:path | echohl None
    return 0
  endif
  if !exists('b:mail_attachments')
    let b:mail_attachments = []
    let b:mail_attach_seq  = 0
  endif
  let b:mail_attach_seq += 1
  call add(b:mail_attachments, {'id': b:mail_attach_seq, 'path': p, 'inline': 1})
  return b:mail_attach_seq
endfunction

function! mail#attach#_is_image(path) abort
  return fnamemodify(a:path, ':e') =~? '^\%(png\|jpe\?g\|gif\|bmp\|webp\|tiff\?\|heic\)$'
endfunction

" Save clipboard image *data* (e.g. a screenshot) to a temp PNG; '' if none.
" macOS uses built-in osascript (coerce the clipboard to PNG) — no extra tools.
" Linux uses wl-paste / xclip (no universal built-in there).
function! mail#attach#_clipboard_image() abort
  let tmp = tempname() . '.png'
  if has('mac')
    let script = join([
          \ 'try',
          \ '  set png to the clipboard as «class PNGf»',
          \ 'on error',
          \ '  return',
          \ 'end try',
          \ 'set fh to open for access (POSIX file "' . tmp . '") with write permission',
          \ 'set eof fh to 0',
          \ 'write png to fh',
          \ 'close access fh',
          \ ], "\n")
    call system('osascript', script)
  elseif executable('wl-paste')
    call system('wl-paste --type image/png > ' . shellescape(tmp) . ' 2>/dev/null')
  elseif executable('xclip')
    call system('xclip -selection clipboard -t image/png -o > ' . shellescape(tmp) . ' 2>/dev/null')
  else
    return ''
  endif
  if filereadable(tmp) && getfsize(tmp) > 0
    return tmp
  endif
  call delete(tmp)
  return ''
endfunction

" <leader>p — insert inline image(s) from the clipboard: raw image data
" (screenshot) or copied image file(s). All-or-nothing: if any clipboard file
" isn't an image, warn and add nothing. Each image inserts an '[img id]' marker.
function! mail#attach#paste_image() abort
  if !exists('b:mail_compose_to')
    echohl ErrorMsg | echom 'mail: not a compose buffer' | echohl None
    return
  endif
  " Prefer copied FILES over the clipboard's image *data*. When you copy a file
  " in Finder, macOS also exposes a «class PNGf» rendering of it — but that's the
  " file's ICON / QuickLook thumbnail, not its real pixels. A data-first check
  " would embed that icon (the reported bug). So: if image file(s) are on the
  " clipboard, embed those; fall back to raw data (e.g. a screenshot) only when
  " there's no file.
  let files = mail#attach#_clipboard_files()
  if !empty(files)
    for f in files
      if !mail#attach#_is_image(f)
        echohl ErrorMsg
        echom 'mail: not an image: ' . fnamemodify(f, ':t') . ' — <leader>p needs all images (use <leader>a)'
        echohl None
        return
      endif
    endfor
    let imgs = files
  else
    let data = mail#attach#_clipboard_image()
    if data ==# ''
      echohl WarningMsg | echom 'mail: no image in clipboard' | echohl None
      return
    endif
    let imgs = [data]
  endif
  let markers = []
  for img in imgs
    let id = mail#attach#_register_inline(img)
    if id > 0 | call add(markers, '[img ' . id . ']') | endif
  endfor
  if !empty(markers)
    execute 'normal! a' . join(markers, ' ')
    echo 'Inserted ' . len(markers) . ' inline image(s)'
  endif
endfunction

" Append '[id] name' to the trailing Attachments: footer (creating it if none).
function! mail#attach#_append_footer_line(id, name) abort
  let entry = '[' . a:id . '] ' . a:name
  let fstart = -1
  for i in range(1, line('$'))
    if getline(i) =~# '^Attachments:\s*$' | let fstart = i | endif
  endfor
  if fstart < 0
    call append(line('$'), ['', 'Attachments:', entry])
  else
    let last = fstart
    let i = fstart + 1
    while i <= line('$') && getline(i) =~# '^\[\d\+\] '
      let last = i | let i += 1
    endwhile
    call append(last, entry)
  endif
endfunction

" :Attach {paths…} / <leader>A — attach file(s) by path (globs expanded).
function! mail#attach#attach(...) abort
  if !exists('b:mail_compose_to')
    echohl ErrorMsg | echom 'mail: not a compose buffer' | echohl None
    return
  endif
  let args = copy(a:000)
  if empty(args)
    let p = input('Attach file: ', '', 'file')
    redraw
    if p ==# '' | return | endif
    let args = [p]
  endif
  let added = 0
  for a in args
    let matches = glob(expand(a), 0, 1)
    if empty(matches)
      echohl WarningMsg | echom 'mail: no file matches: ' . a | echohl None
      continue
    endif
    for m in matches
      if mail#attach#_register_attachment(m) | let added += 1 | endif
    endfor
  endfor
  if added > 0 | echo 'Attached ' . added . ' file(s)' | endif
endfunction

" <leader>a — attach file(s) copied to the system clipboard.
function! mail#attach#attach_clipboard() abort
  if !exists('b:mail_compose_to')
    echohl ErrorMsg | echom 'mail: not a compose buffer' | echohl None
    return
  endif
  let files = mail#attach#_clipboard_files()
  if empty(files)
    echohl WarningMsg | echom 'mail: no file(s) in clipboard' | echohl None
    return
  endif
  let added = 0
  for f in files
    if mail#attach#_register_attachment(f) | let added += 1 | endif
  endfor
  if added > 0 | echo 'Attached ' . added . ' file(s) from clipboard' | endif
endfunction

" File paths currently on the system clipboard (Finder-copied files etc.).
" macOS reads ALL file URLs from the pasteboard via the AppKit bridge (JXA) —
" built-in, and handles multiple files (plain osascript «class furl» only ever
" returns one). Linux uses wl-paste / xclip text/uri-list.
function! mail#attach#_clipboard_files() abort
  if has('mac')
    let js = join([
          \ "ObjC.import('AppKit');",
          \ "var pb=$.NSPasteboard.generalPasteboard;",
          \ "var cls=$.NSMutableArray.alloc.init; cls.addObject($.NSURL.class);",
          \ "var arr=pb.readObjectsForClassesOptions(cls,$.NSDictionary.dictionary);",
          \ "var out=[];",
          \ "if(arr && !arr.isNil()){for(var i=0;i<arr.count;i++){var u=arr.objectAtIndex(i); if(u.isFileURL) out.push(ObjC.unwrap(u.path));}}",
          \ "out.join('\\n');",
          \ ], "\n")
    let raw = system('osascript -l JavaScript', js)
  elseif executable('wl-paste')
    let raw = system('wl-paste --type text/uri-list 2>/dev/null')
  elseif executable('xclip')
    let raw = system('xclip -selection clipboard -t text/uri-list -o 2>/dev/null')
  else
    return []
  endif
  let files = []
  for l in split(raw, "\n")
    let l = substitute(l, '\r$', '', '')
    if l =~# '^file://'
      let l = substitute(l, '^file://[^/]*', '', '')                       " scheme+host
      let l = substitute(l, '%\(\x\x\)', '\=nr2char(str2nr(submatch(1), 16))', 'g')  " %20 etc.
    endif
    if l !=# '' && filereadable(l)
      call add(files, l)
    endif
  endfor
  return files
endfunction
