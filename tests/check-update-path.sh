#!/usr/bin/env bash
# Verify the "ship a Storyrendr change" path actually ships it.
#
# Provisioning patches vite.config.ts in the working tree, so the checkout is
# permanently dirty. `git checkout` refuses to overwrite a modified file, which
# made `colossul provision` fetch the new commit, fail to apply it, warn,
# and leave the instance serving old code — a silent no-op that looks like a
# successful update. These tests pin down the reset-based behaviour instead.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

PATCH="$ROOT/scripts/patches/patch_vite_backend_url.py"
PY="${PYTHON:-python3}"

echo "=== 1. build a fake upstream and an instance checkout ==="
mkdir -p "$T/up"
cd "$T/up"; git init -q -b main
# A minimal file the patch will accept.
cat > vite.config.ts <<'EOF'
/** Shared proxy rules — used by both dev server and preview server. */
const proxyConfig = {
  "/api": {
    target: "http://127.0.0.1:8189",
  },
};
EOF
echo "v1" > marker.txt
git add -A && git commit -qm one
git clone -q "$T/up" "$T/work"
echo "  cloned; marker=$(cat "$T/work/marker.txt")"

echo ""
echo "=== 2. provisioning patches the working tree (tree now dirty) ==="
"$PY" "$PATCH" "$T/work/vite.config.ts" | sed 's/^/  /'
cd "$T/work"
[ -n "$(git status --porcelain)" ] || fail "expected a dirty tree after patching"
echo "  tree is dirty, as it always will be in production"

echo ""
echo "=== 3. upstream ships a change that touches the patched file ==="
cd "$T/up"
cat > vite.config.ts <<'EOF'
/** Shared proxy rules — used by both dev server and preview server. */
const proxyConfig = {
  "/api": {
    target: "http://127.0.0.1:8189",
    changeOrigin: true,
  },
};
EOF
echo "v2" > marker.txt
git add -A && git commit -qm two
echo "  upstream now at v2"

echo ""
echo "=== 4. the update must actually land ==="
cd "$T/work"
git fetch -q origin main
# Exactly what provision.sh now does.
git reset --hard -q FETCH_HEAD || fail "reset --hard failed"
got="$(cat marker.txt)"
[ "$got" = "v2" ] || fail "instance still on '$got' after update - the update silently did nothing"
echo "  marker=$got  (update applied)"

echo ""
echo "=== 5. the reset wipes our patch, so it MUST be re-applied ==="
if grep -q 'VITE_BACKEND_URL' vite.config.ts; then
    fail "expected reset to remove the patch; the rest of this test is meaningless if not"
fi
echo "  patch gone after reset (as expected)"
"$PY" "$PATCH" vite.config.ts | sed 's/^/  /'
grep -q 'VITE_BACKEND_URL' vite.config.ts \
    || fail "patch did not re-apply; every seat would proxy /api to the dead stock port 8189"
echo "PASS: update lands AND the per-seat backend patch is restored"

echo ""
echo "=== 6. provision.sh applies the patch unconditionally ==="
# If the patch were only applied inside the `if NEED_BUILD` block, a
# no-change re-provision would reset the tree and leave it unpatched.
awk '/^if \[ "\$NEED_BUILD" = "1" \]; then/{inblock=1}
     /patch_vite_backend_url/{ if (inblock) print "INSIDE"; else print "OUTSIDE" }' \
    "$ROOT/scripts/provision.sh" | grep -qx OUTSIDE \
    || fail "the vite patch must run outside the NEED_BUILD block, or a no-change re-provision leaves it unpatched"
echo "PASS: patch runs on every provision, not only on rebuilds"

echo ""
echo "=== 7. provision.sh uses reset --hard, not checkout ==="
grep -q 'reset --hard' "$ROOT/scripts/provision.sh" \
    || fail "provision.sh should reset --hard to FETCH_HEAD"
grep -qE 'git .*checkout -q FETCH_HEAD' "$ROOT/scripts/provision.sh" \
    && fail "provision.sh still uses 'git checkout FETCH_HEAD', which a dirty tree blocks"
echo "PASS: update uses reset --hard"

echo ""
echo "=== 8. a new build restarts the seats ==="
# supervisorctl update only touches programs whose config changed; after a
# source update the configs are identical, so seats must be restarted explicitly
# or they keep serving the old build.
grep -q 'supervisorctl restart "seat' "$ROOT/scripts/provision.sh" \
    || fail "provision.sh must restart seats after a rebuild, or the new code is never served"
echo "PASS: seats are restarted when a new build lands"

echo ""
echo "=== 9. the supervisor reachability guard must not use 'status' ==="
# `supervisorctl status` exits non-zero if ANY program isn't RUNNING, and the
# base image's pyworker/syncthing/tensorboard are one-shots that exit at boot -
# so gating on `! supervisorctl status` aborts provisioning on a healthy
# instance, right before the seats start. Must be `pid` (or `version`).
if grep -qE 'if ! supervisorctl status' "$ROOT/scripts/provision.sh"; then
    fail "provision.sh gates on 'supervisorctl status' - exits non-zero when base one-shots have exited, killing provisioning before the seats start. Use 'supervisorctl pid'."
fi
grep -qE 'supervisorctl pid' "$ROOT/scripts/provision.sh" \
    || fail "provision.sh should probe daemon reachability with 'supervisorctl pid'"
echo "PASS: reachability probe uses 'supervisorctl pid', not 'status'"

echo ""
echo "ALL UPDATE PATH CHECKS PASSED"
