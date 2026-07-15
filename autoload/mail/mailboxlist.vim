" The mailbox launcher: a read-only, netrw-style index of all mailboxes under
" g:mail_root. `:Mail` (no arg) opens it; <CR> enters a mailbox; `-` in a mailbox
" returns here. Edits are NOT allowed — deleting/renaming a whole mailbox is too
" destructive to leave to a stray `dd`. Each mailbox still opens in its own
" persistent buffer (a launcher, not a single reused netrw buffer), so staged
" edits and cross-mailbox dd+p moves survive navigation.
"
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

let s:list_bufnr = -1
let s:list_name  = 'mail://[mailboxes]'

" Mailbox basenames under g:mail_root (dirs, skipping the hidden .store), with
" inbox and sent floated to the top, the rest alphabetical.
function! mail#mailboxlist#_mailboxes() abort
  let root = mail#mailbox#root()
  let names = []
  for path in glob(root . '/*', 0, 1)
    if isdirectory(path) && fnamemodify(path, ':t') !~# '^\.'
      call add(names, fnamemodify(path, ':t'))
    endif
  endfor
  call sort(names)
  let front = filter(['inbox', 'sent'], 'index(names, v:val) >= 0')
  let rest  = filter(copy(names), 'index(front, v:val) < 0')
  return front + rest
endfunction

function! mail#mailboxlist#open() abort
  if s:list_bufnr > 0 && bufexists(s:list_bufnr) && bufname(s:list_bufnr) ==# s:list_name
    let winid = bufwinid(s:list_bufnr)
    if winid != -1
      call win_gotoid(winid)
    else
      execute 'buffer ' . s:list_bufnr
    endif
  else
    noautocmd enew
    setlocal buftype=nofile bufhidden=hide noswapfile nowrap nobuflisted
    silent! noautocmd execute 'file ' . fnameescape(s:list_name)
    let s:list_bufnr = bufnr('%')
  endif
  setlocal filetype=mail-mailboxes
  call mail#mailboxlist#render()
endfunction

" Center `s` (ASCII) in a field of width `w`.
function! s:center(s, w) abort
  let n = strchars(a:s)
  if n >= a:w | return a:s | endif
  let l = (a:w - n) / 2
  return repeat(' ', l) . a:s . repeat(' ', a:w - n - l)
endfunction

" --- ASCII scene motifs: the neighbourhood the folder icons live in ---------
" Single-quoted so backslashes are literal; the dog's legs line needs "" (quotes).
let s:CLOUD  = [' ~~', '~~~']
let s:TREES  = [' /\ /\ /\', '//\\/\\/\\', '//\\/\\/\\', ' || || ||']
let s:DOG    = ['    __', ' __/  \_', "'-o---o-'"]
let s:BIGBOX = ['  _||____', ' /\\\\\\\\', '/__\\\\\\\\  _,', '|__|_|_|__|   \__,', '|  |/|\| /|   /\ \']
let s:ICON   = [' ___', '| _ |', '|[_]|', '|___|']
let s:BIN    = [' ___', '|___|', '|. .|', '|___|']

" Overlay art (a list of lines) onto the char grid at (r, c), skipping spaces so
" it composites over the backdrop rather than blanking it.
function! s:put(grid, r, c, art) abort
  let i = 0
  for line in a:art
    let row = a:r + i
    if row >= 0 && row < len(a:grid)
      let j = 0
      for ch in split(line, '\zs')
        let col = a:c + j
        if ch !=# ' ' && col >= 0 && col < len(a:grid[row])
          let a:grid[row][col] = ch
        endif
        let j += 1
      endfor
    endif
    let i += 1
  endfor
endfunction

" Render all mailboxes into ONE scene: a row of folder icons (TRASH as a trash
" bin) framed by trees on the left and a dog + big mailbox on the right, clouds
" above, a ground line below — centered in the window. Only the folder icons are
" navigable: b:mailbox_cells records each one's column span + cursor anchor. TRASH
" is the virtual mail#trash view, appended here (never a real dir).
function! mail#mailboxlist#render() abort
  let names = mail#mailboxlist#_mailboxes() + ['TRASH']

  " Column layout (0-based within the scene): icons in a row after the trees; the
  " dog and big mailbox decorate the right. base = top row of the icons/trees.
  let base = 2
  let iw = 5
  let igap = 4
  let left = 15
  " Uniform icon pitch; the name is centered under each icon (may spill into the
  " gap for names a little longer than the icon). cellcols: [name, c0, c1].
  let cellcols = []
  let x = left
  for name in names
    call add(cellcols, [name, x, x + iw - 1])
    let x += iw + igap
  endfor
  let dog_x = x - igap + 3
  let box_x = dog_x + 10
  let scene_w = box_x + 18
  let scene_h = 8
  let ground = scene_h - 1

  " Too narrow for the scene? Fall back in two tiers: first the compact boxed
  " menu, then (if even that won't fit) the plain one-per-line list.
  " g:mail_launcher_width overrides winwidth (tests / forcing a layout).
  let width = get(g:, 'mail_launcher_width', winwidth(0))
  if width < scene_w
    if width >= s:box_inner(names) + 2
      call s:render_box(names)
    else
      call s:render_list(names)
    endif
    return
  endif

  " Build the grid and composite the scene onto it.
  let grid = []
  for r in range(scene_h) | call add(grid, repeat([' '], scene_w)) | endfor
  call s:put(grid, base - 2, box_x + 4, s:CLOUD)
  call s:put(grid, base + 1, 1, s:TREES)
  for [name, c0, c1] in cellcols
    call s:put(grid, base, c0, name ==# 'TRASH' ? s:BIN : s:ICON)
    call s:put(grid, base + 4, c0 + (iw - strchars(name)) / 2, [name])
  endfor
  call s:put(grid, base + 2, dog_x, s:DOG)
  call s:put(grid, base, box_x, s:BIGBOX)
  for c in range(scene_w) | let grid[ground][c] = '~' | endfor

  " Rows -> strings; append the title/footer centered in the scene width
  " (computed, not hardcoded); then center the whole block in the window.
  let rows = map(copy(grid), 'substitute(join(v:val, ""), "\\s\\+$", "", "")')
  call add(rows, s:hcenter('✉ muaa 2026', scene_w))
  call add(rows, s:hcenter('cirnovsky', scene_w))
  let maxw = 0
  for l in rows | let maxw = max([maxw, strdisplaywidth(l)]) | endfor
  let indent = max([0, (width - maxw) / 2])
  let vpad = max([0, (winheight(0) - len(rows)) / 2])
  call map(rows, 'repeat(" ", indent) . v:val')
  let rows = repeat([''], vpad) + rows

  " Record the navigable folder cells (column span + cursor anchor on the name).
  let b:mailbox_cells = []
  for [name, c0, c1] in cellcols
    call add(b:mailbox_cells, {
          \ 'name':   name,
          \ 'cstart': indent + c0 + 1,
          \ 'cend':   indent + c1 + 1,
          \ 'line':   vpad + base + 4 + 1,
          \ 'col':    indent + (c0 + c1) / 2 + 1})
  endfor

  setlocal modifiable
  silent! 1,$delete _
  call setline(1, rows)
  setlocal nomodifiable nomodified
  call cursor(b:mailbox_cells[0].line, b:mailbox_cells[0].col)
endfunction

" Center a string in width `w` (computed leading pad, never hardcoded).
function! s:hcenter(s, w) abort
  return repeat(' ', max([0, (a:w - strdisplaywidth(a:s)) / 2])) . a:s
endfunction

" Display name: capitalize the first letter (inbox -> Inbox); already-caps names
" (TRASH) are unchanged.
function! s:cap(name) abort
  return toupper(a:name[0]) . a:name[1:]
endfunction

" Inner width of the boxed launcher: a comfy fixed 30, widened only if a label
" would otherwise not fit.
function! s:box_inner(names) abort
  let m = 30
  for name in a:names
    let m = max([m, strchars(' ▸  ' . s:cap(name)) + 2])
  endfor
  return m
endfunction

" First-tier fallback: a compact boxed menu (unicode box-drawing). Adaptive in
" height (one ▸ row per mailbox) and, if needed, width. Line-based navigation via
" the same b:mailbox_cells / cell_at / jump machinery. Centered like the scene.
function! s:render_box(names) abort
  let iw = s:box_inner(a:names)
  let bar = repeat('═', iw)

  " title row: ⚘ far left, '✉ muaa 2026' centered, ☠ far right
  let t = split(repeat(' ', iw), '\zs')
  let t[1] = '⚘'
  let t[iw - 2] = '☠'
  let mid = '✉ muaa 2026'
  let ms = (iw - strchars(mid)) / 2
  let mc = split(mid, '\zs')
  for k in range(len(mc)) | let t[ms + k] = mc[k] | endfor

  let rows = ['╔' . bar . '╗', '║' . join(t, '') . '║',
        \ '║' . s:center('cirnovsky', iw) . '║', '╠' . bar . '╣']
  let mbox0 = len(rows) + 1                    " 1-based line of the first mailbox
  for name in a:names
    let label = ' ▸  ' . s:cap(name)
    call add(rows, '║' . label . repeat(' ', iw - strchars(label)) . '║')
  endfor
  call add(rows, '╚' . bar . '╝')

  " center in the window, like the scene
  let width = get(g:, 'mail_launcher_width', winwidth(0))
  let indent = max([0, (width - (iw + 2)) / 2])
  let vpad = max([0, (winheight(0) - len(rows)) / 2])
  call map(rows, 'repeat(" ", indent) . v:val')
  let rows = repeat([''], vpad) + rows

  let b:mailbox_cells = []
  let i = 0
  for name in a:names
    call add(b:mailbox_cells,
          \ {'name': name, 'line': vpad + mbox0 + i, 'cstart': 1, 'cend': 9999,
          \  'col': indent + 1})
    let i += 1
  endfor

  setlocal modifiable
  silent! 1,$delete _
  call setline(1, rows)
  setlocal nomodifiable nomodified
  call cursor(b:mailbox_cells[0].line, b:mailbox_cells[0].col)
endfunction

" Fallback launcher for a very narrow window: the old plain list, one mailbox per
" line. Navigation is line-based — each cell owns a whole line — but the same
" b:mailbox_cells / cell_at / jump machinery drives it.
function! s:render_list(names) abort
  let b:mailbox_cells = []
  let i = 0
  for name in a:names
    call add(b:mailbox_cells,
          \ {'name': name, 'line': i + 1, 'cstart': 1, 'cend': 9999, 'col': 1})
    let i += 1
  endfor
  setlocal modifiable
  silent! 1,$delete _
  call setline(1, a:names)
  setlocal nomodifiable nomodified
  call cursor(1, 1)
endfunction

" The mailbox cell at the cursor: exact (line, column-span) match, else nearest
" by line then column. Works for both layouts (scene = one row many columns;
" list = one column many rows).
function! s:cell_at() abort
  let cells = get(b:, 'mailbox_cells', [])
  if empty(cells) | return {} | endif
  let ln = line('.')
  let cn = col('.')
  for cell in cells
    if cell.line == ln && cn >= cell.cstart && cn <= cell.cend | return cell | endif
  endfor
  let best = cells[0]
  let bd = [9999, 9999]
  for cell in cells
    let d = [abs(cell.line - ln), abs(cell.col - cn)]
    if d[0] < bd[0] || (d[0] == bd[0] && d[1] < bd[1])
      let best = cell | let bd = d
    endif
  endfor
  return best
endfunction

" <CR>: open the mailbox under the cursor in its own index buffer.
function! mail#mailboxlist#enter() abort
  let cell = s:cell_at()
  if empty(cell) | return | endif
  if cell.name ==# 'TRASH'
    call mail#trash#open()
  else
    call mail#index#open(cell.name)
  endif
endfunction

" hjkl move a whole mailbox at a time (dir = +1 next / -1 prev), landing on that
" mailbox's anchor. Works along the row (scene) or down the list (fallback).
function! mail#mailboxlist#jump(dir) abort
  let cells = get(b:, 'mailbox_cells', [])
  if empty(cells) | return | endif
  let cur = s:cell_at()
  let idx = 0
  for i in range(len(cells))
    if cells[i].name ==# get(cur, 'name', '') | let idx = i | break | endif
  endfor
  let idx = max([0, min([len(cells) - 1, idx + a:dir])])
  call cursor(cells[idx].line, cells[idx].col)
endfunction

" `:Mail` dispatch: no arg -> the launcher; a name -> that mailbox directly.
function! mail#mailboxlist#mail_cmd(name) abort
  call mail#mailbox#ensure_defaults()    " inbox/sent/archive exist on first :Mail
  if a:name ==# 'TRASH'
    call mail#trash#open()
    return
  endif
  call mail#index#preload_all()          " every mailbox buffer live from startup
  if a:name ==# ''
    call mail#mailboxlist#open()
  else
    call mail#index#open(a:name)
  endif
endfunction
