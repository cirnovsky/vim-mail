"""
Test suite for mailstore.send (compose/reply).

Outgoing mail is multipart/alternative: a verbatim text/plain part plus a
text/html part that mirrors the plain body IN ORDER (quoted runs -> nested
<blockquote>, user text inline), so interleaving survives and clients that
don't style raw '>' (e.g. QQ Mail) still render a quote bar. Threading rides
on the In-Reply-To / References headers. These tests call the REAL send_mail
(with sendmail stubbed) — not a reimplementation — so they catch drift
between the test and the shipping code.

Two classes of original:
  - plain-text (no body.html): HTML part is an order-preserving render of the
    composed body (top/bottom/interleave all survive).
  - HTML (body.html exists): original HTML embedded verbatim in a blockquote
    (cid inlined), user reply on top — top-posting, lossless quote.

Cases:
  1. Reply to plain-text original (class 1) — plain verbatim + html blockquote
  2. Reply to HTML original (class 2) — original markup embedded verbatim
  3. Multi-round reply (nested >> quoting) — plain verbatim + nested blockquote
  4. References / In-Reply-To chain preserved (threading)
  5. [cid:...] line filtering (Vim-side body.txt logic)
  6. New compose (no original) — multipart, html has no blockquote
  7. Interleaved '>' lines keep order in BOTH plain and html (class 1)
  8. quote_text — clean quote source (sender text/plain, footnote-free html)
  9. class 2 re-attaches cid images as multipart/related parts
  10. forward-as-attachment (F): original as message/rfc822 (byte-exact)
  11. inline forward (f): embed original + re-attach its files (re-render)

Run: python3 tests/test_reply.py
"""

import base64
import email
import email.policy
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'scripts'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from mailstore import ingest, quote, send  # noqa: E402
import _fixtures   # noqa: E402

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

def make_orig(tmpdir, subject, plain_body, html_body=None, msg_id='<orig@test>'):
    d = Path(tmpdir) / '20260101T000000Z_aabbccdd'
    d.mkdir()
    meta_lines = [
        'From: Alice <alice@example.com>',
        'To: Bob <bob@example.com>',
        f'Subject: {subject}',
        'Date: Wed, 01 Jan 2026 00:00:00 +0000',
        f'Message-ID: {msg_id}',
    ]
    (d / 'meta').write_text('\n'.join(meta_lines) + '\n')
    (d / 'body.txt').write_text(plain_body)
    if html_body:
        (d / 'body.html').write_text(html_body)
    return d

def build_compose(headers, body):
    hdr = '\n'.join(f'{k}: {v}' for k, v in headers.items())
    return hdr + '\n\n' + body

def send_compose(compose_text, orig_dir=None):
    """Invoke the real send.send_mail with sendmail/ingest stubbed,
    and return the parsed message that WOULD have been delivered."""
    captured = {}

    class _Result:
        returncode = 0
        stderr = b''

    def fake_run(cmd, input=None, capture_output=False):
        captured['bytes'] = input
        return _Result()

    import subprocess
    real_run = subprocess.run
    real_ingest = ingest.ingest_one
    subprocess.run = fake_run
    ingest.ingest_one = lambda *args, **kwargs: None
    try:
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            f.write(compose_text)
            compose_path = Path(f.name)
        send.send_mail(compose_path, orig_dir, None)
        compose_path.unlink()
    finally:
        subprocess.run = real_run
        ingest.ingest_one = real_ingest
    return email.message_from_bytes(captured['bytes'], policy=email.policy.default)

def parts_of(msg):
    """Map content-type -> decoded text (CRLF normalised) for leaf parts."""
    out = {}
    for p in msg.walk():
        ct = p.get_content_type()
        if ct.startswith('multipart'):
            continue
        payload = p.get_content()
        if isinstance(payload, str):
            payload = payload.replace('\r\n', '\n')
        out[ct] = payload
    return out


print('\n=== Case 1: Reply to plain-text original ===')
with tempfile.TemporaryDirectory() as tmp:
    orig = make_orig(tmp, 'Hello', 'How are you?\n', msg_id='<orig1@test>')
    compose = build_compose(
        {'To': 'alice@example.com', 'Subject': 'Re: Hello',
         'In-Reply-To': '<orig1@test>'},
        'I am fine!\n\nOn Wed, 01 Jan 2026, Alice wrote:\n> How are you?\n'
    )
    msg = send_compose(compose, orig_dir=orig)
    parts = parts_of(msg)
    ok('is multipart/alternative', msg.get_content_type() == 'multipart/alternative',
       msg.get_content_type())
    ok('has text/plain', 'text/plain' in parts)
    ok('has text/html', 'text/html' in parts)
    ok('plain preserves > quote verbatim', '> How are you?' in parts['text/plain'])
    ok('plain keeps attribution', 'Alice wrote:' in parts['text/plain'])
    html = parts['text/html']
    ok('html has blockquote', '<blockquote' in html)
    ok('html has user text', 'I am fine!' in html)
    ok('html quote text inside blockquote (not raw >)',
       'How are you?' in html and '&gt; How are you' not in html)


print('\n=== Case 2: Reply to HTML original (class 2 — embed body.html) ===')
with tempfile.TemporaryDirectory() as tmp:
    orig = make_orig(tmp, 'Newsletter', 'Check this out!\n',
                     html_body='<html><body><b>Check this out!</b> <i>styled</i></body></html>',
                     msg_id='<orig2@test>')
    compose = build_compose(
        {'To': 'alice@example.com', 'Subject': 'Re: Newsletter',
         'In-Reply-To': '<orig2@test>'},
        'Great content!\n\n> Check this out!\n'
    )
    msg = send_compose(compose, orig_dir=orig)
    parts = parts_of(msg)
    ok('is multipart/alternative', msg.get_content_type() == 'multipart/alternative',
       msg.get_content_type())
    ok('plain preserves > quote', '> Check this out!' in parts['text/plain'])
    html = parts['text/html']
    ok('html embeds ORIGINAL markup verbatim', '<b>Check this out!</b> <i>styled</i>' in html)
    ok('html has blockquote', '<blockquote' in html)
    ok('html has user reply on top', 'Great content!' in html
       and html.find('Great content!') < html.find('<blockquote'))


print('\n=== Case 3: Multi-round reply (nested >> quoting) ===')
compose_r3 = build_compose(
    {'To': 'alice@example.com', 'Subject': 'Re: Thread',
     'In-Reply-To': '<r2@test>'},
    'Second reply.\n\n> First reply.\n>\n>> Original message.\n'
)
msg_r3 = send_compose(compose_r3, orig_dir=None)
parts = parts_of(msg_r3)
ok('plain preserves >> nesting verbatim', '>> Original message.' in parts['text/plain'])
html = parts['text/html']
ok('html nests blockquotes for >>', html.count('<blockquote') >= 2, html)
# the doubly-quoted line must sit inside two opened blockquotes
before_orig = html.split('Original message.')[0]
ok('>> line is inside 2 blockquotes',
   before_orig.count('<blockquote') - before_orig.count('</blockquote') >= 2)


print('\n=== Case 4: References / In-Reply-To chain (threading) ===')
compose_refs = build_compose(
    {'To': 'bob@example.com', 'Subject': 'Re: Thread',
     'In-Reply-To': '<msg2@test>',
     'References': '<msg1@test> <msg2@test>'},
    'My reply.\n\n> Previous.\n'
)
msg = send_compose(compose_refs)
ok('In-Reply-To preserved', msg.get('In-Reply-To', '').strip() == '<msg2@test>',
   repr(msg.get('In-Reply-To', '')))
refs = msg.get('References', '')
ok('References contains msg1', '<msg1@test>' in refs)
ok('References contains msg2', '<msg2@test>' in refs)


print('\n=== Case 5: [cid:...] lines stripped from quote (real quote_text) ===')
import email.message  # noqa: E402
m_cid = email.message.EmailMessage()
m_cid['Subject'] = 'inline'
m_cid.set_content(
    'Dear user,\n\nPlease see attached.\n\n'
    '[cid:8d2f5076-da23-4c2b-aea4-1fe85aff0fef]\n'
    'Regards\n'
)
q_cid = quote.quote_text(m_cid.as_bytes())
ok('[cid:] placeholder line removed', '[cid:' not in q_cid, repr(q_cid))
ok('text before the marker kept', 'Dear user,' in q_cid and 'Please see attached.' in q_cid)
ok('text after the marker kept', 'Regards' in q_cid)
m_inline = email.message.EmailMessage()
m_inline['Subject'] = 'inline2'
m_inline.set_content('see [cid:keepme] here\n')
ok('inline [cid:x] amid words is NOT stripped',
   'see [cid:keepme] here' in quote.quote_text(m_inline.as_bytes()))


print('\n=== Case 6: New compose (no original) ===')
compose_new = build_compose(
    {'To': 'someone@example.com', 'Subject': 'Hello there'},
    'Just saying hi.\n'
)
msg = send_compose(compose_new, orig_dir=None)
parts = parts_of(msg)
ok('is multipart/alternative', msg.get_content_type() == 'multipart/alternative',
   msg.get_content_type())
ok('plain contains message', 'Just saying hi.' in parts['text/plain'])
ok('no spurious > in plain', '>' not in parts['text/plain'])
ok('html has no blockquote (nothing quoted)', '<blockquote' not in parts['text/html'])


print('\n=== Case 7: Interleaved quoting keeps order (plain + html) ===')
compose_inter = build_compose(
    {'To': 'alice@example.com', 'Subject': 'Re: Address'},
    'Yes, correct:\n> 36 Nanyang Cres\n> Singapore\nThank you!\n'
)
msg = send_compose(compose_inter, orig_dir=None)
parts = parts_of(msg)
ok('plain keeps inline quote adjacent',
   'Yes, correct:\n> 36 Nanyang Cres\n> Singapore\nThank you!' in parts['text/plain'])
html = parts['text/html']
# Order: user line, blockquote(addr), user line — NOT all-quotes-at-bottom.
i_user1 = html.find('Yes, correct:')
i_bq = html.find('<blockquote')
i_bqend = html.find('</blockquote')
i_user2 = html.find('Thank you!')
ok('html: user text before blockquote', 0 <= i_user1 < i_bq, f'{i_user1},{i_bq}')
ok('html: blockquote holds the address', 'Singapore' in html[i_bq:i_bqend])
ok('html: user text after blockquote (interleave preserved)',
   i_bqend < i_user2, f'{i_bqend},{i_user2}')


print('\n=== Case 8: quote_text — clean source for quoting ===')
import email.message  # noqa: E402
m = email.message.EmailMessage()
m['Subject'] = 'x'
m.set_content('Guanyu Wang\nhello')                       # plain part (nbsp)
m.add_alternative('<p>Guanyu Wang <a href="http://x.com/very/long/url">site</a></p>',
                  subtype='html')
q = quote.quote_text(m.as_bytes())
ok('prefers sender text/plain', q == 'Guanyu Wang\nhello', repr(q))
ok('no Links footer in quote', 'Links:' not in q and '[1]' not in q)

raw_html_only = (b'Subject: y\r\nMIME-Version: 1.0\r\nContent-Type: text/html\r\n\r\n'
                 b'<p>see <a href="http://example.com/very/long/url">this link</a></p>')
q2 = quote.quote_text(raw_html_only)
ok('html-only quote is footnote-free', 'Links:' not in q2 and '[1]' not in q2, repr(q2))
ok('html-only keeps link text', 'this link' in q2)


print('\n=== Case 9: class 2 re-attaches cid images (multipart/related) ===')
with tempfile.TemporaryDirectory() as tmp:
    d = Path(tmp) / '20260101T000000Z_cidcidci'
    d.mkdir()
    (d / 'meta').write_text('From: A <a@x>\nSubject: s\nMessage-ID: <c@test>\n')
    (d / 'body.html').write_text('<html><body>hi <img src="cid:logo123"></body></html>')
    (d / 'body.txt').write_text('hi')
    png = b'\x89PNG\r\n\x1a\n' + b'\x00' * 16
    # original labels the image application/octet-stream (like QQ) -> must sniff
    raw = (b'Subject: s\r\nMIME-Version: 1.0\r\n'
           b'Content-Type: multipart/related; boundary="B"\r\n\r\n'
           b'--B\r\nContent-Type: text/html\r\n\r\n'
           b'<html><body>hi <img src="cid:logo123"></body></html>\r\n'
           b'--B\r\nContent-Type: application/octet-stream\r\nContent-ID: <logo123>\r\n'
           b'Content-Transfer-Encoding: base64\r\n\r\n'
           + base64.b64encode(png) + b'\r\n--B--\r\n')
    (d / 'raw.eml').write_bytes(raw)
    compose = build_compose({'To': 'a@x', 'Subject': 'Re: s'}, 'my reply\n\n> hi\n')
    msg = send_compose(compose, orig_dir=d)
    html = parts_of(msg)['text/html']
    ok('html keeps cid: reference (not data:)', 'cid:logo123' in html and 'data:' not in html)
    ok('embedded original text present', 'hi <img' in html)
    cidparts = [p for p in msg.walk() if (p.get('Content-ID') or '').strip('<>') == 'logo123']
    ok('image re-attached as a related part', len(cidparts) == 1, str(len(cidparts)))
    if cidparts:
        ok('image content-type sniffed to image/png',
           cidparts[0].get_content_type() == 'image/png', cidparts[0].get_content_type())
        ok('image bytes preserved', cidparts[0].get_content() == png)
    ok('html alternative is multipart/related',
       any(p.get_content_type() == 'multipart/related' for p in msg.walk()))


print('\n=== Case 10: forward-as-attachment (F) — original as message/rfc822 ===')
with tempfile.TemporaryDirectory() as tmp:
    od = Path(tmp) / 'orig'
    od.mkdir()
    (od / 'raw.eml').write_bytes(_fixtures.raw('embrace-the-chaos'))
    compose = build_compose(
        {'To': 'new@example.com', 'Subject': 'Fwd: EMBRACE THE CHAOS',
         'X-Forward-Dir': str(od)},
        'FYI, see below.\n\n---------- Forwarded message ----------\nFrom: Test Sender\n'
    )
    msg = send_compose(compose)
    ok('forward is multipart/mixed', msg.get_content_type() == 'multipart/mixed',
       msg.get_content_type())
    ok('X-Forward-Dir control header not leaked', msg.get('X-Forward-Dir') is None)
    ok('new thread (no In-Reply-To)', msg.get('In-Reply-To') is None)
    plains = [p.get_content() for p in msg.walk() if p.get_content_type() == 'text/plain']
    ok('forward note in body', any('FYI, see below.' in t for t in plains))
    rfc822 = [p for p in msg.walk() if p.get_content_type() == 'message/rfc822']
    ok('original attached as message/rfc822', len(rfc822) == 1)
    if rfc822:
        inner = rfc822[0].get_content()
        ok('forwarded subject preserved', inner.get('Subject') == 'EMBRACE THE CHAOS')
        names = {q.get_filename() for q in inner.walk() if q.get_filename()}
        ok('forwarded original keeps its attachments (lossless)',
           '3A0EC103@F1D05308.F10D3E6A00000000.png' in names, str(names))


print('\n=== Case 11: inline forward (f) — embed original + re-attach files ===')
with tempfile.TemporaryDirectory() as tmp:
    box = Path(tmp) / 'inbox'
    box.mkdir()
    od = ingest.ingest_one(_fixtures.raw('embrace-the-chaos'), box)
    compose = build_compose(
        {'To': 'new@example.com', 'Subject': 'Fwd: EMBRACE THE CHAOS',
         'X-Forward-Inline': '1'},
        'FYI see below.\n---------- Forwarded message ----------\nFrom: Test Sender\n'
    )
    msg = send_compose(compose, orig_dir=od)
    ok('inline forward is multipart/mixed', msg.get_content_type() == 'multipart/mixed',
       msg.get_content_type())
    ok('X-Forward-Inline not leaked', msg.get('X-Forward-Inline') is None)
    ok('new thread (no In-Reply-To)', msg.get('In-Reply-To') is None)
    plains = [p.get_content() for p in msg.walk() if p.get_content_type() == 'text/plain']
    ok('plain: note + original text UNQUOTED',
       any('FYI see below.' in t and '\n1314' in t and '> 1314' not in t for t in plains))
    htmls = [p.get_content() for p in msg.walk() if p.get_content_type() == 'text/html']
    ok('html: embeds the original tables', htmls and htmls[0].count('<table') == 2)
    ok('html: note above the quote (no duplication)',
       htmls and 0 <= htmls[0].find('FYI see below.') < htmls[0].find('<blockquote'))
    ok('cid image embedded as multipart/related',
       any(p.get_content_type() == 'multipart/related' for p in msg.walk()))
    ok('original .ics re-attached as a real attachment',
       any(p.get_content_type() == 'text/calendar' for p in msg.walk()))


print(f'\n{"="*40}')
print(f'Results: {PASS} passed, {FAIL} failed')
if FAIL:
    sys.exit(1)
