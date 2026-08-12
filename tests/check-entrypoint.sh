#!/usr/bin/env bash
# The entrypoint sizes PORTAL_CONFIG to the machine before the base image reads
# it. Two things matter, in this order:
#
#   1. it must ALWAYS exec the base entrypoint — an entrypoint that exits is a
#      dead instance, and on Vast that is a rental someone is paying for;
#   2. it should get the seat count right.
#
# (1) outranks (2): a portal with a few dead links is cosmetic, a container that
# will not start is not.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
EP="$ROOT/scripts/entrypoint.sh"

# A fake /opt tree: stub base entrypoint that records what it saw, and a stub
# nvidia-smi whose GPU count we control.
mkdir -p "$T/opt/instance-tools/bin" "$T/bin"
cat > "$T/opt/instance-tools/bin/entrypoint.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\${PORTAL_CONFIG:-<unset>}" > "$T/seen-portal.txt"
printf 'ARGS:%s\n' "\$*" >> "$T/seen-portal.txt"
echo BASE_ENTRYPOINT_RAN
EOF
chmod +x "$T/opt/instance-tools/bin/entrypoint.sh"
cat > "$T/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-L" ] || exit 0
for ((i = 0; i < ${FAKE_GPUS:-0}; i++)); do echo "GPU $i: NVIDIA RTX 5090 (UUID: GPU-$i)"; done
EOF
chmod +x "$T/bin/nvidia-smi"

# A copy of the real script with the base path pointed at the stub.
sed "s#^BASE_ENTRYPOINT=.*#BASE_ENTRYPOINT=$T/opt/instance-tools/bin/entrypoint.sh#" \
    "$EP" > "$T/entrypoint.sh"
chmod +x "$T/entrypoint.sh"

run() {  # run <env...> -- prints the stub's stdout
    rm -f "$T/seen-portal.txt"
    env -i PATH="$T/bin:$PATH" HOME="$HOME" \
        COLOSSUL_LIB="$ROOT/scripts" WORKSPACE="$T/w" COLOSSUL_ASSETS_ROOT="$T/a" \
        "$@" bash "$T/entrypoint.sh" some-arg 2>"$T/err.txt"
}
mkdir -p "$T/w" "$T/a"
seats_in_portal() { grep -o 'Seat [0-9]* Storyrendr' "$T/seen-portal.txt" | wc -l; }

echo "=== 1. PORTAL_CONFIG is sized to the GPU count ==="
for n in 1 2 4 8; do
    out="$(run FAKE_GPUS="$n" PORTAL_CONFIG="placeholder")"
    grep -q BASE_ENTRYPOINT_RAN <<< "$out" || fail "base entrypoint did not run for $n GPUs"
    got="$(seats_in_portal)"
    [ "$got" = "$n" ] || fail "$n GPUs should give $n portal seats, got $got"
    grep -q 'Instance Portal' "$T/seen-portal.txt" || fail "portal entry itself was dropped"
    grep -q 'Jupyter' "$T/seen-portal.txt" || fail "Jupyter entry was dropped"
    printf '  %d GPU(s) -> %s seat(s) in PORTAL_CONFIG\n' "$n" "$got"
done
echo "PASS: portal matches the machine"

echo ""
echo "=== 2. arguments are passed through untouched ==="
run FAKE_GPUS=1 >/dev/null
grep -q 'ARGS:some-arg' "$T/seen-portal.txt" || fail "arguments were not forwarded"
echo "PASS: argv preserved"

echo ""
echo "=== 3. it ALWAYS execs the base entrypoint ==="
# Every way sizing can fail must still start the container.
out="$(run FAKE_GPUS=0)"                       # no GPUs
grep -q BASE_ENTRYPOINT_RAN <<< "$out" || fail "no GPUs stopped the container starting"
out="$(env -i PATH="/usr/bin:/bin" HOME="$HOME" COLOSSUL_LIB=/nonexistent \
        bash "$T/entrypoint.sh" 2>/dev/null)"  # no colossul tree at all
grep -q BASE_ENTRYPOINT_RAN <<< "$out" || fail "a missing /opt/colossul stopped the container starting"
out="$(run FAKE_GPUS=2 COLOSSUL_PORTAL_AUTOSIZE=0)"
grep -q BASE_ENTRYPOINT_RAN <<< "$out" || fail "autosize=0 stopped the container starting"
echo "PASS: starts under every failure mode"

echo ""
echo "=== 4. opting out keeps the image's own PORTAL_CONFIG ==="
run FAKE_GPUS=2 COLOSSUL_PORTAL_AUTOSIZE=0 PORTAL_CONFIG="UNTOUCHED" >/dev/null
grep -qx 'UNTOUCHED' "$T/seen-portal.txt" \
    || fail "COLOSSUL_PORTAL_AUTOSIZE=0 should leave PORTAL_CONFIG alone: $(head -1 "$T/seen-portal.txt")"
echo "PASS: opt-out respected"

echo ""
echo "=== 5. a broken generator leaves the fallback in place ==="
# Half a config would leave the portal with NO entries — worse than surplus ones.
cp "$ROOT/scripts/bin/colossul-portal-config" "$T/pc.bak"
mkdir -p "$T/fakelib/bin" "$T/fakelib/lib"
cp "$ROOT/scripts/lib/common.sh" "$T/fakelib/lib/"
printf '#!/usr/bin/env bash\necho "PORTAL_CONFIG=\\"garbage\\""\n' > "$T/fakelib/bin/colossul-portal-config"
chmod +x "$T/fakelib/bin/colossul-portal-config"
run FAKE_GPUS=2 COLOSSUL_LIB="$T/fakelib" PORTAL_CONFIG="THE_FALLBACK" >/dev/null
grep -qx 'THE_FALLBACK' "$T/seen-portal.txt" \
    || fail "a malformed generated config was used instead of the fallback: $(head -1 "$T/seen-portal.txt")"
grep -qi 'could not size' "$T/err.txt" || fail "should say it kept the default"
echo "PASS: malformed output is rejected, fallback kept"

echo ""
echo "=== 6. the Dockerfile actually uses it ==="
grep -q 'ENTRYPOINT \["/opt/colossul/entrypoint.sh"\]' "$ROOT/Dockerfile" \
    || fail "Dockerfile does not set our entrypoint — none of this would run"
grep -q 'COPY scripts/ /opt/colossul/' "$ROOT/Dockerfile" \
    || fail "entrypoint.sh must be copied into the image"
# The fallback must still cover the maximum, for launch modes that skip it.
MAXSEATS="$(grep -oE '^ *MAX_SEATS=[0-9]+' "$ROOT/Dockerfile" | grep -oE '[0-9]+' | head -1)"
PORTAL="$(grep -m1 '^ENV PORTAL_CONFIG=' "$ROOT/Dockerfile")"
grep -q "Seat $((MAXSEATS - 1)) ComfyUI" <<< "$PORTAL" \
    || fail "the fallback PORTAL_CONFIG must still cover all $MAXSEATS seats"
echo "PASS: wired up, fallback covers $MAXSEATS seats"

echo ""
echo "ALL ENTRYPOINT CHECKS PASSED"
