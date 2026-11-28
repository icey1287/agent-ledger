-- Agent Desk 数据库表结构（PostgreSQL 17）
-- 2 号：数据库设计与实现
-- 与 backend/app/entities.py 的 SQLAlchemy 映射一一对应；
-- 本脚本额外补齐枚举 CHECK 约束与查询索引，建议作为首次建表脚本使用。
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
CREATE TABLE IF NOT EXISTS agents (
 id VARCHAR(36) PRIMARY KEY,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 user_id VARCHAR(36) NOT NULL REFERENCES users(id),
 model_id VARCHAR(36) NOT NULL REFERENCES models(id),
 name VARCHAR(100) NOT NULL,
 instruction TEXT NOT NULL,
 enabled BOOLEAN NOT NULL DEFAULT TRUE,
 CONSTRAINT ck_agents_text CHECK (length(trim(name)) > 0 AND length(trim(instruction)) > 0)
);
CREATE INDEX IF NOT EXISTS ix_agents_user_id ON agents(user_id);

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
    user_id         VARCHAR(36) NOT NULL REFERENCES users(id),
    price_id        VARCHAR(36) NOT NULL REFERENCES model_prices(id), -- 本轮固定价格版本
    title           VARCHAR(200) NOT NULL,
    instruction     TEXT         NOT NULL,      -- 用户消息
    budget          NUMERIC(24,12) NOT NULL,
    status          VARCHAR(32) NOT NULL DEFAULT 'pending',
    result          TEXT NOT NULL DEFAULT '',   -- 助手最终回复；角色中间输出不算
    reason          TEXT NOT NULL DEFAULT '',
    finished_at     TIMESTAMPTZ,
    execution_mode VARCHAR(16) NOT NULL DEFAULT 'sequential',
    CONSTRAINT ck_tasks_execution_mode CHECK (execution_mode IN ('sequential','parallel')),
    CONSTRAINT ck_tasks_budget CHECK (budget > 0),
    CONSTRAINT ck_tasks_status CHECK (status IN (
        'pending', 'running', 'completed', 'stopped_budget',
        'stopped_permission', 'cancelled', 'awaiting_usage',
        'failed', 'interrupted'
    ))
);
CREATE INDEX IF NOT EXISTS ix_tasks_conversation_id ON tasks (conversation_id);
CREATE INDEX IF NOT EXISTS ix_tasks_user_id ON tasks (user_id);
CREATE INDEX IF NOT EXISTS ix_tasks_status ON tasks (status);
CREATE INDEX IF NOT EXISTS ix_tasks_conv_created ON tasks (conversation_id, created_at, id);
COMMENT ON COLUMN tasks.price_id IS '轮次创建时锁定，之后费率调整不改变历史账目';

CREATE TABLE IF NOT EXISTS task_agents (
 id VARCHAR(36) PRIMARY KEY,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 task_id VARCHAR(36) NOT NULL REFERENCES tasks(id),
 agent_id VARCHAR(36) NOT NULL REFERENCES agents(id),
 price_id VARCHAR(36) NOT NULL REFERENCES model_prices(id),
 name VARCHAR(100) NOT NULL,
 instruction TEXT NOT NULL,
 position INTEGER NOT NULL,
 UNIQUE(task_id, agent_id), UNIQUE(task_id, position),
 CONSTRAINT ck_task_agents_position CHECK (position >= 0)
);
CREATE INDEX IF NOT EXISTS ix_task_agents_task_id ON task_agents(task_id);

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
    CONSTRAINT ck_grants_tool CHECK (tool IN ('read_material', 'search_materials'))
);
CREATE INDEX IF NOT EXISTS ix_task_tool_grants_task_id ON task_tool_grants (task_id);

-- ---------------------------------------------------------------------------
-- 4. Agent 执行、模型调用与工具调用
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS agent_runs (
    task_agent_id VARCHAR(36) REFERENCES task_agents(id),
    price_id VARCHAR(36) REFERENCES model_prices(id),
    id          VARCHAR(36) PRIMARY KEY,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    task_id     VARCHAR(36) NOT NULL REFERENCES tasks(id),
    parent_id   VARCHAR(36) REFERENCES agent_runs(id),  -- 仅协调者可委派
    role        VARCHAR(32) NOT NULL,
    status      VARCHAR(32) NOT NULL DEFAULT 'running',
    instruction TEXT NOT NULL DEFAULT '',
    output      TEXT NOT NULL DEFAULT '',
    finished_at TIMESTAMPTZ,
    CONSTRAINT ck_agent_runs_role CHECK (role IN ('coordinator', 'summary', 'review', 'worker')),
    CONSTRAINT ck_agent_runs_status CHECK (status IN ('running', 'completed', 'stopped', 'interrupted'))
);
CREATE INDEX IF NOT EXISTS ix_agent_runs_task_id ON agent_runs (task_id);
CREATE INDEX IF NOT EXISTS ix_agent_runs_parent_id ON agent_runs (parent_id);

CREATE TABLE IF NOT EXISTS model_calls (
    id                 VARCHAR(36) PRIMARY KEY,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    run_id             VARCHAR(36) NOT NULL REFERENCES agent_runs(id),
    provider_request_id TEXT,
    status             VARCHAR(32) NOT NULL DEFAULT 'in_flight',
    usage_status       VARCHAR(16) NOT NULL DEFAULT 'unknown',
    input_tokens       INTEGER,
    output_tokens      INTEGER,
    cached_tokens      INTEGER,                 -- 输入 token 的子集
    cost               NUMERIC(24,12),         -- NULL = 未知费用，禁止按 0 结算
    raw_usage          JSON,
    response_text      TEXT NOT NULL DEFAULT '',
    error              TEXT NOT NULL DEFAULT '',
    reconciled_by      VARCHAR(36) REFERENCES users(id),
    evidence           TEXT NOT NULL DEFAULT '',
    reconciled_at      TIMESTAMPTZ,
    finished_at        TIMESTAMPTZ,
    CONSTRAINT ck_model_calls_status CHECK (status IN (
        'in_flight', 'succeeded', 'failed', 'usage_unknown', 'reconciled'
    )),
    CONSTRAINT ck_model_calls_usage_status CHECK (usage_status IN ('unknown', 'known')),
    CONSTRAINT ck_model_calls_usage_complete CHECK ((usage_status = 'unknown' AND cost IS NULL) OR (usage_status = 'known' AND input_tokens IS NOT NULL AND output_tokens IS NOT NULL AND cached_tokens IS NOT NULL AND cost IS NOT NULL)),
    CONSTRAINT ck_model_calls_cost CHECK (cost IS NULL OR cost >= 0),
    CONSTRAINT ck_model_calls_input CHECK (input_tokens IS NULL OR input_tokens >= 0),
    CONSTRAINT ck_model_calls_output CHECK (output_tokens IS NULL OR output_tokens >= 0),
    CONSTRAINT ck_model_calls_cached CHECK (
        cached_tokens IS NULL
        OR (cached_tokens >= 0 AND (input_tokens IS NULL OR cached_tokens <= input_tokens))
    )
);
CREATE INDEX IF NOT EXISTS ix_model_calls_run_id ON model_calls (run_id);
CREATE INDEX IF NOT EXISTS ix_model_calls_status ON model_calls (status);
COMMENT ON COLUMN model_calls.cost IS '由固定价格版本精确计算；NULL 表示待核实，不写入估算值';

CREATE TABLE IF NOT EXISTS tool_calls (
    id         VARCHAR(36) PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    run_id     VARCHAR(36) NOT NULL REFERENCES agent_runs(id),
    grant_id   VARCHAR(36) REFERENCES task_tool_grants(id),
    tool       VARCHAR(100) NOT NULL,
    arguments  JSON NOT NULL,
    status     VARCHAR(32) NOT NULL,
    output     TEXT NOT NULL DEFAULT '',
    CONSTRAINT ck_tool_calls_status CHECK (status IN ('completed', 'denied', 'failed'))
);
CREATE INDEX IF NOT EXISTS ix_tool_calls_run_id ON tool_calls (run_id);
COMMENT ON COLUMN tool_calls.grant_id IS '委派类工具为 NULL；资料工具记录本次判断所依据的授权行';

-- Subscription feature: additive tables, immutable enrollment snapshots, historical task links.
CREATE TABLE IF NOT EXISTS plans (
 id VARCHAR(36) PRIMARY KEY, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 code VARCHAR(32) NOT NULL UNIQUE, name VARCHAR(100) NOT NULL,
 duration_days INTEGER NOT NULL, display_price NUMERIC(12,2) NOT NULL,
 currency VARCHAR(3) NOT NULL DEFAULT 'USD', enabled BOOLEAN NOT NULL DEFAULT TRUE,
 CONSTRAINT ck_plans_duration CHECK (duration_days > 0),
 CONSTRAINT ck_plans_price CHECK (display_price >= 0)
);
CREATE TABLE IF NOT EXISTS subscriptions (
 id VARCHAR(36) PRIMARY KEY, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 user_id VARCHAR(36) NOT NULL REFERENCES users(id), plan_id VARCHAR(36) NOT NULL REFERENCES plans(id),
 plan_name VARCHAR(100) NOT NULL, display_price NUMERIC(12,2) NOT NULL, currency VARCHAR(3) NOT NULL,
 starts_at TIMESTAMPTZ NOT NULL, ends_at TIMESTAMPTZ NOT NULL,
 status VARCHAR(16) NOT NULL DEFAULT 'active', cancelled_at TIMESTAMPTZ,
 CONSTRAINT uq_subscriptions_id_user UNIQUE (id,user_id),
 CONSTRAINT ck_subscriptions_period CHECK (ends_at > starts_at),
 CONSTRAINT ck_subscriptions_price CHECK (display_price >= 0),
 CONSTRAINT ck_subscriptions_status CHECK (status IN ('active','cancelled','expired')),
 CONSTRAINT ck_subscriptions_cancelled CHECK ((status = 'cancelled' AND cancelled_at IS NOT NULL) OR (status <> 'cancelled' AND cancelled_at IS NULL))
);
CREATE INDEX IF NOT EXISTS ix_subscriptions_user_id ON subscriptions(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_subscriptions_active_user ON subscriptions(user_id) WHERE status='active';
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS subscription_id VARCHAR(36);
DO $sub$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='fk_tasks_subscription_owner' AND conrelid='tasks'::regclass) THEN
  ALTER TABLE tasks ADD CONSTRAINT fk_tasks_subscription_owner FOREIGN KEY (subscription_id,user_id) REFERENCES subscriptions(id,user_id);
 END IF;
END $sub$;
