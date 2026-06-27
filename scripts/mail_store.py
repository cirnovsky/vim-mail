#!/usr/bin/env python3
"""Explode RFC822 messages into a one-folder-per-message mail store.

<mailbox-dir>/<UTC-timestamp>_<8-hex msgid hash>/
    raw.eml              original bytes, untouched
    meta                 From/To/Subject/Date, one per line
    body.txt             decoded plain-text body (or HTML->text fallback)
    body.html            present only if an HTML part existed
    attachments/<name>   every non-body part, decoded, original filename

The directory name doubles as the dedup key: ingest_one() skips messages
whose target directory already exists, which is what makes migrate_mbox()
resumable without a separate progress file.
"""

import os
import sys

# Real code lives in the mailstore/ package next to this entry point.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mailstore.cli import main

if __name__ == "__main__":
    main()
