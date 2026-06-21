#!/bin/bash
# =============================================================================
# 数据同步守护脚本（CPAMP SQLite 安全版）
# CPA 内置的 GitTokenStore 负责 auths/* 和 config/config.yaml
# 本脚本只处理 CPAMP SQLite 数据：usage.sqlite + WAL/SHM 安全 checkpoint
# =============================================================================
set -e

DATA_REPO="${DATA_REPO:-}"
DATA_BRANCH="${DATA_BRANCH:-main}"
SYNC_INTERVAL="${SYNC_INTERVAL:-120}"   # 2 分钟：Render 免费版休眠窗口较短，检查要更勤
IDLE_TIMEOUT="${IDLE_TIMEOUT:-480}"     # 8 分钟：在 10 分钟休眠前提前同步

# 如果没配数据仓库，静默循环（supervisord 不会反复重启）
if [ -z "$DATA_REPO" ]; then
    while true; do sleep 30; done
fi

# CPAMP 数据目录（与 CPA GitStore 工作树一致）
DATA_DIR="/data/gitstore"

echo "[sync-data] 等待 CPA GitStore 初始化 ${DATA_DIR}/.git ..."
for i in $(seq 1 120); do
    if [ -d "${DATA_DIR}/.git" ]; then
        break
    fi
    if [ "$i" -eq 120 ]; then
        echo "[sync-data] 等待 GitStore 超时，退出以便 supervisord 重启"
        exit 1
    fi
    sleep 1
done

cd "$DATA_DIR"

# 避免 git 因 owner 不同报 dubious ownership
git config --global --add safe.directory "$DATA_DIR" 2>/dev/null || true

# SQLite 文件集合
SQLITE_FILES=("usage.sqlite" "usage.sqlite-wal" "usage.sqlite-shm" "data.key")

sqlite_checkpoint() {
    # 如果 sqlite3 不存在或数据库还没创建，跳过
    if ! command -v sqlite3 >/dev/null 2>&1; then
        return 0
    fi
    if [ ! -f "usage.sqlite" ]; then
        return 0
    fi

    # PASSIVE 不阻塞写入；能合并多少合并多少。
    # 返回三列：busy log checkpointed。busy=0 表示全部合并。
    local out=""
    out=$(sqlite3 "usage.sqlite" "PRAGMA wal_checkpoint(PASSIVE);" 2>/dev/null || true)
    if [ -n "$out" ]; then
        echo "[sync-data] SQLite checkpoint(PASSIVE): $out"
    fi
}

changed_cpamp_files() {
    git status --porcelain -- "${SQLITE_FILES[@]}" 2>/dev/null || true
}

stage_existing_cpamp_files() {
    # 只 add 存在的文件；不存在的 WAL/SHM 不报错
    for f in "${SQLITE_FILES[@]}"; do
        if [ -e "$f" ]; then
            git add "$f" 2>/dev/null || true
        else
            # 如果文件之前被跟踪但现在因 checkpoint 消失，也需要记录删除
            git add -u "$f" 2>/dev/null || true
        fi
    done
}

sync_once() {
    local reason="$1"

    sqlite_checkpoint

    local changed=""
    changed=$(changed_cpamp_files)
    if [ -z "$changed" ]; then
        echo "[sync-data] 无 CPAMP 文件变更，跳过同步 ($reason)"
        return 0
    fi

    echo "[sync-data] $(date '+%Y-%m-%d %H:%M:%S') CPAMP 文件变更，准备同步 ($reason):"
    echo "$changed"

    stage_existing_cpamp_files

    local staged=""
    staged=$(git diff --cached --name-only -- "${SQLITE_FILES[@]}" 2>/dev/null || true)
    if [ -z "$staged" ]; then
        echo "[sync-data] 无 staged 变更，跳过"
        return 0
    fi

    git commit -m "CPAMP data sync (${reason}) $(date -u '+%Y-%m-%dT%H:%M:%SZ')" 2>/dev/null || true

    if git push origin "$DATA_BRANCH" 2>&1; then
        echo "[sync-data] ✓ 推送成功 ($reason)"
    else
        echo "[sync-data] ✗ 推送失败，将在下次重试 ($reason)"
        return 1
    fi
}

# =============================================================================
# 信号处理：收到 SIGTERM/SIGINT 时做最后一次同步再退出
# =============================================================================
do_final_sync() {
    echo "[sync-data] $(date '+%Y-%m-%d %H:%M:%S') 收到关闭信号，执行最终同步..."
    cd "$DATA_DIR" 2>/dev/null || exit 0
    sync_once "final" || true
    exit 0
}
trap 'do_final_sync' SIGTERM SIGINT

echo "[sync-data] $(date '+%Y-%m-%d %H:%M:%S') 数据同步守护启动"
echo "  仓库: ${DATA_REPO}"
echo "  分支: ${DATA_BRANCH}"
echo "  监控目录: ${DATA_DIR}"
echo "  SQLite: usage.sqlite (+ -wal/-shm 安全处理)"
echo "  (CPA 的 auths/ 和 config/ 由 CPA GitTokenStore 自动管理)"

while true; do
    sleep "$SYNC_INTERVAL"

    changed=$(changed_cpamp_files)
    if [ -n "$changed" ]; then
        sync_once "periodic" || true
        continue
    fi

    # ----------------------------------------------------------
    # 空闲预判：usage.sqlite 长时间未变更 → Render 可能即将休眠
    # ----------------------------------------------------------
    if [ -f "usage.sqlite" ]; then
        LAST_MOD=$(stat -c %Y "usage.sqlite" 2>/dev/null || stat -f %m "usage.sqlite" 2>/dev/null)
        NOW=$(date +%s)
        AGE=$((NOW - LAST_MOD))

        if [ "$AGE" -gt "$IDLE_TIMEOUT" ]; then
            echo "[sync-data] $(date '+%Y-%m-%d %H:%M:%S') usage.sqlite 空闲 ${AGE}s > 阈值 ${IDLE_TIMEOUT}s"
            sync_once "idle" || true
        fi
    fi
done