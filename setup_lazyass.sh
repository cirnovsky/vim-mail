#!/bin/sh
# vim-mail one-shot ACCOUNT setup (macOS + Linux), multi-account & OAuth-aware.
#
# Run it once PER account. You give it an email address; it figures out the
# provider and does the rest:
#
#   - OAuth providers (Gmail, Outlook/M365): runs the browser consent for you,
#     captures the refresh token, stores it in your keychain, and wires msmtp +
#     getmail to mint access tokens on demand. The ONLY extra thing it needs is a
#     one-time OAuth *client id* from the provider's console (OAuth can't work
#     without an app registration — unavoidable), which it prompts for with a link.
#   - App-password providers (QQ, and anything you mark as such): asks for the
#     app password / authorization code instead.
#
# Then it writes ~/.config/vim-mail/accounts.json, ~/.msmtprc (send), and
# ~/.getmail/<account>.rc (fetch), creates the store, and prints the g:mail_accounts
# line to add to your vimrc. Re-run for each further account — it merges.
#
# ⚠  PRECAUTION — a convenience installer, NOT a magic button. It writes dotfiles
#   (~/.config/vim-mail, ~/.msmtprc, ~/.getmail/) and stores a secret in your
#   keychain (macOS Keychain / Linux Secret Service; a mode-600 file only as a
#   last resort, with a warning). It backs up existing files to *.vimmail.*.bak.
#   Unlike the old flow it does NOT touch /etc or Postfix. macOS is tested; the
#   Linux path is written but UNTESTED — read it, and see mail-setup.md §6.
#
# Usage:  ./setup_lazyass.sh

set -eu

say()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$1" >&2; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$1" >&2; exit 1; }

OS=$(uname -s)
case $OS in
  Darwin|Linux) ;;
  *) die "Unsupported OS '$OS'. macOS and Linux only — follow mail-setup.md manually." ;;
esac

# --- locate this repo (follow symlinks) ------------------------------------
SELF=$0
while [ -h "$SELF" ]; do
  d=$(cd -P "$(dirname "$SELF")" && pwd); SELF=$(readlink "$SELF")
  case $SELF in /*) ;; *) SELF=$d/$SELF ;; esac
done
REPO=$(cd -P "$(dirname "$SELF")" && pwd)
[ -f "$REPO/scripts/oauth_token.py" ] || die "scripts/oauth_token.py not found in this repo ($REPO)"

warn "This writes ~/.config/vim-mail, ~/.msmtprc, ~/.getmail/, creates the store,"
warn "and stores one secret in your keychain. Existing files are backed up to"
warn "*.vimmail.*.bak. It does NOT touch /etc. It's an automated version of mail-setup.md §6."
[ "$OS" = "Linux" ] && warn "NOTE: the Linux path is UNTESTED. Verify each step or follow mail-setup.md by hand."
printf 'Proceed? [y/N]: '; read -r ANS
case $ANS in [Yy]|[Yy][Ee][Ss]) ;; *) die "Aborted." ;; esac

PYTHON=$(command -v python3 || true)
STAMP=$(date +%Y%m%d%H%M%S 2>/dev/null || echo backup)

# --- 1. account + provider --------------------------------------------------
printf 'Email address: '; read -r EMAIL
[ -n "$EMAIL" ] || die "no email given"
DOMAIN=$(printf '%s' "$EMAIL" | sed 's/.*@//' | tr 'A-Z' 'a-z')

# --- shipped OAuth client id ------------------------------------------------
# Embed a provider's OAuth *client id* here to make it ONE-CLICK (just sign in in
# the browser, no per-user console step). Requires a one-time app registration by
# whoever ships this clone — see mail-setup.md §6 "Shipping Outlook". Empty ->
# fall back to prompting for a client id. Public clients use PKCE (no secret).
#
# Gmail can't be shipped this way (its full-mail scope is a Google "restricted"
# scope needing security verification), so Gmail uses an app password instead.
# Microsoft's mail scopes aren't restricted, so a multi-tenant public client works.
OUTLOOK_CLIENT_ID=""      # <- paste a multi-tenant Azure "public client" id to ship Outlook

# Provider profile fields (filled per case below).
PROVIDER=""; AUTH=""; IMAP_HOST=""; IMAP_PORT=""; SMTP_HOST=""; SMTP_PORT=""
TOKEN_URI=""; AUTHORIZE_URI=""; SCOPE=""; CONSOLE=""; CLIENT_ID_SHIPPED=""; APPPW_HELP=""
set_profile() {
  case $1 in
    gmail)
      PROVIDER=gmail; AUTH=password
      IMAP_HOST=imap.gmail.com; IMAP_PORT=993
      SMTP_HOST=smtp.gmail.com; SMTP_PORT=587
      APPPW_HELP="Generate an app password at https://myaccount.google.com/apppasswords (needs 2-Step Verification)." ;;
    outlook)
      PROVIDER=outlook; AUTH=oauth
      IMAP_HOST=outlook.office365.com; IMAP_PORT=993
      SMTP_HOST=smtp-mail.outlook.com; SMTP_PORT=587
      TOKEN_URI=https://login.microsoftonline.com/common/oauth2/v2.0/token
      AUTHORIZE_URI=https://login.microsoftonline.com/common/oauth2/v2.0/authorize
      SCOPE="offline_access https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send"
      CLIENT_ID_SHIPPED="$OUTLOOK_CLIENT_ID"
      CONSOLE="https://entra.microsoft.com — App registrations; 'Mobile and desktop' (public client); redirect http://127.0.0.1" ;;
    qq)
      PROVIDER=qq; AUTH=password
      IMAP_HOST=imap.qq.com; IMAP_PORT=993
      SMTP_HOST=smtp.qq.com; SMTP_PORT=465
      APPPW_HELP="Enable IMAP/SMTP in QQ Mail settings, then copy the authorization code it gives you." ;;
    *) return 1 ;;
  esac
}

case $DOMAIN in
  gmail.com|googlemail.com)          set_profile gmail ;;
  outlook.com|hotmail.com|live.com|msn.com|hotmail.co.uk) set_profile outlook ;;
  qq.com)                            set_profile qq ;;
  *)
    say "Couldn't infer the provider from '$DOMAIN'."
    printf 'Provider? [gmail/outlook/qq/other]: '; read -r P
    if ! set_profile "$P"; then
      # 'other': ask the essentials.
      PROVIDER=$P
      printf 'Auth kind [oauth/password]: '; read -r AUTH
      printf 'IMAP host: ';  read -r IMAP_HOST;  printf 'IMAP port [993]: '; read -r IMAP_PORT; IMAP_PORT=${IMAP_PORT:-993}
      printf 'SMTP host: ';  read -r SMTP_HOST;  printf 'SMTP port [587]: '; read -r SMTP_PORT; SMTP_PORT=${SMTP_PORT:-587}
      if [ "$AUTH" = oauth ]; then
        printf 'Token URI: ';     read -r TOKEN_URI
        printf 'Authorize URI: '; read -r AUTHORIZE_URI
        printf 'Scope: ';         read -r SCOPE
      fi
    fi ;;
esac
say "Provider: $PROVIDER  (auth: $AUTH)"

DEFAULT_ACCT=$PROVIDER
printf 'Account name (short label) [%s]: ' "$DEFAULT_ACCT"; read -r ACCT
ACCT=${ACCT:-$DEFAULT_ACCT}

DEFAULT_ROOT="$HOME/Mail/$ACCT"
printf 'Mail store path [%s]: ' "$DEFAULT_ROOT"; read -r MAIL_ROOT
MAIL_ROOT=${MAIL_ROOT:-$DEFAULT_ROOT}
case $MAIL_ROOT in "~") MAIL_ROOT=$HOME ;; "~/"*) MAIL_ROOT=$HOME/${MAIL_ROOT#"~/"} ;; esac

# --- 2. dependencies (msmtp + getmail; no Postfix/fetchmail) ----------------
if [ "$OS" = "Darwin" ]; then
  command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install from https://brew.sh then re-run."
  PKG=brew
elif command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
elif command -v pacman  >/dev/null 2>&1; then PKG=pacman
else die "No supported package manager. Install msmtp, getmail, python3 manually, then re-run."
fi
pkg_install() {
  case "$PKG:$1" in
    brew:python3)   brew install python ;;
    brew:getmail)   brew install getmail6 || brew install getmail ;;
    brew:*)         brew install "$1" ;;
    apt:getmail)    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y getmail6 || sudo apt-get install -y getmail ;;
    apt:*)          sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$1" ;;
    dnf:*)          sudo dnf install -y "$1" ;;
    pacman:python3) sudo pacman -S --needed --noconfirm python ;;
    pacman:*)       sudo pacman -S --needed --noconfirm "$1" ;;
  esac
}
[ "$PKG" = apt ] && { say "Refreshing apt index…"; sudo apt-get update; }
command -v msmtp   >/dev/null 2>&1 || { say "Installing msmtp…";   pkg_install msmtp; }
command -v getmail >/dev/null 2>&1 || { say "Installing getmail…"; pkg_install getmail; }
[ -n "$PYTHON" ] || { say "Installing python3…"; pkg_install python3; PYTHON=$(command -v python3); }
say "Using python3: $PYTHON"

# --- 3. secret storage backend ----------------------------------------------
# store_secret reads the secret on stdin, stores it, and prints "method<TAB>id"
# describing how to retrieve it (upsert_account turns that into secret_command).
CONF_DIR="$HOME/.config/vim-mail"
mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
store_secret() {  # $1 = account; secret on stdin
  _s=$(cat)
  if [ "$OS" = "Darwin" ]; then
    security add-generic-password -U -s "vim-mail-$1" -a "$EMAIL" -w "$_s" >/dev/null
    printf 'keychain\t%s' "$1"
  elif command -v secret-tool >/dev/null 2>&1; then
    printf '%s' "$_s" | secret-tool store --label="vim-mail $1" service vim-mail account "$1"
    printf 'secrettool\t%s' "$1"
  else
    _f="$CONF_DIR/$1.secret"
    umask 077; printf '%s' "$_s" > "$_f"; chmod 600 "$_f"
    warn "No keychain/secret-tool found — stored $1's secret in $_f (mode 600, PLAINTEXT)."
    warn "Prefer encrypting it (gpg) and pointing secret_command at 'gpg -dq'; see mail-setup.md §6."
    printf 'file\t%s' "$_f"
  fi
}

# upsert one account into accounts.json (python owns the JSON + secret_command).
upsert_account() {  # $1 = secret method, $2 = secret id
  ACCT="$ACCT" EMAIL="$EMAIL" AUTH="$AUTH" \
  IMAP_HOST="$IMAP_HOST" IMAP_PORT="$IMAP_PORT" SMTP_HOST="$SMTP_HOST" SMTP_PORT="$SMTP_PORT" \
  TOKEN_URI="$TOKEN_URI" AUTHORIZE_URI="$AUTHORIZE_URI" SCOPE="$SCOPE" \
  CLIENT_ID="${CLIENT_ID:-}" CLIENT_SECRET="${CLIENT_SECRET:-}" \
  SECRET_METHOD="$1" SECRET_ID="$2" ACCOUNTS_JSON="$CONF_DIR/accounts.json" \
  "$PYTHON" - <<'PY'
import json, os
from pathlib import Path
e = os.environ
p = Path(e["ACCOUNTS_JSON"])
cfg = json.loads(p.read_text()) if p.exists() else {}
method, sid = e["SECRET_METHOD"], e["SECRET_ID"]
if method == "keychain":
    sc = ["security", "find-generic-password", "-s", f"vim-mail-{sid}", "-w"]
elif method == "secrettool":
    sc = ["secret-tool", "lookup", "service", "vim-mail", "account", sid]
else:
    sc = ["cat", sid]
acct = {"auth": e["AUTH"], "email": e["EMAIL"],
        "imap_host": e["IMAP_HOST"], "imap_port": int(e["IMAP_PORT"]),
        "smtp_host": e["SMTP_HOST"], "smtp_port": int(e["SMTP_PORT"]),
        "secret_command": sc}
if e["AUTH"] == "oauth":
    acct.update({"token_uri": e["TOKEN_URI"], "authorize_uri": e["AUTHORIZE_URI"],
                 "scope": e["SCOPE"], "client_id": e["CLIENT_ID"]})
    if e["CLIENT_SECRET"]:
        acct["client_secret"] = e["CLIENT_SECRET"]
cfg[e["ACCT"]] = acct
p.write_text(json.dumps(cfg, indent=2) + "\n"); p.chmod(0o600)
PY
}

# --- 4. credentials ---------------------------------------------------------
if [ "$AUTH" = oauth ]; then
  if [ -n "$CLIENT_ID_SHIPPED" ]; then
    # One-click: use the built-in app registration; user just signs in.
    CLIENT_ID="$CLIENT_ID_SHIPPED"; CLIENT_SECRET=""
    say "Using the built-in $PROVIDER app — just sign in when the browser opens."
  else
    say "OAuth needs a one-time client id from the provider console:"
    [ -n "$CONSOLE" ] && printf '      %s\n' "$CONSOLE"
    printf 'OAuth client id: '; read -r CLIENT_ID
    [ -n "$CLIENT_ID" ] || die "no client id given"
    printf 'OAuth client secret (blank if none): '; read -r CLIENT_SECRET
  fi

  # Write the account first (login reads endpoints/client_id from accounts.json);
  # secret_command is set to its final value once the token is stored below.
  upsert_account file "$CONF_DIR/$ACCT.secret"

  say "Launching browser consent — sign in and approve…"
  REFRESH=$("$PYTHON" "$REPO/scripts/oauth_token.py" login "$ACCT" --config "$CONF_DIR/accounts.json") \
    || die "OAuth login failed. Check the client id / redirect (http://127.0.0.1) and scopes."
  [ -n "$REFRESH" ] || die "OAuth login returned no refresh token."
  RES=$(printf '%s' "$REFRESH" | store_secret "$ACCT")
  upsert_account "$(printf '%s' "$RES" | cut -f1)" "$(printf '%s' "$RES" | cut -f2)"
  say "Refresh token stored; access tokens are minted on demand."
else
  [ -n "$APPPW_HELP" ] && say "$APPPW_HELP"
  printf 'App password / authorization code (hidden): '
  stty -echo 2>/dev/null; read -r SECRET; stty echo 2>/dev/null; printf '\n'
  [ -n "$SECRET" ] || die "no password given"
  RES=$(printf '%s' "$SECRET" | store_secret "$ACCT")
  upsert_account "$(printf '%s' "$RES" | cut -f1)" "$(printf '%s' "$RES" | cut -f2)"
fi

# --- 5. msmtp (send) --------------------------------------------------------
MSMTPRC="$HOME/.msmtprc"
if [ ! -f "$MSMTPRC" ]; then
  say "Creating $MSMTPRC…"
  umask 077
  { echo "defaults"; echo "tls on"; echo "logfile ~/.msmtp.log"; echo; } > "$MSMTPRC"
fi
if grep -q "^account $ACCT\$" "$MSMTPRC" 2>/dev/null; then
  say "$MSMTPRC already has account '$ACCT' — leaving it (edit by hand to change)."
else
  say "Appending msmtp account '$ACCT'…"
  cp "$MSMTPRC" "$MSMTPRC.vimmail.$STAMP.bak"
  {
    echo "account $ACCT"
    echo "host $SMTP_HOST"
    echo "port $SMTP_PORT"
    echo "from $EMAIL"
    echo "user $EMAIL"
    [ "$SMTP_PORT" = 465 ] && echo "tls_starttls off"
    if [ "$AUTH" = oauth ]; then echo "auth xoauth2"; else echo "auth on"; fi
    echo "passwordeval \"$PYTHON $REPO/scripts/oauth_token.py $ACCT\""
    echo
  } >> "$MSMTPRC"
fi
chmod 600 "$MSMTPRC"

# --- 6. getmail (fetch) -----------------------------------------------------
GM_DIR="$HOME/.getmail"; mkdir -p "$GM_DIR"
GM_RC="$GM_DIR/$ACCT.rc"
[ -f "$GM_RC" ] && cp "$GM_RC" "$GM_RC.vimmail.$STAMP.bak"
say "Writing $GM_RC…"
umask 077
cat > "$GM_RC" <<GMEOF
[retriever]
type = SimpleIMAPSSLRetriever
server = $IMAP_HOST
port = $IMAP_PORT
username = $EMAIL
password_command = ("$PYTHON", "$REPO/scripts/oauth_token.py", "$ACCT")

[destination]
type = MDA_external
path = $PYTHON
arguments = ("$REPO/scripts/mail_store.py", "ingest-stdin", "$MAIL_ROOT/inbox")

[options]
read_all = false
delivered_to = false
received = false
GMEOF
chmod 600 "$GM_RC"

# --- 7. store + verify ------------------------------------------------------
say "Creating store at $MAIL_ROOT (inbox, sent)…"
mkdir -p "$MAIL_ROOT/inbox" "$MAIL_ROOT/sent"

say "Verifying the credential helper resolves…"
if "$PYTHON" "$REPO/scripts/oauth_token.py" "$ACCT" --config "$CONF_DIR/accounts.json" >/dev/null 2>&1; then
  say "Credential OK (token/password retrievable)."
else
  warn "oauth_token.py couldn't produce a credential yet — check the secret store / client id."
fi

# --- 8. vimrc + next steps --------------------------------------------------
cat <<EOF

------------------------------------------------------------------------------
Account '$ACCT' is set up. Add it to g:mail_accounts in your vimrc (merge if you
already have one — re-run this script per account):

    Plug '$REPO'
    let g:mail_accounts = {
      \\ '$ACCT': {'root': '$MAIL_ROOT', 'from': '$EMAIL', 'send': 'msmtp -a $ACCT -t'},
      \\ }

Fetch mail:   getmail --rcfile $ACCT.rc      (schedule via cron/launchd/systemd)
In Vim:       :Mail  ->  fold tree; <CR> the account, <CR> a mailbox.
              :MailAccount $ACCT  to switch.
------------------------------------------------------------------------------
EOF
say "Done."
