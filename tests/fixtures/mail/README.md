# Mock mail corpus

Real `.eml` fixtures for building test stores through the **real** engine
(`mail_store.py ingest-stdin`) — never hand-shaped canons. Each file has a stable
`Date` + `Message-ID`, so ingesting it yields a deterministic message id
(`<UTC-timestamp>_<8-hex sha1(msgid)>`); tests capture that id from the ingest
result rather than hardcoding it.

Load them via the shared generator in `tests/testlib/autoload/testmail.vim`
(Vim) or `tests/_fixtures.py` (Python).

| File | Shape it exercises |
|---|---|
| `plain.eml` | minimal `text/plain` — link-op tests where content is irrelevant |
| `html.eml` | `text/html` body with a link (HTML → `body.txt`, Links footer) |
| `multipart.eml` | `multipart/alternative` (plain + html) |
| `attachment.eml` | `multipart/mixed` with a `note.txt` attachment |
| `thread-parent.eml` | a thread root (has `Message-ID`, no `In-Reply-To`) |
| `thread-reply.eml` | reply carrying `In-Reply-To`/`References` to the parent |

The richer real-world message with tables, an inline cid image, an external
image and a `.ics` lives at `../embrace-the-chaos/raw.eml`.
