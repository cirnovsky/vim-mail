#!/bin/sh
# vim-mail setup helper.
#
# The plugin itself needs no configured paths: it locates mail_store.py
# relative to its own repo and finds python3 on PATH. What lives OUTSIDE the
# repo is ~/.msmtprc (send: SMTP creds) and the getmailrc (fetch), whose
# delivery MDA must point at this machine's python3 + this clone's
# mail_store.py + your inbox dir.
#
# This script prints the config tailored to where you cloned the repo, and
# can patch an existing ~/.getmail/getmailrc's MDA path in place (backup first).
#
# Usage:
#   ./setup.sh              # print vimrc + msmtprc + getmailrc snippets
#   ./setup.sh --patch      # also offer to update ~/.getmail/getmailrc's MDA path

set -eu

# Resolve this script's directory (the repo root), following symlinks.
SELF=$0
while [ -h "$SELF" ]; do
  dir=$(cd -P "$(dirname "$SELF")" && pwd)
  SELF=$(readlink "$SELF")
  case $SELF in /*) ;; *) SELF=$dir/$SELF ;; esac
done
REPO=$(cd -P "$(dirname "$SELF")" && pwd)

PYTHON=$(command -v python3 || true)
[ -n "$PYTHON" ] || { echo "error: python3 not found on PATH" >&2; exit 1; }

STORE="$REPO/scripts/mail_store.py"
[ -f "$STORE" ] || { echo "error: mail_store.py not found at $STORE" >&2; exit 1; }

MAIL_ROOT="${MAIL_ROOT:-$HOME/Mail}"
INBOX="$MAIL_ROOT/inbox"

cat <<EOF
Detected:
  repo         $REPO
  python3      $PYTHON
  mail_store   $STORE
  inbox        $INBOX   (override by exporting MAIL_ROOT before running)

--- vimrc -------------------------------------------------------------------
Plug '$REPO'
let g:mail_root = '$MAIL_ROOT'
let g:mail_from = 'Your Name <you@gmail.com>'
" Optional overrides (auto-detected otherwise):
" let g:mail_python     = '$PYTHON'
" let g:mail_store_py   = '$STORE'
" let g:mail_getmail_rc = '~/.getmail/getmailrc'
" let g:mail_send_cmd   = 'msmtp -t'   " or 'sendmail -t' for a local MTA

--- ~/.msmtprc (mode 600) --------------------------------------------------
(msmtp does NOT allow trailing comments on a value line — keep # on its own line)
defaults
auth on
tls on

# for a 465 implicit-TLS provider: use "port 465" and "tls_starttls off"
account gmail
host smtp.gmail.com
port 587
tls_starttls on
from you@gmail.com
user you@gmail.com
password your-app-password

account default : gmail

--- ~/.getmail/getmailrc (mode 600) ----------------------------------------
[retriever]
type = SimpleIMAPSSLRetriever
server = imap.gmail.com
username = you@gmail.com
password = your-app-password

[destination]
type = MDA_external
path = $PYTHON
arguments = ("$STORE", "ingest-stdin", "$INBOX")

[options]
read_all = false
delete = false
EOF

case "${1:-}" in
  --patch)
    RC="$HOME/.getmail/getmailrc"
    echo
    if [ ! -f "$RC" ]; then
      echo "No $RC yet — create it from the snippet above (chmod 600)."
      exit 0
    fi
    if ! grep -q 'mail_store\.py' "$RC"; then
      echo "$RC has no mail_store.py MDA to patch — add one from the snippet above."
      exit 0
    fi
    echo "Current MDA in $RC:"
    grep -nE '^[[:space:]]*(path|arguments)[[:space:]]*=' "$RC"
    printf 'Replace its python + mail_store.py paths with the detected ones? [y/N] '
    read -r ans
    case "$ans" in
      y|Y)
        cp "$RC" "$RC.bak"
        # Rewrite the MDA's executable (path =) and the mail_store.py argument,
        # preserving the trailing "ingest-stdin", "<inbox>" args already there.
        awk -v py="$PYTHON" -v store="$STORE" '
          /^[[:space:]]*path[[:space:]]*=/ { print "path = " py; next }
          /^[[:space:]]*arguments[[:space:]]*=/ { sub(/"[^"]*mail_store\.py"/, "\"" store "\"") }
          { print }
        ' "$RC.bak" > "$RC"
        echo "Patched. Backup at $RC.bak. New MDA:"
        grep -nE '^[[:space:]]*(path|arguments)[[:space:]]*=' "$RC"
        ;;
      *) echo "Left $RC unchanged." ;;
    esac
    ;;
esac
