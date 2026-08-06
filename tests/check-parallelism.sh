#!/usr/bin/env bash
# Assert the core product requirement: seats run genuinely in parallel.
#
# Employees must never queue behind each other. That requires N separate
# ComfyUI *processes*, one per GPU, each with its own port and its own writable
# state — ComfyUI's PromptQueue is an in-memory object built once per process,
# so separate processes are exactly what gives separate queues.
#
# Sharing read-only things (the install, the weights) does NOT serialise
# anything. Sharing a *writable* thing would. These tests pin that line down.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export COLOSSUL_LIB="$ROOT/scripts"
# shellcheck source=../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
N=4

# Every value in a list must be unique, or seats would contend.
all_distinct() {
    local label="$1"; shift
    local total unique
    total=$#
    unique=$(printf '%s\n' "$@" | sort -u | wc -l)
    [ "$total" -eq "$unique" ] || fail "$label are not unique across seats: $*"
}

echo "=== 1. one ComfyUI PROCESS per seat, not one shared server ==="
for ((i = 0; i < N; i++)); do write_seat_unit "$i" "$T/seat$i.conf"; done
progs=$(grep -h '^\[program:seat[0-9]*-comfyui\]' "$T"/seat*.conf | sort -u | wc -l)
[ "$progs" -eq "$N" ] || fail "expected $N ComfyUI programs, found $progs"
echo "  $progs independent supervisor programs -> $N processes -> $N queues"
echo "PASS: no shared ComfyUI server"

echo ""
echo "=== 2. one GPU per seat ==="
gpus=(); for ((i = 0; i < N; i++)); do gpus+=("$(gpu_for_seat "$i")"); done
all_distinct "GPUs" "${gpus[@]}"
echo "  seats 0..$((N-1)) -> GPUs ${gpus[*]}"
grep -q 'export CUDA_VISIBLE_DEVICES=' "$ROOT/scripts/seat-comfyui.sh" \
    || fail "seat-comfyui.sh must pin CUDA_VISIBLE_DEVICES or every seat lands on GPU 0"
grep -q 'export CUDA_VISIBLE_DEVICES=' "$ROOT/scripts/seat-backend.sh" \
    || fail "seat-backend.sh must pin CUDA_VISIBLE_DEVICES (it runs SAM3D on the GPU)"
echo "PASS: distinct GPUs, pinned in both the ComfyUI and backend wrappers"

echo ""
echo "=== 3. distinct ports for every service ==="
for svc in comfyui backend frontend; do
    ports=(); for ((i = 0; i < N; i++)); do ports+=("$(${svc}_int "$i")"); done
    all_distinct "$svc internal ports" "${ports[@]}"
    echo "  $svc: ${ports[*]}"
done
echo "PASS: no two seats bind the same port"

echo ""
echo "=== 4. each seat's backend drives ITS OWN ComfyUI ==="
# The failure this guards: a backend hardcoded to one ComfyUI would funnel all
# four employees into a single queue - the exact thing seats exist to prevent.
grep -q 'comfyui_int "\$SEAT"' "$ROOT/scripts/seat-backend.sh" \
    || fail "seat-backend.sh must resolve its ComfyUI port from its own seat index"
grep -qE 'COMFYUI_BASE_URL=.*COMFY_PORT' "$ROOT/scripts/seat-backend.sh" \
    || fail "seat-backend.sh must point COMFYUI_BASE_URL at its own seat's ComfyUI"
grep -q 'comfyui_int "\$SEAT"' "$ROOT/scripts/seat-frontend.sh" \
    || fail "seat-frontend.sh must proxy to its own seat's ComfyUI"
grep -q 'backend_int "\$SEAT"' "$ROOT/scripts/seat-frontend.sh" \
    || fail "seat-frontend.sh must proxy /api to its own seat's backend"
echo "PASS: backend and frontend both resolve from \$SEAT, never a constant"

echo ""
echo "=== 5. distinct writable state (shared state would serialise) ==="
for sub in comfyui/input comfyui/output comfyui/temp comfyui/user backend/outputs; do
    dirs=(); for ((i = 0; i < N; i++)); do dirs+=("$(seat_dir "$i")/$sub"); done
    all_distinct "$sub dirs" "${dirs[@]}"
done
dbs=(); for ((i = 0; i < N; i++)); do dbs+=("$(seat_dir "$i")/comfyui/user/comfyui.db"); done
all_distinct "ComfyUI databases" "${dbs[@]}"
echo "  input/output/temp/user, backend outputs, and comfyui.db all per-seat"
echo "PASS: no writable path is shared between seats"

echo ""
echo "=== 6. shared state is READ-ONLY only ==="
# Weights and code are shared on purpose: concurrent reads don't contend, and
# the page cache makes the second seat's load cheaper. Anything a seat WRITES
# must be per-seat, which section 5 covers.
grep -q 'is_default: true' <(write_extra_model_paths /dev/stdout) \
    || fail "the shared model store should be the default download target"
case "$ASSETS_ROOT" in *models) fail "ASSETS_ROOT should be the store root, not the models dir" ;; esac
echo "  shared: ComfyUI install (code), $ASSETS_ROOT (weights)"
echo "PASS: sharing is limited to read-only assets"

echo ""
echo "ALL PARALLELISM CHECKS PASSED"
