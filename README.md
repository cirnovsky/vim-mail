# vim-mail

A mail client in Vim.

Vim-native design. Everything is a buffer. Operations on emails map to operations in vim.

## Deps & Setup

macOS/Linux · Vim 8+ (`+job +timers +lambda +conceal`) · Python 3.9+ ·
`msmtp` (send) · `getmail6` (fetch)

`./setup_lazyass.sh` — use at discretion; writes `~/.msmtprc` + `~/.getmail/getmailrc`
(user-level, no `/etc`, no sudo). Linux has yet to be tested.

## Providers

Works with password/app password: Gmail, Yahoo, AOL, iCloud, Fastmail, Purelymail, Zoho, Yandex, GMX / Web.de, QQ / 163 / 126, self-hosted or generic IMAP+SMTP.

Does not work with normal password: Outlook / Hotmail / Microsoft 365, Google Workspace custom domains, Proton Mail except through paid Proton Bridge, Tuta.

## Use

`:Mail` = folder list; `<CR>` enters, `-` goes back, `:Mail <folder>` opens one
directly. Inside a folder:

| Key | Does |
|---|---|
| `<leader>f` | Fetch new mail |
| `<CR>` / `o` `v` | Open / quick preview in a split |
| `gx` / `gd` `gD` | In an open message: open the link/attachment under the cursor; jump between an inline `[N]` and its footer |
| `r` / `f` `F` | Reply / forward inline or as attachment |
| `<leader>c` | Compose |
| `x` / `gm` | HTML in browser / browse attachments |
| `/` `<leader>s` | Search headers / full text |
| `dd` | Delete — drop this folder's label (staged) |
| `dd`+`p` / `yy`+`p` | Move / copy: cut/yank, paste into another folder |
| `s` / `S` | Mark read / unread (staged) |
| `-` | Folder list (incl. `TRASH`) |

All changes are *staged*, and not *committed* until `:w`.

**Recovering deleted mail.** `dd` just drops a folder label — no trash box, undo
intact. But delete the *last* label and the message is fully removed; those show
up in **`TRASH`** (a read-only entry in the folder list). To get one back, open
`TRASH`, `yy` the line, and `p` it into any folder. `TRASH` keeps no memory of
where a message used to live, and never auto-empties.

Compose (`r`/`f`/`<leader>c`) sends on `:w`. `:Attach`/`<leader>A` = file,
`<leader>a` = clipboard file, `<leader>p` = clipboard image.

## Tricks

You can actually do cool things like:

- Bulk-move: `:g/pat/d A`, then `"ap` in the destination folder.

## Caveats

- Clipboard `<leader>a`/`<leader>p`: macOS built-in; Linux needs
  `xclip`/`wl-clipboard` (untested). `:Attach` works everywhere. No Windows.
- Inline forward (`f`) re-renders; use `F` for a byte-exact copy.
- Threading needs a `Message-ID`.

## TODO

- Merge OAuth support (Outlook/M365, Google Workspace) from `multi-account-oauth`.
- `:MailGC` to sweep orphaned canons from `.store`.
- Scale optimization · message reflow · actionable `[N]` link/attachment jumps.
- Vim-native operator keymaps (unify `s`/`S`/`dd`) · CI clipboard testing.
- First-fetch UX: a fresh machine (empty getmail oldmail) pulls the whole inbox
  with no progress — add progress/count feedback, and an oldmail bootstrap or a
  "recent N" backfill limit.
- Toolbar: an at-a-glance action/keymap hint bar for the index and launcher.
