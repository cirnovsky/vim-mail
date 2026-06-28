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

# Per-test wall-clock cap so a hung test fails fast (and is named) instead of
# stalling forever — e.g. a headless clipboard/X call that blocks on CI.
# `timeout` is GNU coreutils (present on Linux; macOS only as `gtimeout`, if at
# all). When absent (typical macOS), tests run uncapped as before.
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
TIMEOUT_SECS=120

pass=0
fail=0
fails=""

run() {  # name, command...
  name=$1; shift
  printf '\n--- %s ---\n' "$name"
  if [ -n "$TIMEOUT_BIN" ]; then
    # -k: SIGKILL 10s after SIGTERM, in case a hung child ignores TERM.
    "$TIMEOUT_BIN" -k 10 "$TIMEOUT_SECS" "$@"; rc=$?
  else
    "$@"; rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    pass=$((pass + 1))
  elif [ "$rc" -eq 124 ]; then
    printf '  TIMEOUT after %ss\n' "$TIMEOUT_SECS"
    fail=$((fail + 1)); fails="$fails $name(timeout)"
  else
    fail=$((fail + 1)); fails="$fails $name"
  fi
}

# Python suites (-u = unbuffered, so output survives a timeout kill on CI).
for t in "$DIR"/test_*.py; do
  [ -e "$t" ] || continue
  if [ -z "$PYTHON" ]; then
    echo "skip $(basename "$t"): python3 not found"; continue
  fi
  run "$(basename "$t")" "$PYTHON" -u "$t"
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
