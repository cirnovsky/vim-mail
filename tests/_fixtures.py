"""
Test fixtures live one directory per case under tests/fixtures/<case>/, so a
case can carry static assets (a real raw.eml, expected outputs, etc.). Helper
to load a case's raw message bytes.

Not a test (filename doesn't match test_*), so run.sh won't execute it.
"""

import sys
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent / "fixtures"
MAIL = FIXTURES / "mail"

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from mailstore import ingest  # noqa: E402


def case_dir(case: str) -> Path:
    return FIXTURES / case


def raw(case: str) -> bytes:
    return (FIXTURES / case / "raw.eml").read_bytes()


def eml(name: str) -> bytes:
    """Bytes of a corpus fixture tests/fixtures/mail/<name>.eml."""
    return (MAIL / f"{name}.eml").read_bytes()


def build_store(root, spec: list) -> dict:
    """Build a content-store under <root> from corpus .eml files, via the REAL
    ingest. spec = list of {"name": <fixture>, "in": [<mailbox>...], "read": bool}.
    A fixture ingested into several mailboxes is deduped to one canon + links.
    Returns {name -> id}."""
    root = Path(root)
    ids = {}
    for item in spec:
        mid = None
        for mailbox in item["in"]:
            link = ingest.ingest_one(eml(item["name"]), root / mailbox)
            mid = link.name if link is not None else mid
        if mid is None:  # already linked everywhere requested; recover the id
            mid = next(iter(sorted(p.name for p in (root / item["in"][0]).iterdir())))
        if item.get("read"):
            (root / ".store" / mid / ".read").write_text("")
        ids[item["name"]] = mid
    return ids
