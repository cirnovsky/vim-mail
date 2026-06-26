# vim-mail

Netrw-style Vim plugin for a one-folder-per-message mail store. The full
setup doc (Postfix relay, fetchmail, mail_store.py) lives at
`mail-setup.md` (in this repo). This file covers only what's needed to work on
the plugin itself.

## Storage format

```
~/Mail/<mailbox>/<UTC-timestamp>_<8-hex-hash>/
    raw.eml          original RFC822 bytes, never modified
    meta             From/To/Cc/Subject/Date/Message-ID/In-Reply-To, one per line
    body.txt         decoded plain text; Links: footer; [img N] / [audio N] markers; Attachments: footer
    body.html        present only when an HTML part exists
    attachments/     decoded non-body parts, original filenames
    .read            marker file; presence = message is read
```

Directory basename is the stable per-line ID in the index buffer.

## Architecture

All MIME work is in `mail_store.py` (Python, in this repo). The Vim plugin
reads only `meta` and `body.txt`; it never parses MIME itself.

```
plugin/mail.vim           :Mail command
autoload/mail.vim         all logic
ftplugin/mail-index.vim   keymaps + BufWriteCmd
ftplugin/mail-compose.vim :w sends
syntax/mail-index.vim     conceals the hidden per-line message id
mail_store.py             Python backend: all MIME work (migrate/ingest-stdin/send)
mail-setup.md             full backend setup doc (Postfix relay, fetchmail, store)
setup.sh                  one-off: prints vimrc + fetchmailrc config for this clone
Makefile                  `make test` runs the whole suite
tests/run.sh              test runner: auto-discovers tests/test_*.{py,vim}
tests/test_reply.py       reply/threading suite (Python)
tests/test_move.vim       mail#move() suite (headless Vim, assert_*/v:errors)
```

**Running tests:** `make test` (or `sh tests/run.sh`) runs every
`tests/test_*.py` and `tests/test_*.vim`; exits nonzero if any fail. Add a
new suite by dropping a `test_*.py` or `test_*.vim` file in `tests/` — the
runner picks it up automatically. Headless Vim tests use the built-in
`assert_*` API, collect into `v:errors`, and `qall!`/`cquit!` to signal
pass/fail via exit code.

**No hardcoded paths.** `autoload/mail.vim` derives its own repo root via
`expand('<sfile>:p:h:h')`, so `mail_store.py` is found wherever the repo is
cloned. `g:mail_python` defaults to `python3` on `PATH` (`exepath`), and
`g:mail_store_py` to `<repo>/mail_store.py`; `g:mail_store_cmd` is built from
both. All three are overridable in vimrc. The only out-of-repo path is the
`mda` line in `~/.fetchmailrc` — run `./setup.sh` (optionally `--patch`) to
generate/update it for the current machine.

## Index buffer design

Each line: `<id>\t<N|space><*|space> <date>  <from>  <subject>`

- `id` is concealed (`conceallevel=2`)
- `N` = unread, space = read; `*` = marked, space = unmarked
- `dd`/`d3j`/`:g//d` work natively — Vim's own delete machinery
- `b:mail_entries` = disk baseline (`[{id, dir, read, meta}]`), ordered by original sort
- Buffer text is the **authoritative staged state** for both read/unread and deletions
- `b:mail_entries[idx].read` = last-saved disk state (only updated by `mail#refresh()`)

## `:w` semantics (buffer as source of truth)

`BufWriteCmd` calls `mail#write()` which does a single reconciliation pass:
- Lines missing from buffer → message dir moved to `~/Mail/trash` (or deleted if already in trash)
- Read indicator differs from disk → `.read` file written or deleted

Both are staged until `:w`. `u` reverts either before committing.
`setlocal nomodified` at end of `mail#write()` so `:wq` works.

## Key implementation details

**ID-based line resolution (critical)**
After `dd`, buffer line N no longer corresponds to `b:mail_entries[N-1]`. All
functions that need to find an entry from a buffer line extract the concealed
`id` prefix and look it up via `mail#_id_to_idx()` (returns `{id → entry_idx}`).
Affected functions: `_current_index`, `_target_indexes`, `_patch_lines`,
`_set_read`, `_flush_pending`, `ToggleMarkOperator`. Never use `line('.') - 1`
as a `b:mail_entries` index.

**Batch line updates — `mail#_patch_lines(targets, Fn)`**
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
`mail#_build_msgid_index()` scans `meta` files across all mailboxes to build
`{message-id → dir}` for thread reconstruction. Result cached in `s:msgid_index`;
invalidated by `mail#refresh()`. Never reads `raw.eml` as fallback.

**Header filtering — `mail#_filtered_headers(rawfile)`**
Shared helper used by both `mail#open_message()` (current message) and thread
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

Quote sourcing: `mail#reply()` fills the compose buffer with the clean quote from
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
for the user's note. `mail#send()` writes a control header (stripped by
`send_mail`, never sent) per mode.

- **`f` — inline** (`mail#forward()`): sets `b:mail_compose_orig_dir` +
  `b:mail_compose_fwd_inline` → header `X-Forward-Inline: 1`. `send_mail`
  **appends** the original body to the plain part (unquoted) via `quote_text`,
  **embeds** `body.html` in the HTML part (class-2 path, cid images as related),
  and **re-attaches** the original's non-cid attachments (PDF/.ics) into
  `multipart/mixed`. The original is appended at send (not in the buffer) so it
  isn't duplicated against the embedded HTML. A re-render — like Gmail/Outlook
  inline forward, *not* byte-exact.
- **`F` — as attachment** (`mail#forward_attach()`): sets
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
  clipboard file(s) (`mail#_clipboard_files`: macOS `osascript` single-file;
  Linux `xclip` `text/uri-list` multi).
- On `:w`, `mail#_split_attachments(body_lines)` resolves surviving footer ids →
  paths and **strips the footer from the sent body** (it's a compose affordance,
  not literal text); `mail#send` emits one `X-Mail-Attach: <path>` per file.
- `send_mail` strips `X-Mail-Attach` and adds each file via `add_attachment`
  (content-type from `mimetypes`), wrapping into `multipart/mixed`. The recipient's
  ingestion regenerates the `Attachments:` footer from the MIME parts.

**Inline images (compose buffer)** — `<leader>p`. `mail#paste_image()` grabs an
image from the clipboard: raw image *data* (screenshot) via
`mail#_clipboard_image` (`pngpaste`/`xclip`), else copied image *file(s)*
(`mail#_clipboard_files`). All-or-nothing: if any clipboard file isn't an image,
it warns and adds nothing. Each image is registered inline (`{id, path, inline:1}`)
and inserts an `[img id]` marker at the cursor (the marker lives in the body, not
the footer). On `:w`, `mail#_inline_images(body_lines)` finds surviving `[img id]`
markers and `mail#send` emits `X-Mail-Inline: <id> <path>` per image. `send_mail`
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
| `x` | Open `body.html` in browser (netrw convention) |
| `/` | Native Vim search (From/Subject visible text) |
| `<leader>s` | Full-text vimgrep across all `body.txt` files → quickfix |
| `dd`, `d3j`, `:g/pat/d` | Staged delete — committed on `:w` |
| `s` | Mark targets unread (staged) |
| `S` | Mark targets read (staged) |
| `t` / `tt` / `t3j` | Toggle selection mark `*` (operator-pending) |
| `T` | Clear all marks |
| `M` | Move marked/current to another mailbox (immediate) |
| `r` | Reply (opens compose buffer, `:w` sends) |
| `f` | Forward inline (original embedded in the body; re-render, like Gmail) |
| `F` | Forward as attachment (original as a `message/rfc822` `.eml`; byte-exact) |

Compose-buffer keymaps (in `ftplugin/mail-compose.vim`): `:Attach {paths…}` /
`<leader>A` (attach by path), `<leader>a` (attach clipboard files), `<leader>p`
(inline clipboard image / image files). `<leader>p` needs `pngpaste` (macOS) or
`xclip`/`wl-paste` (Linux) for screenshot data.
| `<leader>c` | Compose new message |
| `<leader>f` | Fetch mail (async fetchmail, refreshes index) |
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
| `pngpaste` / `xclip` / `wl-paste` | Clipboard image data for `<leader>p` (optional) | `brew install pngpaste` / `xclip` / `wl-clipboard` |
| `osascript` / `xclip` | Clipboard file paths for `<leader>a` (optional) | macOS built-in / `xclip` |

Postfix must be configured to relay through Gmail SMTP — see `mail-setup.md` §1.

## vimrc

The repo can be cloned anywhere — the plugin self-locates `mail_store.py`
relative to its own root. Point your plugin manager at wherever you cloned it
(a GitHub `'user/vim-mail'` spec works too).

```vim
Plug '/path/to/vim-mail'
let g:mail_root = '~/Mail'
let g:mail_from = 'Your Name <youraddress@gmail.com>'
```

## Mailbox prompts

All places that ask for a mailbox name go through `mail#_prompt_mailbox(prompt, default)`:
- `mail#move()` — `M` keymap
- `mail#fetch()` — `<leader>f` keymap
- `:Mail` command — uses `-complete=customlist,mail#_complete_mailbox`

`mail#_complete_mailbox(arglead, cmdline, cursorpos)` returns a List of dir basenames under
`g:mail_root` filtered by arglead. `mail#_complete_mailbox_str` is the `custom,` variant
(newline-joined) used by `input()`. Never call `input()` directly for mailbox names.

## Reply-all

`mail#reply()` reads `meta.cc`, strips any address matching `g:mail_from`, and prefills
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
- CID inline images in the stored `body.html` still reference `cid:xxx` (not local
  file paths) for *viewing*. When a class-2 reply embeds `body.html`, those parts are
  re-attached as `multipart/related` cid parts so the quoted original keeps its inline
  images across clients. Resolving cid at ingest time (for the viewer) is still
  unimplemented.
