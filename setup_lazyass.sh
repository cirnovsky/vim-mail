#!/bin/sh
# vim-mail one-shot setup (macOS + Linux) — any account+password mail provider.
#
# Give it an email; it detects the provider (Gmail, Yahoo, iCloud, Fastmail,
# Purelymail, Zoho, Yandex, GMX, QQ, 163/126, …), configures the Postfix relay to
# that provider's SMTP in /etc (backups, idempotent), writes ~/.fetchmailrc
# pointed at its IMAP, creates the store, and verifies the login. You provide the
# email, an app password (or authorization code), and your sudo password (for
# /etc). Unknown providers: it asks for the IMAP/SMTP hosts.
#
# It does NOT install dependencies — postfix, fetchmail, python3 must already be
# present (see README "Needs"). It errors out listing anything missing.
#
# Works with any provider that still allows app-password / basic auth over
# IMAP+SMTP. Providers that FORCE OAuth (Outlook.com / Microsoft 365, and Google
# Workspace custom domains) are NOT handled here — use the 'multi-account-oauth'
# branch (getmail + msmtp + OAuth) for those.
#
# ⚠  PRECAUTION — a convenience installer, NOT a magic button. It edits system
#   files: appends to /etc/postfix/main.cf, writes /etc/postfix/sasl_passwd,
#   (re)starts Postfix, writes ~/.fetchmailrc. It backs up what it changes to
#   *.vimmail.<timestamp>.bak, but it's best-effort — READ IT, and treat it as an
#   automated version of mail-setup.md. macOS is tested; the Linux path is
#   written but UNTESTED.
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
[ -f "$REPO/scripts/mail_store.py" ] || die "scripts/mail_store.py not found in this repo ($REPO)"

# --- provider profiles ------------------------------------------------------
# Basic-auth (app-password) providers. OAuth-only ones are rejected below.
PROVIDER=""; SMTP_HOST=""; SMTP_PORT=""; IMAP_HOST=""; APPPW_HELP=""
set_provider() {  # $1 = lowercased email domain
  case $1 in
    gmail.com|googlemail.com)
      PROVIDER=gmail; SMTP_HOST=smtp.gmail.com; SMTP_PORT=587; IMAP_HOST=imap.gmail.com
      APPPW_HELP="App password: https://myaccount.google.com/apppasswords (needs 2-Step Verification). Consumer @gmail.com only — Google Workspace/custom domains now force OAuth." ;;
    yahoo.com|ymail.com|myyahoo.com|rocketmail.com)
      PROVIDER=yahoo; SMTP_HOST=smtp.mail.yahoo.com; SMTP_PORT=465; IMAP_HOST=imap.mail.yahoo.com
      APPPW_HELP="App password: Yahoo Account Security -> Generate app password (needs 2FA)." ;;
    aol.com)
      PROVIDER=aol; SMTP_HOST=smtp.aol.com; SMTP_PORT=465; IMAP_HOST=imap.aol.com
      APPPW_HELP="App password: AOL Account Security -> Generate app password (needs 2-Step Verification)." ;;
    icloud.com|me.com|mac.com)
      PROVIDER=icloud; SMTP_HOST=smtp.mail.me.com; SMTP_PORT=587; IMAP_HOST=imap.mail.me.com
      APPPW_HELP="App-specific password: account.apple.com -> Sign-In and Security -> App-Specific Passwords (needs 2FA)." ;;
    fastmail.com|fastmail.fm)
      PROVIDER=fastmail; SMTP_HOST=smtp.fastmail.com; SMTP_PORT=587; IMAP_HOST=imap.fastmail.com
      APPPW_HELP="App password: Fastmail Settings -> Privacy & Security -> App passwords (needs a paid plan for IMAP)." ;;
    purelymail.com)
      PROVIDER=purelymail; SMTP_HOST=smtp.purelymail.com; SMTP_PORT=465; IMAP_HOST=imap.purelymail.com
      APPPW_HELP="Use your Purelymail password (or an app password if 2FA is on)." ;;
    zoho.com)
      PROVIDER=zoho; SMTP_HOST=smtp.zoho.com; SMTP_PORT=587; IMAP_HOST=imap.zoho.com
      APPPW_HELP="App password: Zoho Account -> Security -> App Passwords (needs 2FA + IMAP enabled)." ;;
    yandex.com|yandex.ru|ya.ru)
      PROVIDER=yandex; SMTP_HOST=smtp.yandex.com; SMTP_PORT=465; IMAP_HOST=imap.yandex.com
      APPPW_HELP="App password: Yandex ID -> App passwords -> Mail (and enable IMAP)." ;;
    gmx.com|gmx.net|gmx.de)
      PROVIDER=gmx; SMTP_HOST=mail.gmx.com; SMTP_PORT=587; IMAP_HOST=imap.gmx.com
      APPPW_HELP="Enable POP3/IMAP in GMX Settings first, then use your account password." ;;
    qq.com)
      PROVIDER=qq; SMTP_HOST=smtp.qq.com; SMTP_PORT=465; IMAP_HOST=imap.qq.com
      APPPW_HELP="Authorization code: enable IMAP/SMTP in QQ Mail settings, copy the code it gives you." ;;
    163.com)
      PROVIDER=163; SMTP_HOST=smtp.163.com; SMTP_PORT=465; IMAP_HOST=imap.163.com
      APPPW_HELP="Authorization code: enable IMAP/SMTP in 163 Mail settings, copy the code." ;;
    126.com)
      PROVIDER=126; SMTP_HOST=smtp.126.com; SMTP_PORT=465; IMAP_HOST=imap.126.com
      APPPW_HELP="Authorization code: enable IMAP/SMTP in 126 Mail settings, copy the code." ;;
    outlook.com|hotmail.com|hotmail.co.uk|live.com|live.co.uk|msn.com|passport.com)
      die "Outlook/Microsoft forces OAuth (basic auth is gone) — not supported by this single-account installer. Use the 'multi-account-oauth' branch (getmail + msmtp + OAuth)." ;;
    *) return 1 ;;
  esac
}

# When sourced with VIMMAIL_TEST=1, load only the helpers/profiles above and stop
# here, so tests can exercise set_provider without the interactive install flow.
# (Safe when executed: the guard is false, so `return` never runs at top level.)
[ "${VIMMAIL_TEST:-}" = 1 ] && return 0

# --- precaution / confirm ---------------------------------------------------
warn "This will edit system files (/etc/postfix/main.cf + sasl_passwd), (re)start"
warn "Postfix, and write ~/.fetchmailrc. Changes are backed up to *.vimmail.*.bak,"
warn "but this is best-effort — it's an automated version of mail-setup.md's steps."
[ "$OS" = "Linux" ] && warn "NOTE: the Linux path is UNTESTED. Verify each step or follow mail-setup.md by hand."
printf 'Proceed? [y/N]: '; read -r ANS
case $ANS in [Yy]|[Yy][Ee][Ss]) ;; *) die "Aborted." ;; esac

# --- prompts ----------------------------------------------------------------
printf 'Email address: '; read -r EMAIL
[ -n "$EMAIL" ] || die "no email given"
DOMAIN=$(printf '%s' "$EMAIL" | sed 's/.*@//' | tr 'A-Z' 'a-z')
if ! set_provider "$DOMAIN"; then
  PROVIDER=$DOMAIN
  say "Unknown provider '$DOMAIN' — enter its servers (must allow app-password / basic auth over IMAP+SMTP)."
  printf 'IMAP host: '; read -r IMAP_HOST; [ -n "$IMAP_HOST" ] || die "no IMAP host"
  printf 'SMTP host: '; read -r SMTP_HOST; [ -n "$SMTP_HOST" ] || die "no SMTP host"
  printf 'SMTP submission port [587]: '; read -r SMTP_PORT; SMTP_PORT=${SMTP_PORT:-587}
fi
say "Provider: $PROVIDER  (SMTP $SMTP_HOST:$SMTP_PORT · IMAP $IMAP_HOST:993)"
[ -n "$APPPW_HELP" ] && say "$APPPW_HELP"

printf 'App password / code (hidden): '
stty -echo 2>/dev/null; read -r APPPW; stty echo 2>/dev/null; printf '\n'
[ -n "$APPPW" ] || die "no password given"
DEFAULT_ROOT="$HOME/Mail"
printf 'Mail store path [%s]: ' "$DEFAULT_ROOT"; read -r MAIL_ROOT
MAIL_ROOT=${MAIL_ROOT:-$DEFAULT_ROOT}
case $MAIL_ROOT in "~") MAIL_ROOT=$HOME ;; "~/"*) MAIL_ROOT=$HOME/${MAIL_ROOT#"~/"} ;; esac
USER_NAME=$(id -un)

# --- required tools (this script does NOT install them; see README "Needs") --
MISSING=""
command -v python3   >/dev/null 2>&1 || MISSING="$MISSING python3"
command -v fetchmail >/dev/null 2>&1 || MISSING="$MISSING fetchmail"
command -v postfix   >/dev/null 2>&1 || MISSING="$MISSING postfix"
[ -n "$MISSING" ] && die "Missing:$MISSING. Install them (see README 'Needs'), then re-run."
PYTHON=$(command -v python3)
say "Using python3: $PYTHON"

say "Caching sudo (needed to write /etc/postfix)…"
sudo -v

# --- Postfix relay (/etc) ---------------------------------------------------
MAIN_CF=/etc/postfix/main.cf
SASL=/etc/postfix/sasl_passwd
STAMP=$(date +%Y%m%d%H%M%S 2>/dev/null || echo backup)

CAFILE=""
for c in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
  [ -f "$c" ] && { CAFILE=$c; break; }
done
[ -n "$CAFILE" ] || die "No TLS CA bundle found in the usual paths; set smtp_tls_CAfile manually in $MAIN_CF."
say "Using CA bundle: $CAFILE"

[ -f "$MAIN_CF" ] || die "$MAIN_CF not found — is Postfix installed? Install it, then re-run."
if sudo grep -q "^relayhost = \[$SMTP_HOST\]:$SMTP_PORT" "$MAIN_CF" 2>/dev/null; then
  say "main.cf already relays to $SMTP_HOST:$SMTP_PORT — leaving it."
else
  say "Backing up $MAIN_CF and appending the relay block…"
  sudo cp "$MAIN_CF" "$MAIN_CF.vimmail.$STAMP.bak"
  # Port 465 is implicit TLS (SMTPS) — Postfix needs wrappermode; 587 is STARTTLS.
  WRAP=""
  [ "$SMTP_PORT" = 465 ] && WRAP="smtp_tls_wrappermode = yes"
  sudo tee -a "$MAIN_CF" >/dev/null <<CF

# --- added by vim-mail setup_lazyass.sh ($PROVIDER) ---
relayhost = [$SMTP_HOST]:$SMTP_PORT
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_tls_security_level = encrypt
smtp_tls_CAfile = $CAFILE
inet_protocols = ipv4
smtp_sasl_mechanism_filter = plain, login
$WRAP
CF
fi

say "Writing $SASL (root, 600) and compiling…"
printf '[%s]:%s\t%s:%s\n' "$SMTP_HOST" "$SMTP_PORT" "$EMAIL" "$APPPW" | sudo tee "$SASL" >/dev/null
sudo chmod 600 "$SASL"
sudo postmap "$SASL"

say "Starting/reloading Postfix…"
if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl enable --now postfix
  sudo systemctl reload postfix 2>/dev/null || sudo systemctl restart postfix
else
  sudo postfix start 2>/dev/null || true      # macOS won't auto-start it
  sudo postfix reload 2>/dev/null || sudo postfix start
fi

# --- mail store + ~/.fetchmailrc -------------------------------------------
say "Creating store at $MAIL_ROOT (inbox, sent)…"
mkdir -p "$MAIL_ROOT/inbox" "$MAIL_ROOT/sent"

RC="$HOME/.fetchmailrc"
[ -f "$RC" ] && { say "Backing up existing $RC…"; cp "$RC" "$RC.vimmail.$STAMP.bak"; }
say "Writing $RC (600)…"
umask 077
cat > "$RC" <<RCEOF
poll $IMAP_HOST protocol IMAP
    user "$EMAIL" with password "$APPPW" is "$USER_NAME" here
    ssl
    mda "$PYTHON $REPO/scripts/mail_store.py ingest-stdin $MAIL_ROOT/inbox"
RCEOF
chmod 600 "$RC"

# --- verify the login (no mail sent) ---------------------------------------
say "Verifying credentials against $SMTP_HOST:$SMTP_PORT (login only, nothing sent)…"
VERIFY=$(mktemp)
cat > "$VERIFY" <<'PY'
import sys, smtplib
host, port, email = sys.argv[1], int(sys.argv[2]), sys.argv[3]
pw = sys.stdin.read()
try:
    if port == 465:
        s = smtplib.SMTP_SSL(host, port, timeout=15)
    else:
        s = smtplib.SMTP(host, port, timeout=15); s.ehlo(); s.starttls()
    s.ehlo(); s.login(email, pw); s.quit()
    print("AUTH OK")
except Exception as e:
    print("AUTH FAILED:", e); sys.exit(1)
PY
if printf '%s' "$APPPW" | "$PYTHON" "$VERIFY" "$SMTP_HOST" "$SMTP_PORT" "$EMAIL"; then
  say "Credentials OK."
else
  warn "SMTP login failed — check the app password / that IMAP-SMTP is enabled for the account."
  warn "Relay config is in place; fix the password in $SASL (then 'sudo postmap $SASL') and $RC."
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
