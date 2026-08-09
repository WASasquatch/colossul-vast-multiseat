#!/usr/bin/env bash
# Install ComfyUI custom node packs into the shared ComfyUI install.
#
#   install-custom-nodes.sh [manifest]      (default: /opt/colossul/custom-nodes.txt)
#
# Run standalone at any time; also called by provision.sh. Safe to re-run —
# existing packs are updated rather than recloned.
#
# Two things ComfyUI will NOT do for you, which is the whole reason this exists:
#   1. It never installs a custom node's requirements.txt. Not at boot, not
#      ever. A hand-copied pack with missing deps just logs "(IMPORT FAILED)"
#      in the startup table and the nodes silently don't exist.
#   2. It gives no protection against a pack's requirements clobbering torch.
#      We pin the packages we refuse to lose; see write_pip_constraints.
set -uo pipefail

_LIB="${COLOSSUL_LIB:-/opt/colossul}/lib/common.sh"
[ -f "$_LIB" ] || _LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=lib/common.sh
source "$_LIB"

load_vast_environment
load_runtime_env

MANIFEST="${1:-${COLOSSUL_LIB:-/opt/colossul}/custom-nodes.txt}"
CUSTOM_NODES="$COMFYUI_HOME/custom_nodes"
CONSTRAINTS="$COLOSSUL_ETC/pip-constraints.txt"
FAILED=()

mkdir -p "$CUSTOM_NODES" "$COLOSSUL_ETC"

log "Custom nodes -> $CUSTOM_NODES"

# ── Pin what we refuse to lose, before installing anything ──────────────────
write_pip_constraints "$COMFYUI_PYTHON" "$CONSTRAINTS"
if [ -s "$CONSTRAINTS" ]; then
    log "Protecting installed versions:"
    sed 's/^/[colossul]     /' "$CONSTRAINTS"
else
    warn "Could not read installed versions — proceeding without dependency protection."
fi
export_constraint_env "$CONSTRAINTS"

# Install one pack's requirements. Never fatal: a single bad pack must not cost
# the operator all the others.
install_reqs() {
    local dir="$1" name="$2"
    # Deliberately a second `local`: bash expands all words of a `local`
    # statement BEFORE assigning any of them, so `local dir="$1" req="$dir/..."`
    # would expand $dir to the *outer* value (empty here) and silently skip
    # every pack's requirements. Verified, not theoretical.
    local req="$dir/requirements.txt"
    [ -f "$req" ] || return 0
    log "  deps: $name"
    if ( cd "$dir" && uv pip install --python "$COMFYUI_PYTHON" \
            --no-cache-dir -r requirements.txt >/dev/null 2>&1 ); then
        return 0
    fi

    # Second attempt, without the lines that fight the protected set.
    #
    # Packs routinely hard-pin torch/opencv/numpy to whatever was current when
    # they were written (MusePose pins opencv==4.8.1.78, from 2023). Under our
    # constraints that line cannot resolve — correctly, since honouring it would
    # downgrade opencv for all four seats. But pip fails the WHOLE file on one
    # bad line, so the pack's dozen other, perfectly installable dependencies
    # were being dropped too, and the pack could never work.
    #
    # So: drop only the protected lines, install the rest normally, and say
    # exactly what was ignored. The pack gets its real dependencies and keeps
    # the environment's torch/opencv, which is nearly always what you want.
    local filtered="$dir/.colossul-requirements-filtered.txt"
    local dropped
    dropped="$("$COMFYUI_PYTHON" - "$req" "$filtered" "$PROTECTED_PACKAGES" <<'PY'
import re, sys
src, out, protected = sys.argv[1], sys.argv[2], set(sys.argv[3].split())
kept, removed = [], []
for line in open(src, encoding="utf-8", errors="replace"):
    bare = line.split("#", 1)[0].strip()
    if not bare:
        kept.append(line.rstrip("\n")); continue
    # Package name is everything before the first version/extra/marker char.
    name = re.split(r"[<>=!~;\[\s]", bare, 1)[0].strip().lower().replace("_", "-")
    if name in protected:
        removed.append(bare)
    else:
        kept.append(line.rstrip("\n"))
open(out, "w", encoding="utf-8").write("\n".join(kept) + "\n")
print("; ".join(removed))
PY
    )" || dropped=""

    if [ -n "$dropped" ]; then
        warn "  $name pins packages we manage; ignoring: $dropped"
        if ( cd "$dir" && uv pip install --python "$COMFYUI_PYTHON" \
                --no-cache-dir -r "$(basename "$filtered")" >/dev/null 2>&1 ); then
            log "  deps: $name installed without those lines (environment torch/opencv kept)"
            rm -f "$filtered"
            return 0
        fi
    fi
    # Third attempt: --no-deps.
    #
    # This is the numpy case, and it is the common one. The conflict is usually
    # not a line in requirements.txt at all — it is TRANSITIVE. A pack asks for
    # some library, that library still declares `numpy<2`, the image ships numpy
    # 2.x, and the resolver reports an impossible resolution naming numpy even
    # though no pack mentioned a version. Filtering direct lines cannot fix that,
    # because the offending constraint is inside a dependency.
    #
    # --no-deps installs exactly what the pack asked for and resolves nothing
    # further, so the stale transitive bound is never considered. The risk is a
    # second-level dependency going missing, which surfaces honestly as
    # (IMPORT FAILED) at seat startup rather than as a silently downgraded numpy
    # breaking every other pack in the shared venv.
    local target="requirements.txt"
    [ -n "$dropped" ] && target="$(basename "$filtered")"
    if ( cd "$dir" && uv pip install --python "$COMFYUI_PYTHON" \
            --no-cache-dir --no-deps -r "$target" >/dev/null 2>&1 ); then
        warn "  $name: installed with --no-deps (a transitive pin, usually numpy,"
        warn "  could not be satisfied without changing the shared environment)."
        warn "  Watch for (IMPORT FAILED) from $name in the seat startup table."
        rm -f "$filtered"
        FAILED+=("$name (installed --no-deps)")
        return 0
    fi
    rm -f "$filtered"

    # Genuinely broken. Show why rather than just failing.
    warn "  deps failed for $name — retrying verbosely:"
    ( cd "$dir" && uv pip install --python "$COMFYUI_PYTHON" \
        --no-cache-dir -r requirements.txt 2>&1 | tail -15 | sed 's/^/[colossul]       /' )
    warn "  $name may not load; it will show (IMPORT FAILED) in the seat startup table."
    FAILED+=("$name (deps)")
    return 1
}

# Some packs ship an install.py that fetches models or builds extensions.
run_install_py() {
    local dir="$1" name="$2"
    [ -f "$dir/install.py" ] || return 0
    log "  install.py: $name"
    ( cd "$dir" && "$COMFYUI_PYTHON" install.py >/dev/null 2>&1 ) \
        || warn "  install.py failed for $name — pack may be partially set up."
}

# ── 1. Colossul Studios Nodes, from the Storyrendr checkout ─────────────────
# Copied rather than cloned: it lives inside the private storyrendr repo, which
# provisioning has already fetched with the operator's token.
NODES_SRC="$SRC_DIR/Colossul_Studios_Nodes"
if [ -d "$NODES_SRC" ]; then
    log "Installing Colossul_Studios_Nodes (from the Storyrendr checkout)"
    rm -rf "$CUSTOM_NODES/Colossul_Studios_Nodes"
    cp -r "$NODES_SRC" "$CUSTOM_NODES/Colossul_Studios_Nodes"
    install_reqs "$CUSTOM_NODES/Colossul_Studios_Nodes" "Colossul_Studios_Nodes"
else
    warn "Colossul_Studios_Nodes not found at $NODES_SRC — Storyrendr workflows will not resolve their nodes."
    FAILED+=("Colossul_Studios_Nodes (missing)")
fi

# ── 2. Third-party packs from the manifest ──────────────────────────────────
if [ "${SKIP_CUSTOM_NODES:-0}" = "1" ]; then
    log "SKIP_CUSTOM_NODES=1 — skipping third-party packs."
elif [ ! -f "$MANIFEST" ]; then
    warn "No manifest at $MANIFEST — skipping third-party packs."
else
    # url[@ref] per line, comments/blanks stripped.
    mapfile -t ENTRIES < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$MANIFEST" | grep -E '^https?://')
    log "Manifest: ${#ENTRIES[@]} pack(s) from $(basename "$MANIFEST")"

    # Clone/update in PARALLEL (network-bound, independent).
    #
    # Announce the start and end of this: the clones produce no output of their
    # own, so without these two lines the provisioning log sits silent for
    # minutes on a slow link and looks wedged.
    log "  cloning/updating ${#ENTRIES[@]} pack(s) in parallel..."
    _clone_start="$(date +%s)"
    pids=()
    for entry in "${ENTRIES[@]}"; do
        url="${entry%@*}"; ref=""
        case "$entry" in *@*) ref="${entry##*@}" ;; esac
        [ "$url" = "$entry" ] && ref=""
        name="$(basename "${url%.git}")"
        dest="$CUSTOM_NODES/$name"
        (
            if [ -d "$dest/.git" ]; then
                git -C "$dest" fetch --depth 1 origin "${ref:-HEAD}" >/dev/null 2>&1 &&
                git -C "$dest" reset --hard -q FETCH_HEAD >/dev/null 2>&1 ||
                    echo "UPDATE_FAILED $name"
            elif [ -d "$dest" ]; then
                :   # present but not a git checkout — leave it alone
            else
                if [ -n "$ref" ]; then
                    # init+fetch rather than `clone --branch`: --branch takes
                    # branch and tag names ONLY and fails on a commit SHA, which
                    # is exactly what a frozen manifest pins to. This form takes
                    # a SHA, tag or branch identically, and still shallow-fetches.
                    ( git init -q "$dest" &&
                      git -C "$dest" remote add origin "$url" &&
                      git -C "$dest" fetch --depth 1 -q origin "$ref" &&
                      git -C "$dest" checkout -q FETCH_HEAD ) >/dev/null 2>&1 || {
                        rm -rf "$dest"   # don't leave a half-init'd dir behind
                        echo "CLONE_FAILED $name"
                    }
                else
                    git clone --depth 1 "$url" "$dest" >/dev/null 2>&1 ||
                        echo "CLONE_FAILED $name"
                fi
            fi
        ) &
        pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" || true; done
    _present=0
    for entry in "${ENTRIES[@]}"; do
        u="${entry%@*}"; [ -d "$CUSTOM_NODES/$(basename "${u%.git}")" ] && _present=$((_present + 1))
    done
    log "  clones finished in $(( $(date +%s) - _clone_start ))s ($_present/${#ENTRIES[@]} present)"
    log "  installing requirements one pack at a time (concurrent pip corrupts a shared venv)..."

    # Install requirements SEQUENTIALLY — concurrent pip into one venv corrupts it.
    for entry in "${ENTRIES[@]}"; do
        url="${entry%@*}"
        name="$(basename "${url%.git}")"
        dest="$CUSTOM_NODES/$name"
        if [ ! -d "$dest" ]; then
            warn "  $name: clone failed (network, or repo moved/renamed)"
            FAILED+=("$name (clone)")
            continue
        fi
        install_reqs "$dest" "$name" && run_install_py "$dest" "$name"
    done
fi

# ── 2b. Did the shared environment survive? ─────────────────────────────────
# The whole point of the constraints file is that torch/numpy/opencv are the
# SAME afterwards. Verify it rather than assume it: a downgraded numpy breaks
# every pack at once and, worse, a CPU torch silently makes all four seats slow
# instead of failing. Compare against the pins written before any installing.
if [ -s "${CONSTRAINTS:-}" ]; then
    log "Verifying the shared environment was not altered..."
    drifted="$("$COMFYUI_PYTHON" - "$CONSTRAINTS" <<'PY'
import sys
try:
    import importlib.metadata as md
except ImportError:
    sys.exit(0)
bad = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line or "==" not in line:
        continue
    name, want = line.split("==", 1)
    try:
        have = md.version(name)
    except Exception:
        bad.append(f"{name}: GONE (was {want})")
        continue
    if have != want:
        bad.append(f"{name}: {want} -> {have}")
print("\n".join(bad))
PY
    )" || drifted=""
    if [ -n "$drifted" ]; then
        warn "  A custom node CHANGED a protected package:"
        printf '%s\n' "$drifted" | while IFS= read -r l; do warn "    $l"; done
        warn "  This affects every seat. If torch moved, inference may now be on CPU."
        warn "  Check with: $COMFYUI_PYTHON -c 'import torch; print(torch.__version__, torch.cuda.is_available())'"
        FAILED+=("environment drift: $(printf '%s' "$drifted" | tr '\n' ' ')")
    else
        log "  torch / numpy / opencv / onnxruntime all unchanged."
    fi
fi

# ── 3. ComfyUI-Manager ──────────────────────────────────────────────────────
# `--enable-manager` uses the PIP PACKAGE. If a legacy source checkout exists at
# custom_nodes/ComfyUI-Manager, ComfyUI's handle_comfyui_manager_unavailable()
# logs a warning and force-sets enable_manager=False — so the flag would appear
# to be ignored. The base image ships exactly that checkout, hence this step.
if [ "${ENABLE_COMFYUI_MANAGER:-1}" = "1" ]; then
    LEGACY="$CUSTOM_NODES/ComfyUI-Manager"
    if [ -e "$LEGACY" ]; then
        log "Retiring the bundled ComfyUI-Manager source checkout"
        log "  (a source checkout makes --enable-manager silently disable itself)"
        rm -rf "$LEGACY.replaced-by-pip-package"
        mv "$LEGACY" "$LEGACY.replaced-by-pip-package"
    fi
    if [ -f "$COMFYUI_HOME/manager_requirements.txt" ]; then
        log "Installing ComfyUI-Manager (pip package, per manager_requirements.txt)"
        uv pip install --python "$COMFYUI_PYTHON" --no-cache-dir \
            -r "$COMFYUI_HOME/manager_requirements.txt" >/dev/null 2>&1 \
            || warn "  manager install failed — seats will start without --enable-manager working."
    else
        warn "  no manager_requirements.txt in $COMFYUI_HOME — this ComfyUI predates the built-in manager."
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────
installed=$(find "$CUSTOM_NODES" -maxdepth 1 -mindepth 1 -type d ! -name '*.disabled' \
            ! -name '*.replaced-by-pip-package' 2>/dev/null | wc -l)
echo ""
log "Custom nodes ready: $installed pack(s) in $CUSTOM_NODES"
if [ "${#FAILED[@]}" -gt 0 ]; then
    warn "${#FAILED[@]} problem(s): ${FAILED[*]}"
    warn "Seats will still start; the affected nodes will show (IMPORT FAILED)"
    warn "in each seat's ComfyUI startup log."
fi
exit 0
