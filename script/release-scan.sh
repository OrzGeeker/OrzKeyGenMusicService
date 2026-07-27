#!/bin/bash
# release-scan — 生产环境临时启动 scanner 并触发音频扫描
#
# 用法:
#   MUSIC_DIR=/absolute/path/to/music ./script/release-scan.sh
#
# 环境变量:
#   IMAGE_REF       目标镜像引用（生产 Compose 需要）
#   MUSIC_DIR       宿主机音频目录；会挂载到容器内 /sources/keygen
#   SCAN_URL        scanner 地址（默认 http://127.0.0.1:8081）
#   SCAN_SOURCE     容器内扫描路径（默认 /sources/keygen）
#   SCAN_WAIT       等待 scanner 启动的秒数（默认 30）
#   COMPOSE_FILE    docker-compose 配置（默认 -f docker-compose.yml -f docker-compose.production.yml）

set -euo pipefail

COMPOSE_BASE="${COMPOSE_FILE:--f docker-compose.yml -f docker-compose.production.yml}"
COMPOSE="${DOCKER_COMPOSE:-docker compose}"
SCAN_URL="${SCAN_URL:-http://127.0.0.1:8081}"
SCAN_SOURCE="${SCAN_SOURCE:-/sources/keygen}"
SCAN_WAIT="${SCAN_WAIT:-30}"

if [ -z "${IMAGE_REF:-}" ]; then
    echo "ERROR: IMAGE_REF is required"
    echo "Usage: IMAGE_REF=ghcr.io/orzgeeker/orzmusic:<version> MUSIC_DIR=/path/to/music $0"
    exit 1
fi

if [ -z "${MUSIC_DIR:-}" ]; then
    echo "ERROR: MUSIC_DIR is required"
    echo "Usage: MUSIC_DIR=/path/to/music $0"
    exit 1
fi

if [ ! -d "$MUSIC_DIR" ]; then
    echo "ERROR: MUSIC_DIR is not a directory: $MUSIC_DIR"
    exit 1
fi

if [ "${MUSIC_DIR#/}" = "$MUSIC_DIR" ]; then
    echo "ERROR: MUSIC_DIR must be an absolute path: $MUSIC_DIR"
    exit 1
fi

echo "=== Release Scan ==="
echo "Image: $IMAGE_REF"
echo "Music dir: $MUSIC_DIR"
echo "Container source: $SCAN_SOURCE"
echo "Scanner URL: $SCAN_URL"
echo ""

echo "[1/3] Starting temporary scanner service..."
SCAN_CONTAINER="$(KEYGEN_DIR="$MUSIC_DIR" IMAGE_REF="$IMAGE_REF" $COMPOSE $COMPOSE_BASE run --rm -d --service-ports scan)"

cleanup() {
    if [ -n "${SCAN_CONTAINER:-}" ]; then
        docker stop "$SCAN_CONTAINER" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "Scanner container: $SCAN_CONTAINER"
echo ""

echo "[2/3] Waiting for scanner readiness..."
ready=false
for _ in $(seq 1 "$SCAN_WAIT"); do
    if curl -fsS "$SCAN_URL/api/health" >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 1
done

if [ "$ready" != true ]; then
    echo "ERROR: scanner did not become ready within ${SCAN_WAIT}s"
    echo "Logs:"
    docker logs --tail=80 "$SCAN_CONTAINER" || true
    exit 1
fi

echo "Scanner is ready."
echo ""

echo "[3/3] Triggering scan..."
curl -fsS -X POST "$SCAN_URL/api/scan" \
    -H "Content-Type: application/json" \
    -d "{\"sources\":[\"$SCAN_SOURCE\"]}"

echo ""
echo "=== Scan Complete ==="
