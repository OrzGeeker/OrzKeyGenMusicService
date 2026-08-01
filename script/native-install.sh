#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=native-common.sh
. "$SCRIPT_DIR/native-common.sh"
native_load_env
native_require_commands swift curl
native_require_config

mkdir -p "$CAS_ROOT" "$(dirname "$NATIVE_PID_FILE")"

echo "Installing OrzAudioCore SDK assets..."
(cd "$NATIVE_PROJECT_ROOT" && make setup)

echo "Building release service..."
(cd "$NATIVE_PROJECT_ROOT" && swift build -c release)

echo "Running database migrations..."
(cd "$NATIVE_PROJECT_ROOT" && .build/release/OrzMusicService migrate --yes)

echo "Native installation complete."
echo "Use: make native-up NATIVE_ENV_FILE=$NATIVE_ENV_FILE"
