"""
Content-store storage layer: canonical bytes live once in <root>/.store/<id>/,
and each mailbox membership is a *symlink* <mailbox>/<id> -> ../.store/<id>.

A message is ONE object; mailboxes are labels. Filing the same message into a
second mailbox just adds a second symlink to the same canonical dir (no byte
duplication); read-state is shared through the one .store/<id>/.read.

These tests pin the on-disk contract ingest_one() must produce, feeding it real
corpus .eml files. The Vim side (move = relink, delete = unlink, refcount via
readdir) builds on this.

Run: python3 tests/test_store.py
"""

import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'scripts'))
sys.path.insert(0, str(HERE))
from mailstore import ingest  # noqa: E402
import _fixtures  # noqa: E402

PASS = 0
FAIL = 0


def ok(name, cond, detail=''):
    global PASS, FAIL
    if cond:
        print(f'  PASS  {name}')
        PASS += 1
    else:
        print(f'  FAIL  {name}' + (f': {detail}' if detail else ''))
        FAIL += 1


print('\n=== ingest writes canonical bytes to .store and a symlink to the mailbox ===')
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    inbox = root / 'inbox'
    inbox.mkdir()

    link = ingest.ingest_one(_fixtures.eml('plain'), inbox)
    ok('ingest returned the mailbox membership', link is not None)
    assert link is not None
    mid = link.name

    store = root / '.store'
    canon = store / mid
    ok('store dir is hidden (.store)', store.name == '.store')
    ok('canonical dir is a real directory (not a symlink)',
       canon.is_dir() and not canon.is_symlink())
    ok('canonical raw.eml holds the real bytes',
       (canon / 'raw.eml').is_file()
       and b'This is a plain text message' in (canon / 'raw.eml').read_bytes())
    ok('canonical meta + body.txt present',
       (canon / 'meta').is_file() and (canon / 'body.txt').is_file())

    ok('mailbox entry is a symlink', link.is_symlink())
    ok('symlink target is relative (../.store/<id>)',
       os.readlink(link) == os.path.join('..', '.store', mid), os.readlink(link))
    ok('symlink resolves into the store', link.resolve() == canon.resolve())
    ok('reads through the symlink work',
       'Subject: Plain hello' in (link / 'meta').read_text())
    ok('mailbox dir holds exactly one entry', len(list(inbox.iterdir())) == 1)


print('\n=== same message, second mailbox = second link, bytes not duplicated ===')
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    inbox = root / 'inbox'
    archive = root / 'archive'
    inbox.mkdir()
    archive.mkdir()
    raw = _fixtures.eml('html')

    a = ingest.ingest_one(raw, inbox)
    b = ingest.ingest_one(raw, archive)
    ok('filing a known message into a new mailbox returns a (new) membership', b is not None)
    assert a is not None and b is not None
    ok('both links share one id', a.name == b.name)

    store = root / '.store'
    ok('store holds exactly ONE canonical copy',
       len([p for p in store.iterdir()]) == 1)
    ok('both mailbox entries are symlinks', a.is_symlink() and b.is_symlink())
    ok('both resolve to the same canonical dir', a.resolve() == b.resolve())


print('\n=== same message, same mailbox twice = no-op (None) ===')
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    inbox = root / 'inbox'
    inbox.mkdir()
    raw = _fixtures.eml('multipart')

    first = ingest.ingest_one(raw, inbox)
    second = ingest.ingest_one(raw, inbox)
    ok('first ingest creates the link', first is not None)
    ok('second ingest into same mailbox is a no-op', second is None)
    ok('still exactly one symlink in the mailbox', len(list(inbox.iterdir())) == 1)


print('\n=== read-state is shared through the one .store/<id>/.read ===')
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    inbox = root / 'inbox'
    archive = root / 'archive'
    inbox.mkdir()
    archive.mkdir()
    raw = _fixtures.eml('attachment')
    a = ingest.ingest_one(raw, inbox)
    b = ingest.ingest_one(raw, archive)
    assert a is not None and b is not None

    # Mark read via one mailbox's link; it must be visible through the other.
    (a / '.read').write_text('')
    ok('.read written via inbox link is visible via archive link',
       (b / '.read').exists())
    ok('.read lives once in the canonical dir',
       (root / '.store' / a.name / '.read').exists())


print(f'\n{"="*40}')
print(f'Results: {PASS} passed, {FAIL} failed')
if FAIL:
    sys.exit(1)
