-- Agent Desk 关键事务与扣费逻辑（2 号：数据库设计与实现）· v1.2
-- 同步三项变更：C1 调用快照费率 / C2 tasks 无 user_id / C3 grant_id 必填。
-- 统一加锁顺序：对话行 / 任务行 → 授权行 / 调用行。
-- 任何数据库锁都不跨外部模型 HTTP 请求：请求前短事务登记 in_flight，响应后另开事务结算。
-- 应用侧在某一步校验失败时应 ROLLBACK 并返回对应业务错误，不要继续执行。

SET client_encoding = 'UTF8';

-- ===========================================================================
-- T1 创建一轮消息：锁对话 → 互斥校验 → 固定价格版本 → 写入轮次 / 资料 / 授权
-- 参数：$1=conversation_id $2=user_id $3=model_id $4=price_id(由最新版本查得)
--       $5=task_id $6=message $7=budget
--       $8~$11=单条附件(id,name,kind,content)，按附件数循环
--       $12~$14=单条资料工具授权(id,tool,expires_at)，按选中工具循环
-- v1.2 C2/C3：$2 仅用于锁对话与归属校验，不写入 tasks；
--             未选中的资料工具须补 revoked_at=now() 的显式拒绝行，
--             delegate_summary / delegate_review 各建一行有效授权。
-- ===========================================================================
BEGIN;

-- 1) 锁定对话，保证同一对话串行发送
SELECT id FROM conversations WHERE id = $1 AND user_id = $2 FOR UPDATE;
-- 无行 → ROLLBACK，返回 404

-- 2) 互斥：活跃轮次或在途调用任一存在即拒绝
SELECT 1 FROM tasks t
JOIN conversations c ON c.id = t.conversation_id
WHERE t.conversation_id = $1 AND c.user_id = $2
  AND t.status IN ('pending', 'running')
LIMIT 1;
-- 有行 → ROLLBACK，返回 409“上一条回复仍在执行或结算”

SELECT 1
FROM model_calls c
JOIN agent_runs r ON r.id = c.run_id
JOIN tasks t ON t.id = r.task_id
JOIN conversations c2 ON c2.id = t.conversation_id
WHERE t.conversation_id = $1 AND c2.user_id = $2 AND c.status = 'in_flight'
LIMIT 1;
-- 有行 → ROLLBACK，返回 409

-- 3) 固定该轮价格版本（$3=model_id，取最大 version）
SELECT id AS price_id FROM model_prices
WHERE model_id = $3
ORDER BY version DESC
LIMIT 1;

-- 4) 写入轮次；价格版本一旦写入不再改变（user_id 由 conversation_id 推导，不入库）
INSERT INTO tasks
    (id, conversation_id, price_id, title, instruction, budget)
VALUES
    ($5, $1, $4, left($6, 60), $6, $7::numeric);

-- 5) 每个附件一行（应用循环绑定）
INSERT INTO materials (id, task_id, name, kind, content)
VALUES ($8, $5, $9, $10, $11);

-- 6) 每个工具授权一行；到期时间必须是带时区的未来时间
INSERT INTO task_tool_grants (id, task_id, tool, expires_at)
VALUES ($12, $5, $13, $14::timestamptz);

-- 7) 更新对话标题与更新时间
UPDATE conversations
SET updated_at = now(),
    title = CASE WHEN title = '新对话' THEN left($6, 60) ELSE title END
WHERE id = $1;

COMMIT;
-- 提交后才提交后台执行任务；提交前不发起任何模型请求。

-- ===========================================================================
-- T2 领取执行权：只有 pending 能转 running，重复领取返回 0 行
-- 参数：$1 = task_id
-- ===========================================================================
BEGIN;

SELECT id, status FROM tasks WHERE id = $1 FOR UPDATE;
-- 行不存在或 status <> 'pending' → COMMIT 后直接返回，不重复执行

UPDATE tasks SET status = 'running' WHERE id = $1 AND status = 'pending';

COMMIT;

-- ===========================================================================
-- T3 调用前检查 + 登记在途调用：短事务，提交后才调用供应商
-- 参数：$1=task_id $2=call_id $3=run_id
-- ===========================================================================
BEGIN;

SELECT id, status, budget FROM tasks WHERE id = $1 FOR UPDATE;
-- status <> 'running' → ROLLBACK，按当前状态停止（用户已停止 / 已中断等）

-- 未知用量优先：存在未确认调用则不得发起新调用
SELECT 1
FROM model_calls c
JOIN agent_runs r ON r.id = c.run_id
WHERE r.task_id = $1 AND c.usage_status = 'unknown'
LIMIT 1;
-- 有行 → ROLLBACK，任务置 awaiting_usage

-- 软预算：只累计已知费用；最后一次调用允许超额，超额在调用后判定
SELECT COALESCE(SUM(c.cost), 0) AS known_cost
FROM model_calls c
JOIN agent_runs r ON r.id = c.run_id
WHERE r.task_id = $1;
-- known_cost >= budget → ROLLBACK，任务置 stopped_budget

-- v1.2 C1：登记在途调用时即复制本轮默认价格版本的费率快照。
-- 后续即使改价或任务默认价格被调整，本次调用仍按快照结算。
INSERT INTO model_calls
    (id, run_id, price_id, currency, input_rate_snapshot, output_rate_snapshot,
     cached_rate_snapshot, rate_unit, status, usage_status)
SELECT $2, $3, p.id, p.currency, p.input_rate, p.output_rate, p.cached_rate,
       'per_1m_tokens', 'in_flight', 'unknown'
FROM tasks t
JOIN model_prices p ON p.id = t.price_id
WHERE t.id = $1;

COMMIT;
-- 此处才发出模型 HTTP 请求；不持有数据库锁。

-- ===========================================================================
-- T4 响应结算：一次调用一行记录，用量与费用在同一事务写入
-- 参数：$1=task_id $2=call_id $3=run_id $4=status('succeeded'/'failed')
--       $5=input_tokens $6=output_tokens $7=cached_tokens $8=cost
--       $9=raw_usage(json) $10=provider_request_id $11=response_text
-- 费用计算：((输入-缓存)*输入单价 + 缓存*缓存单价 + 输出*输出单价)/1000000
-- 单价来自本调用的 model_calls 费率快照（v1.2 C1），由 billing.calculate 用 Decimal 完成；
-- 不读取 model_prices 当前值，也不读取 tasks.price_id。
-- ===========================================================================
BEGIN;

-- 与取消 / 停止操作互斥
SELECT id FROM tasks WHERE id = $1 FOR UPDATE;

UPDATE model_calls
SET status = $4,
    usage_status = 'known',
    input_tokens = $5,
    output_tokens = $6,
    cached_tokens = $7,
    cost = $8::numeric,
    raw_usage = $9::json,
    provider_request_id = $10,
    response_text = $11,
    finished_at = now()
WHERE id = $2;

-- 只在调用返回文本时保存中间输出；run 的 completed 状态由角色产出最终结果时另行更新。
-- 工具调用阶段不把 run 置为 completed。
UPDATE agent_runs
SET output = $11
WHERE id = $3 AND $11 <> '';

COMMIT;

-- ---------------------------------------------------------------------------
-- T4b 未知用量分支：usage 缺失 / 非法 / 缓存无费率 / 超时 / 5xx
-- 费用保持 NULL，禁止写 0；任务进入 awaiting_usage，禁止继续调用。
-- 参数：$1=task_id $2=call_id $12=error_text
-- ---------------------------------------------------------------------------
BEGIN;

SELECT id FROM tasks WHERE id = $1 FOR UPDATE;

UPDATE model_calls
SET status = 'usage_unknown',
    usage_status = 'unknown',
    cost = NULL,
    error = $12,
    finished_at = now()
WHERE id = $2;

UPDATE tasks
SET status = 'awaiting_usage', reason = $12, finished_at = now()
WHERE id = $1 AND status = 'running';

COMMIT;

-- ===========================================================================
-- T5 工具执行：锁任务 → 锁授权，每次读取都有明确的授权判断时点
-- 参数：$1=task_id $2=tool $3=run_id $4=tool_call_id
--       $5=arguments(json) $6=status $7=output $8=grant_id(必填)
-- v1.2 C3：资料工具未获授权时 $8 指向显式拒绝行；委派工具指向预定义角色授权行。
-- ===========================================================================
BEGIN;

SELECT id, status FROM tasks WHERE id = $1 FOR UPDATE;
-- status <> 'running' → ROLLBACK，停止本轮

SELECT id, expires_at, revoked_at
FROM task_tool_grants
WHERE task_id = $1 AND tool = $2
FOR UPDATE;
-- 授权行在任务创建时已为四种工具各建一行；撤销或到期 → $6='denied'，仍写 grant_id
-- 资料范围：JOIN tasks → conversations 限定 conversation_id 相同、user_id 相同且 created_at <= 当前轮

INSERT INTO tool_calls (id, run_id, grant_id, tool, arguments, status, output)
VALUES ($4, $3, $8, $2, $5::json, $6, $7);

COMMIT;
-- $6='denied' → 由调用方把任务置 stopped_permission 并停止后续调度。

-- ===========================================================================
-- T6 管理员补录：锁任务 → 锁调用；以 usage_status 做幂等标记
-- 参数：$1=call_id $2=input_tokens $3=output_tokens $4=cached_tokens
--       $5=cost(按调用自身费率快照用 Decimal 计算) $6=admin_user_id $7=evidence
-- ===========================================================================
BEGIN;

-- 先拿到所属任务
SELECT r.task_id
FROM model_calls c
JOIN agent_runs r ON r.id = c.run_id
WHERE c.id = $1;
-- 无行 → ROLLBACK，404

SELECT id FROM tasks WHERE id = $8 FOR UPDATE;   -- $8 = 上一步得到的 task_id

SELECT * FROM model_calls WHERE id = $1 FOR UPDATE;
-- usage_status = 'known' → COMMIT，返回原 cost，already_reconciled = true（不重复计费）
-- status <> 'usage_unknown' → ROLLBACK，409“调用仍在进行，不能补录”

-- v1.2 C1：费率必须来自该调用的快照，不能用当前最新价格或任务默认价格
SELECT c.currency, c.input_rate_snapshot, c.output_rate_snapshot,
       c.cached_rate_snapshot, c.rate_unit
FROM model_calls c
WHERE c.id = $1;

UPDATE model_calls
SET input_tokens = $2,
    output_tokens = $3,
    cached_tokens = $4,
    cost = $5::numeric,
    usage_status = 'known',
    status = 'reconciled',
    reconciled_by = $6,
    evidence = $7,
    reconciled_at = now()
WHERE id = $1;

-- 未知项全部确认后解除待核实标志，但保留 interrupted，不自动续跑
UPDATE tasks t
SET status = 'interrupted',
    reason = '用量已核实，本次任务不自动恢复',
    finished_at = now()
WHERE t.id = $8
  AND t.status = 'awaiting_usage'
  AND NOT EXISTS (
      SELECT 1
      FROM model_calls c
      JOIN agent_runs r ON r.id = c.run_id
      WHERE r.task_id = $8 AND c.usage_status <> 'known'
  );

COMMIT;

-- ===========================================================================
-- 辅助 A 用户停止任务：在途调用不动，响应回来仍按 T4/T4b 结算
-- 参数：$1 = task_id
-- ===========================================================================
BEGIN;

SELECT id FROM tasks WHERE id = $1 FOR UPDATE;

UPDATE tasks
SET status = 'cancelled',
    reason = '用户停止任务；已发出的模型调用仍会记录用量',
    finished_at = now()
WHERE id = $1 AND status IN ('pending', 'running');

COMMIT;

-- ===========================================================================
-- 辅助 B 管理员改价：追加新版本，不覆盖历史；唯一约束兜底并发
-- 参数：$1=model_id $2=new_version $3=input_rate $4=output_rate
--       $5=cached_rate(可 NULL) $6=currency $7=source_url $8=billing_note
-- ===========================================================================
BEGIN;

SELECT id FROM models WHERE id = $1 FOR UPDATE;

INSERT INTO model_prices
    (id, model_id, version, currency, input_rate, output_rate, cached_rate, source_url, billing_note)
VALUES
    (gen_random_uuid()::text, $1, $2, $6, $3::numeric, $4::numeric,
     $5::numeric, $7, $8);
-- 唯一冲突 (model_id, version) → ROLLBACK，重新取最大 version 后重试

COMMIT;

-- ===========================================================================
-- 辅助 C 启动恢复：in_flight 视为用量未知；其余未完成任务标为中断
-- 单事务执行，不重发任何模型请求，不清除已确认费用。
-- ===========================================================================
BEGIN;

WITH recovered AS (
    UPDATE model_calls
    SET status = 'usage_unknown',
        error = '服务中断，供应商用量待核实',
        finished_at = now()
    WHERE status = 'in_flight'
    RETURNING run_id
)
UPDATE tasks t
SET status = 'awaiting_usage', reason = '服务中断，供应商用量待核实'
FROM recovered rc
JOIN agent_runs r ON r.id = rc.run_id
WHERE t.id = r.task_id;

UPDATE tasks
SET status = 'interrupted',
    reason = '服务已重启，本次任务没有自动恢复',
    finished_at = now()
WHERE status IN ('pending', 'running');

UPDATE agent_runs
SET status = 'interrupted', finished_at = now()
WHERE status = 'running';

COMMIT;
