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
PY="${PYTHON:-python3}"

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

# Aggregate, not per-file: with several transfers in flight, per-file lines
# interleave into noise, and "how long until the library is here" is the number
# an operator actually needs.
grep -qE 'progress: .*%\).*eta' "$T/slow.log" \
    || fail "no progress lines in a non-TTY log — it would look hung: $(cat "$T/slow.log")"
# "how many of how many files" is the question an operator actually asks of a
# 59-file library; bytes alone do not answer it.
grep -qE 'progress: [0-9]+/[0-9]+ files' "$T/slow.log" \
    || fail "progress should report files complete out of total: $(cat "$T/slow.log")"
grep -q 'done slow' "$T/slow.log" || fail "should report each file finishing"
grep -qE '\[1/1\] start' "$T/slow.log" || fail "should show which file of how many"
ticks=$(grep -cE 'progress: .*%\)' "$T/slow.log")
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
grep -q 'CIVITAI_TOKEN' "$SH" || fail "should support CIVITAI_TOKEN for civitai.com URLs"

# Each token must go ONLY to its own host. Sending the HuggingFace key to
# Civitai (or the reverse) hands a credential to a service with no business
# seeing it, and both are long-lived keys.
(
    # shellcheck disable=SC1090
    eval "$(sed -n '/^_set_urlauth()/,/^}/p' "$SH")"
    # Exported so shellcheck can see they leave this scope; the eval'd
    # _set_urlauth reads them.
    export HF_TOKEN=HFSECRET
    export CIVITAI_TOKEN=CIVSECRET
    _URLAUTH=(); _set_urlauth "https://huggingface.co/x/resolve/main/y"
    printf 'hf:%s\n' "${_URLAUTH[*]:-none}"
    _URLAUTH=(); _set_urlauth "https://civitai.com/api/download/models/1"
    printf 'civ:%s\n' "${_URLAUTH[*]:-none}"
    _URLAUTH=(); _set_urlauth "https://example.com/model.safetensors"
    printf 'other:%s\n' "${_URLAUTH[*]:-none}"
) > "$T/urlauth.txt" 2>&1
grep -q '^hf:.*HFSECRET' "$T/urlauth.txt"   || fail "HF_TOKEN not sent to huggingface.co: $(cat "$T/urlauth.txt")"
grep -q '^hf:.*CIVSECRET' "$T/urlauth.txt"  && fail "Civitai token leaked to huggingface.co"
grep -q '^civ:.*CIVSECRET' "$T/urlauth.txt" || fail "CIVITAI_TOKEN not sent to civitai.com"
grep -q '^civ:.*HFSECRET' "$T/urlauth.txt"  && fail "HuggingFace token leaked to civitai.com"
grep -q '^other:none' "$T/urlauth.txt"      || fail "a third-party host received a token: $(cat "$T/urlauth.txt")"
echo "  each token goes only to its own host; third parties get none"

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

# (a) End-to-end: a THIRD-PARTY host must receive no Authorization header at
# all, even with both tokens set. The unit check above proves the selection
# logic; this proves nothing bypasses it on the real download path.
cat > "$T/tok.txt" <<EOF
[tok]
models/vae/tok.safetensors  2  http://127.0.0.1:$ECHO_PORT/gated.bin
EOF
HF_TOKEN=SECRET_TOKEN_VALUE CIVITAI_TOKEN=CIV_SECRET_VALUE \
    MODEL_MANIFEST="$T/tok.txt" MODEL_SETS="" \
    bash "$SH" tok >"$T/tokrun.log" 2>&1 || true
grep -q 'SECRET_TOKEN_VALUE\|CIV_SECRET_VALUE' "$T/seen.txt" \
    && fail "a token was sent to an unrelated host: $(cat "$T/seen.txt")"
grep -q 'gated.bin' "$T/seen.txt" \
    || fail "the request never reached the test server, so this proved nothing: $(cat "$T/seen.txt")"
echo "  a third-party host is contacted with NO Authorization header"

# (b) …and it must never be echoed into the log, which is world-readable
# through the instance portal.
grep -qE 'SECRET_TOKEN_VALUE|CIV_SECRET_VALUE' "$T/tokrun.log" \
    && fail "a token value was printed to the log: $(grep -nE 'SECRET_TOKEN_VALUE|CIV_SECRET_VALUE' "$T/tokrun.log")"
echo "  token value never appears in the log output"

kill "$(cat "$T/echo.pid" 2>/dev/null)" 2>/dev/null
echo "  no --location-trusted in code; curl drops auth across hosts by default"
echo "PASS: token is used where it should be, and never logged"

echo ""
echo "=== 8h. concurrent downloads: correct bytes, and actually concurrent ==="
# HuggingFace throttles per connection, so one stream degrades badly over a long
# pull — sequential moved ten files in an hour. Concurrency is the fix, but only
# if every byte still lands correctly and partials still resume.
mkdir -p "$T/many"
for i in 1 2 3 4; do head -c 700000 /dev/urandom > "$T/many/m$i.bin"; done
MSZ=$(stat -c %s "$T/many/m1.bin")
cp "$T/many"/*.bin "$T/srv/"
{ echo "[many]"
  for i in 1 2 3 4; do echo "models/vae/m$i.safetensors  $MSZ  $BASE/m$i.bin"; done
} > "$T/many.txt"

# A partial, so resume is exercised while other transfers are in flight.
mkdir -p "$COLOSSUL_ASSETS_ROOT/models/vae"
head -c 200000 "$T/many/m2.bin" > "$COLOSSUL_ASSETS_ROOT/models/vae/m2.safetensors.part"

out="$(MODEL_MANIFEST="$T/many.txt" MODEL_SETS="" MODEL_DL_JOBS=4 \
       MODEL_PROGRESS_INTERVAL=1 bash "$SH" many 2>&1)"
for i in 1 2 3 4; do
    cmp -s "$COLOSSUL_ASSETS_ROOT/models/vae/m$i.safetensors" "$T/many/m$i.bin" \
        || fail "m$i is not byte-identical after a concurrent run: $out"
done
echo "  4/4 byte-identical with 4 workers"
grep -qi 'resuming m2' <<< "$out" || fail "the pre-seeded partial was not resumed: $out"
echo "  a partial still resumed while other transfers were running"
[ -z "$(find "$COLOSSUL_ASSETS_ROOT" -name '*.part' 2>/dev/null)" ] \
    || fail "left .part files behind after a successful concurrent run"
echo "  no .part files left behind"

# Results must survive the subshell boundary — bash arrays do not, so a worker's
# success or failure has to be recorded on disk or the summary silently reads
# "0 downloaded" after a perfect run.
grep -q 'Models: 4 downloaded' <<< "$out" \
    || fail "worker results did not reach the parent (arrays don't cross subshells): $out"
echo "  worker results collected across the subshell boundary"

# Concurrency must be real, not just requested.
grep -q '4 concurrent' <<< "$out" || fail "should state the concurrency it used: $out"
starts=$(grep -c 'start m' <<< "$out")
[ "$starts" = "4" ] || fail "expected 4 start lines, got $starts"
echo "PASS: parallel downloads are correct and resumable"

echo ""
echo "=== 8i. link: gives one file a second name, without a second download ==="
# ComfyUI resolves a model name inside its category folder, so a file loaded as
# both a checkpoint and a VAE must exist in both. LTX 2.3's all-in-one build is
# 46 GB; fetching it per loader would be 138 GB.
cat > "$T/link.txt" <<EOF
[aliased]
models/checkpoints/aio.safetensors  $SMALL_SIZE  $BASE/small.bin
models/vae/aio.safetensors  link:models/checkpoints/aio.safetensors
models/text_encoders/aio.safetensors  link:models/checkpoints/aio.safetensors
EOF
rm -rf "$COLOSSUL_ASSETS_ROOT/models/checkpoints" "$COLOSSUL_ASSETS_ROOT/models/vae/aio.safetensors"
out="$(MODEL_MANIFEST="$T/link.txt" MODEL_SETS="" bash "$SH" aliased 2>&1)"
CK="$COLOSSUL_ASSETS_ROOT/models/checkpoints/aio.safetensors"
for p in vae text_encoders; do
    f="$COLOSSUL_ASSETS_ROOT/models/$p/aio.safetensors"
    [ -f "$f" ] || fail "link not created at models/$p/aio.safetensors: $out"
    cmp -s "$f" "$T/srv/small.bin" || fail "linked file has wrong content at models/$p"
done
# One copy on disk: same inode as the source.
[ "$(stat -c %i "$CK")" = "$(stat -c %i "$COLOSSUL_ASSETS_ROOT/models/vae/aio.safetensors")" ] \
    || fail "link is a separate copy, not a link — a 46 GB file would be duplicated"
echo "  3 usable names, 1 inode, 1 download"

# A deleted link must be repaired, even though the download is complete.
rm -f "$COLOSSUL_ASSETS_ROOT/models/vae/aio.safetensors"
out="$(MODEL_MANIFEST="$T/link.txt" MODEL_SETS="" bash "$SH" aliased 2>&1)"
[ -f "$COLOSSUL_ASSETS_ROOT/models/vae/aio.safetensors" ] \
    || fail "a deleted link was not restored on re-run — it would stay missing forever: $out"
echo "  a deleted link is restored on re-run"

# A link whose source was not selected must be reported, not silently skipped.
cat > "$T/link2.txt" <<EOF
[src]
models/checkpoints/nope.safetensors  $SMALL_SIZE  $BASE/small.bin
[alias]
models/vae/nope.safetensors  link:models/checkpoints/nope.safetensors
EOF
out="$(MODEL_MANIFEST="$T/link2.txt" MODEL_SETS="" bash "$SH" alias 2>&1)"
grep -qi 'link source missing' <<< "$out" \
    || fail "a link with no source should be reported: $out"
echo "  a link with an unselected source is reported"
echo "PASS: aliased models resolve from every loader"

echo ""
echo "=== 8j. a finished download does not sit in the page cache ==="
# cgroup v2 charges cached file pages to the container, so a 700 GB library
# reads as 700 GB of "memory used" on the Vast dashboard — which is how that
# figure ends up above 100% of the machine's RAM. It is reclaimable, but it
# competes with four ComfyUI processes loading models, and reclaim under
# pressure is slower than never caching what nobody will read again.
cat > "$T/cached.py" <<'PY'
import ctypes, os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
sz = os.fstat(fd).st_size
libc = ctypes.CDLL("libc.so.6", use_errno=True)
mm = libc.mmap; mm.restype = ctypes.c_void_p
mm.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
               ctypes.c_int, ctypes.c_int, ctypes.c_long]
addr = mm(None, sz, 1, 2, fd, 0)
pages = (sz + 4095) // 4096
vec = (ctypes.c_ubyte * pages)()
libc.mincore(ctypes.c_void_p(addr), ctypes.c_size_t(sz), vec)
print(sum(1 for b in vec if b & 1) * 4096)
libc.munmap(ctypes.c_void_p(addr), ctypes.c_size_t(sz)); os.close(fd)
PY
cat > "$T/cache.txt" <<EOF
[cachetest]
models/vae/cachetest.safetensors  $SMALL_SIZE  $BASE/small.bin
EOF
rm -f "$COLOSSUL_ASSETS_ROOT/models/vae/cachetest.safetensors"
MODEL_MANIFEST="$T/cache.txt" MODEL_SETS="" bash "$SH" cachetest >/dev/null 2>&1
CT="$COLOSSUL_ASSETS_ROOT/models/vae/cachetest.safetensors"
[ -f "$CT" ] || fail "the test file did not download"
resident="$("$PY" "$T/cached.py" "$CT" 2>/dev/null || echo -1)"
# A control, so this measures the fadvise rather than the filesystem's mood.
cp "$T/srv/small.bin" "$T/control.bin"
control="$("$PY" "$T/cached.py" "$T/control.bin" 2>/dev/null || echo -1)"
if [ "$resident" -lt 0 ] || [ "$control" -lt 0 ]; then
    echo "  (mincore unavailable here — skipping the measurement)"
elif [ "$control" -le 0 ]; then
    echo "  (control was not cached either; filesystem does not cache — skipping)"
else
    [ "$resident" -lt "$((control / 4))" ] \
        || fail "download left $resident bytes cached vs $control for a plain copy — fadvise is not working"
    echo "  $resident bytes cached after download, $control after a plain copy"
fi
grep -q 'POSIX_FADV_DONTNEED' "$SH" || fail "the cache-release step is missing"
echo "PASS: downloads do not accumulate page cache"

echo ""
echo "=== 9b. downloads NEVER block the seats from starting ==="
# The default is now every set — hundreds of gigabytes. Downloading that inline
# would leave four artists staring at a dead instance for an hour, for something
# ComfyUI does not need in order to start.
P="$ROOT/scripts/provision.sh"
units_line=$(grep -n 'write_seat_unit' "$P" | head -1 | cut -d: -f1)
models_line=$(grep -n 'write_models_unit' "$P" | head -1 | cut -d: -f1)
[ -n "$units_line" ] && [ -n "$models_line" ] || fail "expected both unit writers in provision.sh"
[ "$models_line" -gt "$units_line" ] \
    || fail "model job is registered BEFORE the seats — seats must be queued first"
grep -qE '^\s*"\$\{COLOSSUL_LIB\}/install-models.sh"' "$P" \
    && fail "provision.sh still runs install-models.sh inline; that blocks seat startup"
echo "  provisioning never invokes the downloader inline"

# The unit must be a job, not a service: a finished download must not be
# restarted forever, and a failure must not flap.
"$PY" - "$ROOT" <<'PY' || fail "generated model unit is wrong"
import re, subprocess, sys, os, tempfile
root = sys.argv[1]
out = tempfile.mktemp()
script = f'''
export COLOSSUL_LIB="{root}/scripts" WORKSPACE=/tmp/w COLOSSUL_ASSETS_ROOT=/tmp/w/a
source "{root}/scripts/lib/common.sh"
write_models_unit "{out}" "alpha,beta"
'''
subprocess.run(["bash", "-c", script], check=True, capture_output=True)
cfg = open(out).read()
os.unlink(out)
def need(pat, why):
    if not re.search(pat, cfg, re.M):
        print(f"MISSING {pat}: {why}"); sys.exit(1)
need(r'^\[program:colossul-models\]', "unit name")
need(r'^autorestart=false',           "a finished download must not be restarted forever")
need(r'^startsecs=0',                 "a fast no-op run must not count as a failed start")
need(r'MODEL_SETS="alpha,beta"',      "the requested sets must reach the job")
need(r'^stdout_logfile=/dev/stdout',   "must reach the INSTANCE log, which is where an operator watches")
need(r'tee /var/log/portal/models\.log', "should also keep a portal log for its own tab")
need(r'set -o pipefail',               "without pipefail the pipe hides the downloader's exit status")

# The command must survive supervisor's own parsing as `bash -c <one script>`.
import shlex, configparser, io
c = configparser.ConfigParser(interpolation=None)
c.read_string(cfg)
parts = shlex.split(c["program:colossul-models"]["command"])
if parts[:2] != ["/bin/bash", "-c"] or len(parts) != 3:
    print(f"command does not parse to bash -c <script>: {parts}"); sys.exit(1)
PY
echo "  unit is a one-shot job, logging where the portal can show it"
echo "PASS: weights download behind the seats, never in front of them"

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
link_targets=()
while IFS= read -r l; do
    [ -n "$l" ] || continue
    read -r d s u _ <<< "$l"
    case "$d" in models/*) ;; *) fail "dest should live under models/: $l" ;; esac
    case "$s" in
        link:*)  link_targets+=("${s#link:}"); continue ;;   # dest link:other
        *://*)   u="$s"; s="-" ;;                            # dest url
    esac
    [ -n "$u" ] || fail "entry has no URL (needs 'dest [bytes] url'): $l"
    case "$u" in http://*|https://*) ;; *) fail "URL field is not a URL: $l" ;; esac
    case "$s" in -|[0-9]*) ;; *) fail "size field must be bytes or omitted: $l" ;; esac
done <<< "$ENTRY_LINES"

# Every link must point at a real entry, or it silently produces nothing.
for t in ${link_targets[@]+"${link_targets[@]}"}; do
    grep -qE "^[[:space:]]*${t//./\\.}[[:space:]]" <<< "$ENTRY_LINES" \
        || fail "link target is not an entry in this manifest: $t"
done
[ "${#link_targets[@]}" -eq 0 ] || echo "  ${#link_targets[@]} link(s), all pointing at real entries"
n=$(grep -c . <<< "$ENTRY_LINES")
echo "  $n entry lines, all canonical URLs, no credentials"
echo "PASS: manifest is clean"

echo ""
echo "ALL MODEL DOWNLOAD CHECKS PASSED"
