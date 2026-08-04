#!/bin/bash
# release-upgrade — 发布升级
#
# 按固定顺序执行生产升级：拉取镜像 → 备份 → 停服 → 迁移 → 启动 → 验收。
#
# 用法: IMAGE_REF=ghcr.io/<owner>/orzmusic:0.0.1 ./script/release-upgrade.sh
#
# 环境变量 (必须):
#   IMAGE_REF        目标镜像引用（必须包含版本或 digest）
#   ADMIN_API_TOKEN  管理写操作 Bearer Token；在容器启动时读取，缺失时管理接口会关闭
#
# 环境变量 (可选):
#   COMPOSE_FILE     docker-compose 配置（默认 -f docker-compose.yml -f docker-compose.production.yml）
#   BACKUP_DIR       备份输出目录（默认 ./backups）
#   RELEASE_LOG      发布日志路径（默认 ./release-log.txt）
#
# 安全约束:
#   - 任一步失败立即停止
#   - 不执行 docker compose down -v
#   - 迁移失败时保持应用停止

set -uo pipefail

COMPOSE_BASE="${COMPOSE_FILE:--f docker-compose.yml -f docker-compose.production.yml}"
COMPOSE="${DOCKER_COMPOSE:-docker compose}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
RELEASE_LOG="${RELEASE_LOG:-./release-log.txt}"

# ---- 参数校验 ----
if [ -z "${IMAGE_REF:-}" ]; then
    echo "ERROR: IMAGE_REF is required"
    echo "Usage: IMAGE_REF=ghcr.io/<owner>/orzmusic:<version> ADMIN_API_TOKEN=<token> $0"
    exit 1
fi

if [ -z "${ADMIN_API_TOKEN:-}" ]; then
    echo "ERROR: ADMIN_API_TOKEN is required"
    echo "The token is read when the app container starts; without it every admin "
    echo "write endpoint (upload/scan/delete) is disabled with 503 admin_api_disabled."
    echo "Generate one with make generate-admin-token and re-run release-upgrade."
    exit 1
fi

echo "=== Release Upgrade ==="
echo "Target: $IMAGE_REF"
echo "Started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

# ---- 发布日志写入函数 ----
log_release() {
    local action="$1"
    local status="$2"
    local detail="${3:-}"
    printf "%s | %s | %s | %s | %s\n" \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        "$action" \
        "$status" \
        "${IMAGE_REF:-unknown}" \
        "$detail" >> "$RELEASE_LOG"
}

touch "$RELEASE_LOG"

# ---- 1. 前置检查 ----
echo "[1/6] Running preflight checks..."
if ! ./script/release-preflight.sh; then
    log_release "preflight" "FAILED"
    echo "ERROR: Preflight checks failed. Aborting."
    exit 1
fi
log_release "preflight" "OK"
echo ""

# ---- 2. 拉取镜像 ----
echo "[2/6] Pulling image: $IMAGE_REF..."
if ! $COMPOSE $COMPOSE_BASE pull app; then
    log_release "pull" "FAILED" "image=$IMAGE_REF"
    echo "ERROR: Failed to pull image $IMAGE_REF"
    exit 1
fi
log_release "pull" "OK" "image=$IMAGE_REF"
echo ""

# ---- 3. 数据库备份 ----
echo "[3/6] Creating database backup..."
if ! VERSION="${IMAGE_REF##*:}" BACKUP_DIR="$BACKUP_DIR" ./script/db-backup.sh; then
    log_release "backup" "FAILED"
    echo "ERROR: Database backup failed. Aborting."
    exit 1
fi
log_release "backup" "OK"
echo ""

# ---- 4. 停止应用服务 ----
echo "[4/6] Stopping app service..."
if ! $COMPOSE $COMPOSE_BASE stop app; then
    log_release "stop" "FAILED"
    echo "ERROR: Failed to stop services. Aborting."
    exit 1
fi
log_release "stop" "OK" "stopped: app"
echo ""

# ---- 5. 执行数据库迁移 ----
echo "[5/6] Running database migrations..."
if ! $COMPOSE $COMPOSE_BASE run --rm migrate; then
    log_release "migrate" "FAILED"
    echo "ERROR: Migration failed."
    echo "  App service is stopped. Do NOT restart app with incompatible schema."
    echo "  Recovery: restore backup, then roll back to previous image:"
    echo "    IMAGE_REF=<previous-image> ./script/release-rollback.sh"
    echo "  Full restore: pg_restore -d vapor_database <backup-file>"
    exit 1
fi
log_release "migrate" "OK"
echo ""

# ---- 6. 启动应用 ----
echo "[6/6] Starting app service..."
if ! $COMPOSE $COMPOSE_BASE up -d app; then
    log_release "start" "FAILED"
    echo "ERROR: Failed to start app service."
    exit 1
fi
log_release "start" "OK"
echo ""

# ---- 验证 ----
echo "=== Upgrade Complete ==="
echo "Target: $IMAGE_REF"
echo "Finished: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""
echo "Next steps:"
echo "  1. Run smoke checks:   curl -fsS http://localhost:8080/api/health"
echo "  2. Verify format count: curl -fsS http://localhost:8080/api/songs/formats"
echo "  3. Trigger scan:       ADMIN_API_TOKEN=<token> ./script/release-scan.sh"
echo "  4. Check logs:         $COMPOSE $COMPOSE_BASE logs --tail=50 app"
echo "  Release log: $RELEASE_LOG"
