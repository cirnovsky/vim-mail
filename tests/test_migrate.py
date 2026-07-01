"""
migrate_store: convert an existing flat one-folder-per-message store
(<mailbox>/<id>/ real dirs) into the content-store layout (.store/<id>/ canonical
bytes + <mailbox>/<id> symlinks). Non-destructive (dirs are moved into .store,
not copied then deleted from under you) and resumable (already-symlinked entries
are skipped). Multi-copy legacy mail (same id as a real dir in two mailboxes)
folds into ONE canon with two links, unioning read-state.

Run: python3 tests/test_migrate.py
"""

import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'scripts'))
from mailstore import ingest  # noqa: E402

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


def mkreal(root, mailbox, mid, read=False, body='body'):
    """A legacy real message dir <root>/<mailbox>/<id>/."""
    d = Path(root) / mailbox / mid
    d.mkdir(parents=True)
    (d / 'meta').write_text(f'Subject: {mid}\nMessage-ID: <{mid}>\n')
    (d / 'raw.eml').write_text(f'raw {mid} {body}')
    if read:
        (d / '.read').write_text('')
    return d


print('\n=== a single legacy dir migrates into the store + a symlink ===')
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    mkreal(root, 'inbox', '20260101T000000Z_aaaaaaaa')

    counts = ingest.migrate_store(root)
    canon = root / '.store' / '20260101T000000Z_aaaaaaaa'
    link = root / 'inbox' / '20260101T000000Z_aaaaaaaa'
    ok('reported one migration', counts['migrated'] == 1, str(counts))
    ok('canonical dir holds the real bytes',
       canon.is_dir() and not canon.is_symlink()
       and 'raw 20260101T000000Z_aaaaaaaa' in (canon / 'raw.eml').read_text())
    ok('mailbox entry is now a symlink', link.is_symlink())
    ok('symlink is relative into .store',
       os.readlink(link) == os.path.join('..', '.store', '20260101T000000Z_aaaaaaaa'))
    ok('symlink resolves to the canon', link.resolve() == canon.resolve())


print('\n=== the same id in two mailboxes dedupes to one canon, two links ===')
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    mkreal(root, 'inbox', '20260101T000000Z_bbbbbbbb', read=False)
    mkreal(root, 'archive', '20260101T000000Z_bbbbbbbb', read=True)  # dup, and read

    counts = ingest.migrate_store(root)
    store = root / '.store'
    ok('exactly one canonical copy after dedup',
       len(list(store.iterdir())) == 1, str([p.name for p in store.iterdir()]))
    inbox_link = root / 'inbox' / '20260101T000000Z_bbbbbbbb'
    arch_link = root / 'archive' / '20260101T000000Z_bbbbbbbb'
    ok('both mailbox entries are symlinks',
       inbox_link.is_symlink() and arch_link.is_symlink())
    ok('both resolve to the same canon', inbox_link.resolve() == arch_link.resolve())
    ok('reported one dedup', counts['deduped'] == 1, str(counts))
    # read-state union: one copy was read -> the shared canon is read
    ok('read-state unioned onto the canon',
       (store / '20260101T000000Z_bbbbbbbb' / '.read').exists())


print('\n=== migration is idempotent / resumable ===')
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    mkreal(root, 'inbox', '20260101T000000Z_cccccccc')

    first = ingest.migrate_store(root)
    second = ingest.migrate_store(root)  # re-run
    link = root / 'inbox' / '20260101T000000Z_cccccccc'
    ok('first run migrates', first['migrated'] == 1)
    ok('second run migrates nothing (all symlinks now)',
       second['migrated'] == 0 and second['deduped'] == 0, str(second))
    ok('second run skips the already-linked entry', second['skipped'] == 1, str(second))
    ok('the link still resolves after a re-run',
       link.is_symlink() and (link / 'raw.eml').exists())


print('\n=== non-dir / dotfile entries at mailbox level are ignored ===')
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    mkreal(root, 'inbox', '20260101T000000Z_dddddddd')
    (root / 'inbox' / '.DS_Store').write_text('junk')   # stray dotfile
    (root / 'inbox' / 'notes.txt').write_text('loose')  # stray file

    counts = ingest.migrate_store(root)
    ok('only the real message dir migrated', counts['migrated'] == 1, str(counts))
    ok('stray file left in place', (root / 'inbox' / 'notes.txt').is_file())
    ok('stray dotfile left in place', (root / 'inbox' / '.DS_Store').is_file())


print(f'\n{"="*40}')
print(f'Results: {PASS} passed, {FAIL} failed')
if FAIL:
    sys.exit(1)
