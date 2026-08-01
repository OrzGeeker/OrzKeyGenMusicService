#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=native-common.sh
. "$SCRIPT_DIR/native-common.sh"

if [ ! -s "$NATIVE_PID_FILE" ]; then
    echo "Native OrzMusic is not running"
    exit 0
fi

pid="$(cat "$NATIVE_PID_FILE")"
if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$NATIVE_PID_FILE"
    echo "Removed stale native PID file"
    exit 0
fi

command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
if ! echo "$command_line" | grep -Eq 'OrzMusicService|\.build/.*/Run'; then
    echo "ERROR: PID $pid does not look like an OrzMusic process; leaving it running" >&2
    exit 1
fi

kill "$pid"
for _ in $(seq 1 10); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
done
if kill -0 "$pid" 2>/dev/null; then
    echo "ERROR: Native OrzMusic did not stop within 10 seconds" >&2
    exit 1
fi
rm -f "$NATIVE_PID_FILE"
echo "Native OrzMusic stopped"
