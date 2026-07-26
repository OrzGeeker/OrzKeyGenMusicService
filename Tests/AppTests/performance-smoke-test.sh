#!/bin/bash

set -euo pipefail

SCRIPT="$PWD/script/performance-smoke.sh"
MOCK_PID=""
TEST_ROOT=$(mktemp -d)

cleanup() {
    if [ -n "$MOCK_PID" ] && kill -0 "$MOCK_PID" 2>/dev/null; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')

python3 -c "
import json
import http.server

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/':
            body = b'<html>OrzMusic</html>'
            content_type = 'text/html'
        elif self.path.startswith('/api/songs?'):
            body = json.dumps({'items': [], 'metadata': {'total': 0, 'page': 1, 'per': 50}}).encode()
            content_type = 'application/json'
        elif self.path == '/api/songs/formats':
            body = json.dumps({'total': 0, 'formats': []}).encode()
            content_type = 'application/json'
        elif self.path == '/api/playlists':
            body = b'[]'
            content_type = 'application/json'
        elif self.path.startswith('/api/songs/') and self.path.endswith('/stream'):
            body = bytes(range(256)) * 512
            content_type = 'application/octet-stream'
        else:
            self.send_response(404)
            self.end_headers()
            return
        start = 0
        end = len(body) - 1
        if self.headers.get('Range', '').startswith('bytes='):
            raw = self.headers['Range'][6:].split('-', 1)
            start = int(raw[0] or 0)
            end = min(int(raw[1] or end), end)
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(body)}')
        else:
            self.send_response(200)
        payload = body[start:end + 1]
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):
        pass

http.server.HTTPServer(('127.0.0.1', $PORT), Handler).serve_forever()
" &
MOCK_PID=$!

for _ in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
    sleep 0.1
done

API_OUTPUT="$TEST_ROOT/api"
SERVICE_URL="http://127.0.0.1:$PORT" PERF_REPEATS=2 PERF_OUTPUT_DIR="$API_OUTPUT" \
    bash "$SCRIPT" >/dev/null

python3 - "$API_OUTPUT/summary.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
assert set(report["medians"]) == {"formats", "home", "playlists", "songs"}
assert all(item["samples"] == 2 for item in report["medians"].values())
assert all(item["http_codes"] == [200] for item in report["medians"].values())
PY

MEDIA_OUTPUT="$TEST_ROOT/media"
SERVICE_URL="http://127.0.0.1:$PORT" PERF_REPEATS=1 PERF_OUTPUT_DIR="$MEDIA_OUTPUT" \
DIRECT_SONG_ID=direct WASM_SONG_ID=wasm BUILTIN_WASM_SONG_ID=builtin SERVER_SONG_ID=server \
    bash "$SCRIPT" >/dev/null

python3 - "$MEDIA_OUTPUT/summary.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
expected = {"home", "songs", "formats", "playlists", "directFile", "wasmDecode", "builtinWasm", "serverDecode"}
assert set(report["medians"]) == expected
for label in expected - {"home", "songs", "formats", "playlists"}:
    assert report["medians"][label]["http_codes"] == [206]
    assert report["medians"][label]["bytes"] == 1
PY

if SERVICE_URL="http://127.0.0.1:1" PERF_REPEATS=1 PERF_TIMEOUT=1 \
    PERF_OUTPUT_DIR="$TEST_ROOT/failure" bash "$SCRIPT" >/dev/null 2>&1; then
    echo "FAIL: unreachable service should return non-zero" >&2
    exit 1
fi

echo "performance-smoke tests passed"
