"""Command-line dispatch: migrate / ingest-stdin / quote / viewhtml / send."""

import sys
from pathlib import Path
from typing import Optional

from .images import _inline_cid_data_uris
from .ingest import ingest_one, migrate_mbox, migrate_store
from .quote import quote_text
from .send import send_mail


USAGE = (
    "usage: mail_store.py migrate <mbox> <mailbox-dir>\n"
    "                   | migrate-store <mail-root>\n"
    "                   | ingest-stdin <mailbox-dir>\n"
    "                   | send <compose-file> [<orig-msg-dir> [<sent-dir>]]\n"
    "                   | quote <msg-dir>\n"
    "                   | viewhtml <msg-dir>"
)


def main(argv: Optional[list[str]] = None) -> None:
    argv = sys.argv[1:] if argv is None else argv
    if not argv:
        sys.exit(USAGE)
    cmd, rest = argv[0], argv[1:]
    if cmd == "migrate" and len(rest) == 2:
        migrate_mbox(Path(rest[0]).expanduser(), Path(rest[1]).expanduser())
    elif cmd == "migrate-store" and len(rest) == 1:
        counts = migrate_store(Path(rest[0]).expanduser())
        print(
            f"migrated={counts['migrated']} deduped={counts['deduped']} "
            f"skipped={counts['skipped']}"
        )
    elif cmd == "ingest-stdin" and len(rest) == 1:
        mailbox_dir = Path(rest[0]).expanduser()
        mailbox_dir.mkdir(parents=True, exist_ok=True)
        ingest_one(sys.stdin.buffer.read(), mailbox_dir)
    elif cmd == "quote" and len(rest) == 1:
        raw_file = Path(rest[0]).expanduser() / "raw.eml"
        raw = raw_file.read_bytes() if raw_file.exists() else b""
        sys.stdout.write(quote_text(raw))
    elif cmd == "viewhtml" and len(rest) == 1:
        d = Path(rest[0]).expanduser()
        html_file = d / "body.html"
        if not html_file.exists():
            sys.exit("no body.html")
        html = html_file.read_text(encoding="utf-8", errors="replace")
        raw_file = d / "raw.eml"
        if raw_file.exists():
            # cid: refs can't resolve from a file:// page — inline them as data:
            # URIs so the image shows when opening the HTML in a browser.
            html = _inline_cid_data_uris(html, raw_file.read_bytes())
        sys.stdout.write(html)
    elif cmd == "send" and len(rest) in (1, 2, 3):
        orig = Path(rest[1]).expanduser() if len(rest) >= 2 and rest[1] else None
        sent = Path(rest[2]).expanduser() if len(rest) >= 3 and rest[2] else None
        try:
            send_mail(Path(rest[0]).expanduser(), orig, sent)
        except Exception as exc:
            print(f"send failed: {exc}", file=sys.stderr)
            sys.exit(1)
    else:
        sys.exit(USAGE)
