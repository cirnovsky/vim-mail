# vim-mail

Read and write emails from inside Vim. Each message is a folder of
plain files (so attachments are real files, not base64 blobs), and
the inbox is a normal Vim buffer — `dd` to delete, `:w` to commit,
`/` to search.

It has three parts you set up once, in order:

1. **Outbound** — your machine relays mail through Gmail's SMTP.
2. **Inbound** — `fetchmail` pulls new mail into a local folder
store.  3. **The plugin** — `:Mail` opens the store in Vim.

---

## Quick start (lazy mode)

If you just want it working, clone the repo and run:

```bash
./setup_lazyass.sh
```

It prompts for your Gmail address, app password, and where to keep
the mail store (and your sudo password, for `/etc`), then does the
rest — installs deps, configures the Postfix→Gmail relay in `/etc`
(with backups, idempotent), writes `~/.fetchmailrc`, creates the
store, and verifies the login. So everything. At the end it prints
the three vimrc lines to add (the one manual step, since plugin
managers vary).

> **Read it before you run it.** This script edits system files
> (`/etc/postfix/…`), (re)starts Postfix, and writes `~/.fetchmailrc`.
> It backs up everything it changes to `*.vimmail.<timestamp>.bak`.
> macOS is tested; the **Linux** path (apt/dnf/pacman, systemctl,
> CA-bundle probing) is **UNTESTED** — if anything looks
> off for your machine, follow the manual steps instead.

Prefer to understand each piece? The manual steps below are the
same thing, broken out.

---

## Requirements

- macOS (Postfix is built in) or Linux - Vim 8+ (with `+job +timers
+lambda +conceal`), Python 3.9+ - `fetchmail` (`brew install
fetchmail`) - A Gmail account with **2-Step Verification** on, and
an **app password**
  (create one at <https://myaccount.google.com/apppasswords>)

Throughout, use your Gmail address and that app password (not your
normal password).

---

## 1. Outbound: relay through Gmail

Append to `/etc/postfix/main.cf`:

```ini relayhost = [smtp.gmail.com]:587 smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous smtp_tls_security_level =
encrypt smtp_tls_CAfile = /etc/ssl/cert.pem inet_protocols = ipv4
smtp_sasl_mechanism_filter = plain ```

The `smtp_tls_CAfile` path is for macOS. On Linux use your distro's
CA bundle — `/etc/ssl/certs/ca-certificates.crt` (Debian/Ubuntu)
or `/etc/pki/tls/certs/ca-bundle.crt` (RHEL/Fedora). On Linux you
also need to install Postfix first (`apt install postfix` / `dnf
install postfix`); macOS ships it.

Create `/etc/postfix/sasl_passwd` with your credentials:

``` [smtp.gmail.com]:587    you@gmail.com:your-app-password ```

Then compile it and (re)start Postfix:

```bash sudo chmod 600 /etc/postfix/sasl_passwd sudo postmap
/etc/postfix/sasl_passwd sudo postfix start      # macOS doesn't
auto-start it sudo postfix reload ```

On Linux, Postfix runs under systemd instead — use `sudo systemctl
enable --now postfix` (and `sudo systemctl reload postfix`).

Check it works:

```bash echo "hello from vim-mail" | sendmail you@gmail.com ```

The mail should arrive in your inbox. (Gmail rewrites the `From:`
line to your real address automatically — that's expected.)

---

## 2. Install the plugin

Clone the repo anywhere, point your plugin manager at it, and create
the store folder:

```bash git clone https://github.com/cirnovsky/vim-mail ~/vim-mail
mkdir -p /path/to/Mail/inbox /path/to/Mail/sent ```

In your vimrc:

```vim Plug '~/vim-mail'                                  " or
wherever you cloned it let g:mail_root = '/path/to/Mail'
" where all mail is stored let g:mail_from = 'Your Name <you@gmail.com>'
" your From: line ```

---

## 3. Inbound: fetch mail into the store

`fetchmail` downloads new mail and hands each message straight to
vim-mail's store. The config has one machine-specific line — let
the repo write it for you:

```bash cd ~/vim-mail
./setup.sh           # prints the exact ~/.fetchmailrc to copy
# or:
./setup.sh --patch   # updates an existing ~/.fetchmailrc in place
```

Your `~/.fetchmailrc` should look like this (keep it `chmod 600`):

``` poll imap.gmail.com protocol IMAP
    user "you@gmail.com" with password "your-app-password" is
    "your-mac-username" here ssl mda "/path/to/python3
    /path/to/vim-mail/scripts/mail_store.py ingest-stdin
    /path/to/Mail/inbox"
```

```bash chmod 600 ~/.fetchmailrc ```

**One Gmail setting:** so that deleting mail in vim-mail actually
deletes it, go to Gmail → Settings → *Forwarding and POP/IMAP* →
set *"When a message is marked as deleted"* to **"Immediately delete
the message forever"**.

---

## 4. Use it

```vim :Mail            " open your inbox ```

Then, in the inbox buffer:

| Key | Does | |---|---| | `<leader>f` | Fetch new mail | | `<CR>`
| Open a message (with the quoted thread) | | `o` / `v` | Quick
preview in a split | | `r` | Reply | | `f` / `F` | Forward inline
/ forward as an attachment | | `<leader>c` | Compose a new message
| | `x` | Open the HTML version in your browser | | `gm` | Browse
the message's attachments | | `/` | Search From/Subject; `<leader>s`
searches full text | | `dd` | Delete (staged) — `:w` to commit, `u`
to undo | | `M` | Move to another folder | | `s` / `S` | Mark read
/ unread (staged) | | `q` | Close |

Deletes, reads, and moves are **staged** like normal edits — nothing
touches disk until you `:w`. Deleted mail goes to a `trash/` folder
under your mail root (recoverable with `M`).

**Writing mail.** `r`, `f`, `<leader>c` open a compose buffer; just
`:w` to send.  While composing:

| Key | Does | |---|---| | `:Attach path` or `<leader>A` | Attach
a file (Tab-completes; accepts several / globs) | | `<leader>a` |
Attach the file(s) you copied to the clipboard | | `<leader>p` |
Paste a clipboard image (screenshot or image file) inline |

Replies and forwards keep formatting and inline images intact, and
stay in the same Gmail thread.

---

## Caveats

- **Clipboard support.** `<leader>a` (clipboard files) and
  `<leader>p` (clipboard image) work out of the box on macOS with no
  extra tools. On Linux they need `xclip` or `wl-clipboard`. The
  `xclip` **image**-paste path is covered by the Linux test
  (`make test-linux`, run under Xvfb); the `wl-clipboard`/Wayland path
  and the clipboard **file**-list path stay untested there, and the
  latter may not pick up files copied from GNOME Files. Attaching by
  path (`:Attach`) works everywhere. Windows isn't supported.
- **Inline forward (`f`) is a re-render**, like Gmail's — it
reproduces the
  content but isn't a byte-exact copy. Use **`F`** (forward as
  attachment) when you need the original email passed along untouched.
- **Threading** needs a `Message-ID`; very old archived mail without
one won't
  thread.

---

## TODO

- **Image-file copy bug** — pasting a *screenshot* inline (`<leader>p`)
works,
  but pasting a *copied image file* doesn't yet.
- **Non-Gmail providers** — SMTP/IMAP hosts are currently hardcoded
to Gmail;
  make them configurable.
- **Modularization & optimization** — split up the larger files;
perf at scale.  - **`<CR>` full-screen open** — open a message
full-screen instead of in a split.  - **Message formatting** —
format/reflow the message body.  - **Actionable placeholders** —
open links/attachments and jump between the
  `[N]` markers and their footer entries in a message view.
- **Non-destructive refresh** — let `M`/`<leader>f` keep staged
edits instead of
  prompting (today they warn before discarding).
- **Rethink the marking/operator keymaps** — reconsider the `t`/`tt`
  toggle-mark mapping, and lean into Vim-native operator semantics so
  actions (move, mark read/unread, delete) work uniformly with motions,
  counts, ranges, and `:g` — instead of today's mix of operator (`t`),
  targets-or-current (`s`/`S`/`M`), and native (`dd`).

---

## Anything deeper?

`mail-setup.md` has the full technical reference — how messages are
stored, how sending builds MIME, the test suite, and the relay-debugging
notes.
