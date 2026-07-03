"""
setup_lazyass.sh: the installer's provider-detection table.

The installer edits /etc and hits the network, so we don't run the whole thing —
but its set_provider() (domain -> IMAP/SMTP hosts+port) is pure. Sourcing the
script with VIMMAIL_TEST=1 loads just the helpers + set_provider and stops before
the interactive/destructive flow, so we can pin the table and the OAuth-provider
rejection here. Also checks the script parses (sh -n).

Run: python3 tests/test_lazyass.py
"""

import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "setup_lazyass.sh"

PASS = 0
FAIL = 0


def ok(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        print(f"  PASS  {name}")
        PASS += 1
    else:
        print(f"  FAIL  {name}" + (f": {detail}" if detail else ""))
        FAIL += 1


def probe(domain):
    """Source the script (test mode) and run set_provider <domain>; return
    (returncode, 'PROVIDER|SMTP_HOST|SMTP_PORT|IMAP_HOST', stderr)."""
    code = ('. "$0"; set_provider "$1" || exit 7; '
            'printf "%s|%s|%s|%s" "$PROVIDER" "$SMTP_HOST" "$SMTP_PORT" "$IMAP_HOST"')
    r = subprocess.run(
        ["sh", "-c", code, str(SCRIPT), domain],
        env={**os.environ, "VIMMAIL_TEST": "1"},
        stdin=subprocess.DEVNULL, capture_output=True, text=True,
    )
    return r.returncode, r.stdout, r.stderr


# --- the script parses ---
ok("sh -n parses setup_lazyass.sh",
   subprocess.run(["sh", "-n", str(SCRIPT)]).returncode == 0)

# --- basic-auth providers resolve to the right hosts/ports ---
EXPECT = {
    "gmail.com":    "gmail|smtp.gmail.com|587|imap.gmail.com",
    "googlemail.com": "gmail|smtp.gmail.com|587|imap.gmail.com",
    "yahoo.com":    "yahoo|smtp.mail.yahoo.com|465|imap.mail.yahoo.com",
    "aol.com":      "aol|smtp.aol.com|465|imap.aol.com",
    "icloud.com":   "icloud|smtp.mail.me.com|587|imap.mail.me.com",
    "me.com":       "icloud|smtp.mail.me.com|587|imap.mail.me.com",
    "fastmail.com": "fastmail|smtp.fastmail.com|587|imap.fastmail.com",
    "purelymail.com": "purelymail|smtp.purelymail.com|465|imap.purelymail.com",
    "zoho.com":     "zoho|smtp.zoho.com|587|imap.zoho.com",
    "yandex.com":   "yandex|smtp.yandex.com|465|imap.yandex.com",
    "gmx.com":      "gmx|mail.gmx.com|587|imap.gmx.com",
    "qq.com":       "qq|smtp.qq.com|465|imap.qq.com",
    "163.com":      "163|smtp.163.com|465|imap.163.com",
    "126.com":      "126|smtp.126.com|465|imap.126.com",
}
for domain, want in EXPECT.items():
    rc, out, _ = probe(domain)
    ok(f"{domain} -> {want}", rc == 0 and out == want, f"rc={rc} out={out!r}")

# --- 465 providers stay on 465, 587 providers on 587 (implicit vs STARTTLS) ---
ok("465 vs 587 split is preserved",
   probe("qq.com")[1].endswith("|465|imap.qq.com")
   and probe("gmail.com")[1].split("|")[2] == "587")

# --- OAuth-only providers are rejected (not silently mis-handled) ---
for domain in ("outlook.com", "hotmail.com", "live.com", "msn.com"):
    rc, _, err = probe(domain)
    ok(f"{domain} rejected with an OAuth pointer",
       rc != 0 and rc != 7 and "OAuth" in err and "multi-account-oauth" in err,
       f"rc={rc} err={err!r}")

# --- unknown domain: set_provider returns nonzero (caller then prompts) ---
rc, _, _ = probe("example.invalid")
ok("unknown domain -> set_provider returns nonzero", rc == 7, f"rc={rc}")


print(f"\n{'='*40}")
print(f"Results: {PASS} passed, {FAIL} failed")
if FAIL:
    sys.exit(1)
