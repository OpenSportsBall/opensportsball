#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
# SPDX-License-Identifier: Apache-2.0
"""Enforce the split-license rules in docs/LICENSING.md.

1. Every source file has an SPDX-License-Identifier header that matches its
   top-level directory.
2. No Apache-2.0 source file references the AGPL code in processing/ or ml/.

`reuse lint` checks that licenses are declared at all; this script checks
they are the *right* ones and that the boundary holds.
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AGPL_DIRS = {"processing", "ml"}
SOURCE_SUFFIXES = {
    ".dart", ".py", ".ts", ".tsx", ".js", ".mjs", ".svelte",
    ".kt", ".java", ".swift", ".m", ".h", ".sh",
}
SPDX = re.compile(r"SPDX-License-Identifier:\s*(\S+)")
# Apache code must not import or path-reference the AGPL tree.
BOUNDARY = re.compile(
    r"osb_processing|(?:^|[\s'\"(/.])(?:processing|ml)/(?:src|data|runs)\b"
    r"|from\s+processing\b|import\s+processing\b"
)
HEADER_LINES = 10
# Vendored code keeps its upstream license, declared in REUSE.toml.
THIRD_PARTY = Path("app/third_party")


def tracked_files():
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout
    return [ROOT / line for line in out.splitlines() if line]


def expected_license(path):
    top = path.relative_to(ROOT).parts[0]
    return "AGPL-3.0-only" if top in AGPL_DIRS else "Apache-2.0"


def main():
    errors = []
    this_file = Path(__file__).resolve()
    for path in tracked_files():
        if path.suffix not in SOURCE_SUFFIXES or not path.is_file():
            continue
        rel = path.relative_to(ROOT)
        if rel.is_relative_to(THIRD_PARTY):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        head = "\n".join(text.splitlines()[:HEADER_LINES])
        want = expected_license(path)

        match = SPDX.search(head)
        if not match:
            errors.append(f"{rel}: missing SPDX-License-Identifier header (expected {want})")
        elif match.group(1) != want:
            errors.append(f"{rel}: header says {match.group(1)}, directory requires {want}")

        if want == "Apache-2.0" and path != this_file:
            for lineno, line in enumerate(text.splitlines(), 1):
                if BOUNDARY.search(line):
                    errors.append(
                        f"{rel}:{lineno}: Apache-2.0 code references AGPL code "
                        f"(docs/LICENSING.md rule 2): {line.strip()}"
                    )

    if errors:
        print("License check failed:\n  " + "\n  ".join(errors))
        return 1
    print("License check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
