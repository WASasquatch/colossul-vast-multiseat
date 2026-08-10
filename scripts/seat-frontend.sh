#!/usr/bin/env bash
# Launch one seat's Storyrendr frontend (Vite preview server).
#
# This is the only port an employee needs. The preview server reverse-proxies
# /api to the seat's backend, /comfyui-api + /ws + /colossul to the seat's
# ComfyUI, and serves ComfyUI's own UI same-origin at /comfyui-frame.
#
# All seats serve the SAME dist/ build: the only build-time flag the client
# reads is VITE_COMFYUI_EMBED, which is identical everywhere. The per-seat
# targets below are consumed by vite.config.ts when the preview server boots,
# so one build safely backs N servers.
set -euo pipefail

SEAT="${1:?usage: seat-frontend.sh <seat-index>}"

_LIB="${COLOSSUL_LIB:-/opt/colossul}/lib/common.sh"
[ -f "$_LIB" ] || _LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=lib/common.sh
source "$_LIB"
load_vast_environment
load_runtime_env
portal_log "seat${SEAT}-frontend"
wait_for_provisioning "seat $SEAT frontend"

PORT="$(frontend_int "$SEAT")"
COMFY_PORT="$(comfyui_int "$SEAT")"
BACKEND_PORT="$(backend_int "$SEAT")"

FRONTEND_DIR="$SRC_DIR/colossul-frontend"
[ -f "$FRONTEND_DIR/dist/index.html" ] \
    || die "seat $SEAT: frontend not built at $FRONTEND_DIR/dist — run: colossul provision"

export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

export VITE_COMFYUI_URL="http://127.0.0.1:${COMFY_PORT}"
export VITE_BACKEND_URL="http://127.0.0.1:${BACKEND_PORT}"

# Vite's DNS-rebinding guard rejects unknown Host headers. Requests arrive via
# Caddy carrying the instance's public hostname — a Cloudflare tunnel, a raw
# IP, or a custom domain — which we cannot enumerate ahead of time. Auth is
# already enforced upstream by the base image's Caddy layer, so the guard adds
# nothing here.
export VITE_ALLOWED_HOSTS="${VITE_ALLOWED_HOSTS:-all}"

log "seat $SEAT: frontend -> 127.0.0.1:$PORT (backend :$BACKEND_PORT, ComfyUI :$COMFY_PORT)"

cd "$FRONTEND_DIR"

# --strictPort makes a port collision a loud crash-loop instead of Vite quietly
# starting seat 2 on seat 3's port.
if [ -x "./node_modules/.bin/vite" ]; then
    exec ./node_modules/.bin/vite preview --host 127.0.0.1 --port "$PORT" --strictPort
fi
exec npm run preview -- --host 127.0.0.1 --port "$PORT" --strictPort
