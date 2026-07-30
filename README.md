# CLIProxyAPI + CPA-Manager-Plus 一体化镜像

将 **CLIProxyAPI**（CPA，AI API 代理）与 **CPA-Manager-Plus**（CPAMP，用量监控与管理面板）打包到同一个 Docker 镜像，**专为 Render 免费版设计**，但也适用于任何 Docker 环境。

---

## 目录

- [两种数据模式](#两种数据模式)
- [架构](#架构)
- [请求路由](#请求路由)
- [数据持久化](#数据持久化)
- [快速开始](#快速开始)
- [环境变量参考](#环境变量参考)
- [数据持久化注意事项](#数据持久化注意事项)
- [自动构建与发布机制](#自动构建与发布机制)
- [构建参数](#构建参数)
- [License](#license)

---

## 两种数据模式

镜像支持两条数据通路，由 `LOCAL_ONLY_MODE` 环境变量决定。选择前请先理解两者差异：

| 维度 | GitStore 模式（默认） | LOCAL_ONLY_MODE 模式 |
|---|---|---|
| `LOCAL_ONLY_MODE` | `false` 或未设置 | `true` |
| 数据备份 | 通过 Git 仓库自动 commit + push | 完全无 git 操作 |
| 必填环境变量 | `DATA_REPO` / `GIT_TOKEN` | 无（全部走本地磁盘） |
| CPA auths/config 落点 | `/data/gitstore/auths/`、`/data/gitstore/config/` | `/data/auths/`、`/data/config.yaml` |
| CPAMP SQLite 落点 | `/data/gitstore/usage.sqlite` | `/data/local/usage.sqlite` |
| 跨容器重启持久化 | ✅ Git 仓库自动恢复 | ❌ 不持久（除非挂载 `/data` volume） |
| 适用场景 | Render 等无状态托管平台 | 本地开发 / 自托管 / 已挂载持久卷 |
| sync-data 守护进程 | 运行（每 2 分钟同步） | 被禁用 |

**选择建议**：
- 没有 Docker volume、跑在 Render/Heroku 等易失环境 → 使用默认 GitStore 模式
- 本地 docker run 做 PoC、或已有持久卷挂载到 `/data` → 使用 `LOCAL_ONLY_MODE=true`

---

## 架构

```
                    ┌──────────────────────────────────────┐
                    │           Docker 容器                  │
                    │                                        │
                    │  浏览器 ──→ Nginx :$PORT ──→ CPA :8317  │
                    │                    │                   │
                    │                    └──→ CPAMP :18317    │
                    │                            │           │
                    │             ┌──────────────┴──────────┐ │
                    │             │                        │ │
                    │   GitStore 模式         LOCAL_ONLY_MODE │ │
                    │   /data/gitstore/       /data/         │ │
                    │   ├ auths/*.json        ├ auths/*.json  │ │
                    │   ├ config/*.yaml       ├ config.yaml   │ │
                    │   ├ usage.sqlite        │               │ │
                    │   └ data.key            └ /data/local/  │ │
                    │     │                     ├ usage.sqlite│ │
                    │     ↓ (各自同步)           └ data.key    │ │
                    │   GitHub 数据仓库           (无同步)       │ │
                    └──────────────────────────────────────┘
```

## 请求路由

| 路径 | 目标 | 说明 |
|---|---|---|
| `/management.html` | CPAMP :18317 | 管理面板（React 单页应用） |
| `/usage-service/*` | CPAMP :18317 | CPAMP 配置和 API |
| `/setup` | CPAMP :18317 | 首次设置向导 |
| `/health` | CPAMP :18317 | 健康检查（Render 用） |
| `/status` | CPAMP :18317 | CPAMP 状态 |
| `/v0/management/*` | CPAMP :18317 | 管理 API（CPAMP 处理用量/定价，其余代理回 CPA） |
| `/` 及其他所有请求 | CPA :8317 | AI API 代理（v1/chat/completions 等） |

---

## 数据持久化

### GitStore 模式（默认，`LOCAL_ONLY_MODE` 未设置或 `false`）

**充分利用 CPA 内置的 GitTokenStore**，所有数据托管在同一个 Git 仓库：

| 数据 | 管理方式 | 同步策略 |
|---|---|---|
| `auths/*.json`（认证文件） | **CPA 自动管理** | 添加/删除/更新时自动 commit + push |
| `config/config.yaml`（CPA 配置） | **CPA 自动管理** | 修改配置时自动 commit + push |
| `usage.sqlite`（CPAMP 用量主库） | **sync-data.sh 管理** | 同步前执行 SQLite checkpoint，尽量把 WAL 合并回主库 |
| `usage.sqlite-wal` / `usage.sqlite-shm` | **sync-data.sh 兜底处理** | checkpoint 未完全合并或数据库繁忙时一并提交，避免丢最新数据 |
| `data.key`（CPAMP 加密密钥） | **sync-data.sh 管理** | 与 SQLite 文件同步提交 |

三层保护：

| 层级 | 触发条件 | 说明 |
|---|---|---|
| ① 定时同步 | 每 2 分钟 | 检测 CPAMP 文件变更，自动 commit + push |
| ② 空闲预判同步 | usage.sqlite 超过 8 分钟未变化 | Render 免费版可能 10 分钟左右休眠，所以提前主动推送 |
| ③ SIGTERM 兜底 | 容器收到停止信号 | 执行最终同步后再退出 |

### LOCAL_ONLY_MODE 模式（`LOCAL_ONLY_MODE=true`）

无任何 git 交互，数据全部落本地磁盘。**注意两个子项目落盘目录不同**（已从 CPA 上游源码验证：CPA file 模式的根目录由启动时 `os.Getwd()` 决定，即容器 `WORKDIR=/data`；`WRITABLE_PATH` 环境变量只对 pgstore/objectstore/gitstore 三条分支生效，file 分支不受控）：

| 数据 | 落点 | 控制方式 |
|---|---|---|
| CPA auths | `/data/auths/*.json` | `WORKDIR=/data` + config 里 `auth-dir: "auths"` |
| CPA config | `/data/config.yaml` | `WORKDIR=/data` |
| CPAMP usage.sqlite | `/data/local/usage.sqlite` | entrypoint 设 `USAGE_DATA_DIR=/data/local` |
| CPAMP data.key | `/data/local/data.key` | 同上 |
| sync-data 守护进程 | 被禁用 | entrypoint 自动 `CPAMP_DB_BACKUP_ENABLED=false` + 移除 supervisor 程序段 |

---

## 快速开始

### 选项 A：GitStore 模式（Render 等无状态平台）

#### 准备工作

1. **Fork 或创建本仓库**：`https://github.com/你的用户名/CLIProxyAPI-With-Plus`
2. **创建一个私有数据仓库**（用于持久化 SQLite 数据）：
   - 在 GitHub 创建一个**私有仓库**，例如 `cpa-data`
3. **配置 GitHub Token 权限**：
   - 你的 Fine-grained PAT 需要以下权限才能正常工作：
     - **数据仓库**：`Contents: Read and write`（推送 SQLite 数据）
     - **Container registry**：`Write`（推送 Docker 镜像，仅首次)

#### Render 部署步骤

1. **Render Dashboard → New + → Web Service**
2. **连接你的 GitHub 仓库**（本项目的 fork）
3. **填写以下配置**：

   | 字段 | 值 |
   |---|---|
   | Name | `cpa-all-in-one`（或任意名称） |
   | Region | 离你最近的区域（推荐 Singapore） |
   | Branch | `main` |
   | Runtime | **Docker** |
   | Health Check Path | `/health` |

4. **环境变量**（见 [环境变量参考](#环境变量参考)）：

   | 变量 | 是否必填 | 默认值 | 说明 |
   |---|---|---|---|
   | `CPA_MANAGEMENT_KEY` | ✅ 必填 | - | CPA 管理 API 密钥（**自己设一个复杂密码**） |
   | `CPA_API_KEYS` | ✅ 必填 | - | API 调用密钥，逗号分隔（如 `sk-key1,sk-key2`） |
   | `DATA_REPO` | ✅ 必填 | - | 私有数据仓库 URL（如 `https://github.com/你的用户名/cpa-data.git` 或 `https://gitee.com/你的用户名/cpa-data.git`） |
   | `GIT_TOKEN` | ✅ 必填 | - | 有数据仓库读写权限的 Git 凭据（GitHub PAT / Gitee 私人令牌等） |
   | `CPA_MANAGER_ADMIN_KEY` | ⬜ 可选 | 同 `CPA_MANAGEMENT_KEY` | CPAMP 管理面板管理员密码；一体化部署默认复用 CPA 管理密钥 |

5. **点击 "Create Web Service"**
6. **打开 CPAMP 管理面板**：
   打开 `https://你的应用名.onrender.com/management.html`，默认使用 `CPA_MANAGEMENT_KEY` 登录。
   如果你显式设置了 `CPA_MANAGER_ADMIN_KEY`，则使用该值登录。

### 选项 B：LOCAL_ONLY_MODE 模式（本地开发 / 持久卷）

```bash
# 拉取镜像
docker pull ghcr.io/zcr268/CLIProxyAPI-With-Plus:latest

# 运行（无需 DATA_REPO / GIT_TOKEN）
docker run -d \
  --name cpa-local \
  -p 8080:10000 \
  -e LOCAL_ONLY_MODE=true \
  -e CPA_MANAGEMENT_KEY=my-secret-key \
  -e CPA_API_KEYS=sk-demo-key \
  -v cpa-data:/data \
  ghcr.io/zcr268/CLIProxyAPI-With-Plus:latest

# 打开管理面板
open http://localhost:8080/management.html
```

> 💡 `-v cpa-data:/data` 让容器重启后数据保留；不挂载则容器删除即数据丢失（这是 LOCAL_ONLY_MODE 的预期行为）。

### 管理面板首次配置

1. 打开 `https://你的应用名.onrender.com/management.html`（或本地 `http://localhost:8080/management.html`）
2. 输入 Admin Key：默认就是 `CPA_MANAGEMENT_KEY`；如果显式设置了 `CPA_MANAGER_ADMIN_KEY`，则使用 `CPA_MANAGER_ADMIN_KEY`
3. 设置向导：
   - **CPA URL**：容器内地址填写 `http://127.0.0.1:8317`
   - **CPA Management Key**：填写你在环境变量中设置的 `CPA_MANAGEMENT_KEY` 值
   - **启用请求监控**：勾选
4. 保存后即可使用管理面板

---

## 环境变量参考

### 模式切换

| 变量 | 默认值 | 说明 |
|---|---|---|
| `LOCAL_ONLY_MODE` | `false` | 设为 `true` 启用**纯本地数据模式**：跳过 `DATA_REPO`/`GIT_TOKEN` 校验，不导出 `GITSTORE_*`（CPA 回落到默认 file 存储），CPAMP SQLite 备份被自动关闭（`CPAMP_DB_BACKUP_ENABLED=false`），不再发起任何 git 操作。注意 CPA auths/config 落 `/data/`、CPAMP SQLite 落 `/data/local/`，两者**不在同一目录**（CPA file 模式的根由启动时工作目录决定，非环境变量可控） |

### GitStore 模式必填

仅 `LOCAL_ONLY_MODE=false`（默认）时必填；`LOCAL_ONLY_MODE=true` 时被全部忽略。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DATA_REPO` | - | 私有数据仓库 URL（当前仅支持 http(s)）；entrypoint 会先 `git ls-remote` 验证认证 |
| `GIT_TOKEN` | - | 有数据仓库读写权限的 Git 凭据（GitHub PAT / Gitee 私人令牌等） |
| `GIT_USERNAME` | `git` | Git 认证用户名；Gitee 通常需要设置为真实用户名 |
| `DATA_BRANCH` | `main` | 数据仓库分支 |

### CPA 必填（两种模式都需）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `CPA_MANAGEMENT_KEY` | `changeme` | CPA 管理 API 密钥（**自己设一个复杂密码**） |
| `CPA_API_KEYS` | `sk-example-key` | API 调用密钥，逗号分隔（如 `sk-key1,sk-key2`） |
| `CPA_MANAGER_ADMIN_KEY` | 同 `CPA_MANAGEMENT_KEY` | CPAMP 管理面板管理员密码；通常不用单独设置 |

### CPAMP 可选变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `CPAMP_DB_MAX_MB` | `5` | 数据库大小上限（MB），超过此值启动时自动清理（清理范围由 `CPAMP_DB_CLEAN_TABLES` 控制） |
| `CPAMP_DB_CLEAN_TABLES` | `USAGE` | 清理模式：`USAGE` 仅清用量统计（保留配置/认证状态），`FULL` 删除整个数据库重建，或逗号分隔表名列表精确指定要清空的表 |
| `CPAMP_DB_KEEP_HOURS` | `72` | 保留最近 N 小时的用量事件（仅当清理范围包含 `usage_events` 表时生效；设为 `0` 则全部清除不保留） |
| `CPAMP_DB_CLEAN_ON_START` | - | 设为 `true` 每次启动强制清理（等效 `CPAMP_DB_CLEAN_TABLES=USAGE`，保留配置/认证状态） |
| `CPAMP_DB_BACKUP_ENABLED` | `true` | 是否定时备份 SQLite 到 Git 仓库；设为 `false` 关闭备份（entrypoint 跳过 sync-data 进程）。`LOCAL_ONLY_MODE=true` 时自动置为 `false` |
| `SYNC_INTERVAL` | `120` | 数据同步间隔（秒） |
| `IDLE_TIMEOUT` | `480` | 空闲判定阈值（秒） |

### CPA 运行可选

| 变量 | 默认值 | 说明 |
|---|---|---|
| `CPA_PROXY` | - | CPA 出站代理（如 `socks5://user:pass@host:1080/`） |
| `CPA_UPSTREAM_URL` | `http://127.0.0.1:8317` | CPAMP 连接 CPA 的地址（容器内无需修改） |
| `CPA_PORT` | `8317` | CPA 监听端口 |
| `CPAMP_PORT` | `18317` | CPAMP 监听端口 |

### 平台自动设置

| 变量 | 说明 |
|---|---|
| `PORT` | Render 自动设置，Nginx 会绑定到 `0.0.0.0:$PORT`；未设置时默认 `10000` |

---

## 数据持久化注意事项

### GitStore 模式

- **必须配置 `DATA_REPO` 和 `GIT_TOKEN`**：未配置会启动失败
- **建议使用私有仓库**：SQLite 文件可能包含敏感信息
- **Token 权限最小化**：需要目标数据仓库读写权限
- **首次同步**：数据仓库为空时，CPA GitStore 会初始化 `auths/` 和 `config/`，CPAMP 同步脚本会写入 `usage.sqlite*` 和 `data.key`
- **并发安全**：只有一个容器实例时安全；多实例不适用

### LOCAL_ONLY_MODE 模式

- **不需要任何 Git 配置**：`DATA_REPO`/`GIT_TOKEN`/`GIT_USERNAME`/`GITSTORE_*` 均不使用
- **CPA 主程序**：无 `GITSTORE_*` → 自动回落到 file 存储。file 分支的下根目录是 CPA 启动时的当前目录（容器 `WORKDIR=/data`），因此 auths 落 `/data/auths/`，config 落 `/data/config.yaml`（**与 CPAMP 不在同一目录**）
- **CPAMP SQLite**：由 entrypoint 显式设置 `USAGE_DATA_DIR=/data/local`、`USAGE_DB_PATH=/data/local/usage.sqlite`，落 `/data/local/`
- **sync-data**：被禁用，不会有任何 git push
- **数据不持久跨重启**：和 GitStore 模式不同，容器重新创建后 `/data/` 与 `/data/local/` 会丢失（volume 挂载 `/data` 则另当别论，视部署平台而定）
- **与 GitStore 模式互不迁移**：切换模式时不会自动搬运数据。从 GitStore 切到 LOCAL：可把 `/data/gitstore/` 下的 `auths/`、`config/` 拷到 `/data/`，`usage.sqlite`、`data.key` 拷到 `/data/local/`。反向同理

---

## 自动构建与发布机制

本仓库的 GitHub Actions 在以下三种情况自动构建并推送镜像到 `ghcr.io`：

| 触发条件 | 说明 |
|---|---|
| push 到 `main` | 你主动改本仓库后立即触发 |
| 每 6 小时（cron） | 检查 CPA/CPAMP 上游最新 Release commit SHA，变了则缓存失效重建 |
| 手动触发 | GitHub → Actions → "构建并推送 Docker 镜像" → Run workflow，可指定 CPA/CPAMP 版本 |

构建过程：

```
到点了 → 获取 CPA 和 CPAMP 上游最新 commit SHA
      → 作为 Docker build-arg 传入
      → SHA 变了？→ 缓存失效 → 拉取新代码 → 构建 → 推送 ghcr.io
      → SHA 没变？→ 全缓存命中 → 秒级完成（不浪费编译资源）
```

镜像发布后会自动创建 GitHub Release 并产出三个 tag：

| Tag 格式 | 含义 |
|---|---|
| `ghcr.io/zcr268/CLIProxyAPI-With-Plus:latest` | 最新构建（推荐生产用） |
| `ghcr.io/zcr268/CLIProxyAPI-With-Plus:<CPA-ver>--<CPAMP-ver>` | 上游版本组合固定 |
| `ghcr.io/zcr268/CLIProxyAPI-With-Plus:sha-<short-sha>` | 精确到 commit |

### 手动触发构建指定版本

1. 进入 GitHub 仓库 → Actions → "构建并推送 Docker 镜像"
2. 点击 "Run workflow"
3. 填写 CPA 和 CPAMP 的版本号
4. 等待构建完成

### 本地构建

```bash
docker build \
  --build-arg CPA_VERSION=v7.2.86 \
  --build-arg CPAMP_VERSION=v1.11.3 \
  -t cpa-all-in-one .

docker run -d \
  --name cpa-test \
  -p 8080:10000 \
  -e LOCAL_ONLY_MODE=true \
  -e CPA_MANAGEMENT_KEY=my-secret-key \
  -e CPA_API_KEYS=sk-demo-key \
  cpa-all-in-one

open http://localhost:8080/management.html
```

---

## 构建参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `CPA_VERSION` | 最新 Release | CPA 版本标签；Actions 默认自动解析最新 Release，手动触发时可覆盖 |
| `CPAMP_VERSION` | 最新 Release | CPAMP 版本标签；Actions 默认自动解析最新 Release，手动触发时可覆盖 |
| `CPA_COMMIT` | `none` | 构建时自动传入 commit SHA |
| `CPA_BUILD_DATE` | `unknown` | 构建时自动传入时间戳 |

---

## License

MIT
