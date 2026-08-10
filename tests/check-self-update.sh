#!/usr/bin/env bash
# Verify self-update against a real git repo: that it installs, refuses broken
# code, backs up, and survives overwriting the script it is running from.
#
# This runs on a live instance reachable only through a web terminal, so a
# half-applied update breaks both the seats and the tool used to fix them.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# A local "upstream" holding the real tree, so no network is needed.
UP="$T/upstream"
git init -q "$UP"
mkdir -p "$UP/scripts"
cp -a "$ROOT/scripts/." "$UP/scripts/"
cp "$ROOT/custom-nodes.txt" "$ROOT/models.txt" "$UP/" 2>/dev/null || true
git -C "$UP" add -A
git -C "$UP" -c user.email=t@t -c user.name=t commit -q -m "v1"
V1="$(git -C "$UP" rev-parse HEAD)"

# A second commit, so there is something to update TO.
echo "# marker-v2" >> "$UP/scripts/lib/common.sh"
git -C "$UP" add -A
git -C "$UP" -c user.email=t@t -c user.name=t commit -q -m "v2: add marker"
V2="$(git -C "$UP" rev-parse HEAD)"

# A fake /opt/colossul, seeded at v1.
INST="$T/opt"
mkdir -p "$INST"
cp -a "$ROOT/scripts/." "$INST/"
echo "$V1" > "$INST/.colossul-version"

run_update() {
    COLOSSUL_LIB="$INST" COLOSSUL_REPO="$UP" WORKSPACE="$T/w" \
    COLOSSUL_ASSETS_ROOT="$T/a" \
        bash "$INST/self-update.sh" "$@" 2>&1
}
mkdir -p "$T/w" "$T/a"

echo "=== 1. --check reports the new commits and changes nothing ==="
before="$(cat "$INST/.colossul-version")"
out="$(run_update --check master 2>/dev/null || run_update --check main)"
grep -q 'v2: add marker' <<< "$out" || fail "--check should list the pending commits: $out"
[ "$(cat "$INST/.colossul-version")" = "$before" ] || fail "--check modified the install"
grep -q 'marker-v2' "$INST/lib/common.sh" && fail "--check actually installed files"
echo "  listed the pending commit, installed nothing"
echo "PASS: --check is read-only"

echo ""
echo "=== 2. an update installs, and records what it installed ==="
out="$(run_update master 2>/dev/null || run_update main)"
grep -q 'marker-v2' "$INST/lib/common.sh" \
    || fail "the new common.sh was not installed: $out"
[ "$(cat "$INST/.colossul-version")" = "$V2" ] \
    || fail "version stamp is '$(cat "$INST/.colossul-version")', expected $V2"
[ -d "${INST}.backup" ] || fail "no backup was taken"
grep -q 'marker-v2' "${INST}.backup/lib/common.sh" && fail "the backup holds the NEW file, not the old one"
echo "  installed, stamped $( "${V2:0:12}" 2>/dev/null || echo "${V2:0:12}" ), previous version backed up"
echo "PASS: update applies and is reversible"

echo ""
echo "=== 3. re-running when already current is a no-op ==="
out="$(run_update master 2>/dev/null || run_update main)"
grep -qi 'already up to date' <<< "$out" || fail "should detect it is current: $out"
echo "PASS: idempotent"

echo ""
echo "=== 4. a syntax error upstream is REFUSED, not installed ==="
# The dangerous case: broken code reaching a box whose only access is a web
# terminal takes out the seats and the CLI used to recover them.
printf '\nif [ broken\n' >> "$UP/scripts/lib/common.sh"
git -C "$UP" add -A
git -C "$UP" -c user.email=t@t -c user.name=t commit -q -m "v3: broken"
good_before="$(md5sum < "$INST/lib/common.sh")"
out="$(run_update master 2>/dev/null || run_update main)"; rc=$?
[ "$rc" -ne 0 ] || fail "a tree that does not parse must not install: $out"
grep -qi 'refusing to install' <<< "$out" || fail "should say it refused: $out"
[ "$(md5sum < "$INST/lib/common.sh")" = "$good_before" ] \
    || fail "the working common.sh was overwritten by a broken one"
[ "$(cat "$INST/.colossul-version")" = "$V2" ] || fail "version stamp moved despite refusing"
echo "  refused, and the working copy is untouched"
echo "PASS: broken updates cannot land"

echo ""
echo "=== 5. it survives overwriting the script it is running from ==="
# bash reads a script incrementally. Running from the directory being replaced
# makes the shell resume at a byte offset into a different file, which corrupts
# the update halfway through. Assert the staging re-exec exists and works.
grep -q 'COLOSSUL_SELFUPDATE_STAGED' "$ROOT/scripts/self-update.sh" \
    || fail "self-update must re-exec from a copy before overwriting its own directory"
# Prove it: make upstream's self-update.sh much larger, so a naive in-place
# overwrite would shift every byte offset under the running shell.
git -C "$UP" -c user.email=t@t -c user.name=t revert --no-edit -q HEAD >/dev/null 2>&1 \
    || git -C "$UP" reset --hard -q "$V2"
{ echo ""; for i in $(seq 1 400); do echo "# padding line $i to shift every offset"; done; } \
    >> "$UP/scripts/self-update.sh"
echo "# marker-v4" >> "$UP/scripts/lib/common.sh"
git -C "$UP" add -A
git -C "$UP" -c user.email=t@t -c user.name=t commit -q -m "v4: bigger self-update"
out="$(run_update master 2>/dev/null || run_update main)"; rc=$?
[ "$rc" = "0" ] || fail "update failed while replacing its own script: $out"
grep -q 'marker-v4' "$INST/lib/common.sh" || fail "v4 did not install: $out"
grep -qE 'syntax error|unexpected' <<< "$out" && fail "the running shell misread its own file: $out"
echo "  replaced its own script mid-run without corruption"
echo "PASS: safe to overwrite itself"

echo ""
echo "ALL SELF-UPDATE CHECKS PASSED"
