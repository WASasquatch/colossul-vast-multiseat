#!/usr/bin/env bash
# Volume detection: a Vast volume must be used automatically when present, and
# must never be claimed when it isn't. Both failures are expensive — the first
# silently puts a 414 GB library and every artist's saved work on disk that dies
# with the instance; the second promises durability that does not exist.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T" /dev/shm/colossul-voltest' EXIT
fail() { echo "FAIL: $*"; exit 1; }

paths_with() {  # paths_with <env assignments...> -> prints ROOT and ASSETS
    env -i PATH="$PATH" HOME="$HOME" COLOSSUL_LIB="$ROOT/scripts" "$@" \
        bash -c 'source "$COLOSSUL_LIB/lib/common.sh"
                 echo "root=$COLOSSUL_ROOT"
                 echo "assets=$ASSETS_ROOT"
                 echo "vol=${COLOSSUL_VOLUME_ROOT:-}"'
}

echo "=== 1. no volume: everything falls back to the workspace ==="
mkdir -p "$T/w"
out="$(paths_with WORKSPACE="$T/w")"
grep -q "root=$T/w/colossul" <<< "$out" || fail "expected the workspace fallback: $out"
grep -q "assets=$T/w/ComfyUI_Assets" <<< "$out" || fail "expected the workspace fallback: $out"
grep -q '^vol=$' <<< "$out" || fail "claimed a volume when none is attached: $out"
echo "  root and assets under the workspace, no volume claimed"
echo "PASS: correct without a volume"

echo ""
echo "=== 2. a plain directory is NOT mistaken for a volume ==="
# The dangerous false positive: /data existing on container disk would promise
# durability it cannot deliver.
mkdir -p "$T/w/fakevol"
out="$(paths_with WORKSPACE="$T/w" COLOSSUL_VOLUME="$T/w/fakevol")"
grep -q '^vol=$' <<< "$out" \
    || fail "a directory on the SAME filesystem as / was treated as a volume: $out"
grep -q "assets=$T/w/ComfyUI_Assets" <<< "$out" || fail "should have fallen back: $out"
echo "  same-filesystem directory correctly rejected"
echo "PASS: no false positives"

echo ""
echo "=== 3. a real separate mount IS used automatically ==="
# /dev/shm is a different filesystem, which is what a volume looks like to df.
VOL=/dev/shm/colossul-voltest
mkdir -p "$VOL"
out="$(paths_with WORKSPACE="$T/w" COLOSSUL_VOLUME="$VOL")"
grep -q "vol=$VOL" <<< "$out" || fail "did not detect the separate mount: $out"
grep -q "root=$VOL/colossul" <<< "$out" || fail "seat data should default to the volume: $out"
grep -q "assets=$VOL/ComfyUI_Assets" <<< "$out" || fail "models should default to the volume: $out"
echo "  both seat data and models moved to the volume with no configuration"
echo "PASS: volume-first by default"

echo ""
echo "=== 3b. a volume mounted AS the workspace is recognised ==="
# Vast volumes can replace /workspace rather than appearing at /data. The paths
# are then already correct, but persistence must still be reported correctly —
# keying off the mount point would tell a perfectly safe instance that all its
# data dies with it, which is the worst possible false alarm.
mkdir -p "$VOL/ws"
out="$(paths_with WORKSPACE="$VOL/ws")"
grep -q "vol=$VOL/ws" <<< "$out" \
    || fail "a volume mounted as the workspace was not recognised as persistent: $out"
grep -q "assets=$VOL/ws/ComfyUI_Assets" <<< "$out" || fail "paths should be unchanged: $out"
echo "  workspace-as-volume detected, default paths unchanged"

# …and the persistence notice must agree with it.
out="$(env -i PATH="$PATH" HOME="$HOME" COLOSSUL_LIB="$ROOT/scripts" \
        WORKSPACE="$VOL/ws" bash -c \
        'source "$COLOSSUL_LIB/lib/common.sh"; print_model_status')"
grep -q 'models    on a separate volume' <<< "$out" \
    || fail "storage notice contradicts detection for workspace-as-volume: $out"
grep -q 'CONTAINER DISK' <<< "$out" \
    && fail "reported data as doomed when it is on a volume: $out"
echo "  storage notice agrees: survives instance destroy"
echo "PASS: persistence is decided by filesystem, not by mount point"

echo ""
echo "=== 4. explicit settings still win ==="
out="$(paths_with WORKSPACE="$T/w" COLOSSUL_VOLUME="$VOL" \
        COLOSSUL_ROOT=/pinned/root COLOSSUL_ASSETS_ROOT=/pinned/assets)"
grep -q 'root=/pinned/root' <<< "$out" || fail "COLOSSUL_ROOT was overridden by detection: $out"
grep -q 'assets=/pinned/assets' <<< "$out" || fail "COLOSSUL_ASSETS_ROOT was overridden: $out"
echo "  COLOSSUL_ROOT / COLOSSUL_ASSETS_ROOT override detection"
echo "PASS: explicit configuration is respected"

echo ""
echo "=== 5. provisioning warns about data stranded on container disk ==="
# Switching to a volume must not silently orphan an earlier run's weights or,
# worse, an artist's saved workflows.
grep -q 'still on container disk' "$ROOT/scripts/provision.sh" \
    || fail "provisioning should warn when an earlier run's data is left behind"
grep -q 'No volume detected' "$ROOT/scripts/provision.sh" \
    || fail "provisioning should say plainly when nothing is persistent"
# The stray-data warning must not fire when the volume IS the workspace: there
# is nothing left behind in that case, and the mv it suggests would be a no-op
# that reads like a real problem.
grep -q 'COLOSSUL_VOLUME_ROOT" != "$WORKSPACE' "$ROOT/scripts/provision.sh" \
    || fail "stray-data warning should be skipped when the volume replaces the workspace"
echo "PASS: stranded data is reported"

echo ""
echo "ALL VOLUME CHECKS PASSED"
