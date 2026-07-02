# vim-mail

Email in Vim. Each message is a folder of plain files (attachments are real
files, not base64), stored **once** and filed into folders as labels — so one
message can live in several. The inbox is a Vim buffer: `dd` deletes, `:w`
commits, `/` searches.

**Provider-agnostic**: the plugin reads a local store and shells out to
`sendmail`. Works with any provider that allows account+password (app-password)
IMAP+SMTP — transport is just Postfix (send) + fetchmail (fetch).

## Setup

`./setup_lazyass.sh` — give it your email; it detects the provider, configures
the Postfix relay + `~/.fetchmailrc` + store, and prints the vimrc lines. Read it
first — it edits `/etc` (macOS-tested; Linux untested). Full reference:
**`mail-setup.md`**. OAuth-only providers (see table) need the
`multi-account-oauth` branch instead.

**Needs:** macOS/Linux · Vim 8+ (`+job +timers +lambda +conceal`) · Python 3.9+ ·
`fetchmail` · an account with an app password.

```vim
Plug '~/vim-mail'
let g:mail_root = '/path/to/Mail'
let g:mail_from = 'You <you@example.com>'
```

## Providers

Needs plain IMAP+SMTP with account+password auth. Most allow it via an app
password; a few force OAuth. As of mid-2026:

| Provider | Works? | Note |
|---|---|---|
| **Gmail** (consumer `@gmail.com`) | ✅ | app password (2-Step Verification) |
| **Yahoo**, **AOL** | ✅ | app password (2FA) |
| **iCloud** | ✅ | app-specific password (2FA) |
| **Fastmail** | ✅ | app password (IMAP needs a paid plan) |
| **Zoho** | ✅ | app password (2FA + IMAP on) |
| **Yandex** | ✅ | app password (enable IMAP) |
| **GMX / Web.de** | ✅ | enable IMAP, then password |
| **QQ / 163 / 126** | ✅ | authorization code |
| self-hosted / generic IMAP+SMTP | ✅ | password |
| **Outlook / Hotmail / Microsoft 365** | ❌ | OAuth only — basic auth gone |
| **Google Workspace** (custom domain) | ❌ | OAuth only (since May 2025) |
| **Proton Mail** | ⚠️ | only via the paid Proton **Bridge** |
| **Tuta** | ❌ | no IMAP/SMTP at all |

✅ works with `setup_lazyass.sh`. ❌ (OAuth) needs the `multi-account-oauth`
branch. Proton: point the installer at the Bridge's `127.0.0.1`.

## Use

`:Mail` = folder list; `<CR>` enters, `-` goes back, `:Mail <folder>` opens one
directly. Inside a folder:

| Key | Does |
|---|---|
| `<leader>f` | Fetch new mail |
| `<CR>` / `o` `v` | Open / quick preview in a split |
| `r` / `f` `F` | Reply / forward inline or as attachment |
| `<leader>c` | Compose |
| `x` / `gm` | HTML in browser / browse attachments |
| `/` `<leader>s` | Search headers / full text |
| `dd` | Delete — drop this folder's label (staged) |
| `dd`+`p` / `yy`+`p` | Move / copy: cut/yank, paste into another folder |
| `s` / `S` | Mark read / unread (staged) |
| `-` / `q` | Folder list / close |

Deletes, read-marks, and moves are **staged** — nothing hits disk until `:w`, and
`u` reverts them (even after `:w`). Deleting drops a folder label; the last one
falling sends the message to `trash/`. Even emptying trash only orphans the bytes
— nothing is destroyed. Move = `dd` here + `p` in another folder (`yy`+`p` =
copy); one `:w` commits both. No move *command* — the folder list makes the
destination one keystroke away.

Compose (`r`/`f`/`<leader>c`) sends on `:w`. `:Attach`/`<leader>A` = file,
`<leader>a` = clipboard file, `<leader>p` = clipboard image.

## Tricks

**Bulk-move by pattern:** `:g/pat/d A` (append each match to register `a`), then
`"ap` in the destination folder, `:w`. Plain `:g/pat/d`+`p` moves only the *last*
match — each `:d` overwrites the unnamed register; an uppercase register appends.
(Lowercase = overwrite, uppercase = append — true of any register.)

A message you `s`-mark read **and** move in the same `:w` lands **unread** — the
staged mark doesn't survive the move. Mark read after moving.

## Caveats

- Clipboard `<leader>a`/`<leader>p`: macOS built-in; Linux needs
  `xclip`/`wl-clipboard` (untested). `:Attach` works everywhere. No Windows.
- Inline forward (`f`) re-renders; use `F` for a byte-exact copy.
- Threading needs a `Message-ID`.

## TODO

- Merge OAuth support (Outlook/M365, Google Workspace) from `multi-account-oauth`.
- `:MailGC` to sweep orphaned canons from `.store`.
- Scale optimization · message reflow · actionable `[N]` link/attachment jumps.
- Vim-native operator keymaps (unify `t`/`s`/`S`/`dd`) · CI clipboard testing.

Deeper: **`mail-setup.md`**.
