#!/usr/bin/env bash
# End-to-end check of the command each seat actually execs.
#
# This runs the REAL seat-comfyui.sh with a stub interpreter that records its
# argv, so it catches mistakes that inspecting the source cannot — most
# importantly a stray EMPTY argument, which argparse rejects outright
# ("unrecognized arguments:") and which would stop every seat from starting.
#
# Everything is faked into a temp tree: no GPU, no ComfyUI, no supervisor.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# ── fake instance ────────────────────────────────────────────────────────────
mkdir -p "$T/etc" "$T/workspace" "$T/comfy/comfy"
touch "$T/comfy/main.py"

cat > "$T/fake-python" <<EOF
#!/usr/bin/env bash
# Records argv, one argument per line, so empty args are visible.
printf '%s\n' "\$@" > "$T/argv.txt"
printf 'ARGC=%s\n' "\$#" > "$T/argc.txt"
EOF
chmod +x "$T/fake-python"

cat > "$T/etc/runtime.env" <<EOF
COMFYUI_HOME=$T/comfy
COMFYUI_PYTHON=$T/fake-python
NUM_SEATS=4
EOF

run_seat() {
    env -i PATH="$PATH" HOME="$HOME" \
        COLOSSUL_LIB="$ROOT/scripts" \
        COLOSSUL_ETC="$T/etc" \
        WORKSPACE="$T/workspace" \
        "$@" \
        bash "$ROOT/scripts/seat-comfyui.sh" 2 >"$T/out.log" 2>&1 \
        || { echo "--- seat script output ---"; cat "$T/out.log"; fail "seat-comfyui.sh exited non-zero"; }
}

echo "=== 1. the default case: no COLOSSUL_COMFYUI_ARGS set ==="
run_seat
argc=$(sed 's/ARGC=//' "$T/argc.txt")
echo "  argc=$argc"
sed 's/^/    | /' "$T/argv.txt"

# The bug this exists to catch.
if grep -qxF '' "$T/argv.txt"; then
    echo ""
    echo "  Empty argument present in argv:"
    grep -nxF '' "$T/argv.txt" | sed 's/^/    line /'
    fail "a stray EMPTY argument reached ComfyUI - argparse would reject it and the seat would not start"
fi
echo "PASS: no empty arguments"

echo ""
echo "=== 2. the seat's own wiring is correct and complete ==="
# `--` before the pattern, or grep parses "--port" as one of its own options.
expect_pair() {
    grep -qxF -- "$1" "$T/argv.txt" || fail "missing flag $1"
    local got
    got="$(grep -A1 -xF -- "$1" "$T/argv.txt" | tail -1)"
    [ "$got" = "$2" ] || fail "$1 should be '$2', got '$got'"
    echo "  $1 $2"
}
grep -qxF -- 'main.py' "$T/argv.txt" || fail "main.py not passed"
expect_pair --listen 127.0.0.1
expect_pair --port 18211                                   # seat 2 ComfyUI
expect_pair --input-directory  "$T/workspace/colossul/seats/2/comfyui/input"
expect_pair --output-directory "$T/workspace/colossul/seats/2/comfyui/output"
expect_pair --temp-directory   "$T/workspace/colossul/seats/2/comfyui/temp"
expect_pair --user-directory   "$T/workspace/colossul/seats/2/comfyui/user"
expect_pair --database-url     "sqlite:///$T/workspace/colossul/seats/2/comfyui/user/comfyui.db"
grep -qxF -- '--disable-auto-launch' "$T/argv.txt" || fail "missing --disable-auto-launch"
echo "PASS: ports, per-seat directories and database all resolve to seat 2"

echo ""
echo "=== 3. the seat creates its own writable directories ==="
for d in input output temp user; do
    [ -d "$T/workspace/colossul/seats/2/comfyui/$d" ] || fail "did not create $d"
done
echo "PASS: input/output/temp/user created under seat 2"

echo ""
echo "=== 4. operator extras are appended, seat-owned flags stripped ==="
rm -f "$T/argv.txt"
run_seat COLOSSUL_COMFYUI_ARGS='--highvram --port 9999 --preview-method auto'
grep -qxF -- '--highvram' "$T/argv.txt" || fail "operator flag --highvram was dropped"
grep -qxF -- '--preview-method' "$T/argv.txt" || fail "operator flag --preview-method was dropped"
grep -qxF '9999' "$T/argv.txt" && fail "operator --port 9999 leaked through; the seat must own its port"
expect_pair --port 18211
echo "PASS: extras kept, --port stripped, seat port intact"

echo ""
echo "=== 5. a stray glob in extras is not expanded ==="
rm -f "$T/argv.txt"
touch "$T/comfy/loot1" "$T/comfy/loot2"
run_seat COLOSSUL_COMFYUI_ARGS='*'
grep -qxF 'loot1' "$T/argv.txt" && fail "extras were glob-expanded against the ComfyUI directory"

echo ""
echo "=== --cache-ram scales with seat count, and is overridable ==="
# ComfyUI's --cache-ram defaults assume it is the only ComfyUI on the box: it
# evicts cache only once free RAM drops below 10 GB. With four seats sharing one
# host, whoever needs memory at that moment meets the OOM killer first.
run_seat
expect_pair '--cache-ram' '32'   # 8 GB x NUM_SEATS(4)

# An operator must be able to tune it, including the two-value form.
run_seat COLOSSUL_CACHE_RAM="6 40"
expect_pair '--cache-ram' '6'
grep -qxF -- '40' "$T/argv.txt" \
    || fail "the second --cache-ram value did not reach argv: $(tr '\n' ' ' < "$T/argv.txt")"
echo "  two-value form passes through"

# …and to opt out entirely, back to ComfyUI's own defaults.
run_seat COLOSSUL_CACHE_RAM=""
grep -qxF -- '--cache-ram' "$T/argv.txt" \
    && fail "COLOSSUL_CACHE_RAM= should leave ComfyUI's own defaults alone"
grep -qxF '' "$T/argv.txt" \
    && fail "opting out left an empty argument in argv, which argparse rejects"
echo "  COLOSSUL_CACHE_RAM= restores ComfyUI's defaults, with no empty arg"
echo "PASS: RAM cache threshold is seat-aware and tunable"

echo ""
echo "=== 6. the shared model store is passed when present ==="
rm -f "$T/argv.txt"
mkdir -p "$T/etc"
printf 'colossul_shared:\n    base_path: %s\n' "$T/workspace/ComfyUI_Assets" > "$T/etc/extra_model_paths.yaml"
run_seat
expect_pair --extra-model-paths-config "$T/etc/extra_model_paths.yaml"
echo "PASS: --extra-model-paths-config points at the generated config"

echo ""
echo "=== 7. COLOSSUL_ASSETS_ROOT override is honoured, not silently ignored ==="
rm -f "$T/argv.txt" "$T/etc/extra_model_paths.yaml"
mkdir -p "$T/elsewhere"
printf 'colossul_shared:\n' > "$T/elsewhere/extra_model_paths.yaml"
run_seat COLOSSUL_ASSETS_ROOT="$T/elsewhere"
grep -qxF -- "$T/elsewhere/extra_model_paths.yaml" "$T/argv.txt" \
    || fail "COLOSSUL_ASSETS_ROOT override ignored - derived paths were frozen before the environment loaded"
echo "PASS: relocating the model store actually takes effect"

echo ""
echo "=== 8. GPU pinning reaches the process environment ==="
rm -f "$T/argv.txt"
cat > "$T/fake-python" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$T/argv.txt"
printf 'ARGC=%s\n' "\$#" > "$T/argc.txt"
printf '%s\n' "\${CUDA_VISIBLE_DEVICES:-<unset>}" > "$T/gpu.txt"
EOF
chmod +x "$T/fake-python"
run_seat
got="$(cat "$T/gpu.txt")"
[ "$got" = "2" ] || fail "seat 2 should run on GPU 2, got '$got'"
echo "  CUDA_VISIBLE_DEVICES=$got"
rm -f "$T/argv.txt"
run_seat GPU_MAP=4,5,6,7
got="$(cat "$T/gpu.txt")"
[ "$got" = "6" ] || fail "with GPU_MAP=4,5,6,7 seat 2 should be GPU 6, got '$got'"
echo "  with GPU_MAP=4,5,6,7 -> CUDA_VISIBLE_DEVICES=$got"
echo "PASS: GPU pinning and GPU_MAP both take effect"

# ── backend ──────────────────────────────────────────────────────────────────
echo ""
echo "=== 9. backend: own port, own ComfyUI, own outputs ==="
SRC="$T/workspace/colossul/src/storyrendr"
mkdir -p "$SRC/colossul-backend/.venv/bin"
cat > "$SRC/colossul-backend/.venv/bin/python" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$T/bargv.txt"
env | grep -E '^(OUTPUTS_DIR|COMFYUI_BASE_URL|COMFYUI_INPUT_DIR|COMFYUI_OUTPUT_DIR|COMFYUI_ROOT|ENVIRONMENT|CUDA_VISIBLE_DEVICES)=' \
    | sort > "$T/benv.txt"
EOF
chmod +x "$SRC/colossul-backend/.venv/bin/python"

env -i PATH="$PATH" HOME="$HOME" \
    COLOSSUL_LIB="$ROOT/scripts" COLOSSUL_ETC="$T/etc" WORKSPACE="$T/workspace" \
    bash "$ROOT/scripts/seat-backend.sh" 2 >"$T/out.log" 2>&1 \
    || { cat "$T/out.log"; fail "seat-backend.sh exited non-zero"; }

sed 's/^/    | /' "$T/bargv.txt"
grep -qxF -- '-m' "$T/bargv.txt" && grep -qxF -- 'uvicorn' "$T/bargv.txt" || fail "uvicorn not invoked"
grep -qxF -- 'app.main:app' "$T/bargv.txt" || fail "wrong ASGI app"
grep -A1 -xF -- '--port' "$T/bargv.txt" | tail -1 | grep -qxF '18212' \
    || fail "backend must use seat 2's port 18212"
grep -A1 -xF -- '--host' "$T/bargv.txt" | tail -1 | grep -qxF '127.0.0.1' \
    || fail "backend must bind loopback only"
echo "  --- environment ---"
sed 's/^/    | /' "$T/benv.txt"
grep -qxF "COMFYUI_BASE_URL=http://127.0.0.1:18211" "$T/benv.txt" \
    || fail "backend must point at SEAT 2's ComfyUI (18211), not another seat's"
grep -qxF "OUTPUTS_DIR=$T/workspace/colossul/seats/2/backend/outputs" "$T/benv.txt" \
    || fail "backend OUTPUTS_DIR must be seat 2's (this is what isolates the project database)"
grep -qxF "ENVIRONMENT=cloud" "$T/benv.txt" || fail "ENVIRONMENT should be cloud"
grep -qxF "CUDA_VISIBLE_DEVICES=2" "$T/benv.txt" \
    || fail "backend must be GPU-pinned too (it runs SAM3D)"
echo "PASS: backend bound to seat 2 throughout"

# ── frontend ─────────────────────────────────────────────────────────────────
echo ""
echo "=== 10. frontend: own port, proxies to its own backend and ComfyUI ==="
mkdir -p "$SRC/colossul-frontend/dist" "$SRC/colossul-frontend/node_modules/.bin"
touch "$SRC/colossul-frontend/dist/index.html"
cat > "$SRC/colossul-frontend/node_modules/.bin/vite" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$T/fargv.txt"
env | grep -E '^VITE_' | sort > "$T/fenv.txt"
EOF
chmod +x "$SRC/colossul-frontend/node_modules/.bin/vite"

env -i PATH="$PATH" HOME="$HOME" \
    COLOSSUL_LIB="$ROOT/scripts" COLOSSUL_ETC="$T/etc" WORKSPACE="$T/workspace" \
    bash "$ROOT/scripts/seat-frontend.sh" 2 >"$T/out.log" 2>&1 \
    || { cat "$T/out.log"; fail "seat-frontend.sh exited non-zero"; }

sed 's/^/    | /' "$T/fargv.txt"
grep -qxF -- 'preview' "$T/fargv.txt" || fail "vite preview not invoked"
grep -qxF -- '--strictPort' "$T/fargv.txt" \
    || fail "--strictPort missing; Vite would silently move onto another seat's port"
grep -A1 -xF -- '--port' "$T/fargv.txt" | tail -1 | grep -qxF '18210' \
    || fail "frontend must use seat 2's port 18210"
echo "  --- environment ---"
sed 's/^/    | /' "$T/fenv.txt"
grep -qxF "VITE_BACKEND_URL=http://127.0.0.1:18212" "$T/fenv.txt" \
    || fail "frontend /api must proxy to SEAT 2's backend (18212)"
grep -qxF "VITE_COMFYUI_URL=http://127.0.0.1:18211" "$T/fenv.txt" \
    || fail "frontend must proxy to SEAT 2's ComfyUI (18211)"
grep -qxF "VITE_ALLOWED_HOSTS=all" "$T/fenv.txt" \
    || fail "tunnel hostnames are random per boot; the host guard must be disabled"
echo "PASS: frontend bound to seat 2 throughout"

echo ""
echo "=== 11. no two seats resolve to the same wiring ==="
# Cheapest possible guard against a constant creeping into a seat script.
for s in 0 1 3; do
    rm -f "$T/fargv.txt"
    env -i PATH="$PATH" HOME="$HOME" \
        COLOSSUL_LIB="$ROOT/scripts" COLOSSUL_ETC="$T/etc" WORKSPACE="$T/workspace" \
        bash "$ROOT/scripts/seat-frontend.sh" "$s" >/dev/null 2>&1 || fail "seat $s frontend failed"
    p="$(grep -A1 -xF -- '--port' "$T/fargv.txt" | tail -1)"
    want=$((18190 + s * 10))
    [ "$p" = "$want" ] || fail "seat $s frontend used port $p, expected $want"
    echo "  seat $s -> $p"
done
echo "PASS: each seat resolves to its own port"

echo ""
echo "ALL SEAT ARGV CHECKS PASSED"
