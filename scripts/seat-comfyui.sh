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

log "seat $SEAT: ComfyUI on GPU $GPU -> 127.0.0.1:$PORT"

cd "$COMFYUI_HOME"
exec "$COMFYUI_PYTHON" main.py \
    --listen 127.0.0.1 \
    --port "$PORT" \
    --disable-auto-launch \
    --enable-cors-header \
    ${MANAGER_ARGS[@]+"${MANAGER_ARGS[@]}"} \
    --input-directory  "$D/comfyui/input" \
    --output-directory "$D/comfyui/output" \
    --temp-directory   "$D/comfyui/temp" \
    --user-directory   "$D/comfyui/user" \
    --database-url     "sqlite:///$DB_PATH" \
    ${MODEL_PATH_ARGS[@]+"${MODEL_PATH_ARGS[@]}"} \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
