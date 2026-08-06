#!/usr/bin/env python3
"""Teach the Storyrendr frontend to talk to a per-seat backend.

Upstream ``vite.config.ts`` already reads the ComfyUI endpoint from the
environment (``VITE_COMFYUI_URL`` / ``COMFYUI_API_BASE``), but the ``/api``
proxy target is hardcoded to ``http://127.0.0.1:8189``. With one backend per
seat on distinct ports, every seat's frontend would otherwise proxy to seat 0's
backend, and employees would silently share one project database.

This rewrites the hardcoded target to a ``VITE_BACKEND_URL``-driven constant,
mirroring how ``COMFY_TARGET`` is already resolved. It is idempotent, and it
fails loudly rather than silently no-op'ing if upstream changes shape, so a
broken assumption surfaces at provision time instead of as four employees
overwriting each other's work.

The right long-term home for this is upstream in storyrender-services; this
patch exists so the image doesn't require a coordinated release to work.

Usage: patch_vite_backend_url.py <path-to-vite.config.ts>
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

MARKER = "VITE_BACKEND_URL"

# Matches:  target: "http://127.0.0.1:8189",
TARGET_RE = re.compile(
    r'target:\s*["\']http://(?:127\.0\.0\.1|localhost):8189/?["\']\s*,'
)

ANCHOR = "const proxyConfig = {"

# Preferred insertion point: above proxyConfig's own doc comment, so the patch
# doesn't orphan that comment from the declaration it documents. Falls back to
# the declaration itself if upstream drops or reworks the comment.
DOC_ANCHOR = "/** Shared proxy rules"

CONST_BLOCK = """/**
 * Backend endpoint for the /api proxy.
 *
 * VITE_BACKEND_URL lets one build serve several backends, as required by the
 * multi-seat vast.ai image, where each GPU seat runs its own backend on its
 * own port. Falls back to the single-instance local default.
 */
const BACKEND_TARGET = (process.env.VITE_BACKEND_URL || "http://127.0.0.1:8189")
  .trim()
  .replace(/^["']|["']$/g, "")
  .replace(/\\/+$/, "");

"""


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"ERROR: {path} does not exist", file=sys.stderr)
        return 1

    # newline="" preserves the file's existing line endings verbatim. Without
    # it, Python rewrites every line to os.linesep on write, which turns a
    # one-line change into a whole-file rewrite.
    with path.open("r", encoding="utf-8", newline="") as fh:
        source = fh.read()

    if MARKER in source:
        print(f"[patch] {path.name} already supports {MARKER} - nothing to do.")
        return 0

    matches = TARGET_RE.findall(source)
    if len(matches) != 1:
        print(
            f"ERROR: expected exactly 1 hardcoded backend proxy target in {path}, "
            f"found {len(matches)}.\n"
            "       Upstream vite.config.ts has changed shape. Update "
            "patch_vite_backend_url.py before shipping, or seats will share a backend.",
            file=sys.stderr,
        )
        return 1

    if ANCHOR not in source:
        print(
            f"ERROR: anchor {ANCHOR!r} not found in {path}. "
            "Upstream vite.config.ts has changed shape.",
            file=sys.stderr,
        )
        return 1

    # Match the file's own line endings so the inserted block doesn't leave the
    # file with mixed newlines.
    block = CONST_BLOCK.replace("\n", "\r\n") if "\r\n" in source else CONST_BLOCK

    insert_at = DOC_ANCHOR if DOC_ANCHOR in source else ANCHOR

    patched = TARGET_RE.sub("target: BACKEND_TARGET,", source, count=1)
    patched = patched.replace(insert_at, block + insert_at, 1)

    with path.open("w", encoding="utf-8", newline="") as fh:
        fh.write(patched)
    print(f"[patch] {path.name}: /api proxy target is now driven by {MARKER}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
