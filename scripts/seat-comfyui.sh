#!/usr/bin/env bash
# Launch one seat's ComfyUI, pinned to that seat's GPU.
#
# All seats share the same ComfyUI code, custom_nodes and models. Everything
# ComfyUI *writes* is redirected into the seat's own tree so employees never see
# each other's uploads, renders, saved workflows, or asset database.
set -euo pipefail

SEAT="${1:?usage: seat-comfyui.sh <seat-index>}"

_LIB="${COLOSSUL_LIB:-/opt/colossul}/lib/common.sh"
[ -f "$_LIB" ] || _LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=lib/common.sh
source "$_LIB"

load_vast_environment
load_runtime_env
portal_log "seat${SEAT}-comfyui"
wait_for_provisioning "seat $SEAT ComfyUI"

GPU="$(gpu_for_seat "$SEAT")"
PORT="$(comfyui_int "$SEAT")"
D="$(seat_dir "$SEAT")"

mkdir -p "$D/comfyui/input" "$D/comfyui/output" "$D/comfyui/temp" "$D/comfyui/user"

# One GPU per seat. Set via the environment rather than --cuda-device so that
# any subprocess ComfyUI spawns inherits the same restriction.
export CUDA_VISIBLE_DEVICES="$GPU"

# ComfyUI derives its SQLite path from __file__ — i.e. <install>/user/comfyui.db
# — and does NOT re-derive it from --user-directory. Four seats sharing one
# install would therefore hammer a single database file and hit "database is
# locked". Point each seat at its own.
DB_PATH="$D/comfyui/user/comfyui.db"

# Extras come from COLOSSUL_COMFYUI_ARGS, never the base image's COMFYUI_ARGS:
# that variable is preset to "... --port 18188" for the stock single instance,
# and argparse's last-wins would pin every seat to the same port.
#
# The expansion is deliberately unquoted so extras word-split into separate
# arguments; `set -f` stops them also being glob-expanded against the ComfyUI
# directory, which would turn a stray `*` into a screenful of filenames.
set -f
mapfile -t EXTRA_ARGS < <(sanitize_comfyui_args ${COLOSSUL_COMFYUI_ARGS:-})
set +f

# Point this seat at the shared model store. --extra-model-paths-config appends,
# so the generated config and an operator-authored one both apply, as does any
# --extra-model-paths-config the operator adds via COLOSSUL_COMFYUI_ARGS (that
# flag is deliberately not in the seat-owned list).
MODEL_PATH_ARGS=()
for cfg in "$COLOSSUL_ETC/extra_model_paths.yaml" "$ASSETS_ROOT/extra_model_paths.yaml"; do
    [ -f "$cfg" ] && MODEL_PATH_ARGS+=(--extra-model-paths-config "$cfg")
done
if [ "${#MODEL_PATH_ARGS[@]}" -eq 0 ]; then
    warn "seat $SEAT: no extra_model_paths.yaml found - this seat will only see \$COMFYUI_HOME/models"
fi

# tcmalloc materially reduces RSS for ComfyUI; the stock launcher preloads it
# and it matters more here with four instances sharing host RAM.
if [ -z "${LD_PRELOAD:-}" ] && ldconfig -p 2>/dev/null | grep -q libtcmalloc_minimal.so.4; then
    export LD_PRELOAD=libtcmalloc_minimal.so.4
fi

# ── VRAM allocator ──────────────────────────────────────────────────────────
# Seats deliberately run ComfyUI's stock VRAM policy (--normalvram with smart
# memory on) so models spill to host RAM dynamically. This is not a policy
# change: it is internal to PyTorch's caching allocator and does not affect any
# offload decision ComfyUI makes.
#
# By default that allocator carves fixed-size segments it cannot later merge. A
# seat holding ~23 GB of live tensors on a 32 GB card ends up with the remaining
# slack split across blocks too small to serve one multi-GB request, and a node
# dies with "Allocation on device 0 would exceed allowed memory" while reporting
# a device limit that the numbers say should fit — the tell is CUDA reporting a
# few MiB free when allocated + requested is several GB under the limit.
#
# expandable_segments lets a segment grow in place instead, keeping that slack
# usable. Set COLOSSUL_CUDA_ALLOC_CONF to override, or to empty to opt out
# entirely; an inherited PYTORCH_CUDA_ALLOC_CONF always wins.
if [ -z "${PYTORCH_CUDA_ALLOC_CONF:-}" ]; then
    # Unset -> default; set-but-empty -> deliberate opt-out. Hence ${x-default}.
    _alloc_conf="${COLOSSUL_CUDA_ALLOC_CONF-expandable_segments:True}"
    if [ -n "$_alloc_conf" ]; then
        export PYTORCH_CUDA_ALLOC_CONF="$_alloc_conf"
        log "seat $SEAT: PYTORCH_CUDA_ALLOC_CONF=$_alloc_conf"
    fi
fi

# ComfyUI-Manager is opt-out. It is the built-in manager (pip package), enabled
# by this flag — NOT the legacy custom_nodes/ComfyUI-Manager checkout, which
# provisioning retires because its presence makes ComfyUI force this flag off.
#
# Caveat worth knowing: all four seats share one custom_nodes directory, so a
# node installed from one seat's Manager appears for everyone, and two seats
# installing at the same moment can conflict. Set ENABLE_COMFYUI_MANAGER=0 to
# keep artists out of it.
MANAGER_ARGS=()
if [ "${ENABLE_COMFYUI_MANAGER:-1}" = "1" ]; then
    MANAGER_ARGS+=(--enable-manager)
else
    log "seat $SEAT: ComfyUI-Manager disabled (ENABLE_COMFYUI_MANAGER=0)"
fi

# ── Host RAM, shared by every seat ──────────────────────────────────────────
# ComfyUI's node cache evicts based on how much RAM is FREE, not on how much it
# has cached: --cache-ram takes headroom thresholds, and ram_release() frees
# entries until psutil available >= target. Both numbers are GB of free RAM to
# maintain — the first before evicting current-workflow entries, the second
# before evicting older ones.
#
# The defaults are computed for a machine running one ComfyUI:
#     active   = min(10, max(2, total_ram * 0.10))   -> 10 GB on a 256 GB box
#     inactive = min(128, total_ram)                 -> 128 GB
#
# All seats read the same system-wide figure, so they do back off together — but
# a 10 GB floor is far too tight when four processes must each still allocate
# while freeing. Whoever needs a buffer at that moment meets the OOM killer
# first. Scale the active threshold with the number of seats instead.
#
# Set COLOSSUL_CACHE_RAM to override ("active inactive", or "" to leave ComfyUI's
# own defaults alone).
CACHE_ARGS=()
if [ -n "${COLOSSUL_CACHE_RAM+x}" ]; then
    # Explicitly set, possibly to empty: honour it exactly.
    [ -n "$COLOSSUL_CACHE_RAM" ] && read -r -a CACHE_ARGS <<< "--cache-ram $COLOSSUL_CACHE_RAM"
elif [ "$(num_seats)" -gt 1 ]; then
    _active=$(( 8 * $(num_seats) ))
    CACHE_ARGS=(--cache-ram "$_active")
    log "seat $SEAT: keeping ${_active}GB RAM free before evicting cache ($(num_seats) seats share this host)"
fi

log "seat $SEAT: ComfyUI on GPU $GPU -> 127.0.0.1:$PORT"

cd "$COMFYUI_HOME"
exec "$COMFYUI_PYTHON" main.py \
    --listen 127.0.0.1 \
    --port "$PORT" \
    --disable-auto-launch \
    --enable-cors-header \
    ${MANAGER_ARGS[@]+"${MANAGER_ARGS[@]}"} \
    ${CACHE_ARGS[@]+"${CACHE_ARGS[@]}"} \
    --input-directory  "$D/comfyui/input" \
    --output-directory "$D/comfyui/output" \
    --temp-directory   "$D/comfyui/temp" \
    --user-directory   "$D/comfyui/user" \
    --database-url     "sqlite:///$DB_PATH" \
    ${MODEL_PATH_ARGS[@]+"${MODEL_PATH_ARGS[@]}"} \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
