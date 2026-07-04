"""
End-to-end reply + forward test on the REAL complex message
(tests/fixtures/embrace-the-chaos/raw.eml): CLI ingest -> a real headless vim
opens it and replies (top-post) / forwards -> CLI send (msmtp faked) -> CLI
ingest into the sent box -> assert each sent message meets requirements.

Exercises the whole pipeline together: mailstore ingestion, mail#compose#reply quote
sourcing, mail#compose#forward (inline + as-attachment), mail#compose#compose + :Attach, and
mail#send#send (class-2 MIME, message/rfc822 forward, X-Mail-Attach attachments).

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


VIM = shutil.which('vim') or ''
if not VIM:
    print('  SKIP  vim not found on PATH')
    sys.exit(0)

PY = sys.executable
STORE = Path(tempfile.mkdtemp(prefix='mailtest_'))
try:
    inbox = STORE / 'inbox'
    inbox.mkdir(parents=True)

    # 1. Ingest the real message via the real CLI.
    r = subprocess.run([PY, str(REPO / 'scripts' / 'mail_store.py'), 'ingest-stdin', str(inbox)],
                       input=RAW, capture_output=True)
    ok('CLI ingest succeeded', r.returncode == 0, r.stderr.decode('utf-8', 'replace'))
    msg_dirs = [d for d in inbox.iterdir() if d.is_dir()]
    ok('one message ingested', len(msg_dirs) == 1, str(msg_dirs))

    # 2. Fake msmtp on PATH (send.py's default transport): capture stdin, exit 0.
    bindir = STORE / 'bin'
    bindir.mkdir()
    capture = STORE / 'sent_bytes.eml'
    fake = bindir / 'msmtp'
    fake.write_text('#!/bin/sh\ncat > "$SENDMAIL_CAPTURE"\n')
    fake.chmod(0o755)

    # 3. Driver: open inbox, reply (top-post), insert reply text, send.
    status = STORE / 'status'
    driver = STORE / 'driver.vim'
    driver.write_text(f"""
set rtp+={REPO}
let g:mail_python = '{PY}'
let g:mail_store_py = '{REPO}/scripts/mail_store.py'
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
let g:mail_root = '{STORE}'
let g:mail_from = 'Me <me@example.com>'
try
  call mail#index#open('inbox')
  call cursor(1, 1)
  call mail#compose#reply()
  call setline(line('.'), 'Top posted reply.')
  call mail#send#send()
  call mail#send#_await()
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

    # 5. Forward the message via vim, both ways, and verify the sent box.
    def run_forward(call, tag):
        st = STORE / f'{tag}_status'
        drv = STORE / f'{tag}_driver.vim'
        drv.write_text(f"""
set rtp+={REPO}
let g:mail_python = '{PY}'
let g:mail_store_py = '{REPO}/scripts/mail_store.py'
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
let g:mail_root = '{STORE}'
let g:mail_from = 'Me <me@example.com>'
try
  call mail#index#open('inbox')
  call cursor(1, 1)
  call {call}
  call setline(line('.'), 'Forwarding this.')
  call mail#send#send()
  call mail#send#_await()
  call writefile(['OK'], '{st}')
catch
  call writefile(['ERR: ' . v:exception . ' @ ' . v:throwpoint], '{st}')
endtry
qall!
""")
        r = subprocess.run([VIM, '-u', 'NONE', '-N', '-es', '-S', str(drv)],
                           env=env, capture_output=True)
        s = st.read_text().strip() if st.exists() else '(no status)'
        ok(f'vim {tag} forward+send ran cleanly', s == 'OK',
           s + ' | ' + r.stderr.decode('utf-8', 'replace'))

    run_forward("mail#compose#forward()", 'inline')
    run_forward("mail#compose#forward_attach()", 'attach')

    # classify the sent messages: reply = alternative; inline forward = mixed,
    # no rfc822; attach forward = mixed with a rfc822 part.
    sent_all = []
    for path in sorted((STORE / 'sent').glob('*/raw.eml')):
        sent_all.append(email.message_from_bytes(path.read_bytes(), policy=email.policy.default))
    inline_fwd = next((mm for mm in sent_all
                       if mm.get_content_type() == 'multipart/mixed'
                       and not any(p.get_content_type() == 'message/rfc822' for p in mm.walk())), None)
    attach_fwd = next((mm for mm in sent_all
                       if any(p.get_content_type() == 'message/rfc822' for p in mm.walk())), None)

    ok('inline forward landed in sent box', inline_fwd is not None)
    if inline_fwd is not None:
        ok('inline: Fwd: subject, new thread',
           (inline_fwd.get('Subject') or '').startswith('Fwd:')
           and inline_fwd.get('In-Reply-To') is None)
        ok('inline: X-Forward-Inline not leaked', inline_fwd.get('X-Forward-Inline') is None)
        ihtml = [p.get_content() for p in inline_fwd.walk() if p.get_content_type() == 'text/html']
        ok('inline: embeds the original tables', ihtml and ihtml[0].count('<table') == 2)
        ok('inline: re-attaches the original .ics',
           any(p.get_content_type() == 'text/calendar' for p in inline_fwd.walk()))

    ok('attach forward landed in sent box', attach_fwd is not None)
    if attach_fwd is not None:
        inner = [p for p in attach_fwd.walk()
                 if p.get_content_type() == 'message/rfc822'][0].get_content()
        ok('attach: forwarded original subject preserved',
           inner.get('Subject') == 'EMBRACE THE CHAOS')
        ok('attach: forwarded original keeps its attachments',
           '3A0EC103@F1D05308.F10D3E6A00000000.png' in
           {q.get_filename() for q in inner.walk() if q.get_filename()})

    # 6. Compose a NEW message via vim, :Attach a file, send — covers mail#send#send
    #    emitting X-Mail-Attach and the multipart/mixed build end to end.
    probe = STORE / 'attach_probe.bin'
    probe.write_bytes(b'PROBE-BYTES-123')
    cstatus = STORE / 'c_status'
    cdriver = STORE / 'c_driver.vim'
    cdriver.write_text(f"""
set rtp+={REPO}
let g:mail_python = '{PY}'
let g:mail_store_py = '{REPO}/scripts/mail_store.py'
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
let g:mail_root = '{STORE}'
let g:mail_from = 'Me <me@example.com>'
try
  call mail#compose#compose()
  call setline(1, 'To: someone@example.com')
  call setline(2, 'Subject: with attachment')
  call mail#attach#attach('{probe}')
  call mail#send#send()
  call mail#send#_await()
  call writefile(['OK'], '{cstatus}')
catch
  call writefile(['ERR: ' . v:exception . ' @ ' . v:throwpoint], '{cstatus}')
endtry
qall!
""")
    cvr = subprocess.run([VIM, '-u', 'NONE', '-N', '-es', '-S', str(cdriver)],
                         env=env, capture_output=True)
    cst = cstatus.read_text().strip() if cstatus.exists() else '(no status)'
    ok('vim compose+attach+send ran cleanly', cst == 'OK',
       cst + ' | ' + cvr.stderr.decode('utf-8', 'replace'))

    attached = None
    for path in sorted((STORE / 'sent').glob('*/raw.eml')):
        mm = email.message_from_bytes(path.read_bytes(), policy=email.policy.default)
        if any(p.get_filename() == 'attach_probe.bin' for p in mm.walk()):
            attached = mm
            break
    ok('attachment landed in sent box', attached is not None)
    if attached is not None:
        ok('compose+attach is multipart/mixed',
           attached.get_content_type() == 'multipart/mixed', attached.get_content_type())
        ok('X-Mail-Attach control header not leaked', attached.get('X-Mail-Attach') is None)
        part = [p for p in attached.walk() if p.get_filename() == 'attach_probe.bin'][0]
        ok('attached bytes preserved', part.get_content() == b'PROBE-BYTES-123')
        ok('Attachments: footer not sent as literal body text',
           not any(p.get_content_type() == 'text/plain' and 'Attachments:' in p.get_content()
                   for p in attached.walk()))
finally:
    shutil.rmtree(STORE, ignore_errors=True)

print(f'\n{"="*40}')
print(f'Results: {PASS} passed, {FAIL} failed')
if FAIL:
    sys.exit(1)
