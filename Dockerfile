# syntax=docker/dockerfile:1
#
# Colossul multi-seat Storyrendr image for Vast.ai
# ------------------------------------------------
# Runs N independent "seats" (default 4) in a single Vast.ai instance. Each
# seat is a full Storyrendr stack — ComfyUI + FastAPI backend + Vite preview
# frontend — pinned to its own GPU, so N employees can work concurrently
# without sharing a queue, a project database, or VRAM.
#
# The application source is NOT baked in. It is fetched on first boot by
# /opt/colossul/provision.sh (see docs/VAST_TEMPLATE.md), which keeps this
# image free of private code and lets employees pick up updates with a
# restart instead of an image rebuild.
#
# Build:
#   docker build -t <registry>/colossul-multiseat:latest .
#
ARG BASE_IMAGE=vastai/comfy:v0.30.0-cuda-13.2-py312
FROM ${BASE_IMAGE}

# image.source must point at THIS repo: GHCR uses it to link the published
# package to a repository, and pointing it at the private application repo
# would both break that link and imply the image contains that source.
LABEL org.opencontainers.image.title="Colossul multi-seat Storyrendr" \
      org.opencontainers.image.description="N GPU-pinned ComfyUI + Storyrendr seats in one Vast.ai instance" \
      org.opencontainers.image.source="https://github.com/WASasquatch/colossul-vast-multiseat"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ─────────────────────────────────────────────────────────────────────────────
# Seat topology
#
# Each seat owns a block of 10 external ports from 8190; internal ports are the
# vast.ai convention of external + 10000.
#
#   seat i   frontend   8190+i*10  ->  18190+i*10   <- what employees open
#            ComfyUI    8191+i*10  ->  18191+i*10
#            backend    8192+i*10  ->  18192+i*10   (loopback only by default)
#
# This range avoids every port the base image binds. Note in particular that
# its ComfyUI API wrapper listens on 18288, so the tempting "8188/8288/8388"
# per-seat layout collides on seat 1.
#
# COLOSSUL_ROOT is left unset here so lib/common.sh can derive it from
# $WORKSPACE, which the base image owns and an operator may relocate.
# ─────────────────────────────────────────────────────────────────────────────
ENV NUM_SEATS=4 \
    COLOSSUL_ETC=/etc/colossul \
    COLOSSUL_LIB=/opt/colossul \
    STORYRENDR_REPO=https://github.com/WASasquatch/storyrendr-services.git \
    STORYRENDR_REF=main

# The base image's supervisor scripts want OPEN_BUTTON_PORT present in the
# container, so set it here — but note this is NOT what makes the console's
# "Open" button appear. Vast decides that from the *template's* stored
# environment and never inspects the image's ENV, so the template must set
# OPEN_BUTTON_PORT=1111 as well or the console reports "Instance is running but
# has no web interface". See docs/VAST_TEMPLATE.md.
ENV OPEN_BUTTON_PORT=1111

# Instance Portal entries for the default 4 seats. Regenerate with
# `colossul-portal-config <n>` if you change NUM_SEATS, and update the
# template's exposed-port list to match.
ENV PORTAL_CONFIG="localhost:1111:11111:/:Instance Portal|localhost:8080:18080:/:Jupyter|localhost:8190:18190:/:Seat 0 Storyrendr|localhost:8191:18191:/:Seat 0 ComfyUI|localhost:8200:18200:/:Seat 1 Storyrendr|localhost:8201:18201:/:Seat 1 ComfyUI|localhost:8210:18210:/:Seat 2 Storyrendr|localhost:8211:18211:/:Seat 2 ComfyUI|localhost:8220:18220:/:Seat 3 Storyrendr|localhost:8221:18221:/:Seat 3 ComfyUI"

# ─────────────────────────────────────────────────────────────────────────────
# System dependencies the app needs but the ComfyUI base image doesn't carry:
#   node   — Vite build + the per-seat preview servers
#   ffmpeg — required by Storyrendr pipeline step 4 (clip stitching)
#   uv     — backend venv resolver used by install.sh / start.sh
# Baked here rather than provisioned so instance boot stays fast and offline.
# ─────────────────────────────────────────────────────────────────────────────
ARG NODE_MAJOR=20
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg git ffmpeg jq && \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    node --version && npm --version && ffmpeg -version | head -1

# The base image already ships uv (it builds its venvs with it). Only install
# if that ever stops being true, so we don't shadow their pinned version.
RUN if command -v uv >/dev/null 2>&1; then \
        echo "[build] using base image uv: $(uv --version)"; \
    else \
        curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh && \
        uv --version; \
    fi

# ─────────────────────────────────────────────────────────────────────────────
# Retire the base image's single-instance services.
#
#   comfyui     — replaced by N GPU-pinned seat units generated at provision
#                 time. Left enabled it would be a 5th ComfyUI competing for
#                 VRAM on GPU 0.
#   api-wrapper — a serverless shim for that instance. It binds internal port
#                 18288 and is useless for interactive seats.
#
# Supervisor only includes /etc/supervisor/conf.d/*.conf, so renaming the file
# deactivates the unit while keeping it readable for debugging. Match on the
# [program:...] header rather than a filename the base image doesn't guarantee.
# ─────────────────────────────────────────────────────────────────────────────
RUN set -euo pipefail; \
    shopt -s nullglob; \
    for prog in comfyui api-wrapper; do \
        found=0; \
        for f in /etc/supervisor/conf.d/*.conf; do \
            if grep -qiE "^\[program:${prog}\]" "$f"; then \
                mv "$f" "$f.stock-disabled"; \
                echo "[build] disabled stock unit [program:${prog}] ($f)"; \
                found=1; \
            fi; \
        done; \
        if [ "$found" -eq 0 ]; then \
            echo "[build] WARNING: no [program:${prog}] unit found; provision.sh will stop it by name at runtime."; \
        fi; \
    done

# ─────────────────────────────────────────────────────────────────────────────
# Our own scripts
# ─────────────────────────────────────────────────────────────────────────────
COPY scripts/ /opt/colossul/
RUN chmod +x /opt/colossul/*.sh /opt/colossul/bin/* && \
    ln -sf /opt/colossul/bin/colossul-seats /usr/local/bin/colossul-seats && \
    ln -sf /opt/colossul/bin/colossul-portal-config /usr/local/bin/colossul-portal-config && \
    mkdir -p /etc/colossul /var/log/portal

# One-shot provisioning unit. Runs once at boot, generates the seat units, then
# exits. Seat units are created by it rather than baked here, which guarantees
# no seat can start before its source tree and venv exist.
COPY supervisor/colossul-provision.conf /etc/supervisor/conf.d/colossul-provision.conf

# Documentation only — Vast exposes ports from the template's port list, and
# the base image itself declares none.
EXPOSE 8190 8191 8192 8200 8201 8202 8210 8211 8212 8220 8221 8222
