#!/bin/bash

set -euo pipefail

COMPOSE="${DOCKER_COMPOSE:-docker compose}"
MUSIC_DIR="${MUSIC_DIR:-}"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker CLI not found" >&2
    exit 1
fi
if ! $COMPOSE version >/dev/null 2>&1; then
    echo "ERROR: docker compose is not available" >&2
    exit 1
fi
if [ -z "$MUSIC_DIR" ] || [ ! -d "$MUSIC_DIR" ] || [ ! -r "$MUSIC_DIR" ]; then
    echo "ERROR: MUSIC_DIR must be an existing readable directory" >&2
    exit 1
fi
if [ -z "${ADMIN_API_TOKEN:-}" ]; then
    echo "ERROR: ADMIN_API_TOKEN is required" >&2
    exit 1
fi

echo "Validating Docker Compose configuration..."
$COMPOSE config --quiet

echo "Starting PostgreSQL and CAS initialization..."
$COMPOSE up --build -d db cas-init

echo "Waiting for PostgreSQL..."
ready=false
for _ in $(seq 1 60); do
    if $COMPOSE exec -T db pg_isready -U vapor_username -d vapor_database >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 1
done
if [ "$ready" != true ]; then
    echo "ERROR: PostgreSQL did not become ready" >&2
    exit 1
fi

echo "Running database migrations..."
$COMPOSE run --rm migrate

echo "Starting application..."
$COMPOSE up --build -d app

echo "Checking application health..."
SERVICE_URL="${SERVICE_URL:-http://127.0.0.1:8080}" "$PWD/script/release-smoke.sh"
echo "Docker installation complete."
