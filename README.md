# vim-mail

Email inside Vim. Each message is a folder of plain files (attachments are real
files, not base64), stored **once** and filed into folders as labels — so it can
live in several at once. The inbox is a Vim buffer: `dd` to delete, `:w` to
commit, `/` to search.

Three one-time parts: **outbound** (relay through Gmail SMTP), **inbound**
(`fetchmail` → local store), **plugin** (`:Mail`).

## Setup

**Lazy:** `./setup_lazyass.sh` — prompts for your Gmail address, app password, and
store path; configures the Postfix→Gmail relay, `~/.fetchmailrc`, and the store;
prints the vimrc lines. Read it first — it edits `/etc` (macOS-tested; Linux
untested). Manual steps + full reference: **`mail-setup.md`**.

**Needs:** macOS or Linux · Vim 8+ (`+job +timers +lambda +conceal`) · Python
3.9+ · `fetchmail` · a Gmail account with 2-Step Verification and an
[app password](https://myaccount.google.com/apppasswords).

**vimrc:**

```vim
Plug '~/vim-mail'
let g:mail_root = '/path/to/Mail'
let g:mail_from = 'Your Name <you@gmail.com>'
```

## Use

`:Mail` opens the inbox.

`:Mail` shows a read-only list of your folders; `<CR>` enters one, `-` goes back.
Inside a folder:

| Key | Does |
|---|---|
| `<leader>f` | Fetch new mail |
| `<CR>` / `o` `v` | Open message / quick preview in a split |
| `r` / `f` `F` | Reply / forward inline or as attachment |
| `<leader>c` | Compose |
| `x` / `gm` | HTML in browser / browse attachments |
| `/` `<leader>s` | Search headers / full text |
| `dd` | Delete — drop this folder's label (staged; `:w` commits) |
| `dd`+`p` / `yy`+`p` | Move / copy: cut/yank here, paste into another folder buffer |
| `s` / `S` | Mark read / unread (staged) |
| `-` / `q` | Up to the folder list / close |

Deletes, read-marks, and moves are **staged** — nothing hits disk until `:w`. A
message carries folder-labels; deleting drops one, and the last one falling sends
it to `trash/`. Move is `dd` here + `p` in another folder's buffer (`yy`+`p` to
copy) — one `:w` commits it. There's no move/copy *command*; the folder list (`-`)
makes opening the destination to paste into one keystroke.

Compose buffers (`r`/`f`/`<leader>c`) send on `:w`. `:Attach`/`<leader>A` attach a
file, `<leader>a` a clipboard file, `<leader>p` a clipboard image inline.

**Upgrading an old store:** run `:MailMigrate` once (or `mail_store.py
migrate-store /path/to/Mail`) — converts to the shared-storage layout, safe and
resumable, dedupes cross-folder copies. Old mail keeps working until you do.

## Caveats

- Clipboard `<leader>a`/`<leader>p`: macOS out of the box; Linux needs
  `xclip`/`wl-clipboard` (untested). `:Attach` works everywhere. No Windows.
- Inline forward (`f`) re-renders; use `F` for a byte-exact copy.
- Threading needs a `Message-ID`.

## TODO

- Non-Gmail providers (SMTP/IMAP hardcoded to Gmail).
- Optimization at scale.
- Message reflow/formatting.
- Actionable link/attachment placeholders + `[N]` jumps.
- Vim-native operator keymaps (unify `t`/`s`/`S`/`dd`).
- Optional batch `:M`/`:Move` command (dropped for now; move is `dd`+`p`).
- CI clipboard (xclip) testing.
- undo after saving — currently after `:w` undo history will be lost.

Deeper: **`mail-setup.md`**.
