#!/bin/bash
# release-rollback — 回滚到上一版本
#
# 回滚到指定的上一镜像。不自动恢复数据库（保留迁移后的状态）。
# 仅当迁移向后兼容时才能安全回滚。
#
# 用法: IMAGE_REF=ghcr.io/<owner>/orzmusic:0.0.1 ./script/release-rollback.sh
#       （指定上一版本的镜像引用，不是当前版本）
#
# 环境变量 (必须):
#   IMAGE_REF       上一版本的镜像引用
#
# 环境变量 (可选):
#   COMPOSE_FILE     docker-compose 配置（默认 -f docker-compose.yml -f docker-compose.production.yml）
#   RELEASE_LOG      发布日志路径（默认 ./release-log.txt）

set -uo pipefail

COMPOSE_BASE="${COMPOSE_FILE:--f docker-compose.yml -f docker-compose.production.yml}"
COMPOSE="${DOCKER_COMPOSE:-docker compose}"
RELEASE_LOG="${RELEASE_LOG:-./release-log.txt}"

# ---- 参数校验 ----
if [ -z "${IMAGE_REF:-}" ]; then
    echo "ERROR: IMAGE_REF is required (set to the PREVIOUS image reference)"
    echo "Usage: IMAGE_REF=ghcr.io/<owner>/orzmusic:<previous-version> $0"
    exit 1
fi

echo "=== Release Rollback ==="
echo "Target (previous image): $IMAGE_REF"
echo "Started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

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
echo "[1/5] Running preflight checks..."
if ! ./script/release-preflight.sh; then
    log_release "rollback-preflight" "FAILED"
    echo "ERROR: Preflight checks failed. Aborting."
    exit 1
fi
log_release "rollback-preflight" "OK"
echo ""

# ---- 2. 拉取上一版本镜像 ----
echo "[2/5] Pulling previous image: $IMAGE_REF..."
if ! $COMPOSE $COMPOSE_BASE pull app; then
    log_release "rollback-pull" "FAILED" "image=$IMAGE_REF"
    echo "ERROR: Failed to pull image $IMAGE_REF"
    exit 1
fi
log_release "rollback-pull" "OK" "image=$IMAGE_REF"
echo ""

# ---- 3. 停止当前服务 ----
echo "[3/5] Stopping app service..."
if ! $COMPOSE $COMPOSE_BASE stop app; then
    log_release "rollback-stop" "FAILED"
    echo "ERROR: Failed to stop services."
    exit 1
fi
log_release "rollback-stop" "OK"
echo ""

# ---- 4. 启动上一版本应用 ----
# 通过设置 IMAGE_REF 为上一版本镜像，重新创建 app 服务
# 注意：不执行数据库回退，仅启动上一版本代码
echo "[4/5] Starting previous version..."
if ! IMAGE_REF="$IMAGE_REF" $COMPOSE $COMPOSE_BASE up -d app; then
    log_release "rollback-start" "FAILED"
    echo "ERROR: Failed to start previous version."
    exit 1
fi
log_release "rollback-start" "OK" "rolled back to $IMAGE_REF"
echo ""

# ---- 5. 验证 ----
echo "[5/5] Waiting for app readiness..."
for i in $(seq 1 12); do
    if curl -fsS "http://localhost:8080/api/health" >/dev/null 2>&1; then
        echo "  App is ready."
        break
    fi
    if [ "$i" -eq 12 ]; then
        echo "WARNING: App did not become ready within 60 seconds."
        echo "  Check logs: $COMPOSE $COMPOSE_BASE logs --tail=50 app"
        log_release "rollback-health" "WARNING"
    fi
    sleep 5
done

echo ""
echo "=== Rollback Complete ==="
echo "Target: $IMAGE_REF"
echo "Finished: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""
echo "Notes:"
echo "  - Database was NOT reverted. This rollback only restores the app code."
echo "  - If the rollback is due to incompatible migration, restore DB first:"
echo "    pg_restore -d vapor_database <backup-file>"
echo "  - Release log: $RELEASE_LOG"
