#!/bin/sh
# vim-mail one-shot setup (macOS + Linux).
#
# Prompts for your Gmail address, app password, and where to keep the mail store
# (defaults to ~/Mail), then does everything else: installs deps, configures the
# Postfix→Gmail relay in /etc (with backups, idempotent), writes ~/.fetchmailrc,
# creates the store, and verifies the login. The only other thing it asks for is
# your *sudo* password (needed for /etc).
#
# ⚠  PRECAUTION — this is a convenience installer, NOT a magic button.
#   It edits system files: it appends to /etc/postfix/main.cf, writes
#   /etc/postfix/sasl_passwd, (re)starts Postfix, and writes ~/.fetchmailrc. It
#   backs up everything it changes to *.vimmail.<timestamp>.bak, but it is
#   best-effort and not bulletproof. READ IT before running, and treat it as an
#   automated, runnable version of the manual install steps in README.md /
#   mail-setup.md — if anything looks off for your machine, follow those by hand.
#
#   macOS is tested. The Linux path (apt/dnf/pacman package install, systemctl
#   service start, CA-bundle probing) is written but UNTESTED — sanity-check each
#   step if you rely on it, and keep the manual steps handy as a fallback.
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

OS=$(uname -s)
case $OS in
  Darwin|Linux) ;;
  *) die "Unsupported OS '$OS'. macOS and Linux only — follow README.md manually." ;;
esac

# --- locate this repo (follow symlinks) ------------------------------------
SELF=$0
while [ -h "$SELF" ]; do
  d=$(cd -P "$(dirname "$SELF")" && pwd); SELF=$(readlink "$SELF")
  case $SELF in /*) ;; *) SELF=$d/$SELF ;; esac
done
REPO=$(cd -P "$(dirname "$SELF")" && pwd)
[ -f "$REPO/mail_store.py" ] || die "mail_store.py not found next to this script ($REPO)"

# --- precaution / confirm ---------------------------------------------------
warn "This will edit system files (/etc/postfix/main.cf + sasl_passwd), (re)start"
warn "Postfix, and write ~/.fetchmailrc. Changes are backed up to *.vimmail.*.bak,"
warn "but this is best-effort — it's an automated version of README.md's steps."
[ "$OS" = "Linux" ] && warn "NOTE: the Linux path is UNTESTED. Verify each step or follow README.md by hand."
printf 'Proceed? [y/N]: '; read -r ANS
case $ANS in [Yy]|[Yy][Ee][Ss]) ;; *) die "Aborted." ;; esac

# --- prompts (the only inputs) ----------------------------------------------
printf 'Gmail address: '; read -r EMAIL
[ -n "$EMAIL" ] || die "no email given"
printf 'Gmail app password (hidden): '
stty -echo 2>/dev/null; read -r APPPW; stty echo 2>/dev/null; printf '\n'
[ -n "$APPPW" ] || die "no password given"
DEFAULT_ROOT="$HOME/Mail"
printf 'Mail store path [%s]: ' "$DEFAULT_ROOT"; read -r MAIL_ROOT
MAIL_ROOT=${MAIL_ROOT:-$DEFAULT_ROOT}
# Expand a leading ~ (read leaves it literal).
case $MAIL_ROOT in "~") MAIL_ROOT=$HOME ;; "~/"*) MAIL_ROOT=$HOME/${MAIL_ROOT#"~/"} ;; esac
USER_NAME=$(id -un)

say "Caching sudo (needed to write /etc/postfix)…"
sudo -v

# --- package manager + dependencies ----------------------------------------
if [ "$OS" = "Darwin" ]; then
  command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install from https://brew.sh then re-run."
  PKG=brew
elif command -v apt-get >/dev/null 2>&1; then
  PKG=apt
elif command -v dnf >/dev/null 2>&1; then
  PKG=dnf
elif command -v pacman >/dev/null 2>&1; then
  PKG=pacman
else
  die "No supported package manager (brew/apt/dnf/pacman). Install postfix, fetchmail, python3 manually, then re-run."
fi

pkg_install() {  # $1 = generic tool name (postfix | fetchmail | python3)
  case "$PKG:$1" in
    brew:python3)   brew install python ;;
    brew:*)         brew install "$1" ;;
    apt:*)          sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$1" ;;
    dnf:*)          sudo dnf install -y "$1" ;;
    pacman:python3) sudo pacman -S --needed --noconfirm python ;;
    pacman:*)       sudo pacman -S --needed --noconfirm "$1" ;;
  esac
}

[ "$PKG" = apt ] && { say "Refreshing apt package index…"; sudo apt-get update; }

# Postfix is built into macOS; on Linux install it if missing.
if [ "$OS" != "Darwin" ] && ! command -v postfix >/dev/null 2>&1; then
  say "Installing postfix…"; pkg_install postfix
fi
if ! command -v fetchmail >/dev/null 2>&1; then
  say "Installing fetchmail…"; pkg_install fetchmail
else
  say "fetchmail already installed."
fi
PYTHON=$(command -v python3 || true)
if [ -z "$PYTHON" ]; then
  say "Installing python3…"; pkg_install python3; PYTHON=$(command -v python3)
fi
say "Using python3: $PYTHON"

# --- Postfix → Gmail relay (/etc) ------------------------------------------
MAIN_CF=/etc/postfix/main.cf
SASL=/etc/postfix/sasl_passwd
STAMP=$(date +%Y%m%d%H%M%S 2>/dev/null || echo backup)

# CA bundle path differs by OS/distro — probe the usual locations.
CAFILE=""
for c in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
  [ -f "$c" ] && { CAFILE=$c; break; }
done
[ -n "$CAFILE" ] || die "No TLS CA bundle found in the usual paths; set smtp_tls_CAfile manually in $MAIN_CF."
say "Using CA bundle: $CAFILE"

[ -f "$MAIN_CF" ] || die "$MAIN_CF not found — is Postfix installed? Install it, then re-run."
if sudo grep -q '^relayhost = \[smtp.gmail.com\]:587' "$MAIN_CF" 2>/dev/null; then
  say "main.cf already has the Gmail relay block — leaving it."
else
  say "Backing up $MAIN_CF and appending the relay block…"
  sudo cp "$MAIN_CF" "$MAIN_CF.vimmail.$STAMP.bak"
  sudo tee -a "$MAIN_CF" >/dev/null <<CF

# --- added by vim-mail setup_lazyass.sh ---
relayhost = [smtp.gmail.com]:587
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_tls_security_level = encrypt
smtp_tls_CAfile = $CAFILE
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
