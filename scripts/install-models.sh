#!/usr/bin/env bash
# Download model weights listed in models.txt into the shared asset tree.
#
#   install-models.sh --list                  what sets exist, and their size
#   install-models.sh --check <set...>        verify without downloading a byte
#   install-models.sh minimax-h3 [set...]     download those sets
#   install-models.sh --all                   download everything defined
#
# Sets are opt-in: with no arguments and no MODEL_SETS, this does nothing. These
# are tens of gigabytes on a metered, rented machine — nobody should pay for
# them by accident.
#
# Deliberately NOT `set -e`: one unreachable URL must not cost the operator the
# other twelve files, some of which took twenty minutes.
set -uo pipefail

_LIB="${COLOSSUL_LIB:-/opt/colossul}/lib/common.sh"
[ -f "$_LIB" ] || _LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=lib/common.sh
source "$_LIB"

load_vast_environment
ensure_asset_dirs

MANIFEST="${MODEL_MANIFEST:-${COLOSSUL_LIB:-/opt/colossul}/models.txt}"
[ -f "$MANIFEST" ] || MANIFEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/models.txt"

FAILED=()
SKIPPED=0
FETCHED=0

# ── Manifest parsing ────────────────────────────────────────────────────────
# Emits "set<TAB>dest<TAB>bytes<TAB>url" for every entry, so every consumer
# below reads the file the same way. A commented-out [set] stays invisible.
parse_manifest() {
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*\[.*\][[:space:]]*$/ {
            gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "")
            set = $0; next
        }
        {
            dest = $1; size = $2; url = $3
            if (dest == "" || url == "") next
            if (set == "") set = "(unset)"
            print set "\t" dest "\t" size "\t" url
        }
    ' "$MANIFEST"
}

list_sets() {
    parse_manifest | awk -F'\t' '
        { n[$1]++; if ($3 ~ /^[0-9]+$/) b[$1] += $3; else unknown[$1] = 1 }
        END {
            for (s in n)
                printf "  %-22s %2d file(s)  %6.1f GB%s\n",
                       s, n[s], b[s]/1e9, (s in unknown ? " +unknown" : "")
        }
    ' | sort
}

human() { awk -v b="${1:-0}" 'BEGIN { printf (b >= 1e9 ? "%.1f GB" : "%.0f MB"), (b >= 1e9 ? b/1e9 : b/1e6) }'; }

# ── Argument handling ───────────────────────────────────────────────────────
WANT=()
CHECK_ONLY=0
case "${1:-}" in
    --list|-l)
        echo ""
        echo "Model sets defined in $(basename "$MANIFEST"):"
        list_sets
        echo ""
        echo "Download one with:  colossul-seats models <set>"
        exit 0
        ;;
    --check|--dry-run|-n)
        shift
        CHECK_ONLY=1
        if [ "$#" -gt 0 ]; then WANT=("$@")
        else mapfile -t WANT < <(parse_manifest | cut -f1 | sort -u); fi
        ;;
    --all) mapfile -t WANT < <(parse_manifest | cut -f1 | sort -u) ;;
    "")    IFS=', ' read -r -a WANT <<< "${MODEL_SETS:-}" ;;
    *)     WANT=("$@") ;;
esac

# Drop empties that a trailing comma in MODEL_SETS would produce.
_w=(); for s in ${WANT[@]+"${WANT[@]}"}; do [ -n "$s" ] && _w+=("$s"); done
WANT=(${_w[@]+"${_w[@]}"})

if [ "${#WANT[@]}" -eq 0 ]; then
    log "No model sets requested — nothing to download."
    log "  Available:"
    list_sets
    log "  Request one with: colossul-seats models <set>   (or MODEL_SETS=<set>)"
    exit 0
fi

# Fail on a typo'd set name rather than silently downloading nothing: a silent
# no-op here looks identical to success and is only noticed when a workflow
# can't find its weights.
AVAILABLE="$(parse_manifest | cut -f1 | sort -u)"
for s in "${WANT[@]}"; do
    grep -qxF "$s" <<< "$AVAILABLE" || {
        warn "No such model set: '$s'"
        warn "Available: $(tr '\n' ' ' <<< "$AVAILABLE")"
        exit 2
    }
done

# ── Auth ────────────────────────────────────────────────────────────────────
# Set before anything reaches the network, so --check exercises exactly the
# credentials a real download would use.
#
# The token goes ONLY to huggingface.co. HF answers /resolve/ with a redirect to
# a pre-signed CDN URL that needs no auth, and curl drops the Authorization
# header across hosts by default — which is what we want. Do not "fix" this with
# --location-trusted: that hands your token to every host in the redirect chain.
# HF_TOKEN arrives the same way GITHUB_TOKEN does: set it as a Vast ACCOUNT-level
# environment variable and the base image writes it to /etc/environment, which
# load_vast_environment() sourced above. $WORKSPACE/.env works too.
AUTH=()
if [ -n "${HF_TOKEN:-}" ]; then
    AUTH=(--header "Authorization: Bearer ${HF_TOKEN}")
    # Say so, but never echo the value — this log is world-readable in the portal.
    log "Authenticating to huggingface.co with HF_TOKEN (…${HF_TOKEN: -4})"
else
    log "No HF_TOKEN set — public repos only. Gated ones will 401/403."
fi

# ── Selection, and what is actually still missing ───────────────────────────
SELECTED="$(parse_manifest | awk -F'\t' -v want="$(printf '%s\n' "${WANT[@]}" | paste -sd'|')" '
    $1 ~ "^(" want ")$"')"

# ── --check: prove the whole thing works without spending bandwidth ─────────
# The point is to answer "will this work?" before committing to 40+ GB on a
# rented GPU, so it must touch every failure mode a real run would hit: dead
# URL, gated repo, wrong declared size, not enough disk.
if [ "$CHECK_ONLY" = "1" ]; then
    echo ""
    log "Checking sets: ${WANT[*]}   (no data will be downloaded)"
    [ -n "${HF_TOKEN:-}" ] && log "  HF_TOKEN is set" || log "  HF_TOKEN is NOT set (fine unless a repo is gated)"
    echo ""
    printf '  %-8s %-52s %s\n' "STATUS" "FILE" "NOTE"
    problems=0; want_bytes=0; present=0
    while IFS=$'\t' read -r set dest size url; do
        [ -n "$dest" ] || continue
        name="$(basename "$dest")"
        target="$ASSETS_ROOT/$dest"

        if [ -f "$target" ] && [ "$size" != "-" ] \
           && [ "$(stat -c %s "$target" 2>/dev/null || echo 0)" = "$size" ]; then
            printf '  %-8s %-52s %s\n' "have" "$name" "already downloaded"
            present=$((present + 1))
            continue
        fi

        # -I can 405 on some CDNs; fall back to a ranged GET that pulls 1 byte.
        hdr="$(curl -sIL --max-time 45 ${AUTH[@]+"${AUTH[@]}"} "$url" 2>/dev/null)"
        code="$(awk 'toupper($1) ~ /^HTTP/ {c=$2} END {print c}' <<< "$hdr")"
        if [ -z "$code" ] || [ "$code" -ge 400 ] 2>/dev/null; then
            hdr="$(curl -sL --max-time 45 -r 0-0 -D - -o /dev/null ${AUTH[@]+"${AUTH[@]}"} "$url" 2>/dev/null)"
            code="$(awk 'toupper($1) ~ /^HTTP/ {c=$2} END {print c}' <<< "$hdr")"
        fi
        # True file size: from Content-Range on a 206 (Content-Length there is
        # only the slice we asked for, so comparing it would be nonsense), else
        # from Content-Length on a 200.
        remote="$(grep -i '^content-range:' <<< "$hdr" | tail -1 | tr -d '\r' \
                  | sed -n 's#.*/\([0-9][0-9]*\).*#\1#p')"
        [ -n "$remote" ] || [ "$code" != "200" ] || \
            remote="$(grep -i '^content-length:' <<< "$hdr" | tail -1 | tr -d '\r' | awk '{print $2}')"

        case "${code:-000}" in
            200|206)
                if [ "$size" = "-" ]; then
                    printf '  %-8s %-52s %s\n' "ok" "$name" "size not declared; remote says $(human "${remote:-0}")"
                elif [ -n "$remote" ] && [ "$remote" != "$size" ]; then
                    printf '  %-8s %-52s %s\n' "SIZE" "$name" "manifest says $size, server says $remote"
                    problems=$((problems + 1))
                else
                    printf '  %-8s %-52s %s\n' "ok" "$name" "$(human "$size")"
                fi
                [ "$size" != "-" ] && want_bytes=$((want_bytes + size))
                ;;
            401|403)
                printf '  %-8s %-52s %s\n' "AUTH" "$name" "gated — needs a valid HF_TOKEN"
                problems=$((problems + 1)) ;;
            404)
                printf '  %-8s %-52s %s\n' "GONE" "$name" "404 — file moved or renamed upstream"
                problems=$((problems + 1)) ;;
            *)
                printf '  %-8s %-52s %s\n' "FAIL" "$name" "HTTP ${code:-no response}"
                problems=$((problems + 1)) ;;
        esac
    done <<< "$SELECTED"

    AVAIL_KB="$(df -Pk "$ASSETS_ROOT" | awk 'NR==2 {print $4}')"
    AVAIL=$((AVAIL_KB * 1024))
    echo ""
    log "Would download $(human "$want_bytes"); $present file(s) already present."
    log "Free space at $ASSETS_ROOT: $(human "$AVAIL")"
    if [ "$want_bytes" -gt 0 ] && [ "$AVAIL" -lt $((want_bytes + 5 * 1024 * 1024 * 1024)) ]; then
        warn "NOT ENOUGH DISK — need $(human "$want_bytes") plus a 5 GB margin."
        problems=$((problems + 1))
    fi
    echo ""
    if [ "$problems" -eq 0 ]; then
        log "All checks passed. Download for real with:"
        log "    colossul-seats models ${WANT[*]}"
        exit 0
    fi
    warn "$problems problem(s) above — fix these before downloading."
    exit 1
fi

NEED_BYTES=0
TODO=""
while IFS=$'\t' read -r set dest size url; do
    [ -n "$dest" ] || continue
    target="$ASSETS_ROOT/$dest"
    if [ -f "$target" ] && [ "$size" != "-" ]; then
        have="$(stat -c %s "$target" 2>/dev/null || echo 0)"
        if [ "$have" = "$size" ]; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
    fi
    TODO+="$set	$dest	$size	$url
"
    [ "$size" != "-" ] && NEED_BYTES=$((NEED_BYTES + size))
done <<< "$SELECTED"

TODO_COUNT=$(grep -c . <<< "${TODO%$'\n'}" 2>/dev/null || echo 0)
[ -n "${TODO//[[:space:]]/}" ] || TODO_COUNT=0

log "Model sets: ${WANT[*]}"
[ "$SKIPPED" -gt 0 ] && log "  $SKIPPED file(s) already present and complete — skipping"
if [ "$TODO_COUNT" -eq 0 ]; then
    log "Everything requested is already downloaded."
    exit 0
fi
log "  $TODO_COUNT file(s) to fetch, $(human "$NEED_BYTES")"

# ── Disk check, before anything starts ──────────────────────────────────────
# Filling the disk 90% into a 20 GB file wedges provisioning in a way that is
# tedious to unpick, so refuse up front instead.
AVAIL_KB="$(df -Pk "$ASSETS_ROOT" | awk 'NR==2 {print $4}')"
AVAIL=$((AVAIL_KB * 1024))
MARGIN=$((5 * 1024 * 1024 * 1024))   # leave 5 GB for everything else
log "  Free space at $ASSETS_ROOT: $(human "$AVAIL")"
if [ "$NEED_BYTES" -gt 0 ] && [ "$AVAIL" -lt $((NEED_BYTES + MARGIN)) ]; then
    warn "Not enough free disk: need $(human "$NEED_BYTES") plus a 5 GB margin,"
    warn "but only $(human "$AVAIL") is free at $ASSETS_ROOT."
    warn "Rent an instance with a larger volume, or download fewer sets."
    exit 1
fi

# ── Download ────────────────────────────────────────────────────────────────
# Sequential on purpose. A single stream already saturates these instances
# (~70-90 MB/s observed), so concurrency buys nothing and makes the disk check,
# the progress output and resume-after-interrupt all harder to reason about.
download_one() {
    local dest="$1" size="$2" url="$3"
    local target="$ASSETS_ROOT/$dest"
    local name; name="$(basename "$dest")"
    local dir; dir="$(dirname "$target")"
    mkdir -p "$dir"

    local part="$target.part"
    # A stale .part larger than the expected size can never converge; start over.
    if [ -f "$part" ] && [ "$size" != "-" ]; then
        local psz; psz="$(stat -c %s "$part" 2>/dev/null || echo 0)"
        if [ "$psz" -gt "$size" ]; then
            warn "  discarding oversized partial for $name"
            rm -f "$part"
        elif [ "$psz" -gt 0 ]; then
            log "  resuming $name at $(human "$psz") of $(human "$size")"
        fi
    fi

    local pretty="$size"
    [ "$size" = "-" ] && pretty="unknown size" || pretty="$(human "$size")"
    log "  fetching $name ($pretty)"

    local progress=(--silent --show-error)
    [ -t 2 ] && progress=(--progress-bar)

    _curl() {
        curl --location --fail --retry 5 --retry-delay 5 --retry-connrefused \
             --connect-timeout 30 "$@" ${AUTH[@]+"${AUTH[@]}"} \
             "${progress[@]}" --output "$part" "$url"
    }

    _curl --continue-at -
    local rc=$?
    # 33 = "server doesn't support byte ranges". Without this fallback a partial
    # from such a host can NEVER complete: every re-run attempts a resume, gets
    # 33 again, and fails identically forever. Start over instead — slower, but
    # it finishes.
    if [ "$rc" = "33" ]; then
        warn "  $name: server won't resume; restarting the download from zero"
        rm -f "$part"
        _curl
        rc=$?
    fi
    if [ "$rc" != "0" ]; then
        warn "  download failed: $name (curl exit $rc)"
        FAILED+=("$dest (download)")
        return 1
    fi

    if [ "$size" != "-" ]; then
        local got; got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
        if [ "$got" != "$size" ]; then
            warn "  size mismatch for $name: got $got, expected $size"
            warn "  (partial kept at $part — re-run to resume)"
            FAILED+=("$dest (truncated)")
            return 1
        fi
    fi

    # Rename only once complete, so an interrupted run never leaves a
    # half-written file that later looks finished.
    mv -f "$part" "$target" || { FAILED+=("$dest (rename)"); return 1; }
    FETCHED=$((FETCHED + 1))
    return 0
}

while IFS=$'\t' read -r set dest size url; do
    [ -n "$dest" ] || continue
    download_one "$dest" "$size" "$url"
done <<< "${TODO%$'\n'}"

# ── Report ──────────────────────────────────────────────────────────────────
echo ""
log "Models: $FETCHED downloaded, $SKIPPED already present."
if [ "${#FAILED[@]}" -gt 0 ]; then
    warn "${#FAILED[@]} file(s) did not complete:"
    for f in "${FAILED[@]}"; do warn "    $f"; done
    warn "Re-run to resume — completed files are skipped and partials continue:"
    warn "    colossul-seats models ${WANT[*]}"
    warn "If a repo is gated, set HF_TOKEN and re-run."
fi
exit 0
