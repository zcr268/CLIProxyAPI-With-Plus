#!/bin/bash
# =============================================================================
# CLIProxyAPI + CPA-Manager-Plus 一体化容器入口脚本
# 功能：配置生成 + CPA 内置 GitStore 持久化 + 服务启动
# =============================================================================
set -e

# ------------------------------------------------------------------
# 第1步：处理 Render 端口替换
# ------------------------------------------------------------------
NGINX_CONF="/etc/nginx/nginx.conf"
RENDER_PORT="${PORT:-10000}"
sed "s/{{PORT}}/${RENDER_PORT}/g" -i "$NGINX_CONF"
echo "[entrypoint] Nginx configured to listen on port ${RENDER_PORT}"

# ------------------------------------------------------------------
# 第2步：LOCAL_ONLY_MODE 分支（纯本地模式）
#        设为 true 时，跳过 GitStore 强制校验，所有数据落本地
#        /data/local/，CPA 与 CPAMP 都不会发起任何 git 操作。
# ------------------------------------------------------------------
LOCAL_ONLY_MODE="${LOCAL_ONLY_MODE:-false}"

if [ "${LOCAL_ONLY_MODE}" = "true" ]; then
    echo "[entrypoint] ============================================================"
    echo "[entrypoint]  LOCAL_ONLY_MODE=true — 本地数据模式已启用"
    echo "[entrypoint]  • 不校验 DATA_REPO / GIT_TOKEN"
    echo "[entrypoint]  • CPA GitTokenStore 被禁用（不 export GITSTORE_*）"
    echo "[entrypoint]  • CPAMP SQLite 备份被禁用（CPAMP_DB_BACKUP_ENABLED=false）"
    echo "[entrypoint]  • CPA auths/config 落 /data/，CPAMP SQLite 落 /data/local/"
    echo "[entrypoint]  • 注意：两个子目录不同（CPA file 根由 WORKDIR 决定）"
    echo "[entrypoint] ============================================================"

    # 准备本地数据目录
    mkdir -p /data/local
    # 关闭 CPAMP sync-data：让脚本一进入即 exit 0
    export CPAMP_DB_BACKUP_ENABLED=false
    # 显式标记 git 模式关闭，便于脚本/文档自洽
    export CPAMP_GIT_MODE=false
    # 从 supervisor 配置中移除 sync-data 程序段（与 GitStore 路径分支一致）
    sed -i '/^\[program:sync-data\]/,/^\[/ s/^/#/' /etc/supervisor/supervisord.conf

    # 跳过 GitStore 相关校验与初始化，直接进入配置生成（第3步保留，以便本地也写入 config.example.yaml）
    DATA_REPO=""
    GIT_TOKEN=""
    DATA_BRANCH="${DATA_BRANCH:-main}"
    SKIP_GITSTORE=1
else
    SKIP_GITSTORE=0
fi

# ------------------------------------------------------------------
# 第2步（续）：强制校验 GitStore 持久化参数（仅 GitStore 模式）
#        一体化部署在非 LOCAL_ONLY_MODE 下不再提供本地兜底；
#        没有 DATA_REPO 时直接失败，避免 Render 休眠/重启后数据丢失。
# ------------------------------------------------------------------
DATA_REPO="${DATA_REPO:-}"
GIT_TOKEN="${GIT_TOKEN:-}"
DATA_BRANCH="${DATA_BRANCH:-main}"

if [ "$SKIP_GITSTORE" -eq 0 ]; then
    if [ -z "$DATA_REPO" ]; then
        echo "[entrypoint] ERROR: DATA_REPO 未设置。此镜像在 GitStore 模式下必须配置数据仓库；如需纯本地运行请设置 LOCAL_ONLY_MODE=true。" >&2
        exit 1
    fi

    if [ -z "$GIT_TOKEN" ]; then
        echo "[entrypoint] ERROR: GIT_TOKEN 未设置。必须提供可读写 DATA_REPO 的 Git 凭据；或设置 LOCAL_ONLY_MODE=true 以禁用 git 备份。" >&2
        exit 1
    fi

    if ! printf '%s' "$DATA_REPO" | grep -Eq '^https?://'; then
        echo "[entrypoint] ERROR: DATA_REPO 目前只支持 http(s) URL：${DATA_REPO}" >&2
        exit 1
    fi

    echo "[entrypoint] GitStore 参数校验通过"
    echo "  Git repo: ${DATA_REPO} (branch: ${DATA_BRANCH})"
    echo "  Git user: ${GIT_USERNAME:-git}"

    # 用系统 git 先验证远端认证，避免 CPA 启动后才反复重启。
    GIT_ASKPASS_FILE="/tmp/git-askpass-entrypoint.sh"
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

    if ! timeout 30 git ls-remote "$DATA_REPO" >/dev/null 2>&1; then
        echo "[entrypoint] ERROR: 无法访问 DATA_REPO，请检查 DATA_REPO/GIT_USERNAME/GIT_TOKEN/DATA_BRANCH 权限。" >&2
        exit 1
    fi

    echo "[entrypoint] Git 远端认证验证通过"
fi

# ------------------------------------------------------------------
# 第3步：生成 CPA GitStore 初始配置文件
#        路径：/data/config.example.yaml
#        CPA 的 GitStore 首次启动时，如果 gitstore/config/config.yaml
#        不存在，会从 config.example.yaml 复制过去并提交到 git。
# ------------------------------------------------------------------
echo "[entrypoint] Generating CPA config example..."

CPA_MANAGEMENT_KEY="${CPA_MANAGEMENT_KEY:-changeme}"
CPA_API_KEYS="${CPA_API_KEYS:-sk-example-key}"

# 将逗号分隔的 API keys 转为 YAML 列表
API_KEYS_YAML=""
IFS=',' read -ra KEYS <<< "${CPA_API_KEYS}"
for key in "${KEYS[@]}"; do
    key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    API_KEYS_YAML="${API_KEYS_YAML}  - \"${key}\""$'\n'
done

PROXY_CONFIG=""
if [ -n "${CPA_PROXY}" ]; then
    PROXY_CONFIG="proxy: \"${CPA_PROXY}\""
fi

# 写入 config.example.yaml（CPA git store bootstrap 用）
cat > /data/config.example.yaml << CPAEOF
# CPA config.example.yaml — 由 entrypoint.sh 自动生成
# 首次启动时 CPA 的 GitStore 会使用此文件初始化 gitstore/config/config.yaml
host: "127.0.0.1"
port: ${CPA_PORT:-8317}

tls:
  enable: false
  cert: ""
  key: ""

remote-management:
  allow-remote: true
  secret-key: "${CPA_MANAGEMENT_KEY}"
  disable-control-panel: true

api-keys:
${API_KEYS_YAML}

auth-dir: "auths"

debug: false
usage-statistics-enabled: true
redis-usage-queue-retention-seconds: 120
${PROXY_CONFIG}
CPAEOF

echo "[entrypoint] CPA config example written to /data/config.example.yaml"

# ------------------------------------------------------------------
# 第4步：配置 Git 数据持久化（仅 GitStore 模式）
#        CPA 内置的 GitTokenStore（GITSTORE_* 环境变量）
#        数据统一放在 /data/gitstore/ 目录下：
#          /data/gitstore/auths/*.json          ← CPA 管理
#          /data/gitstore/config/config.yaml     ← CPA 管理
#          /data/gitstore/usage.sqlite           ← CPAMP 同步
#          /data/gitstore/data.key               ← CPAMP 同步
#
# LOCAL_ONLY_MODE=true 时此步被跳过：
#   CPA 主程序无 GITSTORE_* 环境变量 → 回落到默认 file 存储
#   CPAMP 数据直接落 /data/local/，sync-data 已被禁用
# ------------------------------------------------------------------
if [ "$SKIP_GITSTORE" -eq 0 ]; then
    echo "[entrypoint] Configuring CPA GitStore + CPAMP data persistence..."
    echo "  Git repo: ${DATA_REPO} (branch: ${DATA_BRANCH})"

    export GITSTORE_GIT_URL="${DATA_REPO}"
    export GITSTORE_GIT_USERNAME="${GIT_USERNAME:-git}"
    export GITSTORE_GIT_TOKEN="${GIT_TOKEN}"
    export GITSTORE_GIT_BRANCH="${DATA_BRANCH}"
    # 关键：local path 决定 git 工作树位置
    # CPA 会 clone/pull 到 ${GITSTORE_LOCAL_PATH}/gitstore/
    export GITSTORE_LOCAL_PATH="/data"

    export CPAMP_GIT_MODE="true"
    echo "[entrypoint] CPA GitStore enabled: /data/gitstore/"
else
    echo "[entrypoint] CPA GitStore disabled (LOCAL_ONLY_MODE): data stays at /data/local/"
fi

# ------------------------------------------------------------------
# 第5步：设置 CPAMP 环境变量
#        GitStore 模式：数据目录为 /data/gitstore/（与 CPA 同仓库）
#        LOCAL_ONLY_MODE：数据目录为 /data/local/（纯本地）
# ------------------------------------------------------------------
export HTTP_ADDR="127.0.0.1:${CPAMP_PORT:-18317}"
if [ "$SKIP_GITSTORE" -eq 0 ]; then
    export USAGE_DATA_DIR="/data/gitstore"
    export USAGE_DB_PATH="/data/gitstore/usage.sqlite"
else
    export USAGE_DATA_DIR="/data/local"
    export USAGE_DB_PATH="/data/local/usage.sqlite"
fi

export CPA_UPSTREAM_URL="${CPA_UPSTREAM_URL:-http://127.0.0.1:8317}"

# 传递 CPA 管理密钥给 CPAMP；一体化部署默认复用同一个密码。
# 如果用户显式设置 CPA_MANAGER_ADMIN_KEY，则以显式设置为准；否则使用 CPA_MANAGEMENT_KEY。
if [ -n "${CPA_MANAGEMENT_KEY}" ] && [ "${CPA_MANAGEMENT_KEY}" != "changeme" ]; then
    export CPA_MANAGEMENT_KEY="${CPA_MANAGEMENT_KEY}"
    export CPA_MANAGER_ADMIN_KEY="${CPA_MANAGER_ADMIN_KEY:-${CPA_MANAGEMENT_KEY}}"
elif [ -n "${CPA_MANAGER_ADMIN_KEY}" ]; then
    export CPA_MANAGER_ADMIN_KEY="${CPA_MANAGER_ADMIN_KEY}"
fi

# ------------------------------------------------------------------
# 第5步（续）：根据环境变量调整 supervisor 服务
# ------------------------------------------------------------------
# 数据库备份开关：关闭时从 supervisor 中移除 sync-data 程序
# 注意：LOCAL_ONLY_MODE=true 分支已执行过同样的 sed 注释，
#       这里仅在 GitStore 模式下单独靠 CPAMP_DB_BACKUP_ENABLED 关闭备份时才执行。
if [ "$SKIP_GITSTORE" -eq 0 ] && [ "${CPAMP_DB_BACKUP_ENABLED:-true}" != "true" ]; then
    echo "[entrypoint] CPAMP_DB_BACKUP_ENABLED=${CPAMP_DB_BACKUP_ENABLED}，禁用数据库备份同步"
    # 用 sed 注释掉 sync-data 整段配置，supervisor 不会启动它
    sed -i '/^\[program:sync-data\]/,/^\[/ s/^/#/' /etc/supervisor/supervisord.conf
fi

# ------------------------------------------------------------------
# 第6步：启动所有服务
# ------------------------------------------------------------------
echo "[entrypoint] Starting services..."
echo "  CPA  : http://127.0.0.1:${CPA_PORT:-8317}"
echo "  CPAMP: http://127.0.0.1:${CPAMP_PORT:-18317}"
echo "  Nginx: http://0.0.0.0:${RENDER_PORT}"
if [ "$SKIP_GITSTORE" -eq 0 ]; then
    echo "  Data : GitStore @ /data/gitstore/ (repo: ${DATA_REPO})"
else
    echo "  Data : LOCAL  CPA→/data/  CPAMP→/data/local/  (no git)"
fi

exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
