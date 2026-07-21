" muaa-init.vim — boots Vim as a standalone modal mail client (vim-mail only).
" Loaded via `vim -u muaa-init.vim -c Mail` (the `muaa` launcher does this), so
" your ~/.vimrc and other plugins are NOT sourced — this is a clean mail app that
" happens to be Vim, which is exactly why gx/gf/marks/registers/:cmds all work.

set nocompatible

" Clean runtimepath: just Vim's own runtime (keeps netrw, so `gx` works) plus
" this repo. Drops ~/.vim and your other plugins for a dedicated environment.
let &runtimepath = $VIMRUNTIME
let s:repo = expand('<sfile>:p:h')
execute 'set runtimepath^=' . fnameescape(s:repo)

filetype plugin indent on
syntax on

" App feel: no editor-chrome noise, no swap clutter, window titled 'muaa'.
set hidden noswapfile nobackup nowritebackup
set laststatus=2 noshowmode belloff=all mouse=
set shortmess+=I
set title titlestring=muaa

" --- Mail store + identity ------------------------------------------------
" Store: defaults to the plugin's ~/Mail; override with $MUAA_MAIL_ROOT or in
" ~/.config/muaa/config.vim. Identity: read from ~/.msmtprc (single source of
" truth) when present, so the From isn't duplicated.
if $MUAA_MAIL_ROOT !=# ''
  let g:mail_root = $MUAA_MAIL_ROOT
endif
if filereadable(expand('~/.msmtprc'))
  let s:from = trim(system("awk '$1==\"from\" {print $2; exit}' " . expand('~/.msmtprc')))
  if s:from !=# '' | let g:mail_from = s:from | endif
endif

" Personal overrides: paths, a From with a display name, extra keymaps, colours.
if filereadable(expand('~/.config/muaa/config.vim'))
  source ~/.config/muaa/config.vim
endif

" The plugin (plugin/mail.vim) auto-loads at startup from the runtimepath above;
" the launcher's `-c Mail` then opens the mailbox list.
