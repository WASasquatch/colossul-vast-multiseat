#!/usr/bin/env bash
# Shared helpers for the Colossul multi-seat image.
#
# Sourced by provision.sh and every per-seat wrapper. Single source of truth for
# seat port math, GPU assignment, ComfyUI/venv discovery, and the vast.ai boot
# conventions we have to cooperate with.
#
# shellcheck shell=bash

log()  { echo "[colossul] $*"; }
warn() { echo "[colossul] WARN: $*" >&2; }
die()  { echo "[colossul] ERROR: $*" >&2; exit 1; }

# ── Derived paths ────────────────────────────────────────────────────────────
# Recomputed rather than assigned once, because template overrides
# (COLOSSUL_ROOT, COLOSSUL_ASSETS_ROOT, WORKSPACE) arrive via /etc/environment
# and are therefore only visible AFTER load_vast_environment runs — which is
# after this file is sourced. Assigning once left ASSETS_ROOT pinned to the
# default while COLOSSUL_ROOT moved, i.e. seats written to one tree and looked
# for in another.
#
# WORKSPACE is defined by the vast.ai base image (default /workspace) and is the
# only path guaranteed to persist across instance stop/start.
# SRC_DIR/SEATS_DIR/ASSETS_ROOT are consumed by the scripts that source this
# file, so shellcheck can't see their use.
# shellcheck disable=SC2034
colossul_init_paths() {
    WORKSPACE="${WORKSPACE:-/workspace}"
    COLOSSUL_ETC="${COLOSSUL_ETC:-/etc/colossul}"
    COLOSSUL_ROOT="${COLOSSUL_ROOT:-$WORKSPACE/colossul}"
    COLOSSUL_LIB="${COLOSSUL_LIB:-/opt/colossul}"

    SRC_DIR="$COLOSSUL_ROOT/src/storyrendr"
    SEATS_DIR="$COLOSSUL_ROOT/seats"
    RUNTIME_ENV="$COLOSSUL_ETC/runtime.env"

    # One shared model tree, outside the ComfyUI install so a reinstall can't
    # take the weights with it and it can be moved to its own volume.
    ASSETS_ROOT="${COLOSSUL_ASSETS_ROOT:-$WORKSPACE/ComfyUI_Assets}"
}
colossul_init_paths

# ── vast.ai boot conventions ─────────────────────────────────────────────────

# Template environment variables (GITHUB_TOKEN, NUM_SEATS, ...) are written to
# /etc/environment by the base image's 10-prep-env.sh boot step, and every stock
# supervisor script re-sources it rather than trusting inheritance from
# supervisord. We do the same: without this, GITHUB_TOKEN can be absent from a
# seat/provisioner process and provisioning fails with a confusing auth error.
load_vast_environment() {
    set -a
    # shellcheck disable=SC1091
    . /etc/environment 2>/dev/null || true
    # shellcheck disable=SC1090
    [ -f "$WORKSPACE/.env" ] && . "$WORKSPACE/.env" 2>/dev/null
    set +a
    # Overrides only just became visible - re-derive everything built from them.
    colossul_init_paths
    return 0
}

# supervisord is started BEFORE vast.ai runs PROVISIONING_SCRIPT /
# PROVISIONING_MANIFEST (boot steps 65 then 75), and /.provisioning exists for
# the duration. Stock services block on it; so must we, or our provisioning
# races model downloads and our seats boot against a half-built instance.
wait_for_provisioning() {
    local what="${1:-startup}"
    while [ -f /.provisioning ]; do
        echo "[colossul] $what paused until instance provisioning completes (/.provisioning present)"
        sleep 5
    done
}

# ── Seat topology ────────────────────────────────────────────────────────────
# Each seat owns a contiguous block of 10 external ports starting at 8190, and
# the matching internal ports at +10000 (the base image convention: Caddy
# terminates TLS and auth on the external port and proxies to the internal one).
#
#   seat i   frontend  8190+i*10   <- the only port an employee needs
#            ComfyUI   8191+i*10
#            backend   8192+i*10   (loopback only by default)
#
# This range deliberately avoids every port the base image already uses. In
# particular the stock ComfyUI API wrapper listens on 18288, which an earlier
# "8188/8288/8388" layout collided with head-on.

frontend_ext() { echo $((  8190 + $1 * 10 )); }
frontend_int() { echo $(( 18190 + $1 * 10 )); }
comfyui_ext()  { echo $((  8191 + $1 * 10 )); }
comfyui_int()  { echo $(( 18191 + $1 * 10 )); }
backend_ext()  { echo $((  8192 + $1 * 10 )); }
backend_int()  { echo $(( 18192 + $1 * 10 )); }

# Ports the vastai/comfy base image binds or reserves. Verified against its
# supervisor scripts: instance portal 11111, tunnel manager 11112, tensorboard
# 16006, jupyter 18080, ComfyUI 18188, ComfyUI API wrapper 18288, syncthing
# 18384 — plus their external counterparts.
RESERVED_PORTS="1111 6006 8080 8188 8288 8384 11111 11112 16006 18080 18188 18288 18384"

# Fail loudly rather than let a seat crash-loop against a base-image service.
assert_no_reserved_collisions() {
    local n="$1" i p bad=""
    for ((i = 0; i < n; i++)); do
        for p in "$(frontend_ext "$i")" "$(frontend_int "$i")" \
                 "$(comfyui_ext "$i")"  "$(comfyui_int "$i")" \
                 "$(backend_ext "$i")"  "$(backend_int "$i")"; do
            case " $RESERVED_PORTS " in
                *" $p "*) bad="$bad seat$i:$p" ;;
            esac
        done
    done
    [ -z "$bad" ] || return 1
    return 0
}

num_seats() {
    local n="${NUM_SEATS:-4}"
    case "$n" in
        ''|*[!0-9]*) warn "NUM_SEATS='$n' is not a number - falling back to 4"; echo 4; return ;;
    esac
    if [ "$n" -lt 1 ]; then
        warn "NUM_SEATS=$n < 1 - falling back to 1"; echo 1; return
    fi
    echo "$n"
}

seat_dir() { echo "$SEATS_DIR/$1"; }

# Physical GPU for a seat. Identity by default (seat 0 -> GPU 0, ...). Override
# with GPU_MAP as a comma-separated list, e.g. GPU_MAP=4,5,6,7.
gpu_for_seat() {
    local seat="$1"
    if [ -n "${GPU_MAP:-}" ]; then
        local -a map
        IFS=',' read -r -a map <<< "$GPU_MAP"
        if [ "$seat" -lt "${#map[@]}" ]; then
            echo "${map[$seat]}" | tr -d '[:space:]'
            return 0
        fi
        warn "GPU_MAP has ${#map[@]} entries but seat $seat was requested - using GPU $seat"
    fi
    echo "$seat"
}

# ── ComfyUI argument hygiene ─────────────────────────────────────────────────
# The base image exports COMFYUI_ARGS="--disable-auto-launch --enable-cors-header
# --port 18188" for its single stock instance. Appending that verbatim to a seat
# command would let argparse's last-wins behaviour pin every seat to port 18188.
# So we ignore COMFYUI_ARGS entirely and take extras from COLOSSUL_COMFYUI_ARGS,
# stripping anything that would fight the per-seat wiring.
#
# Prints the sanitised arguments on stdout.
COMFYUI_OWNED_FLAGS="--port --listen --cuda-device --database-url
--input-directory --output-directory --temp-directory --user-directory --base-directory"

sanitize_comfyui_args() {
    local -a out=()
    local skip_next=0 tok flag owned f

    for tok in "$@"; do
        if [ "$skip_next" = "1" ]; then
            # Drop this flag's value, unless it's clearly the next flag.
            skip_next=0
            case "$tok" in -*) ;; *) continue ;; esac
        fi

        flag="${tok%%=*}"
        owned=0
        for f in $COMFYUI_OWNED_FLAGS; do
            [ "$flag" = "$f" ] && { owned=1; break; }
        done

        if [ "$owned" = "1" ]; then
            warn "ignoring '$flag' from COLOSSUL_COMFYUI_ARGS - the seat owns that setting" >&2
            # "--flag=value" carries its value inline; "--flag value" doesn't.
            case "$tok" in *=*) ;; *) skip_next=1 ;; esac
            continue
        fi
        out+=("$tok")
    done

    # Emit NOTHING when there are no extras. `printf '%s\n' "${out[@]:-}"` would
    # print a single empty line, which mapfile turns into one empty-string
    # argument; argparse rejects a stray empty arg ("unrecognized arguments:"),
    # so with no COLOSSUL_COMFYUI_ARGS set — the default — every seat's ComfyUI
    # would have refused to start.
    if [ "${#out[@]}" -gt 0 ]; then
        printf '%s\n' "${out[@]}"
    fi
}

# ── Runtime discovery ────────────────────────────────────────────────────────
# vastai/comfy stages ComfyUI at /opt/workspace-internal/ComfyUI and the base
# image copies it to $WORKSPACE on first boot, so the path differs between build
# and run time. Detection therefore happens at runtime, in provision.sh.

detect_comfyui_home() {
    local candidates=(
        "${COMFYUI_HOME:-}"
        "$WORKSPACE/ComfyUI"
        /workspace/ComfyUI
        /opt/ComfyUI
        "$WORKSPACE/comfyui"
        /opt/workspace-internal/ComfyUI
    )
    local c
    for c in "${candidates[@]}"; do
        [ -n "$c" ] && [ -f "$c/main.py" ] && [ -d "$c/comfy" ] && { echo "$c"; return 0; }
    done

    local found
    found="$(find "$WORKSPACE" /opt -maxdepth 5 -type f -name main.py \
                -execdir test -d comfy \; -print -quit 2>/dev/null || true)"
    if [ -n "$found" ]; then
        dirname "$found"
        return 0
    fi
    return 1
}

detect_comfyui_python() {
    local home="$1"
    local candidates=(
        "${COMFYUI_PYTHON:-}"
        /venv/main/bin/python
        "$home/venv/bin/python"
        "$home/.venv/bin/python"
    )
    local c
    for c in "${candidates[@]}"; do
        [ -n "$c" ] && [ -x "$c" ] && "$c" -c 'import torch' >/dev/null 2>&1 && { echo "$c"; return 0; }
    done
    for c in "${candidates[@]}" "$(command -v python3 || true)"; do
        [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

load_runtime_env() {
    [ -f "$RUNTIME_ENV" ] || die "$RUNTIME_ENV missing - provisioning has not completed. Run: colossul-seats provision"
    # shellcheck disable=SC1090
    source "$RUNTIME_ENV"
    [ -n "${COMFYUI_HOME:-}" ] || die "COMFYUI_HOME not set in $RUNTIME_ENV"
    [ -n "${COMFYUI_PYTHON:-}" ] || die "COMFYUI_PYTHON not set in $RUNTIME_ENV"
}

# Mirror a wrapper's output into the Instance Portal log viewer while leaving
# supervisor's /dev/stdout capture (which feeds vast.ai's log stream) intact.
# log-tee is the base image's own helper: it strips ANSI for the companion
# /var/log/<name>.log that the portal renders. Fall back to tee without it.
portal_log() {
    local name="$1" dir=/var/log/portal
    # Never fatal: losing the portal log view is a cosmetic problem, but dying
    # here under `set -e` would take the whole seat down with it.
    mkdir -p "$dir" 2>/dev/null || true
    if [ ! -w "$dir" ]; then
        warn "$dir is not writable - Instance Portal log view unavailable for $name"
        return 0
    fi
    if command -v log-tee >/dev/null 2>&1; then
        exec > >(log-tee "$dir/${name}.log")
    else
        exec > >(tee -a "$dir/${name}.log")
    fi
    exec 2>&1
}

# ── Shared model store ───────────────────────────────────────────────────────
# One model tree for every seat, deliberately OUTSIDE the ComfyUI install so it
# survives a ComfyUI reinstall/upgrade and can be relocated or mounted on its
# own volume. Wired in with extra_model_paths.yaml rather than by moving
# ComfyUI's own models/ dir, so anything already there (the base image symlinks
# SD1.5 into it) keeps resolving.
#
# ASSETS_ROOT itself is set by colossul_init_paths(), so it re-derives after the
# vast environment loads; assigning it again here would freeze the default and
# silently ignore a COLOSSUL_ASSETS_ROOT set in the template.

# Canonical folder map for ComfyUI v0.30, from folder_names_and_paths. Keys with
# two directories carry a legacy alias that older workflows still reference:
#   text_encoders    <- models/clip
#   diffusion_models <- models/unet
#   controlnet       <- models/t2i_adapter
#
# custom_nodes and datasets are intentionally absent: they are base-path (not
# models/) entries, and redirecting custom_nodes would move the Colossul node
# pack away from the install every seat loads it from.
COMFYUI_FOLDER_MAP=(
    "checkpoints:models/checkpoints"
    "configs:models/configs"
    "loras:models/loras"
    "vae:models/vae"
    "text_encoders:models/text_encoders,models/clip"
    "diffusion_models:models/diffusion_models,models/unet"
    "clip_vision:models/clip_vision"
    "style_models:models/style_models"
    "embeddings:models/embeddings"
    "diffusers:models/diffusers"
    "vae_approx:models/vae_approx"
    "controlnet:models/controlnet,models/t2i_adapter"
    "gligen:models/gligen"
    "upscale_models:models/upscale_models"
    "latent_upscale_models:models/latent_upscale_models"
    "hypernetworks:models/hypernetworks"
    "photomaker:models/photomaker"
    "classifiers:models/classifiers"
    "model_patches:models/model_patches"
    "audio_encoders:models/audio_encoders"
    "background_removal:models/background_removal"
    "frame_interpolation:models/frame_interpolation"
    "geometry_estimation:models/geometry_estimation"
    "optical_flow:models/optical_flow"
    "detection:models/detection"
)

# Materialise the shared tree. ComfyUI tolerates missing dirs, but creating them
# gives operators an obvious place to drop weights.
ensure_asset_dirs() {
    local entry dirs d
    local -a _d
    for entry in "${COMFYUI_FOLDER_MAP[@]}"; do
        dirs="${entry#*:}"
        IFS=',' read -r -a _d <<< "$dirs"
        for d in "${_d[@]}"; do
            mkdir -p "$ASSETS_ROOT/$d"
        done
    done
}

# Emit an extra_model_paths.yaml pointing every model folder at the shared tree.
#
# is_default makes this store the default download target, so a model pulled
# from one seat's ComfyUI Manager lands where all four seats can see it instead
# of inside a single install.
#
#   write_extra_model_paths <output-path>
write_extra_model_paths() {
    # Named outfile, not out: `out` is the array inside sanitize_comfyui_args,
    # and reusing the name is the exact string/array confusion that produced a
    # stray empty argument there.
    local outfile="$1" entry key dirs d
    local -a _d
    {
        echo "# Generated by Colossul provision.sh - do not edit by hand."
        echo "# Regenerate with: colossul-seats provision"
        echo "#"
        echo "# One shared model store for every seat. Keeping it outside the"
        echo "# ComfyUI install means upgrading or reinstalling ComfyUI cannot"
        echo "# disturb the weights, and the store can live on its own volume."
        echo "colossul_shared:"
        echo "    base_path: $ASSETS_ROOT"
        echo "    is_default: true"
        for entry in "${COMFYUI_FOLDER_MAP[@]}"; do
            key="${entry%%:*}"
            dirs="${entry#*:}"
            if [[ "$dirs" == *,* ]]; then
                # Block scalar for multi-directory keys. No inline comments in
                # here - YAML would fold them into the value.
                echo "    ${key}: |"
                IFS=',' read -r -a _d <<< "$dirs"
                for d in "${_d[@]}"; do
                    echo "        ${d}/"
                done
            else
                echo "    ${key}: ${dirs}/"
            fi
        done
    } > "$outfile"
}

# ── Dependency protection ────────────────────────────────────────────────────
# Custom node requirements.txt files routinely list bare `torch`, `numpy` or
# `opencv-python`. Installing enough of them into one shared venv eventually
# replaces the CUDA torch build with a CPU wheel, or downgrades numpy under
# compiled packages — and the failure surfaces much later as an unrelated
# ImportError or a silent fall back to CPU inference.
#
# Defence: pin the packages we refuse to lose to EXACTLY what is installed, and
# let a conflicting request fail loudly at install time instead of quietly
# mutating the environment.
PROTECTED_PACKAGES="torch torchvision torchaudio xformers triton numpy \
opencv-python opencv-python-headless opencv-contrib-python onnxruntime onnxruntime-gpu"

# Writes a constraints file reflecting the currently-installed versions.
#   write_pip_constraints <python> <outfile>
write_pip_constraints() {
    local py="$1" outfile="$2"
    "$py" - "$PROTECTED_PACKAGES" <<'PY' > "$outfile"
import sys
try:
    import importlib.metadata as md
except ImportError:
    sys.exit(0)
for name in sys.argv[1].split():
    try:
        print(f"{name}=={md.version(name)}")
    except Exception:
        pass
PY
}

# Export the constraint environment for a pip/uv invocation.
#   pip reads PIP_CONSTRAINT; uv ignores it entirely and reads UV_CONSTRAINT,
#   so both must be set or the protection silently does nothing under uv.
#   The +cuXXX local version on torch only resolves from PyTorch's own index,
#   which the base image identifies via PYTORCH_BACKEND (e.g. cu130).
export_constraint_env() {
    local cfile="$1"
    export PIP_CONSTRAINT="$cfile" UV_CONSTRAINT="$cfile"
    export PIP_BUILD_CONSTRAINT="$cfile" UV_BUILD_CONSTRAINT="$cfile"
    if [ -n "${PYTORCH_BACKEND:-}" ]; then
        export PIP_EXTRA_INDEX_URL="https://download.pytorch.org/whl/${PYTORCH_BACKEND}"
        export UV_INDEX_STRATEGY="unsafe-best-match"
    fi
}

# ── Tunnels ──────────────────────────────────────────────────────────────────
# The base image's tunnel_manager opens a Cloudflare quick tunnel for every
# entry in /etc/portal.yaml, so each seat already has a public URL. These two
# are split so the parser can be tested without a running instance.

# Read /get-all-quick-tunnels JSON on stdin, print "port<TAB>url" lines.
# Silent on malformed input: a missing tunnel must degrade to "show the direct
# address", never to a crash or a wrong URL.
parse_tunnel_json() {
    python3 -c '
import json, re, sys
try:
    for t in json.load(sys.stdin):
        target, url = t.get("targetUrl", ""), t.get("tunnelUrl", "")
        # Matches "localhost:8190" and "http://localhost:8190/" alike - the
        # scheme colon is not followed by digits.
        m = re.search(r":(\d+)", str(target))
        if m and url:
            print(f"{m.group(1)}\t{url}")
except Exception:
    pass
' 2>/dev/null || true
}

tunnel_map() {
    local json
    json="$(curl -s --max-time 3 http://127.0.0.1:11112/get-all-quick-tunnels 2>/dev/null)" || return 0
    [ -n "$json" ] || return 0
    printf '%s' "$json" | parse_tunnel_json
}

# ── Access summary ───────────────────────────────────────────────────────────
# Everything an operator needs, in one block, printed last. The credentials and
# tunnel URLs do exist in the boot log already, but scattered across hundreds of
# lines of pip output and cloudflared chatter - which is not usable when someone
# just wants to hand four links to four artists.

# The instance credential: operator-chosen WEB_PASSWORD when set, else the
# auto-generated token. Empty when neither is available yet.
web_password() {
    echo "${WEB_PASSWORD:-${OPEN_BUTTON_TOKEN:-}}"
}

# Append the auth token to a URL so it logs straight in - Caddy accepts
# ?token= in place of the basic-auth prompt (it is what the Open button sets
# as a cookie). Only for real URLs; placeholders pass through untouched.
tokenized() {
    local url="$1" pw
    pw="$(web_password)"
    case "$url" in
        http*) if [ -n "$pw" ]; then printf '%s/?token=%s' "$url" "$pw"; else printf '%s' "$url"; fi ;;
        *) printf '%s' "$url" ;;
    esac
}

# Mirror access info into /var/log/portal/ACCESS.log so it shows up as its own
# entry in the Instance Portal log viewer and survives on disk. Falls back to
# plain pass-through when the directory isn't writable (tests, degraded boot).
access_log_tee() {
    local f=/var/log/portal/ACCESS.log
    if mkdir -p /var/log/portal 2>/dev/null && [ -w /var/log/portal ]; then
        if [ "${1:-}" = "--append" ]; then tee -a "$f"; else tee "$f"; fi
    else
        cat
    fi
}

# The instance's public address for a given EXTERNAL port. Vast publishes the
# host-side mapping as VAST_TCP_PORT_<external>, so prefer the Cloudflare tunnel
# and fall back to the direct address.
external_url() {
    # Named tmap, not map: `map` is the array inside gpu_for_seat, and reusing
    # the name is the string/array confusion that once produced a stray empty
    # argument in sanitize_comfyui_args.
    local ext="$1" tmap="${2:-}" tunnel var hostport
    tunnel="$(printf '%s\n' "$tmap" | awk -v p="$ext" -F'\t' '$1==p {print $2; exit}')"
    if [ -n "$tunnel" ]; then printf '%s' "$tunnel"; return 0; fi
    var="VAST_TCP_PORT_${ext}"
    hostport="${!var:-}"
    if [ -n "${PUBLIC_IPADDR:-}" ] && [ -n "$hostport" ]; then
        printf 'https://%s:%s' "$PUBLIC_IPADDR" "$hostport"
    else
        printf '<port %s - see IP & Port Info>' "$ext"
    fi
}

# Wait for the seat programs to reach RUNNING, so the summary reflects reality
# rather than intent. Bounded: a stuck seat must not hold the summary hostage.
# How many seat processes are RUNNING. Uses bare `supervisorctl status` and
# filters here: supervisorctl accepts `<name>` or `<gname>:*` but does NOT glob
# group names (it doesn't even import fnmatch), so `seat*:*` silently matches
# nothing and every count comes back zero.
seats_running() {
    supervisorctl status 2>/dev/null | awk '/^seat[0-9]+-/ && /RUNNING/' | wc -l
}

seat_status_lines() {
    supervisorctl status 2>/dev/null | awk '/^seat[0-9]+-/'
}

wait_for_seats() {
    local n="$1" timeout="${2:-120}" waited=0 want got
    want=$(( n * 3 ))
    while [ "$waited" -lt "$timeout" ]; do
        got="$(seats_running)"
        [ "${got:-0}" -ge "$want" ] && return 0
        sleep 5; waited=$(( waited + 5 ))
    done
    return 1
}

# Printed as soon as the Instance Portal's tunnel exists - minutes before the
# seats. Every seat URL shows a spinner while provisioning runs, so without
# this the operator has nothing clickable until the very end.
# Pure print; call sites tee it into ACCESS.log.
print_early_access() {
    local timeout="${1:-45}" waited=0 url="" tmap="" pw
    while :; do
        tmap="$(tunnel_map)"
        url="$(printf '%s\n' "$tmap" | awk -F'\t' '$1==1111 {print $2; exit}')"
        [ -n "$url" ] && break
        [ "$waited" -ge "$timeout" ] && break
        sleep 5; waited=$(( waited + 5 ))
    done
    [ -n "$url" ] || url="$(external_url 1111 "$tmap")"
    pw="$(web_password)"; [ -n "$pw" ] || pw="<see the 'Your web credentials' lines in this log>"

    echo ""
    echo "------------------------------------------------------------------"
    echo "  CONTROL PANEL IS UP — you can open it NOW (setup continues)"
    case "$url" in
        http*) echo "      $(tokenized "$url")" ;;
        *)     echo "      $url" ;;
    esac
    echo "      username: vastai    password: $pw"
    echo ""
    echo "  Seat links appear on that page as they come up. The READY block"
    echo "  prints at the very end of this log when everything is done."
    echo "------------------------------------------------------------------"
    echo ""
}

# Say plainly whether any weights are on disk.
#
# Model sets are opt-in, which is right — nobody should spend 40 GB of a rented
# GPU's time by accident — but the consequence is that a fresh instance opens a
# workflow to ComfyUI's "Missing Models" dialog, which reads as a broken image
# rather than as a choice nobody made yet. So state it in the READY block, where
# it cannot scroll past.
print_model_status() {
    local root="${ASSETS_ROOT}/models" n=0
    [ -d "$root" ] && n="$(find "$root" -type f \
        \( -name '*.safetensors' -o -name '*.ckpt' -o -name '*.pt' -o -name '*.pth' -o -name '*.gguf' \) \
        2>/dev/null | wc -l)"

    # Is the background download job still working?
    local running=0
    supervisorctl status colossul-models 2>/dev/null | grep -q RUNNING && running=1

    echo "  MODELS"
    if [ "$running" = "1" ]; then
        echo "      DOWNLOADING NOW, in the background: ${MODEL_SETS:-?}"
        echo "      $n file(s) landed so far in $root"
        echo "      The seats above work already. A workflow opened before its"
        echo "      weights arrive will say \"Missing Models\" — reopen it later."
        echo ""
        echo "      Follow it:   colossul-seats models-log"
        echo "      (also in the Instance Portal -> Logs -> models)"
    elif [ "${n:-0}" -gt 0 ]; then
        echo "      $n weight file(s) in $root"
        echo "      Add more:  colossul-seats models --list"
    else
        echo "      NONE DOWNLOADED — ComfyUI will show \"Missing Models\" on any"
        echo "      workflow that needs weights."
        echo ""
        echo "      See what is available:   colossul-seats models --list"
        echo "      Download a set now:      colossul-seats models minimax-h3"
        echo "      Or at boot, in the Vast template's Docker Options:"
        echo "          -e MODEL_SETS=all"
    fi
    echo ""
}

print_access_summary() {
    local n="$1" tmap i gpu pw
    tmap="$(tunnel_map)"
    # WEB_PASSWORD when the operator set one, else the generated token.
    pw="$(web_password)"; [ -n "$pw" ] || pw="<see the 'Your web credentials' line above>"

    echo ""
    echo "=================================================================="
    echo "  COLOSSUL MULTI-SEAT — READY"
    echo "=================================================================="
    echo ""
    echo "  LOG IN WITH"
    echo "      username:  vastai"
    echo "      password:  $pw"
    echo ""
    echo "  INSTANCE PORTAL (all seats listed here)"
    echo "      $(tokenized "$(external_url 1111 "$tmap")")"
    echo ""
    echo "  GIVE ONE LINK TO EACH ARTIST (each logs straight in)"
    printf '      %-5s %-4s %s\n' "SEAT" "GPU" "STORYRENDR"
    for ((i = 0; i < n; i++)); do
        gpu="$(gpu_for_seat "$i")"
        printf '      %-5s %-4s %s\n' "$i" "$gpu" \
            "$(tokenized "$(external_url "$(frontend_ext "$i")" "$tmap")")"
    done
    echo ""
    echo "  ComfyUI directly (optional, for advanced use)"
    for ((i = 0; i < n; i++)); do
        printf '      seat %-2s %s\n' "$i" "$(external_url "$(comfyui_ext "$i")" "$tmap")"
    done
    echo ""
    print_model_status
    echo "  NOTES"
    echo "      - The links above are PRE-AUTHENTICATED: anyone holding one is"
    echo "        logged in. Treat them like passwords; send privately."
    echo "      - If a login box ever appears:  vastai / the password above,"
    echo "        or append  ?token=$pw  to the URL."
    echo "      - This block is saved to /var/log/portal/ACCESS.log"
    echo "        (Instance Portal -> Logs -> ACCESS)."
    echo "      - Put model weights in: ${ASSETS_ROOT}/models  (shared by all seats)"
    echo "      - Admin:  colossul-seats status | urls | logs <n> | restart <n>"
    echo ""
    echo "=================================================================="
    echo ""
}

# ── Supervisor units ─────────────────────────────────────────────────────────
# Emit one seat's three programs plus a group, so an operator can recycle a
# single employee's stack (`supervisorctl restart seat2:`). Lives here rather
# than inline in provision.sh so tests can generate units without provisioning.
#
#   write_seat_unit <seat-index> <output-path>
write_seat_unit() {
    local i="$1" outfile="$2"
    local gpu; gpu="$(gpu_for_seat "$i")"

    {
        echo "; Seat $i - GPU $gpu"
        echo ";   frontend 127.0.0.1:$(frontend_int "$i")  (external $(frontend_ext "$i"))"
        echo ";   ComfyUI  127.0.0.1:$(comfyui_int "$i")  (external $(comfyui_ext "$i"))"
        echo ";   backend  127.0.0.1:$(backend_int "$i")  (loopback only)"
        echo "; Generated by provision.sh - regenerate with: colossul-seats provision"

        local svc name rest prio startsecs
        for svc in comfyui:100:20 backend:200:10 frontend:300:10; do
            name="${svc%%:*}"; rest="${svc#*:}"
            prio="${rest%%:*}"; startsecs="${rest#*:}"
            echo ""
            echo "[program:seat${i}-${name}]"
            echo "environment=PROC_NAME=\"%(program_name)s\""
            echo "command=${COLOSSUL_LIB}/seat-${name}.sh $i"
            echo "autostart=true"
            echo "autorestart=true"
            echo "startsecs=${startsecs}"
            echo "startretries=3"
            echo "priority=${prio}"
            echo "stopasgroup=true"
            echo "killasgroup=true"
            echo "stopwaitsecs=30"
            echo "stdout_logfile=/dev/stdout"
            echo "stdout_logfile_maxbytes=0"
            echo "redirect_stderr=true"
        done

        echo ""
        echo "[group:seat${i}]"
        echo "programs=seat${i}-comfyui,seat${i}-backend,seat${i}-frontend"
    } > "$outfile"
}

# A one-shot unit that downloads model weights alongside the running seats.
#
# NOT run inline from provisioning: the full set is hundreds of gigabytes, and
# downloading it before the seats are registered would leave four artists staring
# at a dead instance for over an hour while nothing they need is even blocked on
# it. ComfyUI starts fine without weights and picks them up as they land, so this
# runs behind the seats instead.
#
# autorestart=false — it is a job, not a service. When it exits, it is done.
# Its log is a portal log so it shows up as its own tab in the Instance Portal.
write_models_unit() {
    local outfile="$1" sets="$2"
    {
        echo "; Model downloads: $sets"
        echo "; Runs once, in the background, while the seats serve traffic."
        echo "; Progress:  colossul-seats models-log     Re-run:  colossul-seats models $sets"
        echo ""
        echo "[program:colossul-models]"
        echo "environment=PROC_NAME=\"%(program_name)s\",MODEL_SETS=\"${sets}\""
        echo "command=${COLOSSUL_LIB}/install-models.sh"
        echo "autostart=true"
        echo "autorestart=false"
        echo "startsecs=0"
        echo "exitcodes=0,1"
        echo "priority=900"
        echo "stopasgroup=true"
        echo "killasgroup=true"
        echo "stopwaitsecs=30"
        echo "stdout_logfile=/var/log/portal/models.log"
        echo "stdout_logfile_maxbytes=10MB"
        echo "stdout_logfile_backups=1"
        echo "redirect_stderr=true"
    } > "$outfile"
}
