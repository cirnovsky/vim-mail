# vim-mail backend setup (Postfix relay + fetchmail + store)

The vim-mail plugin is a frontend over a one-folder-per-message mail store.
Underneath it needs three things wired up:

1. **Outbound** — Postfix relaying through Gmail SMTP, so `mail_store.py send`
   (called on `:w` from a compose buffer) actually delivers.
2. **Inbound** — fetchmail pulling new Gmail messages straight into the store
   via an MDA, so `<leader>f` has something to refresh.
3. **The plugin itself** — `:Mail`, the index buffer, keymaps.

This document covers all three, plus the non-obvious failures hit while
setting up the relay (kept because they're hard to rediscover).

> History: this setup evolved from stock BSD `mail` → s-nail/neomutt → the
> vim-mail frontend. The reader tutorials for those superseded tools have
> been removed; only the infrastructure vim-mail still depends on remains.

## 1. Outbound relay (Postfix → Gmail SMTP)

### Goal
Relay locally-submitted mail through `smtp.gmail.com:587` with SASL auth, so
`sendmail -t` (which `mail_store.py send` shells out to) reaches the internet.

### Config applied
`/etc/postfix/main.cf` (appended):

```ini
relayhost = [smtp.gmail.com]:587
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_tls_security_level = encrypt
smtp_tls_CAfile = /etc/ssl/cert.pem
inet_protocols = ipv4
smtp_sasl_mechanism_filter = plain
```

`/etc/postfix/sasl_passwd` (mode `600`, root-owned, compiled with `postmap`):

```
[smtp.gmail.com]:587    youraddress@gmail.com:your-app-password
```

Credential generated at https://myaccount.google.com/apppasswords (requires
2-Step Verification on the Google account).

### Failures hit, and how each was diagnosed

| Symptom | Diagnosis command | Root cause | Fix |
|---|---|---|---|
| `postfix reload` → `fatal: the Postfix mail system is not running` | `launchctl print system/org.postfix.master` | macOS doesn't auto-start Postfix; it's launched on demand | `sudo postfix start` first |
| `mailq` showed `connect to smtp.gmail.com: No route to host` | `nc -zv -4 smtp.gmail.com 587` vs `nc -zv -6 smtp.gmail.com 587` | Network had no IPv6 route to Gmail; Postfix tried IPv6 first | `inet_protocols = ipv4` |
| `SASL authentication failed: generic failure` (no further detail) | `/usr/bin/log show --last 5m --predicate 'process == "smtp"' --info` only repeated the generic error | Postfix's log message is too vague to tell credentials-vs-library issue apart | wrote a standalone Python `smtplib` test script (below) to isolate the variable |
| Standalone Python test (`smtplib.SMTP(...).login(...)`) → `AUTH OK` | n/a | Confirmed credentials were correct; the bug was Postfix/Cyrus-SASL specific (a known macOS quirk negotiating SASL mechanisms) | `smtp_sasl_mechanism_filter = plain` forces Postfix to request `AUTH PLAIN` directly |

Standalone credential-isolation script used for the auth diagnosis:

```python
import smtplib, getpass

user = input("Gmail address: ").strip()
pw = getpass.getpass("App password: ")
s = smtplib.SMTP("smtp.gmail.com", 587, timeout=10)
s.ehlo(); s.starttls(); s.ehlo()
s.login(user, pw)
print("AUTH OK")
```

This pattern — reproduce the failure in the smallest possible tool outside
the system you're debugging — is what separated "bad credentials" from "bad
Postfix SASL config" without ever needing to put the password in a chat
transcript or log file.

### A red herring: the `From:` header

Early on, a test message sent to an external inbox didn't show up there
immediately, and the message Postfix generated had
`From: cirnovsky@<hostname>.local` (from `myorigin`/`myhostname`) rather than
the real Gmail address. This looked like it would need a `smtp_generic_maps`
rewrite to fix — but it turned out **unnecessary**: Gmail's SMTP relay
rewrites the `From:` header server-side to match the authenticated account
regardless of what the submitting client sends, as an anti-spoofing
measure. Confirmed via:

- [Atlassian KB: "Google will rewrite the From field if you do not own the email address being used"](https://confluence.atlassian.com/confkb/when-using-gmail-as-an-smtp-server-the-from-address-is-wrong-710837471.html)
- [SMTP2GO: Gmail enforces sender identity / DMARC alignment on relay](https://www.smtp2go.com/blog/avoid-gmails-behalf-message-use-different-smtp-server/)

The original missing-from-inbox case was just normal delivery lag between
the Sent-folder copy and inbox delivery, not a spam-filter rejection.

## 2. Inbound: fetchmail → the store

```bash
brew install fetchmail
```

`~/.fetchmailrc` (mode `600`) routes each fetched message straight into the
store via an MDA, instead of local Postfix delivery into `/var/mail/$USER`:

```
poll imap.gmail.com protocol IMAP
    user "youraddress@gmail.com" with password "your-app-password" is "yourlocalunixuser" here
    ssl
    mda "/path/to/python3 /path/to/vim-mail/scripts/mail_store.py ingest-stdin /path/to/Mail/inbox"
```

This `mda` line is the only path that lives outside the repo and can't be
auto-resolved. Run `./setup.sh` in the repo to print the exact line for the
current machine, or `./setup.sh --patch` to rewrite an existing
`~/.fetchmailrc`'s `mda` in place (backs up first; preserves password and
inbox target).

Run on demand:

```bash
fetchmail -v        # single poll, verbose
fetchmail -c        # check what's pending without retrieving
```

Useful flags: `-a`/`--all` (retrieve old messages too, not just unseen),
`-k`/`--keep` (don't delete from server), `-s` (silent, for cron). This setup
is **on-demand** (no daemon) — `<leader>f` in the plugin runs fetchmail
asynchronously and overrides the MDA target per inbox via `--mda`.

**Caveat**: Gmail's default Auto-Expunge only removes the Inbox label on
IMAP delete — the message persists in All Mail. To make it a true delete,
change Gmail Settings → Forwarding and POP/IMAP → "When a message is
marked as deleted" → "Immediately delete the message forever".

## 3. One-time full-mailbox archive (historical)

A one-time download of the entire mail history into a single mbox file
(`/path/to/Mail/gmail_archive.mbox`), separate from the live store. Not part of the
running system — kept here because that file still exists on disk.

Key implementation points of the archive script:

- Connects via `imaplib.IMAP4_SSL("imap.gmail.com")`.
- Finds Gmail's "All Mail" folder by its IMAP special-use attribute
  (`\All`) rather than hardcoding `[Gmail]/All Mail`, since the literal
  name varies by account language/locale.
- Gmail's "All Mail" excludes Spam and Trash by Gmail's own design.
- Tracks completed UIDs in a sidecar file (`/path/to/Mail/.gmail_archive_done_uids`)
  so an interrupted run can resume without re-downloading.

To fold that archive into the store, run it through the migrator:
`python3 scripts/mail_store.py migrate /path/to/Mail/gmail_archive.mbox <mailbox-dir>`.

## 4. The vim-mail frontend

A netrw-style Vim buffer over the mailbox — list messages, mark several, act
on them (preview, open, mimeview, delete, move, reply, compose) — with
attachments as real files instead of base64 blobs buried in an mbox.

### Storage format

Each message becomes its own directory, named so a plain sort is already
chronological:

```
<mailbox-dir>/<UTC-timestamp>_<8-hex Message-ID hash>/
    raw.eml              original bytes, untouched
    meta                  From/To/Cc/Subject/Date/Message-ID/In-Reply-To, one per line
    body.txt              decoded plain-text body (HTML→text when no plain part);
                          URL footnotes ([N] href) appended as "Links:" section;
                          CID-embedded content gets [img N]/[audio N]/etc. markers
                          inline and an "Attachments: [N] filename" footer
    body.html             present only if an HTML part existed
    attachments/<name>    every non-body part, decoded, original filename
    .read                 marker file; presence = read
```

`Message-ID` and `In-Reply-To` are cached in `meta` to allow fast
cross-folder thread reconstruction without re-reading `raw.eml`.

The directory name doubles as the dedup key (ingestion is resumable) and
as the stable per-line id the Vim index buffer uses to survive `dd`-style
edits.

### `scripts/mail_store.py`

Ships in the plugin repo under `scripts/`. The entry point `scripts/mail_store.py`
is a thin shim; the actual MIME work lives in the `scripts/mailstore/` package
(`htmltext`, `ingest`, `quote`, `images`, `send`, `cli`). All parsing/decoding is
in Python; the Vim side only reads the small `meta`/`body.txt` files and shells
out for the rest. The plugin finds the entry point relative to its own repo root,
so it works wherever you clone the repo — no hardcoded path.

```bash
# One-time mbox → store conversion
python3 scripts/mail_store.py migrate <mbox-file> <mailbox-dir>

# Explode one RFC822 message from stdin (used by fetchmail MDA)
python3 scripts/mail_store.py ingest-stdin <mailbox-dir>

# Build and deliver a reply or new message (used by vim-mail on :w)
python3 scripts/mail_store.py send <compose-file> [<orig-msg-dir> [<sent-dir>]]
```

`send` builds a `multipart/alternative` message. The **text/plain** part is the
composed body verbatim (preserves `>` quoting). The **text/html** part depends
on the class of the original being replied to (decided by whether the original
has a `body.html`):

- **Plain-text original** → HTML is a faithful, *order-preserving* render of the
  composed body (quoted runs → nested `<blockquote>`s, user text inline).
  Top/bottom/interleaved posting all survive losslessly.
- **HTML original** → the original `body.html` is embedded verbatim in a
  `<blockquote>`, user reply on top. Inline `cid:` images are re-attached as
  `multipart/related` parts (sniffed to a real `image/*` type) so they render in
  every client. Top-posting, but the quoted original is reproduced without loss.

The reply quote is sourced by `mail#compose#reply()` from `mail_store.py quote <dir>` —
the sender's own `text/plain` (clean), or a footnote-free html render for
HTML-only mail — **not** the annotated `body.txt`. The `On … wrote:` attribution
is added in the compose buffer (editable before sending). Threading is carried by
the `In-Reply-To`/`References` headers, independent of MIME type. After delivery
via `sendmail -t`, the message is ingested into `<sent-dir>` (default
`/path/to/Mail/sent`) for thread reconstruction.

> Why two classes: a plain-text-only message shows literal `>` in clients that
> don't style quotes (e.g. QQ Mail), so we always send an HTML part. For plain
> originals the HTML is generated order-preserving (interleaving survives). For
> HTML originals, embedding the real `body.html` reproduces the original exactly
> (images, styling, links) — quoting our html→text conversion would lose that.

### Plugin layout

```
<wherever you cloned the repo>/
    plugin/mail.vim           :Mail command + g:mail_* setup
    autoload/mail/*.vim       all logic, one module per topic: mailbox, util,
                              index, actions, thread, view, compose, send,
                              attach, fetch (functions are mail#<topic>#fn)
    ftplugin/mail-index.vim   keymaps + BufWriteCmd for the index buffer
    ftplugin/mail-compose.vim :w sends the compose buffer
    syntax/mail-index.vim     conceals the hidden per-line message id
    scripts/mail_store.py     Python backend entry point (thin shim)
    scripts/mailstore/        backend package: htmltext, ingest, quote, images, send, cli
    mail-setup.md             this document
    setup.sh                  prints/patches vimrc + fetchmailrc for this clone
    setup_lazyass.sh          macOS one-shot: prompts email+password, does deps + /etc relay + fetchmailrc
    Makefile                  `make test` runs the whole suite
    tests/                    test suites (see §5)
```

The index buffer treats each message as a line of text: `<id>\t<visible>`,
id concealed (`conceallevel=2`), so `dd`/`:g//d` work natively and the id
survives arbitrary edits for diffing on `:w`.

`~/dotfiles/.vimrc` (clone the repo anywhere and point `Plug` at it — or use
a GitHub `'user/vim-mail'` spec):

```vim
Plug '/path/to/vim-mail'

let g:mail_root = '/path/to/Mail'                       " all mailboxes live here
let g:mail_from = 'Your Name <youraddress@gmail.com>'  " From: header on outgoing mail

" Optional — auto-detected otherwise (python3 on PATH, mail_store.py in repo):
" let g:mail_python   = '/usr/bin/python3'
" let g:mail_store_py = '/path/to/vim-mail/scripts/mail_store.py'
```

The plugin needs no path configuration: it locates `mail_store.py` relative
to its own repo and finds `python3` on `PATH`. The override vars above are
only for non-standard setups. Run `./setup.sh` to generate this snippet
(and the `~/.fetchmailrc` line) tailored to where the repo is cloned.

Usage:

```vim
:Mail               " opens g:mail_root/inbox
:Mail inbox         " same — bare name is resolved under g:mail_root
:Mail sent          " g:mail_root/sent
:Mail /path/to/Mail/trash  " absolute/~ paths still work as-is
```

#### Keymaps — index buffer

| Key | Action |
|---|---|
| `<CR>` | Open message: filtered headers (From/To/Cc/Reply-To/Date/Subject) + full body including inline quoted thread. If `In-Reply-To`/`References` are present and ancestors are found across mailboxes, they are appended below `────` dividers. `buftype=nofile` + `nomodifiable`: `:q` never prompts. Stages as read. |
| `o` | Quick preview — body only, quoted lines (`>`) stripped so only the current message's text is shown. Horizontal split, shared buffer reused on next `o`. Stages as read. |
| `v` | Same as `o` but opens in a vertical split (direction only matters on first open). |
| `gm` | Mimeview — opens `attachments/` in a reused netrw split. |
| `x` | Open `body.html` in the default browser. Inline `cid:` images are inlined as `data:` URIs in a temporary copy (the stored file is untouched) so they render from `file://`; external (`http`) images load via the browser. Falls back to "No HTML body" if the message has no HTML part. |
| `/` | Native Vim search over visible buffer text (From/Subject). |
| `<leader>s` | Full-text search across all mailboxes under `g:mail_root` — prompts for a Vim regex, runs `vimgrep` over all `body.txt` files, opens quickfix with entries showing `From — Subject \| matched line`. Enter on a result opens that message's `body.txt` at the match. |
| `dd`, `d3j`, `:g/pat/d`, … | **Staged delete** — lines removed from the buffer are only staged; nothing touches disk until `:w`. Undo (`u`) before `:w` cancels. |
| `s` | Mark targets read — operates on all `*`-marked messages, or the current line if none marked. Staged; committed on `:w`. |
| `S` | Mark targets unread — same targeting as `s`. Staged; committed on `:w`. |
| `t`, `tt`, `t3j`, `tG`, … | Toggle selection mark (`*`) — operator-pending: `tt` = current line, `t{motion}` = range. Used by `s`/`S`/`M`. Note: `:g/pat/norm tt` for pattern-based toggling (`:g/pat/t` is Vim's built-in copy). |
| `T` | Clear all selection marks in one shot. |
| `M` | Move marked (or current) messages to another mailbox; immediate, not staged. Accepts bare mailbox name (resolved under `g:mail_root`) or full path. Refuses (with an error) if a message with the same id already exists in the destination. If you have staged-but-unwritten edits (it refreshes the buffer afterward), it asks first — Save (commit them), Discard, or Cancel. |
| `r` | Reply — opens compose buffer prefilled with `To:`, `Subject:`, `In-Reply-To:`, `References:`, and `> `-quoted body. `:w` sends. |
| `f` | Forward inline — original embedded in the body (HTML + images), its real attachments re-attached; `Fwd: …`, new thread. A re-render (like Gmail). |
| `F` | Forward as attachment — the whole original rides along as a `message/rfc822` `.eml` (byte-exact, all attachments); `Fwd: …`, new thread. |
| `<leader>c` | New compose — blank `To:`/`Subject:` buffer. `:w` sends. |
| `<leader>f` | Fetch — prompts for target mailbox (hint shown, field empty so you can type directly; bare name resolved under `g:mail_root`). Overrides MDA target via `fetchmail --mda`. Async; echoes count on completion, refreshes index in place. If staged-but-unwritten edits would be discarded by the refresh, asks first — Save / Discard / Cancel. |
| `R` | Refresh index listing from disk. |
| `q` | Close the index buffer. |

#### Buffer as source of truth

The index buffer is the authoritative state. `:w` reconciles disk to match:

- **Deleted lines** → message directory moved to `g:mail_root/trash` (or permanently deleted if already in trash).
- **Read indicator changed** (`N` ↔ ` `) → `.read` marker file written or deleted accordingly.

Both kinds of change are staged until `:w`. `u` undoes any staged change before committing. The `modified` flag is set whenever the buffer diverges from disk — either by a staged delete or a staged read/unread change.

Recovery from accidental delete: `:Mail trash` → find the message → `M` back to the original mailbox.

Emptying the trash:

```vim
:Mail /path/to/Mail/trash   →  ggdG  →  :w
```

#### Sending

Both `r` (reply) and `<leader>c` (compose) open an `acwrite` buffer.
The format is:

```
To: recipient@example.com
Subject: Re: something
In-Reply-To: <msgid>        ← present on replies
References: <chain> <msgid> ← present on replies

reply text here
> quoted original line 1
> quoted original line 2
```

`:w` calls `mail_store.py send`, which builds a `multipart/alternative` message
(verbatim text/plain + an HTML part — order-preserving render for plain-text
originals, or the embedded original `body.html` for HTML originals) and delivers
it via `sendmail -t` (Postfix → Gmail relay). The sent copy is automatically
ingested into `/path/to/Mail/sent`. Threading is preserved by the
`In-Reply-To`/`References` headers, not by MIME type.

**Forwarding** comes in two modes, both new-thread (no `In-Reply-To`/
`References`), signalled by a control header `mail#send#send` writes and `send_mail`
strips:
- **`f` inline** (`X-Forward-Inline`): the original's body is appended to the
  plain part (unquoted) and embedded in the HTML part (with its inline images),
  and its real attachments are re-attached. A re-render — like Gmail/Outlook's
  default forward; *not* byte-exact (drops raw MIME/DKIM, like every client's
  inline forward).
- **`F` as attachment** (`X-Forward-Dir`): the original's `raw.eml` is attached
  as a `message/rfc822` part. Byte-exact and lossless — the recipient gets the
  original intact (even re-verifiable against DKIM), as an openable `.eml`.

#### Attachments and inline images

In a compose buffer:
- **Attach files** — `:Attach {paths…}` (Tab-completes, globs expand), `<leader>A`
  (a prefilled `:Attach `), or `<leader>a` (files copied to the clipboard). Each
  shows as a line in a trailing `Attachments:` footer (`[1] report.pdf`); the
  buffer is the source of truth, so deleting a line drops that file. On `:w` the
  footer is resolved to paths and stripped from the sent body, and each file is
  added as a `multipart/mixed` part (content-type from the extension).
- **Inline images** — `<leader>p` pastes an image from the clipboard: a screenshot
  (raw image data — built-in `osascript` on macOS, no extra tools; `wl-paste`/
  `xclip` on Linux) or copied image file(s). It inserts an
  `[img N]` marker at the cursor (all-or-nothing — refuses if any clipboard file
  isn't an image). On `:w`, each `[img N]` becomes an inline `cid` image
  (`multipart/related`) in the HTML part; the plain part keeps the literal
  `[img N]`, exactly like a received message's `body.txt`.

Both round-trip: the recipient's ingestion regenerates the `Attachments:` footer
and `[img N]` markers from the MIME parts.

> Clipboard support is **macOS-tested only**. macOS uses built-in `osascript`
> (image data) and the AppKit/`NSPasteboard` bridge (file paths, multi-file). The
> Linux paths (`wl-paste`/`xclip`) are written but **untested**, need those tools
> installed, and may miss GNOME/Nautilus file copies (which use
> `x-special/gnome-copied-files` rather than `text/uri-list`). Attach by path
> (`:Attach`) works everywhere. Windows isn't supported.

> **Lesson — a copied file carries its icon too, so prefer the file over the
> data.** Cmd-C on a file in Finder puts *several* representations on the clipboard
> at once: a file URL (`public.file-url` / `NSFilenamesPboardType`) **and** the
> file's icon as image data (`com.apple.icns`, coercible to `«class PNGf»` /
> `public.tiff`). So `the clipboard as «class PNGf»` on a copied file returns its
> **icon / QuickLook thumbnail, not its pixels**. `mail#attach#paste_image`
> therefore checks `mail#attach#_clipboard_files()` (the file URL) *before*
> `mail#attach#_clipboard_image()` (the PNGf): it embeds the real file, and falls
> back to image data only when there's no file (a screenshot carries data and no
> file URL). A data-first order silently embeds the icon — the original bug shipped
> a "JPG document" thumbnail instead of the photo. Guarded by `test_clipboard.vim`
> (mac-only): the clipboard is given *both* a file URL and PNG data, and the file
> must win. (To inspect a real copy: `osascript -l JavaScript -e
> 'ObjC.import("AppKit");$.NSPasteboard.generalPasteboard.types'`.)

#### Thread reconstruction

`<CR>` (full open) scans `meta` files across all subdirectories of
`g:mail_root` to build a `{Message-ID → dir}` index. For the current
mailbox the already-loaded `b:mail_entries` are used (no disk I/O); other
mailboxes are scanned by reading their `meta` files (fast — 6 lines each).
Old messages without `Message-ID` in `meta` fall back to `raw.eml` header
extraction automatically.

## 5. Testing

Run the whole suite from the repo root:

```bash
make test            # or: sh tests/run.sh
make test-linux      # same suite, inside a Linux Docker container (headless)
make test-linux-clip # + a virtual X display, to exercise the xclip path (local)
```

`tests/run.sh` auto-discovers and runs every `tests/test_*.py` (Python) and
`tests/test_*.vim` (headless Vim). It exits non-zero if any suite fails, so
it works in CI. Each test is wrapped in `timeout` when available so a hang fails
fast and is named, instead of stalling. Add a new suite by dropping a
`test_*.py` or `test_*.vim` file in `tests/` — no wiring needed.

`make test-linux` builds `tests/Dockerfile` (Debian + `vim-nox`, Python) and runs
the suite under Linux, bind-mounting the repo so edits need no rebuild. It runs
**headless** (no `$DISPLAY`), so `test_clipboard.vim` self-skips — this is the CI
path (`.github/workflows/tests.yml`) and is robust everywhere. It still catches
portability bugs the macOS run hides — e.g. a missing `from typing import
Optional` that Python 3.14's lazy annotation evaluation tolerates locally but the
container's 3.13 rejects at import. `make test-linux-clip` wraps the suite in
`xvfb-run` to exercise the Linux `xclip` clipboard path too — **local only** and
timeout-bounded, since `xclip`'s selection daemon can hold the container's stdout
open and hang `docker run` (the reason CI runs headless). Not covered anywhere:
`setup_lazyass.sh`'s Linux branch (systemd/sudo/Gmail), `wl-clipboard`/Wayland,
or the clipboard *file*-list path.

Current suites:

| File | Covers |
|---|---|
| `tests/test_reply.py` | `mail_store.py` send (calls the real function): both reply classes (plain-text → order-preserving HTML; HTML → embedded `body.html` with cid images re-attached as multipart/related), both forward modes (inline embed + re-attach; as-attachment `message/rfc822`), `quote_text` clean sourcing, verbatim text/plain, `In-Reply-To`/`References` threading. |
| `tests/test_ingest.py` | Ingestion of a **real** complex message (`fixtures/embrace-the-chaos/raw.eml` — 2 tables, inline cid image, external image, businesscard link, `.ics`): attachments downloaded, links footnoted, body parsed, `quote_text` clean, and `viewhtml`/`_inline_cid_data_uris` turning `cid:` into `data:` URIs while the stored `body.html` stays pristine. |
| `tests/test_reply_integration.py` | Full pipeline on that real message: CLI ingest → real headless `vim` replies (top-post) **and forwards both ways** + sends (fake `sendmail`) → sent box verified — reply (multipart/alternative, tables embedded, cid as multipart/related, clean `>` quote, threading), inline forward (tables embedded, `.ics` re-attached, new thread), and as-attachment forward (`message/rfc822`, attachments intact). |
| `tests/test_attach.py` | `mail_store.py` attachments + inline images: `X-Mail-Attach` → `multipart/mixed`, `X-Mail-Inline` → `[img N]` becomes a `cid` image (`multipart/related`), combined, content-type guessing, headers stripped, missing-file errors. |
| `tests/test_compose.vim` | Compose buffers: `mail#compose#reply()`, both forward modes, attachments (`Attachments:` footer + `mail#send#_split_attachments` resolve/strip), and inline images (`mail#send#_inline_images` resolution + `mail#attach#paste_image` marker insert, clipboard grab stubbed). |
| `tests/test_clipboard.vim` | REAL clipboard integration: puts a PNG on the system clipboard and verifies the unstubbed `mail#attach#_clipboard_image` captures it + `mail#attach#paste_image` inserts a marker; also puts two file URLs on the clipboard and checks `mail#attach#_clipboard_files` returns both (multi-file). Skips where no image-clipboard tool exists; restores the text clipboard on macOS. |

Fixtures: real sample messages live one directory per case under
`tests/fixtures/<case>/` (each holds a `raw.eml` and any static assets);
`tests/_fixtures.py` (`raw(case)`) loads them. Not run as tests themselves.
| `tests/test_move.vim` | `mail#actions#move()`: clean move succeeds; collision reports an error and keeps the message; and the staged-edit guard — Cancel aborts (keeping pending edits), Discard proceeds, Save commits the staged edits (to trash) then moves. |

### Headless Vim test convention

`test_*.vim` files use Vim's built-in assertion API and signal pass/fail via
exit code:

- Assert with `assert_equal` / `assert_true` / `assert_match` etc.; failures
  accumulate in the `v:errors` list.
- At the end, `qall!` (exit 0) if `v:errors` is empty, else `cquit!`
  (non-zero). `run.sh` keys off that exit code.
- Build fixtures in an isolated `tempname()` dir and `delete(root, 'rf')`
  after — **never** touch a real mail store.
- Run a single file directly: `vim -u NONE -N -es -S tests/test_move.vim`.

**Gotcha — stubbing autoloaded functions.** `mail#<topic>#*` functions are loaded
lazily per module: the first call into a topic re-sources its
`autoload/mail/<topic>.vim`, which would clobber any stub defined beforehand (e.g.
replacing `mail#mailbox#_prompt_mailbox` to skip the interactive `input()`). Force
*all* modules to load *before* stubbing — `runtime!` with a glob loads every one:

```vim
runtime plugin/mail.vim
runtime! autoload/mail/*.vim   " load all now, so the stub below survives
function! mail#mailbox#_prompt_mailbox(prompt, default) abort
  return 'history'            " no interactive input() in batch mode
endfunction
```

Also note `feedkeys()` does not reliably drive operator-pending mappings or
`input()` in `-es` batch mode — call the underlying functions directly
(e.g. `mail#actions#ToggleMarkOperator('line')`) instead.
