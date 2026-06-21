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
            echo "[start-cpamp] GitStore 已就绪，启动 CPA-Manager-Plus"
            break
        fi
        if [ "$i" -eq 120 ]; then
            echo "[start-cpamp] 等待 GitStore 超时：仓库没有有效 HEAD，通常是 DATA_REPO/GIT_TOKEN/GIT_USERNAME 认证失败"
            exit 1
        fi
        sleep 1
    done
else
    echo "[start-cpamp] DATA_REPO 未设置，直接启动 CPA-Manager-Plus"
fi

exec /usr/local/bin/cpa-manager-plus
