-- Agent Desk 数据库验收自查 SQL（2 号：数据库设计与实现）· v1.2
-- V1~V9、V11~V16 为一致性断言：均应返回 0 行；
-- V10 为软预算观察查询，返回行属正常业务现象。
-- v1.2 新增：V11 快照完整性 / V12 快照与价格版本一致 / V13 授权归属 /
--            V14 工具与授权类型匹配 / V15 按快照复算费用 / V16 归属触发器在线。
-- 与 docs/database-design.md 第 8 节、第 10 节、第 11 节配套使用。

SET client_encoding = 'UTF8';

-- V1 未知用量调用不得写入费用
SELECT id, status, usage_status, cost
FROM model_calls
WHERE usage_status = 'unknown' AND cost IS NOT NULL;

-- V2 已知用量调用必须有完整 token 与非负费用
SELECT id
FROM model_calls
WHERE usage_status = 'known'
  AND (input_tokens IS NULL OR output_tokens IS NULL
       OR cached_tokens IS NULL OR cost IS NULL OR cost < 0);

-- V3 缓存 token 必须是输入 token 的子集
SELECT id, input_tokens, cached_tokens
FROM model_calls
WHERE cached_tokens > input_tokens;

-- V4a awaiting_usage 必须存在未确认用量的调用
SELECT t.id
FROM tasks t
WHERE t.status = 'awaiting_usage'
  AND NOT EXISTS (
      SELECT 1 FROM model_calls c
      JOIN agent_runs r ON r.id = c.run_id
      WHERE r.task_id = t.id AND c.usage_status = 'unknown'
  );

-- V4b completed 不得存在未确认用量的调用
SELECT t.id
FROM tasks t
WHERE t.status = 'completed'
  AND EXISTS (
      SELECT 1 FROM model_calls c
      JOIN agent_runs r ON r.id = c.run_id
      WHERE r.task_id = t.id AND c.usage_status = 'unknown'
  );

-- V5a 任务必须引用存在的价格版本（价格不可变、历史可追溯）
SELECT t.id
FROM tasks t
LEFT JOIN model_prices p ON p.id = t.price_id
WHERE p.id IS NULL;

-- V5b 价格版本必须归属存在的模型
SELECT p.id
FROM model_prices p
LEFT JOIN models m ON m.id = p.model_id
WHERE m.id IS NULL;

-- V6 任务与对话必须同属一个用户；v1.2 起由 trg_tasks_owner 在写入时强制
SELECT t.id
FROM tasks t
JOIN conversations c ON c.id = t.conversation_id
WHERE t.user_id <> c.user_id;

-- V6b 迁移前不应残留无对话归属的任务
SELECT t.id
FROM tasks t
LEFT JOIN conversations c ON c.id = t.conversation_id
WHERE c.id IS NULL;

-- V7 无孤立记录
SELECT 'agent_runs' AS tbl, id FROM agent_runs
  WHERE task_id NOT IN (SELECT id FROM tasks)
UNION ALL
SELECT 'model_calls', id FROM model_calls
  WHERE run_id NOT IN (SELECT id FROM agent_runs)
UNION ALL
SELECT 'tool_calls', id FROM tool_calls
  WHERE run_id NOT IN (SELECT id FROM agent_runs)
UNION ALL
SELECT 'materials', id FROM materials
  WHERE task_id NOT IN (SELECT id FROM tasks)
UNION ALL
SELECT 'task_tool_grants', id FROM task_tool_grants
  WHERE task_id NOT IN (SELECT id FROM tasks);

-- V8 唯一约束复核
SELECT task_id, tool FROM task_tool_grants
GROUP BY task_id, tool HAVING COUNT(*) > 1;
SELECT model_id, version FROM model_prices
GROUP BY model_id, version HAVING COUNT(*) > 1;

-- V9 预算必须为正
SELECT id FROM tasks WHERE budget <= 0;

-- V10 软预算观察：已知费用超过预算的轮次（最后一次调用允许超额，不是错误）
SELECT
    t.id,
    t.status,
    t.budget,
    COALESCE(SUM(c.cost), 0) AS known_cost
FROM tasks t
JOIN agent_runs r ON r.task_id = t.id
LEFT JOIN model_calls c ON c.run_id = r.id
GROUP BY t.id, t.budget, t.status
HAVING COALESCE(SUM(c.cost), 0) > t.budget
ORDER BY known_cost DESC;

-- ---------------------------------------------------------------------------
-- v1.2 新增断言（均应为 0 行）
-- ---------------------------------------------------------------------------

-- V11 每次调用的费率快照必须完整且单位正确（C1）
SELECT id
FROM model_calls
WHERE price_id IS NULL OR currency IS NULL
   OR input_rate_snapshot IS NULL OR output_rate_snapshot IS NULL
   OR rate_unit IS NULL OR rate_unit <> 'per_1m_tokens'
   OR currency !~ '^[A-Z]{3}$';

-- V12 快照必须与所引用的历史价格版本一致；有行说明历史费率被改写，账单失去依据（C1）
SELECT c.id
FROM model_calls c
JOIN model_prices p ON p.id = c.price_id
WHERE c.currency <> p.currency
   OR c.input_rate_snapshot <> p.input_rate
   OR c.output_rate_snapshot <> p.output_rate
   OR c.cached_rate_snapshot IS DISTINCT FROM p.cached_rate;

-- V13 工具调用必须有授权行，且授权属于同一轮次（C3）
SELECT tc.id
FROM tool_calls tc
LEFT JOIN task_tool_grants g ON g.id = tc.grant_id
LEFT JOIN agent_runs r ON r.id = tc.run_id
LEFT JOIN tasks t ON t.id = r.task_id
WHERE g.id IS NULL OR g.task_id IS DISTINCT FROM t.id;

-- V14 授权类型必须与工具类型匹配：委派工具不能挂资料授权，反之亦然（C3）
SELECT tc.id
FROM tool_calls tc
JOIN task_tool_grants g ON g.id = tc.grant_id
WHERE (tc.tool IN ('read_material', 'search_materials')
       AND g.tool NOT IN ('read_material', 'search_materials'))
   OR (tc.tool IN ('delegate_summary', 'delegate_review')
       AND g.tool NOT IN ('delegate_summary', 'delegate_review'));

-- V15 已知费用必须等于按本次快照费率复算的结果（C1，容差 1e-12）
SELECT c.id
FROM model_calls c
WHERE c.usage_status = 'known'
  AND c.cost IS NOT NULL
  AND c.input_tokens IS NOT NULL
  AND c.output_tokens IS NOT NULL
  AND c.cached_tokens IS NOT NULL
  AND (c.cached_rate_snapshot IS NOT NULL OR c.cached_tokens = 0)
  AND c.cost <> (
      ((c.input_tokens - c.cached_tokens) * c.input_rate_snapshot
       + c.cached_tokens * COALESCE(c.cached_rate_snapshot, 0)
       + c.output_tokens * c.output_rate_snapshot) / 1000000
  );

-- V16 v1.2 C2：归属不变量触发器必须存在且启用（订阅复合外键依赖 tasks.user_id）
SELECT 'missing_or_disabled_trigger' AS issue
WHERE NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'tasks'::regclass
      AND tgname = 'trg_tasks_owner'
      AND NOT tgisinternal
      AND tgenabled = 'O'
)
UNION ALL
SELECT 'missing_trigger_function'
WHERE NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'enforce_task_owner'
);
