# vim-mail

Email inside Vim. Each message is a folder of plain files (attachments are real
files, not base64), stored **once** and filed into folders as labels — so it can
live in several at once. The inbox is a Vim buffer: `dd` to delete, `:w` to
commit, `/` to search.

The plugin and backend are **provider-agnostic** — they read a local store and
shell out to `sendmail`. It works with **any mail provider that allows
account + password (app-password / authorization-code) access over IMAP+SMTP**;
transport is just Postfix (send) + fetchmail (fetch). Three one-time parts:
**outbound** (relay through your provider's SMTP), **inbound** (`fetchmail` →
local store), **plugin** (`:Mail`).

## Setup

**Lazy:** `./setup_lazyass.sh` — give it your email; it detects the provider
(Gmail, Yahoo, iCloud, Fastmail, Zoho, Yandex, GMX, QQ, 163/126, or asks for the
hosts), then configures the Postfix relay, `~/.fetchmailrc`, and the store, and
prints the vimrc lines. Read it first — it edits `/etc` (macOS-tested; Linux
untested). Manual steps + full reference: **`mail-setup.md`**.

Providers that **force OAuth** (Outlook.com / Microsoft 365, Google Workspace
custom domains) aren't handled by this installer — use the `multi-account-oauth`
branch (getmail + msmtp + OAuth). See the compatibility table below.

**Needs:** macOS or Linux · Vim 8+ (`+job +timers +lambda +conceal`) · Python
3.9+ · `fetchmail` · a mail account whose provider allows an app password /
authorization code (see the table below).

**vimrc:**

```vim
Plug '~/vim-mail'
let g:mail_root = '/path/to/Mail'
let g:mail_from = 'Your Name <you@gmail.com>'
```

## Provider compatibility

vim-mail needs plain IMAP+SMTP with account+password auth. Most providers still
allow it via an **app password** (or "authorization code"); the notable holdouts
force OAuth. As of mid-2026:

| Provider | Account + password? | How / note |
|---|---|---|
| **Gmail** (consumer `@gmail.com`) | ✅ | app password (needs 2-Step Verification) |
| **Yahoo**, **AOL** | ✅ | app password (needs 2FA) |
| **iCloud Mail** | ✅ | app-specific password (needs 2FA) |
| **Fastmail** | ✅ | app password (IMAP needs a paid plan) |
| **Zoho Mail** | ✅ | app password (2FA + IMAP enabled) |
| **Yandex Mail** | ✅ | app password (enable IMAP) |
| **GMX / Web.de** | ✅ | enable IMAP in settings, then password |
| **QQ / 163 / 126** | ✅ | authorization code (enable IMAP/SMTP) |
| Generic / self-hosted IMAP+SMTP | ✅ | password / app password |
| **Outlook.com / Hotmail / Microsoft 365** | ❌ **OAuth only** | basic auth removed; SMTP AUTH gone by Apr 2026 |
| **Google Workspace** (custom-domain Gmail) | ❌ **OAuth only** | app-password IMAP disabled May 2025 |
| **Proton Mail** | ⚠️ **via Bridge** | needs paid Proton Mail **Bridge** (local IMAP/SMTP) |
| **Tuta** (Tutanota) | ❌ **none** | no IMAP/SMTP at all — apps only |

The ✅ rows work with `setup_lazyass.sh` on `main`. The ❌ **OAuth-only** rows
need the `multi-account-oauth` branch (getmail + msmtp + OAuth). Proton works via
its Bridge (point the installer at the Bridge's `127.0.0.1` IMAP/SMTP); Tuta can't
be supported by any standard mail client.

## Use

`:Mail` shows a read-only list of your folders; `<CR>` enters one, `-` goes back
(`:Mail <folder>` opens one directly). Inside a folder:

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

Deletes, read-marks, and moves are **staged** — nothing hits disk until `:w`, and
`u` reverts them (even after `:w`). A message carries folder-labels; deleting
drops one, and the last one falling sends it to `trash/`. Even deleting from trash
only orphans the bytes in the store — nothing is destroyed, so it stays
recoverable. Move is `dd` here + `p` in another folder's buffer (`yy`+`p` to
copy) — one `:w` commits it. There's no move/copy *command*; the folder list (`-`)
makes opening the destination to paste into one keystroke.

Compose buffers (`r`/`f`/`<leader>c`) send on `:w`. `:Attach`/`<leader>A` attach a
file, `<leader>a` a clipboard file, `<leader>p` a clipboard image inline.

## Tricks

**Bulk-move by pattern.** `dd`+`p` moves one message. To move *every* message
matching a pattern at once, collect them into a named register with a
**capital-letter (append) register**, then paste into the destination folder:

```vim
:g/invoice/d A      " delete each matching line, APPENDING it to register a
```

then open the destination (`-` to the folder list, `<CR>` to enter it), `"ap`,
and `:w`.

Why the capital `A`? `:g/pat/d` runs a *separate* delete per match, and each
delete **overwrites** the unnamed register — so plain `:g/pat/d` + `p` pastes
only the last match. An uppercase register **appends**, so register `a`
accumulates every match and `"ap` pastes them all. (Lowercase = overwrite,
uppercase = append — for any register: `"Ayy`, `:g/pat/y A`, …)

Note: a message you `s`-mark read and move in the *same* `:w` lands **unread** —
the staged read-mark doesn't survive a move. Mark read after moving, or in a
separate `:w`.

## Caveats

- Clipboard `<leader>a`/`<leader>p`: macOS out of the box; Linux needs
  `xclip`/`wl-clipboard` (untested). `:Attach` works everywhere. No Windows.
- Inline forward (`f`) re-renders; use `F` for a byte-exact copy.
- Threading needs a `Message-ID`.

## TODO

- OAuth providers on `main` (Outlook/M365, Google Workspace) — done on the
  `multi-account-oauth` branch; not yet merged. (Account+password providers work
  today — the app is provider-agnostic; see the compatibility table.)
- Optimization at scale.
- Message reflow/formatting.
- Actionable link/attachment placeholders + `[N]` jumps.
- Vim-native operator keymaps (unify `t`/`s`/`S`/`dd`).
- Optional batch `:M`/`:Move` command (dropped for now; move is `dd`+`p`).
- CI clipboard (xclip) testing.
- `:MailGC` to sweep orphaned canons from `.store` (delete keeps bytes so it stays undoable).

Deeper: **`mail-setup.md`**.
