#!/usr/bin/env bash
# Seat count comes from the machine's GPUs. Getting this wrong is expensive in
# both directions: too few seats wastes a rented GPU per artist, too many puts
# two artists on one card and neither knows why everything is slow.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# A stub nvidia-smi, so the count is controllable without hardware.
mkdir -p "$T/bin"
cat > "$T/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-L" ] || exit 0
n="${FAKE_GPUS:-0}"
[ "$n" = "fail" ] && exit 1
for ((i = 0; i < n; i++)); do
    echo "GPU $i: NVIDIA GeForce RTX 5090 (UUID: GPU-fake-$i)"
done
EOF
chmod +x "$T/bin/nvidia-smi"

seats() {  # seats <env assignments...>
    env -i PATH="$T/bin:$PATH" HOME="$HOME" COLOSSUL_LIB="$ROOT/scripts" \
        WORKSPACE="$T/w" COLOSSUL_ASSETS_ROOT="$T/a" "$@" \
        bash -c 'source "$COLOSSUL_LIB/lib/common.sh"; num_seats' 2>/dev/null
}
# Warnings only. Captured to a file rather than juggling fd order inline, which
# is easy to get subtly backwards.
warns() {
    env -i PATH="$T/bin:$PATH" HOME="$HOME" COLOSSUL_LIB="$ROOT/scripts" \
        WORKSPACE="$T/w" COLOSSUL_ASSETS_ROOT="$T/a" "$@" \
        bash -c 'source "$COLOSSUL_LIB/lib/common.sh"; num_seats' \
        >/dev/null 2>"$T/warn.txt"
    cat "$T/warn.txt"
}
mkdir -p "$T/w" "$T/a"

echo "=== 1. one seat per GPU, by default ==="
for n in 1 2 3 4 6 8; do
    got="$(seats FAKE_GPUS="$n")"
    [ "$got" = "$n" ] || fail "$n GPUs should give $n seats, got '$got'"
    printf '  %d GPU(s) -> %s seat(s)\n' "$n" "$got"
done
echo "PASS: scales with the machine"

echo ""
echo "=== 2. capped, so an unusual machine cannot blow past the port math ==="
got="$(seats FAKE_GPUS=16)"
[ "$got" = "8" ] || fail "16 GPUs should cap at MAX_SEATS=8, got '$got'"
warns FAKE_GPUS=16 | grep -qi 'capping' || fail "capping should be reported, not silent"
got="$(seats FAKE_GPUS=16 MAX_SEATS=10)"
[ "$got" = "10" ] || fail "MAX_SEATS should be raisable, got '$got'"
echo "  16 GPUs -> 8 seats (MAX_SEATS=10 -> 10)"
echo "PASS: capped and adjustable"

echo ""
echo "=== 3. an explicit NUM_SEATS still wins ==="
got="$(seats FAKE_GPUS=8 NUM_SEATS=2)"
[ "$got" = "2" ] || fail "explicit NUM_SEATS=2 should win over 8 GPUs, got '$got'"
echo "  8 GPUs, NUM_SEATS=2 -> 2"
# Oversubscribing is allowed but must be called out: otherwise it reads as
# broken GPU pinning rather than a deliberate choice.
got="$(seats FAKE_GPUS=1 NUM_SEATS=4)"
[ "$got" = "4" ] || fail "explicit oversubscription should be honoured, got '$got'"
warns FAKE_GPUS=1 NUM_SEATS=4 | grep -qi 'share' \
    || fail "sharing one GPU across seats should be warned about"
echo "  1 GPU, NUM_SEATS=4 -> 4, with a warning about sharing"
echo "PASS: explicit wins, loudly"

echo ""
echo "=== 4. no GPU at all still yields a usable instance ==="
got="$(seats FAKE_GPUS=0)"
[ "$got" = "1" ] || fail "no GPUs should still give 1 seat, got '$got'"
got="$(seats FAKE_GPUS=fail)"
[ "$got" = "1" ] || fail "a failing nvidia-smi should give 1 seat, got '$got'"
got="$(env -i PATH="/usr/bin:/bin" HOME="$HOME" COLOSSUL_LIB="$ROOT/scripts" \
        WORKSPACE="$T/w" COLOSSUL_ASSETS_ROOT="$T/a" \
        bash -c 'source "$COLOSSUL_LIB/lib/common.sh"; num_seats' 2>/dev/null)"
[ "$got" = "1" ] || fail "no nvidia-smi at all should give 1 seat, got '$got'"
echo "  0 GPUs / nvidia-smi failing / nvidia-smi absent -> 1 seat each"
echo "PASS: degrades to a working single seat"

echo ""
echo "=== 5. garbage is rejected without taking the instance down ==="
for bad in abc -3 3.5; do
    got="$(seats FAKE_GPUS=4 NUM_SEATS="$bad")"
    [ "$got" = "1" ] || fail "NUM_SEATS='$bad' should fall back to 1, got '$got'"
done
echo "  'abc', '-3', '3.5' all fall back to 1"
echo "PASS: bad input cannot wedge provisioning"

echo ""
echo "=== 6. every reachable count has a portal entry ==="
# The image ships portal entries for MAX_SEATS. A seat with no entry has no
# tunnel and therefore no URL — it would run and be silently unreachable.
PORTAL="$(grep -m1 '^ENV PORTAL_CONFIG=' "$ROOT/Dockerfile")"
for ((i = 0; i < 8; i++)); do
    grep -q "Seat $i Storyrendr" <<< "$PORTAL" \
        || fail "no portal entry for seat $i: an 8-GPU box would have unreachable seats"
    grep -q "Seat $i ComfyUI" <<< "$PORTAL" || fail "no ComfyUI portal entry for seat $i"
done
echo "  portal entries present for seats 0..7"
grep -q 'NUM_SEATS=auto' "$ROOT/Dockerfile" || fail "the image should default to auto"
echo "PASS: portal covers the maximum, image defaults to auto"

echo ""
echo "ALL SEAT COUNT CHECKS PASSED"
