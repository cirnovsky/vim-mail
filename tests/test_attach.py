"""
Test mail_store.py attachment handling: 'X-Mail-Attach: <path>' control headers
(stripped, never sent) attach files, wrapping the message into multipart/mixed.

Run: python3 tests/test_attach.py
"""

import email
import email.policy
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import mail_store  # noqa: E402

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

def send_compose(compose_text):
    captured = {}

    class _R:
        returncode = 0
        stderr = b''

    def fake_run(cmd, input=None, capture_output=False):
        captured['bytes'] = input
        return _R()

    import subprocess
    real_run, real_ingest = subprocess.run, mail_store.ingest_one
    subprocess.run = fake_run
    mail_store.ingest_one = lambda *a, **k: None
    try:
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            f.write(compose_text)
            cp = Path(f.name)
        mail_store.send_mail(cp, None, None)
        cp.unlink()
    finally:
        subprocess.run = real_run
        mail_store.ingest_one = real_ingest
    return email.message_from_bytes(captured['bytes'], policy=email.policy.default)


print('\n=== Case 1: files attached, content-types guessed, header stripped ===')
with tempfile.TemporaryDirectory() as tmp:
    pdf = Path(tmp) / 'report.pdf'
    pdf.write_bytes(b'%PDF-1.4 fake')
    csv = Path(tmp) / 'data.csv'
    csv.write_text('a,b\n1,2\n')
    compose = (f"From: Me <me@example.com>\nTo: x@example.com\nSubject: files\n"
               f"X-Mail-Attach: {pdf}\nX-Mail-Attach: {csv}\n\nSee attached.\n")
    msg = send_compose(compose)
    ok('is multipart/mixed', msg.get_content_type() == 'multipart/mixed', msg.get_content_type())
    ok('X-Mail-Attach control header not leaked', msg.get('X-Mail-Attach') is None)
    ok('body alternative preserved', any(p.get_content_type() == 'text/plain'
       and 'See attached.' in p.get_content() for p in msg.walk()))
    atts = {p.get_filename(): p for p in msg.iter_attachments()}
    ok('both files attached', set(atts) == {'report.pdf', 'data.csv'}, str(set(atts)))
    ok('pdf content-type guessed', atts['report.pdf'].get_content_type() == 'application/pdf')
    ok('csv content-type guessed', atts['data.csv'].get_content_type() == 'text/csv')
    ok('pdf bytes preserved', atts['report.pdf'].get_content() == b'%PDF-1.4 fake')


print('\n=== Case 2: no attachments → stays multipart/alternative ===')
msg = send_compose("From: a@x\nTo: b@y\nSubject: hi\n\nplain note\n")
ok('no attach → alternative', msg.get_content_type() == 'multipart/alternative',
   msg.get_content_type())


print('\n=== Case 3: missing attachment path raises (pre-send) ===')
raised = False
try:
    send_compose("From: a@x\nTo: b@y\nSubject: x\nX-Mail-Attach: /no/such/file.pdf\n\nbody\n")
except RuntimeError as e:
    raised = 'not found' in str(e)
ok('missing file raises before send', raised)


print('\n=== Case 4: octet-stream fallback for unknown extension ===')
with tempfile.TemporaryDirectory() as tmp:
    blob = Path(tmp) / 'thing.weirdext'
    blob.write_bytes(b'\x00\x01\x02')
    msg = send_compose(f"From: a@x\nTo: b@y\nSubject: x\nX-Mail-Attach: {blob}\n\nb\n")
    att = list(msg.iter_attachments())[0]
    ok('unknown ext → application/octet-stream',
       att.get_content_type() == 'application/octet-stream', att.get_content_type())


print(f'\n{"="*40}')
print(f'Results: {PASS} passed, {FAIL} failed')
if FAIL:
    sys.exit(1)
