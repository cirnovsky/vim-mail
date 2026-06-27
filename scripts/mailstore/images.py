"""Inline images: cid parts, type sniffing, cid→data URIs, [img] embedding."""

import email
from email import policy
from email.message import EmailMessage


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
