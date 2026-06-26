"""
Test mail_store.py ingestion on a REAL complex message
(tests/fixtures/embrace-the-chaos/raw.eml — 2 tables, an inline cid image, an
external image, a businesscard link, a .ics attachment): does it download
attachments, footnote links, and parse the body correctly?

Run: python3 tests/test_ingest.py
"""

import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import mail_store        # noqa: E402
import _fixtures         # noqa: E402

CASE = 'embrace-the-chaos'
RAW = _fixtures.raw(CASE)
PNG_NAME = '3A0EC103@F1D05308.F10D3E6A00000000.png'
ICS_NAME = 'part_2.ics'   # the .ics part carries no filename -> part_2.ics
MSGID = '<embrace-the-chaos@example.com>'

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


print('\n=== Ingest the real complex message ===')
with tempfile.TemporaryDirectory() as tmp:
    box = Path(tmp) / 'inbox'
    box.mkdir()
    msg_dir = mail_store.ingest_one(RAW, box)
    ok('ingest created a message dir', msg_dir is not None and msg_dir.is_dir())
    assert msg_dir is not None

    # --- attachments downloaded ---
    att = msg_dir / 'attachments'
    files = sorted(p.name for p in att.iterdir()) if att.is_dir() else []
    ok('attachments/ exists', att.is_dir())
    ok('inline image saved', PNG_NAME in files, str(files))
    ok('.ics calendar saved', ICS_NAME in files, str(files))
    ok('image bytes saved (png signature)',
       att.is_dir() and (att / PNG_NAME).read_bytes().startswith(b'\x89PNG'))
    ok('ics is a real calendar',
       att.is_dir() and 'BEGIN:VCALENDAR' in (att / ICS_NAME).read_text(errors='replace'))

    # --- body.html written verbatim ---
    html = (msg_dir / 'body.html')
    ok('body.html written', html.is_file())
    ok('body.html keeps both tables', html.read_text().count('<table') == 2)
    ok('body.html keeps cid ref', 'cid:' + PNG_NAME in html.read_text())

    # --- body.txt parsed from html ---
    body = (msg_dir / 'body.txt').read_text()
    ok('table cells flattened into text', '1314' in body and '456' in body)
    ok('inline image -> [img N] marker', '[img 1]' in body, repr(body[:200]))
    ok('businesscard link -> Links footer',
       'Links:' in body and 'wx.mail.qq.com' in body)
    ok('Attachments footer lists both files',
       'Attachments:' in body and PNG_NAME in body and ICS_NAME in body)

    # --- meta parsed ---
    meta = (msg_dir / 'meta').read_text()
    ok('meta has subject', 'Subject: EMBRACE THE CHAOS' in meta)
    ok('meta has Message-ID', MSGID in meta)


print('\n=== quote_text on the real message is clean ===')
q = mail_store.quote_text(RAW)
ok('quote uses sender text/plain', q.splitlines()[:3] == ['1314', '5', '456'], repr(q[:40]))
ok('quote has no [img]/Links/Attachments noise',
   '[img' not in q and 'Links:' not in q and 'Attachments:' not in q)
ok('quote keeps signature', '12345678901' in q)


print(f'\n{"="*40}')
print(f'Results: {PASS} passed, {FAIL} failed')
if FAIL:
    sys.exit(1)
