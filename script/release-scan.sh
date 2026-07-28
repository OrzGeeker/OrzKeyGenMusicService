#!/bin/bash
# release-scan — 触发已运行主服务的配置音频扫描
#
# 用法:
#   ADMIN_API_TOKEN=... ./script/release-scan.sh
#
# 环境变量:
#   ADMIN_API_TOKEN 管理 API Bearer token（必填）
#   SCAN_URL        主服务地址（默认 http://127.0.0.1:8080）

set -euo pipefail

SCAN_URL="${SCAN_URL:-http://127.0.0.1:8080}"

if [ -z "${ADMIN_API_TOKEN:-}" ]; then
    echo "ERROR: ADMIN_API_TOKEN is required"
    echo "Usage: ADMIN_API_TOKEN=<token> $0"
    exit 1
fi

echo "=== Release Scan ==="
echo "Service URL: $SCAN_URL"
echo ""

echo "Triggering configured scan root..."
curl -fsS -X POST "$SCAN_URL/api/scan" \
    -H "Authorization: Bearer $ADMIN_API_TOKEN"

echo ""
echo "=== Scan Complete ==="
