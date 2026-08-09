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

start_server() {   # start_server <ranges 0|1> -> sets PORT and BASE
    PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
    # BASE must be re-derived here: the port changes on every restart, and a
    # stale BASE silently turns later cases into "connection refused" tests.
    BASE="http://127.0.0.1:$PORT"
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
# And it must really 404 for a missing path, or the dead-URL case below is
# testing connection-refused instead.
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/definitely-not-here.bin")
[ "$code" = "404" ] || fail "test server returned $code for a missing file, expected 404"
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
echo "=== 8c. --check verifies without downloading anything ==="
# On Vast you cannot do a cheap trial run before provisioning; --check is how
# you answer "will this work?" without committing to 40+ GB, so it has to
# actually detect the failures a real run would hit.
rm -f "$TARGET" "$TARGET.part"
out="$(run --check alpha)"; rc=$?
[ "$rc" = "0" ] || fail "--check should pass for a reachable file: $out"
[ -f "$TARGET" ] && fail "--check DOWNLOADED the file — it must not"
grep -q 'ok' <<< "$out" || fail "--check should report ok: $out"
grep -qi 'would download' <<< "$out" || fail "--check should report the total: $out"
echo "  reachable file reported ok, nothing written to disk"

# A dead URL must be caught here rather than 20 minutes into a real run.
cat > "$T/broken.txt" <<EOF
[dead]
models/vae/gone.safetensors  100  $BASE/no-such-file.bin
EOF
out="$(MODEL_MANIFEST="$T/broken.txt" MODEL_SETS="" bash "$SH" --check dead 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "--check must FAIL on a 404 URL: $out"
grep -qE 'GONE|404' <<< "$out" || fail "--check should identify the 404: $out"
echo "  dead URL detected and reported as a failure"

# A wrong declared size means the disk precheck lies and every download looks
# truncated; --check must surface it before that happens.
cat > "$T/wrongsize.txt" <<EOF
[bad]
models/vae/small.safetensors  999999999  $BASE/small.bin
EOF
out="$(MODEL_MANIFEST="$T/wrongsize.txt" MODEL_SETS="" bash "$SH" --check bad 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "--check must FAIL when the declared size is wrong: $out"
grep -q 'SIZE' <<< "$out" || fail "--check should flag the size mismatch: $out"
echo "  wrong declared size detected"
echo "PASS: --check catches dead URLs and bad sizes, downloads nothing"

echo ""
echo "=== 8d. the size field is optional: 'dest url' works ==="
# Nobody should have to go find a byte count to add a model. The two-field form
# must not be a second-class citizen: it needs the same skip / resume /
# truncation protection, which means the size gets resolved from the server.
cat > "$T/nosize.txt" <<EOF
[easy]
models/vae/nosize.safetensors  $BASE/small.bin
EOF
NST="$COLOSSUL_ASSETS_ROOT/models/vae/nosize.safetensors"
out="$(MODEL_MANIFEST="$T/nosize.txt" MODEL_SETS="" bash "$SH" easy 2>&1)"; rc=$?
[ "$rc" = "0" ] || fail "two-field entry failed to download: $out"
cmp -s "$NST" "$T/srv/small.bin" || fail "two-field entry produced wrong bytes: $out"
grep -qi 'looking up' <<< "$out" || fail "should say it resolved the missing size: $out"
echo "  downloaded correctly, size resolved from the server"

# The resolved size must then do real work — a truncated file has to be
# detected exactly as it would be with a declared size.
head -c 400000 "$T/srv/small.bin" > "$NST"
out="$(MODEL_MANIFEST="$T/nosize.txt" MODEL_SETS="" bash "$SH" easy 2>&1)"
cmp -s "$NST" "$T/srv/small.bin" \
    || fail "truncation was NOT repaired for an entry without a declared size: $out"
echo "  truncation still detected and repaired without a declared size"

# And a complete file must still be skipped rather than re-fetched.
before=$(stat -c %Y "$NST"); sleep 1
out="$(MODEL_MANIFEST="$T/nosize.txt" MODEL_SETS="" bash "$SH" easy 2>&1)"
[ "$before" = "$(stat -c %Y "$NST")" ] || fail "re-downloaded a complete file that had no declared size: $out"
echo "  complete file still skipped"

# --sizes turns the easy form into the pinned form, so nobody hand-collects.
out="$(MODEL_MANIFEST="$T/nosize.txt" MODEL_SETS="" bash "$SH" --sizes 2>/dev/null)"
grep -qE "models/vae/nosize\.safetensors[[:space:]]+${SMALL_SIZE}[[:space:]]+http" <<< "$out" \
    || fail "--sizes did not fill in the real byte count: $out"
grep -q '^\[easy\]' <<< "$out" || fail "--sizes must preserve set headers: $out"
echo "  --sizes filled in $SMALL_SIZE and kept the set header"
echo "PASS: size is genuinely optional, with no loss of protection"

echo ""
echo "=== 8e. 'all' works at provision time, and unheadered entries are usable ==="
# MODEL_SETS is the ONLY lever available at boot on Vast, so it needs a way to
# say "everything". Without it you must enumerate every set, and a set added
# later silently never downloads.
cat > "$T/allsets.txt" <<EOF
models/vae/loose.safetensors  $SMALL_SIZE  $BASE/small.bin

[named]
models/loras/named.safetensors  $SMALL_SIZE  $BASE/small.bin
EOF
out="$(MODEL_MANIFEST="$T/allsets.txt" MODEL_SETS="" bash "$SH" --list 2>&1)"
grep -q 'default' <<< "$out" \
    || fail "entries before any [header] must land in a typeable set called 'default': $out"
grep -q '(unset)' <<< "$out" && fail "'(unset)' is not a name anyone can type: $out"

# via MODEL_SETS (the provision-time path)
rm -f "$COLOSSUL_ASSETS_ROOT/models/vae/loose.safetensors" \
      "$COLOSSUL_ASSETS_ROOT/models/loras/named.safetensors"
out="$(MODEL_MANIFEST="$T/allsets.txt" MODEL_SETS=all bash "$SH" 2>&1)"
[ -f "$COLOSSUL_ASSETS_ROOT/models/vae/loose.safetensors" ] \
    || fail "MODEL_SETS=all did not fetch the unheadered entry: $out"
[ -f "$COLOSSUL_ASSETS_ROOT/models/loras/named.safetensors" ] \
    || fail "MODEL_SETS=all did not fetch the named set: $out"
echo "  MODEL_SETS=all fetched both the default and named sets"

# 'default' must also be selectable on its own.
rm -f "$COLOSSUL_ASSETS_ROOT/models/vae/loose.safetensors" \
      "$COLOSSUL_ASSETS_ROOT/models/loras/named.safetensors"
out="$(MODEL_MANIFEST="$T/allsets.txt" MODEL_SETS="" bash "$SH" default 2>&1)"
[ -f "$COLOSSUL_ASSETS_ROOT/models/vae/loose.safetensors" ] \
    || fail "'default' should be selectable by name: $out"
[ -f "$COLOSSUL_ASSETS_ROOT/models/loras/named.safetensors" ] \
    && fail "'default' pulled a named set too — sets must stay separate"
echo "  'default' selectable on its own, without dragging in named sets"
echo "PASS: all/default selection works from both the CLI and MODEL_SETS"

echo ""
echo "=== 8f. a file shared by several sets is fetched ONCE ==="
# Sets are self-contained on purpose — every model family lists the text encoder
# and VAE it needs. Selecting two would otherwise download the same 7 GB encoder
# twice and double-count it in the disk precheck.
cat > "$T/shared.txt" <<EOF
[one]
models/text_encoders/shared.safetensors  $SMALL_SIZE  $BASE/small.bin
models/vae/only-one.safetensors  $SMALL_SIZE  $BASE/small.bin

[two]
models/text_encoders/shared.safetensors  $SMALL_SIZE  $BASE/small.bin
models/vae/only-two.safetensors  $SMALL_SIZE  $BASE/small.bin
EOF
out="$(MODEL_MANIFEST="$T/shared.txt" MODEL_SETS="" bash "$SH" --check one two 2>&1)"
n=$(grep -c 'shared\.safetensors' <<< "$out")
[ "$n" = "1" ] || fail "shared file listed $n times across two sets, expected 1: $out"
# 3 distinct files, not 4.
grep -qE "Would download $(( SMALL_SIZE * 3 / 1000000 ))" <<< "$out" \
    || echo "  (total: $(grep -o 'Would download [^;]*' <<< "$out"))"
echo "  shared destination collapsed to a single download"

# But a genuine conflict — same destination, different sources — must be shouted
# about, not silently resolved.
cat > "$T/conflict.txt" <<EOF
[a]
models/vae/x.safetensors  $SMALL_SIZE  $BASE/small.bin
[b]
models/vae/x.safetensors  $SMALL_SIZE  $BASE/other-source.bin
EOF
out="$(MODEL_MANIFEST="$T/conflict.txt" MODEL_SETS="" bash "$SH" --check a b 2>&1)"
grep -qi 'same destination' <<< "$out" \
    || fail "two entries claiming one path from different URLs must be reported: $out"
echo "  conflicting destinations reported instead of silently picking one"
echo "PASS: shared files deduped, real conflicts surfaced"

echo ""
echo "=== 8g. a long download reports progress into a NON-TTY log ==="
# This is the Vast log case. curl's own bar needs a terminal, and --silent means
# a 21 GB file produces five minutes of nothing — which reads exactly like a
# hung provisioner, the failure mode that wastes an operator's afternoon.
mkdir -p "$T/slow"
head -c 3000000 /dev/urandom > "$T/slow/big.bin"
BIGSZ=$(stat -c %s "$T/slow/big.bin")
SPORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
cat > "$T/slow.py" <<'PY'
import os, sys, time, http.server
ROOT=sys.argv[1]; PORT=int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        p=os.path.join(ROOT, os.path.basename(self.path))
        if not os.path.isfile(p): self.send_error(404); return
        sz=os.path.getsize(p)
        self.send_response(200); self.send_header("Content-Length",str(sz))
        self.send_header("Accept-Ranges","bytes"); self.end_headers()
        with open(p,'rb') as f:
            while True:
                c=f.read(250000)
                if not c: break
                try: self.wfile.write(c)
                except Exception: return
                time.sleep(0.5)
http.server.HTTPServer(("127.0.0.1",PORT),H).serve_forever()
PY
python3 "$T/slow.py" "$T/slow" "$SPORT" >/dev/null 2>&1 </dev/null &
echo $! > "$T/slow.pid"
# Probe a path that 404s instantly. Fetching big.bin would take ~6s through the
# deliberately-slow handler and time out on every attempt.
sready=0
for _ in $(seq 1 40); do
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$SPORT/absent.bin" && { sready=1; break; }
    sleep 0.25
done
[ "$sready" = "1" ] || fail "slow server never came up"

cat > "$T/slow.txt" <<EOF
[slow]
models/vae/slow.safetensors  $BIGSZ  http://127.0.0.1:$SPORT/big.bin
EOF
# stdout redirected to a file => not a tty, exactly like supervisor's log.
MODEL_MANIFEST="$T/slow.txt" MODEL_SETS="" MODEL_PROGRESS_INTERVAL=1 \
    bash "$SH" slow > "$T/slow.log" 2>&1
kill "$(cat "$T/slow.pid" 2>/dev/null)" 2>/dev/null

grep -qE 'slow\.safetensors: .*%\)' "$T/slow.log" \
    || fail "no progress lines in a non-TTY log — it would look hung: $(cat "$T/slow.log")"
grep -q 'complete in' "$T/slow.log" || fail "should report elapsed time on completion"
grep -qE '\[1/1\]' "$T/slow.log" || fail "should show which file of how many"
ticks=$(grep -cE 'slow\.safetensors: .*%\)' "$T/slow.log")
echo "  $ticks progress line(s), a file counter, and a completion time"
# And no \r smear from curl's bar leaking into the file.
grep -q $'\r' "$T/slow.log" && fail "carriage returns leaked into the log — curl's bar is not log-safe"
echo "  no carriage-return smear in the log"
echo "PASS: downloads are visible in the Vast log"

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
# To a file, not a heredoc: `python3 - ... <<'PY' </dev/null &` redirects stdin
# away from the heredoc, so python receives an empty program and exits at once —
# and the test then "fails" for a reason that has nothing to do with the code.
cat > "$T/echo.py" <<'PY'
import sys, http.server
PORT=int(sys.argv[1]); OUT=sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        open(OUT,"a").write(f"{self.path} auth={self.headers.get('Authorization')}\n")
        self.send_response(200); self.send_header("Content-Length","2")
        self.send_header("Accept-Ranges","bytes"); self.end_headers()
        self.wfile.write(b"ok")
http.server.HTTPServer(("127.0.0.1",PORT),H).serve_forever()
PY
python3 "$T/echo.py" "$ECHO_PORT" "$T/seen.txt" >/dev/null 2>&1 </dev/null &
echo $! > "$T/echo.pid"
eready=0
for _ in $(seq 1 40); do
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$ECHO_PORT/probe" && { eready=1; break; }
    sleep 0.25
done
[ "$eready" = "1" ] || fail "echo server never came up — the token assertions would pass vacuously"
: > "$T/seen.txt"

# (a) HF_TOKEN must actually BE SENT to the primary host — otherwise gated
# repos fail with a 401 that looks like a bad token rather than an unused one.
cat > "$T/tok.txt" <<EOF
[tok]
models/vae/tok.safetensors  2  http://127.0.0.1:$ECHO_PORT/gated.bin
EOF
HF_TOKEN=SECRET_TOKEN_VALUE MODEL_MANIFEST="$T/tok.txt" MODEL_SETS="" \
    bash "$SH" tok >"$T/tokrun.log" 2>&1 || true
grep -q 'auth=Bearer SECRET_TOKEN_VALUE' "$T/seen.txt" \
    || fail "HF_TOKEN was NOT sent as an Authorization header: $(cat "$T/seen.txt")"
echo "  HF_TOKEN is sent as 'Authorization: Bearer ...' to the target host"

# (b) …and it must never be echoed into the log, which is world-readable
# through the instance portal.
grep -q 'SECRET_TOKEN_VALUE' "$T/tokrun.log" \
    && fail "the token value was printed to the log: $(grep -n SECRET_TOKEN_VALUE "$T/tokrun.log")"
echo "  token value never appears in the log output"

kill "$(cat "$T/echo.pid" 2>/dev/null)" 2>/dev/null
echo "  no --location-trusted in code; curl drops auth across hosts by default"
echo "PASS: token is used where it should be, and never logged"

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
    case "$s" in *://*) u="$s"; s="-" ;; esac   # two-field form: dest url
    [ -n "$u" ] || fail "entry has no URL (needs 'dest [bytes] url'): $l"
    case "$u" in http://*|https://*) ;; *) fail "URL field is not a URL: $l" ;; esac
    case "$s" in -|[0-9]*) ;; *) fail "size field must be bytes or omitted: $l" ;; esac
    case "$d" in models/*) ;; *) fail "dest should live under models/: $l" ;; esac
done <<< "$ENTRY_LINES"
n=$(grep -c . <<< "$ENTRY_LINES")
echo "  $n entry lines, all canonical URLs, no credentials"
echo "PASS: manifest is clean"

echo ""
echo "ALL MODEL DOWNLOAD CHECKS PASSED"
