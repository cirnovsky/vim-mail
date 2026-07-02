#!/usr/bin/env python3
"""Print a credential for a mail account to stdout — for msmtp/getmail.

Two auth kinds, chosen per account in the config:

  password : print the secret verbatim (e.g. a QQ authorization code, or any
             app password). msmtp/getmail use it as the IMAP/SMTP password.
  oauth    : exchange the stored refresh token for a fresh OAuth2 access token
             (XOAUTH2 bearer) and print that.

SECRETS ARE NEVER STORED HERE. accounts.json holds only non-secret metadata
(endpoints, client_id, scope) plus a `secret_command` per account whose stdout
IS the secret — the refresh token for oauth, the password/app-code for password.
Wire it to your keychain / pass / gpg so nothing sensitive sits in plaintext:

    "secret_command": ["gpg", "--quiet", "--decrypt", "~/.config/vim-mail/gmail.gpg"]
    "secret_command": ["security", "find-generic-password", "-s", "vim-mail-gmail", "-w"]
    "secret_command": ["pass", "show", "mail/gmail-refresh"]

Config (default ~/.config/vim-mail/accounts.json), one entry per account:

    {
      "gmail": {
        "auth": "oauth",
        "token_uri": "https://oauth2.googleapis.com/token",
        "client_id": "....apps.googleusercontent.com",
        "client_secret": "",                       // optional (Google desktop apps)
        "scope": "https://mail.google.com/",
        "secret_command": ["pass", "show", "mail/gmail-refresh"]
      },
      "qq": {
        "auth": "password",
        "secret_command": ["pass", "show", "mail/qq-authcode"]
      }
    }

Usage:  oauth_token.py <account> [--config PATH]
"""

import argparse
import base64
import hashlib
import json
import secrets
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

DEFAULT_CONFIG = Path.home() / ".config" / "vim-mail" / "accounts.json"


def load_config(path):
    return json.loads(Path(path).expanduser().read_text(encoding="utf-8"))


def run_secret(command):
    """Run secret_command (argv list) and return its stdout, stripped. ~ in any
    argument is expanded so token-store paths can be written portably."""
    if not command:
        raise ValueError("account has no secret_command")
    argv = [str(Path(a).expanduser()) if a.startswith("~") else a for a in command]
    out = subprocess.run(argv, capture_output=True, check=True).stdout
    return out.decode("utf-8", "replace").strip()


def _post_form(url, fields):
    """Default HTTP form POST returning parsed JSON. Isolated so tests inject a
    fake and never touch the network."""
    data = urllib.parse.urlencode(fields).encode()
    with urllib.request.urlopen(url, data) as resp:
        return json.load(resp)


def token_from_refresh(acct, refresh_token, poster=_post_form):
    """Exchange a refresh token for an access token via the OAuth2 token endpoint."""
    fields = {
        "client_id": acct["client_id"],
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
    }
    if acct.get("client_secret"):
        fields["client_secret"] = acct["client_secret"]
    if acct.get("scope"):
        fields["scope"] = acct["scope"]
    resp = poster(acct["token_uri"], fields)
    if "access_token" not in resp:
        raise RuntimeError(f"token endpoint returned no access_token: {resp}")
    return resp["access_token"]


def credential(acct, poster=_post_form):
    """The credential to print for this account: the app-password for 'password'
    accounts, or a fresh access token for 'oauth' accounts."""
    secret = run_secret(acct.get("secret_command", []))
    if acct.get("auth", "password") == "oauth":
        return token_from_refresh(acct, secret, poster=poster)
    return secret


# --- one-time login: authorization-code + PKCE loopback flow ----------------
# `oauth_token.py login <account>` runs the browser consent once and prints the
# resulting REFRESH TOKEN to stdout (setup_lazyass.sh captures it into your
# keychain/gpg store). The account entry needs authorize_uri, token_uri,
# client_id, scope (client_secret optional). Loopback redirect on 127.0.0.1, so
# it works with Google "Desktop app" and Microsoft "public client" registrations.

def _pkce():
    """(verifier, challenge) for PKCE S256."""
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(64)).rstrip(b"=").decode()
    digest = hashlib.sha256(verifier.encode()).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode()
    return verifier, challenge


def build_authorize_url(acct, redirect_uri, challenge):
    params = {
        "client_id": acct["client_id"],
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": acct.get("scope", ""),
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "access_type": "offline",   # Google: needed to be issued a refresh token
        "prompt": "consent",        # force a refresh token even on re-consent
    }
    return acct["authorize_uri"] + "?" + urllib.parse.urlencode(params)


def exchange_code(acct, code, verifier, redirect_uri, poster=_post_form):
    fields = {
        "client_id": acct["client_id"],
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": redirect_uri,
        "code_verifier": verifier,
    }
    if acct.get("client_secret"):
        fields["client_secret"] = acct["client_secret"]
    return poster(acct["token_uri"], fields)


def login(acct, open_browser=True, poster=_post_form):
    """Run the consent flow and return a fresh refresh token."""
    import http.server
    import webbrowser

    verifier, challenge = _pkce()
    holder = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            holder.update(urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"vim-mail: authorization received. Close this tab.")

        def log_message(self, format, *args):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    redirect_uri = f"http://127.0.0.1:{srv.server_address[1]}/"
    url = build_authorize_url(acct, redirect_uri, challenge)
    sys.stderr.write("Opening your browser to authorize:\n  " + url + "\n")
    if open_browser:
        webbrowser.open(url)
    srv.handle_request()          # serve exactly the one redirect
    if "code" not in holder:
        raise RuntimeError(f"no authorization code received: {holder}")
    resp = exchange_code(acct, holder["code"][0], verifier, redirect_uri, poster=poster)
    if "refresh_token" not in resp:
        raise RuntimeError(f"no refresh_token in token response: {resp}")
    return resp["refresh_token"]


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)

    # `login <account>`: one-time consent, print the refresh token.
    if args and args[0] == "login":
        ap = argparse.ArgumentParser(prog="oauth_token.py login")
        ap.add_argument("account")
        ap.add_argument("--config", default=str(DEFAULT_CONFIG))
        a = ap.parse_args(args[1:])
        cfg = load_config(a.config)
        if a.account not in cfg:
            sys.exit(f"no such account: {a.account}")
        sys.stdout.write(login(cfg[a.account]))
        return

    # default: print a credential (access token / password) for msmtp/getmail.
    ap = argparse.ArgumentParser(description="print a mail-account credential")
    ap.add_argument("account")
    ap.add_argument("--config", default=str(DEFAULT_CONFIG))
    a = ap.parse_args(args)
    cfg = load_config(a.config)
    if a.account not in cfg:
        sys.exit(f"no such account: {a.account}")
    sys.stdout.write(credential(cfg[a.account]))


if __name__ == "__main__":
    main()
