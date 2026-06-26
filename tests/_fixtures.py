"""Test fixtures live one directory per case under tests/fixtures/<case>/, so a
case can carry static assets (a real raw.eml, expected outputs, etc.). Helper
to load a case's raw message bytes.

Not a test (filename doesn't match test_*), so run.sh won't execute it.
"""

from pathlib import Path

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def case_dir(case: str) -> Path:
    return FIXTURES / case


def raw(case: str) -> bytes:
    return (FIXTURES / case / "raw.eml").read_bytes()
