# vim-mail

Netrw-style Vim plugin for a one-folder-per-message mail store. The full
setup doc (Postfix relay, fetchmail, mail_store.py) lives at
`mail-setup.md` (in this repo). This file covers only what's needed to work on
the plugin itself.

## Storage format

```
/path/to/Mail/<mailbox>/<UTC-timestamp>_<8-hex-hash>/
    raw.eml          original RFC822 bytes, never modified
    meta             From/To/Cc/Subject/Date/Message-ID/In-Reply-To, one per line
    body.txt         decoded plain text; Links: footer; [img N] / [audio N] markers; Attachments: footer
    body.html        present only when an HTML part exists
    attachments/     decoded non-body parts, original filenames
    .read            marker file; presence = message is read
```

Directory basename is the stable per-line ID in the index buffer.

## Architecture

All MIME work is in the `scripts/mailstore/` package (Python; entry point
`scripts/mail_store.py`). The Vim plugin reads only `meta` and `body.txt`; it
never parses MIME itself.

```
plugin/mail.vim           :Mail command + g:mail_* setup (repo root, python cmd)
autoload/mail/mailbox.vim mailbox path resolution, completion, prompting
autoload/mail/util.vim    shared helpers (py_cmd)
autoload/mail/index.vim   index buffer: render, batched redraw, line<->entry
autoload/mail/actions.vim staged actions: marks, read/unread, delete (:w), move
autoload/mail/thread.vim  cross-mailbox message-id index
autoload/mail/view.vim    reading: preview, full open, html/mime view, search
autoload/mail/compose.vim compose, reply, forward
autoload/mail/send.vim    assemble + send the compose buffer
autoload/mail/attach.vim  attachments + inline images (+ clipboard)
autoload/mail/fetch.vim   async fetchmail
ftplugin/mail-index.vim   keymaps + BufWriteCmd
ftplugin/mail-compose.vim :w sends
syntax/mail-index.vim     conceals the hidden per-line message id
scripts/mail_store.py     Python backend entry point (thin shim)
scripts/mailstore/        backend package: htmltext/ingest/quote/images/send/cli
mail-setup.md             full backend setup doc (Postfix relay, fetchmail, store)
setup.sh                  one-off: prints vimrc + fetchmailrc config for this clone
Makefile                  `make test` (local) / `make test-linux` (Docker)
tests/run.sh              test runner: auto-discovers tests/test_*.{py,vim}
tests/Dockerfile          Debian image to run the suite under Linux
tests/test_reply.py       reply/threading suite (Python)
tests/test_move.vim       mail#actions#move() suite (headless Vim, assert_*/v:errors)
```

**Autoload namespacing.** Logic is split into `autoload/mail/<topic>.vim`, so
functions are `mail#<topic>#fn()` (e.g. `mail#index#refresh()`,
`mail#compose#reply()`). Vim lazy-loads each module on first call. Script-local
state (`s:`) is file-scoped, so each module owns its own state; the two
cross-module touchpoints go through accessors — `mail#thread#invalidate()` (called
by `mail#index#refresh()` to drop the msgid cache) and `mail#index#refresh_for(dir)`
(called by `mail#fetch#_fetch_exit_cb()` to repaint the index after a fetch).

**Running tests:** `make test` (or `sh tests/run.sh`) runs every
`tests/test_*.py` and `tests/test_*.vim`; exits nonzero if any fail. Add a
new suite by dropping a `test_*.py` or `test_*.vim` file in `tests/` — the
runner picks it up automatically. Headless Vim tests use the built-in
`assert_*` API, collect into `v:errors`, and `qall!`/`cquit!` to signal
pass/fail via exit code.

**`make test-linux`** builds `tests/Dockerfile` (Debian + `vim-nox`, Python) and
runs the same suite under Linux, bind-mounting the repo (no rebuild between runs).
It runs **headless** (no `$DISPLAY`), so `test_clipboard.vim` self-skips — this is
the CI path (`.github/workflows/tests.yml`) and is robust everywhere. It still
catches cross-platform breakage the macOS run can't — e.g. a missing
`from typing import Optional` masked locally by Python 3.14's lazy annotation
evaluation but fatal on the container's 3.13. **`make test-linux-clip`** is the
opt-in variant that wraps the suite in `xvfb-run` so the Linux `xclip` clipboard
path is exercised too — **local only** and timeout-bounded, because `xclip`'s
selection daemon can hold the container's stdout open and hang `docker run`
(which is why CI runs headless). Not covered anywhere: `setup_lazyass.sh`'s Linux
branch (systemd/sudo/Gmail), the `wl-clipboard`/Wayland path, the clipboard
*file*-list path.

**No hardcoded paths.** `plugin/mail.vim` derives the repo root via
`expand('<sfile>:p:h:h')`, so `mail_store.py` is found wherever the repo is
cloned. `g:mail_python` defaults to `python3` on `PATH` (`exepath`), and
`g:mail_store_py` to `<repo>/scripts/mail_store.py`; `g:mail_store_cmd` is built
from both. All three are overridable in vimrc. The only out-of-repo path is the
`mda` line in `~/.fetchmailrc` — run `./setup.sh` (optionally `--patch`) to
generate/update it for the current machine.

## Index buffer design

Each line: `<id>\t<N|space><*|space> <date>  <from>  <subject>`

- `id` is concealed (`conceallevel=2`)
- `N` = unread, space = read; `*` = marked, space = unmarked
- `dd`/`d3j`/`:g//d` work natively — Vim's own delete machinery
- `b:mail_entries` = disk baseline (`[{id, dir, read, meta}]`), ordered by original sort
- Buffer text is the **authoritative staged state** for both read/unread and deletions
- `b:mail_entries[idx].read` = last-saved disk state (only updated by `mail#index#refresh()`)

## `:w` semantics (buffer as source of truth)

`BufWriteCmd` calls `mail#actions#write()` which does a single reconciliation pass:
- Lines missing from buffer → message dir moved to `/path/to/Mail/trash` (or deleted if already in trash)
- Read indicator differs from disk → `.read` file written or deleted

Both are staged until `:w`. `u` reverts either before committing.
`mail#index#refresh()` ends with `setlocal nomodified` (a just-refreshed buffer matches
disk), so `&modified` reliably means "staged, uncommitted changes exist."

**Staged-edit guard.** `M` (move) and `<leader>f` (fetch) mutate disk and then
`mail#index#refresh()`, which rebuilds the buffer from disk and would silently discard
uncommitted staged edits. Both first call `mail#actions#_ok_to_refresh(action)`: if
`&modified`, it asks via `mail#actions#_confirm()` — **Save / Discard / Cancel**. *Save*
runs `mail#actions#write()` (commits the staged edits, then proceeds); *Discard* proceeds
and lets the refresh drop them; *Cancel* aborts. `mail#actions#_confirm` returns
`'save'`/`'discard'`/`'cancel'` and wraps `confirm()` so tests can stub it.
Because *Save* rebuilds `b:mail_entries`, `mail#actions#move()` captures its targets by id
**before** the guard and re-resolves them after.
(`R` and `:w`'s own refresh are not guarded — `R` is an explicit discard, and
`:w` refreshes after committing.) *Future:* update the buffer incrementally
(insert fetched lines / drop moved lines) so staged edits survive without a
discard prompt — deferred; the guard is the floor.

## Key implementation details

**ID-based line resolution (critical)**
After `dd`, buffer line N no longer corresponds to `b:mail_entries[N-1]`. All
functions that need to find an entry from a buffer line extract the concealed
`id` prefix and look it up via `mail#index#_id_to_idx()` (returns `{id → entry_idx}`).
Affected functions: `_current_index`, `_target_indexes`, `_patch_lines`,
`_set_read`, `_flush_pending`, `ToggleMarkOperator`. Never use `line('.') - 1`
as a `b:mail_entries` index.

**Batch line updates — `mail#index#_patch_lines(targets, Fn)`**
- `targets`: `{entry_idx: 1}`; empty = all lines
- `Fn(read, marked) -> [new_read, new_marked]`
- Iterates current buffer lines, resolves entry by ID, applies Fn
- One `noautocmd setline(1, list)` call regardless of selection size

**`_flush_pending`**
Rebuilds only existing buffer lines (by ID) — never restores lines deleted by `dd`.
Computes `&modified` by checking whether any entry is absent from buffer or has
a different read state than disk baseline.

**`_set_read(idx, read)`**
Scans buffer for the line whose ID matches `b:mail_entries[idx].id`, updates
that line directly. O(n) scan but only called once per message open.

**Msgid index cache**
`mail#thread#_build_msgid_index()` scans `meta` files across all mailboxes to build
`{message-id → dir}` for thread reconstruction. Result cached in `s:msgid_index`;
invalidated by `mail#index#refresh()`. Never reads `raw.eml` as fallback.

**Header filtering — `mail#view#_filtered_headers(rawfile)`**
Shared helper used by both `mail#view#open_message()` (current message) and thread
ancestor reconstruction. Filters to From/To/Cc/Reply-To/Date/Subject only.
Reply-To suppressed when identical to From.

**Outgoing MIME structure — multipart/alternative, two classes of original**
`mail_store.py send` always produces `multipart/alternative`. The `text/plain`
part is the compose body **verbatim** (preserves `>` quoting exactly). The
`text/html` part depends on the class of the message being replied to, decided
by **whether `orig_dir/body.html` exists**:

- **Class 1 — plain-text original (no `body.html`)**: HTML = `_plain_to_html(body)`,
  an ORDER-PRESERVING render. `_quote_depth()` measures leading `>`/`>>`; runs of
  quoted lines become nested `<blockquote>`s, user text stays inline. Top/bottom/
  **interleaved** posting all survive. Lossless — the quoted source is already
  plain text.
- **Class 2 — HTML original (`body.html` exists)**: the original `body.html` is
  **embedded verbatim** in a `<blockquote>`, with the user's reply (the non-`>`
  lines) on top. Inline `cid:` images are re-attached as `multipart/related`
  parts (the html alternative becomes `multipart/related`; `_cid_parts` pulls the
  bytes from the original `raw.eml`, `_sniff_image_type` gives them a real
  `image/*` type) — universally rendered, unlike `data:` URIs which Outlook
  blocks and Gmail strips. Top-posting, quoted original reproduced without loss.

Quote sourcing: `mail#compose#reply()` fills the compose buffer with the clean quote from
`mail_store.py quote <dir>` (`quote_text`: the sender's own `text/plain`, or a
footnote-free `html_to_text` for HTML-only mail) — **never** the annotated
`body.txt` with its `Links:`/`[N]` reading-aid footers. The buffer holds an empty
reply line (cursor), an `On <date>, <sender> wrote:` attribution, then the
`> `-quoted clean original.

Threading rides entirely on the `In-Reply-To`/`References` headers — independent
of MIME type. `send_mail`'s `orig_dir` arg selects the class and supplies the
HTML to embed (class 2); attribution is produced at compose time.

**Forward — two modes (`f` inline, `F` as-attachment)**
Both open a compose buffer (shared `s:_forward_buffer`): empty `To:`, `Fwd: …`
subject, **no** `In-Reply-To`/`References` (new thread), a forwarded-header block
for the user's note. `mail#send#send()` writes a control header (stripped by
`send_mail`, never sent) per mode.

- **`f` — inline** (`mail#compose#forward()`): sets `b:mail_compose_orig_dir` +
  `b:mail_compose_fwd_inline` → header `X-Forward-Inline: 1`. `send_mail`
  **appends** the original body to the plain part (unquoted) via `quote_text`,
  **embeds** `body.html` in the HTML part (class-2 path, cid images as related),
  and **re-attaches** the original's non-cid attachments (PDF/.ics) into
  `multipart/mixed`. The original is appended at send (not in the buffer) so it
  isn't duplicated against the embedded HTML. A re-render — like Gmail/Outlook
  inline forward, *not* byte-exact.
- **`F` — as attachment** (`mail#compose#forward_attach()`): sets
  `b:mail_compose_forward` → header `X-Forward-Dir: <dir>`. `send_mail` attaches
  `<dir>/raw.eml` as a `message/rfc822` part (named from the subject) —
  byte-exact and lossless, opened by the recipient.

**Attachments (compose buffer)**
`b:mail_attachments` = `[{id, path}]` (monotonic `id` in `b:mail_attach_seq`).
Each attachment shows as a line in a trailing `Attachments:` footer
(`[id] basename`, matching the ingestion footer). Buffer is the source of truth:
delete a footer line → that file isn't sent.
- `:Attach {paths…}` (buffer-local, `-complete=file`, globs expanded) /
  `<leader>A` (prefilled `:Attach `) — attach by path. `<leader>a` — attach
  clipboard file(s) (`mail#attach#_clipboard_files`: macOS reads all file URLs via the
  AppKit bridge `osascript -l JavaScript` / `NSPasteboard.readObjectsForClasses`
  — handles multiple; Linux `wl-paste`/`xclip` `text/uri-list`).
- On `:w`, `mail#send#_split_attachments(body_lines)` resolves surviving footer ids →
  paths and **strips the footer from the sent body** (it's a compose affordance,
  not literal text); `mail#send#send` emits one `X-Mail-Attach: <path>` per file.
- `send_mail` strips `X-Mail-Attach` and adds each file via `add_attachment`
  (content-type from `mimetypes`), wrapping into `multipart/mixed`. The recipient's
  ingestion regenerates the `Attachments:` footer from the MIME parts.

**Inline images (compose buffer)** — `<leader>p`. `mail#attach#paste_image()` grabs an
image from the clipboard: raw image *data* (screenshot) via
`mail#attach#_clipboard_image` (built-in `osascript` on macOS — coerces the clipboard
to PNG, no extra tools; `wl-paste`/`xclip` on Linux), else copied image *file(s)*
(`mail#attach#_clipboard_files`). All-or-nothing: if any clipboard file isn't an image,
it warns and adds nothing. Each image is registered inline (`{id, path, inline:1}`)
and inserts an `[img id]` marker at the cursor (the marker lives in the body, not
the footer). On `:w`, `mail#send#_inline_images(body_lines)` finds surviving `[img id]`
markers and `mail#send#send` emits `X-Mail-Inline: <id> <path>` per image. `send_mail`
→ `_embed_inline_images` replaces `[img id]` in the HTML with
`<img src="cid:mail-inline-id">` and attaches the bytes as a `multipart/related`
part (image type sniffed); the plain part keeps the literal `[img id]`. Round-trips:
the recipient's ingestion re-derives `[img id]` in `body.txt`.

**`o` preview strips quotes**
Lines starting with `>` and attribution lines filtered out.

**`<CR>` full open**
Filtered headers + body + thread ancestors (each ancestor also filtered headers).

## Keymaps — index buffer

| Key | Action |
|---|---|
| `<CR>` | Open: filtered headers + full body + thread ancestors |
| `o` | Preview: body with `>` quotes stripped, horizontal split, reused buffer |
| `v` | Same as `o`, vertical split |
| `gm` | Mimeview: open `attachments/` in netrw split |
| `x` | Open `body.html` in browser (inline `cid:` images shown via a temp data-URI copy) |
| `/` | Native Vim search (From/Subject visible text) |
| `<leader>s` | Full-text vimgrep across all `body.txt` files → quickfix |
| `dd`, `d3j`, `:g/pat/d` | Staged delete — committed on `:w` |
| `s` | Mark targets read (staged) |
| `S` | Mark targets unread (staged) |
| `t` / `tt` / `t3j` | Toggle selection mark `*` (operator-pending) |
| `T` | Clear all marks |
| `M` | Move marked/current to another mailbox (immediate; warns if staged edits would be discarded) |
| `r` | Reply (opens compose buffer, `:w` sends) |
| `f` | Forward inline (original embedded in the body; re-render, like Gmail) |
| `F` | Forward as attachment (original as a `message/rfc822` `.eml`; byte-exact) |

Compose-buffer keymaps (in `ftplugin/mail-compose.vim`): `:Attach {paths…}` /
`<leader>A` (attach by path), `<leader>a` (attach clipboard files), `<leader>p`
(inline clipboard image / image files). Screenshot data needs no extra tools on
macOS (built-in `osascript`); Linux uses `wl-paste`/`xclip`.
| `<leader>c` | Compose new message |
| `<leader>f` | Fetch mail (async fetchmail, refreshes index; warns if staged edits would be discarded) |
| `R` | Refresh from disk |
| `q` | Close buffer |

"Targets" for `s`/`S`/`M`: all `*`-marked messages if any, else current line.

## Dependencies

### Vim
Requires Vim 8+ (tested on 9.2). Required feature flags:
`+job` `+timers` `+lambda` `+conceal`

Check with `:echo has('job') && has('timers') && has('lambda') && has('conceal')`

### Python
`mail_store.py` requires Python 3.9+ (uses `email.policy`, `html.parser`,
`pathlib`). All stdlib — no pip dependencies.

### System tools

| Tool | Used for | Installed via |
|---|---|---|
| `fetchmail` | Fetching mail from IMAP (`<leader>f`) | `brew install fetchmail` |
| `sendmail` | Delivering outgoing mail (called by `mail_store.py send`) | ships with macOS Postfix |
| `open` / `xdg-open` | Opening `body.html` in browser (`x` keymap) | macOS built-in / `xdg-utils` on Linux |
| `python3` | Running `mail_store.py` | `brew install python` or system |
| `osascript` (macOS) / `wl-paste` / `xclip` (Linux) | Clipboard image data + file paths for `<leader>p`/`<leader>a` | macOS built-in; `wl-clipboard` / `xclip` on Linux |

**Clipboard support is macOS-tested only.** The macOS paths (`mail#attach#_clipboard_image`
via `osascript` PNG coercion; `mail#attach#_clipboard_files` via the AppKit/JXA
`NSPasteboard` bridge) are built-in and have real integration tests
(`test_clipboard.vim`). The **Linux paths are written but UNTESTED** and have
known caveats: they need `xclip` (X11) or `wl-clipboard` (Wayland) installed; and
`mail#attach#_clipboard_files` reads `text/uri-list`, which **may miss GNOME/Nautilus
copies** (those use `x-special/gnome-copied-files`). **Windows is unsupported**
(no clipboard code). The clipboard test skips where no image-clipboard tool exists,
so CI green ≠ Linux verified.

Postfix must be configured to relay through Gmail SMTP — see `mail-setup.md` §1.

## vimrc

The repo can be cloned anywhere — the plugin self-locates `mail_store.py`
relative to its own root. Point your plugin manager at wherever you cloned it
(a GitHub `'user/vim-mail'` spec works too).

```vim
Plug '/path/to/vim-mail'
let g:mail_root = '/path/to/Mail'
let g:mail_from = 'Your Name <youraddress@gmail.com>'
```

## Mailbox prompts

All places that ask for a mailbox name go through `mail#mailbox#_prompt_mailbox(prompt, default)`:
- `mail#actions#move()` — `M` keymap
- `mail#fetch#fetch()` — `<leader>f` keymap
- `:Mail` command — uses `-complete=customlist,mail#mailbox#_complete_mailbox`

`mail#mailbox#_complete_mailbox(arglead, cmdline, cursorpos)` returns a List of dir basenames under
`g:mail_root` filtered by arglead. `mail#mailbox#_complete_mailbox_str` is the `custom,` variant
(newline-joined) used by `input()`. Never call `input()` directly for mailbox names.

## Reply-all

`mail#compose#reply()` reads `meta.cc`, strips any address matching `g:mail_from`, and prefills
`Cc:` in the compose buffer between `To:` and `Subject:`. Only messages ingested after
the `Cc` field was added to `_write_meta` will have it in meta.

## Known quirks

- Outgoing mail is multipart/alternative with two classes by original type: plain-text
  originals get an order-preserving HTML render (top/bottom/interleave all survive);
  HTML originals get the original `body.html` embedded verbatim with inline images
  re-attached as multipart/related cid parts, top-posting. Plain part is always the
  verbatim composed body.
- Thread reconstruction only works for messages whose `meta` file contains `Message-ID`.
- Old messages moved via `M` before the `/` separator fix have a `history` prefix in
  their dir name — thread reconstruction won't find them by Message-ID.
- The stored `body.html` keeps `cid:xxx` refs (pristine). Two consumers rewrite them
  on the fly, never the stored file: **viewing** (`x` → `mail_store.py viewhtml` →
  `_inline_cid_data_uris` rewrites `cid:`→`data:` URIs in a temp copy for the browser,
  since `cid:` can't resolve from `file://`); **replying** (class-2 embed re-attaches
  them as `multipart/related` parts for cross-client rendering). `data:`/external
  (`http`) refs are passed through untouched by both. External images load per the
  browser/remote — e.g. an oversized Wikimedia thumbnail URL the sender used may 400.
