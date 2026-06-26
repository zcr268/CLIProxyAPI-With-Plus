#!/bin/bash
# =============================================================================
# CPA-Manager-Plus 启动包装脚本
# 当启用 CPA GitStore 时，必须等待 CPA 先完成 /data/gitstore 初始化，
# 避免 CPAMP 率先创建 SQLite 文件导致 CPA clone 工作树发生竞态。
#
# 环境变量：
#   CPAMP_DB_MAX_MB             数据库大小上限（MB），超限自动清理，默认 5
#   CPAMP_DB_CLEAN_ON_START     设为 true 则每次启动强制清理数据库
#   CPAMP_DB_BACKUP_ENABLED     是否备份数据库到 Git，默认 true；设 false 关闭备份
# =============================================================================
set -e

# 数据库大小上限（默认 5MB）
CPAMP_DB_MAX_MB=${CPAMP_DB_MAX_MB:-5}
# 检查是否是有效数字
if ! [ "$CPAMP_DB_MAX_MB" -gt 0 ] 2>/dev/null; then
    echo "[start-cpamp] ⚠ CPAMP_DB_MAX_MB 必须是正整数，使用默认 5"
    CPAMP_DB_MAX_MB=5
fi
CPAMP_DB_MAX_KB=$((CPAMP_DB_MAX_MB * 1024))

gitstore_ready() {
    [ -d /data/gitstore/.git ] || return 1
    git -C /data/gitstore rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    git -C /data/gitstore rev-parse --verify HEAD >/dev/null 2>&1 || return 1
}

if [ -n "${DATA_REPO:-}" ]; then
    echo "[start-cpamp] DATA_REPO 已设置，等待 CPA GitStore 完成有效初始化 /data/gitstore ..."
    for i in $(seq 1 120); do
        if gitstore_ready; then
            echo "[start-cpamp] GitStore 已就绪"
            break
        fi
        if [ "$i" -eq 120 ]; then
            echo "[start-cpamp] 等待 GitStore 超时：仓库没有有效 HEAD，通常是 DATA_REPO/GIT_TOKEN/GIT_USERNAME 认证失败"
            exit 1
        fi
        sleep 1
    done

    # 从同步快照恢复 live 数据库
    if [ -f /data/gitstore/usage.snapshot.sqlite ]; then
        cp /data/gitstore/usage.snapshot.sqlite /data/gitstore/usage.sqlite
        # 清理快照恢复后可能残留的 WAL/SHM 文件（不同 SQLite 实现可能产生不兼容的 WAL）
        rm -f /data/gitstore/usage.sqlite-wal /data/gitstore/usage.sqlite-shm
        echo "[start-cpamp] ✓ 从 usage.snapshot.sqlite 恢复 usage.sqlite（已清理 WAL/SHM）"

        # 检查是否需要清理数据
        need_cleanup=false

        # 条件1: 环境变量 CPAMP_DB_CLEAN_ON_START=true → 每次启动强制清理
        if [ "${CPAMP_DB_CLEAN_ON_START:-}" = "true" ]; then
            echo "[start-cpamp] ⚠ CPAMP_DB_CLEAN_ON_START=true，强制清理数据库"
            need_cleanup=true
        fi

        # 条件2: data.key 丢失 → 密钥未被持久化，现有数据无法解密
        if [ "$need_cleanup" = false ] && [ ! -f /data/gitstore/data.key ]; then
            echo "[start-cpamp] ⚠ data.key 不存在 — 密钥丢失，清理数据从零初始化"
            need_cleanup=true
        fi

        # 条件3: 数据库文件超过 CPAMP_DB_MAX_MB
        if [ "$need_cleanup" = false ]; then
            for f in usage.sqlite usage.snapshot.sqlite; do
                if [ -f "/data/gitstore/$f" ]; then
                    size_kb=$(du -k "/data/gitstore/$f" | cut -f1)
                    if [ "$size_kb" -gt "$CPAMP_DB_MAX_KB" ]; then
                        echo "[start-cpamp] ⚠ $f 大小 ${size_kb}KB 超过 ${CPAMP_DB_MAX_MB}MB 限制，清理数据从零初始化"
                        need_cleanup=true
                        break
                    fi
                fi
            done
        fi

        if [ "$need_cleanup" = true ]; then
            rm -f /data/gitstore/usage.sqlite /data/gitstore/usage.snapshot.sqlite
            rm -f /data/gitstore/usage.sqlite-wal /data/gitstore/usage.sqlite-shm
            rm -f /data/gitstore/data.key
        fi
    else
        echo "[start-cpamp] usage.snapshot.sqlite 不存在，使用已有 usage.sqlite（如有）"
    fi
else
    echo "[start-cpamp] DATA_REPO 未设置，直接启动 CPA-Manager-Plus"
fi

# CPAMP 启动包装：如果启动失败（如密钥不匹配），自动清理数据重试一次
if ! /usr/local/bin/cpa-manager-plus; then
    echo "[start-cpamp] ⚠ CPAMP 启动失败，清理数据重新初始化..."
    rm -f /data/gitstore/usage.sqlite /data/gitstore/usage.snapshot.sqlite /data/gitstore/data.key
    rm -f /data/gitstore/usage.sqlite-wal /data/gitstore/usage.sqlite-shm
    echo "[start-cpamp] 第二次尝试启动 CPAMP..."
    exec /usr/local/bin/cpa-manager-plus
fi