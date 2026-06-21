# CLIProxyAPI + CPA-Manager-Plus 一体化镜像

将 **CLIProxyAPI**（CPA，AI API 代理）和 **CPA-Manager-Plus**（CPAMP，用量监控与管理面板）打包到同一个 Docker 镜像，**专为 Render 免费版设计**。

## 架构

```
                    ┌──────────────────────────────────────┐
                    │           Docker 容器                  │
                    │                                        │
                    │  浏览器 ──→ Nginx :8080 ──→ CPA :8317   │
                    │                    │                   │
                    │                    └──→ CPAMP :18317    │
                    │                            │           │
                    │                    ┌───────┘           │
                    │                    ↓                    │
                    │           /data/gitstore/  ← Git 工作树  │
                    │            ├── auths/*.json  ← CPA 管理  │
                    │            ├── config/*.yaml ← CPA 管理  │
                    │            ├── usage.sqlite  ← CPAMP     │
                    │            └── data.key      ← CPAMP     │
                    │                    ↓ (各自同步)           │
                    │               GitHub 数据仓库             │
                    └──────────────────────────────────────┘
```

### 请求路由

| 路径 | 目标 | 说明 |
|---|---|---|
| `/management.html` | CPAMP :18317 | 管理面板（React 单页应用） |
| `/usage-service/*` | CPAMP :18317 | CPAMP 配置和 API |
| `/setup` | CPAMP :18317 | 首次设置向导 |
| `/health` | CPAMP :18317 | 健康检查（Render 用） |
| `/status` | CPAMP :18317 | CPAMP 状态 |
| `/v0/management/*` | CPAMP :18317 | 管理 API（CPAMP 处理用量/定价，其余代理回 CPA） |
| `/` 及其他所有请求 | CPA :8317 | AI API 代理（v1/chat/completions 等） |

### 数据持久化

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

## 自动重建机制

本仓库的 GitHub Actions **每 6 小时自动运行一次**，逻辑如下：

```
到点了 → 获取 CPA 和 CPAMP 上游最新 commit SHA
      → 作为 Docker build-arg 传入
      → SHA 变了？→ 缓存失效 → 拉取新代码 → 构建 → 推送 ghcr.io
      → SHA 没变？→ 全缓存命中 → 秒级完成（不浪费编译资源）
```

- **CPA 上游更新** 📦 → 镜像自动重建
- **CPAMP 上游更新** 📦 → 镜像自动重建
- **你主动改本仓库** → 立即触发构建（push 事件）
- **上游没更新** → 构建跳过编译步骤（Docker layer cache 返回）

你也可以在 GitHub → Actions → 手动触发指定版本构建。

## 使用方法

### 1. 在 Render 上部署

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

#### 环境变量

| 变量 | 是否必填 | 默认值 | 说明 |
|---|---|---|---|
| `CPA_MANAGEMENT_KEY` | ✅ 必填 | - | CPA 管理 API 密钥（**自己设一个复杂密码**） |
| `CPA_API_KEYS` | ✅ 必填 | - | API 调用密钥，逗号分隔（如 `sk-key1,sk-key2`） |
| `DATA_REPO` | ✅ 必填 | - | 私有数据仓库 URL（如 `https://github.com/你的用户名/cpa-data.git` 或 `https://gitee.com/你的用户名/cpa-data.git`） |
| `GIT_TOKEN` | ✅ 必填 | - | 有数据仓库读写权限的 Git 凭据（GitHub PAT / Gitee 私人令牌等） |
| `CPA_MANAGER_ADMIN_KEY` | ⬜ 可选 | 同 `CPA_MANAGEMENT_KEY` | CPAMP 管理面板管理员密码；一体化部署默认复用 CPA 管理密钥 |

**本镜像强制使用 GitStore 模式：**
- CPA 将认证文件（auths/*.json）和配置（config/config.yaml）自动 commit/push 到该仓库
- CPAMP 的 usage.sqlite 和 data.key 存到同一个 Git 工作树，由 sync-data.sh 同步
- 所有文件都在同一个 Git 仓库里，容器重启自动恢复
- 如果未配置 `DATA_REPO` 或 `GIT_TOKEN`，容器会在启动阶段直接失败，避免误用本地临时存储

其他可选变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `CPA_PROXY` | - | CPA 出站代理（如 `socks5://user:pass@host:1080/`） |
| `CPA_UPSTREAM_URL` | `http://127.0.0.1:8317` | CPAMP 连接 CPA 的地址（容器内无需修改） |
| `SYNC_INTERVAL` | `120` | CPAMP 数据同步检查间隔（秒） |
| `IDLE_TIMEOUT` | `480` | 空闲判定阈值（秒），默认 8 分钟 |
| `DATA_BRANCH` | `main` | 数据仓库分支 |
| `GIT_USERNAME` | `git` | Git 认证用户名；Gitee 通常需要设置为真实用户名 |

5. **点击 "Create Web Service"**

6. **打开 CPAMP 管理面板**：
   打开 `https://你的应用名.onrender.com/management.html`，默认使用 `CPA_MANAGEMENT_KEY` 登录。
   如果你显式设置了 `CPA_MANAGER_ADMIN_KEY`，则使用该值登录。

### 2. 本地构建测试

```bash
# 构建镜像
docker build \
  --build-arg CPA_VERSION=v7.2.26 \
  --build-arg CPAMP_VERSION=v1.7.0 \
  -t cpa-all-in-one .

# 运行
docker run -d \
  --name cpa-test \
  -p 8080:8080 \
  -e CPA_MANAGEMENT_KEY=my-secret-key \
  -e CPA_API_KEYS=sk-demo-key \
  -e DATA_REPO=https://github.com/你的用户名/cpa-data.git \
  -e GIT_TOKEN=github_pat_xxxxx \
  cpa-all-in-one

# 打开管理面板
open http://localhost:8080/management.html
```

## 管理面板配置

### 首次使用（Full Docker 模式）

1. 打开 `https://你的应用名.onrender.com/management.html`
2. 输入 Admin Key：默认就是 `CPA_MANAGEMENT_KEY`；如果显式设置了 `CPA_MANAGER_ADMIN_KEY`，则使用 `CPA_MANAGER_ADMIN_KEY`
3. 设置向导：
   - **CPA URL**：容器内地址填写 `http://127.0.0.1:8317`
   - **CPA Management Key**：填写你在环境变量中设置的 `CPA_MANAGEMENT_KEY` 值
   - **启用请求监控**：勾选
4. 保存后即可使用管理面板

### 后续使用

- 打开 `https://你的应用名.onrender.com/management.html`
- 输入 Admin Key 登录

## 从 GitHub Actions 构建

每次推送代码到 `main` 分支，GitHub Actions 会自动构建并推送镜像到 `ghcr.io`。
另外，定时任务会每 6 小时检查 CPA 和 CPAMP 的 GitHub 最新 Release；只要任一上游发布新版本，就会自动重建并推送新的 `latest` 镜像。

### 手动触发构建指定版本

1. 进入 GitHub 仓库 → Actions → "构建并推送 Docker 镜像"
2. 点击 "Run workflow"
3. 填写 CPA 和 CPAMP 的版本号
4. 等待构建完成

### 使用自定义版本镜像

```bash
# 拉取最新版
docker pull ghcr.io/你的用户名/cliproxyapi-with-plus:latest

# 拉取指定发布版本组合
docker pull ghcr.io/你的用户名/cliproxyapi-with-plus:v7.2.26--v1.7.0
```

## 环境变量参考

### CPAMP 可选变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `CPA_MANAGER_ADMIN_KEY` | 同 `CPA_MANAGEMENT_KEY` | 管理面板管理员密码；通常不用单独设置 |
| `SYNC_INTERVAL` | `120` | 数据同步间隔（秒） |
| `IDLE_TIMEOUT` | `480` | 空闲判定阈值（秒） |
| `DATA_BRANCH` | `main` | 数据仓库分支 |
| `GIT_USERNAME` | `git` | Git 认证用户名；Gitee 通常需要设置为真实用户名 |

### Render 自动设置

| 变量 | 说明 |
|---|---|
| `PORT` | Render 自动设置，Nginx 会监听此端口 |

## 数据持久化注意事项

- **必须配置 `DATA_REPO` 和 `GIT_TOKEN`**：未配置会启动失败，不再提供本地兜底
- **建议使用私有仓库**：SQLite 文件可能包含敏感信息
- **Token 权限最小化**：需要目标数据仓库读写权限
- **首次同步**：数据仓库为空时，CPA GitStore 会初始化 `auths/` 和 `config/`，CPAMP 同步脚本会写入 `usage.sqlite*` 和 `data.key`
- **并发安全**：只有一个容器实例时安全；多实例不适用

## 构建参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `CPA_VERSION` | 最新 Release | CPA 版本标签；Actions 默认自动解析最新 Release，手动触发时可覆盖 |
| `CPAMP_VERSION` | 最新 Release | CPAMP 版本标签；Actions 默认自动解析最新 Release，手动触发时可覆盖 |
| `CPA_COMMIT` | `none` | 构建时自动传入 commit SHA |
| `CPA_BUILD_DATE` | `unknown` | 构建时自动传入时间戳 |

## License

MIT
