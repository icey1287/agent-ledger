-- Agent Desk 数据库表结构（PostgreSQL 17）· v1.2
-- 2 号：数据库设计与实现
-- 全新库建表脚本；已有 v1.1 库请执行 db/migration_v1_2.sql，不要重建表。
--
-- v1.2 相对 v1.1 的三项变更（决策理由见 docs/database-design.md 第 11 节）：
--   C1 model_calls 增加 price_id + 费率快照：历史账目不再依赖 model_prices 后续状态
--   C2 删除 tasks.user_id：用户归属只从 conversations 推导，回归第三范式
--   C3 tool_calls.grant_id 非空：每次工具调用都有显式授权依据（含委派工具）
--
-- 与 backend/app/entities.py 的对应关系：C1/C2/C3 需后端同步改动，
-- 具体位置与替换写法见 docs/database-design.md 第 11.5 节；本文件不改后端代码。
-- 重复执行安全：CREATE TABLE IF NOT EXISTS。

SET client_encoding = 'UTF8';

-- ---------------------------------------------------------------------------
-- 1. 账号与会话
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    id            VARCHAR(36) PRIMARY KEY,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    username      VARCHAR(64) NOT NULL UNIQUE,
    password_hash TEXT        NOT NULL,          -- Argon2id PHC 字符串，不明文入库
    role          VARCHAR(16) NOT NULL DEFAULT 'user',
    CONSTRAINT ck_users_role CHECK (role IN ('user', 'admin'))
);
COMMENT ON TABLE users IS '用户账号；公开注册只能得到 user，admin 由独立命令创建';

CREATE TABLE IF NOT EXISTS sessions (
    id         VARCHAR(36) PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    user_id    VARCHAR(36) NOT NULL REFERENCES users(id),
    token_hash VARCHAR(64) NOT NULL UNIQUE,      -- SHA-256(随机令牌)，浏览器只持 HttpOnly cookie
    csrf_token VARCHAR(64) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_sessions_user_id ON sessions (user_id);

-- ---------------------------------------------------------------------------
-- 2. 模型目录与不可变价格版本
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS models (
    id           VARCHAR(36) PRIMARY KEY,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    name         VARCHAR(200) NOT NULL UNIQUE,   -- 供应商标识，创建后不可改
    display_name VARCHAR(200) NOT NULL,
    enabled      BOOLEAN NOT NULL DEFAULT TRUE
);
COMMENT ON COLUMN models.name IS 'OpenRouter 模型标识；已有记录不可修改，改名等于新增模型';

CREATE TABLE IF NOT EXISTS model_prices (
    id           VARCHAR(36) PRIMARY KEY,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    model_id     VARCHAR(36) NOT NULL REFERENCES models(id),
    version      INTEGER      NOT NULL,
    currency     VARCHAR(3)   NOT NULL DEFAULT 'USD',
    input_rate   NUMERIC(24,12) NOT NULL,        -- USD / 百万 token
    output_rate  NUMERIC(24,12) NOT NULL,
    cached_rate  NUMERIC(24,12),                 -- 可为空；有缓存 token 但无此费率时费用记为未知
    source_url   TEXT NOT NULL DEFAULT '',
    billing_note TEXT NOT NULL DEFAULT '',
    CONSTRAINT uq_model_prices_model_version UNIQUE (model_id, version),
    CONSTRAINT ck_model_prices_nonneg CHECK (
        input_rate >= 0 AND output_rate >= 0
        AND (cached_rate IS NULL OR cached_rate >= 0)
    )
);
CREATE INDEX IF NOT EXISTS ix_model_prices_model_id ON model_prices (model_id);
COMMENT ON TABLE model_prices IS '价格按版本追加，历史版本不可修改；任务固定引用其中一个版本';

-- ---------------------------------------------------------------------------
-- 3. 对话、轮次与资料
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS conversations (
    id         VARCHAR(36) PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    user_id    VARCHAR(36) NOT NULL REFERENCES users(id),
    title      VARCHAR(200) NOT NULL DEFAULT '新对话',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_conversations_user_id ON conversations (user_id);
CREATE INDEX IF NOT EXISTS ix_conversations_updated_at ON conversations (updated_at DESC);

CREATE TABLE IF NOT EXISTS tasks (
    id              VARCHAR(36) PRIMARY KEY,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    conversation_id VARCHAR(36) REFERENCES conversations(id),
    -- v1.2 C2：user_id 已删除；归属只从 conversations.user_id 推导（3NF）
    price_id        VARCHAR(36) NOT NULL REFERENCES model_prices(id), -- 本轮默认价格版本
    title           VARCHAR(200) NOT NULL,
    instruction     TEXT         NOT NULL,      -- 用户消息
    budget          NUMERIC(24,12) NOT NULL,
    status          VARCHAR(32) NOT NULL DEFAULT 'pending',
    result          TEXT NOT NULL DEFAULT '',   -- 助手最终回复；角色中间输出不算
    reason          TEXT NOT NULL DEFAULT '',
    finished_at     TIMESTAMPTZ,
    CONSTRAINT ck_tasks_budget CHECK (budget > 0),
    CONSTRAINT ck_tasks_status CHECK (status IN (
        'pending', 'running', 'completed', 'stopped_budget',
        'stopped_permission', 'cancelled', 'awaiting_usage',
        'failed', 'interrupted'
    ))
);
CREATE INDEX IF NOT EXISTS ix_tasks_conversation_id ON tasks (conversation_id);
CREATE INDEX IF NOT EXISTS ix_tasks_status ON tasks (status);
CREATE INDEX IF NOT EXISTS ix_tasks_conv_created ON tasks (conversation_id, created_at, id);
-- v1.2 C2：按用户查轮次改走 JOIN conversations，复用 ix_conversations_user_id。
COMMENT ON COLUMN tasks.price_id IS '本轮默认价格版本（spec EXEC-02：一轮一个模型，所有角色共用）；每次调用实际费率以 model_calls 快照为准';

CREATE TABLE IF NOT EXISTS materials (
    id         VARCHAR(36) PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    task_id    VARCHAR(36) NOT NULL REFERENCES tasks(id),
    name       TEXT        NOT NULL,            -- 原始文件名或“粘贴资料”
    kind       VARCHAR(16) NOT NULL,
    content    TEXT        NOT NULL,            -- 提取后的完整文本，不做 OCR
    CONSTRAINT ck_materials_kind CHECK (kind IN ('text', 'txt', 'pdf'))
);
CREATE INDEX IF NOT EXISTS ix_materials_task_id ON materials (task_id);
COMMENT ON TABLE materials IS '资料归属轮次，但同一对话的后续轮次可读取（需本轮授权）';

CREATE TABLE IF NOT EXISTS task_tool_grants (
    id         VARCHAR(36) PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    task_id    VARCHAR(36) NOT NULL REFERENCES tasks(id),
    tool       VARCHAR(32) NOT NULL,
    expires_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,
    CONSTRAINT uq_grants_task_tool UNIQUE (task_id, tool),
    -- v1.2 C3：白名单含两个资料工具与两个 EXEC-01 预定义委派角色工具。
    CONSTRAINT ck_grants_tool CHECK (tool IN (
        'read_material', 'search_materials', 'delegate_summary', 'delegate_review'
    ))
);
CREATE INDEX IF NOT EXISTS ix_task_tool_grants_task_id ON task_tool_grants (task_id);
COMMENT ON TABLE task_tool_grants IS '本轮＋工具粒度的授权决策记录：含用户未选择资料工具的显式拒绝行、EXEC-01 预定义委派角色行';

-- ---------------------------------------------------------------------------
-- 4. Agent 执行、模型调用与工具调用
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS agent_runs (
    id          VARCHAR(36) PRIMARY KEY,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    task_id     VARCHAR(36) NOT NULL REFERENCES tasks(id),
    parent_id   VARCHAR(36) REFERENCES agent_runs(id),  -- 仅协调者可委派
    role        VARCHAR(32) NOT NULL,
    status      VARCHAR(32) NOT NULL DEFAULT 'running',
    instruction TEXT NOT NULL DEFAULT '',
    output      TEXT NOT NULL DEFAULT '',
    finished_at TIMESTAMPTZ,
    CONSTRAINT ck_agent_runs_role CHECK (role IN ('coordinator', 'summary', 'review')),
    CONSTRAINT ck_agent_runs_status CHECK (status IN ('running', 'completed', 'stopped', 'interrupted'))
);
CREATE INDEX IF NOT EXISTS ix_agent_runs_task_id ON agent_runs (task_id);
CREATE INDEX IF NOT EXISTS ix_agent_runs_parent_id ON agent_runs (parent_id);

CREATE TABLE IF NOT EXISTS model_calls (
    id                    VARCHAR(36) PRIMARY KEY,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    run_id                VARCHAR(36) NOT NULL REFERENCES agent_runs(id),
    -- v1.2 C1：本次调用实际费率快照，不再依赖 model_prices 后续状态
    price_id              VARCHAR(36) NOT NULL REFERENCES model_prices(id),
    currency              VARCHAR(3)  NOT NULL,
    input_rate_snapshot   NUMERIC(24,12) NOT NULL,  -- 每百万 token
    output_rate_snapshot  NUMERIC(24,12) NOT NULL,
    cached_rate_snapshot  NUMERIC(24,12),           -- 可空；有缓存 token 且为 NULL 时费用未知
    rate_unit             VARCHAR(16) NOT NULL DEFAULT 'per_1m_tokens',
    provider_request_id   TEXT,
    status                VARCHAR(32) NOT NULL DEFAULT 'in_flight',
    usage_status          VARCHAR(16) NOT NULL DEFAULT 'unknown',
    input_tokens          INTEGER,
    output_tokens         INTEGER,
    cached_tokens         INTEGER,                  -- 输入 token 的子集
    cost                  NUMERIC(24,12),          -- 最终费用；NULL = 未知，禁止按 0 结算
    raw_usage             JSON,
    response_text         TEXT NOT NULL DEFAULT '',
    error                 TEXT NOT NULL DEFAULT '',
    reconciled_by         VARCHAR(36) REFERENCES users(id),
    evidence              TEXT NOT NULL DEFAULT '',
    reconciled_at         TIMESTAMPTZ,
    finished_at           TIMESTAMPTZ,
    CONSTRAINT ck_model_calls_status CHECK (status IN (
        'in_flight', 'succeeded', 'failed', 'usage_unknown', 'reconciled'
    )),
    CONSTRAINT ck_model_calls_usage_status CHECK (usage_status IN ('unknown', 'known')),
    CONSTRAINT ck_model_calls_cost CHECK (cost IS NULL OR cost >= 0),
    CONSTRAINT ck_model_calls_input CHECK (input_tokens IS NULL OR input_tokens >= 0),
    CONSTRAINT ck_model_calls_output CHECK (output_tokens IS NULL OR output_tokens >= 0),
    CONSTRAINT ck_model_calls_cached CHECK (
        cached_tokens IS NULL
        OR (cached_tokens >= 0 AND (input_tokens IS NULL OR cached_tokens <= input_tokens))
    ),
    CONSTRAINT ck_model_calls_rate_nonneg CHECK (
        input_rate_snapshot >= 0 AND output_rate_snapshot >= 0
        AND (cached_rate_snapshot IS NULL OR cached_rate_snapshot >= 0)
    ),
    CONSTRAINT ck_model_calls_rate_unit CHECK (rate_unit = 'per_1m_tokens'),
    CONSTRAINT ck_model_calls_currency CHECK (currency ~ '^[A-Z]{3}$')
);
CREATE INDEX IF NOT EXISTS ix_model_calls_run_id ON model_calls (run_id);
CREATE INDEX IF NOT EXISTS ix_model_calls_status ON model_calls (status);
CREATE INDEX IF NOT EXISTS ix_model_calls_price_id ON model_calls (price_id);
COMMENT ON COLUMN model_calls.price_id IS '本次调用实际使用的价格版本；调用登记时从轮次默认价格复制，之后不随任务或最新价变化';
COMMENT ON COLUMN model_calls.rate_unit IS '费率单位固定 per_1m_tokens，与 billing.calculate 的 /1,000,000 一致';
COMMENT ON COLUMN model_calls.cost IS '按快照费率精确计算的最终费用；NULL 表示待核实，不写入估算值';

CREATE TABLE IF NOT EXISTS tool_calls (
    id         VARCHAR(36) PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    run_id     VARCHAR(36) NOT NULL REFERENCES agent_runs(id),
    -- v1.2 C3：必填；委派工具指向本轮预定义角色授权行
    grant_id   VARCHAR(36) NOT NULL REFERENCES task_tool_grants(id),
    tool       VARCHAR(100) NOT NULL,
    arguments  JSON NOT NULL,
    status     VARCHAR(32) NOT NULL,
    output     TEXT NOT NULL DEFAULT '',
    CONSTRAINT ck_tool_calls_status CHECK (status IN ('completed', 'denied', 'failed'))
);
CREATE INDEX IF NOT EXISTS ix_tool_calls_run_id ON tool_calls (run_id);
CREATE INDEX IF NOT EXISTS ix_tool_calls_grant_id ON tool_calls (grant_id);
COMMENT ON COLUMN tool_calls.grant_id IS '必填；资料工具指向本轮对应工具的授权行（含显式拒绝行），委派工具指向本轮预定义角色授权行';
