#!/bin/bash
# OrzMusic repeatable HTTP performance sampler.
#
# Required tools: curl, python3
# Results default to /tmp so measurements do not dirty the repository.

set -uo pipefail

SERVICE_URL="${SERVICE_URL:-http://localhost:8080}"
PERF_REPEATS="${PERF_REPEATS:-3}"
PERF_TIMEOUT="${PERF_TIMEOUT:-30}"
PERF_CACHE_MODE="${PERF_CACHE_MODE:-unspecified}"
PERF_OUTPUT_DIR="${PERF_OUTPUT_DIR:-/tmp/orzmusic-performance-$(date -u +%Y%m%dT%H%M%SZ)}"
PERF_RANGE="${PERF_RANGE:-bytes=0-0}"

if ! command -v curl >/dev/null 2>&1; then
    echo "FAIL: curl is required" >&2
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL: python3 is required" >&2
    exit 2
fi
if ! [[ "$PERF_REPEATS" =~ ^[1-9][0-9]*$ ]]; then
    echo "FAIL: PERF_REPEATS must be a positive integer" >&2
    exit 2
fi
if ! [[ "$PERF_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    echo "FAIL: PERF_TIMEOUT must be a positive integer" >&2
    exit 2
fi

mkdir -p "$PERF_OUTPUT_DIR" || {
    echo "FAIL: cannot create PERF_OUTPUT_DIR=$PERF_OUTPUT_DIR" >&2
    exit 2
}

RAW_FILE="$PERF_OUTPUT_DIR/requests.jsonl"
JSON_FILE="$PERF_OUTPUT_DIR/summary.json"
MARKDOWN_FILE="$PERF_OUTPUT_DIR/summary.md"
: > "$RAW_FILE"

FAILURES=0

sample() {
    local label="$1"
    local path="$2"
    local iteration="$3"
    local range_header="${4:-}"
    local metrics
    local url="${SERVICE_URL%/}${path}"
    local format

    format="{\"label\":\"$label\",\"iteration\":$iteration,\"cache_mode\":\"$PERF_CACHE_MODE\",\"http_code\":%{http_code},\"size_download\":%{size_download},\"time_namelookup\":%{time_namelookup},\"time_connect\":%{time_connect},\"time_appconnect\":%{time_appconnect},\"time_starttransfer\":%{time_starttransfer},\"time_total\":%{time_total},\"url_effective\":\"%{url_effective}\"}"

    if [ -n "$range_header" ]; then
        metrics=$(curl -sS --max-time "$PERF_TIMEOUT" --range "${range_header#bytes=}" \
            --output /dev/null --write-out "$format" "$url") || {
            FAILURES=$((FAILURES + 1))
            echo "WARN: $label iteration $iteration failed" >&2
            return
        }
    else
        metrics=$(curl -sS --max-time "$PERF_TIMEOUT" \
            --output /dev/null --write-out "$format" "$url") || {
            FAILURES=$((FAILURES + 1))
            echo "WARN: $label iteration $iteration failed" >&2
            return
        }
    fi

    printf '%s\n' "$metrics" >> "$RAW_FILE"
}

for iteration in $(seq 1 "$PERF_REPEATS"); do
    sample "home" "/" "$iteration"
    sample "songs" "/api/songs?page=1&per=50" "$iteration"
    sample "formats" "/api/songs/formats" "$iteration"
    sample "playlists" "/api/playlists" "$iteration"

    [ -z "${DIRECT_SONG_ID:-}" ] || sample "directFile" "/api/songs/$DIRECT_SONG_ID/stream" "$iteration" "$PERF_RANGE"
    [ -z "${WASM_SONG_ID:-}" ] || sample "wasmDecode" "/api/songs/$WASM_SONG_ID/stream" "$iteration" "$PERF_RANGE"
    [ -z "${BUILTIN_WASM_SONG_ID:-}" ] || sample "builtinWasm" "/api/songs/$BUILTIN_WASM_SONG_ID/stream" "$iteration" "$PERF_RANGE"
    [ -z "${SERVER_SONG_ID:-}" ] || sample "serverDecode" "/api/songs/$SERVER_SONG_ID/stream" "$iteration" "$PERF_RANGE"
done

python3 - "$RAW_FILE" "$JSON_FILE" "$MARKDOWN_FILE" "$SERVICE_URL" "$PERF_CACHE_MODE" <<'PY'
import json
import platform
import statistics
import sys
from collections import defaultdict
from datetime import datetime, timezone

raw_path, json_path, markdown_path, service_url, cache_mode = sys.argv[1:]
rows = []
with open(raw_path, encoding="utf-8") as source:
    for line in source:
        if line.strip():
            rows.append(json.loads(line))

if not rows:
    raise SystemExit("no successful samples collected")

groups = defaultdict(list)
for row in rows:
    groups[row["label"]].append(row)

summary = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "service_url": service_url,
    "cache_mode": cache_mode,
    "host": platform.node(),
    "platform": platform.platform(),
    "samples": rows,
    "medians": {},
}
for label, values in sorted(groups.items()):
    summary["medians"][label] = {
        "samples": len(values),
        "http_codes": sorted({int(value["http_code"]) for value in values}),
        "ttfb_ms": round(statistics.median(float(value["time_starttransfer"]) for value in values) * 1000, 3),
        "total_ms": round(statistics.median(float(value["time_total"]) for value in values) * 1000, 3),
        "bytes": round(statistics.median(float(value["size_download"]) for value in values)),
    }

with open(json_path, "w", encoding="utf-8") as target:
    json.dump(summary, target, ensure_ascii=False, indent=2)
    target.write("\n")

with open(markdown_path, "w", encoding="utf-8") as target:
    target.write("# OrzMusic performance sample\n\n")
    target.write(f"- Generated: {summary['generated_at']}\n")
    target.write(f"- Service: `{service_url}`\n")
    target.write(f"- Cache mode: `{cache_mode}`\n")
    target.write(f"- Host: `{summary['host']}`\n\n")
    target.write("| Request | Samples | HTTP | Median TTFB (ms) | Median total (ms) | Median bytes |\n")
    target.write("|:--------|--------:|:-----|-----------------:|------------------:|-------------:|\n")
    for label, values in summary["medians"].items():
        codes = ",".join(str(code) for code in values["http_codes"])
        target.write(
            f"| {label} | {values['samples']} | {codes} | {values['ttfb_ms']:.3f} | "
            f"{values['total_ms']:.3f} | {values['bytes']} |\n"
        )
PY

echo "Raw samples: $RAW_FILE"
echo "JSON summary: $JSON_FILE"
echo "Markdown summary: $MARKDOWN_FILE"

if [ "$FAILURES" -gt 0 ]; then
    echo "FAIL: $FAILURES request(s) failed" >&2
    exit 1
fi
