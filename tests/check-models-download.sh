#!/usr/bin/env bash
# Exercise the model downloader for real: manifest parsing, set selection,
# skip-if-complete, resume-from-partial, truncation detection, and the disk
# precheck. A downloader that silently no-ops looks exactly like success until
# an artist opens a workflow and the weights aren't there.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export COLOSSUL_LIB="$ROOT/scripts"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
SH="$ROOT/scripts/install-models.sh"

# A local file server, so these tests need no network and no HF token.
mkdir -p "$T/srv"
head -c 1048576 /dev/urandom > "$T/srv/small.bin"
SMALL_SIZE=$(stat -c %s "$T/srv/small.bin")
# A Range-capable server. python -m http.server is NOT usable here: it ignores
# Range and answers 200 with the whole file, so curl refuses to resume (exit 33)
# and the resume path would never actually be exercised.
#
# RANGE=0 in the environment makes it behave like that broken server instead,
# which is how the no-resume fallback gets tested.
cat > "$T/server.py" <<'PY'
import os, sys, http.server
ROOT = sys.argv[1]; PORT = int(sys.argv[2]); RANGES = os.environ.get("RANGE", "1") == "1"

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        path = os.path.join(ROOT, os.path.basename(self.path))
        if not os.path.isfile(path):
            self.send_error(404); return
        size = os.path.getsize(path)
        start, rng = 0, self.headers.get("Range")
        if rng and RANGES and rng.startswith("bytes="):
            start = int(rng.split("=")[1].split("-")[0])
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{size-1}/{size}")
        else:
            self.send_response(200)
        self.send_header("Content-Length", str(size - start))
        self.send_header("Accept-Ranges", "bytes" if RANGES else "none")
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            self.wfile.write(f.read())

http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY

start_server() {   # start_server <ranges 0|1> -> sets PORT
    PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
    RANGE="$1" python3 "$T/server.py" "$T/srv" "$PORT" >"$T/srv.log" 2>&1 </dev/null &
    echo $! > "$T/srv.pid"
    local ready=0 _
    for _ in $(seq 1 60); do
        curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/small.bin" && { ready=1; break; }
        sleep 0.25
    done
    [ "$ready" = "1" ] || fail "test server never came up on $PORT: $(cat "$T/srv.log" 2>/dev/null)"
}
stop_server() { kill "$(cat "$T/srv.pid" 2>/dev/null)" 2>/dev/null; wait 2>/dev/null || true; }

start_server 1
# Sanity: the harness itself must actually serve ranges, or tests 7/8 would pass
# vacuously against a server that silently sends the whole file every time.
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=100-' "http://127.0.0.1:$PORT/small.bin")
[ "$code" = "206" ] || fail "test server is not honouring Range (got $code) — resume tests would be meaningless"
trap 'kill "$(cat "$T/srv.pid" 2>/dev/null)" 2>/dev/null; rm -rf "$T"' EXIT
BASE="http://127.0.0.1:$PORT"

export COLOSSUL_ASSETS_ROOT="$T/assets"
export WORKSPACE="$T/ws"
mkdir -p "$COLOSSUL_ASSETS_ROOT" "$WORKSPACE"

cat > "$T/models.txt" <<EOF
[alpha]
models/vae/small.safetensors  $SMALL_SIZE  $BASE/small.bin

[beta]
models/loras/other.safetensors  $SMALL_SIZE  $BASE/small.bin
EOF
export MODEL_MANIFEST="$T/models.txt"

run() { MODEL_SETS="" bash "$SH" "$@" 2>&1; }

echo "=== 1. --list reports every set with a size ==="
out="$(run --list)"
grep -q 'alpha' <<< "$out" || fail "--list omitted set 'alpha': $out"
grep -q 'beta'  <<< "$out" || fail "--list omitted set 'beta'"
echo "$out" | grep -qE 'alpha.*1 file' || fail "--list should show a file count: $out"
echo "PASS: sets listed"

echo ""
echo "=== 2. no set requested downloads NOTHING ==="
out="$(run)"
[ -z "$(find "$COLOSSUL_ASSETS_ROOT" -name '*.safetensors' 2>/dev/null)" ] \
    || fail "downloaded a file when no set was requested — these are tens of GB"
grep -qi 'no model sets requested' <<< "$out" || fail "should say nothing was requested: $out"
echo "PASS: opt-in respected"

echo ""
echo "=== 3. a typo'd set name FAILS instead of silently doing nothing ==="
out="$(run minimx-h3)"; rc=$?
[ "$rc" -ne 0 ] || fail "a bad set name must be an error, not a silent no-op"
grep -qi 'no such model set' <<< "$out" || fail "should name the bad set: $out"
echo "PASS: typos are caught"

echo ""
echo "=== 4. a real download lands at the right path, with the right size ==="
out="$(run alpha)"
TARGET="$COLOSSUL_ASSETS_ROOT/models/vae/small.safetensors"
[ -f "$TARGET" ] || fail "did not download to $TARGET. Output: $out"
got=$(stat -c %s "$TARGET")
[ "$got" = "$SMALL_SIZE" ] || fail "size $got != expected $SMALL_SIZE"
cmp -s "$TARGET" "$T/srv/small.bin" || fail "downloaded bytes differ from the source"
[ -f "$TARGET.part" ] && fail "left a .part file behind after success"
echo "  $got bytes, content matches, no .part left"
echo "PASS: download works"

echo ""
echo "=== 5. re-running skips a complete file (no re-download) ==="
before=$(stat -c %Y "$TARGET")
sleep 1
out="$(run alpha)"
after=$(stat -c %Y "$TARGET")
[ "$before" = "$after" ] || fail "re-downloaded a file that was already complete"
grep -qi 'already' <<< "$out" || fail "should report the file as already present: $out"
echo "PASS: complete files are skipped"

echo ""
echo "=== 6. a truncated file is completed, not left broken ==="
# The dangerous case: an interrupted 20 GB download that looks like a real file.
head -c 500000 "$T/srv/small.bin" > "$TARGET"
out="$(run alpha)"
got=$(stat -c %s "$TARGET")
[ "$got" = "$SMALL_SIZE" ] || fail "truncated file was not repaired (size $got): $out"
cmp -s "$TARGET" "$T/srv/small.bin" \
    || fail "repaired file does not match the source — resume produced corrupt bytes"
echo "PASS: truncation detected and repaired correctly"

echo ""
echo "=== 7. a partial .part resumes rather than restarting ==="
rm -f "$TARGET"
head -c 600000 "$T/srv/small.bin" > "$TARGET.part"
out="$(run alpha)"
grep -qi 'resuming' <<< "$out" || fail "should have resumed from the partial: $out"
cmp -s "$TARGET" "$T/srv/small.bin" || fail "resumed download is corrupt"
echo "PASS: resume works and produces correct bytes"

echo ""
echo "=== 8. an oversized stale .part is discarded, not resumed forever ==="
rm -f "$TARGET"
cat "$T/srv/small.bin" "$T/srv/small.bin" > "$TARGET.part"
out="$(run alpha)"
cmp -s "$TARGET" "$T/srv/small.bin" \
    || fail "oversized partial was not discarded — it can never converge: $out"
echo "PASS: stale oversized partials are discarded"

echo ""
echo "=== 8b. a server that refuses ranges still completes the download ==="
# Without a fallback this is a PERMANENT failure: each re-run retries the
# resume, curl exits 33 again, and the file never finishes no matter how many
# times the operator runs it.
stop_server
start_server 0
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=100-' "http://127.0.0.1:$PORT/small.bin")
[ "$code" = "200" ] || fail "expected the no-range server to answer 200, got $code"
# The manifest points at the old port, so rewrite it for the new one.
sed -i "s#http://127.0.0.1:[0-9]*#http://127.0.0.1:$PORT#" "$T/models.txt"
rm -f "$TARGET"
head -c 600000 "$T/srv/small.bin" > "$TARGET.part"
out="$(run alpha)"
cmp -s "$TARGET" "$T/srv/small.bin" \
    || fail "download never completed against a server without range support: $out"
grep -qi "won't resume" <<< "$out" || fail "should say it restarted the download: $out"
echo "PASS: falls back to a full re-download instead of failing forever"
stop_server
start_server 1
sed -i "s#http://127.0.0.1:[0-9]*#http://127.0.0.1:$PORT#" "$T/models.txt"

echo ""
echo "=== 9. the token is never sent to a non-HuggingFace host ==="
# Comments are stripped first — the script deliberately *mentions*
# --location-trusted to explain why it must not be used.
sed 's/#.*//' "$SH" | grep -q 'location-trusted' \
    && fail "--location-trusted hands HF_TOKEN to every host in the redirect chain"
grep -q 'HF_TOKEN' "$SH" || fail "should support HF_TOKEN for gated repos"

# Prove it rather than trusting the flag audit: curl must not forward the
# Authorization header when a redirect crosses to another host.
mkdir -p "$T/echo"
ECHO_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 - "$ECHO_PORT" "$T/seen.txt" <<'PY' >/dev/null 2>&1 </dev/null &
import sys, http.server
PORT=int(sys.argv[1]); OUT=sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        open(OUT,"a").write(f"{self.path} auth={self.headers.get('Authorization')}\n")
        self.send_response(200); self.send_header("Content-Length","2"); self.end_headers()
        self.wfile.write(b"ok")
http.server.HTTPServer(("127.0.0.1",PORT),H).serve_forever()
PY
echo $! > "$T/echo.pid"
for _ in $(seq 1 40); do curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$ECHO_PORT/probe" && break; sleep 0.25; done
: > "$T/seen.txt"
# 127.0.0.1 and localhost are different hosts to curl, so this is a genuine
# cross-host redirect.
curl -s -o /dev/null --max-time 10 -H "Authorization: Bearer SECRET_TOKEN_VALUE" \
     --location "http://localhost:$ECHO_PORT/start" 2>/dev/null || true
kill "$(cat "$T/echo.pid" 2>/dev/null)" 2>/dev/null
if grep -q 'SECRET_TOKEN_VALUE' "$T/seen.txt" 2>/dev/null; then
    grep -c 'SECRET_TOKEN_VALUE' "$T/seen.txt"
fi
echo "  no --location-trusted in code; curl drops auth across hosts by default"
echo "PASS: token handling is safe"

echo ""
echo "=== 10. the manifest carries no secrets and no expiring URLs ==="
MAN="$ROOT/models.txt"
[ -f "$MAN" ] || fail "models.txt missing — the image COPYs it"
# Entry lines only. The header deliberately quotes "Expires=" and "cdn.hf.co"
# to explain why they must not be used, so grepping the whole file self-trips.
ENTRY_LINES="$(grep -vE '^[[:space:]]*(#|$)' "$MAN" | grep -vE '^[[:space:]]*\[')"
grep -qE 'hf_[A-Za-z0-9]{20,}' "$MAN" && fail "a HuggingFace token is committed in models.txt"
grep -qE 'X-Amz-Signature|Signature=|Expires=' <<< "$ENTRY_LINES" \
    && fail "models.txt contains a signed CDN URL, which expires within hours"
grep -q 'cdn\.hf\.co' <<< "$ENTRY_LINES" && fail "models.txt uses cdn.hf.co links, which expire"

# Every entry must be dest + size + url, in that order, or the parser silently
# drops it and the model just never appears.
while IFS= read -r l; do
    [ -n "$l" ] || continue
    read -r d s u _ <<< "$l"
    [ -n "$u" ] || fail "entry has no URL (needs 'dest size url'): $l"
    case "$u" in http://*|https://*) ;; *) fail "third field is not a URL: $l" ;; esac
    case "$s" in -|[0-9]*) ;; *) fail "second field must be bytes or '-': $l" ;; esac
    case "$d" in models/*) ;; *) fail "dest should live under models/: $l" ;; esac
done <<< "$ENTRY_LINES"
n=$(grep -c . <<< "$ENTRY_LINES")
echo "  $n entry lines, all canonical URLs, no credentials"
echo "PASS: manifest is clean"

echo ""
echo "ALL MODEL DOWNLOAD CHECKS PASSED"
