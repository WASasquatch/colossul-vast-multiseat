#!/usr/bin/env bash
# Verify the tunnel URL parser used by `colossul-seats urls`.
#
# The base image's tunnel_manager opens a Cloudflare quick tunnel per portal
# entry, so each seat has a public URL — but the endpoint only exists on a live
# instance. These tests exercise the real parser from lib/common.sh against
# recorded payloads, so a regression shows up here rather than as an operator
# handing an employee the wrong seat's URL.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export COLOSSUL_LIB="$ROOT/scripts"
# shellcheck source=../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

fail() { echo "FAIL: $*"; exit 1; }

MAP="$(parse_tunnel_json <<'EOF'
[
 {"targetUrl":"localhost:1111","tunnelUrl":"https://alpha-beta-one-two.trycloudflare.com"},
 {"targetUrl":"localhost:8080","tunnelUrl":"https://jupyter-words-here-x.trycloudflare.com"},
 {"targetUrl":"localhost:8190","tunnelUrl":"https://seat-zero-words-aa.trycloudflare.com"},
 {"targetUrl":"localhost:8191","tunnelUrl":"https://seat-zero-comfy-bb.trycloudflare.com"},
 {"targetUrl":"localhost:8200","tunnelUrl":"https://seat-one-words-cc.trycloudflare.com"},
 {"targetUrl":"localhost:8210","tunnelUrl":"https://seat-two-words-dd.trycloudflare.com"},
 {"targetUrl":"localhost:8220","tunnelUrl":"https://seat-three-word-ee.trycloudflare.com"}
]
EOF
)"

lookup() { printf '%s\n' "$MAP" | awk -v p="$1" -F'\t' '$1==p {print $2; exit}'; }

echo "=== 1. each seat resolves to its OWN tunnel ==="
for pair in "0 seat-zero-words-aa" "1 seat-one-words-cc" \
            "2 seat-two-words-dd" "3 seat-three-word-ee"; do
    set -- $pair
    port="$(frontend_ext "$1")"
    got="$(lookup "$port")"
    [ "$got" = "https://$2.trycloudflare.com" ] \
        || fail "seat $1 (port $port) resolved to '$got'"
    echo "  seat $1  port $port  -> $got"
done
echo "PASS: no cross-seat mix-up"

echo ""
echo "=== 2. ComfyUI and frontend tunnels are distinct per seat ==="
[ "$(lookup "$(frontend_ext 0)")" != "$(lookup "$(comfyui_ext 0)")" ] \
    || fail "seat 0 frontend and ComfyUI resolved to the same tunnel"
echo "PASS: seat 0 frontend != seat 0 ComfyUI"

echo ""
echo "=== 3. a seat without a tunnel yields empty, never a wrong URL ==="
[ -z "$(lookup 8230)" ] || fail "an unmapped port returned '$(lookup 8230)'"
echo "PASS: unmapped port -> empty (caller falls back to the direct address)"

echo ""
echo "=== 4. targetUrl with a scheme still parses (colon before the port) ==="
got="$(printf '%s' '[{"targetUrl":"http://localhost:8190/","tunnelUrl":"https://x-y-z-w.trycloudflare.com"}]' \
        | parse_tunnel_json | awk -F'\t' '$1==8190 {print $2}')"
[ "$got" = "https://x-y-z-w.trycloudflare.com" ] || fail "scheme form parsed as '$got'"
echo "PASS: 'http://localhost:8190/' -> port 8190"

echo ""
echo "=== 5. malformed input degrades quietly ==="
for bad in '' 'not json' '{}' '[]' '[{"targetUrl":null,"tunnelUrl":null}]' '[{"nope":1}]'; do
    out="$(printf '%s' "$bad" | parse_tunnel_json)" \
        || fail "parser returned non-zero on input: $bad"
    [ -z "$out" ] || fail "expected no output for '$bad', got '$out'"
done
echo "PASS: 6 malformed payloads produce no output and no error"

echo ""
echo "ALL TUNNEL CHECKS PASSED"
