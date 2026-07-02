"""Build a MIME message from a compose file and deliver via sendmail -t."""

import email
import html as html_module
from email import policy
from email.message import EmailMessage
from email.utils import make_msgid
from pathlib import Path
from typing import Optional

from . import ingest
from .ingest import _attachment_content, _safe_filename
from .images import _cid_parts, _embed_inline_images, _sniff_image_type
from .quote import _plain_to_html, quote_text


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

    # Generated here (not left to Postfix) so the locally-ingested sent copy
    # carries the same Message-ID that goes out on the wire — otherwise a
    # reply's In-Reply-To has nothing in the local store to thread against.
    msg["Message-ID"] = make_msgid()

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

    # Transport is a sendmail-compatible command, taken from $MAIL_SENDMAIL so
    # the caller can route per account (e.g. 'msmtp -a gmail -t'). Defaults to
    # 'sendmail -t' — unchanged single-account behaviour.
    import os
    import shlex
    transport = shlex.split(os.environ.get("MAIL_SENDMAIL", "sendmail -t"))
    msg_bytes = msg.as_bytes()
    proc = subprocess.run(transport, input=msg_bytes, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode("utf-8", errors="replace").strip())
    if sent_dir is not None:
        sent_dir.mkdir(parents=True, exist_ok=True)
        ingest.ingest_one(msg_bytes, sent_dir)
