"""
End-to-end reply test on the REAL complex message
(tests/fixtures/embrace-the-chaos/raw.eml): CLI ingest -> a real headless vim
opens it and replies (top-post) -> CLI send (sendmail faked) -> CLI ingest into
the sent box -> assert the sent message meets requirements.

Exercises the whole pipeline together: mail_store ingestion, mail#reply quote
sourcing, mail#send, and the class-2 (HTML original) MIME build.

Run: python3 tests/test_reply_integration.py   (needs vim on PATH)
"""

import os
import shutil
import subprocess
import sys
import tempfile
import email
import email.policy
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(HERE))
import _fixtures         # noqa: E402

CASE = 'embrace-the-chaos'
RAW = _fixtures.raw(CASE)
MSGID = '<embrace-the-chaos@example.com>'
CID = 'cid:3A0EC103@F1D05308.F10D3E6A00000000.png'

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


VIM = shutil.which('vim')
if VIM is None:
    print('  SKIP  vim not found on PATH')
    sys.exit(0)

PY = sys.executable
STORE = Path(tempfile.mkdtemp(prefix='mailtest_'))
try:
    inbox = STORE / 'inbox'
    inbox.mkdir(parents=True)

    # 1. Ingest the real message via the real CLI.
    r = subprocess.run([PY, str(REPO / 'mail_store.py'), 'ingest-stdin', str(inbox)],
                       input=RAW, capture_output=True)
    ok('CLI ingest succeeded', r.returncode == 0, r.stderr.decode('utf-8', 'replace'))
    msg_dirs = [d for d in inbox.iterdir() if d.is_dir()]
    ok('one message ingested', len(msg_dirs) == 1, str(msg_dirs))

    # 2. Fake sendmail on PATH: capture stdin, exit 0.
    bindir = STORE / 'bin'
    bindir.mkdir()
    capture = STORE / 'sent_bytes.eml'
    fake = bindir / 'sendmail'
    fake.write_text('#!/bin/sh\ncat > "$SENDMAIL_CAPTURE"\n')
    fake.chmod(0o755)

    # 3. Driver: open inbox, reply (top-post), insert reply text, send.
    status = STORE / 'status'
    driver = STORE / 'driver.vim'
    driver.write_text(f"""
set rtp+={REPO}
let g:mail_python = '{PY}'
let g:mail_store_py = '{REPO}/mail_store.py'
runtime plugin/mail.vim
runtime autoload/mail.vim
let g:mail_root = '{STORE}'
let g:mail_from = 'Me <me@example.com>'
try
  call mail#open('inbox')
  call cursor(1, 1)
  call mail#reply()
  call setline(line('.'), 'Top posted reply.')
  call mail#send()
  call writefile(['OK'], '{status}')
catch
  call writefile(['ERR: ' . v:exception . ' @ ' . v:throwpoint], '{status}')
endtry
qall!
""")

    env = dict(os.environ)
    env['PATH'] = f"{bindir}{os.pathsep}{env.get('PATH', '')}"
    env['SENDMAIL_CAPTURE'] = str(capture)
    vr = subprocess.run([VIM, '-u', 'NONE', '-N', '-es', '-S', str(driver)],
                        env=env, capture_output=True)

    st = status.read_text().strip() if status.exists() else '(no status written)'
    ok('vim reply+send ran cleanly', st == 'OK', st + ' | ' + vr.stderr.decode('utf-8', 'replace'))

    # 4. Inspect the message in the SENT box.
    sent = STORE / 'sent'
    sent_msgs = sorted(sent.glob('*/raw.eml')) if sent.is_dir() else []
    ok('a message landed in the sent box', len(sent_msgs) == 1, str(sent_msgs))

    if sent_msgs:
        m = email.message_from_bytes(sent_msgs[0].read_bytes(), policy=email.policy.default)
        parts = {}
        for p in m.walk():
            ct = p.get_content_type()
            if not ct.startswith('multipart'):
                parts[ct] = p.get_content()

        ok('sent is multipart/alternative', m.get_content_type() == 'multipart/alternative',
           m.get_content_type())
        ok('threading: In-Reply-To = original',
           (m.get('In-Reply-To') or '').strip() == MSGID, repr(m.get('In-Reply-To')))

        plain = parts.get('text/plain', '')
        ok('plain: has the typed reply', 'Top posted reply.' in plain)
        ok('plain: has clean > quote (table cell)', '> 1314' in plain)
        ok('plain: quote is clean (no [img]/Links footers)',
           '[img' not in plain and 'Links:' not in plain, repr(plain[-200:]))

        html = parts.get('text/html', '')
        ok('html: reply on top, above the quote',
           0 <= html.find('Top posted reply.') < html.find('<blockquote'))
        ok('html: embeds both original tables', html.count('<table') == 2)
        ok('html: keeps cid: ref (not data:)', CID in html and 'data:' not in html)
        ok('html: external avatar URL preserved', 'thirdqq.qlogo.cn' in html)
        ok('html: businesscard link preserved', 'readmail_businesscard' in html)

        # the inline image is re-attached as a multipart/related cid part
        cidparts = [p for p in m.walk()
                    if '3A0EC103' in (p.get('Content-ID') or '')]
        ok('inline image re-attached by cid', len(cidparts) == 1, str(len(cidparts)))
        ok('related structure present',
           any(p.get_content_type() == 'multipart/related' for p in m.walk()))
        if cidparts:
            ok('re-attached image sniffed to image/*',
               cidparts[0].get_content_type().startswith('image/'),
               cidparts[0].get_content_type())
finally:
    shutil.rmtree(STORE, ignore_errors=True)

print(f'\n{"="*40}')
print(f'Results: {PASS} passed, {FAIL} failed')
if FAIL:
    sys.exit(1)
