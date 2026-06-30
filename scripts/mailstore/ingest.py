"""Ingest: explode one RFC822 message into the one-folder-per-message store."""

import email
import email.utils
import hashlib
import html as html_module
import mailbox
import mimetypes
import os
from datetime import datetime, timezone
from email import policy
from email.message import EmailMessage
from pathlib import Path
from typing import Optional

from .htmltext import _build_cid_map, html_to_text, text_cid_to_markers


def _message_datetime(msg: EmailMessage) -> datetime:
    date_header = msg.get("Date")
    if date_header is not None:
        try:
            dt = email.utils.parsedate_to_datetime(str(date_header))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc)
        except (TypeError, ValueError):
            pass
    return datetime.now(timezone.utc)


def _message_id_hash(msg: EmailMessage, raw: bytes) -> str:
    msgid = msg.get("Message-ID")
    basis = str(msgid).strip().encode() if msgid is not None else raw
    return hashlib.sha1(basis).hexdigest()[:8]


def _write_meta(msg: EmailMessage, meta_path: Path) -> None:
    lines = []
    for key in ("From", "Reply-To", "To", "Cc", "Subject", "Date", "Message-ID", "In-Reply-To"):
        value = msg.get(key)
        text = " ".join(str(value).split()) if value is not None else ""
        lines.append(f"{key}: {text}")
    meta_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _write_body(
    msg: EmailMessage, msg_dir: Path, cid_map: dict[str, str] | None = None
) -> list[str]:
    """Write body.txt (and body.html when present). Returns ordered list of
    CID-referenced filenames so ingest_one can build the Attachments footer."""
    # Prefer HTML: most modern senders (Gmail, QQ, Outlook) treat HTML as the
    # authoritative part; their auto-generated text/plain often contains literal
    # HTML entities (&nbsp; etc.) that look broken when quoted in replies.
    body_part = msg.get_body(preferencelist=("html", "plain"))
    if body_part is None:
        (msg_dir / "body.txt").write_text("", encoding="utf-8")
        return []
    content = body_part.get_content()
    if body_part.get_content_type() == "text/html":
        (msg_dir / "body.html").write_text(content, encoding="utf-8")
        text, cid_refs = html_to_text(content, cid_map)
        (msg_dir / "body.txt").write_text(text, encoding="utf-8")
        return cid_refs
    else:
        # Unescape any stray HTML entities in plain-text parts and normalise
        # non-breaking spaces to regular spaces. Render [cid:...] inline-image
        # tokens as [img N] via the shared numberer — same markers the HTML path
        # emits — and return their filenames for the Attachments footer.
        clean = html_module.unescape(content).replace('\xa0', ' ')
        clean, cid_refs = text_cid_to_markers(clean, cid_map)
        (msg_dir / "body.txt").write_text(clean, encoding="utf-8")
        return cid_refs


def _safe_filename(name: Optional[str], idx: int, content_type: str) -> str:
    if name:
        name = os.path.basename(str(name)).strip().lstrip(".")
    if not name:
        ext = mimetypes.guess_extension(content_type) or ""
        name = f"part_{idx}{ext}"
    return name


def _attachment_content(part: EmailMessage) -> tuple[object, str]:
    """Most attachments decode cleanly via get_content(). Two exceptions
    seen in practice: a forwarded message attached as message/rfc822
    (get_content() returns an EmailMessage, not bytes), and a multipart
    container misclassified as an attachment (get_content() has no
    registered handler and raises KeyError). Both get dumped as raw
    .eml bytes instead of decoded."""
    try:
        content = part.get_content()
    except KeyError:
        return part.as_bytes(), ".eml"
    if isinstance(content, EmailMessage):
        return content.as_bytes(), ".eml"
    return content, ""


def _write_attachments(msg: EmailMessage, attachments_dir: Path) -> list[str]:
    """Write all attachment parts to attachments_dir. Returns saved filenames."""
    attachments = list(msg.iter_attachments())
    if not attachments:
        return []
    attachments_dir.mkdir(exist_ok=True)
    used_names: set[str] = set()
    saved: list[str] = []
    for i, part in enumerate(attachments, 1):
        content, forced_ext = _attachment_content(part)
        name = part.get_filename()
        if not name and forced_ext:
            name = f"part_{i}{forced_ext}"
        name = _safe_filename(name, i, part.get_content_type())
        while name in used_names:
            stem, _, ext = name.rpartition(".")
            name = f"{stem or name}_{i}" + (f".{ext}" if ext else "")
        used_names.add(name)
        path = attachments_dir / name
        if isinstance(content, str):
            path.write_text(content, encoding="utf-8")
        else:
            path.write_bytes(content)
        saved.append(name)
    return saved


def ingest_one(raw: bytes, mailbox_dir: Path) -> Optional[Path]:
    """Explode one RFC822 message into mailbox_dir. Returns the created
    directory, or None if a directory for this message already exists."""
    msg = email.message_from_bytes(raw, policy=policy.default)
    dt = _message_datetime(msg)
    msgid_hash = _message_id_hash(msg, raw)
    dirname = f"{dt.strftime('%Y%m%dT%H%M%SZ')}_{msgid_hash}"
    msg_dir = mailbox_dir / dirname
    if msg_dir.exists():
        return None

    tmp_dir = mailbox_dir / f".tmp_{dirname}"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    (tmp_dir / "raw.eml").write_bytes(raw)
    _write_meta(msg, tmp_dir / "meta")
    cid_map = _build_cid_map(msg)
    cid_refs = _write_body(msg, tmp_dir, cid_map)
    saved = _write_attachments(msg, tmp_dir / "attachments")

    # Append a unified "Attachments:" footer to body.txt listing every file
    # saved into attachments/. CID-referenced parts (inline images etc.) come
    # first in HTML appearance order — their [img N] markers in the body refer
    # to entry N here. Non-CID parts (real user attachments: PDFs, zips, …)
    # follow with no inline marker.
    if saved:
        cid_set = set(cid_refs)
        ordered = list(cid_refs) + [f for f in saved if f not in cid_set]
        body_path = tmp_dir / "body.txt"
        existing = body_path.read_text(encoding="utf-8").rstrip()
        lines = ["", "", "Attachments:"] + [
            f"[{i}] {fn}" for i, fn in enumerate(ordered, 1)
        ]
        body_path.write_text(existing + "\n" + "\n".join(lines) + "\n", encoding="utf-8")

    tmp_dir.rename(msg_dir)
    return msg_dir


def migrate_mbox(mbox_path: Path, mailbox_dir: Path) -> None:
    mailbox_dir.mkdir(parents=True, exist_ok=True)
    box = mailbox.mbox(str(mbox_path))
    total = len(box)
    created = skipped = failed = 0
    for i, msg in enumerate(box, 1):
        try:
            result = ingest_one(msg.as_bytes(), mailbox_dir)
            if result is None:
                skipped += 1
            else:
                created += 1
        except Exception as exc:
            failed += 1
            print(f"  [{i}/{total}] FAILED: {exc}")
        if i % 200 == 0 or i == total:
            print(f"  {i}/{total} (created={created} skipped={skipped} failed={failed})")
    print(f"Done. created={created} skipped={skipped} failed={failed}")
