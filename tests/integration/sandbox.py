#!/usr/bin/env python3
"""
Local GreenMail sandbox — hand-test mail fetching with NO real mail server.

Starts a throwaway in-memory GreenMail IMAP server on localhost, seeds it, and
prints the two vimrc lines to point the plugin at it. Then you drive fetch by
hand in Vim (`:Mail`, `<leader>f`) and watch the real N/M progress — no Gmail,
no credentials, no network (after the one-time GreenMail jar download).

    python3 tests/integration/sandbox.py [N]      # start + seed N (default 20),
                                                  # print config, stay up (Ctrl-C stops)
    python3 tests/integration/sandbox.py seed [K]  # APPEND K more to the running one

Typical loop:
    term 1)  python3 tests/integration/sandbox.py 20      # start, seed 20
    vim   )  :Mail  ->  <leader>f                          # fetch 20, watch 1/20..20/20
    term 2)  python3 tests/integration/sandbox.py seed 15  # 15 more arrive
    vim   )  <leader>f                                     # incremental: fetch the 15
"""
import email.utils
import imaplib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
GM_VER = '2.1.9'
GM_URL = ('https://repo1.maven.org/maven2/com/icegreen/greenmail-standalone/'
          f'{GM_VER}/greenmail-standalone-{GM_VER}.jar')
IMAP_PORT = 3143
USER, PW = 'test@localhost', 'pw'
SANDBOX = Path.home() / '.cache' / 'vim-mail-sandbox'


def get_jar():
    cache = Path(tempfile.gettempdir()) / f'greenmail-standalone-{GM_VER}.jar'
    if not (cache.exists() and cache.stat().st_size > 1_000_000):
        print(f'downloading GreenMail {GM_VER} (one time) ...')
        urllib.request.urlretrieve(GM_URL, cache)
    return cache


def imap():
    m = imaplib.IMAP4('127.0.0.1', IMAP_PORT)
    m.login(USER, PW)
    return m


def wait_ready(timeout=30.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            imap().logout()
            return True
        except Exception:
            time.sleep(0.3)
    return False


def count():
    m = imap()
    m.select('INBOX')
    _, d = m.search(None, 'ALL')
    m.logout()
    return len(d[0].split())


def seed(n, start):
    m = imap()
    try:
        m.create('INBOX')
    except Exception:
        pass
    m.select('INBOX')
    for i in range(start, start + n):
        msg = (f"From: Sender {i} <sender{i}@example.com>\r\nTo: {USER}\r\n"
               f"Subject: Sandbox message {i}\r\n"
               f"Message-ID: <sbx{i}.{int(time.time())}@greenmail.test>\r\n"
               f"Date: {email.utils.formatdate()}\r\n\r\n"
               f"Hello, this is sandbox message {i}.\r\n")
        m.append('INBOX', '', imaplib.Time2Internaldate(time.time()), msg.encode())
    m.logout()
    print(f'seeded {n} message(s)')


def cmd_seed():
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    if not wait_ready(2):
        sys.exit('No sandbox running on port 3143 — start it first:\n'
                 '  python3 tests/integration/sandbox.py')
    seed(n, count())


def cmd_start():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    for b in ('java', 'getmail', 'vim'):
        if not shutil.which(b):
            sys.exit(f'{b} not found on PATH (install it, or use the fake-getmail approach)')
    if wait_ready(1):
        sys.exit('Port 3143 is already busy (another sandbox / GreenMail). Stop it first.')

    jar = get_jar()
    # Fresh store + rc every start, so each session begins empty.
    shutil.rmtree(SANDBOX, ignore_errors=True)
    store = SANDBOX / 'store'
    (store / 'inbox').mkdir(parents=True)
    gmdir = SANDBOX / 'getmail'
    gmdir.mkdir(parents=True)
    (gmdir / 'getmailrc').write_text(f"""[retriever]
type = SimpleIMAPRetriever
server = 127.0.0.1
port = {IMAP_PORT}
username = {USER}
password = {PW}

[destination]
type = MDA_external
path = {sys.executable}
arguments = ("{REPO}/scripts/mail_store.py", "ingest-stdin", "{store}/inbox")

[options]
read_all = false
delete = false
""")

    gm = subprocess.Popen(
        ['java', '-Dgreenmail.setup.test.all', '-Dgreenmail.auth.disabled',
         '-Dgreenmail.hostname=127.0.0.1', '-jar', str(jar)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        if not wait_ready():
            sys.exit('GreenMail did not come up')
        seed(n, 0)
        print(f"""
GreenMail sandbox up on 127.0.0.1:{IMAP_PORT} — {count()} message(s) in INBOX.

Point the plugin at it (add to vimrc, or :let in a scratch Vim):
    let g:mail_root       = '{store}'
    let g:mail_getmail_rc = '{gmdir}/getmailrc'

Then:   :Mail   ->   <leader>f          (watch the N/M progress; mail lands in inbox)
More:   python3 tests/integration/sandbox.py seed 15   ->   <leader>f again (incremental)

Ctrl-C here to stop the sandbox.
""", flush=True)
        signal.pause()
    except KeyboardInterrupt:
        print('\nstopping sandbox ...')
    finally:
        gm.terminate()
        try:
            gm.wait(timeout=10)
        except Exception:
            gm.kill()


if __name__ == '__main__':
    if len(sys.argv) >= 2 and sys.argv[1] == 'seed':
        cmd_seed()
    else:
        cmd_start()
