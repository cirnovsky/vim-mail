# vim-mail

Netrw-style Vim plugin for a mail store where a message is ONE object and
mailboxes are labels (gmail-style). The full setup doc (Postfix relay,
fetchmail, mail_store.py) lives at `mail-setup.md` (in this repo). This file
covers only what's needed to work on the plugin itself.

## Storage format (content store + symlink labels)

Canonical bytes live **once** in the hidden content store; each mailbox is a
directory of **relative symlinks** into it. Membership = a label.

```
/path/to/Mail/
    .store/<UTC-timestamp>_<8-hex-hash>/   canonical content, bytes live once
        raw.eml          original RFC822 bytes, never modified
        meta             From/To/Cc/Subject/Date/Message-ID/In-Reply-To, one per line
        body.txt         decoded plain text; Links: footer; [img N] markers; Attachments: footer
        body.html        present only when an HTML part exists
        attachments/     decoded non-body parts, original filenames
        .read            marker file; presence = message is read (SHARED across labels)
    <mailbox>/<id>       symlink -> ../.store/<id>   (membership only)
```

- `<id>` (the store dir basename) is the stable per-line ID in the index buffer.
- **copy** = another symlink, **move** = relink, **delete** = unlink. The last
  label falling sends the message to `trash`; deleting from `trash` removes the
  canonical bytes. Read-state is shared: one `.store/<id>/.read` seen through
  every label.
- `.store` and `.tmp_*`/`.linktmp_*` are dot-prefixed, so the index/mailbox
  readers (which skip `^\.`) never list them as messages.
- Reads flow through symlinks transparently — `glob`/`isdirectory`/`readfile`
  all follow the link, so the reading code is unchanged.

**Legacy real dirs.** A pre-content-store mailbox holds real `<mailbox>/<id>/`
directories (no `.store`, no symlinks). Everything still works: reads are
identical, and move/delete/copy detect a real dir (`getftype() != 'link'`) and
fall back to physical rename/rf, or migrate it into the store on touch. Run
`:MailMigrate` (or `mail_store.py migrate-store <root>`) to convert a whole
store — deduping multi-copy mail into one canon, resumable and non-destructive.

## Architecture

All MIME work is in the `scripts/mailstore/` package (Python; entry point
`scripts/mail_store.py`). The Vim plugin reads only `meta` and `body.txt`; it
never parses MIME itself.

```
plugin/mail.vim           :Mail (-> launcher / a mailbox) + :MailMigrate + g:mail_* setup
autoload/mail/mailboxlist.vim read-only mailbox launcher (:Mail list, <CR>/- navigation)
autoload/mail/mailbox.vim mailbox path resolution, completion, prompting
autoload/mail/util.vim    shared helpers (py_cmd)
autoload/mail/index.vim   index buffer: render, refresh/merge, line<->entry, cross-buffer :w helpers
autoload/mail/actions.vim staged actions: marks, read/unread, delete + paste-link (:w), migrate
autoload/mail/link.vim    link map L {id -> mailboxes}: readdir-built refcount source
autoload/mail/thread.vim  cross-mailbox message-id index
autoload/mail/view.vim    reading: preview, full open, html/mime view, search
autoload/mail/compose.vim compose, reply, forward
autoload/mail/send.vim    assemble + send the compose buffer
autoload/mail/attach.vim  attachments + inline images (+ clipboard)
autoload/mail/fetch.vim   async fetchmail
ftplugin/mail-index.vim   keymaps + BufWriteCmd
ftplugin/mail-mailboxes.vim launcher keymaps (read-only: <CR> enter, q close)
ftplugin/mail-compose.vim :w sends
syntax/mail-index.vim     conceals the hidden per-line message id
scripts/mail_store.py     Python backend entry point (thin shim)
scripts/mailstore/        backend package: htmltext/ingest/quote/images/send/cli
                          ingest.ingest_one writes .store + symlink; migrate_store converts a flat store
mail-setup.md             full backend setup doc (Postfix relay, fetchmail, store)
setup.sh                  one-off: prints vimrc + fetchmailrc config for this clone
Makefile                  `make test` (local) / `make test-linux` (Docker)
tests/run.sh              test runner: auto-discovers tests/test_*.{py,vim}
tests/Dockerfile          Debian image to run the suite under Linux
tests/fixtures/mail/      .eml corpus (plain/html/multipart/attachment/thread-*) — real messages
tests/testlib/autoload/testmail.vim  shared generator: build a store from .eml via the real engine
tests/_fixtures.py        Python fixtures: eml()/build_store()/legacy() (also via the real engine)
tests/test_reply.py       reply/threading suite (Python)
tests/test_store.py       content store: ingest -> .store + symlink, dedup, shared .read
tests/test_migrate.py     migrate_store: flat store -> .store + symlinks, dedup, resumable
tests/test_store_ops.vim  link-safe delete: unlink, refcount, trash, permanent
tests/test_link.vim       link map L: labels + count_others reflect disk
tests/test_paste.vim      native dd+p = move / yy+p = copy across mailbox buffers
tests/test_write_all.vim  one :w commits every modified index buffer
tests/test_fetch_merge.vim fetch/nav merges new mail into a modified buffer, edits kept
tests/test_launcher.vim   :Mail launcher: read-only list, <CR> enter, - return
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

**Fixtures come from the real engine.** Store fixtures are built from real `.eml`
files (`tests/fixtures/mail/*.eml`) run through the actual backend — never
hand-shaped canons. Vim suites `set rtp+=<repo>/tests/testlib` and call
`testmail#ingest`/`testmail#build`/`testmail#legacy` (which shell
`mail_store.py ingest-stdin`); Python suites use `_fixtures.eml`/`build_store`/
`legacy` (real `ingest.ingest_one`). Ids are derived from each message's
Date+Message-ID, so tests **capture** the id from the build result rather than
hardcoding it. `testmail#legacy` / `_fixtures.legacy` build a faithful
pre-content-store real dir (ingest, then "de-symlink" the canon back into the
mailbox) — the only way to get old-format mail, since no current verb emits it.
`testmail#` also holds the shared `wipe_buffers`/`goto`/`ftype`/`has_entry`
helpers (previously duplicated across every suite). Because Vim fixtures shell
out to `python3`, these suites need it on `PATH` (the plugin requires it anyway).

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
- current line underlined: buffer-local `cursorline` + `CursorLine` restyled to a
  plain (no-background) underline in `ftplugin/mail-index.vim`
- `N` = unread, space = read; `*` = marked, space = unmarked
- `dd`/`d3j`/`:g//d` work natively — Vim's own delete machinery
- `b:mail_entries` = disk baseline (`[{id, dir, read, meta}]`), ordered by original sort
- Buffer text is the **authoritative staged state** for both read/unread and deletions
- `b:mail_entries[idx].read` = last-saved disk state (only updated by `mail#index#refresh()`)

## `:w` semantics (buffer as source of truth)

`BufWriteCmd` calls `mail#actions#write()`, which commits the staged edits of the
current index buffer **and every other modified index buffer** — one `:w`
reconciles all mailboxes. It runs in **two phases** across those buffers, because
a `dd`-here / paste-there move must add the destination label *before* dropping
the source (else the refcount would treat the source as the last label and trash
it):
- **Phase 1** — reconcile read-marks and add pasted labels; *collect* the deletes.
- **Phase 2** — execute the deletes, once every add is already on disk.

Per buffer, diffing its lines against its `b:mail_entries` baseline:
- **Line missing** → drop this mailbox's label (`_delete_entry`): unlink the
  symlink, then consult L — last label → link into `trash` (or, from `trash`,
  `rm -rf` the canon, permanent); still labelled elsewhere → just unlink. **Never**
  `delete(...,'rf')` a symlink (that rf's through into the store); flagless
  `delete()` unlinks safely. Legacy real dirs fall back to physical rename/rf.
- **Line present but not in the baseline** → a line pasted from another mailbox
  (native `dd`+`p` / `yy`+`p`): `_add_pasted_labels` links it here (migrating a
  legacy source on touch). An id that resolves to nothing is ignored.
- **Read indicator differs** → `.read` written/deleted (via the symlink → the
  shared canonical `.read`).

All staged until `:w`; `u` reverts before committing. `refresh()` ends with
`setlocal nomodified`, so `&modified` means "staged, uncommitted changes exist."

**Move and copy are native gestures, not commands.** `dd`+`p` (cut here, paste
into another mailbox buffer) = move; `yy`+`p` = copy; both commit on `:w` via the
add/delete passes above. There is **no** `:M`/`:Move`/`:Copy` command or `M`
keymap — the launcher (`-`) makes opening the destination to paste into one
keystroke. A move needs both buffers loaded (you paste into the dest); the
launcher's `<CR>`/`-` navigation keeps them loaded. Trade-off (accepted): `u` in
the source buffer after `dd`+`p` restores the source line but not the dest paste,
so it turns the move into a *copy* (recoverable — `dd` it from one).

**No staged-edit guard — navigation and fetch MERGE instead of discarding.** Any
path that would otherwise rebuild a modified buffer from disk (wiping staged
edits) instead inserts only the newly-appeared mail, leaving edited lines
untouched (`mail#index#_merge_new()`):
- `mail#index#open()` (the `:Mail` path): first open / return-to-*unmodified* →
  full `refresh()`; return-to-**modified** → `_merge_new()`. Otherwise navigating
  away and back would turn a `dd`+`p` move into an accidental copy (the source
  never gets unlinked).
- `mail#index#refresh_for()` (fetch completion): visible + unmodified → full
  refresh; visible + **modified** → `_merge_new()`; hidden → nothing (the merge
  runs on the next navigation). So fetch never prompts.

`_merge_new()` inserts, newest-first, only ids on disk that are in neither the
baseline nor the current lines; a staged-*deleted* message stays in the baseline
so it is not resurrected; it's a no-op when nothing is new. `R` still
full-refreshes on purpose (an explicit discard). Regression-tested in
`test_fetch_merge.vim`, `test_paste.vim`, `test_workflow.vim`, `test_write_all.vim`.

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

**Content store & link operations (`mail#actions#*`, `mail#link#*`)**
- `_store_root()` = `<mail_root>/.store`. `_make_link(id, dest)` shells out to
  `ln -s ../.store/<id> dest/<id>` (Vim has no native `symlink()`). `_unlink(dir)`
  = flagless `delete()` — unlinks a symlink, never rf's through it.
- `getftype(entry.dir) ==# 'link'` distinguishes a store label from a legacy real
  dir; the link ops branch on it (`getftype(target) !=# ''` = "already exists").
- **Link map L** (`autoload/mail/link.vim`): `{id → {mailbox-name → 1}}`, rebuilt
  from `readdir()` (names only, no meta reads) at `:Mail`/`open()` and at the top
  of each `write()`. `count_others(id, mbox)` is the O(1) last-label refcount —
  it excludes `mbox`, so the just-done unlink in `_delete_entry` doesn't skew it.
- `_ensure_canonical(dir)` = migrate-on-touch: a legacy real dir is moved into
  `.store/<id>` and replaced by a symlink (used by the paste path so both
  mailboxes share one canon). `_find_source(id, excl)` locates a legacy source for
  a pasted id. There are no move/copy *functions* — move is `dd`+`p`, copy is
  `yy`+`p`, both reconciled by `write()` (no `_guarded_targets`/`_resolve_dest`).

**Msgid index cache**
`mail#thread#_build_msgid_index()` scans `meta` files across all mailboxes to build
`{message-id → dir}` for thread reconstruction (reads through symlinks). Result
cached in `s:msgid_index`; invalidated by `mail#index#refresh()`. Never reads
`raw.eml` as fallback. (A message with two labels is read once per link but maps
to the same canon — harmless; a `.store`-once scan is a possible optimization.)

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
Opens in a bottom split maximized to full height (`wincmd _`) for a full-screen
read; the index stays a 1-line sliver so `:q` returns to it (no quit-Vim risk).

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
| `dd`, `d3j`, `:g/pat/d` | Staged delete (unlink label; last label → trash) — committed on `:w` |
| `dd`+`p` / `yy`+`p` | Native cross-buffer move / copy (paste into another mailbox buffer; linked on `:w`) |
| `s` | Mark targets read (staged) |
| `S` | Mark targets unread (staged) |
| `t` / `tt` / `t3j` | Toggle selection mark `*` (operator-pending) |
| `T` | Clear all marks |
| `-` | Up to the mailbox launcher (`:Mail` list) |
| `r` | Reply (opens compose buffer, `:w` sends) |
| `f` | Forward inline (original embedded in the body; re-render, like Gmail) |
| `F` | Forward as attachment (original as a `message/rfc822` `.eml`; byte-exact) |

Compose-buffer keymaps (in `ftplugin/mail-compose.vim`): `:Attach {paths…}` /
`<leader>A` (attach by path), `<leader>a` (attach clipboard files), `<leader>p`
(inline clipboard image / image files). Screenshot data needs no extra tools on
macOS (built-in `osascript`); Linux uses `wl-paste`/`xclip`.
| `<leader>c` | Compose new message |
| `<leader>f` | Fetch mail (async fetchmail; merges new mail into the index, staged edits preserved) |
| `R` | Refresh from disk (explicit — discards staged edits) |
| `q` | Close buffer |

"Targets" for `s`/`S`: all `*`-marked messages if any, else current line. Global
command `:MailMigrate` converts an existing flat store to the content-store layout
(shells out to `mail_store.py migrate-store`, then rebuilds L).

## Mailbox launcher

`:Mail` (no arg) opens a **read-only** list of all mailboxes under `g:mail_root`
(inbox/sent floated to top; `.store` hidden) — `autoload/mail/mailboxlist.vim` +
`ftplugin/mail-mailboxes.vim`, buffer `mail://[mailboxes]`, `nomodifiable` so a
stray `dd` can't delete a whole mailbox. `<CR>` enters the mailbox under the
cursor (its own `mail://<name>` buffer); `-` from a mailbox returns to the list;
`q` closes. `:Mail <box>` still opens a mailbox directly, skipping the list. It's
a **launcher**, not single-buffer netrw: each mailbox keeps its own persistent
buffer, so staged edits and `dd`+`p`/`yy`+`p` moves survive navigation. `:Mail`
dispatches through `mail#mailboxlist#mail_cmd()` (empty → list, else `index#open`).

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

Mailbox names come from: `mail#fetch#fetch()` (`<leader>f`, via
`mail#mailbox#_prompt_mailbox`); `:Mail <box>` (command completion); and the
launcher `<CR>` (the current line). Move/copy no longer prompt (they're `dd`+`p`
/ `yy`+`p`).

`_complete_mailbox` globs `g:mail_root/*` and skips `.store` (dot-prefixed), so it
never offers the content store as a mailbox.

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
- Some old messages moved before the `/` separator fix have a `history` prefix in
  their dir name — thread reconstruction won't find them by Message-ID.
- `dd`+`p` move's undo is per-buffer: `u` in the source after `dd`+`p` restores
  the source line but not the dest paste, leaving the message linked in BOTH
  mailboxes (an accidental copy — recoverable by `dd`-ing one). Accepted as the
  price of the native-gesture model; there's no command-move alternative anymore.
  (*Future:* a batch `:M`/`:Move` could be added back later.)
- `t` (toggle mark, operator-pending) and `T` (clear marks) overlap in mnemonic
  space — kept as-is for now.
- Legacy real dirs and store symlinks coexist in a partially-migrated store; both
  render and operate correctly (link ops branch on `getftype() == 'link'`), but
  dedup/label-sharing only applies to store-backed messages until `:MailMigrate`.
- The stored `body.html` keeps `cid:xxx` refs (pristine). Two consumers rewrite them
  on the fly, never the stored file: **viewing** (`x` → `mail_store.py viewhtml` →
  `_inline_cid_data_uris` rewrites `cid:`→`data:` URIs in a temp copy for the browser,
  since `cid:` can't resolve from `file://`); **replying** (class-2 embed re-attaches
  them as `multipart/related` parts for cross-client rendering). `data:`/external
  (`http`) refs are passed through untouched by both. External images load per the
  browser/remote — e.g. an oversized Wikimedia thumbnail URL the sender used may 400.
