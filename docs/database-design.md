# Agent Desk 数据库设计与实现（2 号交付）· v1.2

## 0. 交付清单

| 交付项 | 文件 | 内容 |
| --- | --- | --- |
| ER 图 | 本文第 2 节 | 13 张实体的关系、基数与外键；v1.2 快照与必填授权 |
| ER 图预览 / 图片 | `docs/er-diagram.html`、`docs/er-diagram.png` | 概览 / 完整 / 跨模块三视图 |
| 表结构 | `db/schema.sql`、本文第 3 节 | PostgreSQL 17 DDL、字段、约束、索引 |
| 样例数据 | `db/sample-data.sql` | 3 用户（含管理员） / 3 模型 / 4 轮次 / 6 次调用，覆盖完成、超预算、待核实、已停止 |
| 业务 SQL | `db/business-queries.sql` | 对话列表、轮次详情、费用汇总、待核实队列等 12 条 |
| 事务与扣费逻辑 | `db/transactions.sql`、本文第 6 节 | 6 个关键事务、扣费公式、软预算、幂等补录、启动恢复 |
| 数据库补齐迁移 | `db/migration.sql`、本文第 9 节 | 对 `create_all` 建立的库补齐枚举 CHECK 与复合索引 |
| v1.2 变更迁移 | `db/migration_v1_2.sql`、本文第 14 节 | 快照回填、归属触发器、授权必填；含硬前置断言 |
| 验收自查 SQL | `db/verification.sql`、本文第 10 节 | V1–V10 原断言 + V11–V16 v1.2 专项断言 |

后端接口协同与本文的对应关系见第 7 节。本文是数据库设计的统一说明，不替代 spec 的行为定义。

## 1. 设计依据与范围

依据 `ARCHITECTURE.md` 与 `spec/*.md`：

- 对话是上下文与资料隔离边界；一轮消息对应一个 `tasks` 行，固定模型价格版本、预算与工具授权。
- 费用按模型实际返回的 token 和**本次调用保存的费率快照**计算，历史账目不随现价或目录状态变化（v1.2，第 14 节）。
- 用量未知时费用为 `NULL`，禁止记 0 或估算值。
- 实现套餐与订阅有效期，不实现充值、积分、周期额度和真实支付结算；调用计费是**用量账目**，不是资金账户。

因此本设计没有 `wallets` / `balances` / `payments` 表。用户要求的“扣费逻辑”对应的是**调用成功后原子写入一次费用记录**，以及按轮累计判断软预算，而不是从余额扣减。

## 2. ER 图

```mermaid
erDiagram
    direction LR

    USERS ||--o{ SUBSCRIPTIONS : "subscribes"
    PLANS ||--o{ SUBSCRIPTIONS : "plan source"
    SUBSCRIPTIONS |o--o{ TASKS : "entitles tasks"
    PLANS {
        string id PK
        string code UK
        int duration_days
        decimal display_price
        boolean enabled
    }
    SUBSCRIPTIONS {
        string id PK
        string user_id FK
        string plan_id FK
        string plan_name
        decimal display_price
        timestamp starts_at
        timestamp ends_at
        string status
        timestamp cancelled_at
    }
    USERS ||--o{ SESSIONS : "starts session"
    USERS ||--o{ CONVERSATIONS : "owns"
    USERS ||--o{ TASKS : "initiates"
    USERS |o--o{ MODEL_CALLS : "reconciles"
    CONVERSATIONS ||--o{ TASKS : "contains tasks"
    MODELS ||--o{ MODEL_PRICES : "price versions"
    MODEL_PRICES ||--o{ TASKS : "locks default price"
    MODEL_PRICES ||--o{ MODEL_CALLS : "prices each call"
    TASKS ||--o{ MATERIALS : "uploads materials"
    TASKS ||--o{ TASK_TOOL_GRANTS : "grants tools"
    TASKS ||--o{ AGENT_RUNS : "runs"
    AGENT_RUNS |o--o{ AGENT_RUNS : "delegates sub-role"
    AGENT_RUNS ||--o{ MODEL_CALLS : "model calls"
    AGENT_RUNS ||--o{ TOOL_CALLS : "tool calls"
    TASK_TOOL_GRANTS ||--o{ TOOL_CALLS : "authorization basis"

    USERS {
        string id PK
        string username UK
        string password_hash
        string role
    }
    SESSIONS {
        string id PK
        string user_id FK
        string token_hash UK
        string csrf_token
        timestamp expires_at
    }
    MODELS {
        string id PK
        string name UK
        string display_name
        boolean enabled
    }
    MODEL_PRICES {
        string id PK
        string model_id FK
        int version
        string currency
        decimal input_rate
        decimal output_rate
        decimal cached_rate
    }
    CONVERSATIONS {
        string id PK
        string user_id FK
        string title
        timestamp updated_at
    }
    TASKS {
        string id PK
        string conversation_id FK
        string user_id FK
        string subscription_id FK
        string price_id FK
        text instruction
        decimal budget
        string status
        text result
    }
    MATERIALS {
        string id PK
        string task_id FK
        string name
        string kind
        text content
    }
    TASK_TOOL_GRANTS {
        string id PK
        string task_id FK
        string tool
        timestamp expires_at
        timestamp revoked_at
    }
    AGENT_RUNS {
        string id PK
        string task_id FK
        string parent_id FK
        string role
        string status
        text output
    }
    MODEL_CALLS {
        string id PK
        string run_id FK
        string price_id FK
        string currency
        decimal input_rate_snapshot
        decimal output_rate_snapshot
        decimal cached_rate_snapshot
        string rate_unit
        string status
        string usage_status
        int input_tokens
        int output_tokens
        int cached_tokens
        decimal cost
        json raw_usage
        string reconciled_by FK
    }
    TOOL_CALLS {
        string id PK
        string run_id FK
        string grant_id FK
        string tool
        json arguments
        string status
    }
```

Entities are laid out left to right: identity and subscriptions → conversations and turns → resources and grants → execution and billing. One TASKS row represents one conversation turn. In v1.2 every MODEL_CALLS row carries its own price_id and rate snapshot, so historical bills do not depend on the current catalog or on later edits to agent pricing. tasks.user_id is retained as a deliberate redundancy (the subscription composite FK depends on it) and is enforced by trigger trg_tasks_owner. Every TOOL_CALLS row has a mandatory grant_id.

关系要点（v1.2）：

- `model_calls.price_id → model_prices`：单价优先取 `agent_runs.price_id`，否则回退任务默认价；快照登记后不变，补录按快照结算。
- `tasks.conversation_id` 容许为空，用于兼容迁移前创建的旧轮次；新轮次必须属于对话。
- `tasks.user_id` 保留冗余值：订阅复合外键 `(subscription_id, user_id)` 依赖该列；`trg_tasks_owner` 在写入时强制其等于 `conversations.user_id`。
- `agent_runs.parent_id` 自关联只允许协调者委派摘要 / 审核角色，不能递归创建角色。
- `task_tool_grants ||--o{ tool_calls`：授权必填；委派工具挂 EXEC-01 预定义角色授权行，资料工具的拒绝记录也挂显式拒绝行。

## 3. 表结构

### 3.1 总览

| 表 | 用途 | 关键唯一 / 检查约束 |
| --- | --- | --- |
| `users` | 账号与角色 | `username` 唯一；`role IN ('user','admin')` |
| `sessions` | 服务端会话与 CSRF | `token_hash` 唯一；`expires_at` |
| `models` | 模型目录 | `name` 唯一；`enabled` |
| `model_prices` | 不可变价格版本 | `(model_id, version)` 唯一；费率非负 |
| `conversations` | 对话 | `user_id` 索引；`updated_at` 索引 |
| `tasks` | 一轮消息 / 执行 | `budget > 0`；9 种状态；`user_id` 冗余由 `trg_tasks_owner` 强制 |
| `materials` | TXT / PDF / 粘贴文本 | `kind IN ('text','txt','pdf')` |
| `task_tool_grants` | 每轮每工具授权决策 | `(task_id, tool)` 唯一；4 工具白名单（含委派角色） |
| `agent_runs` | 协调 / 摘要 / 审核执行 | 角色与状态枚举；`parent_id` 自关联 |
| `model_calls` | 调用与用量账目 | v1.2 价格版本 + 费率快照必填；`cost >= 0` 或 `NULL` |
| `tool_calls` | 资料工具 / 委派审计 | 状态枚举；`grant_id` 必填且归属同一轮 |

主键统一 `VARCHAR(36)`（UUID 字符串），时间统一 `TIMESTAMPTZ`（UTC），金额统一 `NUMERIC(24,12)`。完整 DDL 见 `db/schema.sql`。

### 3.2 字段明细

**users**：`id` PK、`created_at`、`username` UK、`password_hash`（Argon2id PHC）、`role`（user/admin）。

**sessions**：`id` PK、`created_at`、`user_id` FK→users、`token_hash` UK（令牌 SHA-256，不明文）、`csrf_token`、`expires_at`。

**models**：`id` PK、`created_at`、`name` UK（供应商标识，创建后不可改）、`display_name`、`enabled`。

**model_prices**：`id` PK、`created_at`、`model_id` FK→models、`version`、`currency`（3 位字母）、`input_rate`、`output_rate`、`cached_rate`（可空）、`source_url`、`billing_note`；费率单位 USD/百万 token。

**conversations**：`id` PK、`created_at`、`user_id` FK→users、`title`（首条消息生成）、`updated_at`。

**tasks**：`id` PK、`created_at`、`conversation_id` FK→conversations（可空）、`user_id` FK→users（v1.2 保留的冗余字段，由 `trg_tasks_owner` 强制等于对话归属）、`subscription_id`、`price_id` FK→model_prices（本轮默认价）、`execution_mode`、`title`、`instruction`、`budget`、`status`、`result`、`reason`、`finished_at`。

**materials**：`id` PK、`created_at`、`task_id` FK→tasks、`name`、`kind`（text/txt/pdf）、`content`（提取全文）。

**task_tool_grants**：`id` PK、`created_at`、`task_id` FK→tasks、`tool`（read_material / search_materials / delegate_summary / delegate_review）、`expires_at`、`revoked_at`。未选资料工具也保留一行，`revoked_at` 非空表示显式拒绝。

**agent_runs**：`id` PK、`created_at`、`task_id` FK→tasks、`parent_id` FK→agent_runs（可空）、`role`（coordinator/summary/review）、`status`、`instruction`、`output`、`finished_at`。

**model_calls**：`id` PK、`created_at`、`run_id` FK→agent_runs、`price_id` FK→model_prices（本次调用实际版本）、`currency`、三项费率快照、`rate_unit`（固定 `per_1m_tokens`）、`provider_request_id`、`status`、`usage_status`、`input_tokens`、`output_tokens`、`cached_tokens`、`cost`（NULL=未知）、`raw_usage` JSON、`response_text`、`error`、`reconciled_by` FK→users、`evidence`、`reconciled_at`、`finished_at`。

**tool_calls**：`id` PK、`created_at`、`run_id` FK→agent_runs、`grant_id` FK→task_tool_grants（**必填**）、`tool`、`arguments` JSON、`status`（completed/denied/failed）、`output`。

### 3.3 索引设计

| 索引 | 支撑的查询 |
| --- | --- |
| `ix_conversations_user_id`、`ix_conversations_updated_at` | 用户对话列表按最近更新排序 |
| `ix_tasks_conversation_id`、`ix_tasks_conv_created(conversation_id, created_at, id)` | 对话时间线、同对话历史上下文 |
| `ix_tasks_user_id`、`ix_tasks_status` | 用户任务列表、执行器扫描、互斥检查 |
| `ix_model_prices_model_id` | 查询最新价格版本 |
| `ix_materials_task_id`、`ix_task_tool_grants_task_id` | 资料目录与授权检查 |
| `ix_agent_runs_task_id`、`ix_agent_runs_parent_id` | 单轮执行详情、委派链 |
| `ix_model_calls_run_id`、`ix_model_calls_status`、`ix_model_calls_price_id` | 费用汇总、待核实队列、启动恢复、按价格版本追溯 |
| `ix_tool_calls_run_id`、`ix_tool_calls_grant_id` | 工具审计展示、按授权依据反查 |

### 3.4 关键约束与设计取舍

- **价格不可变**：没有 `UPDATE model_prices` 的业务路径；改价插入新 `version`，唯一约束防止并发生成重复版本。v1.2 起每次调用另存费率快照，历史账目不再依赖该表。
- **v1.2 调用快照**：`price_id` / 币种 / 三项费率 / `rate_unit` 在登记在途调用时复制，补录按快照计费；`rate_unit` 固定 `per_1m_tokens`，与 `billing.py` 的 `/1_000_000` 一致。
- **v1.2 归属不变量**：`tasks.user_id` 因订阅复合外键不能删除，`trg_tasks_owner` 在 INSERT / UPDATE 时强制其等于 `conversations.user_id`，把原来的应用层约定升级为数据库约束（V6 / V16）。
- **v1.2 授权必填**：`tool_calls.grant_id NOT NULL` 且授权行属于同一轮；委派工具使用 EXEC-01 预定义角色授权行。
- **费用与用量状态联合约束**：`ck_model_calls_usage_complete` 强制 unknown 的费用为 NULL，known 的输入、输出、缓存 token 与费用全部非空；再由非负和缓存子集 CHECK 校验数值。仅有 `cost >= 0` 不能阻止未知费用被记为 0。
- **缓存 token 是输入子集**：`cached_tokens <= input_tokens` 由 CHECK 保证，计费公式不再重复相加。
- **金额用 NUMERIC 不用 float**：`Decimal(24,12)` 对应前端十进制字符串，避免累计误差。
- **不做资金余额表**：业务只记录费用账目；“扣费”是幂等的调用结算，不是账户扣款。

## 4. 样例数据

`db/sample-data.sql` 使用固定 ID，覆盖以下场景：

| 样例 | 说明 |
| --- | --- |
| `t-alice-1` / `call-01~03` | 完整完成的一轮：协调 + 摘要 + 审核，费用 0.00228 USD |
| `t-alice-2` / `call-04` | 软预算 0.0005，最后一次调用记 0.0014，任务 `stopped_budget` |
| `t-alice-3` / `call-05` | 网络中断，`cost = NULL`，任务 `awaiting_usage`，授权已过期 |
| `t-bob-1` / `call-06` | 用户停止 + 供应商明确拒绝，记已知零用量失败调用 |
| `p-minimax-v1/v2` | 同一模型两个价格版本，旧轮次仍引用 v1 |
| `tc-05/06/07` | 分别演示授权撤销、授权过期、未获授权的工具拒绝 |

样例密码哈希是占位字符串，仅用于展示字段形态，不能用于登录。

## 5. 业务 SQL

`db/business-queries.sql` 提供以下查询，参数用 `$1`、`$2` 占位，由应用绑定：

| 编号 | 查询 | 用途 |
| --- | --- | --- |
| Q1 | 用户对话列表 | 首页侧栏，按 `updated_at` 倒序 |
| Q2 | 对话时间线 | 一轮一条，含状态、费用小计 |
| Q3 | 单轮执行详情 | runs + 委派链 |
| Q4 | 单轮调用账目 | 逐次 token、费用、错误、补录依据 |
| Q5 | 单轮费用汇总 | 已知小计 + 未知调用数 |
| Q6 | 发送前互斥检查 | 活跃轮次 + 在途调用 |
| Q7 | 授权有效性检查 | 判断 `revoked_at` / `expires_at` |
| Q8 | 待核实队列 | 管理员补录入口 |
| Q9 | 价格版本历史 | 管理端展示改价轨迹 |
| Q10 | 用户累计费用 | 按模型与币种汇总 |
| Q11 | 对话内资料目录 | 模型可见的附件清单 |
| Q12 | 工具调用审计 | 区分成功、拒绝、失败 |

所有查询都带用户归属过滤（`user_id = $1`），管理员通过普通任务接口访问时也受同样约束。

## 6. 事务与扣费逻辑

### 6.1 加锁顺序总表

统一顺序：**对话行 / 任务行 → 授权行 / 调用行**。禁止反向加锁，避免死锁。

| 场景 | 加锁顺序 | 目的 |
| --- | --- | --- |
| 创建新一轮 | `conversation` FOR UPDATE | 同对话互斥，校验上一轮已结算 |
| 领取执行权 | `task` FOR UPDATE | 只有 `pending` 能转 `running`，只领取一次 |
| 调用前检查 | `task` FOR UPDATE | 预算与未知用量判定有稳定时点 |
| 响应结算 | `task` → `model_call` | 用量、费用、状态一次写入 |
| 工具执行 / 授权修改 | `task` → `task_tool_grant` | 每次读取有明确的授权判断时点 |
| 管理员补录 | `task` → `model_call` | 幂等，且不覆盖已确认账目 |

**关键原则**：任何数据库锁都不跨外部 HTTP 模型请求。发出请求前短事务提交 `in_flight` 记录，响应回来后另开事务结算。

### 6.2 六个关键事务

参数化事务步骤见 `db/transactions.sql`（分支判断及参数绑定由应用执行，不能直接整文件作为独立事务运行），这里给出要点：

1. **创建一轮**：锁对话 → 检查 `status IN ('pending','running')` 的轮次与 `in_flight` 调用 → 取模型最新价格版本 → 插入 `tasks` / `materials` / `task_tool_grants` → 更新对话标题与 `updated_at` → 提交后才启动后台执行。
2. **领取执行权**：`SELECT ... FOR UPDATE` 任务，`status = 'pending'` 才置 `running`；重复领取直接返回。
3. **调用前登记**：短事务锁任务并检查“是否存在 `usage_status='unknown'` 的调用”和“已知费用是否已达预算”，通过后插入 `model_calls(status='in_flight', usage_status='unknown')`，提交，然后调用供应商。
4. **响应结算**：同事务写入 `raw_usage` / token / `cost` / `status` / `usage_status`；费用按**本调用快照**（优先 `agent_runs.price_id`）计算，只有一行调用记录，不另生成账单。用量非法或缺失时 `cost` 保持 `NULL`、状态置 `usage_unknown`，任务转 `awaiting_usage`。
5. **工具执行**：锁任务 → 锁授权行 → 判断撤销与到期 → 读取当前对话资料 → 写 `tool_calls`。任一项不满足即记录 `denied` 并停止本轮。
6. **管理员补录**：锁任务 → 锁调用行；`usage_status='known'` 直接返回原费用（`already_reconciled=true`）；`status <> 'usage_unknown'` 拒绝；否则按**该调用自身的费率快照**计算并写入 token、费用、操作者、依据、时间。若该轮全部未知项已确认，把 `awaiting_usage` 改为 `interrupted`，不自动续跑。

### 6.3 扣费公式与精度

```
费用 = ((输入 token − 缓存 token) × 输入单价
        + 缓存 token × 缓存单价
        + 输出 token × 输出单价) / 1,000,000
```

- 缓存 token 是输入子集，不重复计费；推理 token 已含在供应商输出计数中时不另加。
- 计算使用 `Decimal`，存储 `NUMERIC(24,12)`，传输用十进制字符串。
- 以下情况**不得按 0 结算**：usage 缺失、计数非法、缓存计数 > 输入计数、有缓存 token 但价格版本 `cached_rate IS NULL`。这些情况 `cost = NULL`，任务进入 `awaiting_usage`。
- 供应商明确拒绝（4xx）可确定未产生用量，记已知 `0` 费用的失败调用；超时、5xx、响应格式异常一律待核实，不自动重试。

### 6.4 软预算

预算是**停止阈值**，不是预付额度：

- 每次调用前检查本轮已知费用合计 `SUM(cost) >= budget` 则不再发起新调用。
- 最后一次调用允许超额。若该调用已形成完整最终回复，任务可 `completed`；否则置 `stopped_budget`。
- 存在任何 `usage_status='unknown'` 的调用时优先停止，状态为 `awaiting_usage`。

### 6.5 幂等与并发

- 一次模型调用只有一条 `model_calls` 记录；请求前创建、响应后更新，不插入第二条“账单行”。
- 补录以 `usage_status='known'` 为幂等标记，重复提交返回原费用，不改已确认账目。
- 价格版本 `(model_id, version)` 唯一，并发改价只有一个成功。
- 授权 `(task_id, tool)` 唯一，并发撤销 / 开启作用于同一行。
- 同对话通过行锁串行；不同对话可并发。

### 6.6 启动恢复

服务重启时单事务处理：

- `model_calls.status = 'in_flight'` → `usage_unknown`，关联任务 → `awaiting_usage`（用量可能已产生）。
- 其余 `tasks.status IN ('pending','running')` → `interrupted`，`agent_runs.status='running'` → `interrupted`。
- 恢复逻辑不重发模型请求，不清除已确认费用。

## 7. 后端接口协同（2 号与 3 号）

### 7.1 模块与代码的对应

| 设计项 | 现有代码位置 | 状态 |
| --- | --- | --- |
| 实体与 ORM 映射 | `backend/app/entities.py` | 已实现 13 张表；本文 DDL 额外补枚举 CHECK 与复合索引 |
| 建表与兼容迁移 | `backend/app/main.py`、`backend/app/schema.py` | `create_all` + `upgrade_conversations` 增加 `conversation_id` |
| 费用计算 | `backend/app/billing.py` | `calculate()` 已实现 Decimal 公式与 `UnknownUsage` |
| 执行与事务 | `backend/app/execution.py` | 6 个事务的加锁顺序已实现 |
| 创建轮次 / 授权 / 查询 | `backend/app/workspaces.py` | 对话互斥、授权变更、详情查询 |
| 补录 | `backend/app/admin.py` | 幂等补录与待核实队列 |
| 模型与价格版本 | `backend/app/catalog.py` | 改价生成新版本 |

### 7.2 接口到数据表与事务的映射

下表是“后端接口由 2 号和 3 号协同完成”的逐项核查依据。前端只经这些接口访问数据库，不直接读写表；每行给出接口涉及的读写表、对应的事务或业务 SQL、以及数据库层必须守住的一致性要点。

**账号与会话**（`auth.py`）

| 接口 | 读写表 | 对应事务 / SQL | 一致性要点 |
| --- | --- | --- | --- |
| `POST /api/auth/register` | `users` INSERT；`sessions` INSERT | 单事务 | `username` 唯一；客户端角色不生效，`role` 只能为 `user` |
| `POST /api/auth/login` | `users` SELECT；`sessions` INSERT | 单事务 | 凭据错误不建立会话 |
| `GET /api/auth/me` | `sessions` + `users` SELECT | 只读 | 仅 `expires_at > now()` 的会话有效 |
| `POST /api/auth/logout` | `sessions` DELETE | 单事务 | 只删除当前会话 |

**模型与价格**（`catalog.py`）

| 接口 | 读写表 | 对应事务 / SQL | 一致性要点 |
| --- | --- | --- | --- |
| `GET /api/models` | `models` + `model_prices` SELECT | Q9 取最新价 | 只返回 `enabled = true` 的模型 |
| `GET /api/admin/models` | 同上（含停用） | Q9 | 管理员权限 |
| `POST /api/admin/models` | `models` + `model_prices`（v1）INSERT | 辅助 B | `(model_id, version)` 唯一；首个版本为 1 |
| `PUT /api/admin/models/{id}` | `models` UPDATE；新 `model_prices` INSERT | 辅助 B | 供应商标识不可改；改价追加版本，不覆盖历史 |

**对话与轮次**（`workspaces.py`）

| 接口 | 读写表 | 对应事务 / SQL | 一致性要点 |
| --- | --- | --- | --- |
| `GET /api/conversations` | `conversations` SELECT | Q1 | `user_id` 过滤，按 `updated_at` 倒序 |
| `POST /api/conversations` | `conversations` INSERT | 单事务 | `title` 初值为“新对话” |
| `GET /api/conversations/{id}` | `conversations` + `tasks` + 明细 | Q2、Q3、Q4、Q11、Q12 | `user_id` 过滤，逐轮返回执行与费用 |
| `POST /api/conversations/{id}/messages` | `tasks`、`materials`、`task_tool_grants` INSERT | T1 | 锁对话；活跃轮次或在途调用存在时拒绝 |
| `GET /api/tasks` | `tasks` + `model_calls` | Q5 | 兼容入口；仍按 `user_id` 过滤 |
| `POST /api/tasks` | 同消息接口 | T1 | 兼容入口；聊天页使用对话消息接口 |
| `GET /api/tasks/{id}` | `tasks`、`agent_runs`、`model_calls`、`tool_calls`、`materials`、授权 | Q3、Q4、Q11、Q12 | 单轮详情；角色中间输出与最终回复分开 |
| `POST /api/tasks/{id}/cancel` | `tasks` UPDATE | 辅助 A | 在途调用不置为失败，响应回来仍结算 |
| `PUT /api/tasks/{id}/grants/{tool}` | `task_tool_grants` UPSERT | T5 授权段 | 锁任务 → 授权行；到期时间须为未来 |

**管理与补录**（`admin.py`）

| 接口 | 读写表 | 对应事务 / SQL | 一致性要点 |
| --- | --- | --- | --- |
| `GET /api/admin/unresolved` | `model_calls` + `tasks` + `users` + `model_prices` | Q8 | 仅管理员；返回补录所需原价格费率 |
| `POST /api/admin/calls/{id}/reconcile` | `model_calls` + `tasks` UPDATE | T6 | 锁任务 → 调用行；已确认调用幂等返回，不重复计费 |

**协同边界**：接口层负责身份、权限与参数校验，事务脚本负责加锁顺序与状态流转，数据库约束负责最终兜底（枚举、唯一、非空、非负）。三者不重复计算费用：金额只在 `billing.calculate()` 中按固定价格版本计算一次，接口只读取 `model_calls.cost`。若以 `db/schema.sql` 初始化数据库（而非 `create_all`），枚举 CHECK 会生效；已有库按第 9 节迁移补齐。

## 8. 验收对照

| spec 条款 | 数据库层面的支撑 |
| --- | --- |
| ACC-01/03/04/05 | `users` 唯一约束、`role` CHECK、全表 `user_id` 过滤、`token_hash` 不明文 |
| MODEL-01/02/03/04 | `models.name` 唯一 / `enabled`、`model_prices` 版本唯一与非负 CHECK |
| MAT-02/04/05 | `materials` 归属 + `task_tool_grants` 有效期 / 撤销字段、`tool_calls` 审计 |
| EXEC-03/04/08 | `tasks.status` 与 `agent_runs.status` 枚举、`model_calls.status` 枚举 |
| BILL-01/02/03/06/07 | `model_calls` 全字段、`cost` 可空、补录审计字段、`usage_status` 幂等标记 |

## 9. 数据库初始化与迁移

### 9.1 初始化路径

| 场景 | 方式 | 结果 |
| --- | --- | --- |
| 全新数据库 | 执行 `db/schema.sql` | 13 张表 + 全部枚举 CHECK + 复合索引一次到位 |
| 现有 `create_all` 库 | 执行 `db/migration.sql`，再执行 `db/migration_v1_2.sql` | 保留全部数据，补齐 CHECK / 索引并升级到 v1.2 |
| 旧版无 `conversations` 的库 | `main.py` 启动时调用 `upgrade_conversations` | 增加 `tasks.conversation_id` 并接入旧任务 |

`db/schema.sql` 与 `backend/app/entities.py` 字段一一对应，主键、金额精度与 UTC 时间口径一致；差别只在 DDL 额外声明了枚举与业务 CHECK。应用侧写入的枚举值均在约束范围内，因此迁移不改变现有代码行为。

### 9.2 迁移顺序

1. 备份数据库。
2. 执行 `db/verification.sql` 的 V1–V9，确认无异常行；存在脏数据时先清洗。
3. 执行 `db/migration.sql`。DO 块按约束名判重，重复执行不会报错。
4. 再跑一次 V1–V9，确认约束生效且历史数据仍可查询；`db/sample-data.sql` 只导入独立演示或测试库，不导入已有用户数据的数据库。
5. v1.2 库执行 `db/migration_v1_2.sql`：硬前置断言 → 回填快照 → 建归属触发器 → 授权必填。
6. 迁移不修改 `model_prices` 任何已有行；改价仍只追加新版本。V12 有行说明历史费率被改写，需人工核对。

Compose 启动与依赖安装见 `DEVELOPMENT.md`，本文不重复运行步骤。

## 10. 验收自查

`db/verification.sql` 把第 8 节 spec 条款与 v1.2 变更落到可执行断言。V1–V9、V11–V16 均应返回 0 行；V10 返回的行表示软预算允许的最后一次超额，不是错误。

| 编号 | 检查内容 | 预期 |
| --- | --- | --- |
| V1 | 未知用量调用不得写入费用 | 0 行，`cost` 保持 `NULL` |
| V2 | 已知用量调用的 token 与费用完整 | 0 行 |
| V3 | 缓存 token 是输入 token 的子集 | 0 行 |
| V4a / V4b | `awaiting_usage` 有未确认调用；`completed` 无未确认调用 | 0 行 |
| V5a / V5b | 任务引用存在的价格版本；价格版本归属存在的模型 | 0 行 |
| V6 | 任务与对话同属一个用户 | 0 行 |
| V7 | 无孤立的执行、调用、工具、资料与授权记录 | 0 行 |
| V8 | 授权与价格版本唯一约束复核 | 0 行 |
| V9 | 预算为正 | 0 行 |
| V10 | 已知费用超过预算的轮次 | 允许有行，对应 BILL-04 |
| V11 | 调用快照完整、币种与单位合法 | 0 行 |
| V12 | 快照与所引用价格版本一致 | 0 行 |
| V13 | 工具调用授权必填且属于同一轮 | 0 行 |
| V14 | 委派 / 资料工具与授权类型匹配 | 0 行 |
| V15 | 已知费用等于按快照复算的结果 | 0 行 |
| V16 | 归属触发器与函数存在且启用 | 0 行 |

数据库断言只覆盖 2 号可观测的一致性；业务流程正确性仍由 1 号按 spec 验收标准整体测试与验收，两者衔接处是：V1–V9 通过后，再按 `DEVELOPMENT.md` 第 5 节的验证重点执行端到端流程。


## 11. 统一启动与回归验证（2026-11-28）

应用启动及创建管理员都调用 `initialize_database`：创建缺失表、兼容旧对话结构、再执行同一份 `db/migration.sql`。也可先运行 `uv run python -m app.schema`。迁移按事务执行并使用当前 schema 的 advisory lock，发现违反新约束的旧数据时失败，不把未知费用自动改成 0，也不删除旧账。应用仍限定单进程部署。

`schema_translate_map` 对应的测试 schema 同时用于 ORM 和显式 SQL，避免测试操作落入 public。迁移目录必须随应用一起部署。约束与索引的一致性通过 PostgreSQL 系统目录比较；这不声称两种初始化路径所有服务端默认值完全相同。ORM 写入继续提供 Python 默认值。

回归入口及环境见 `DEVELOPMENT.md`。测试覆盖直接非法 SQL、合法零用量、重复初始化、旧结构迁移、脏数据阻断、原子回滚、并发补录、历史价格固定、重复补录不覆盖、并发发消息互斥、用户隔离、CSRF、未知用量和恢复不重发。测试模型通过 HTTP transport 模拟，不消费真实 API。

## 12. 关系设计与理论依据

- `users.id → username, password_hash, role`，username 也是候选键；`models.name` 与主键均可唯一识别模型。
- `model_prices.id → model_id, version, currency, rates`，`(model_id, version)` 是另一候选键。版本价格单独建表，防止现价更新覆盖任务的历史定价。
- `task_tool_grants.(task_id, tool) → expires_at, revoked_at`，通过复合唯一约束确保每轮每工具只有一份授权。
- 用户、模型价格、工具授权在这些已声明依赖下不存在非键属性对候选键的部分或传递依赖；技术主键本身不构成“所有表自动满足 3NF”的证明。
- `tasks` 对新轮次同时保存 conversation_id 与 user_id，而 conversation_id 决定所属用户，属于有意保留的归属冗余。当前一致性由接口写入和 V6 审计保证，普通单列外键不会阻止跨用户组合；因此不能宣称该冗余完全由数据库约束保护。未来可移除冗余或增加复合归属外键。
- `model_calls.cost` 是依据历史价格与 token 推导的账目快照。保存结果有利于审计，但与原始用量之间的公式一致性仍由计费函数与测试保证，不能仅靠非负 CHECK 证明。
- 原子性：一次补录的用量、费用、操作者和任务状态在同一事务提交；失败回滚。并发控制：同一对话创建新轮次先锁对话；补录先锁任务再锁调用；外部 HTTP 期间不持有数据库锁。
- `NULL` 表达“尚不可确认”，已知零费用是不同事实。汇总必须同时展示已知小计和未知调用数，不能将 `COALESCE(SUM(cost),0)` 单独解释成最终总账。


## 13. 套餐与订阅实现

新增 `plans` 和 `subscriptions` 两张表。套餐候选键为 id/code；duration_days > 0，display_price >= 0。订阅保存 user_id、plan_id、开通时名称/展示价/币种、UTC 起止时间、状态和取消时间；ends_at > starts_at，取消状态必须有取消时间。套餐展示价仅用于课程业务演示，不产生付款记录。

部分唯一索引 `uq_subscriptions_active_user` 确保每用户最多一条 active 记录。到期可由结束时间派生，续订先将到期记录置 expired 后插入新行。业务锁用户行保证重复/并发开通返回同一有效订阅，而非延长有效期；不同套餐在有效期内返回冲突。

新任务关联 subscription_id，并通过 `(subscription_id,user_id)` 复合外键保护归属。旧任务保持 NULL，无虚构的历史订阅。SQL 建库脚本包含同一 DDL；应用启动先执行 `db/subscriptions.sql` 再读取旧任务，重复迁移安全。

接口：GET /api/plans、GET /api/subscriptions、POST /api/subscriptions、POST /api/subscriptions/{id}/cancel。所有接口要求登录，写操作沿用 CSRF；订阅历史和取消按当前用户过滤。管理员同样需有效订阅才能发新任务。

新任务事务锁顺序为用户 → 对话 → 其他记录。取消只锁用户并更新订阅，不更改已接纳任务；用量补录仍按原任务/调用行锁顺序执行。订阅展示价与 token 费用分别展示，不能相加为真实收款。

## 2026-11-28 团队扩展（当前结构）

当前为 15 表：原 13 表加 agents、task_agents。用户 1:N agents，模型 1:N agents；任务 1:N task_agents，Agent 1:N task_agents，价格版本 1:N task_agents；task_agents 1:N agent_runs（实现当前每个选定成员一次执行），价格版本 1:N agent_runs。agent_runs.task_agent_id 可空用于协调者和内置角色。tasks.execution_mode 限定串行或并行。

agents 由 id 决定 owner/model/name/instruction/enabled；task_agents 有候选键 id、(task_id,agent_id)、(task_id,position)。快照 name/instruction 描述当次接纳配置，不依赖可变的当前 Agent 属性，因此保留历史而非同步冗余。task_agents.price_id 固定接纳价格，agent_runs.price_id 支持内置和自建角色统一记账；自建成员运行时复制快照价格，属于受应用维护的一致性冗余。数据库 FK 保证引用存在，快照不可编辑、快照与任务归属和价格相同由受控应用路径保证，不声称由数据库完全强制。

正式 ER 图需补充上述两个实体、价格到执行的关系和可选基数。已有 13 表图与 v2 报告是升级前版本，不能作为当前结构完整图。迁移和新旧路径一致性由回归测试验证。

## 14. v1.2 Schema 变更决策记录

本节把原先散落在 ER 图预览页的“待确认项”转为**已决记录**，逐项写明决策、理由、代码依据与验收方式。变更只涉及 2 号的数据库交付物；后端代码由对应选手按第 14.5 节同步。

### 14.1 决策总览

| 编号 | 变更 | 决策 | 依据摘要 | 验收 |
| --- | --- | --- | --- | --- |
| C1 | `model_calls` 增加价格版本与费率快照 | **采纳，最高优先级** | 历史账目不能依赖 `model_prices` 后续状态；`billing.py:23-27`、`execution.py:333`、`admin.py:78` | V11 / V12 / V15 |
| C2 | `tasks.user_id` 归属不变量 | **保留冗余 + 触发器强制**（不删列） | 订阅复合外键 `fk_tasks_subscription_owner` 依赖该列；原第 12 节只由应用层保证 | V6 / V16 |
| C3 | `tool_calls.grant_id` 改强制 + 授权覆盖委派工具 | **采纳方案 A，并补齐委派授权行** | 每次工具调用可审计；`execution.py:398,565`、spec MAT-04/05、EXEC-01 | V13 / V14 |

### 14.2 C1：调用费率快照

**问题**。当前后端 `execution.py:416`、`admin.py:78`、`workspaces.py:242` 都按 `run.price_id or task.price_id` 读取 `model_prices` 算账。团队扩展后 `task_agents.price_id` 与 `agent_runs.price_id` 允许每个自建角色使用不同价格，因此“一轮一个模型”已不成立；若历史价格行被改写或删除，历史 `model_calls.cost` 与按表重算金额会不一致，对账环节 `USERS → MODEL_CALLS : reconciles` 直接暴露差额。

**决策**。保留 `tasks.price_id` 作为本轮默认价，并在 `model_calls` 增加 `price_id`、`currency`、`input_rate_snapshot`、`output_rate_snapshot`、`cached_rate_snapshot`、`rate_unit` 六个字段。登记在途调用时从 `COALESCE(agent_runs.price_id, tasks.price_id)` 复制快照；响应结算与管理员补录都只读调用自身快照。

**为何保留 `tasks.price_id`**。它是无自建 Agent 时的默认价，且 3 处后端读取与 `workspaces.py` 展示依赖该字段；删除会扩大改动面。快照落地后，价格版本即使变化也不影响历史账目。

**计费口径（已决）**：

| 项目 | 结论 | 依据 |
| --- | --- | --- |
| 费率单位 | 每百万 token，`rate_unit` CHECK 固定 `per_1m_tokens` | `billing.py` 的 `/1_000_000`；`spec/models-and-pricing.md:11` |
| `cached_tokens` | 输入 token 子集，计费不重复相加 | `billing.py`；`spec/usage-and-billing.md:20` |
| 计算公式 | `((输入−缓存)×输入单价 + 缓存×缓存单价 + 输出×输出单价)/1,000,000` | `spec/usage-and-billing.md:20` |
| 精度 | `Decimal` 计算、`NUMERIC(24,12)` 存储、十进制字符串传输，不额外舍入 | `spec/usage-and-billing.md:10` |
| `tasks.budget` 币种 | USD，与价格版本 `currency` 一致 | `spec/models-and-pricing.md:11`；样例数据 |
| 未知用量 | `cost = NULL`，不记 0 | `spec/usage-and-billing.md:11`；V1 与 `ck_model_calls_usage_complete` |

**验收**：V11 快照完整性；V12 快照与原价格版本一致（有行即历史费率被改写）；V15 按同一公式复算已知费用。

### 14.3 C2：`tasks.user_id` 归属不变量

**问题**。原设计同时有 `USERS → CONVERSATIONS → TASKS` 与 `USERS → TASKS`，属于传递依赖；原第 12 节已明确“当前一致性由接口写入和 V6 审计保证，普通单列外键不会阻止跨用户组合”。

**决策**。不删列，改为**保留冗余 + 数据库触发器**：`trg_tasks_owner` 在 `INSERT` 或 `UPDATE OF user_id, conversation_id` 时读取父对话的 `user_id`，不一致即抛异常。这样把应用层约定升级为数据库强制，V6 与 V16 均可复核。

**为何不删列**。团队扩展引入 `fk_tasks_subscription_owner (subscription_id, user_id) → subscriptions(id, user_id)`，删除 `tasks.user_id` 会直接破坏订阅归属校验。删除后也无法用单列 FK 表达“订阅属于该用户”；触发器是当前成本最低且可审计的方案。

**迁移约束**。触发器上线前必须 V6 = 0 行；旧库先用 `upgrade_conversations` 接入对话。`db/migration_v1_2.sql` 的 DO 块对不一致数据硬中断，避免半迁移。

**验收**：V6 检查任务与对话同主；V6b 检查无孤立任务；V16 检查触发器与函数存在且启用。

### 14.4 C3：工具授权强制化

**问题**。v1.1 `execution.py:565` 写 `grant_id=grant.id if grant else None`，`execution.py:398` 的委派工具调用不写 `grant_id`，允许无授权依据的工具调用；`tool_calls.status='denied'` 时也可能没有 grant 行。安全审计无法回答“这次工具调用凭什么被允许”。

**方案评估**。方案 B（授权下沉到 `AGENT_RUNS` 或新建 `RUN_TOOL_GRANTS`）不采纳：现有 `execution.py` 按 `task_id + tool` 查授权，子 Agent 继承本轮授权；`spec/materials-and-permissions.md:12`（MAT-04）明确“按本轮执行＋工具”保存授权；`spec/agent-execution.md:9`（EXEC-01）只允许预定义角色。查不到需要 Run 级细粒度的业务场景，增加一层表只会提高复杂度。

**决策**。采用方案 A，但补一层“全工具覆盖”，否则直接全局 `NOT NULL` 会迫使委派工具伪造资料授权：

- `task_tool_grants.tool` 白名单扩展为 4 个：`read_material`、`search_materials`、`delegate_summary`、`delegate_review`。
- 每轮创建 4 行授权。用户未选择的资料工具插入 `revoked_at = now()` 的**显式拒绝行**；委派工具插入有效行，其权限来自 EXEC-01 预定义角色，不暴露给用户撤销接口（`workspaces.py:29` 的 `TOOLS` 保持两个资料工具）。
- `tool_calls.grant_id` 设为 `NOT NULL`；`denied` 记录也挂对应授权行，保留判断依据。
- 子 Agent 继承本轮 Task 授权，不逐 Run 授权（依据 MAT-04 / EXEC-01）。

**并发与锁**。扩展后授权行仍受 `uq_grants_task_tool (task_id, tool)` 约束，T5 的加锁顺序“任务 → 授权行”不变；撤销与开启作用于同一行。

**验收**：V13 检查 grant 必填且归属同一轮；V14 检查资料工具与委派工具不能挂错授权类型。

### 14.5 后端需同步改动点（2 号提出，后端代码未改）

v1.2 DDL 与 v1.1 ORM 不兼容。以下位置来自对现有代码的逐行核对，需在后端选手确认后修改；`catalog.py`、`billing.py` 的 calculate 公式本身无需改单位（已是每百万）。

| 文件与位置 | 当前实现 | v1.2 需要 |
| --- | --- | --- |
| `backend/app/entities.py` `Task` | `user_id` + `fk_tasks_subscription_owner` | **保留**，并新增触发器（DDL 层） |
| `backend/app/entities.py` `ModelCall` | 无快照字段 | 增加 `price_id`（FK）、`currency`、三项费率快照、`rate_unit` |
| `backend/app/entities.py` `ToolCall:282` | `grant_id` 可空 | 改为非空 |
| `backend/app/execution.py:416` | `price = db.get(Price, run.price_id or task.price_id)` | 创建 `ModelCall` 时写 `price_id` / 币种 / 费率快照 / `rate_unit`；`calculate()` 改传快照 |
| `backend/app/execution.py:398` | 委派工具 `ToolCall` 不写 `grant_id` | 写本轮委派授权行 id |
| `backend/app/execution.py:565` | 资料工具 `grant_id=grant.id if grant else None` | 拒绝时挂显式拒绝行 id，不再为 NULL |
| `backend/app/workspaces.py:54,242` | 价格说明取 `task.price_id` | 展示调用快照费率（或明确标注为轮次默认值） |
| `backend/app/workspaces.py` 创建任务处 | 只建选中工具的 grant | 建 4 行授权（含显式拒绝行与委派行） |
| `backend/app/admin.py:78` | 补录用 `run.price_id or task.price_id` | 用 `call` 自身快照费率 |
| `backend/app/schema.py` | 旧迁移用 `task.user_id` 建 `Conversation` | 该迁移须在 v1.2 触发器前执行 |
| `backend/app/catalog.py`、`billing.py` | 价格不可变、按每百万 token 计算 | 无需改单位；`calculate()` 入参改快照对象 |

`catalog.py` 与 `billing.py` 的公式本身已按每百万 token 计算，不需改单位；后端未同步前，v1.2 库与 ORM 不兼容。
### 14.6 迁移与回滚

迁移步骤见第 9.2 节；脚本 `db/migration_v1_2.sql` 自带三段硬中断（用户归属不一致、无对话轮次、快照回填不完整），避免半迁移。

回滚前提是有迁移前备份：C1 的快照列可保留不删；C2 的 `tasks.user_id` 未被删除，回滚只需移除 `trg_tasks_owner` 与函数；C3 的 `NOT NULL` 可放宽但不建议回滚——一旦放宽，历史无授权调用会重新出现审计缺口。没有备份时不要执行回滚。

### 14.7 原“待确认项”的处置

| 原待确认项 | 现状态 | 处置 |
| --- | --- | --- |
| Task / Turn 命名 | 已决 | `contains tasks`；一行 `TASKS` = 一次对话 turn |
| 一个任务是否单模型 | 已决（已扩展） | 自建 Agent 可按 `task_agents.price_id` 使用不同价格；`tasks.price_id` 仅为默认值，调用自带快照 |
| 费率单位 1K / 1M | 已决 | `per_1m_tokens`（第 14.2 节） |
| `cached_tokens` 口径 | 已决 | 输入子集，不重复计费 |
| cost 公式、精度、舍入 | 已决 | 第 14.2 节；不额外舍入 |
| `tasks.budget` 币种 | 已决 | USD，与价格版本 `currency` 一致 |
| `tasks.user_id` 冗余 | 已决 | 保留 + 触发器强制（C2）；订阅复合外键依赖该列 |
| 工具授权可选性 | 已决 | 必填，全工具覆盖（C3） |
| 子 Agent 继承授权 | 已决 | 继承本轮 Task 授权；不做 Run 级授权（MAT-04 / EXEC-01）；Agent 可自带价格，故采用调用级快照（C1） |
| `USERS.role` / `AGENT_RUNS.role` 命名 | 已决 | 不改名；分别指账号角色与执行者角色，按实体作用域区分 |
| `created_at` / `reconciled_at` / 幂等键 | 已决 | 全表已有 `created_at`；`model_calls` 已有 `reconciled_at` 与 `provider_request_id`；一行一调用即幂等，不新增键 |
| `MATERIALS.content` 大文件 | 本版不采纳 | `spec/materials-and-permissions.md:9` 限定 UTF-8 TXT / PDF 提取文本；查不到大文件存储需求。若后续支持二进制再用 URI + 大小 + 校验和 |
| `TOOL_CALLS.arguments` 脱敏 / 加密 / 保留周期 | **查不到 / 未验证** | spec 与本仓库代码均无相应条款或实现；属应用层安全策略，不在本次数据库变更范围。需安全负责人确认后另立版本 |
