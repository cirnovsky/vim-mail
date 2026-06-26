"""Explode RFC822 messages into a one-folder-per-message mail store.

<mailbox-dir>/<UTC-timestamp>_<8-hex msgid hash>/
    raw.eml              original bytes, untouched
    meta                 From/To/Subject/Date, one per line
    body.txt             decoded plain-text body (or HTML->text fallback)
    body.html            present only if an HTML part existed
    attachments/<name>   every non-body part, decoded, original filename

The directory name doubles as the dedup key: ingest_one() skips messages
whose target directory already exists, which is what makes migrate_mbox()
resumable without a separate progress file.
"""

import email
import email.utils
import hashlib
import html as html_module
import mailbox
import mimetypes
import os
import sys
from datetime import datetime, timezone
from email import policy
from email.message import EmailMessage
from html.parser import HTMLParser
from pathlib import Path
from typing import Optional

USAGE = (
    "usage: mail_store.py migrate <mbox> <mailbox-dir>\n"
    "                   | ingest-stdin <mailbox-dir>\n"
    "                   | send <compose-file> [<orig-msg-dir> [<sent-dir>]]\n"
    "                   | quote <msg-dir>\n"
    "                   | viewhtml <msg-dir>"
)


class _TextExtractor(HTMLParser):
    def __init__(self, cid_map: dict[str, str] | None = None,
                 link_footnotes: bool = True) -> None:
        super().__init__()
        self._skip = False
        self.chunks: list[str] = []
        self._links: list[str] = []       # collected hrefs, in order
        self._link_href: str = ""         # href of currently open <a>
        self._link_chunk_start: int = 0   # chunks index when <a> opened
        # When False, link text is kept but no "[N]" markers / "Links:" footer
        # are emitted (used for reply quoting — footnote URLs are noise there).
        self._link_footnotes = link_footnotes
        self._cid_map: dict[str, str] = cid_map or {}
        self._cid_refs: list[str] = []    # filenames in order of first appearance
        self._cid_seen: set[str] = set()

    def handle_starttag(self, tag: str, attrs: list) -> None:
        if tag in ("script", "style"):
            self._skip = True
        if tag in ("br", "p", "div", "tr", "li", "h1", "h2", "h3"):
            self.chunks.append("\n")
        if tag == "a":
            hrefs = [v for k, v in attrs if k == "href" and v]
            if hrefs:
                href = hrefs[0]
                # Skip anchors, javascript, and mailto (not actionable as text)
                if not href.startswith(("javascript:", "#", "mailto:")):
                    self._link_href = href
                    self._link_chunk_start = len(self.chunks)
        if tag in ("img", "audio", "video", "embed", "source"):
            src = next((v for k, v in attrs if k == "src" and v), "")
            if src.lower().startswith("cid:"):
                cid = src[4:].strip()
                fname = self._cid_map.get(cid, cid)
                if fname not in self._cid_seen:
                    self._cid_seen.add(fname)
                    self._cid_refs.append(fname)
                n = self._cid_refs.index(fname) + 1
                alt = next((v for k, v in attrs if k == "alt" and v), "")
                kind = "img" if tag == "img" else tag
                label = f"{alt} [{kind} {n}]" if alt else f"[{kind} {n}]"
                self.chunks.append(label)
        if tag == "object":
            data = next((v for k, v in attrs if k == "data" and v), "")
            if data.lower().startswith("cid:"):
                cid = data[4:].strip()
                fname = self._cid_map.get(cid, cid)
                if fname not in self._cid_seen:
                    self._cid_seen.add(fname)
                    self._cid_refs.append(fname)
                n = self._cid_refs.index(fname) + 1
                self.chunks.append(f"[object {n}]")

    def handle_endtag(self, tag: str) -> None:
        if tag in ("script", "style"):
            self._skip = False
        if tag == "a" and self._link_href:
            link_text = "".join(self.chunks[self._link_chunk_start:]).strip()
            # Emit footnote marker only when visible text differs from the URL
            # itself (avoids duplicating raw URLs already in the body), and only
            # when footnotes are enabled.
            if self._link_footnotes and link_text and link_text != self._link_href:
                n = len(self._links) + 1
                self._links.append(self._link_href)
                self.chunks.append(f" [{n}]")
            self._link_href = ""

    def handle_data(self, data: str) -> None:
        if not self._skip:
            self.chunks.append(data.replace('\xa0', ' '))


def _build_cid_map(msg: EmailMessage) -> dict[str, str]:
    """Map stripped Content-ID → filename for all MIME parts that have one."""
    result: dict[str, str] = {}
    for part in msg.walk():
        cid = part.get("Content-ID")
        if cid:
            stripped = cid.strip().strip("<>")
            result[stripped] = part.get_filename() or stripped
    return result


def html_to_text(html: str, cid_map: dict[str, str] | None = None,
                 link_footnotes: bool = True) -> tuple[str, list[str]]:
    """Convert HTML to plain text. Returns (text, cid_filenames_in_order).
    link_footnotes=False suppresses the 'Links:' footer and inline [N] markers
    (used for reply quoting)."""
    extractor = _TextExtractor(cid_map, link_footnotes=link_footnotes)
    extractor.feed(html)
    raw_lines = ("".join(extractor.chunks)).splitlines()
    # Collapse runs of blank lines to a single blank; strip leading whitespace.
    result: list[str] = []
    prev_blank = False
    for line in (l.strip() for l in raw_lines):
        if not line:
            if not prev_blank and result:
                result.append("")
            prev_blank = True
        else:
            result.append(line)
            prev_blank = False
    while result and not result[-1]:
        result.pop()
    # Append link footnotes when any actionable hrefs were found
    if extractor._links:
        result.append("")
        result.append("Links:")
        for i, href in enumerate(extractor._links, 1):
            result.append(f"[{i}] {href}")
    return "\n".join(result), extractor._cid_refs


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
    for key in ("From", "To", "Cc", "Subject", "Date", "Message-ID", "In-Reply-To"):
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
        # non-breaking spaces to regular spaces.
        clean = html_module.unescape(content).replace('\xa0', ' ')
        (msg_dir / "body.txt").write_text(clean, encoding="utf-8")
        return []


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


def _quote_depth(line: str) -> tuple[int, str]:
    """Return (quote nesting depth, remaining content) for a body line.
    '> x' -> (1, 'x'); '>> x' / '> > x' -> (2, 'x'); 'x' -> (0, 'x')."""
    depth = 0
    i = 0
    n = len(line)
    while i < n and line[i] == ">":
        depth += 1
        i += 1
        if i < n and line[i] == " ":
            i += 1
    return depth, line[i:]


def _plain_to_html(body: str) -> str:
    """Render a plain-text mail body (with '>'/'>>' quoting) to HTML that
    mirrors it IN ORDER: runs of quoted lines become nested <blockquote>s,
    user text stays inline. This preserves top/bottom/interleaved posting —
    unlike a naive 'pull all > lines to the bottom' approach."""
    lines = body.split("\n")
    while lines and lines[-1] == "":
        lines.pop()
    bq_open = (
        '<blockquote style="margin:0 0 0 0.8em;padding-left:0.8em;'
        'border-left:2px solid #ccc;color:#555">'
    )
    out: list[str] = []
    depth = 0
    for line in lines:
        d, content = _quote_depth(line)
        while depth < d:
            out.append(bq_open)
            depth += 1
        while depth > d:
            out.append("</blockquote>")
            depth -= 1
        out.append(html_module.escape(content) + "<br>")
    while depth > 0:
        out.append("</blockquote>")
        depth -= 1
    return "<html><body>" + "".join(out) + "</body></html>"


def quote_text(raw: bytes) -> str:
    """Best clean plain text of a message for quoting in a reply.

    Prefers the sender's own text/plain part (entity-unescaped, nbsp→space) —
    clean by construction. Falls back to a footnote-free html_to_text render
    for HTML-only messages. Never includes our 'Links:'/'[N]' reading-aid
    footnotes (those are added to body.txt, not wanted in a quote)."""
    if not raw:
        return ""
    msg = email.message_from_bytes(raw, policy=policy.default)
    plain = msg.get_body(preferencelist=("plain",))
    if plain is not None and plain.get_content_type() == "text/plain":
        text = plain.get_content()
        return html_module.unescape(text).replace("\xa0", " ").rstrip("\n")
    html = msg.get_body(preferencelist=("html",))
    if html is not None and html.get_content_type() == "text/html":
        text, _ = html_to_text(
            html.get_content(), _build_cid_map(msg), link_footnotes=False
        )
        return text
    return ""


def _cid_parts(raw: bytes) -> dict[str, tuple[str, bytes]]:
    """Map stripped Content-ID -> (content_type, bytes) for every inline part
    of a message, so an embedded original's cid: images can be re-attached."""
    msg = email.message_from_bytes(raw, policy=policy.default)
    out: dict[str, tuple[str, bytes]] = {}
    for part in msg.walk():
        cid = part.get("Content-ID")
        if not cid:
            continue
        try:
            payload = part.get_content()
        except Exception:
            continue
        if isinstance(payload, str):
            payload = payload.encode("utf-8", "replace")
        if isinstance(payload, (bytes, bytearray)):
            out[cid.strip().strip("<>")] = (part.get_content_type(), bytes(payload))
    return out


def _sniff_image_type(data: bytes, fallback: str) -> str:
    """Guess an image content-type from magic bytes. Senders (e.g. QQ) often
    label inline images as application/octet-stream; a real image/* type helps
    stricter clients render the cid reference."""
    sigs = [
        (b"\x89PNG\r\n\x1a\n", "image/png"),
        (b"\xff\xd8\xff", "image/jpeg"),
        (b"GIF87a", "image/gif"),
        (b"GIF89a", "image/gif"),
        (b"BM", "image/bmp"),
    ]
    for sig, ctype in sigs:
        if data.startswith(sig):
            return ctype
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return fallback if fallback.startswith("image/") else (fallback or "application/octet-stream")


def _inline_cid_data_uris(html: str, raw: bytes) -> str:
    """Rewrite src/background="cid:ID" in HTML to self-contained data: URIs from
    the message's own inline parts — for *viewing* the stored body.html in a
    browser, where cid: can't resolve. (Replies use multipart/related instead.)
    cid refs with no matching part are left untouched."""
    import base64
    import re as _re
    parts = _cid_parts(raw)
    if not parts:
        return html

    def repl(m: "_re.Match") -> str:
        attr, quote, cid = m.group(1), m.group(2), m.group(3).strip()
        entry = parts.get(cid)
        if entry is None:
            return m.group(0)
        ctype, data = entry
        ctype = _sniff_image_type(data, ctype)
        b64 = base64.b64encode(data).decode("ascii")
        return f"{attr}={quote}data:{ctype};base64,{b64}{quote}"

    return _re.sub(r'(src|background)=(["\'])cid:([^"\']+)\2', repl, html,
                   flags=_re.IGNORECASE)


def _embed_inline_images(msg: EmailMessage, imap: dict) -> None:
    """Turn '[img <id>]' markers in the HTML part into inline cid images.

    imap: {id: (content_type, bytes)}. The matching `[img id]` in the text/html
    part becomes <img src="cid:mail-inline-<id>"> and the bytes are attached as a
    multipart/related part. The text/plain part keeps the literal `[img id]`
    (round-trips to the recipient's body.txt). Marker ids with no image are left
    as-is."""
    import re as _re
    html_leaf = next((p for p in msg.walk()
                      if p.get_content_type() == "text/html"), None)
    if html_leaf is None:
        return
    used: set[str] = set()

    def repl(m: "_re.Match") -> str:
        i = m.group(1)
        if i in imap:
            used.add(i)
            return f'<img src="cid:mail-inline-{i}" style="max-width:100%">'
        return m.group(0)

    new_html = _re.sub(r"\[img (\d+)\]", repl, html_leaf.get_content())
    if not used:
        return
    html_leaf.set_content(new_html, subtype="html")
    # Attach into the existing related container (reply embedding) if present,
    # else add_related converts the html leaf into one.
    related = next((p for p in msg.walk()
                    if p.get_content_type() == "multipart/related"), None)
    target = related if isinstance(related, EmailMessage) else html_leaf
    for i in used:
        ctype, data = imap[i]
        maintype, _, subtype = ctype.partition("/")
        target.add_related(data, maintype=maintype,
                           subtype=subtype or "octet-stream",
                           cid=f"<mail-inline-{i}>")


def send_mail(
    compose_path: Path,
    orig_dir: Optional[Path] = None,
    sent_dir: Optional[Path] = None,
) -> None:
    """Build a plain-text email from a compose file and deliver via sendmail -t.

    compose_path format (same as the Vim compose buffer written to disk):
        Header: value
        ...

        user reply text
        On <date>, <sender> wrote:      <- attribution line (added by mail#reply)
        > quoted lines …

    Always multipart/alternative. The text/plain part is the composed body
    verbatim (preserves '>' quoting exactly). The text/html part depends on the
    class of the original being replied to:

      - Plain-text original (no orig_dir/body.html): the HTML is an
        ORDER-PRESERVING render of the composed body — runs of quoted lines
        become nested <blockquote>s, user text stays inline. Top/bottom/
        interleaved posting all survive losslessly.

      - HTML original (orig_dir/body.html exists): the original HTML is embedded
        verbatim in a <blockquote>, with the user's reply (the non-'>' lines) on
        top. Inline cid: images are re-attached as multipart/related parts (the
        html alternative becomes multipart/related), so they render in every
        client — unlike data: URIs, which Outlook blocks and Gmail strips. The
        plain part still carries a '>' text quote for plain-only readers.

    Threading is carried by the In-Reply-To / References headers, independent
    of MIME structure.

    Attachments: one 'X-Mail-Attach: <path>' control header per file (stripped,
    never sent) attaches that file, wrapping the message into multipart/mixed.
    Inline images: 'X-Mail-Inline: <id> <path>' turns a '[img <id>]' marker in
    the body into an inline cid image (multipart/related) in the HTML part; the
    plain part keeps the literal '[img <id>]'.

    Forwarding (control headers in the compose block, stripped and never sent):
      - 'X-Forward-Inline': inline forward. orig_dir supplies the original; its
        body is appended to the plain part (unquoted) and embedded in the HTML
        part (class-2 path, with cid images), and its real attachments are
        re-attached. A re-render (not byte-exact) — same as Gmail/Outlook inline.
      - 'X-Forward-Dir: <msg-dir>': forward-as-attachment. Attaches that
        message's raw.eml as a message/rfc822 part — byte-exact and lossless
        (all original headers, body, attachments), wrapping into multipart/mixed.
    """
    import subprocess
    import re as _re

    compose_text = compose_path.read_text(encoding="utf-8")
    header_block, _, body = compose_text.partition("\n\n")
    body = body.rstrip("\n") + "\n"

    msg = EmailMessage(policy=policy.SMTP)
    fwd_dir: Optional[str] = None       # X-Forward-Dir → forward-as-attachment
    fwd_inline = False                  # X-Forward-Inline → inline forward
    attach_files: list[str] = []        # X-Mail-Attach → file attachments
    inline_imgs: dict[str, str] = {}    # X-Mail-Inline → {id: path} for [img id]
    for line in header_block.splitlines():
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        key, val = key.strip(), val.strip()
        if key.lower() == "x-forward-dir":
            fwd_dir = val            # control header, not part of the sent message
        elif key.lower() == "x-forward-inline":
            fwd_inline = True        # control header, not part of the sent message
        elif key.lower() == "x-mail-attach":
            if val:
                attach_files.append(val)  # control header, not part of the message
        elif key.lower() == "x-mail-inline":
            num, _, path = val.partition(" ")  # "<id> <path>"
            if num.strip() and path.strip():
                inline_imgs[num.strip()] = path.strip()
        else:
            msg[key] = val

    # Inline forward: the buffer holds the user's note + a forwarded-header block;
    # the original body is appended here (unquoted, like Gmail) rather than living
    # in the buffer, so it isn't duplicated against the embedded HTML below.
    plain_body = body
    if fwd_inline and orig_dir is not None and (orig_dir / "raw.eml").exists():
        orig_plain = quote_text((orig_dir / "raw.eml").read_bytes())
        if orig_plain:
            plain_body = body.rstrip("\n") + "\n\n" + orig_plain + "\n"
    msg.set_content(plain_body)

    if orig_dir is not None and (orig_dir / "body.html").exists():
        # HTML original → embed it verbatim (lossless), user reply on top.
        user_lines = [l for l in body.splitlines() if not l.startswith(">")]
        while user_lines and not user_lines[-1]:
            user_lines.pop()
        user_html = html_module.escape("\n".join(user_lines)).replace("\n", "<br>\n")
        orig_html = (orig_dir / "body.html").read_text(encoding="utf-8")
        html_body = (
            "<html><body>"
            f"<div>{user_html}</div>"
            '<blockquote style="margin:0 0 0 0.8em;padding-left:0.8em;'
            'border-left:2px solid #ccc">'
            f"{orig_html}"
            "</blockquote>"
            "</body></html>"
        )
        msg.add_alternative(html_body, subtype="html")
        # Re-attach the original's inline (cid) images as multipart/related parts
        # so they render everywhere (Outlook blocks data: URIs; Gmail strips
        # them). Only the cids actually referenced in the HTML are attached, each
        # given a real image/* content-type via magic-byte sniffing.
        raw_file = orig_dir / "raw.eml"
        if raw_file.exists():
            parts = _cid_parts(raw_file.read_bytes())
            refs = _re.findall(
                r'(?:src|background)=["\']cid:([^"\']+)["\']',
                orig_html, flags=_re.IGNORECASE,
            )
            payload = msg.get_payload()
            html_part = payload[-1] if isinstance(payload, list) else payload
            if isinstance(html_part, EmailMessage):
                seen: set[str] = set()
                for ref in refs:
                    cid = ref.strip()
                    if cid in seen or cid not in parts:
                        continue
                    seen.add(cid)
                    ctype, data = parts[cid]
                    ctype = _sniff_image_type(data, ctype)
                    maintype, _, subtype = ctype.partition("/")
                    html_part.add_related(
                        data, maintype=maintype, subtype=subtype or "octet-stream",
                        cid=f"<{cid}>",
                    )
    else:
        # Plain-text original (or new compose) → faithful order-preserving render.
        # For an inline forward of a plain original, plain_body already includes
        # the appended original text, so it renders in the HTML part too.
        msg.add_alternative(_plain_to_html(plain_body), subtype="html")

    # Inline forward: re-attach the original's real (non-inline) attachments so
    # nothing is lost — cid images are already embedded above as related parts;
    # everything else (PDFs, .ics, …) rides along here, wrapping into mixed.
    if fwd_inline and orig_dir is not None and (orig_dir / "raw.eml").exists():
        orig_msg = email.message_from_bytes(
            (orig_dir / "raw.eml").read_bytes(), policy=policy.default
        )
        idx = 0
        for part in orig_msg.iter_attachments():
            if part.get("Content-ID"):
                continue  # inline image — already embedded as a related part
            idx += 1
            content, forced_ext = _attachment_content(part)
            name = _safe_filename(
                part.get_filename() or (f"part_{idx}{forced_ext}" if forced_ext else None),
                idx, part.get_content_type(),
            )
            maintype, _, subtype = part.get_content_type().partition("/")
            if isinstance(content, str):
                content = content.encode("utf-8", "replace")
            msg.add_attachment(content, maintype=maintype,
                               subtype=subtype or "octet-stream", filename=name)

    # Inline images (X-Mail-Inline): replace '[img id]' in the HTML with cid
    # images (multipart/related). Done before user attachments so the related
    # block stays inside the alternative, with attachments wrapping into mixed.
    if inline_imgs:
        import mimetypes
        imap: dict = {}
        for i, path in inline_imgs.items():
            p = Path(path).expanduser()
            if not p.is_file():
                raise RuntimeError(f"inline image not found: {path}")
            data = p.read_bytes()
            ctype = _sniff_image_type(data, mimetypes.guess_type(p.name)[0] or "")
            imap[i] = (ctype, data)
        _embed_inline_images(msg, imap)

    # User attachments (X-Mail-Attach): attach each file, wrapping into mixed.
    # Validate all paths first so a bad one fails before anything is sent.
    if attach_files:
        import mimetypes
        resolved = []
        for raw_path in attach_files:
            p = Path(raw_path).expanduser()
            if not p.is_file():
                raise RuntimeError(f"attachment not found: {raw_path}")
            resolved.append(p)
        for p in resolved:
            ctype, _ = mimetypes.guess_type(p.name)
            maintype, _, subtype = (ctype or "application/octet-stream").partition("/")
            msg.add_attachment(p.read_bytes(), maintype=maintype,
                               subtype=subtype or "octet-stream", filename=p.name)

    # Forward: attach the whole original as a message/rfc822 part (the body above
    # is the user's note + a short forwarded-header block). This carries the
    # original's headers, body, and every attachment intact — lossless. Wraps the
    # message into multipart/mixed.
    if fwd_dir:
        fwd_raw = Path(fwd_dir).expanduser() / "raw.eml"
        if fwd_raw.exists():
            orig_msg = email.message_from_bytes(fwd_raw.read_bytes(), policy=policy.default)
            subj = orig_msg.get("Subject") or "message"
            fname = "".join(c if c.isalnum() or c in " ._-" else "_" for c in str(subj))[:60]
            msg.add_attachment(orig_msg, filename=f"{fname}.eml".strip())

    msg_bytes = msg.as_bytes()
    proc = subprocess.run(["sendmail", "-t"], input=msg_bytes, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode("utf-8", errors="replace").strip())
    if sent_dir is not None:
        sent_dir.mkdir(parents=True, exist_ok=True)
        ingest_one(msg_bytes, sent_dir)


def main(argv: Optional[list[str]] = None) -> None:
    argv = sys.argv[1:] if argv is None else argv
    if not argv:
        sys.exit(USAGE)
    cmd, rest = argv[0], argv[1:]
    if cmd == "migrate" and len(rest) == 2:
        migrate_mbox(Path(rest[0]).expanduser(), Path(rest[1]).expanduser())
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


if __name__ == "__main__":
    main()
