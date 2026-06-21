# =============================================================================
# CLIProxyAPI + CPA-Manager-Plus 一体化镜像
# 多阶段构建：在构建期内从上游仓库 clone 源码并编译
# =============================================================================
# 构建参数（可在 GitHub Actions 或 docker build --build-arg 中覆盖）
ARG CPA_VERSION=v7.2.26
ARG CPAMP_VERSION=v1.7.0
ARG CPA_COMMIT=none
ARG CPA_BUILD_DATE=unknown

# === 上游 HEAD SHA（用于自动重建缓存失效）===
# 当 schedule 触发时，Actions 传入最新的上游 commit SHA
# SHA 变了 → Docker layer cache 自动失效 → 拉取新代码 → 构建新镜像
# SHA 没变 → 全缓存命中 → 秒级完成
ARG CPA_HEAD_SHA=check-schedule
ARG CPAMP_HEAD_SHA=check-schedule

# ============================== 阶段1：编译 CPA ==============================
FROM golang:1.26-bookworm AS cpa-builder
ARG CPA_VERSION
ARG CPA_COMMIT
ARG CPA_BUILD_DATE
ARG CPA_HEAD_SHA

WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

# 缓存失效标记：CPA_HEAD_SHA 变化时此层重建
RUN echo "CPA HEAD SHA: ${CPA_HEAD_SHA}" > /tmp/cpa-version.txt

# Clone CPA 源码
RUN git clone --depth 1 --branch ${CPA_VERSION} \
    https://github.com/router-for-me/CLIProxyAPI.git .

RUN go mod download
RUN CGO_ENABLED=1 GOOS=linux go build -buildvcs=false \
    -ldflags="-s -w \
      -X 'main.Version=${CPA_VERSION}' \
      -X 'main.Commit=${CPA_COMMIT}' \
      -X 'main.BuildDate=${CPA_BUILD_DATE}'" \
    -o /out/CLIProxyAPI ./cmd/server/

# ============================ 阶段2：编译 CPAMP 前端 ==========================
FROM node:22-alpine AS web-build
ARG CPAMP_VERSION
ARG CPAMP_HEAD_SHA
RUN apk add --no-cache git
WORKDIR /src

# 缓存失效标记：CPAMP_HEAD_SHA 变化时此层重建
RUN echo "CPAMP HEAD SHA: ${CPAMP_HEAD_SHA}" > /tmp/cpamp-version.txt

RUN git clone --depth 1 --branch ${CPAMP_VERSION} \
    https://github.com/seakee/CPA-Manager-Plus.git .

# 安装 npm 依赖（根目录 workspaces 包含 apps/web）
RUN npm ci
# 构建前端（单文件 React 应用）
WORKDIR /src/apps/web
RUN VERSION=${CPAMP_VERSION} npm run build

# ============================ 阶段3：编译 CPAMP 后端 ==========================
FROM golang:1.24-alpine AS cpamp-builder
ARG CPAMP_VERSION
ARG CPAMP_HEAD_SHA
RUN apk add --no-cache git
WORKDIR /src
COPY patches/cpamp-collector-db-config.patch /tmp/cpamp-collector-db-config.patch

# 缓存失效标记：CPAMP_HEAD_SHA 变化时此层重建
RUN echo "CPAMP HEAD SHA: ${CPAMP_HEAD_SHA}" > /tmp/cpamp-version.txt

RUN git clone --depth 1 --branch ${CPAMP_VERSION} \
    https://github.com/seakee/CPA-Manager-Plus.git .

# 一体化部署补丁：连接信息仍可由环境变量注入，但采集模式/轮询/批量/查询上限
# 必须留给 CPAMP 数据库和管理面板管理，避免 Render 环境变量把页面配置锁死。
RUN git apply /tmp/cpamp-collector-db-config.patch

# 注入构建好的前端
COPY --from=web-build /src/apps/web/dist/index.html \
    /src/apps/manager-server/internal/httpapi/web/management.html

WORKDIR /src/apps/manager-server
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/cpa-manager-plus ./cmd/cpa-manager-plus

# ========================== 阶段4：最终运行镜像 =============================
FROM debian:bookworm-slim

# 安装运行时依赖：nginx + supervisor + git（数据持久化用）
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    tzdata \
    nginx \
    supervisor \
    git \
    sqlite3 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/log/supervisor /data

# 复制二进制文件
COPY --from=cpa-builder /out/CLIProxyAPI /usr/local/bin/
COPY --from=cpamp-builder /out/cpa-manager-plus /usr/local/bin/

# 复制配置文件
COPY nginx.conf /etc/nginx/nginx.conf
COPY supervisord.conf /etc/supervisor/supervisord.conf

# 复制脚本
COPY entrypoint.sh /entrypoint.sh
COPY sync-data.sh /usr/local/bin/sync-data.sh
COPY start-cpamp.sh /usr/local/bin/start-cpamp.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/sync-data.sh /usr/local/bin/start-cpamp.sh

# 时区
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime && echo "${TZ}" > /etc/timezone

# Render 的 PORT 环境变量默认 10000，我们用 8080 作为默认，
# entrypoint 会替换为真实的 PORT
ENV CPA_PORT=8317
ENV CPAMP_PORT=18317

WORKDIR /data

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
