"""HTML → plain-text extraction, and the Content-ID → filename map."""

import re
from email.message import EmailMessage
from html.parser import HTMLParser


class _CidNumberer:
    """Assigns stable '[<kind> N]' markers to Content-IDs in first-seen order.

    Shared by the HTML extractor and the plain-text cid pass so an inline part
    gets the same [img N] number no matter which body part referenced it —
    `<img src="cid:x">` in the HTML and `[cid:x]` in the text/plain alternative
    both resolve to the same marker."""

    def __init__(self, cid_map: dict[str, str] | None = None) -> None:
        self._cid_map: dict[str, str] = cid_map or {}
        self.refs: list[str] = []          # filenames, first-appearance order
        self._seen: set[str] = set()

    def marker(self, cid: str, kind: str = "img", alt: str = "") -> str:
        fname = self._cid_map.get(cid, cid)
        if fname not in self._seen:
            self._seen.add(fname)
            self.refs.append(fname)
        n = self.refs.index(fname) + 1
        return f"{alt} [{kind} {n}]" if alt else f"[{kind} {n}]"


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
        self._cid = _CidNumberer(cid_map)

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
                alt = next((v for k, v in attrs if k == "alt" and v), "")
                kind = "img" if tag == "img" else tag
                self.chunks.append(self._cid.marker(src[4:].strip(), kind=kind, alt=alt))
        if tag == "object":
            data = next((v for k, v in attrs if k == "data" and v), "")
            if data.lower().startswith("cid:"):
                self.chunks.append(self._cid.marker(data[4:].strip(), kind="object"))

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


def text_cid_to_markers(text: str,
                        cid_map: dict[str, str] | None = None) -> tuple[str, list[str]]:
    """Replace '[cid:ID]' placeholder tokens in a plain-text body with the same
    '[img N]' markers `html_to_text` assigns — via the shared `_CidNumberer`, so
    an inline part numbers identically whether it was referenced from the HTML
    or the text/plain alternative. Returns (text, cid_filenames_in_order)."""
    num = _CidNumberer(cid_map)
    out = re.sub(r"\[cid:([^\]]+)\]",
                 lambda m: num.marker(m.group(1).strip()), text)
    return out, num.refs


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
    return "\n".join(result), extractor._cid.refs
