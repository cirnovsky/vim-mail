" Small shared helpers.
" Part of vim-mail; the frontend never parses MIME (that's mail_store.py).

" Base 'python3 /path/to/mail_store.py' command (g:mail_store_cmd minus its
" trailing ' ingest-stdin' — that suffix is the ingest-MDA form the getmailrc
" uses; py_cmd strips it for the send/quote/viewhtml subcommands).
function! mail#util#py_cmd() abort
  return substitute(g:mail_store_cmd, '\s\+ingest-stdin$', '', '')
endfunction

" --- portable async jobs (Vim job_start / Neovim jobstart) -----------------
" Vim's job API and Neovim's differ in both the spawn call and the stdout
" callback shape (Vim calls out_cb(ch, msg) once per line; Neovim calls
" on_stdout(id, list, ev) where the list's first element continues the previous
" chunk and the last is a partial line). This shim takes Vim-style opts
" {out_cb, err_cb, exit_cb, detach} and adapts to whichever host, so callers keep
" one code path and their existing (ch,msg)/(job,status) callbacks.
function! mail#util#job_start(cmd, opts) abort
  if !has('nvim')
    let vopts = {}
    for k in ['out_cb', 'err_cb', 'exit_cb']
      if has_key(a:opts, k) | let vopts[k] = a:opts[k] | endif
    endfor
    " Vim kills the job on exit by default; '' lets a detached opener outlive us.
    if get(a:opts, 'detach', 0) | let vopts.stoponexit = '' | endif
    return job_start(a:cmd, vopts)
  endif
  let nopts = {}
  if has_key(a:opts, 'out_cb')
    let Ocb = a:opts.out_cb | let ob = ['']
    let nopts.on_stdout = {id, d, ev -> mail#util#_nvim_lines(ob, Ocb, d)}
  endif
  if has_key(a:opts, 'err_cb')
    let Rcb = a:opts.err_cb | let eb = ['']
    let nopts.on_stderr = {id, d, ev -> mail#util#_nvim_lines(eb, Rcb, d)}
  endif
  if has_key(a:opts, 'exit_cb')
    let Ecb = a:opts.exit_cb
    let nopts.on_exit = {id, code, ev -> call(Ecb, [id, code])}
  endif
  if get(a:opts, 'detach', 0) | let nopts.detach = v:true | endif
  return jobstart(a:cmd, nopts)
endfunction

" Neovim on_stdout/on_stderr: the data list's first element continues the
" previous chunk and its last element is a partial line — reassemble across calls
" (a:buf is the persistent 1-element carry, mutated in place) and emit each
" complete line as Cb(0, line), matching Vim's per-line out_cb. A final
" unterminated line is left buffered; the plugin's job output is line-terminated.
" Public (not s:) so it's unit-testable under Vim without a live Neovim.
function! mail#util#_nvim_lines(buf, Cb, data) abort
  let a:buf[-1] .= a:data[0]
  call extend(a:buf, a:data[1:])
  while len(a:buf) > 1
    call call(a:Cb, [0, remove(a:buf, 0)])
  endwhile
endfunction

" Is the job still running? (v:null = never started.)
function! mail#util#job_running(job) abort
  if a:job is v:null | return 0 | endif
  return has('nvim') ? jobwait([a:job], 0)[0] == -1 : job_status(a:job) ==# 'run'
endfunction
