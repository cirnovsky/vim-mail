#!/bin/sh
# vim-mail setup helper.
#
# The plugin itself needs no configured paths: it locates mail_store.py
# relative to its own repo and finds python3 on PATH. The one thing that
# lives OUTSIDE the repo is ~/.fetchmailrc, whose `mda` line must point at
# this machine's python3 + this clone's mail_store.py + your inbox dir.
#
# This script prints the config tailored to where you cloned the repo, and
# can patch an existing ~/.fetchmailrc's mda line in place (backup first).
#
# Usage:
#   ./setup.sh              # print vimrc + fetchmailrc snippets
#   ./setup.sh --patch      # also offer to update ~/.fetchmailrc's mda line

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

MDA="$PYTHON $STORE ingest-stdin $INBOX"

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
" let g:mail_python   = '$PYTHON'
" let g:mail_store_py = '$STORE'

--- ~/.fetchmailrc (mode 600) ----------------------------------------------
poll imap.gmail.com protocol IMAP
    user "you@gmail.com" with password "your-app-password" is "$(id -un)" here
    ssl
    mda "$MDA"
EOF

case "${1:-}" in
  --patch)
    RC="$HOME/.fetchmailrc"
    echo
    if [ ! -f "$RC" ]; then
      echo "No $RC yet — create it from the snippet above (chmod 600)."
      exit 0
    fi
    if ! grep -q 'mail_store\.py' "$RC"; then
      echo "$RC has no mail_store.py mda line to patch — add one from the snippet above."
      exit 0
    fi
    echo "Current mda line in $RC:"
    grep -n 'mda' "$RC" | sed 's/password "[^"]*"/password "***"/g'
    printf 'Replace its python+mail_store path with the detected ones? [y/N] '
    read -r ans
    case "$ans" in
      y|Y)
        cp "$RC" "$RC.bak"
        # Rewrite only the python3 ... mail_store.py portion of the mda command,
        # preserving the trailing "ingest-stdin <inbox>" target already there.
        awk -v repl="$PYTHON $STORE" '
          /mda/ && /mail_store\.py/ {
            sub(/[^ "]*python3[^ ]* [^ ]*mail_store\.py/, repl)
          }
          { print }
        ' "$RC.bak" > "$RC"
        echo "Patched. Backup at $RC.bak. New line:"
        grep -n 'mda' "$RC" | sed 's/password "[^"]*"/password "***"/g'
        ;;
      *) echo "Left $RC unchanged." ;;
    esac
    ;;
esac
