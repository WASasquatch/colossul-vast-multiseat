#!/usr/bin/env bash
# Pull newer Colossul scripts and manifests onto a RUNNING instance.
#
#   colossul self-update            take the latest main
#   colossul self-update <ref>      take a tag, branch or commit
#   colossul self-update --check    show what is new, change nothing
#
# Why this exists: destroying and recreating an instance to pick up a script fix
# costs a full re-provision — and on a box that has pulled hundreds of gigabytes
# of weights, that is an expensive way to change a shell script.
#
# What it CANNOT update, because those live in Docker layers rather than in this
# repo's scripts:
#   - the base image, and anything installed by a Dockerfile RUN (Node, ffmpeg,
#     uv, the retired stock supervisor units)
#   - Dockerfile ENV defaults (COMFYUI_REF, MODEL_SETS, ENABLE_COMFYUI_MANAGER).
#     The values already in the container's environment stay as they are; pass
#     them explicitly if you want a new default, or recreate the instance.
# For those, rent a new instance on a newer image tag.
set -uo pipefail

# ── Re-exec from a copy before touching anything ────────────────────────────
# bash reads a script incrementally as it executes. Overwriting /opt/colossul
# while running from /opt/colossul makes the shell resume reading at a byte
# offset into a *different* file — which usually manifests as a syntax error
# halfway through an update that has already half-applied.
if [ "${COLOSSUL_SELFUPDATE_STAGED:-0}" != "1" ]; then
    _stage="$(mktemp -d)"
    cp "$0" "$_stage/self-update.sh" || exit 1
    COLOSSUL_SELFUPDATE_STAGED=1 COLOSSUL_SELFUPDATE_STAGE="$_stage" \
        exec bash "$_stage/self-update.sh" "$@"
fi
trap 'rm -rf "${COLOSSUL_SELFUPDATE_STAGE:-/nonexistent}" "${WORK:-/nonexistent}"' EXIT

_LIB="${COLOSSUL_LIB:-/opt/colossul}/lib/common.sh"
[ -f "$_LIB" ] || _LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=lib/common.sh
source "$_LIB"

INSTALL_DIR="${COLOSSUL_LIB:-/opt/colossul}"
REPO="${COLOSSUL_REPO:-https://github.com/WASasquatch/colossul-vast-multiseat.git}"
STAMP="$INSTALL_DIR/.colossul-version"

CHECK_ONLY=0
REF="main"
case "${1:-}" in
    --check|-n) CHECK_ONLY=1; REF="${2:-main}" ;;
    "")         ;;
    -*)         die "usage: colossul self-update [--check] [ref]" ;;
    *)          REF="$1" ;;
esac

CURRENT="$(cat "$STAMP" 2>/dev/null || echo "")"
log "Installed: ${CURRENT:-unknown (original image build)}"
log "Fetching $REPO @ $REF ..."

WORK="$(mktemp -d)"
if ! git clone --quiet --depth 50 "$REPO" "$WORK/repo" 2>/dev/null; then
    die "could not clone $REPO — no network, or the repo is private to this instance"
fi
if ! git -C "$WORK/repo" checkout --quiet "$REF" 2>/dev/null; then
    git -C "$WORK/repo" fetch --quiet --depth 50 origin "$REF" 2>/dev/null \
        && git -C "$WORK/repo" checkout --quiet FETCH_HEAD 2>/dev/null \
        || die "'$REF' is not a branch, tag or commit in that repository"
fi
NEW="$(git -C "$WORK/repo" rev-parse HEAD)"
log "Available: $NEW  ($(git -C "$WORK/repo" log -1 --format='%cs %s'))"

if [ "$NEW" = "$CURRENT" ]; then
    log "Already up to date."
    exit 0
fi

# What changed, when we know where we started.
if [ -n "$CURRENT" ] && git -C "$WORK/repo" cat-file -e "$CURRENT^{commit}" 2>/dev/null; then
    echo ""
    log "Changes since the installed version:"
    git -C "$WORK/repo" log --oneline --no-decorate "$CURRENT..$NEW" \
        | sed 's/^/[colossul]     /'
    echo ""
fi

if [ "$CHECK_ONLY" = "1" ]; then
    log "--check: nothing was changed."
    log "Apply with:  colossul self-update $REF"
    exit 0
fi

# ── Refuse to install something that cannot even parse ──────────────────────
# A syntax error reaching /opt/colossul would break the seats AND the CLI used
# to fix them, on a machine reachable only through a web terminal.
log "Checking the new scripts parse..."
bad=0
while IFS= read -r f; do
    bash -n "$f" 2>/dev/null || { warn "  syntax error: ${f#"$WORK/repo/"}"; bad=$((bad + 1)); }
done < <(find "$WORK/repo/scripts" -type f \( -name '*.sh' -o -path '*/bin/*' \))
if [ "$bad" -gt 0 ]; then
    die "$bad script(s) failed to parse — refusing to install. Nothing was changed."
fi
[ -f "$WORK/repo/scripts/lib/common.sh" ] || die "the fetched tree has no scripts/lib/common.sh"
log "  ok"

# ── Back up, then install ───────────────────────────────────────────────────
BACKUP="${INSTALL_DIR}.backup"
rm -rf "$BACKUP"
cp -a "$INSTALL_DIR" "$BACKUP" || die "could not back up $INSTALL_DIR"
log "Backed up the current install to $BACKUP"

cp -a "$WORK/repo/scripts/." "$INSTALL_DIR/" || {
    warn "copy failed — restoring the backup"
    rm -rf "$INSTALL_DIR"; mv "$BACKUP" "$INSTALL_DIR"
    die "update failed; the previous version is back in place"
}
for m in custom-nodes.txt models.txt; do
    [ -f "$WORK/repo/$m" ] && cp -f "$WORK/repo/$m" "$INSTALL_DIR/$m"
done
chmod +x "$INSTALL_DIR"/*.sh "$INSTALL_DIR"/bin/* 2>/dev/null
ln -sf "$INSTALL_DIR/bin/colossul" /usr/local/bin/colossul
# Old name kept as an alias: instances provisioned before the rename, and any
# note or runbook written then, still say colossul-seats.
ln -sf "$INSTALL_DIR/bin/colossul" /usr/local/bin/colossul-seats
ln -sf "$INSTALL_DIR/bin/colossul-portal-config" /usr/local/bin/colossul-portal-config
echo "$NEW" > "$STAMP"

log "Updated to $NEW"
echo ""
log "Nothing is running the new code yet. To apply it:"
log "    colossul provision        re-run provisioning (nodes, units, config)"
log "    colossul restart all      restart the seats"
log ""
log "Both are safe to re-run: node clones and model downloads skip what is"
log "already present. Roll back with:  rm -rf $INSTALL_DIR && mv $BACKUP $INSTALL_DIR"
exit 0
