" Fetching mail via fetchmail (async).
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

let s:fetch_job       = v:null
let s:fetch_dir       = ''
let s:fetch_before    = {}

function! mail#fetch#_snapshot_dirs(dir) abort
  let result = {}
  for path in glob(a:dir . '/*', 0, 1)
    if isdirectory(path) && fnamemodify(path, ':t') !~# '^\.'
      let result[path] = 1
    endif
  endfor
  return result
endfunction

" Runs fetchmail asynchronously; prompts for target inbox dir (default:
" current index buffer's dir, or ~/Mail/inbox). Passes --mda on the CLI so
" each inbox can be fetched into a different directory without editing
" ~/.fetchmailrc. New-mail count is echoed on completion; no quickfix.
function! mail#fetch#fetch() abort
  if s:fetch_job isnot v:null && job_status(s:fetch_job) ==# 'run'
    echo 'A fetch is already in progress'
    return
  endif
  " No staged-edit guard: the completion repaint (refresh_for) merges new mail
  " into a modified buffer instead of rebuilding it, so staged edits survive.
  let default_dir = exists('b:mail_dir') ? b:mail_dir : mail#mailbox#_resolve_mailbox('inbox')
  let default_name = fnamemodify(default_dir, ':t')
  let chosen = mail#mailbox#_prompt_mailbox('Fetch into mailbox [' . default_name . ']', '')
  let target = chosen ==# '' ? default_dir : mail#mailbox#_resolve_mailbox(chosen)
  if !isdirectory(target)
    echohl ErrorMsg | echom 'Not a directory: ' . target | echohl None
    return
  endif
  let s:fetch_dir = target
  let s:fetch_before = mail#fetch#_snapshot_dirs(target)
  let mda = g:mail_store_cmd . ' ' . shellescape(target)
  echo 'Fetching into ' . target . ' ...'
  let s:fetch_job = job_start(['fetchmail', '-v', '-N', '--mda', mda], {
        \ 'exit_cb': 'mail#fetch#_fetch_exit_cb',
        \ })
endfunction

function! mail#fetch#_fetch_exit_cb(job, status) abort
  let after = mail#fetch#_snapshot_dirs(s:fetch_dir)
  let new_dirs = []
  for path in keys(after)
    if !has_key(s:fetch_before, path)
      call add(new_dirs, path)
    endif
  endfor

  " fetchmail exit 1 = no messages (normal); anything else is a real error
  if a:status != 0 && a:status != 1
    echohl ErrorMsg
    echom 'fetchmail exited with status ' . a:status
    echohl None
  endif

  if empty(new_dirs)
    echom 'No new mail.'
  else
    echom len(new_dirs) . ' new message(s) in ' . fnamemodify(s:fetch_dir, ':~')
  endif

  call mail#index#refresh_for(s:fetch_dir)
endfunction
