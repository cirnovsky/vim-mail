#!/usr/bin/env python3
"""
Integration test: fetch a real 200-message mailbox from a local GreenMail IMAP
server, through REAL getmail + the plugin, and verify the store, the live-progress
total, and incremental (oldmail) fetching.

This is NOT part of `make test` (which is hermetic and fast) — it starts a real
IMAP server and drives real getmail. Run it with `make test-integration`. It needs
`java`, `getmail`, `vim`, and (once) network access to fetch the GreenMail jar
from Maven Central. It self-SKIPS (exit 0) if any of those is missing.

What it proves that the unit tests can't:
  - mail#fetch#_progress matches REAL getmail output (not a guessed format).
  - the whole plugin fetch path (job_start -> out_cb -> _progress, MDA ingest)
    works end to end against a real server.
  - getmail's incremental/oldmail behaviour (re-fetch pulls nothing; new mail
    pulls exactly the new count).
"""
import email.utils
import imaplib
import shutil
import socket
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
IMAP_PORT = 3143            # GreenMail's default test IMAP port (setup.test.all)
USER, PW = 'test@localhost', 'pw'
SEED_N = 200

PASS = FAIL = 0


def ok(name, cond, detail=''):
    global PASS, FAIL
    if cond:
        print(f'  PASS  {name}')
        PASS += 1
    else:
        print(f'  FAIL  {name}' + (f': {detail}' if detail else ''))
        FAIL += 1


def skip(msg):
    print(f'  SKIP  {msg}')
    sys.exit(0)


def wait_port(port, timeout=30.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        with socket.socket() as s:
            s.settimeout(0.5)
            if s.connect_ex(('127.0.0.1', port)) == 0:
                return True
        time.sleep(0.2)
    return False


def wait_ready(timeout=30.0):
    """The IMAP socket opens before GreenMail's auth subsystem is ready, so a
    port check isn't enough — retry a real login until it succeeds."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            m = imaplib.IMAP4('127.0.0.1', IMAP_PORT)
            m.login(USER, PW)
            m.logout()
            return True
        except Exception:
            time.sleep(0.3)
    return False


def get_jar():
    cache = Path(tempfile.gettempdir()) / f'greenmail-standalone-{GM_VER}.jar'
    if cache.exists() and cache.stat().st_size > 1_000_000:
        return cache
    try:
        urllib.request.urlretrieve(GM_URL, cache)
    except Exception:
        return None
    return cache if cache.exists() and cache.stat().st_size > 1_000_000 else None


def seed(n, start=0):
    """APPEND n synthetic messages (unique Message-IDs) to the INBOX."""
    m = imaplib.IMAP4('127.0.0.1', IMAP_PORT)
    m.login(USER, PW)
    try:
        m.create('INBOX')
    except Exception:
        pass
    m.select('INBOX')
    for i in range(start, start + n):
        msg = (f"From: sender{i}@example.com\r\nTo: {USER}\r\n"
               f"Subject: Message {i}\r\nMessage-ID: <m{i}@greenmail.test>\r\n"
               f"Date: {email.utils.formatdate()}\r\n\r\nBody of message {i}.\r\n")
        m.append('INBOX', '', imaplib.Time2Internaldate(time.time()), msg.encode())
    m.logout()


def store_count(store):
    inbox = store / 'inbox'
    if not inbox.is_dir():
        return 0
    return len([d for d in inbox.iterdir() if not d.name.startswith('.')])


def main():
    for b in ('java', 'getmail', 'vim'):
        if not shutil.which(b):
            skip(f'{b} not found on PATH')
    jar = get_jar()
    if not jar:
        skip('could not obtain the GreenMail jar (no network?)')
    if wait_port(IMAP_PORT, timeout=0.5):
        skip(f'port {IMAP_PORT} already in use — stop any running GreenMail first')

    work = Path(tempfile.mkdtemp(prefix='gmtest_'))
    store = work / 'store'
    (store / 'inbox').mkdir(parents=True)
    gmdir = work / 'gmdir'
    gmdir.mkdir()
    py = sys.executable

    (gmdir / 'gmrc').write_text(f"""[retriever]
type = SimpleIMAPRetriever
server = 127.0.0.1
port = {IMAP_PORT}
username = {USER}
password = {PW}

[destination]
type = MDA_external
path = {py}
arguments = ("{REPO}/scripts/mail_store.py", "ingest-stdin", "{store}/inbox")

[options]
read_all = false
delete = false
""")

    def driver(tag):
        """Drive one fetch through the plugin; return its reported total string."""
        result = work / tag
        d = work / f'{tag}.vim'
        d.write_text(f"""
set rtp+={REPO}
let g:mail_python = '{py}'
let g:mail_store_py = '{REPO}/scripts/mail_store.py'
runtime plugin/mail.vim
runtime! autoload/mail/*.vim
let g:mail_root = '{store}'
let g:mail_getmail_rc = '{gmdir}/gmrc'
try
  call mail#fetch#fetch()
  call mail#fetch#_await()
  call writefile(['total=' . mail#fetch#_last_total()], '{result}')
catch
  call writefile(['ERR: ' . v:exception], '{result}')
endtry
qall!
""")
        subprocess.run(['vim', '-u', 'NONE', '-N', '-es', '-S', str(d)],
                       capture_output=True)
        return result.read_text().strip() if result.exists() else '(no result)'

    gm = None
    try:
        gm = subprocess.Popen(
            ['java', '-Dgreenmail.setup.test.all', '-Dgreenmail.auth.disabled',
             '-Dgreenmail.hostname=127.0.0.1', '-jar', str(jar)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not wait_port(IMAP_PORT) or not wait_ready():
            ok('GreenMail IMAP came up and accepts logins', False,
               'never became ready')
            return
        ok('GreenMail IMAP came up and accepts logins', True)

        # 1. Seed 200 and fetch through the plugin.
        seed(SEED_N)
        r = driver('r1')
        ok(f'fetch reports total={SEED_N} (real getmail -> live progress)',
           r == f'total={SEED_N}', r)
        ok(f'{SEED_N} messages ingested into the store',
           store_count(store) == SEED_N, str(store_count(store)))

        # 2. Re-fetch: getmail's oldmail should skip everything.
        r = driver('r2')
        ok('re-fetch reports total=0 (oldmail dedup)', r == 'total=0', r)
        ok(f'store unchanged at {SEED_N}', store_count(store) == SEED_N,
           str(store_count(store)))

        # 3. 50 more arrive. getmail numbers progress by position in the FULL
        #    mailbox, so its reported total M is now the mailbox size (250), not
        #    the 50 delivered — the delivered count is the store delta.
        seed(50, start=SEED_N)
        r = driver('r3')
        ok('fetch reports total=250 (getmail M = mailbox size, not fetched count)',
           r == 'total=250', r)
        ok(f'store grew to {SEED_N + 50} (the 50 new were delivered)',
           store_count(store) == SEED_N + 50, str(store_count(store)))
    finally:
        if gm:
            gm.terminate()
            try:
                gm.wait(timeout=10)
            except Exception:
                gm.kill()
        shutil.rmtree(work, ignore_errors=True)

    print(f'\n{"=" * 40}\nResults: {PASS} passed, {FAIL} failed')
    sys.exit(1 if FAIL else 0)


if __name__ == '__main__':
    main()
