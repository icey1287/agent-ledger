-- Agent Desk 常用业务 SQL（2 号：数据库设计与实现）
-- 参数用 $1 / $2 ... 占位，由应用绑定；所有用户态查询都带 user_id 过滤。
-- 金额输出为 NUMERIC，应用侧转十进制字符串给前端。

SET client_encoding = 'UTF8';

-- Q1 用户对话列表：首页侧栏
-- $1 = user_id
SELECT id, title, updated_at
FROM conversations
WHERE user_id = $1
ORDER BY updated_at DESC;

-- Q2 对话时间线：一轮一条，含已知费用小计与未知调用数
-- $1 = conversation_id, $2 = user_id
SELECT
    t.id,
    t.title,
    t.status,
    t.reason,
    t.created_at,
    t.finished_at,
    COALESCE(SUM(c.cost), 0) AS known_cost,
    COUNT(*) FILTER (WHERE c.usage_status = 'unknown') AS unknown_calls
FROM tasks t
LEFT JOIN agent_runs r ON r.task_id = t.id
LEFT JOIN model_calls c ON c.run_id = r.id
WHERE t.conversation_id = $1 AND t.user_id = $2
GROUP BY t.id
ORDER BY t.created_at, t.id;

-- Q3 单轮执行详情：协调 / 摘要 / 审核及委派关系
-- $1 = task_id, $2 = user_id
SELECT
    r.id,
    r.role,
    r.status,
    r.parent_id,
    p.role AS parent_role,
    r.instruction,
    r.output,
    r.created_at,
    r.finished_at
FROM agent_runs r
JOIN tasks t ON t.id = r.task_id
LEFT JOIN agent_runs p ON p.id = r.parent_id
WHERE r.task_id = $1 AND t.user_id = $2
ORDER BY r.created_at, r.id;

-- Q4 单轮调用账目：逐次 token、费用、错误与补录依据
-- $1 = task_id, $2 = user_id
SELECT
    c.id,
    r.role,
    c.status,
    c.usage_status,
    c.input_tokens,
    c.output_tokens,
    c.cached_tokens,
    c.cost,
    c.provider_request_id,
    c.error,
    c.evidence,
    c.reconciled_at,
    c.created_at
FROM model_calls c
JOIN agent_runs r ON r.id = c.run_id
JOIN tasks t ON t.id = r.task_id
WHERE r.task_id = $1 AND t.user_id = $2
ORDER BY c.created_at, c.id;

-- Q5 单轮费用汇总：已知小计、未知调用数、总 token
-- $1 = task_id, $2 = user_id
SELECT
    t.id,
    t.budget,
    t.status,
    COALESCE(SUM(c.cost), 0) AS known_cost,
    COUNT(*) FILTER (WHERE c.usage_status = 'unknown') AS unknown_calls,
    COALESCE(SUM(c.input_tokens), 0) AS input_tokens,
    COALESCE(SUM(c.output_tokens), 0) AS output_tokens
FROM tasks t
JOIN agent_runs r ON r.task_id = t.id
LEFT JOIN model_calls c ON c.run_id = r.id
WHERE t.id = $1 AND t.user_id = $2
GROUP BY t.id;

-- Q6 发送前互斥检查：同对话是否有活跃轮次或在途调用
-- $1 = conversation_id, $2 = user_id
SELECT
    EXISTS (
        SELECT 1 FROM tasks
        WHERE conversation_id = $1 AND user_id = $2
          AND status IN ('pending', 'running')
    ) AS has_active_task,
    EXISTS (
        SELECT 1
        FROM model_calls c
        JOIN agent_runs r ON r.id = c.run_id
        JOIN tasks t ON t.id = r.task_id
        WHERE t.conversation_id = $1 AND t.user_id = $2
          AND c.status = 'in_flight'
    ) AS has_in_flight_call;

-- Q7 授权有效性检查：撤销与到期任一成立即无效
-- $1 = task_id, $2 = tool, $3 = user_id
SELECT
    g.id,
    g.tool,
    g.expires_at,
    g.revoked_at,
    (g.revoked_at IS NULL
     AND (g.expires_at IS NULL OR g.expires_at > now())) AS active
FROM task_tool_grants g
JOIN tasks t ON t.id = g.task_id
WHERE g.task_id = $1 AND g.tool = $2 AND t.user_id = $3;

-- Q8 管理员待核实队列：含补录所需的原价格版本费率
-- 无 user_id 过滤，仅供 administrator 使用
SELECT
    c.id AS call_id,
    c.error,
    c.provider_request_id,
    c.raw_usage,
    c.created_at,
    t.id AS task_id,
    t.title,
    u.username,
    p.currency,
    p.input_rate,
    p.output_rate,
    p.cached_rate
FROM model_calls c
JOIN agent_runs r ON r.id = c.run_id
JOIN tasks t ON t.id = r.task_id
JOIN users u ON u.id = t.user_id
JOIN model_prices p ON p.id = t.price_id
WHERE c.status = 'usage_unknown'
ORDER BY c.created_at;

-- Q9 价格版本历史：管理端展示改价轨迹
-- $1 = model_id
SELECT
    version,
    currency,
    input_rate,
    output_rate,
    cached_rate,
    source_url,
    billing_note,
    created_at
FROM model_prices
WHERE model_id = $1
ORDER BY version DESC;

-- Q10 用户累计费用：按模型与币种汇总
-- $1 = user_id
SELECT
    m.display_name,
    m.name AS model_id,
    p.currency,
    COUNT(c.id) AS calls,
    COALESCE(SUM(c.cost), 0) AS total_cost,
    COUNT(*) FILTER (WHERE c.cost IS NULL) AS unknown_calls
FROM tasks t
JOIN agent_runs r ON r.task_id = t.id
JOIN model_calls c ON c.run_id = r.id
JOIN model_prices p ON p.id = t.price_id
JOIN models m ON m.id = p.model_id
WHERE t.user_id = $1
GROUP BY m.display_name, m.name, p.currency
ORDER BY total_cost DESC;

-- Q11 对话内资料目录：模型可见的附件清单，跨轮次但同对话
-- $1 = conversation_id, $2 = user_id
SELECT
    m.id,
    m.name,
    m.kind,
    length(m.content) AS characters,
    t.created_at AS uploaded_at
FROM materials m
JOIN tasks t ON t.id = m.task_id
WHERE t.conversation_id = $1 AND t.user_id = $2
ORDER BY t.created_at, m.created_at;

-- Q12 工具调用审计：区分成功、拒绝、失败
-- $1 = task_id, $2 = user_id
SELECT
    tc.id,
    tc.tool,
    r.role,
    tc.status,
    tc.arguments,
    tc.output,
    tc.grant_id,
    tc.created_at
FROM tool_calls tc
JOIN agent_runs r ON r.id = tc.run_id
JOIN tasks t ON t.id = r.task_id
WHERE t.id = $1 AND t.user_id = $2
ORDER BY tc.created_at, tc.id;
