#!/bin/bash
# =============================================================================
# Nginx 启动等待脚本
# 在 CPA 和 CPAMP 上游服务 TCP 就绪前每秒轮询，
# 避免 supervisor 并行启动时 nginx 先监听端口导致 502
# =============================================================================
set -e

CPA_HOST="${CPA_HOST:-127.0.0.1}"
CPA_PORT="${CPA_PORT:-8317}"
CPAMP_HOST="${CPAMP_HOST:-127.0.0.1}"
CPAMP_PORT="${CPAMP_PORT:-18317}"
MAX_RETRIES=120  # 最多等 2 分钟

echo "[start-nginx] 等待上游服务就绪..."

# ------------------------------------------------------------------
# 等待 CPA（CLIProxyAPI）
# ------------------------------------------------------------------
echo "[start-nginx] 等待 CPA (${CPA_HOST}:${CPA_PORT})..."
for i in $(seq 1 $MAX_RETRIES); do
    if timeout 2 bash -c "echo > /dev/tcp/${CPA_HOST}/${CPA_PORT}" 2>/dev/null; then
        echo "[start-nginx] CPA 已就绪（等待 ${i} 秒）"
        break
    fi
    if [ "$i" -eq "$MAX_RETRIES" ]; then
        echo "[start-nginx] 错误：CPA 启动超时（${MAX_RETRIES} 秒）" >&2
        exit 1
    fi
    sleep 1
done

# ------------------------------------------------------------------
# 等待 CPAMP（CPA-Manager-Plus）
# ------------------------------------------------------------------
echo "[start-nginx] 等待 CPAMP (${CPAMP_HOST}:${CPAMP_PORT})..."
for i in $(seq 1 $MAX_RETRIES); do
    if timeout 2 bash -c "echo > /dev/tcp/${CPAMP_HOST}/${CPAMP_PORT}" 2>/dev/null; then
        echo "[start-nginx] CPAMP 已就绪（等待 ${i} 秒）"
        break
    fi
    if [ "$i" -eq "$MAX_RETRIES" ]; then
        echo "[start-nginx] 错误：CPAMP 启动超时（${MAX_RETRIES} 秒）" >&2
        exit 1
    fi
    sleep 1
done

echo "[start-nginx] 所有上游服务已就绪，启动 Nginx..."
exec /usr/sbin/nginx -g "daemon off;"
