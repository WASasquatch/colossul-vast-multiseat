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
TMP_CONFLICTS="$(mktemp)"
trap 'rm -f "$TMP_CONFLICTS"' EXIT

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
            dest = $1
            # The size is optional: "dest url" and "dest bytes url" are both
            # valid. Detected by whether field 2 looks like a URL, so nobody has
            # to go and find a byte count just to add a model.
            #
            # "dest link:<other-dest>" is a third form: the same weights under a
            # second name. ComfyUI resolves a model name inside its category
            # folder, so a file loaded as both a VAE and a text encoder must
            # exist in both — linking avoids downloading 46 GB twice.
            if ($2 ~ /^link:/)                  { size = "0";  url = $2 }
            else if ($2 ~ /^[a-z][a-z0-9+.-]*:\/\//) { size = "-"; url = $2 }
            else                                { size = $2;  url = $3 }
            if (dest == "" || url == "") next
            if (size == "") size = "-"
            # Entries written before any [header] belong to "default" — a name
            # that can actually be typed. It still has to be asked for; an
            # implicit set that downloads itself would break the one guarantee
            # this script makes.
            if (set == "") set = "default"
            print set "\t" dest "\t" size "\t" url
        }
    ' "$MANIFEST"
}

# Ask the server what a URL is: prints "<http-code>\t<total-bytes>".
#
# Used both by --check and to fill in an omitted size, so the two can never
# disagree about what the server said.
probe_url() {
    local url="$1" hdr code total
    local -a _URLAUTH=(); _set_urlauth "$url"
    hdr="$(curl -sIL --max-time 45 ${_URLAUTH[@]+"${_URLAUTH[@]}"} "$url" 2>/dev/null)"
    code="$(awk 'toupper($1) ~ /^HTTP/ {c=$2} END {print c}' <<< "$hdr")"
    # Some CDNs answer HEAD with 403/405; retry as a GET for a single byte.
    if [ -z "$code" ] || { [ "$code" -ge 400 ] 2>/dev/null; }; then
        hdr="$(curl -sL --max-time 45 -r 0-0 -D - -o /dev/null ${_URLAUTH[@]+"${_URLAUTH[@]}"} "$url" 2>/dev/null)"
        code="$(awk 'toupper($1) ~ /^HTTP/ {c=$2} END {print c}' <<< "$hdr")"
    fi
    # On a 206 the true size is the denominator of Content-Range; Content-Length
    # there is only the slice we asked for, so it must not be used.
    total="$(grep -i '^content-range:' <<< "$hdr" | tail -1 | tr -d '\r' \
             | sed -n 's#.*/\([0-9][0-9]*\).*#\1#p')"
    [ -n "$total" ] || [ "$code" != "200" ] || \
        total="$(grep -i '^content-length:' <<< "$hdr" | tail -1 | tr -d '\r' | awk '{print $2}')"
    printf '%s\t%s\n' "${code:-000}" "${total:-}"
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
fmt_secs() {
    local s="${1:-0}"
    if   [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60))
    elif [ "$s" -ge 60 ];   then printf '%dm%02ds' $((s / 60)) $((s % 60))
    else                         printf '%ds' "$s"; fi
}

# How often to report on a running download, in seconds. A 21 GB file takes
# minutes; without this the log looks hung.
PROGRESS_INTERVAL="${MODEL_PROGRESS_INTERVAL:-30}"

# ── Auth ────────────────────────────────────────────────────────────────────
# Established before ANY command that touches the network, so --check and
# --sizes exercise exactly the credentials a real download would use.
#
# The token goes ONLY to huggingface.co. HF answers /resolve/ with a redirect to
# a pre-signed CDN URL that needs no auth, and curl drops the Authorization
# header across hosts by default — which is what we want. Do not "fix" this with
# --location-trusted: that hands your token to every host in the redirect chain.
#
# HF_TOKEN arrives the same way GITHUB_TOKEN does: set it as a Vast ACCOUNT-level
# environment variable and the base image writes it to /etc/environment, which
# load_vast_environment() sourced above. $WORKSPACE/.env works too.

# Civitai needs its own key, and hosts things HuggingFace does not — community
# merges like FusionX live only there. Per-URL rather than global: sending the
# HuggingFace token to Civitai (or the reverse) would leak a credential to a
# service that has no business seeing it.
#
# `curl --url-query`-style header selection is not a thing, so pick per request.
# Sets _URLAUTH (must be declared local by the caller) to the curl header args
# appropriate for this URL, or nothing.
_set_urlauth() {
    _URLAUTH=()
    case "$1" in
        *huggingface.co*)
            [ -n "${HF_TOKEN:-}" ] && _URLAUTH=(--header "Authorization: Bearer ${HF_TOKEN}") ;;
        *civitai.com*)
            [ -n "${CIVITAI_TOKEN:-}" ] && _URLAUTH=(--header "Authorization: Bearer ${CIVITAI_TOKEN}") ;;
    esac
    return 0
}
# Whether a token is in play is worth stating; its value never is — the
# provisioning log is readable through the instance portal.
announce_auth() {
    if [ -n "${HF_TOKEN:-}" ]; then
        log "Authenticating to huggingface.co with HF_TOKEN (…${HF_TOKEN: -4})"
    else
        log "No HF_TOKEN set — public HuggingFace repos only. Gated ones will 401/403."
    fi
    [ -n "${CIVITAI_TOKEN:-}" ] && log "CIVITAI_TOKEN set (…${CIVITAI_TOKEN: -4}) for civitai.com URLs"
    return 0
}

# ── Argument handling ───────────────────────────────────────────────────────
WANT=()
CHECK_ONLY=0
case "${1:-}" in
    --list|-l)
        echo ""
        echo "Model sets defined in $(basename "$MANIFEST"):"
        list_sets
        echo ""
        echo "  Download one:   colossul models <set>"
        echo "  Download all:   colossul models --all"
        echo "  At boot time:   MODEL_SETS=<set>[,<set>...]   or   MODEL_SETS=all"
        echo ""
        exit 0
        ;;
    --sizes)
        # Print the manifest with every omitted size filled in, so sizes can be
        # pinned without anyone hand-collecting byte counts:
        #     colossul models --sizes > models.txt.new
        shift
        while IFS= read -r line; do
            trimmed="${line#"${line%%[![:space:]]*}"}"
            case "$trimmed" in ''|'#'*|'['*) printf '%s\n' "$line"; continue ;; esac
            read -r d s u _ <<< "$line"
            case "$s" in
                *://*) u="$s"; s="-" ;;   # two-field form: dest url
            esac
            if [ "$s" = "-" ] || [ -z "$s" ]; then
                IFS=$'\t' read -r _c total < <(probe_url "$u")
                s="${total:--}"
                [ "$s" = "-" ] && warn "could not size $u (HTTP $_c)" >&2
            fi
            printf '%s  %s  %s\n' "$d" "$s" "$u"
        done < "$MANIFEST"
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

# "all" means every set, wherever it is named. Without this there is no way to
# say "download everything" at provision time — MODEL_SETS would have to list
# every set by hand, and a set added later would silently never download.
for s in ${WANT[@]+"${WANT[@]}"}; do
    case "$s" in
        all|ALL|'*')
            mapfile -t WANT < <(parse_manifest | cut -f1 | sort -u)
            log "MODEL_SETS=all — selecting every set: ${WANT[*]}"
            break ;;
    esac
done

if [ "${#WANT[@]}" -eq 0 ]; then
    log "No model sets requested — nothing to download."
    log "  Available:"
    list_sets
    log "  Request one with: colossul models <set>   (or MODEL_SETS=<set>)"
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

# ── Selection, and what is actually still missing ───────────────────────────
SELECTED="$(parse_manifest | awk -F'\t' -v want="$(printf '%s\n' "${WANT[@]}" | paste -sd'|')" '
    $1 ~ "^(" want ")$"')"

# Sets legitimately share files — a text encoder or VAE is listed by every model
# family that needs it, so each set stands alone. Selecting two would otherwise
# fetch the shared 7 GB encoder twice. Keep the first entry per destination, and
# say so loudly if two entries claim the same path from DIFFERENT sources, which
# is a manifest bug rather than an overlap.
SELECTED="$(awk -F'\t' '
    { if (!($2 in seen)) { seen[$2] = $4; order[++n] = $0 }
      else if (seen[$2] != $4) conflict[$2] = seen[$2] "\n      vs " $4 }
    END {
        for (i = 1; i <= n; i++) print order[i]
        for (d in conflict) printf "CONFLICT\t%s\t%s\n", d, conflict[d] > "/dev/stderr"
    }' <<< "$SELECTED" 2>"$TMP_CONFLICTS")"
if [ -s "${TMP_CONFLICTS:-/dev/null}" ]; then
    warn "Two manifest entries want the same destination from different URLs:"
    sed 's/^/    /' "$TMP_CONFLICTS" | while IFS= read -r l; do warn "$l"; done
    warn "Using the first. Fix models.txt — one of them is wrong."
fi

# ── --check: prove the whole thing works without spending bandwidth ─────────
# The point is to answer "will this work?" before committing to 40+ GB on a
# rented GPU, so it must touch every failure mode a real run would hit: dead
# URL, gated repo, wrong declared size, not enough disk.
if [ "$CHECK_ONLY" = "1" ]; then
    echo ""
    log "Checking sets: ${WANT[*]}   (no data will be downloaded)"
    announce_auth
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

        IFS=$'\t' read -r code remote < <(probe_url "$url")

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
                # Count the server's number when the manifest doesn't declare
                # one, or the disk check silently passes on a 0-byte total.
                if [ "$size" != "-" ]; then
                    want_bytes=$((want_bytes + size))
                elif [ -n "$remote" ]; then
                    want_bytes=$((want_bytes + remote))
                fi
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
        log "    colossul models ${WANT[*]}"
        exit 0
    fi
    warn "$problems problem(s) above — fix these before downloading."
    exit 1
fi

# ── Split out the link entries ──────────────────────────────────────────────
# They cost no bandwidth and must be created AFTER their source exists, so they
# are held aside rather than run through the download machinery.
LINKS="$(awk -F'\t' '$4 ~ /^link:/' <<< "$SELECTED")"
SELECTED="$(awk -F'\t' '$4 !~ /^link:/' <<< "$SELECTED")"

# Fill in any omitted size by asking the server, so the disk precheck,
# skip-if-complete and truncation detection all work whether or not a byte
# count was written down. One HEAD per unsized entry; a manifest that declares
# its sizes just skips this.
UNSIZED=$(awk -F'\t' '$3 == "-"' <<< "$SELECTED" | grep -c . || true)
if [ "$UNSIZED" -gt 0 ]; then
    log "Looking up $UNSIZED file size(s) not declared in the manifest..."
    RESOLVED=""
    while IFS=$'\t' read -r set dest size url; do
        [ -n "$dest" ] || continue
        if [ "$size" = "-" ]; then
            IFS=$'\t' read -r _code _total < <(probe_url "$url")
            if [ -n "$_total" ]; then
                size="$_total"
            else
                warn "  could not determine the size of $(basename "$dest") (HTTP $_code)"
                warn "  it will still download, but disk cannot be checked in advance"
            fi
        fi
        RESOLVED+="$set	$dest	$size	$url
"
    done <<< "$SELECTED"
    SELECTED="${RESOLVED%$'\n'}"
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
announce_auth
[ "$SKIPPED" -gt 0 ] && log "  $SKIPPED file(s) already present and complete — skipping"
if [ "$TODO_COUNT" -eq 0 ] && [ -z "${LINKS//[[:space:]]/}" ]; then
    log "Everything requested is already downloaded."
    exit 0
fi
[ "$TODO_COUNT" -gt 0 ] && log "  $TODO_COUNT file(s) to fetch, $(human "$NEED_BYTES")"

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
# Runs in a subshell as one of several concurrent workers, so it must not touch
# shell state the parent needs: results go to $STATUS_DIR/<idx>, which the parent
# reads back once everything has finished.
download_one() {
    local dest="$1" size="$2" url="$3" idx="$4"
    local target="$ASSETS_ROOT/$dest"
    local name; name="$(basename "$dest")"
    local dir; dir="$(dirname "$target")"
    mkdir -p "$dir"

    local -a _URLAUTH=(); _set_urlauth "$url"
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
    log "  [$idx/$TODO_COUNT] start $name ($pretty)"

    # Always silent per transfer. curl's bar is \r-driven and only readable on a
    # terminal, and with several transfers in flight even line output would
    # interleave into noise — the aggregate monitor reports for all of them.
    local progress=(--silent --show-error)

    _curl() {
        curl --location --fail --retry 5 --retry-delay 5 --retry-connrefused \
             --connect-timeout 30 "$@" ${_URLAUTH[@]+"${_URLAUTH[@]}"} \
             "${progress[@]}" --output "$part" "$url"
    }

    local started; started="$(date +%s)"
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
        warn "  FAILED $name (curl exit $rc)"
        printf 'fail\t%s (download, curl %s)\n' "$dest" "$rc" > "$STATUS_DIR/$idx"
        return 1
    fi

    if [ "$size" != "-" ]; then
        local got; got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
        if [ "$got" != "$size" ]; then
            warn "  FAILED $name: got $got bytes, expected $size (partial kept, re-run to resume)"
            printf 'fail\t%s (truncated)\n' "$dest" > "$STATUS_DIR/$idx"
            return 1
        fi
    fi

    # Rename only once complete, so an interrupted run never leaves a
    # half-written file that later looks finished.
    if ! mv -f "$part" "$target"; then
        printf 'fail\t%s (rename)\n' "$dest" > "$STATUS_DIR/$idx"
        return 1
    fi
    local secs=$(( $(date +%s) - started ))
    [ "$secs" -lt 1 ] && secs=1
    log "  done $name in $(fmt_secs "$secs")$( [ "$size" != "-" ] && printf ' (%s MB/s)' "$(( size / secs / 1000000 ))" )"
    printf 'ok\t%s\n' "$dest" > "$STATUS_DIR/$idx"
    return 0
}

# ── Run the downloads, N at a time ──────────────────────────────────────────
# Concurrency is not about link speed — a single stream can saturate these
# instances on a cold connection. It is about HuggingFace throttling a sustained
# transfer: one stream degrades badly over a long pull, while several in
# parallel each get their own allowance. Sequential took over an hour to move
# ten files.
#
# Downloads have none of the constraints that force custom-node installs to be
# serial: every file is independent, has its own .part, and touches nothing
# shared. The ceiling is disk write throughput, so this stays modest.
JOBS="${MODEL_DL_JOBS:-4}"
case "$JOBS" in ''|*[!0-9]*) JOBS=4 ;; esac
[ "$JOBS" -lt 1 ] && JOBS=1

STATUS_DIR="$(mktemp -d)"
PARTS_LIST="$STATUS_DIR/.parts"
: > "$PARTS_LIST"
while IFS=$'\t' read -r set dest size url; do
    [ -n "$dest" ] || continue
    printf '%s\t%s\n' "$ASSETS_ROOT/$dest" "$size" >> "$PARTS_LIST"
done <<< "${TODO%$'\n'}"

# Bytes of the requested set currently on disk: the finished file if it has been
# renamed, else whatever its .part has so far.
# Prints "<bytes><TAB><files-complete>". A finished file has been renamed off
# its .part, so its presence is the completion signal.
bytes_on_disk() {
    local t s total=0 n done=0
    while IFS=$'\t' read -r t s; do
        [ -n "$t" ] || continue
        if [ -f "$t" ]; then
            n="$(stat -c %s "$t" 2>/dev/null || echo 0)"
            done=$((done + 1))
        elif [ -f "$t.part" ]; then n="$(stat -c %s "$t.part" 2>/dev/null || echo 0)"
        else n=0; fi
        total=$((total + n))
    done < "$PARTS_LIST"
    printf '%s\t%s\n' "$total" "$done"
}

# One aggregate progress line for the whole run. Per-file lines would interleave
# unreadably with several transfers in flight, and the number an operator
# actually wants is "how long until the library is here".
monitor_progress() {
    local start last_t last_b now total ndone rate eta pct active
    start="$(date +%s)"; last_t="$start"; last_b=0
    while [ -e "$STATUS_DIR/.running" ]; do
        local waited=0
        while [ "$waited" -lt "$PROGRESS_INTERVAL" ] && [ -e "$STATUS_DIR/.running" ]; do
            sleep 1; waited=$((waited + 1))
        done
        [ -e "$STATUS_DIR/.running" ] || break
        IFS=$'\t' read -r total ndone < <(bytes_on_disk)
        now="$(date +%s)"
        rate=$(( (total - last_b) / ((now - last_t) > 0 ? (now - last_t) : 1) ))
        active="$(find "$STATUS_DIR" -maxdepth 1 -name '.active-*' 2>/dev/null | wc -l)"
        pct=0; [ "$NEED_BYTES" -gt 0 ] && pct=$(( total * 100 / NEED_BYTES ))
        if [ "$rate" -gt 0 ]; then
            eta="$(fmt_secs $(( (NEED_BYTES - total) / rate )))"
        else
            eta="stalled"
        fi
        log "  progress: ${ndone}/${TODO_COUNT} files | $(human "$total") / $(human "$NEED_BYTES") (${pct}%) | ${active} downloading | $(( rate / 1000000 )) MB/s | eta $eta"
        last_t="$now"; last_b="$total"
    done
}

[ "$TODO_COUNT" -gt 0 ] && log "  downloading with $JOBS concurrent transfer(s)"
touch "$STATUS_DIR/.running"
[ -t 2 ] || { monitor_progress & MONITOR_PID=$!; }

IDX=0
while IFS=$'\t' read -r set dest size url; do
    [ -n "$dest" ] || continue
    IDX=$((IDX + 1))
    # Wait for a free slot.
    while [ "$(jobs -rp | wc -l)" -ge "$((JOBS + ${MONITOR_PID:+1}))" ]; do sleep 1; done
    (
        touch "$STATUS_DIR/.active-$IDX"
        download_one "$dest" "$size" "$url" "$IDX"
        rm -f "$STATUS_DIR/.active-$IDX"
    ) &
done <<< "${TODO%$'\n'}"

# Wait for the transfers, then stop the monitor.
for p in $(jobs -rp); do
    [ "${MONITOR_PID:-}" = "$p" ] && continue
    wait "$p" 2>/dev/null || true
done
rm -f "$STATUS_DIR/.running"
[ -n "${MONITOR_PID:-}" ] && wait "$MONITOR_PID" 2>/dev/null || true

# Collect what the workers recorded. Arrays cannot cross a subshell boundary,
# so each writes a one-line result file and the parent reads them back.
for f in "$STATUS_DIR"/[0-9]*; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r st detail < "$f"
    case "$st" in
        ok)   FETCHED=$((FETCHED + 1)) ;;
        fail) FAILED+=("$detail") ;;
    esac
done
rm -rf "$STATUS_DIR"

# ── Second names for the same weights ───────────────────────────────────────
# Hardlink by preference: no extra bytes, no dangling target if something later
# moves, and ComfyUI reads it as an ordinary file. Symlink only when the two
# paths are on different filesystems, where a hardlink is impossible.
LINKED=0
if [ -n "${LINKS//[[:space:]]/}" ]; then
    while IFS=$'\t' read -r set dest size url; do
        [ -n "$dest" ] || continue
        src="$ASSETS_ROOT/${url#link:}"
        tgt="$ASSETS_ROOT/$dest"
        name="$(basename "$dest")"
        if [ ! -f "$src" ]; then
            warn "  link source missing for $name: ${url#link:}"
            warn "  (its set was probably not selected — nothing to link to)"
            FAILED+=("$dest (link source missing)")
            continue
        fi
        # Already correct? Same inode means the hardlink is in place.
        if [ -e "$tgt" ] && [ "$(stat -c %i "$tgt" 2>/dev/null)" = "$(stat -c %i "$src" 2>/dev/null)" ]; then
            continue
        fi
        mkdir -p "$(dirname "$tgt")"
        rm -f "$tgt"
        if ln "$src" "$tgt" 2>/dev/null; then
            log "  linked $dest -> ${url#link:}"
            LINKED=$((LINKED + 1))
        elif ln -s "$src" "$tgt" 2>/dev/null; then
            log "  symlinked $dest -> ${url#link:} (different filesystem)"
            LINKED=$((LINKED + 1))
        else
            warn "  could not link $name"
            FAILED+=("$dest (link)")
        fi
    done <<< "${LINKS%$'\n'}"
fi

# ── Report ──────────────────────────────────────────────────────────────────
echo ""
log "Models: $FETCHED downloaded, $SKIPPED already present.$( [ "$LINKED" -gt 0 ] && printf ' %s linked.' "$LINKED" )"
if [ "${#FAILED[@]}" -gt 0 ]; then
    warn "${#FAILED[@]} file(s) did not complete:"
    for f in "${FAILED[@]}"; do warn "    $f"; done
    warn "Re-run to resume — completed files are skipped and partials continue:"
    warn "    colossul models ${WANT[*]}"
    warn "If a repo is gated, set HF_TOKEN and re-run."
fi
exit 0
