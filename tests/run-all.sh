#!/usr/bin/env bash
# Run every check: shell syntax, seat topology, and the upstream patch.
#
# Usage: tests/run-all.sh [path/to/colossul-frontend]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

PY="${PYTHON:-python3}"
# Don't leave __pycache__ in the build context just for a syntax check.
export PYTHONDONTWRITEBYTECODE=1
rc=0
note() { echo ""; echo "############ $* ############"; }

note "SHELL SYNTAX"
while IFS= read -r f; do
    if bash -n "$f" 2>/dev/null; then
        echo "OK   $f"
    else
        echo "FAIL $f"; bash -n "$f"; rc=1
    fi
done < <(find scripts tests -type f \( -name '*.sh' -o -path 'scripts/bin/*' \) | sort; echo build.sh)

# compile() rather than py_compile: same syntax check, but py_compile writes a
# __pycache__ into the Docker build context as a side effect.
if "$PY" -c 'import sys; p=sys.argv[1]; compile(open(p).read(), p, "exec")' \
        scripts/patches/patch_vite_backend_url.py; then
    echo "OK   scripts/patches/patch_vite_backend_url.py"
else
    echo "FAIL scripts/patches/patch_vite_backend_url.py"; rc=1
fi

note "PARALLELISM"
bash tests/check-parallelism.sh || rc=1

note "TOPOLOGY"
bash tests/check-topology.sh || rc=1

note "COMFYUI ARGUMENTS"
bash tests/check-args.sh || rc=1

note "TUNNELS"
bash tests/check-tunnels.sh || rc=1

note "SHARED MODEL STORE"
bash tests/check-models.sh || rc=1

note "UPSTREAM PATCH"
if [ $# -gt 0 ]; then
    bash tests/check-patch.sh "$1" || rc=1
else
    bash tests/check-patch.sh || rc=1
fi

echo ""
if [ "$rc" = "0" ]; then
    echo "############ ALL CHECKS PASSED ############"
else
    echo "############ FAILURES ABOVE ############"
fi
exit "$rc"
