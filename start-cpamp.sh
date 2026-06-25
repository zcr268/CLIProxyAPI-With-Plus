#!/bin/bash
# =============================================================================
# CPA-Manager-Plus 启动包装脚本
# 当启用 CPA GitStore 时，必须等待 CPA 先完成 /data/gitstore 初始化，
# 避免 CPAMP 率先创建 SQLite 文件导致 CPA clone 工作树发生竞态。
# =============================================================================
set -e

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

        # 检测 data.key 丢失：有 snapshot 但没有 data.key → 密钥未被持久化（已知 bug）
        # 此时 CPAMP 会生成新 key 但现有数据用旧 key 加密无法解密
        # → 主动清理，让 CPAMP 从零初始化
        if [ ! -f /data/gitstore/data.key ]; then
            echo "[start-cpamp] ⚠ data.key 不存在 — 密钥丢失，清理数据从零初始化"
            rm -f /data/gitstore/usage.sqlite /data/gitstore/usage.snapshot.sqlite
            rm -f /data/gitstore/usage.sqlite-wal /data/gitstore/usage.sqlite-shm
        fi
    else
        echo "[start-cpamp] usage.snapshot.sqlite 不存在，使用已有 usage.sqlite（如有）"
    fi
else
    echo "[start-cpamp] DATA_REPO 未设置，直接启动 CPA-Manager-Plus"
fi

exec /usr/local/bin/cpa-manager-plus
