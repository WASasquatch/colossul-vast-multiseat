#!/usr/bin/env bash
# Size PORTAL_CONFIG to this machine, then hand off to the base image.
#
# The Instance Portal reads PORTAL_CONFIG exactly once, on first boot, to write
# /etc/portal.yaml — and Vast's own docs say services do not re-read that file
# while running. So the only way to show the right number of seats is to get
# PORTAL_CONFIG right BEFORE the base image processes it, which means here: the
# entrypoint runs before supervisord, before the boot steps, before anything
# else in the container.
#
# Editing /etc/portal.yaml afterwards would mean guessing an undocumented
# schema, restarting instance_portal and tunnel_manager, and rebuilding every
# tunnel (new URLs, into Cloudflare's rate limiter). This avoids all of it.
#
# Set COLOSSUL_PORTAL_AUTOSIZE=0 to keep the image's full-size PORTAL_CONFIG.

BASE_ENTRYPOINT=/opt/instance-tools/bin/entrypoint.sh
LIB="${COLOSSUL_LIB:-/opt/colossul}"

# Nothing below may prevent the container from starting. A wrong number of
# portal entries is a cosmetic problem; an entrypoint that exits is a dead
# instance, and on Vast that is a rental someone pays for.
autosize_portal_config() {
    [ "${COLOSSUL_PORTAL_AUTOSIZE:-1}" = "1" ] || return 0
    [ -f "$LIB/lib/common.sh" ] || return 0
    [ -x "$LIB/bin/colossul-portal-config" ] || return 0

    # shellcheck source=lib/common.sh
    . "$LIB/lib/common.sh" 2>/dev/null || return 0
    local n; n="$(num_seats 2>/dev/null)" || return 0
    case "$n" in ''|*[!0-9]*) return 0 ;; esac
    [ "$n" -ge 1 ] || return 0

    local generated
    generated="$("$LIB/bin/colossul-portal-config" "$n" 2>/dev/null \
                 | grep '^PORTAL_CONFIG=' | sed 's/^PORTAL_CONFIG="//; s/"$//')"
    # Only replace a config we can actually build. A half-formed string here
    # would leave the portal with no entries at all, which is far worse than a
    # few dead ones.
    case "$generated" in
        *"Instance Portal"*"Seat 0 Storyrendr"*)
            export PORTAL_CONFIG="$generated"
            echo "[colossul] $n GPU-backed seat(s): portal sized to match." >&2
            ;;
        *)
            echo "[colossul] could not size PORTAL_CONFIG; keeping the image default." >&2
            ;;
    esac
}

autosize_portal_config || true

if [ -x "$BASE_ENTRYPOINT" ]; then
    exec "$BASE_ENTRYPOINT" "$@"
fi
# The base image moved its entrypoint. Say so loudly — this is not survivable
# quietly — but still try to do something useful with the arguments.
echo "[colossul] FATAL: $BASE_ENTRYPOINT is missing. The base image layout changed." >&2
[ "$#" -gt 0 ] && exec "$@"
exit 1
