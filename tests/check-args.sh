#!/usr/bin/env bash
# Verify ComfyUI argument sanitisation.
#
# The base image exports COMFYUI_ARGS="--disable-auto-launch
# --enable-cors-header --port 18188" for its single stock instance. Because
# argparse takes the last occurrence of a flag, letting any of that reach a seat
# command would pin every seat to port 18188 — three of four would then fail to
# bind and crash-loop. These tests pin down that the seat owns its own wiring.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export COLOSSUL_LIB="$ROOT/scripts"
# shellcheck source=../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

fail() { echo "FAIL: $*"; exit 1; }
# Join sanitiser output onto one line for comparison.
san() { sanitize_comfyui_args "$@" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'; }

echo "=== 1. the base image's COMFYUI_ARGS cannot smuggle in a port ==="
got="$(san --disable-auto-launch --enable-cors-header --port 18188)"
[ "$got" = "--disable-auto-launch --enable-cors-header" ] \
    || fail "expected the port to be stripped, got: '$got'"
echo "PASS: '--port 18188' stripped, harmless flags kept"

echo ""
echo "=== 2. every seat-owned flag is stripped, space and equals forms ==="
for f in --port --listen --cuda-device --database-url \
         --input-directory --output-directory --temp-directory \
         --user-directory --base-directory; do
    got="$(san "$f" somevalue --highvram)"
    [ "$got" = "--highvram" ] || fail "'$f somevalue' not stripped cleanly, got: '$got'"
    got="$(san "$f=somevalue" --highvram)"
    [ "$got" = "--highvram" ] || fail "'$f=somevalue' not stripped cleanly, got: '$got'"
done
echo "PASS: all 9 owned flags stripped in both forms"

echo ""
echo "=== 3. user flags survive untouched ==="
got="$(san --highvram --preview-method auto --disable-smart-memory)"
[ "$got" = "--highvram --preview-method auto --disable-smart-memory" ] \
    || fail "user args were altered: '$got'"
echo "PASS: unrelated args pass through unchanged"

echo ""
echo "=== 4. valueless owned flag followed by another flag ==="
# --listen takes an optional value; "--listen --highvram" must not eat --highvram.
got="$(san --listen --highvram)"
[ "$got" = "--highvram" ] || fail "optional-value flag consumed the next flag: '$got'"
echo "PASS: optional-value flags don't swallow the following flag"

echo ""
echo "=== 5. empty input produces ZERO arguments, not one empty one ==="
# Deliberately checked as an ARRAY, exactly as seat-comfyui.sh consumes it.
# An earlier version of this test joined the output into a string first, which
# hid a real bug: the function emitted one empty line, mapfile turned it into a
# single empty-string argument, and argparse rejects a stray empty arg — so
# every seat's ComfyUI failed to start with no extras set, i.e. by default.
mapfile -t EMPTY < <(sanitize_comfyui_args)
[ "${#EMPTY[@]}" -eq 0 ] \
    || fail "expected 0 arguments, got ${#EMPTY[@]}: $(printf '%q ' "${EMPTY[@]}")"
mapfile -t ONE < <(sanitize_comfyui_args --highvram)
[ "${#ONE[@]}" -eq 1 ] || fail "expected 1 argument, got ${#ONE[@]}"
# Stripping the only argument must also leave nothing behind.
mapfile -t STRIPPED < <(sanitize_comfyui_args --port 18188)
[ "${#STRIPPED[@]}" -eq 0 ] \
    || fail "stripping the only arg left ${#STRIPPED[@]} behind: $(printf '%q ' "${STRIPPED[@]}")"
echo "PASS: 0 args -> 0 elements; 1 arg -> 1; fully-stripped -> 0"

echo ""
echo "=== 6. the seat script never passes COMFYUI_ARGS through ==="
# A regression here silently re-pins every seat to port 18188.
if grep -qE '\$\{?COMFYUI_ARGS' "$ROOT/scripts/seat-comfyui.sh"; then
    fail "seat-comfyui.sh references COMFYUI_ARGS; it must use COLOSSUL_COMFYUI_ARGS"
fi
grep -q 'COLOSSUL_COMFYUI_ARGS' "$ROOT/scripts/seat-comfyui.sh" \
    || fail "seat-comfyui.sh should read COLOSSUL_COMFYUI_ARGS for extras"
echo "PASS: seat script uses COLOSSUL_COMFYUI_ARGS, not the base image's COMFYUI_ARGS"

echo ""
echo "=== 7. each seat gets its own ComfyUI database ==="
# ComfyUI derives its SQLite path from __file__, not --user-directory, so all
# seats would otherwise share <install>/user/comfyui.db.
grep -q -- '--database-url' "$ROOT/scripts/seat-comfyui.sh" \
    || fail "seat-comfyui.sh must pass --database-url or seats share one SQLite file"
echo "PASS: --database-url is passed per seat"

echo ""
echo "ALL ARGUMENT CHECKS PASSED"
