"""Reply quoting and plain-text → HTML rendering (order-preserving)."""

import email
import html as html_module
from email import policy

from .htmltext import _build_cid_map, html_to_text, text_cid_to_markers


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
        text = html_module.unescape(plain.get_content()).replace("\xa0", " ")
        # Render any [cid:...] inline-image tokens as [img N] — same markers the
        # HTML path produces, so a quote reads consistently either way.
        text, _ = text_cid_to_markers(text, _build_cid_map(msg))
        return text.rstrip("\n")
    html = msg.get_body(preferencelist=("html",))
    if html is not None and html.get_content_type() == "text/html":
        text, _ = html_to_text(
            html.get_content(), _build_cid_map(msg), link_footnotes=False
        )
        return text
    return ""
