#!/bin/bash
# =============================================================================
# CPA-Manager-Plus 启动包装脚本
# 当启用 CPA GitStore 时，必须等待 CPA 先完成 /data/gitstore 初始化，
# 避免 CPAMP 率先创建 SQLite 文件导致 CPA clone 工作树发生竞态。
#
# 环境变量：
#   CPAMP_DB_MAX_MB             数据库大小上限（MB），超限自动清理，默认 5
#   CPAMP_DB_CLEAN_TABLES       清理模式：USAGE（默认，仅清用量）/ FULL（全删）/ 逗号分隔表列表
#   CPAMP_DB_KEEP_HOURS         保留最近 N 小时的用量事件（默认 72，仅清理含 usage 表时生效）
#   CPAMP_DB_CLEAN_ON_START     设为 true 则每次启动强制清理（映射到 USAGE 模式）
#   CPAMP_DB_BACKUP_ENABLED     是否备份数据库到 Git，默认 true；设 false 关闭备份
# =============================================================================
set -e

# 数据库大小上限（默认 5MB）
CPAMP_DB_MAX_MB=${CPAMP_DB_MAX_MB:-5}
if ! [ "$CPAMP_DB_MAX_MB" -gt 0 ] 2>/dev/null; then
    echo "[start-cpamp] ⚠ CPAMP_DB_MAX_MB 必须是正整数，使用默认 5"
    CPAMP_DB_MAX_MB=5
fi
CPAMP_DB_MAX_KB=$((CPAMP_DB_MAX_MB * 1024))

# =============================================================================
# 辅助函数
# =============================================================================

gitstore_ready() {
    [ -d /data/gitstore/.git ] || return 1
    git -C /data/gitstore rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    git -C /data/gitstore rev-parse --verify HEAD >/dev/null 2>&1 || return 1
}

# --- Git 认证辅助 ---
_setup_git_askpass() {
    if [ -n "${GIT_TOKEN:-}" ]; then
        cat > /tmp/git-askpass-cpamp.sh <<'ASKPASS'
#!/bin/sh
case "$1" in
    *Username*) printf '%s\n' "${GIT_USERNAME:-git}" ;;
    *Password*) printf '%s\n' "${GIT_TOKEN:-}" ;;
    *) printf '\n' ;;
esac
ASKPASS
        chmod 700 /tmp/git-askpass-cpamp.sh
        export GIT_ASKPASS=/tmp/git-askpass-cpamp.sh
        export GIT_TERMINAL_PROMPT=0
    fi
}

_cleanup_git_askpass() {
    rm -f /tmp/git-askpass-cpamp.sh 2>/dev/null || true
}

# --- 精准清理：只删用量表，保留配置/认证状态 ---
_clean_usage_tables() {
    local keep="$1"
    if [ ! -f /data/gitstore/usage.sqlite ]; then
        echo "[start-cpamp]   usage.sqlite 不存在，跳过清理"
        return 0
    fi

    local now_ms cutoff_ms
    now_ms=$(date +%s%3N)

    if [ "$keep" -gt 0 ]; then
        cutoff_ms=$(( now_ms - keep * 3600 * 1000 ))
        echo "[start-cpamp]   KEEP_HOURS=${keep}，保留 timestamp_ms >= ${keep} 小时内的事件"
    fi

    echo "[start-cpamp]   DELETE FROM usage_events..."
    if [ "$keep" -gt 0 ]; then
        sqlite3 /data/gitstore/usage.sqlite "DELETE FROM usage_events WHERE timestamp_ms < ${cutoff_ms};"
    else
        sqlite3 /data/gitstore/usage.sqlite "DELETE FROM usage_events;"
    fi

    echo "[start-cpamp]   DELETE FROM usage_cache_accounting_v2_changes..."
    sqlite3 /data/gitstore/usage.sqlite "DELETE FROM usage_cache_accounting_v2_changes;"

    echo "[start-cpamp]   DELETE FROM dead_letter_events..."
    if [ "$keep" -gt 0 ]; then
        sqlite3 /data/gitstore/usage.sqlite "DELETE FROM dead_letter_events WHERE created_at_ms < ${cutoff_ms};"
    else
        sqlite3 /data/gitstore/usage.sqlite "DELETE FROM dead_letter_events;"
    fi

    echo "[start-cpamp]   DELETE FROM usage_dashboard_hourly_rollups..."
    if [ "$keep" -gt 0 ]; then
        sqlite3 /data/gitstore/usage.sqlite "DELETE FROM usage_dashboard_hourly_rollups WHERE bucket_ms < ${cutoff_ms};"
    else
        sqlite3 /data/gitstore/usage.sqlite "DELETE FROM usage_dashboard_hourly_rollups;"
    fi

    echo "[start-cpamp]   DELETE FROM usage_account_model_rollups..."
    if [ "$keep" -gt 0 ]; then
        sqlite3 /data/gitstore/usage.sqlite "DELETE FROM usage_account_model_rollups WHERE last_seen_ms < ${cutoff_ms};"
    else
        sqlite3 /data/gitstore/usage.sqlite "DELETE FROM usage_account_model_rollups;"
    fi

    echo "[start-cpamp]   DELETE FROM usage_rollup_checkpoints..."
    sqlite3 /data/gitstore/usage.sqlite "DELETE FROM usage_rollup_checkpoints;"

    echo "[start-cpamp]   VACUUM..."
    sqlite3 /data/gitstore/usage.sqlite "VACUUM;"

    # 删除旧快照（同步时会重建）
    rm -f /data/gitstore/usage.snapshot.sqlite
    rm -f /data/gitstore/usage.sqlite-wal /data/gitstore/usage.sqlite-shm

    echo "[start-cpamp]   ✓ 精准清理完成（保留 settings / model_prices / api_key_aliases 等配置/状态表）"
}

# --- 自定义表列表清理 ---
_clean_custom_tables() {
    local tables="$1" keep="$2"
    if [ ! -f /data/gitstore/usage.sqlite ]; then
        echo "[start-cpamp]   usage.sqlite 不存在，跳过清理"
        return 0
    fi

    local now_ms cutoff_ms
    now_ms=$(date +%s%3N)
    [ "$keep" -gt 0 ] && cutoff_ms=$(( now_ms - keep * 3600 * 1000 ))

    local IFS=','
    for tbl in $tables; do
        tbl="${tbl#"${tbl%%[![:space:]]*}"}"
        tbl="${tbl%"${tbl##*[![:space:]]}"}"
        [ -z "$tbl" ] && continue

        echo "[start-cpamp]   DELETE FROM ${tbl}..."
        case "$tbl" in
            usage_events)
                if [ "$keep" -gt 0 ]; then
                    sqlite3 /data/gitstore/usage.sqlite "DELETE FROM usage_events WHERE timestamp_ms < ${cutoff_ms};"
                else
                    sqlite3 /data/gitstore/usage.sqlite "DELETE FROM usage_events;"
                fi
                ;;
            usage_dashboard_hourly_rollups)
                if [ "$keep" -gt 0 ]; then
                    sqlite3 /data/gitstore/usage.sqlite "DELETE FROM usage_dashboard_hourly_rollups WHERE bucket_ms < ${cutoff_ms};"
                else
                    sqlite3 /data/gitstore/usage.sqlite "DELETE FROM usage_dashboard_hourly_rollups;"
                fi
                ;;
            usage_account_model_rollups)
                if [ "$keep" -gt 0 ]; then
                    sqlite3 /data/gitstore/usage.sqlite "DELETE FROM usage_account_model_rollups WHERE last_seen_ms < ${cutoff_ms};"
                else
                    sqlite3 /data/gitstore/usage.sqlite "DELETE FROM usage_account_model_rollups;"
                fi
                ;;
            dead_letter_events)
                if [ "$keep" -gt 0 ]; then
                    sqlite3 /data/gitstore/usage.sqlite "DELETE FROM dead_letter_events WHERE created_at_ms < ${cutoff_ms};"
                else
                    sqlite3 /data/gitstore/usage.sqlite "DELETE FROM dead_letter_events;"
                fi
                ;;
            *)
                sqlite3 /data/gitstore/usage.sqlite "DELETE FROM ${tbl};"
                ;;
        esac
    done

    echo "[start-cpamp]   VACUUM..."
    sqlite3 /data/gitstore/usage.sqlite "VACUUM;"
    rm -f /data/gitstore/usage.snapshot.sqlite
    rm -f /data/gitstore/usage.sqlite-wal /data/gitstore/usage.sqlite-shm
    echo "[start-cpamp]   ✓ 自定义表清理完成"
}

# --- Git untrack：全部数据库文件 ---
_git_untrack_db_files() {
    cd /data/gitstore
    git config user.name "CPA-Manager-Plus" 2>/dev/null || true
    git config user.email "cpamp@local" 2>/dev/null || true

    _setup_git_askpass
    for gf in usage.snapshot.sqlite usage.sqlite data.key; do
        git rm --cached --ignore-unmatch "$gf" 2>/dev/null || true
    done
    if git diff --cached --quiet 2>/dev/null; then
        echo "[start-cpamp]   git 中无可清理的数据库文件"
    else
        git commit -m "chore: cleanup database files from tracking" 2>/dev/null || true
        _maybe_git_push
    fi
    _cleanup_git_askpass
}

# --- Git untrack：仅快照文件 ---
_git_untrack_snapshot() {
    cd /data/gitstore
    git config user.name "CPA-Manager-Plus" 2>/dev/null || true
    git config user.email "cpamp@local" 2>/dev/null || true

    _setup_git_askpass
    git rm --cached --ignore-unmatch usage.snapshot.sqlite 2>/dev/null || true
    if git diff --cached --quiet 2>/dev/null; then
        echo "[start-cpamp]   git 中无可清理的数据库文件"
    else
        git commit -m "chore: cleanup stale usage snapshot" 2>/dev/null || true
        _maybe_git_push
    fi
    _cleanup_git_askpass
}

_maybe_git_push() {
    local branch="${DATA_BRANCH:-main}"
    _setup_git_askpass
    if git push origin "HEAD:refs/heads/${branch}" 2>&1; then
        echo "[start-cpamp]   ✓ git 推送成功"
    else
        echo "[start-cpamp]   ! git 推送失败（下次启动会重试）"
    fi
    _cleanup_git_askpass
}

# =============================================================================
# 主流程
# =============================================================================

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
        rm -f /data/gitstore/usage.sqlite-wal /data/gitstore/usage.sqlite-shm
        echo "[start-cpamp] ✓ 从 usage.snapshot.sqlite 恢复 usage.sqlite（已清理 WAL/SHM）"

        # 检查是否需要清理数据
        need_cleanup=false

        # 条件1: CPAMP_DB_CLEAN_ON_START=true → 强制清理（映射到 USAGE 模式）
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
                        echo "[start-cpamp] ⚠ $f 大小 ${size_kb}KB 超过 ${CPAMP_DB_MAX_MB}MB 限制"
                        need_cleanup=true
                        break
                    fi
                fi
            done
        fi

        # 执行清理
        if [ "$need_cleanup" = true ]; then
            clean_mode="${CPAMP_DB_CLEAN_TABLES:-USAGE}"
            keep_hours="${CPAMP_DB_KEEP_HOURS:-72}"
            if ! [ "$keep_hours" -ge 0 ] 2>/dev/null; then
                keep_hours=72
            fi

            case "${clean_mode^^}" in
                FULL)
                    echo "[start-cpamp] ⚠ FULL 模式：删除全部数据库及密钥文件，从零初始化"
                    rm -f /data/gitstore/usage.sqlite /data/gitstore/usage.snapshot.sqlite
                    rm -f /data/gitstore/usage.sqlite-wal /data/gitstore/usage.sqlite-shm
                    rm -f /data/gitstore/data.key
                    _git_untrack_db_files
                    ;;
                USAGE)
                    echo "[start-cpamp] ⚠ USAGE 模式：精准清理用量数据（保留配置和认证状态，KEEP_HOURS=${keep_hours}）"
                    _clean_usage_tables "$keep_hours"
                    _git_untrack_snapshot
                    ;;
                *)
                    echo "[start-cpamp] ⚠ 自定义表列表：${clean_mode}（KEEP_HOURS=${keep_hours}）"
                    _clean_custom_tables "$clean_mode" "$keep_hours"
                    _git_untrack_snapshot
                    ;;
            esac
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
