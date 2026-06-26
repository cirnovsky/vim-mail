"""
End-to-end reply + forward test on the REAL complex message
(tests/fixtures/embrace-the-chaos/raw.eml): CLI ingest -> a real headless vim
opens it and replies (top-post) / forwards -> CLI send (sendmail faked) -> CLI
ingest into the sent box -> assert each sent message meets requirements.

Exercises the whole pipeline together: mail_store ingestion, mail#reply quote
sourcing, mail#forward, mail#send, the class-2 (HTML original) MIME build, and
the message/rfc822 forward.

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

    # 5. Forward the same message via vim; verify the sent box gets a complete
    #    message/rfc822 forward (covers mail#send emitting X-Forward-Dir).
    fstatus = STORE / 'fstatus'
    fdriver = STORE / 'fdriver.vim'
    fdriver.write_text(f"""
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
  call mail#forward()
  call setline(line('.'), 'Forwarding this.')
  call mail#send()
  call writefile(['OK'], '{fstatus}')
catch
  call writefile(['ERR: ' . v:exception . ' @ ' . v:throwpoint], '{fstatus}')
endtry
qall!
""")
    fvr = subprocess.run([VIM, '-u', 'NONE', '-N', '-es', '-S', str(fdriver)],
                         env=env, capture_output=True)
    fst = fstatus.read_text().strip() if fstatus.exists() else '(no status)'
    ok('vim forward+send ran cleanly', fst == 'OK',
       fst + ' | ' + fvr.stderr.decode('utf-8', 'replace'))

    # the forward is the sent message that is multipart/mixed with a rfc822 part
    fwd = None
    for path in sorted((STORE / 'sent').glob('*/raw.eml')):
        mm = email.message_from_bytes(path.read_bytes(), policy=email.policy.default)
        if mm.get_content_type() == 'multipart/mixed' and \
           any(p.get_content_type() == 'message/rfc822' for p in mm.walk()):
            fwd = mm
            break
    ok('forward landed in sent box as multipart/mixed', fwd is not None)
    if fwd is not None:
        ok('forward subject is Fwd:', (fwd.get('Subject') or '').startswith('Fwd:'),
           repr(fwd.get('Subject')))
        ok('forward is a new thread', fwd.get('In-Reply-To') is None)
        ok('X-Forward-Dir not leaked', fwd.get('X-Forward-Dir') is None)
        inner = [p for p in fwd.walk() if p.get_content_type() == 'message/rfc822'][0].get_content()
        ok('forwarded original subject preserved', inner.get('Subject') == 'EMBRACE THE CHAOS')
        names = {q.get_filename() for q in inner.walk() if q.get_filename()}
        cts = [q.get_content_type() for q in inner.walk()]
        ok('forwarded original keeps its image attachment',
           '3A0EC103@F1D05308.F10D3E6A00000000.png' in names, str(names))
        ok('forwarded original keeps its calendar (.ics)',
           'text/calendar' in cts, str(cts))
finally:
    shutil.rmtree(STORE, ignore_errors=True)

print(f'\n{"="*40}')
print(f'Results: {PASS} passed, {FAIL} failed')
if FAIL:
    sys.exit(1)
