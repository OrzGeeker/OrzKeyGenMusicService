#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=native-common.sh
. "$SCRIPT_DIR/native-common.sh"
native_load_env

if native_pid_running; then
    echo "Native OrzMusic: running (PID $(cat "$NATIVE_PID_FILE"))"
else
    echo "Native OrzMusic: stopped"
fi

if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 2 \
    "http://127.0.0.1:$APP_PORT/api/health"; then
    echo
else
    echo "Health: unavailable"
fi
