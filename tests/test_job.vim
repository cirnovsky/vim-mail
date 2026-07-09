" mail#util#job_start / job_running — the portable async-job shim. Runs under
" whatever editor executes it: Vim (its job_start) in CI, and the SAME code path
" drives Neovim's jobstart when run under nvim. Asserts the stdout callback gets
" reassembled complete lines (Neovim delivers a list with a trailing partial),
" the exit callback fires with the status, and job_running tracks liveness.
"
" Run:  vim -u NONE -N -es -S tests/test_job.vim   (or: nvim -u NONE ... )

let s:repo = expand('<sfile>:p:h:h')
execute 'set rtp+=' . fnameescape(s:repo)
runtime plugin/mail.vim
runtime! autoload/mail/*.vim

let s:lines = []
let s:status = -2
function! s:out(ch, msg) abort
  call add(s:lines, a:msg)
endfunction
function! s:exit(job, status) abort
  let s:status = a:status
endfunction

function! Test_job_lines_and_exit() abort
  let s:lines = []
  let s:status = -2
  let job = mail#util#job_start(['/bin/sh', '-c', 'printf "one\ntwo\nthree\n"'],
        \ {'out_cb': function('s:out'), 'exit_cb': function('s:exit')})
  let waited = 0
  while s:status == -2 && waited < 5000
    sleep 20m
    let waited += 20
  endwhile
  call assert_equal(0, s:status, 'exit_cb fired with status 0')
  call assert_equal(['one', 'two', 'three'], s:lines, 'out_cb got complete lines')
  call assert_false(mail#util#job_running(job), 'job_running false after exit')
  call assert_false(mail#util#job_running(v:null), 'job_running false for v:null')
endfunction

" The Neovim stdout contract, unit-tested under Vim: on_stdout gets a list whose
" first element continues the previous chunk and whose last is a partial line.
" mail#util#_nvim_lines must stitch a line split across chunks and emit only
" complete lines (leaving the trailing partial buffered).
function! Test_nvim_line_reassembly() abort
  let s:lines = []
  let buf = ['']
  " 'three' is split: 'thr' arrives in chunk 1's partial, 'ee' completes it next.
  call mail#util#_nvim_lines(buf, function('s:out'), ['one', 'two', 'thr'])
  call assert_equal(['one', 'two'], s:lines, 'complete lines emitted, partial held')
  call mail#util#_nvim_lines(buf, function('s:out'), ['ee', 'four', ''])
  call assert_equal(['one', 'two', 'three', 'four'], s:lines, 'split line stitched')
  call assert_equal([''], buf, 'only the trailing empty partial remains')
endfunction

let v:errors = []
for s:t in ['Test_job_lines_and_exit', 'Test_nvim_line_reassembly']
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
