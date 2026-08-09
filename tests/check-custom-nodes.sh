#!/usr/bin/env bash
# Verify custom-node installation, dependency protection and Manager enablement.
#
# Every failure here is silent in production: a pack whose deps didn't install
# shows only "(IMPORT FAILED)" in a seat's startup table, and a torch clobbered
# by a node's requirements.txt surfaces later as CPU-speed inference or an
# unrelated ImportError.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export COLOSSUL_LIB="$ROOT/scripts"
# shellcheck source=../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
PY="${PYTHON:-python3}"

echo "=== 1. the manifest parses to real git URLs ==="
MAN="$ROOT/custom-nodes.txt"
[ -f "$MAN" ] || fail "custom-nodes.txt missing — the image COPYs it"
mapfile -t ENTRIES < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$MAN" | grep -E '^https?://')
[ "${#ENTRIES[@]}" -gt 0 ] || fail "manifest yielded no entries — comment stripping is wrong"
for e in "${ENTRIES[@]}"; do
    [[ "$e" =~ ^https://github\.com/[^/]+/[^/@]+(@[^@]+)?$ ]] \
        || fail "malformed manifest entry: '$e'"
done
echo "  ${#ENTRIES[@]} packs, all well-formed"
# Inline comments must not leak into the URL - that would produce a clone of a
# path containing spaces.
for e in "${ENTRIES[@]}"; do
    case "$e" in *" "*) fail "entry contains whitespace (comment leaked): '$e'" ;; esac
done
echo "PASS: manifest parses cleanly"

echo ""
echo "=== 2. derived pack names are unique (no clobbering in custom_nodes/) ==="
names=(); for e in "${ENTRIES[@]}"; do u="${e%@*}"; names+=("$(basename "${u%.git}")"); done
dupes="$(printf '%s\n' "${names[@]}" | sort | uniq -d)"
[ -z "$dupes" ] || fail "two manifest entries resolve to the same directory: $dupes"
echo "  ${#names[@]} distinct destination directories"
echo "PASS: no collisions"

echo ""
echo "=== 3. constraints pin only what is actually installed ==="
# Run against the real interpreter: the function must emit well-formed pins,
# never invent a version, and never name a package that isn't installed
# (a bogus pin makes EVERY later install fail with ResolutionImpossible).
write_pip_constraints "$PY" "$T/constraints.txt" || fail "write_pip_constraints exited non-zero"
while read -r line; do
    [ -n "$line" ] || continue
    [[ "$line" =~ ^[A-Za-z0-9_.-]+==[^=]+$ ]] || fail "malformed pin: '$line'"
    pkg="${line%%==*}"
    grep -qw -- "$pkg" <<< "$PROTECTED_PACKAGES" || fail "pinned '$pkg', which is not in PROTECTED_PACKAGES"
    "$PY" - "$pkg" <<'PY' || fail "pinned '$pkg' but it is not installed"
import importlib.metadata as md, sys
md.version(sys.argv[1])
PY
done < "$T/constraints.txt"
echo "  $(grep -c . "$T/constraints.txt" || true) pin(s), all installed and well-formed"

# A CUDA-labelled version must survive verbatim — stripping "+cu130" would let
# pip satisfy the pin with a CPU wheel from PyPI.
grep -q '+' <<< "$("$PY" -c 'import importlib.metadata as m
try: print(m.version("torch"))
except Exception: print("")')" && grep -q 'torch==.*+' "$T/constraints.txt" \
    && echo "  local CUDA label preserved on torch"
echo "PASS: constraints reflect reality"

echo ""
echo "=== 4. uv is protected too, not just pip ==="
# uv ignores PIP_CONSTRAINT entirely; a pip-only setup protects nothing when
# the installer uses uv, which ours does.
( export_constraint_env "$T/constraints.txt"
  [ "${PIP_CONSTRAINT:-}" = "$T/constraints.txt" ] || exit 1
  [ "${UV_CONSTRAINT:-}"  = "$T/constraints.txt" ] || exit 2
  [ "${PIP_BUILD_CONSTRAINT:-}" = "$T/constraints.txt" ] || exit 3
) || fail "export_constraint_env must set PIP_CONSTRAINT, UV_CONSTRAINT and the build variants"
echo "  PIP_CONSTRAINT, UV_CONSTRAINT and both build constraints exported"
( export PYTORCH_BACKEND=cu130
  export_constraint_env "$T/constraints.txt"
  [ "${PIP_EXTRA_INDEX_URL:-}" = "https://download.pytorch.org/whl/cu130" ] || exit 1
) || fail "with PYTORCH_BACKEND set, the PyTorch wheel index must be added or +cuXXX pins cannot resolve"
echo "  PyTorch index derived from PYTORCH_BACKEND"
echo "PASS: uv and pip both constrained"

echo ""
echo "=== 5. the installer never lets one bad pack kill the rest ==="
grep -q 'exit 0' "$ROOT/scripts/install-custom-nodes.sh" \
    || fail "installer should exit 0 so provisioning continues"
grep -qE 'FAILED\+=' "$ROOT/scripts/install-custom-nodes.sh" \
    || fail "installer should collect failures and report them"
grep -q 'set -uo pipefail' "$ROOT/scripts/install-custom-nodes.sh" \
    || fail "installer must NOT use 'set -e' - one failing pack would abort all of them"
grep -qE '^set -euo' "$ROOT/scripts/install-custom-nodes.sh" \
    && fail "installer uses 'set -e'; a single failing pack would abort the rest"
echo "PASS: failures are collected, not fatal"

echo ""
echo "=== 6. requirements install is SEQUENTIAL ==="
# Parallel pip into one shared venv corrupts it. Clones may be parallel.
awk '/Install requirements SEQUENTIALLY/,/^fi$/' "$ROOT/scripts/install-custom-nodes.sh" \
    | grep -qE '^\s*\)\s*&\s*$' \
    && fail "requirements loop appears to background jobs — pip into a shared venv must be serial"
echo "PASS: requirements installed one at a time"

echo ""
echo "=== 6b. install_reqs actually reaches a pack's requirements.txt ==="
# Executed, not grepped. `local dir="$1" req="$dir/..."` expands $dir to the
# OUTER value (empty), so req became "/requirements.txt", every pack was skipped
# as having no requirements, and nothing was logged as failing. Grep-based
# checks all passed while zero dependencies installed.
mkdir -p "$T/pack/MyPack"
echo "some-package==1.0" > "$T/pack/MyPack/requirements.txt"
cat > "$T/fake-uv" <<'EOF'
#!/usr/bin/env bash
echo "UV CALLED: $*" >> "$UVLOG"
EOF
chmod +x "$T/fake-uv"
(
    export UVLOG="$T/uv.log" PATH="$T:$PATH"
    ln -sf "$T/fake-uv" "$T/uv"
    export COMFYUI_PYTHON="$PY" COMFYUI_HOME="$T/comfy" SRC_DIR="$T/src"
    export CUSTOM_NODES="$T/pack" SKIP_MANIFEST=1
    # Pull in just the function, without running the installer body.
    eval "$(awk '/^install_reqs\(\)/,/^}/' "$ROOT/scripts/install-custom-nodes.sh")"
    # shellcheck disable=SC2034  # read by the eval'd install_reqs above
    FAILED=()
    install_reqs "$T/pack/MyPack" MyPack
) >/dev/null 2>&1
grep -q 'UV CALLED' "$T/uv.log" 2>/dev/null \
    || fail "install_reqs never invoked the installer for a pack that HAS requirements.txt — every pack's deps would be silently skipped"
echo "  requirements.txt found and handed to the installer"
echo "PASS: install_reqs resolves the pack path correctly"

echo ""
echo "=== 6c. pinned entries can clone a COMMIT SHA, not just a branch ==="
# `git clone --branch <sha>` fails: --branch takes branch and tag names only.
# The manifest pins commit SHAs, so a --branch-based clone would fail every
# pinned pack. Proven against a real local repo, no network needed.
git init -q "$T/origin"
( cd "$T/origin" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one \
  && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m two ) >/dev/null 2>&1
PINSHA="$(git -C "$T/origin" rev-parse HEAD)"

grep -q 'clone --depth 1 --branch' "$ROOT/scripts/install-custom-nodes.sh" \
    && fail "installer clones pins with 'clone --branch', which cannot take a commit SHA"

# Exercise the installer's actual pinned-clone form.
if ( git init -q "$T/dest" &&
     git -C "$T/dest" remote add origin "$T/origin" &&
     git -C "$T/dest" fetch --depth 1 -q origin "$PINSHA" &&
     git -C "$T/dest" checkout -q FETCH_HEAD ) >/dev/null 2>&1; then
    got="$(git -C "$T/dest" rev-parse HEAD)"
    [ "$got" = "$PINSHA" ] || fail "pinned clone landed on $got, expected $PINSHA"
    echo "  commit-SHA pin checked out exactly"
else
    fail "the installer's pinned-clone form cannot fetch a commit SHA"
fi

# Every manifest ref, if present, should be a full SHA or a version tag — a
# bare branch name in a "frozen" manifest is drift waiting to happen.
unpinned=0
for e in "${ENTRIES[@]}"; do
    case "$e" in
        *@*) r="${e##*@}"
             [[ "$r" =~ ^[0-9a-f]{40}$ || "$r" =~ ^v?[0-9] ]] \
                 || echo "  NOTE: '$r' is a branch, not a pin ($e)" ;;
        *)   unpinned=$((unpinned + 1)) ;;
    esac
done
echo "  $unpinned of ${#ENTRIES[@]} entries unpinned"
echo "PASS: commit pins are clonable"

echo ""
echo "=== 7. Manager: flag passed AND the self-disabling checkout retired ==="
grep -q -- '--enable-manager' "$ROOT/scripts/seat-comfyui.sh" \
    || fail "seat-comfyui.sh must pass --enable-manager"
grep -q 'ENABLE_COMFYUI_MANAGER' "$ROOT/scripts/seat-comfyui.sh" \
    || fail "manager should be switchable via ENABLE_COMFYUI_MANAGER"
# The trap: ComfyUI's handle_comfyui_manager_unavailable() force-disables the
# flag when custom_nodes/ComfyUI-Manager exists, so the flag alone is not enough.
grep -q 'replaced-by-pip-package' "$ROOT/scripts/install-custom-nodes.sh" \
    || fail "installer must retire the bundled ComfyUI-Manager checkout, or --enable-manager silently self-disables"
grep -q 'manager_requirements.txt' "$ROOT/scripts/install-custom-nodes.sh" \
    || fail "installer should install the manager pip package"
echo "PASS: flag set, legacy checkout retired, pip package installed"

echo ""
echo "=== 8. ComfyUI version is selectable for newer model support ==="
grep -q 'COMFYUI_REF' "$ROOT/scripts/provision.sh" \
    || fail "provision.sh must honour COMFYUI_REF"
grep -qE 'ENV COMFYUI_REF=' "$ROOT/Dockerfile" \
    || fail "Dockerfile should declare a default COMFYUI_REF"
# An upgrade moves the pinned comfyui-frontend-package, so requirements must be
# re-synced AFTER the version changes — not before, or the UI and backend drift.
# Matched across line continuations: the command spans two lines.
awk '/COMFYUI_REF="\$\{COMFYUI_REF/{seen=NR}
     seen && /-r requirements.txt/{print NR; found=1}
     END{exit !found}' "$ROOT/scripts/provision.sh" >/dev/null \
    || fail "ComfyUI requirements must be re-synced AFTER the version update"
echo "PASS: COMFYUI_REF honoured, requirements re-synced after upgrade"

echo ""
echo "ALL CUSTOM NODE CHECKS PASSED"
