# 开发与运行说明

## 1. 模型与演示费率配置

模型提供商为 OpenRouter，Base URL 是 `https://openrouter.ai/api/v1`，后端拼接 `/chat/completions`。默认模型为 `minimax/minimax-m3.1-flash:free`，调用使用 `tools` 参数。应用使用以下演示费率，费用记录与供应商实际扣费分开：

| 计费项目 | USD / 百万 token |
| --- | ---: |
| 普通输入 | 0.50 |
| 输出 | 2.00 |
| 缓存输入 | 0.10 |

页面明确区分演示费用与供应商实扣。费率可在管理页面调整，已有任务继续使用创建时的版本。

## 2. 本机运行与配置维护

依赖：Python 使用 uv；Vue 使用 pnpm。PostgreSQL 使用 Compose 命名持久卷，只绑定 `127.0.0.1`。提交 `uv.lock` 与 `pnpm-lock.yaml`；密钥、运行环境、用户资料及构建产物不进入 Git。

首次启动，在仓库根目录复制 `.env.example` 为 `.env` 并填入 `MODEL_API_KEY`。如果 `.env` 已存在，应直接编辑，避免覆盖已有配置。

```sh
docker compose up -d --wait db
```

在 `backend` 目录：

```sh
uv sync --locked
uv run uvicorn app.main:app --host 127.0.0.1 --port 8000
```

在 `frontend` 目录：

```sh
pnpm install --frozen-lockfile
pnpm dev
```

访问 `http://127.0.0.1:5173`。API 文档为 `http://127.0.0.1:8000/docs`。后端必须仅启动一个应用进程；当前启动恢复逻辑不用于多进程部署。

创建自己的管理员，在 `backend` 运行：

```sh
uv run python -m app.manage create-admin --username admin
```

该命令交互读取密码，不覆盖已有账户，也不将普通用户自动提升为管理员。本次演示账号的用户名和随机密码保存在本机 `.env` 的 `LOCAL_DEMO_USERNAME`、`LOCAL_DEMO_PASSWORD`，不写入本文或 Git。

`.env` 的模型费率仅用于首次初始化。后续在管理员页面修改费率以生成新版本。修改 API Key、Base URL 或超时配置后重启后端。`DATABASE_URL` 可覆盖后端 PostgreSQL 连接；Compose 使用 `POSTGRES_*` 配置。

新增工具时更新执行器的白名单、参数结构及授权入口；新增提供商协议时修改或替换 `ModelClient`，不把供应商逻辑散落到页面或计费模块。新增计费维度时先修改用量映射和 `billing.calculate`，再扩展价格版本与界面。

## 3. HTTP 接口

- 对话：`GET/POST /api/conversations`、`GET /api/conversations/{id}`。
- 发消息：`POST /api/conversations/{id}/messages`，表单包含消息、模型、预算和可选附件及权限。
- 注册 / 登录：`POST /api/auth/register`、`login`、`logout`；`GET /api/auth/me`。
- 用户模型目录：`GET /api/models`。
- 单轮执行：`GET /api/tasks/{id}`、`POST /api/tasks/{id}/cancel`。
- 工具授权：`PUT /api/tasks/{id}/grants/{tool}`。
- 管理模型：`GET/POST /api/admin/models`、`PUT /api/admin/models/{id}`。
- 待核实与补录：`GET /api/admin/unresolved`、`POST /api/admin/calls/{id}/reconcile`。

API 完整参数及响应结构见运行中的 `/docs`。`GET/POST /api/tasks` 为兼容入口，聊天页面使用对话消息接口。

## 4. 数据库初始化与迁移

启动统一调用 `initialize_database`：创建缺失表、迁移旧对话结构、执行 `db/migration.sql` 补齐 CHECK 与索引。管理员初始化也走同一路径。可在 backend 目录先单独执行：

```sh
uv run python -m app.schema
```

迁移前备份数据库。若历史数据违反约束，迁移和应用启动会报错；先根据约束名核对数据，不自动删除或修正账目。SQL 脚本必须随仓库部署。正常启动与迁移均只支持一个应用进程。

## 5. 验证

验证重点：真实模型多轮问答、历史上下文、同对话附件复用与跨对话隔离、旧数据迁移、真实模型摘要与审核、用户隔离、PDF/TXT 解析、预算超额停止、授权撤销、用户停止后的在途计费、价格版本固定、未知用量及重复补录、服务中断恢复。内部测试使用隔离 PostgreSQL schema，并只在 HTTP transport 处替换供应商，测试数据不会混入用户任务。

## 6. 部署配置

本机开发使用 HTTP。公开部署需配置 HTTPS、Secure cookie、可信来源和部署级访问控制。


## 7. 可复现数据库回归测试

在 PostgreSQL 17 创建一个专用的空测试数据库（例如 agent_ledger_test），以有建 schema 权限的测试账号设置环境变量；不要使用生产数据库或把密码提交到 Git：

```sh
# 用你自己的测试连接替换占位符；不要原样运行。
export TEST_DATABASE_URL='postgresql+psycopg://TEST_USER:TEST_PASSWORD@127.0.0.1:5432/agent_ledger_test'
cd backend
uv sync --locked
uv run python -m pytest -q
```

未设置 TEST_DATABASE_URL 时数据库测试会明确 skip，不能把 skip 当作验证通过。每项测试创建随机 schema 并在结束时删除它；不会读取 `.env` 中的模型密钥或调用真实供应商。模型只在 HTTP transport 边界替换，API、鉴权、后台执行与 PostgreSQL 事务仍真实运行。

测试包含 SQL/应用两种初始化路径的命名 CHECK 和查询索引比较、重复迁移、旧版无对话表升级、脏数据阻止升级、账目联合约束、事务回滚、历史价格和并发幂等、同对话并发发送、用户隔离、CSRF、缺失用量以及重启恢复。`db/verification.sql` 是现存数据的只读审计，不能代替这些负例和并发测试。

本机可使用 DeepSeek 等 OpenAI 兼容服务：在 `.env` 设置 MODEL_BASE_URL、MODEL_API_KEY、MODEL_NAME 后重启。更换提供商时应停用旧提供商模型，保留历史记录。页面费用仍按配置的演示费率计算，不等于供应商扣费。
