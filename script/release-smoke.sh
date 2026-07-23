#!/bin/bash
# release-smoke — 发布冒烟检查
#
# 升级后自动验收：健康接口、版本、首页、格式统计、搜索。
# 播放链路保留人工抽测，首期不自动播放音频。
#
# 用法:
#   ./script/release-smoke.sh
#   SERVICE_URL=http://localhost:8080 EXPECTED_VERSION=0.0.1 ./script/release-smoke.sh
#
# 环境变量:
#   SERVICE_URL       服务地址（默认 http://localhost:8080）
#   EXPECTED_VERSION  期望版本（可选，不设置则只检查存在性）
#   SMOKE_TIMEOUT     每个请求超时秒数（默认 10）

set -uo pipefail

SERVICE_URL="${SERVICE_URL:-http://localhost:8080}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-10}"
CURL="curl -fsS --max-time $SMOKE_TIMEOUT"
PASS=true

red()    { printf '\033[31m%s\033[0m\n' "$1"; }
green()  { printf '\033[32m%s\033[0m\n' "$1"; }

echo "=== Release Smoke Check ==="
echo "Target: $SERVICE_URL"
if [ -n "${EXPECTED_VERSION:-}" ]; then
    echo "Expected version: $EXPECTED_VERSION"
fi
echo ""

# ---- 1. 健康接口 ----
echo "--- 1. Health Check ---"
HEALTH=$($CURL "$SERVICE_URL/api/health" 2>&1) || {
    red "FAIL: Cannot reach /api/health"
    PASS=false
}
if [ "$PASS" = true ]; then
    STATUS=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "")
    VERSION=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])" 2>/dev/null || echo "")
    DB=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin)['database'])" 2>/dev/null || echo "")
    CAS=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin)['cas'])" 2>/dev/null || echo "")

    if [ "$STATUS" = "ready" ]; then
        green "  [PASS] status=ready"
    else
        red "  [FAIL] status=$STATUS (expected 'ready')"
        PASS=false
    fi

    if [ -n "$VERSION" ]; then
        green "  [PASS] version=$VERSION"
    else
        red "  [FAIL] version is empty"
        PASS=false
    fi

    if [ -n "${EXPECTED_VERSION:-}" ] && [ "$VERSION" != "$EXPECTED_VERSION" ]; then
        red "  [FAIL] version mismatch: expected $EXPECTED_VERSION, got $VERSION"
        PASS=false
    fi

    if [ "$DB" = "healthy" ]; then
        green "  [PASS] database=healthy"
    else
        red "  [FAIL] database=$DB"
        PASS=false
    fi

    if [ "$CAS" = "healthy" ]; then
        green "  [PASS] cas=healthy"
    else
        red "  [FAIL] cas=$CAS"
        PASS=false
    fi
fi
echo ""

# ---- 2. 首页 ----
echo "--- 2. Frontend Page ---"
PAGE=$($CURL "$SERVICE_URL/" 2>&1) || {
    red "FAIL: Cannot reach frontend page"
    PASS=false
}
if [ "$PASS" = true ]; then
    if echo "$PAGE" | grep -qi "OrzMusic"; then
        green "  [PASS] Page contains OrzMusic"
    else
        red "  [FAIL] Page does not contain 'OrzMusic'"
        PASS=false
    fi
fi
echo ""

# ---- 3. 格式统计 ----
echo "--- 3. Format Summary ---"
FORMATS=$($CURL "$SERVICE_URL/api/songs/formats" 2>&1) || {
    red "FAIL: Cannot reach /api/songs/formats"
    PASS=false
}
if [ "$PASS" = true ]; then
    TOTAL=$(echo "$FORMATS" | python3 -c "import sys,json; print(json.load(sys.stdin)['total'])" 2>/dev/null || echo "")
    # total >= 0 means the endpoint works
    if [ "$TOTAL" -ge 0 ] 2>/dev/null; then
        green "  [PASS] formats total=$TOTAL"
    else
        red "  [FAIL] could not parse format total"
        PASS=false
    fi
fi
echo ""

# ---- 4. 搜索接口 ----
echo "--- 4. Search API ---"
SEARCH=$($CURL "$SERVICE_URL/api/songs/search?q=test" 2>&1) || {
    red "FAIL: Cannot reach /api/songs/search"
    PASS=false
}
if [ "$PASS" = true ]; then
    # 搜索应该返回一个 JSON 数组（可能为空）
    if echo "$SEARCH" | python3 -c "import sys,json; data=json.load(sys.stdin); assert isinstance(data, list)" 2>/dev/null; then
        COUNT=$(echo "$SEARCH" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
        green "  [PASS] search returned $COUNT results"
    else
        red "  [FAIL] search did not return a JSON array"
        PASS=false
    fi
fi
echo ""

# ---- 汇总 ----
echo "=== Result ==="
if [ "$PASS" = true ]; then
    green "SMOKE CHECK PASSED"
    exit 0
else
    red "SMOKE CHECK FAILED"
    echo ""
    echo "Manual playback verification checklist (not automated):"
    echo "  - Play a directFile format (mp3) — should play immediately"
    echo "  - Play a wasmDecode format (xm/mod/sid) — should load WASM and play"
    echo "  - Play a serverDecode format (sc68/wav) — should transcode and play"
    echo "  - Test seek, pause, volume, next/prev"
    exit 1
fi
