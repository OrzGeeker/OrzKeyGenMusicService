#!/bin/bash

set -euo pipefail

if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl is required to generate an admin token" >&2
    exit 1
fi

token="$(openssl rand -hex 32)"
if ! [[ "$token" =~ ^[0-9a-f]{64}$ ]]; then
    echo "ERROR: openssl returned an unexpected token" >&2
    exit 1
fi

printf '%s\n' "$token"
