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
echo "=== 6. the access summary an operator actually reads ==="
# Printed last at boot and by `colossul-seats urls`. If it is wrong or crashes,
# the operator has no assembled way to hand out links.
tunnel_map() { printf '1111\thttps://portal.trycloudflare.com\n8190\thttps://seat0.trycloudflare.com\n'; }
export PUBLIC_IPADDR=203.0.113.10 VAST_TCP_PORT_8200=40001
export OPEN_BUTTON_TOKEN=tok_generated_value

out="$(print_access_summary 2)" || fail "print_access_summary exited non-zero"
grep -q 'username:  vastai'        <<< "$out" || fail "username missing"
grep -q 'tok_generated_value'      <<< "$out" || fail "password missing"
grep -q 'https://portal.trycloudflare.com' <<< "$out" || fail "portal URL missing"
grep -q 'https://seat0.trycloudflare.com'  <<< "$out" || fail "seat 0 should use its tunnel"
grep -q 'https://203.0.113.10:40001'       <<< "$out" || fail "seat 1 should fall back to the direct address"
grep -q "$ASSETS_ROOT/models"      <<< "$out" || fail "model store path missing"
grep -q '?token='                  <<< "$out" || fail "the prompt-skipping tip should be included"
echo "  tunnel where available, direct address otherwise, credentials present"

# An operator-set password must win over the generated token.
export WEB_PASSWORD='chosen-password'
out="$(print_access_summary 1)"
grep -q 'password:  chosen-password' <<< "$out" || fail "WEB_PASSWORD should take precedence"
grep -q 'tok_generated_value'        <<< "$out" && fail "the generated token should not appear once WEB_PASSWORD is set"
echo "  WEB_PASSWORD overrides the generated token"

# Worst case: no tunnels, no public address. Must still print, not crash.
tunnel_map() { :; }
unset PUBLIC_IPADDR VAST_TCP_PORT_8200
out="$(print_access_summary 2)" || fail "summary crashed with no tunnels and no public IP"
grep -q 'see IP & Port Info' <<< "$out" || fail "should degrade to an actionable placeholder"
echo "  degrades to a placeholder rather than an empty or broken URL"
echo "PASS: access summary is correct and never leaves the operator stranded"

echo ""
echo "=== 7. links are pre-authenticated, and the early box works ==="
# Every artist-facing link must carry ?token= so one click logs straight in;
# a bare link puts a non-technical user in front of a 64-char password prompt.
export WEB_PASSWORD='pw123'
tunnel_map() { printf '1111\thttps://portal.try\n8190\thttps://seat0.try\n'; }
out="$(print_access_summary 1)"
grep -q 'https://portal.try/?token=pw123' <<< "$out" || fail "portal link not pre-authenticated"
grep -q 'https://seat0.try/?token=pw123'  <<< "$out" || fail "seat link not pre-authenticated"
echo "  summary links carry ?token="

out="$(print_early_access 0)" || fail "print_early_access exited non-zero"
grep -q 'CONTROL PANEL IS UP' <<< "$out" || fail "early box missing its banner"
grep -q 'https://portal.try/?token=pw123' <<< "$out" || fail "early box link not pre-authenticated"
echo "  early box prints a one-click portal link"

# No tunnel and no public address: must degrade to a placeholder, never hang
# (timeout 0) and never emit a bogus tokenised placeholder.
tunnel_map() { :; }
unset PUBLIC_IPADDR 2>/dev/null || true
out="$(print_early_access 0)" || fail "early box crashed with no tunnel"
grep -q 'see IP & Port Info' <<< "$out" || fail "early box should degrade to a placeholder"
grep -q '<port 1111.*?token=' <<< "$out" && fail "placeholder must not be tokenised"
echo "  degrades to a placeholder without hanging"
echo "PASS: one-click links, early announcement, graceful degradation"

echo ""
echo "ALL TUNNEL CHECKS PASSED"
