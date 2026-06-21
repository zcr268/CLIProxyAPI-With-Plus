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
RENDER_PORT="${PORT:-8080}"
sed "s/{{PORT}}/${RENDER_PORT}/g" -i "$NGINX_CONF"
echo "[entrypoint] Nginx configured to listen on port ${RENDER_PORT}"

# ------------------------------------------------------------------
# 第2步：生成 CPA 初始配置文件（用于 git store 首次 bootstrap）
#        路径：/data/config.example.yaml
#        CPA 的 git store 首次启动时，如果 gitstore/config/config.yaml
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
host: ""
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

# 同时写入 /etc/cpa/config.yaml 作为非 git store 模式的兜底配置
cat > /etc/cpa/config.yaml << CPAEOF2
# CPA 本地配置 — 非 git store 模式时使用
host: ""
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

auth-dir: "/data/auths"

debug: false
usage-statistics-enabled: true
redis-usage-queue-retention-seconds: 120
${PROXY_CONFIG}
CPAEOF2
echo "[entrypoint] CPA local config written to /etc/cpa/config.yaml"

# ------------------------------------------------------------------
# 第3步：配置 Git 数据持久化（可选）
#        CPA 内置的 GitTokenStore（GITSTORE_* 环境变量）
#        数据统一放在 /data/gitstore/ 目录下：
#          /data/gitstore/auths/*.json          ← CPA 管理
#          /data/gitstore/config/config.yaml     ← CPA 管理
#          /data/gitstore/usage.sqlite           ← CPAMP 同步
#          /data/gitstore/data.key               ← CPAMP 同步
# ------------------------------------------------------------------
DATA_REPO="${DATA_REPO:-}"
GIT_TOKEN="${GIT_TOKEN:-}"
DATA_BRANCH="${DATA_BRANCH:-main}"

if [ -n "$DATA_REPO" ]; then
    echo "[entrypoint] Configuring CPA GitStore + CPAMP data persistence..."
    echo "  Git repo: ${DATA_REPO} (branch: ${DATA_BRANCH})"

    # 设置 CPA 内置 GitStore 环境变量
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
    echo "[entrypoint] DATA_REPO not set — 不使用 Git 持久化"
    echo "  CPA 使用本地文件存储，容器重启后数据丢失！"
    # 不使用 git store 时，CPA 用 -config 参数加载本地配置
    # 不需要额外设置
fi

# ------------------------------------------------------------------
# 第4步：设置 CPAMP 环境变量
#        使用 git store 时，数据目录设为 /data/gitstore/（与 CPA 同仓库）
#        不使用 git store 时，数据目录设为 /data/
# ------------------------------------------------------------------
export HTTP_ADDR="127.0.0.1:${CPAMP_PORT:-18317}"

if [ -n "$DATA_REPO" ]; then
    export USAGE_DATA_DIR="/data/gitstore"
    export USAGE_DB_PATH="/data/gitstore/usage.sqlite"
else
    export USAGE_DATA_DIR="/data"
    export USAGE_DB_PATH="/data/usage.sqlite"
fi

export CPA_UPSTREAM_URL="${CPA_UPSTREAM_URL:-http://127.0.0.1:8317}"

# 传递 CPA 管理密钥给 CPAMP
if [ -n "${CPA_MANAGEMENT_KEY}" ] && [ "${CPA_MANAGEMENT_KEY}" != "changeme" ]; then
    export CPA_MANAGEMENT_KEY="${CPA_MANAGEMENT_KEY}"
fi
if [ -n "${CPA_MANAGER_ADMIN_KEY}" ]; then
    export CPA_MANAGER_ADMIN_KEY="${CPA_MANAGER_ADMIN_KEY}"
fi

# ------------------------------------------------------------------
# 第5步：启动所有服务
# ------------------------------------------------------------------
echo "[entrypoint] Starting services..."
echo "  CPA  : http://127.0.0.1:${CPA_PORT:-8317}"
echo "  CPAMP: http://127.0.0.1:${CPAMP_PORT:-18317}"
echo "  Nginx: http://0.0.0.0:${RENDER_PORT}"
if [ -n "$DATA_REPO" ]; then
    echo "  Data : GitStore @ /data/gitstore/ (repo: ${DATA_REPO})"
fi

exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
