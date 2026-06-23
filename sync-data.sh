#!/bin/bash
# =============================================================================
# 数据同步守护脚本（CPAMP SQLite 安全版）
# CPA 内置的 GitTokenStore 负责 auths/* 和 config/config.yaml
# 本脚本只处理 CPAMP SQLite 数据：usage.sqlite .backup 一致快照 + integrity 校验
# =============================================================================
set -e

DATA_REPO="${DATA_REPO:-}"
DATA_BRANCH="${DATA_BRANCH:-main}"
SYNC_INTERVAL="${SYNC_INTERVAL:-60}"    # 1 分钟：缩短同步窗口，设置变更后更快落盘
IDLE_TIMEOUT="${IDLE_TIMEOUT:-480}"     # 8 分钟：在 10 分钟休眠前提前同步

# 强制 GitStore：未配置数据仓库时直接失败，不做本地兜底。
if [ -z "$DATA_REPO" ]; then
    echo "[sync-data] ERROR: DATA_REPO 未设置，无法同步 CPAMP 数据" >&2
    exit 1
fi
if [ -z "${GIT_TOKEN:-}" ]; then
    echo "[sync-data] ERROR: GIT_TOKEN 未设置，无法推送 CPAMP 数据" >&2
    exit 1
fi

# CPAMP 数据目录（与 CPA GitStore 工作树一致）
DATA_DIR="/data/gitstore"

gitstore_ready() {
    [ -d "${DATA_DIR}/.git" ] || return 1
    git -C "${DATA_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    git -C "${DATA_DIR}" rev-parse --verify HEAD >/dev/null 2>&1 || return 1
}

echo "[sync-data] 等待 CPA GitStore 完成有效初始化 ${DATA_DIR} ..."
for i in $(seq 1 120); do
    if gitstore_ready; then
        break
    fi
    if [ "$i" -eq 120 ]; then
        echo "[sync-data] 等待 GitStore 超时：仓库没有有效 HEAD，通常是 DATA_REPO/GIT_TOKEN/GIT_USERNAME 认证失败"
        exit 1
    fi
    sleep 1
done

cd "$DATA_DIR"

# 避免 git 因 owner 不同报 dubious ownership，并为 CPAMP 同步提交设置固定作者
git config --global --add safe.directory "$DATA_DIR" 2>/dev/null || true
git config user.name "CPA-Manager-Plus" 2>/dev/null || true
git config user.email "cpamp@local" 2>/dev/null || true

# 系统 git 不会自动读取 CPA 的 GITSTORE_* 认证信息；这里用 GIT_ASKPASS
# 把 DATA_REPO/GIT_USERNAME/GIT_TOKEN 传给 git push，避免交互式提示失败：
# fatal: could not read Username for 'https://...': No such device or address
if [ -n "${GIT_TOKEN:-}" ]; then
    GIT_ASKPASS_FILE="/tmp/git-askpass-cpamp.sh"
    cat > "$GIT_ASKPASS_FILE" <<'EOF'
#!/bin/sh
case "$1" in
    *Username*) printf '%s\n' "${GIT_USERNAME:-git}" ;;
    *Password*) printf '%s\n' "${GIT_TOKEN:-}" ;;
    *) printf '\n' ;;
esac
EOF
    chmod 700 "$GIT_ASKPASS_FILE"
    export GIT_ASKPASS="$GIT_ASKPASS_FILE"
    export GIT_TERMINAL_PROMPT=0
fi

# 迁移：不再跟踪 live usage.sqlite，改用 usage.snapshot.sqlite
if git ls-files --error-unmatch usage.sqlite >/dev/null 2>&1; then
    echo "[sync-data] 迁移: 将 usage.sqlite 从 git 跟踪中移除（改用 usage.snapshot.sqlite）..."
    git rm --cached usage.sqlite
    git commit -m "chore: stop tracking live usage.sqlite, use usage.snapshot.sqlite" 2>/dev/null || true
    if git push origin "HEAD:refs/heads/${DATA_BRANCH}" 2>&1; then
        echo "[sync-data] ✓ 迁移推送成功"
    else
        echo "[sync-data] ! 迁移推送失败（下次启动会重试）"
    fi
fi

# 同步到 git 的文件集合（快照 + 密钥 + 插件目录）
SQLITE_FILES=("usage.snapshot.sqlite" "data.key" "plugins/")

backup_and_verify() {
    # 如果 sqlite3 不存在或数据库还没创建，跳过
    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo "[sync-data] WARNING: sqlite3 不可用，跳过备份"
        return 1
    fi
    if [ ! -f "usage.sqlite" ]; then
        echo "[sync-data] usage.sqlite 不存在，跳过备份"
        return 1
    fi

    local snap=".usage.sqlite.snap.$$"
    echo "[sync-data] 创建 SQLite 一致快照..."
    if ! sqlite3 "usage.sqlite" ".backup ${snap}" 2>/dev/null; then
        echo "[sync-data] ERROR: SQLite .backup 失败"
        rm -f "$snap"
        return 1
    fi

    echo "[sync-data] 校验快照完整性..."
    if ! sqlite3 "$snap" "PRAGMA quick_check(1);" 2>/dev/null | grep -q "ok"; then
        echo "[sync-data] ERROR: 快照完整性校验失败（可能已损坏），放弃同步"
        rm -f "$snap"
        return 1
    fi

    # cp 替换同步用的副本（不碰 CPAMP 的 live usage.sqlite）
    cp "$snap" "usage.snapshot.sqlite"
    rm -f "$snap"
    echo "[sync-data] ✓ 快照已验证并写入 usage.snapshot.sqlite"
    return 0
}

changed_cpamp_files() {
    git status --porcelain -- "${SQLITE_FILES[@]}" 2>/dev/null || true
}

stage_existing_cpamp_files() {
    # 只 add 存在的文件（snapshot + data.key + plugins/）
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

    if ! backup_and_verify; then
        echo "[sync-data] 备份或校验失败，跳过本次同步"
        return 1
    fi

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

    if git push origin "HEAD:refs/heads/${DATA_BRANCH}" 2>&1; then
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
echo "  SQLite: live usage.sqlite → 快照 usage.snapshot.sqlite (一致快照 + integrity 校验)"
echo "  插件:   plugins/ (git 同步)"
echo "  (CPA 的 auths/ 和 config/ 由 CPA GitTokenStore 自动管理)"

# idle 同步节流：mtime 不会因为“检查过 idle”自动变化，
# 所以超过阈值后必须记录上次 idle 检查时间，避免每轮刷屏。
LAST_IDLE_CHECK_AT=0

while true; do
    sleep "$SYNC_INTERVAL"

    # 每轮都尝试同步，内部 .backup + quick_check + git diff 决定是否有变更需提交
    sync_once "periodic" || true

    # ----------------------------------------------------------
    # 空闲预判：live usage.sqlite 长时间未变更 → Render 可能即将休眠
    # ----------------------------------------------------------
    if [ -f "usage.sqlite" ]; then
        LAST_MOD=$(stat -c %Y "usage.sqlite" 2>/dev/null || stat -f %m "usage.sqlite" 2>/dev/null)
        NOW=$(date +%s)
        AGE=$((NOW - LAST_MOD))

        if [ "$AGE" -gt "$IDLE_TIMEOUT" ] && [ $((NOW - LAST_IDLE_CHECK_AT)) -ge "$IDLE_TIMEOUT" ]; then
            echo "[sync-data] $(date '+%Y-%m-%d %H:%M:%S') usage.sqlite 空闲 ${AGE}s > 阈值 ${IDLE_TIMEOUT}s，执行 idle 同步"
            sync_once "idle" || true
            LAST_IDLE_CHECK_AT="$NOW"
        fi
    fi
done
