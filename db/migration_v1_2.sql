-- Agent Desk v1.2 Schema 变更迁移（2 号：数据库设计与实现）
-- 适用对象：v1.1 库（db/schema.sql 初始化，或 create_all + db/migration.sql 补齐）。
--
-- 三项变更：
--   C1  model_calls 固定价格版本 + 费率快照  → 历史账目不依赖 model_prices 后续状态
--   C2  删除 tasks.user_id                  → 回归 3NF，用户归属只从 conversations 推导
--   C3  tool_calls.grant_id 强制非空        → 每次工具调用都有显式授权依据（含委派工具）
--
-- 前置条件（缺一不可）：
--   1. 已备份数据库。
--   2. db/verification.sql 的 V1–V10 全部返回 0 行 / 符合预期。
--   3. 旧库若 conversation_id 为空，必须先运行 main.py 的 upgrade_conversations，
--      否则第 0 节会中止（tasks.user_id 是旧 conversation 的唯一来源）。
--   4. 应用已停止写入；迁移期间不要启动执行器。
-- 原则：不修改 model_prices 历史行；不删除调用与工具审计记录；重复执行安全。
--
-- 依据（backend 代码位置，v1.1 现状）：
--   billing.py:23-27    费率为每百万 token，除以 1,000,000
--   spec/agent-execution.md:11  EXEC-02 每轮固定一个模型、所有角色共用
--   execution.py:333 / admin.py:78 / workspaces.py:51   按 task.price_id 取费率
--   execution.py:87,234 / workspaces.py:34,88,166 / admin.py:19 / schema.py:24   依赖 Task.user_id
--   execution.py:424-427,484  工具授权按 task_id+tool 查；委派工具 grant_id 写 None
--   spec/materials-and-permissions.md:12-13  MAT-04/05 授权粒度为「本轮＋工具」

SET client_encoding = 'UTF8';

-- ---------------------------------------------------------------------------
-- 0. 硬前置断言：不满足直接中止，避免留下半迁移状态
-- ---------------------------------------------------------------------------
DO $pre$
BEGIN
    IF EXISTS (
        SELECT 1 FROM tasks t
        JOIN conversations c ON c.id = t.conversation_id
        WHERE t.user_id <> c.user_id
    ) THEN
        RAISE EXCEPTION 'v1.2 aborted: tasks.user_id differs from conversations.user_id (verification V6)';
    END IF;

    IF EXISTS (SELECT 1 FROM tasks WHERE conversation_id IS NULL) THEN
        RAISE EXCEPTION 'v1.2 aborted: task without conversation_id; run upgrade_conversations first';
    END IF;

    IF EXISTS (
        SELECT 1 FROM model_calls c
        LEFT JOIN agent_runs r ON r.id = c.run_id
        LEFT JOIN tasks t ON t.id = r.task_id
        LEFT JOIN model_prices p ON p.id = t.price_id
        WHERE r.id IS NULL OR t.id IS NULL OR p.id IS NULL
    ) THEN
        RAISE EXCEPTION 'v1.2 aborted: cannot resolve price version for an existing model call';
    END IF;
END $pre$;

-- ---------------------------------------------------------------------------
-- 1. C1：为 model_calls 增加可空的快照列（先加列，再回填，最后收紧）
-- ---------------------------------------------------------------------------
ALTER TABLE model_calls ADD COLUMN IF NOT EXISTS price_id              VARCHAR(36);
ALTER TABLE model_calls ADD COLUMN IF NOT EXISTS currency              VARCHAR(3);
ALTER TABLE model_calls ADD COLUMN IF NOT EXISTS input_rate_snapshot   NUMERIC(24,12);
ALTER TABLE model_calls ADD COLUMN IF NOT EXISTS output_rate_snapshot  NUMERIC(24,12);
ALTER TABLE model_calls ADD COLUMN IF NOT EXISTS cached_rate_snapshot  NUMERIC(24,12);
ALTER TABLE model_calls ADD COLUMN IF NOT EXISTS rate_unit             VARCHAR(16);

-- 2. 回填：按调用所属轮次锁定的价格版本写入快照。
--    当前 EXEC-02 规定一轮一个模型，因此 task.price_id 就是本次调用的实际费率来源。
UPDATE model_calls mc
SET price_id             = p.id,
    currency             = p.currency,
    input_rate_snapshot  = p.input_rate,
    output_rate_snapshot = p.output_rate,
    cached_rate_snapshot = p.cached_rate,
    rate_unit            = 'per_1m_tokens'
FROM agent_runs r
JOIN tasks t ON t.id = r.task_id
JOIN model_prices p ON p.id = t.price_id
WHERE mc.run_id = r.id
  AND mc.price_id IS NULL;

DO $fill$
BEGIN
    IF EXISTS (
        SELECT 1 FROM model_calls
        WHERE price_id IS NULL OR currency IS NULL OR input_rate_snapshot IS NULL
           OR output_rate_snapshot IS NULL OR rate_unit IS NULL
    ) THEN
        RAISE EXCEPTION 'v1.2 aborted: rate snapshot backfill incomplete';
    END IF;
END $fill$;

-- 3. 收紧为强制字段，并补齐 FK / CHECK / 索引
ALTER TABLE model_calls ALTER COLUMN price_id            SET NOT NULL;
ALTER TABLE model_calls ALTER COLUMN currency            SET NOT NULL;
ALTER TABLE model_calls ALTER COLUMN input_rate_snapshot SET NOT NULL;
ALTER TABLE model_calls ALTER COLUMN output_rate_snapshot SET NOT NULL;
ALTER TABLE model_calls ALTER COLUMN rate_unit           SET NOT NULL;
ALTER TABLE model_calls ALTER COLUMN rate_unit           SET DEFAULT 'per_1m_tokens';

DO $c1$
DECLARE
    c RECORD;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'fk_model_calls_price_id' AND conrelid = 'model_calls'::regclass
    ) THEN
        ALTER TABLE model_calls ADD CONSTRAINT fk_model_calls_price_id
            FOREIGN KEY (price_id) REFERENCES model_prices(id);
    END IF;

    FOR c IN
        SELECT * FROM (VALUES
            ('ck_model_calls_rate_nonneg',
             $expr$input_rate_snapshot >= 0 AND output_rate_snapshot >= 0 AND (cached_rate_snapshot IS NULL OR cached_rate_snapshot >= 0)$expr$),
            ('ck_model_calls_rate_unit',
             $expr$rate_unit = 'per_1m_tokens'$expr$),
            ('ck_model_calls_currency',
             $expr$currency ~ '^[A-Z]{3}$'$expr$)
        ) AS x(name, expr)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conname = c.name AND conrelid = 'model_calls'::regclass
        ) THEN
            EXECUTE format('ALTER TABLE model_calls ADD CONSTRAINT %I CHECK (%s)', c.name, c.expr);
        END IF;
    END LOOP;
END $c1$;

CREATE INDEX IF NOT EXISTS ix_model_calls_price_id ON model_calls (price_id);

COMMENT ON COLUMN model_calls.price_id IS '本次调用实际使用的价格版本；回填自所属轮次 tasks.price_id，之后不随任务或最新价变化';
COMMENT ON COLUMN model_calls.rate_unit IS '费率单位固定 per_1m_tokens，与 billing.calculate 的 /1,000,000 一致';
COMMENT ON COLUMN model_calls.cost IS '最终费用；快照费率 + token 计算，NULL 表示待核实，禁止按 0 结算';

-- ---------------------------------------------------------------------------
-- 4. C2：删除 tasks.user_id。user_id 只保留在 conversations，
--    按用户查 task 走 JOIN conversations（索引 ix_conversations_user_id 已存在）。
-- ---------------------------------------------------------------------------
DROP INDEX IF EXISTS ix_tasks_user_id;
ALTER TABLE tasks DROP COLUMN IF EXISTS user_id;

-- ---------------------------------------------------------------------------
-- 5. C3a：授权工具白名单扩展到预定义委派工具。
--    委派工具的授权来自 EXEC-01 的固定角色，不暴露给用户撤销接口
--    （workspaces.py:29 的 TOOLS 仍只有两个资料工具）。
-- ---------------------------------------------------------------------------
ALTER TABLE task_tool_grants DROP CONSTRAINT IF EXISTS ck_grants_tool;
ALTER TABLE task_tool_grants ADD CONSTRAINT ck_grants_tool
    CHECK (tool IN ('read_material', 'search_materials', 'delegate_summary', 'delegate_review'));

-- 6. 为每个轮次补齐缺失的授权行：
--    资料工具缺失 → 显式拒绝（revoked_at = now()），保留"未授权"业务语义；
--    委派工具缺失 → 有效授权（EXEC-01 预定义角色）。
INSERT INTO task_tool_grants (id, created_at, task_id, tool, revoked_at)
SELECT gen_random_uuid()::text, now(), t.id, x.tool, now()
FROM tasks t
CROSS JOIN (VALUES ('read_material'), ('search_materials')) AS x(tool)
WHERE NOT EXISTS (
    SELECT 1 FROM task_tool_grants g
    WHERE g.task_id = t.id AND g.tool = x.tool
);

INSERT INTO task_tool_grants (id, created_at, task_id, tool)
SELECT gen_random_uuid()::text, now(), t.id, x.tool
FROM tasks t
CROSS JOIN (VALUES ('delegate_summary'), ('delegate_review')) AS x(tool)
WHERE NOT EXISTS (
    SELECT 1 FROM task_tool_grants g
    WHERE g.task_id = t.id AND g.tool = x.tool
);

-- 7. 回填悬空的 grant_id，然后收紧为 NOT NULL。
--    委派工具在此挂到对应委派授权行；资料工具被拒绝但无授权行时挂到显式拒绝行。
UPDATE tool_calls tc
SET grant_id = g.id
FROM agent_runs r
JOIN tasks t ON t.id = r.task_id
JOIN task_tool_grants g ON g.task_id = t.id AND g.tool = tc.tool
WHERE tc.run_id = r.id
  AND tc.grant_id IS NULL;

DO $c3$
BEGIN
    IF EXISTS (SELECT 1 FROM tool_calls WHERE grant_id IS NULL) THEN
        RAISE EXCEPTION 'v1.2 aborted: tool_calls.grant_id backfill incomplete';
    END IF;
END $c3$;

ALTER TABLE tool_calls ALTER COLUMN grant_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS ix_tool_calls_grant_id ON tool_calls (grant_id);

COMMENT ON COLUMN tool_calls.grant_id IS '必填；资料工具指向本轮对应工具的授权行，委派工具指向本轮预定义角色授权行；拒绝记录也保留授权判断依据';
COMMENT ON TABLE task_tool_grants IS '本轮＋工具粒度的授权决策记录；含用户未选择资料工具的显式拒绝行与 EXEC-01 预定义委派角色行';

-- ---------------------------------------------------------------------------
-- 8. 迁移后自查：db/verification.sql 的 V11–V14 均应返回 0 行
-- ---------------------------------------------------------------------------
-- SELECT 1 FROM model_calls WHERE price_id IS NULL OR input_rate_snapshot IS NULL;
-- SELECT 1 FROM tool_calls WHERE grant_id IS NULL;
-- SELECT 1 FROM tasks t JOIN conversations c ON c.id=t.conversation_id WHERE t.user_id <> c.user_id;  -- 列已删除，仅迁移前有效
-- SELECT 1 FROM tool_calls tc JOIN task_tool_grants g ON g.id=tc.grant_id JOIN agent_runs r ON r.id=tc.run_id JOIN tasks t ON t.id=r.task_id WHERE g.task_id <> t.id;
