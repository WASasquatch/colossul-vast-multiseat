#!/usr/bin/env bash
# Launch one seat's Storyrendr backend.
#
# Every seat runs the same code out of the shared checkout. Isolation comes
# entirely from environment: OUTPUTS_DIR is a pydantic setting and the backend
# puts its SQLite databases at ${OUTPUTS_DIR}/_databases/, so pointing it at a
# per-seat path gives each employee their own projects, outputs and history.
# Environment variables outrank the .env file in pydantic-settings, so these
# win even if a stray .env is ever committed.
set -euo pipefail

SEAT="${1:?usage: seat-backend.sh <seat-index>}"

_LIB="${COLOSSUL_LIB:-/opt/colossul}/lib/common.sh"
[ -f "$_LIB" ] || _LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=lib/common.sh
source "$_LIB"
load_vast_environment
load_runtime_env
portal_log "seat${SEAT}-backend"
wait_for_provisioning "seat $SEAT backend"

GPU="$(gpu_for_seat "$SEAT")"
PORT="$(backend_int "$SEAT")"
COMFY_PORT="$(comfyui_int "$SEAT")"
D="$(seat_dir "$SEAT")"

BACKEND_DIR="$SRC_DIR/colossul-backend"
[ -x "$BACKEND_DIR/.venv/bin/python" ] \
    || die "seat $SEAT: backend venv missing at $BACKEND_DIR/.venv — run: colossul-seats provision"

mkdir -p "$D/backend/outputs"

# The backend runs SAM3D/torch work for Pose Studio, so it needs the same GPU
# pin as its ComfyUI — otherwise pose extraction would land on GPU 0 for
# every seat.
export CUDA_VISIBLE_DEVICES="$GPU"

# Hosted deployment: disables desktop-only affordances such as "open folder".
export ENVIRONMENT="cloud"

# Bind this seat to its own ComfyUI. COMFYUI_BASE_URL wins over the
# COMFYUI_API_BASE the base image exports for the (now retired) stock instance.
export COMFYUI_BASE_URL="http://127.0.0.1:${COMFY_PORT}"
export COMFYUI_API_BASE="$COMFYUI_BASE_URL"
export COMFYUI_ROOT="$COMFYUI_HOME"
export COMFYUI_INPUT_DIR="$D/comfyui/input"
export COMFYUI_OUTPUT_DIR="$D/comfyui/output"
export COMFYUI_CUSTOM_NODES_DIR="$COMFYUI_HOME/custom_nodes"

# Per-seat state. Everything else (workflows/, preset_media/) stays relative to
# the shared checkout and is read-only in practice.
export OUTPUTS_DIR="$D/backend/outputs"

log "seat $SEAT: backend on GPU $GPU -> 127.0.0.1:$PORT (ComfyUI :$COMFY_PORT, outputs $OUTPUTS_DIR)"

cd "$BACKEND_DIR"
# uvicorn is exec'd directly instead of via the repo's run.sh, which hardcodes
# PORT=8189 and wraps its own restart loop that would fight supervisor's.
exec ./.venv/bin/python -m uvicorn app.main:app \
    --host 127.0.0.1 \
    --port "$PORT"
