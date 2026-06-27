#!/bin/sh
# vim-mail one-shot setup (macOS).
#
# Prompts ONLY for your Gmail address and app password, then does everything
# else: installs deps, configures the Postfix→Gmail relay in /etc (with backups,
# idempotent), writes ~/.fetchmailrc, creates the store, and verifies the login.
# The only other thing it asks for is your *sudo* password (needed for /etc).
#
# Requires: 2-Step Verification on the Google account + an app password
#   https://myaccount.google.com/apppasswords
#
# After it finishes, add the printed snippet to your vimrc (the one manual step —
# plugin managers vary, so it won't touch your vimrc).
#
# Usage:  ./setup_lazyass.sh

set -eu

say()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$1" >&2; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "This script is macOS-only (Postfix relay setup). On Linux, follow README.md."

# --- locate this repo (follow symlinks) ------------------------------------
SELF=$0
while [ -h "$SELF" ]; do
  d=$(cd -P "$(dirname "$SELF")" && pwd); SELF=$(readlink "$SELF")
  case $SELF in /*) ;; *) SELF=$d/$SELF ;; esac
done
REPO=$(cd -P "$(dirname "$SELF")" && pwd)
[ -f "$REPO/mail_store.py" ] || die "mail_store.py not found next to this script ($REPO)"

# --- prompts (the only two) -------------------------------------------------
printf 'Gmail address: '; read -r EMAIL
[ -n "$EMAIL" ] || die "no email given"
printf 'Gmail app password (hidden): '
stty -echo 2>/dev/null; read -r APPPW; stty echo 2>/dev/null; printf '\n'
[ -n "$APPPW" ] || die "no password given"
USER_NAME=$(id -un)

say "Caching sudo (needed to write /etc/postfix)…"
sudo -v

# --- dependencies -----------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  die "Homebrew not found. Install from https://brew.sh then re-run."
fi
if ! command -v fetchmail >/dev/null 2>&1; then
  say "Installing fetchmail…"; brew install fetchmail
else
  say "fetchmail already installed."
fi
PYTHON=$(command -v python3 || true)
if [ -z "$PYTHON" ]; then
  say "Installing python3…"; brew install python; PYTHON=$(command -v python3)
fi
say "Using python3: $PYTHON"

# --- Postfix → Gmail relay (/etc) ------------------------------------------
MAIN_CF=/etc/postfix/main.cf
SASL=/etc/postfix/sasl_passwd
STAMP=$(date +%Y%m%d%H%M%S 2>/dev/null || echo backup)

if sudo grep -q '^relayhost = \[smtp.gmail.com\]:587' "$MAIN_CF" 2>/dev/null; then
  say "main.cf already has the Gmail relay block — leaving it."
else
  say "Backing up $MAIN_CF and appending the relay block…"
  sudo cp "$MAIN_CF" "$MAIN_CF.vimmail.$STAMP.bak"
  sudo tee -a "$MAIN_CF" >/dev/null <<'CF'

# --- added by vim-mail setup_lazyass.sh ---
relayhost = [smtp.gmail.com]:587
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_tls_security_level = encrypt
smtp_tls_CAfile = /etc/ssl/cert.pem
inet_protocols = ipv4
smtp_sasl_mechanism_filter = plain
CF
fi

say "Writing $SASL (root, 600) and compiling…"
# printf is a shell builtin, so the password is not exposed in the process list.
printf '[smtp.gmail.com]:587\t%s:%s\n' "$EMAIL" "$APPPW" | sudo tee "$SASL" >/dev/null
sudo chmod 600 "$SASL"
sudo postmap "$SASL"

say "Starting/reloading Postfix…"
sudo postfix start 2>/dev/null || true      # macOS won't auto-start it
sudo postfix reload 2>/dev/null || sudo postfix start

# --- mail store + ~/.fetchmailrc -------------------------------------------
MAIL_ROOT="${MAIL_ROOT:-$HOME/Mail}"
say "Creating store at $MAIL_ROOT (inbox, sent)…"
mkdir -p "$MAIL_ROOT/inbox" "$MAIL_ROOT/sent"

RC="$HOME/.fetchmailrc"
[ -f "$RC" ] && { say "Backing up existing $RC…"; cp "$RC" "$RC.vimmail.$STAMP.bak"; }
say "Writing $RC (600)…"
umask 077
cat > "$RC" <<RCEOF
poll imap.gmail.com protocol IMAP
    user "$EMAIL" with password "$APPPW" is "$USER_NAME" here
    ssl
    mda "$PYTHON $REPO/mail_store.py ingest-stdin $MAIL_ROOT/inbox"
RCEOF
chmod 600 "$RC"

# --- verify the login (no mail sent) ---------------------------------------
# Script in a temp file, password on stdin — so stdin isn't claimed by the
# heredoc and the password never appears in argv or the environment.
say "Verifying Gmail credentials (login only, nothing sent)…"
VERIFY=$(mktemp)
cat > "$VERIFY" <<'PY'
import sys, smtplib
email = sys.argv[1]
pw = sys.stdin.read()
try:
    s = smtplib.SMTP("smtp.gmail.com", 587, timeout=15)
    s.ehlo(); s.starttls(); s.ehlo(); s.login(email, pw); s.quit()
    print("AUTH OK")
except Exception as e:
    print("AUTH FAILED:", e); sys.exit(1)
PY
if printf '%s' "$APPPW" | "$PYTHON" "$VERIFY" "$EMAIL"; then
  say "Credentials OK."
else
  warn "SMTP login failed — check the app password / 2FA. Relay config is in place; fix the password in $SASL (then 'sudo postmap $SASL') and $RC."
fi
rm -f "$VERIFY"

# --- final manual step: vimrc ----------------------------------------------
cat <<EOF

------------------------------------------------------------------------------
Almost done. Add this to your vimrc (the only manual step):

    Plug '$REPO'
    let g:mail_root = '$MAIL_ROOT'
    let g:mail_from = '$EMAIL'

Then restart Vim, run :Mail, and press <leader>f to fetch.
------------------------------------------------------------------------------
EOF
say "Done."
