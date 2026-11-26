-- Agent Desk 数据库验收自查 SQL（2 号：数据库设计与实现）
-- V1~V9 为一致性断言：均应返回 0 行；V10 为软预算观察查询，返回行属正常业务现象。
-- 与 docs/database-design.md 第 8 节、第 10 节配套使用。

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

-- V6 任务与对话必须同属一个用户（数据隔离的数据库层断言）
SELECT t.id
FROM tasks t
JOIN conversations c ON c.id = t.conversation_id
WHERE t.user_id <> c.user_id;

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
