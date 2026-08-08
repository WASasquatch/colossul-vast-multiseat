#!/usr/bin/env bash
# Verify the seat topology: port allocation, generated supervisor units, and
# that the PORTAL_CONFIG baked into the Dockerfile still matches what the port
# math produces.
#
# That last check matters because PORTAL_CONFIG is consumed at first boot and
# cannot be corrected afterwards: if it drifts from the ports the seats
# actually bind, Caddy proxies employees to dead ports and the only fix is a
# new template.
#
# Usage: tests/check-topology.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export COLOSSUL_LIB="$ROOT/scripts"

# shellcheck source=../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

PY="${PYTHON:-python3}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

echo "=== 1. no port collisions, for any supported seat count ==="
for n in 1 2 3 4 5 6 7 8; do
    : > "$T/ports"
    for ((i = 0; i < n; i++)); do
        { comfyui_ext "$i"; comfyui_int "$i"
          backend_ext "$i"; backend_int "$i"
          frontend_ext "$i"; frontend_int "$i"; } >> "$T/ports"
    done
    total="$(wc -l < "$T/ports")"
    uniq="$(sort -un "$T/ports" | wc -l)"
    [ "$total" = "$uniq" ] || fail "duplicate ports at NUM_SEATS=$n: $(sort -n "$T/ports" | uniq -d | tr '\n' ' ')"
    max="$(sort -n "$T/ports" | tail -1)"
    [ "$max" -lt 65536 ] || fail "port $max exceeds the 16-bit range at NUM_SEATS=$n"
done
echo "PASS: 1-8 seats allocate 6 unique in-range ports each"

echo ""
echo "=== 1b. no seat port collides with a base-image service ==="
# vastai/comfy binds these; a collision means a permanent crash-loop that looks
# like "the seat is broken" rather than "the port was taken".
for n in 1 2 3 4 5 6 7 8; do
    assert_no_reserved_collisions "$n" \
        || fail "at NUM_SEATS=$n a seat port hits a reserved base-image port ($RESERVED_PORTS)"
done
# Prove the guard actually bites, so it can't silently rot into a no-op.
if (RESERVED_PORTS="$(frontend_ext 2)"; assert_no_reserved_collisions 4) 2>/dev/null; then
    fail "assert_no_reserved_collisions did not detect a known-colliding port"
fi
echo "PASS: 1-8 seats avoid all reserved ports, and the guard detects collisions"

echo ""
echo "=== 2. generated supervisor units are valid INI ==="
for ((i = 0; i < 4; i++)); do
    write_seat_unit "$i" "$T/colossul-seat${i}.conf"
done
"$PY" - "$T" <<'EOF' || exit 1
import configparser, glob, os, sys

d = sys.argv[1]
files = sorted(glob.glob(os.path.join(d, "colossul-seat*.conf")))
assert len(files) == 4, f"expected 4 unit files, got {len(files)}"

for f in files:
    cp = configparser.ConfigParser(strict=True)
    # Supervisor allows %(program_name)s; disable interpolation like it does.
    cp = configparser.RawConfigParser()
    cp.read(f)
    seat = os.path.basename(f).replace("colossul-seat", "").replace(".conf", "")
    expected = {f"program:seat{seat}-{s}" for s in ("comfyui", "backend", "frontend")}
    expected.add(f"group:seat{seat}")
    got = set(cp.sections())
    assert got == expected, f"{f}: sections {got} != {expected}"

    for s in ("comfyui", "backend", "frontend"):
        sec = f"program:seat{seat}-{s}"
        cmd = cp.get(sec, "command")
        assert cmd.endswith(f"seat-{s}.sh {seat}"), f"{sec}: unexpected command {cmd!r}"
        script = cmd.rsplit(" ", 1)[0]
        assert os.path.isfile(script), f"{sec}: command points at a missing script: {script}"
        # vast.ai only ingests logs written to stdout.
        assert cp.get(sec, "stdout_logfile") == "/dev/stdout", f"{sec}: must log to /dev/stdout"
        assert cp.get(sec, "redirect_stderr") == "true", f"{sec}: must redirect stderr"

    prios = {s: int(cp.get(f"program:seat{seat}-{s}", "priority"))
             for s in ("comfyui", "backend", "frontend")}
    assert prios["comfyui"] < prios["backend"] < prios["frontend"], \
        f"seat {seat}: start order wrong: {prios}"

print("PASS: 4 seats x 3 programs + group, valid INI, correct start order,")
print("      every command resolves to a real script")
EOF

echo ""
echo "=== 3. each seat's programs are pinned to distinct GPUs ==="
seen=""
for ((i = 0; i < 4; i++)); do
    g="$(gpu_for_seat "$i")"
    case " $seen " in *" $g "*) fail "GPU $g assigned to more than one seat" ;; esac
    seen="$seen $g"
done
echo "PASS: seats 0-3 map to GPUs$seen"

echo ""
echo "=== 4. GPU_MAP override is honoured ==="
[ "$(GPU_MAP=4,5,6,7 gpu_for_seat 2)" = "6" ] || fail "GPU_MAP did not remap seat 2"
[ "$(gpu_for_seat 2)" = "2" ] || fail "identity mapping broken without GPU_MAP"
echo "PASS: GPU_MAP remaps, identity is the default"

echo ""
echo "=== 5. baked PORTAL_CONFIG matches the port math ==="
generated="$(bash "$ROOT/scripts/bin/colossul-portal-config" 4 | grep '^PORTAL_CONFIG=' | sed 's/^PORTAL_CONFIG=//; s/^"//; s/"$//')"
baked="$(grep -o 'ENV PORTAL_CONFIG="[^"]*"' "$ROOT/Dockerfile" | sed 's/^ENV PORTAL_CONFIG="//; s/"$//')"
[ -n "$generated" ] || fail "could not generate a PORTAL_CONFIG"
[ -n "$baked" ] || fail "could not find PORTAL_CONFIG in the Dockerfile"
if [ "$generated" != "$baked" ]; then
    echo "generated: $generated"
    echo "baked    : $baked"
    fail "Dockerfile PORTAL_CONFIG has drifted from the port math"
fi
echo "PASS: Dockerfile PORTAL_CONFIG agrees with the generator"

echo ""
echo "=== 6. every documented port list matches PORTAL_CONFIG ==="
# `|| true`: an empty grep result must reach the explicit check below rather
# than tripping set -e and aborting with no explanation.
gen_ports="$(bash "$ROOT/scripts/bin/colossul-portal-config" 4 | grep -oE '^[0-9]+(,[0-9]+)+$' | head -1 || true)"
[ -n "$gen_ports" ] || fail "generator produced no port list"

# Compare as sets: Vast doesn't care about ordering, so only a genuine
# difference in which ports are exposed should fail this.
norm() { printf '%s' "$1" | tr ',' '\n' | sort -un | paste -sd, -; }
want="$(norm "$gen_ports")"

# Check EVERY markdown file, not just VAST_TEMPLATE.md. A stale list in the
# README is exactly as damaging — an operator pastes it into the template and
# the seats whose ports are missing never become reachable.
checked=0
while IFS= read -r doc; do
    while IFS= read -r found; do
        [ -n "$found" ] || continue
        checked=$((checked + 1))
        if [ "$(norm "$found")" != "$want" ]; then
            echo "  in $doc:"
            echo "    documented: $found"
            echo "    generated : $gen_ports"
            fail "a documented port list has drifted from the port math"
        fi
    done < <(grep -oE '\b[0-9]{4,5}(,[0-9]{4,5}){3,}\b' "$doc" || true)
done < <(find "$ROOT" -name '*.md' -not -path '*/.git/*')

[ "$checked" -gt 0 ] || fail "no port list found in any doc - has the format changed?"

# Also check docker "-p 8190:8190 ..." style lists. QUICK_START.md states the
# ports that way, and it is the doc a non-technical operator copies from - a
# stale entry there means an artist silently has no working link.
dockerfmt=0
while IFS= read -r doc; do
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        found="$(printf '%s' "$line" | grep -oE '\-p [0-9]+:[0-9]+' | grep -oE '[0-9]+:' | tr -d ':' | paste -sd, -)"
        [ -n "$found" ] || continue
        dockerfmt=$((dockerfmt + 1))
        if [ "$(norm "$found")" != "$want" ]; then
            echo "  in $doc:"
            echo "    documented: $(norm "$found")"
            echo "    generated : $want"
            fail "a '-p' port list has drifted from the port math"
        fi
    done < <(grep -E '(\-p [0-9]+:[0-9]+.*){4,}' "$doc" || true)
done < <(find "$ROOT" -name '*.md' -not -path '*/.git/*')

echo "PASS: $checked comma-style and $dockerfmt docker-style port list(s) all match"

echo ""
echo "ALL TOPOLOGY CHECKS PASSED"
