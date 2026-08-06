#!/usr/bin/env bash
# Verify the vite.config.ts patch against a real Storyrendr checkout.
#
# The patch is the one place this image reaches into upstream source, so it is
# also the one place a silent failure would be expensive: if it stopped working
# without complaining, all four seats would proxy /api to seat 0's backend and
# employees would share one project database.
#
# Usage:
#   tests/check-patch.sh [path/to/colossul-frontend]
#
# Defaults to a sibling storyrendr-services checkout.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/../scripts/patches/patch_vite_backend_url.py"

EXPLICIT=0
[ $# -gt 0 ] && EXPLICIT=1
FRONTEND="${1:-$HERE/../../storyrendr-services/colossul-frontend}"
CONFIG="$FRONTEND/vite.config.ts"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "python3 not found; set PYTHON="; exit 1; }

if [ ! -f "$CONFIG" ]; then
    # storyrender-services is private, so CI and fresh clones won't have it.
    # Skip rather than fail there, but never skip a path someone asked for
    # explicitly - that's a typo they need to hear about.
    if [ "$EXPLICIT" = "1" ]; then
        echo "ERROR: no vite.config.ts at $CONFIG"
        exit 1
    fi
    echo "SKIP: no Storyrendr checkout at $FRONTEND"
    echo "      These checks need the private repo. Run locally beside a checkout,"
    echo "      or pass the path: tests/check-patch.sh /path/to/colossul-frontend"
    exit 0
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cp "$CONFIG" "$T/vite.config.ts"

fail() { echo "FAIL: $*"; exit 1; }

echo "=== 1. apply patch ==="
"$PY" "$PATCH" "$T/vite.config.ts"

echo ""
echo "=== 2. patched file is valid TypeScript ==="
ESB="$(find "$FRONTEND/node_modules/@esbuild" -type f -name esbuild 2>/dev/null | head -1 || true)"
if [ -n "$ESB" ] && "$ESB" --version >/dev/null 2>&1; then
    "$ESB" --log-level=warning "$T/vite.config.ts" > "$T/out.js" || fail "esbuild could not parse the patched config"
    grep -q 'target: BACKEND_TARGET' "$T/out.js" || fail "BACKEND_TARGET is not wired into the proxy"
    echo "PASS: parses, and /api proxies to BACKEND_TARGET"
else
    echo "SKIP: no runnable esbuild in $FRONTEND/node_modules (run npm install to enable)"
fi

echo ""
echo "=== 3. env override semantics ==="
cat > "$T/probe.mjs" <<'EOF'
const BACKEND_TARGET = (process.env.VITE_BACKEND_URL || "http://127.0.0.1:8189")
  .trim().replace(/^["']|["']$/g, "").replace(/\/+$/, "");
console.log(BACKEND_TARGET);
EOF
if command -v node >/dev/null 2>&1; then
    [ "$(node "$T/probe.mjs")" = "http://127.0.0.1:8189" ] \
        || fail "wrong default backend target"
    [ "$(VITE_BACKEND_URL='http://127.0.0.1:18389/' node "$T/probe.mjs")" = "http://127.0.0.1:18389" ] \
        || fail "override or trailing-slash normalisation broken"
    echo "PASS: default and per-seat override both resolve correctly"
else
    echo "SKIP: node not available"
fi

echo ""
echo "=== 4. idempotent across re-provisioning ==="
"$PY" "$PATCH" "$T/vite.config.ts"
cp "$T/vite.config.ts" "$T/again.ts"
"$PY" "$PATCH" "$T/again.ts" >/dev/null
diff -q "$T/vite.config.ts" "$T/again.ts" >/dev/null || fail "patch is not stable across runs"
echo "PASS: re-running changes nothing"

echo ""
echo "=== 5. refuses to patch a drifted upstream ==="
sed 's|target: "http://127.0.0.1:8189",|target: SOMETHING_ELSE,|' "$CONFIG" > "$T/drifted.ts"
if "$PY" "$PATCH" "$T/drifted.ts" 2>/dev/null; then
    fail "patch silently accepted a config whose proxy target had moved"
fi
echo "PASS: drift is a hard error, not a silent no-op"

echo ""
echo "=== 6. line endings preserved ==="
if file "$T/vite.config.ts" | grep -q CRLF; then fail "CRLF introduced into an LF file"; fi
echo "PASS: line endings untouched"

echo ""
echo "ALL PATCH CHECKS PASSED"
