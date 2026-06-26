#!/bin/sh
# Run the whole vim-mail test suite.
#
#   ./tests/run.sh          # or `make test` from the repo root
#
# Auto-discovers tests/test_*.py (Python) and tests/test_*.vim (headless Vim).
# Exit 0 only if every test passes. Self-locating — works wherever cloned.

set -u

DIR=$(cd -P "$(dirname "$0")" && pwd)   # tests/
REPO=$(dirname "$DIR")

PYTHON=$(command -v python3 || true)
VIM=$(command -v vim || true)

pass=0
fail=0
fails=""

run() {  # name, command...
  name=$1; shift
  printf '\n--- %s ---\n' "$name"
  if "$@"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    fails="$fails $name"
  fi
}

# Python suites.
for t in "$DIR"/test_*.py; do
  [ -e "$t" ] || continue
  if [ -z "$PYTHON" ]; then
    echo "skip $(basename "$t"): python3 not found"; continue
  fi
  run "$(basename "$t")" "$PYTHON" "$t"
done

# Headless Vim suites (exit 0 = pass, nonzero = fail via cquit).
for t in "$DIR"/test_*.vim; do
  [ -e "$t" ] || continue
  if [ -z "$VIM" ]; then
    echo "skip $(basename "$t"): vim not found"; continue
  fi
  run "$(basename "$t")" "$VIM" -u NONE -N -es -S "$t"
done

printf '\n========================================\n'
if [ "$fail" -eq 0 ]; then
  echo "ALL PASS ($pass suites)"
  exit 0
else
  echo "FAILED:$fails  ($pass passed, $fail failed)"
  exit 1
fi
