"""
oauth_token.py: the credential helper for msmtp/getmail.

  - 'password' accounts print the secret_command output verbatim.
  - 'oauth' accounts exchange the refresh token (from secret_command) for a
    fresh access token via the token endpoint.

No secret is ever read from the config file itself — only from secret_command,
so these tests use a real subprocess (echo) for the secret and inject a fake
HTTP poster for the token exchange (never touches the network).

Run: python3 tests/test_oauth.py
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'scripts'))
import oauth_token  # noqa: E402

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


# --- run_secret: reads from the command, not the config ---
ok('run_secret returns command stdout, stripped',
   oauth_token.run_secret(['echo', 'authcode123']) == 'authcode123')

try:
    oauth_token.run_secret([])
    ok('empty secret_command raises', False)
except ValueError:
    ok('empty secret_command raises', True)


# --- password account: credential == the secret, no HTTP ---
def boom(*_a, **_k):
    raise AssertionError('password account must not call the token endpoint')


pw_acct = {'auth': 'password', 'secret_command': ['echo', 's3cr3t']}
ok('password account prints the secret verbatim',
   oauth_token.credential(pw_acct, poster=boom) == 's3cr3t')


# --- oauth account: refresh token -> access token via injected poster ---
seen = {}


def fake_poster(url, fields):
    seen['url'] = url
    seen['fields'] = fields
    return {'access_token': 'ATOKEN', 'expires_in': 3600}


oauth_acct = {
    'auth': 'oauth',
    'token_uri': 'https://oauth2.example/token',
    'client_id': 'cid',
    'client_secret': 'csecret',
    'scope': 'https://mail.example/',
    'secret_command': ['echo', 'REFRESH'],
}
tok = oauth_token.credential(oauth_acct, poster=fake_poster)
ok('oauth account returns the access token', tok == 'ATOKEN')
ok('token exchange hits the configured token_uri',
   seen.get('url') == 'https://oauth2.example/token')
ok('grant_type is refresh_token', seen['fields'].get('grant_type') == 'refresh_token')
ok('refresh token comes from secret_command', seen['fields'].get('refresh_token') == 'REFRESH')
ok('client_id / secret / scope forwarded',
   seen['fields'].get('client_id') == 'cid'
   and seen['fields'].get('client_secret') == 'csecret'
   and seen['fields'].get('scope') == 'https://mail.example/')

# client_secret omitted when empty (Google desktop apps / MS public clients)
oauth_acct2 = dict(oauth_acct, client_secret='')
oauth_token.credential(oauth_acct2, poster=fake_poster)
ok('empty client_secret is not sent', 'client_secret' not in seen['fields'])


# --- missing access_token in the response is an error ---
try:
    oauth_token.token_from_refresh(oauth_acct, 'RT', poster=lambda u, f: {'error': 'bad'})
    ok('missing access_token raises', False)
except RuntimeError:
    ok('missing access_token raises', True)


# --- login flow: PKCE + authorize URL + code exchange (pure parts) ---
import base64 as _b64
import hashlib as _hashlib

verifier, challenge = oauth_token._pkce()
ok('pkce verifier/challenge are non-empty distinct strings',
   bool(verifier) and bool(challenge) and verifier != challenge)
ok('pkce challenge is base64url(sha256(verifier)) unpadded',
   challenge == _b64.urlsafe_b64encode(_hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode())

login_acct = {
    'authorize_uri': 'https://auth.example/authorize',
    'token_uri': 'https://auth.example/token',
    'client_id': 'cid',
    'scope': 'https://mail.example/',
}
url = oauth_token.build_authorize_url(login_acct, 'http://127.0.0.1:9/', 'CHAL')
ok('authorize url targets authorize_uri', url.startswith('https://auth.example/authorize?'))
ok('authorize url carries client_id + PKCE + offline',
   'client_id=cid' in url and 'code_challenge=CHAL' in url
   and 'code_challenge_method=S256' in url and 'access_type=offline' in url
   and 'redirect_uri=http%3A%2F%2F127.0.0.1%3A9%2F' in url)

exch = {}


def code_poster(u, f):
    exch['url'] = u
    exch['fields'] = f
    return {'refresh_token': 'RT', 'access_token': 'AT'}


resp = oauth_token.exchange_code(login_acct, 'CODE', 'VER', 'http://127.0.0.1:9/', poster=code_poster)
ok('code exchange returns the token response', resp.get('refresh_token') == 'RT')
ok('code exchange sends authorization_code grant + code + verifier',
   exch['fields'].get('grant_type') == 'authorization_code'
   and exch['fields'].get('code') == 'CODE'
   and exch['fields'].get('code_verifier') == 'VER')


print(f'\n{"="*40}')
print(f'Results: {PASS} passed, {FAIL} failed')
if FAIL:
    sys.exit(1)
