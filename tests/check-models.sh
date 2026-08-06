#!/usr/bin/env bash
# Verify the shared model store wiring.
#
# Every seat reads one model tree via extra_model_paths.yaml, so a checkpoint is
# stored once regardless of seat count. A mistake here is quiet and expensive:
# ComfyUI simply won't list a model type, and the first anyone notices is an
# empty dropdown mid-shot. These tests parse the generated YAML exactly the way
# ComfyUI's load_extra_path_config does.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export COLOSSUL_LIB="$ROOT/scripts"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Point the store somewhere disposable before sourcing.
export WORKSPACE="$T/workspace"
export COLOSSUL_ASSETS_ROOT="$T/workspace/ComfyUI_Assets"
# shellcheck source=../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

fail() { echo "FAIL: $*"; exit 1; }
PY="${PYTHON:-python3}"

echo "=== 1. generate the config and the directory tree ==="
ensure_asset_dirs
write_extra_model_paths "$T/extra_model_paths.yaml"
echo "  wrote $(wc -l < "$T/extra_model_paths.yaml") lines, ${#COMFYUI_FOLDER_MAP[@]} folder types"

if ! "$PY" -c 'import yaml' 2>/dev/null; then
    echo "SKIP: pyyaml not available; cannot validate the generated YAML"
    exit 0
fi

echo ""
echo "=== 2. parses as ComfyUI parses it, and resolves onto real dirs ==="
ASSETS_ROOT="$ASSETS_ROOT" "$PY" - "$T/extra_model_paths.yaml" <<'EOF' || exit 1
import os, sys, yaml

path = sys.argv[1]
assets = os.environ["ASSETS_ROOT"]
with open(path) as fh:
    conf = yaml.safe_load(fh)

assert list(conf.keys()) == ["colossul_shared"], f"unexpected top-level keys: {list(conf)}"
sec = conf["colossul_shared"]

base = sec.pop("base_path", None)
assert base == assets, f"base_path is {base!r}, expected {assets!r}"
assert sec.pop("is_default", None) is True, "is_default must be true so downloads land in the shared store"

# custom_nodes/datasets are base-path entries; redirecting custom_nodes would
# move the Colossul node pack away from the install every seat loads from.
for forbidden in ("custom_nodes", "datasets"):
    assert forbidden not in sec, f"{forbidden} must not be redirected into the model store"

# Mirrors ComfyUI's load_extra_path_config: values may be a block scalar
# holding several directories, each joined onto base_path.
missing = []
resolved = 0
for key, value in sec.items():
    entries = [x.strip() for x in str(value).split("\n") if x.strip()]
    assert entries, f"{key} resolved to no directories"
    for rel in entries:
        assert not os.path.isabs(rel), f"{key}: {rel} should be relative to base_path"
        assert rel.startswith("models/"), f"{key}: {rel} is not under models/"
        full = os.path.join(base, rel)
        resolved += 1
        if not os.path.isdir(full):
            missing.append(full)

assert not missing, "ensure_asset_dirs did not create:\n  " + "\n  ".join(missing)
print(f"  PASS: {len(sec)} keys -> {resolved} directories, all present under {base}")
EOF

echo ""
echo "=== 3. legacy aliases are preserved ==="
# Old workflows still reference models/clip, models/unet and models/t2i_adapter.
ASSETS_ROOT="$ASSETS_ROOT" "$PY" - "$T/extra_model_paths.yaml" <<'EOF' || exit 1
import sys, yaml
sec = yaml.safe_load(open(sys.argv[1]))["colossul_shared"]
expect = {
    "text_encoders":    {"models/text_encoders/", "models/clip/"},
    "diffusion_models": {"models/diffusion_models/", "models/unet/"},
    "controlnet":       {"models/controlnet/", "models/t2i_adapter/"},
}
for key, want in expect.items():
    got = {x.strip() for x in str(sec[key]).split("\n") if x.strip()}
    assert got == want, f"{key}: got {got}, expected {want}"
    print(f"  {key}: {sorted(got)}")
print("  PASS: all three legacy aliases present")
EOF

echo ""
echo "=== 4. covers ComfyUI v0.30's model folder set ==="
ASSETS_ROOT="$ASSETS_ROOT" "$PY" - "$T/extra_model_paths.yaml" <<'EOF' || exit 1
import sys, yaml
sec = yaml.safe_load(open(sys.argv[1]))["colossul_shared"]
sec.pop("base_path", None); sec.pop("is_default", None)
# From folder_names_and_paths in ComfyUI v0.30.0, minus the base-path entries.
canonical = {
    "checkpoints","configs","loras","vae","text_encoders","diffusion_models",
    "clip_vision","style_models","embeddings","diffusers","vae_approx",
    "controlnet","gligen","upscale_models","latent_upscale_models",
    "hypernetworks","photomaker","classifiers","model_patches",
    "audio_encoders","background_removal","frame_interpolation",
    "geometry_estimation","optical_flow","detection",
}
got = set(sec)
missing, extra = canonical - got, got - canonical
assert not missing, f"model folders not shared (they would fall back to per-install): {sorted(missing)}"
assert not extra, f"unknown folder keys ComfyUI will ignore: {sorted(extra)}"
print(f"  PASS: all {len(canonical)} model folder types are shared")
EOF

echo ""
echo "=== 5. the seat passes the config to ComfyUI ==="
grep -q -- '--extra-model-paths-config' "$ROOT/scripts/seat-comfyui.sh" \
    || fail "seat-comfyui.sh must pass --extra-model-paths-config or seats ignore the shared store"
# It must stay user-extendable: ComfyUI appends this flag, so it is deliberately
# NOT in the seat-owned strip list.
if grep -q 'extra-model-paths-config' <<< "$COMFYUI_OWNED_FLAGS"; then
    fail "--extra-model-paths-config must not be stripped; ComfyUI appends it, so operator configs should add to ours"
fi
echo "PASS: seat passes it, and operator-supplied configs still append"

echo ""
echo "=== 6. store lives outside the ComfyUI install ==="
case "$ASSETS_ROOT" in
    *"/ComfyUI/"*) fail "the store is inside the ComfyUI install; a reinstall would take the weights with it" ;;
esac
echo "PASS: $ASSETS_ROOT is independent of the ComfyUI install"

echo ""
echo "ALL MODEL STORE CHECKS PASSED"
