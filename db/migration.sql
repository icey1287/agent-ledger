-- Agent Desk 数据库补齐迁移（2 号：数据库设计与实现）
-- 适用对象：已由 SQLAlchemy Base.metadata.create_all 建立的库。
-- 作用：补齐 db/schema.sql 中定义、但 create_all 未声明的枚举 CHECK 约束与查询索引。
-- 原则：不删数据、不覆盖历史价格、不修改已有业务行；重复执行安全。
-- 注意：若库中存在违反 CHECK 的历史数据，ADD CONSTRAINT 会失败，请先执行文末检查查询清洗。

SET client_encoding = 'UTF8';

-- ---------------------------------------------------------------------------
-- 1. 枚举与非负 CHECK：用 DO 块按约束名判重，避免 PostgreSQL 不支持 IF NOT EXISTS
-- ---------------------------------------------------------------------------
DO $mig$
DECLARE
    c RECORD;
BEGIN
    FOR c IN
        SELECT * FROM (VALUES
            ('users',            'ck_users_role',              $expr$role IN ('user', 'admin')$expr$),
            ('model_prices',     'ck_model_prices_nonneg',     $expr$input_rate >= 0 AND output_rate >= 0 AND (cached_rate IS NULL OR cached_rate >= 0)$expr$),
            ('tasks',            'ck_tasks_budget',            $expr$budget > 0$expr$),
            ('tasks',            'ck_tasks_status',            $expr$status IN ('pending', 'running', 'completed', 'stopped_budget', 'stopped_permission', 'cancelled', 'awaiting_usage', 'failed', 'interrupted')$expr$),
            ('materials',        'ck_materials_kind',          $expr$kind IN ('text', 'txt', 'pdf')$expr$),
            ('task_tool_grants', 'ck_grants_tool',             $expr$tool IN ('read_material', 'search_materials')$expr$),
            ('agent_runs',       'ck_agent_runs_role',         $expr$role IN ('coordinator', 'summary', 'review', 'worker')$expr$),
            ('agent_runs',       'ck_agent_runs_status',       $expr$status IN ('running', 'completed', 'stopped', 'interrupted')$expr$),
            ('model_calls',      'ck_model_calls_status',      $expr$status IN ('in_flight', 'succeeded', 'failed', 'usage_unknown', 'reconciled')$expr$),
            ('model_calls',      'ck_model_calls_usage_status',$expr$usage_status IN ('unknown', 'known')$expr$),
            ('model_calls',      'ck_model_calls_usage_complete', $expr$(usage_status = 'unknown' AND cost IS NULL) OR (usage_status = 'known' AND input_tokens IS NOT NULL AND output_tokens IS NOT NULL AND cached_tokens IS NOT NULL AND cost IS NOT NULL)$expr$),
            ('model_calls',      'ck_model_calls_cost',        $expr$cost IS NULL OR cost >= 0$expr$),
            ('model_calls',      'ck_model_calls_input',       $expr$input_tokens IS NULL OR input_tokens >= 0$expr$),
            ('model_calls',      'ck_model_calls_output',      $expr$output_tokens IS NULL OR output_tokens >= 0$expr$),
            ('model_calls',      'ck_model_calls_cached',      $expr$cached_tokens IS NULL OR (cached_tokens >= 0 AND (input_tokens IS NULL OR cached_tokens <= input_tokens))$expr$),
            ('tool_calls',       'ck_tool_calls_status',       $expr$status IN ('completed', 'denied', 'failed')$expr$)
        ) AS t(tbl, name, expr)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conname = c.name AND conrelid = c.tbl::regclass
        ) THEN
            EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I CHECK (%s)', c.tbl, c.name, c.expr);
        END IF;
    END LOOP;
END $mig$;

-- ---------------------------------------------------------------------------
-- 2. 查询索引：create_all 已建单列索引，这里补复合索引并幂等兜底
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_sessions_user_id         ON sessions (user_id);
CREATE INDEX IF NOT EXISTS ix_model_prices_model_id    ON model_prices (model_id);
CREATE INDEX IF NOT EXISTS ix_conversations_user_id    ON conversations (user_id);
CREATE INDEX IF NOT EXISTS ix_conversations_updated_at ON conversations (updated_at DESC);
CREATE INDEX IF NOT EXISTS ix_tasks_conversation_id    ON tasks (conversation_id);
CREATE INDEX IF NOT EXISTS ix_tasks_user_id            ON tasks (user_id);
CREATE INDEX IF NOT EXISTS ix_tasks_status             ON tasks (status);
CREATE INDEX IF NOT EXISTS ix_tasks_conv_created       ON tasks (conversation_id, created_at, id);
CREATE INDEX IF NOT EXISTS ix_materials_task_id        ON materials (task_id);
CREATE INDEX IF NOT EXISTS ix_task_tool_grants_task_id ON task_tool_grants (task_id);
CREATE INDEX IF NOT EXISTS ix_agent_runs_task_id       ON agent_runs (task_id);
CREATE INDEX IF NOT EXISTS ix_agent_runs_parent_id     ON agent_runs (parent_id);
CREATE INDEX IF NOT EXISTS ix_model_calls_run_id       ON model_calls (run_id);
CREATE INDEX IF NOT EXISTS ix_model_calls_status       ON model_calls (status);
CREATE INDEX IF NOT EXISTS ix_tool_calls_run_id        ON tool_calls (run_id);

-- ---------------------------------------------------------------------------
-- 3. 约束生效前的数据检查：以下查询均应返回 0 行，否则先清洗再执行第 1 节
-- ---------------------------------------------------------------------------
-- SELECT * FROM users WHERE role NOT IN ('user','admin');
-- SELECT * FROM tasks WHERE budget <= 0;
-- SELECT * FROM tasks WHERE status NOT IN ('pending','running','completed','stopped_budget','stopped_permission','cancelled','awaiting_usage','failed','interrupted');
-- SELECT * FROM model_calls WHERE cached_tokens > input_tokens;
-- SELECT * FROM model_calls WHERE cost < 0;
-- SELECT * FROM model_calls WHERE status NOT IN ('in_flight','succeeded','failed','usage_unknown','reconciled');
-- SELECT * FROM tool_calls WHERE status NOT IN ('completed','denied','failed');
