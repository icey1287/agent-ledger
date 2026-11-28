-- Agent Desk 演示数据（2 号：数据库设计与实现）· v1.2
-- 固定 ID，便于文档和接口联调引用；ON CONFLICT DO NOTHING 保证可重复执行。
-- 密码哈希为占位值，不能用于真实登录；真实值由 Argon2id 生成。
-- 金额单位 USD，精度与 NUMERIC(24,12) 一致；费率单位统一 per_1m_tokens。
-- v1.2 同步点：tasks 保留 user_id（订阅复合外键依赖，由触发器保证与对话一致）；model_calls 带费率快照；每个工具调用都有 grant_id。

SET client_encoding = 'UTF8';

-- ---------------------------------------------------------------------------
-- 账号与会话
-- ---------------------------------------------------------------------------
INSERT INTO users (id, created_at, username, password_hash, role) VALUES
('u-admin', '2026-11-20T08:50:00+00:00', 'admin', 'ARGON2ID_PLACEHOLDER_ADMIN', 'admin'),
('u-alice', '2026-11-20T08:55:00+00:00', 'alice', 'ARGON2ID_PLACEHOLDER_ALICE', 'user'),
('u-bob',   '2026-11-23T08:30:00+00:00', 'bob',   'ARGON2ID_PLACEHOLDER_BOB',   'user')
ON CONFLICT (id) DO NOTHING;

INSERT INTO sessions (id, created_at, user_id, token_hash, csrf_token, expires_at) VALUES
('s-alice-01', '2026-11-25T09:00:00+00:00', 'u-alice',
 'demo_sha256_token_hash_alice_0000000000000000000000000000001',
 'demo_csrf_alice_0000000000000000000000000000001', '2026-12-02T09:00:00+00:00'),
('s-bob-01', '2026-11-25T10:00:00+00:00', 'u-bob',
 'demo_sha256_token_hash_bob_00000000000000000000000000000001',
 'demo_csrf_bob_0000000000000000000000000000000001', '2026-12-02T10:00:00+00:00')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 模型目录与价格版本：v2 演示“改价生成新版本”，历史轮次仍固定 v1
-- ---------------------------------------------------------------------------
INSERT INTO models (id, created_at, name, display_name, enabled) VALUES
('m-minimax', '2026-11-20T08:56:00+00:00', 'minimax/minimax-m3.1-flash:free', 'MiniMax M3.1 Flash (free)', TRUE),
('m-gpt',     '2026-11-21T08:00:00+00:00', 'openai/gpt-4o-mini',              'GPT-4o mini',               TRUE),
('m-retired', '2026-11-19T08:00:00+00:00', 'old/model',                       '旧模型（已停用）',          FALSE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO model_prices
(id, created_at, model_id, version, currency, input_rate, output_rate, cached_rate, source_url, billing_note) VALUES
('p-minimax-v1', '2026-11-20T08:56:00+00:00', 'm-minimax', 1, 'USD',
 0.500000000000, 2.000000000000, 0.100000000000, '',
 '演示费率；实际调用 OpenRouter 免费接口，并非供应商实际扣费。'),
('p-minimax-v2', '2026-11-24T08:00:00+00:00', 'm-minimax', 2, 'USD',
 0.600000000000, 2.500000000000, 0.120000000000, 'https://openrouter.ai/models',
 '调整后的演示费率；仅新轮次使用。'),
('p-gpt-v1', '2026-11-21T08:00:00+00:00', 'm-gpt', 1, 'USD',
 0.150000000000, 0.600000000000, NULL, '', '无缓存费率的演示价格。'),
('p-retired-v1', '2026-11-19T08:00:00+00:00', 'm-retired', 1, 'USD',
 1.000000000000, 1.000000000000, NULL, '', '已停用模型保留历史价格。')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 对话与轮次
-- ---------------------------------------------------------------------------
INSERT INTO conversations (id, created_at, user_id, title, updated_at) VALUES
('c-alice-1', '2026-11-20T09:00:00+00:00', 'u-alice', '项目周报摘要', '2026-11-20T09:11:00+00:00'),
('c-alice-2', '2026-11-22T14:00:00+00:00', 'u-alice', '合同要点核对', '2026-11-22T14:02:00+00:00'),
('c-bob-1',   '2026-11-23T08:35:00+00:00', 'u-bob',   '待办清单整理', '2026-11-23T08:36:00+00:00')
ON CONFLICT (id) DO NOTHING;

-- v1.2 C2：user_id 保留（订阅复合外键依赖），值与 conversation.user_id 一致并由触发器强制
INSERT INTO tasks
(id, created_at, conversation_id, user_id, price_id, title, instruction, budget, status, result, reason, finished_at) VALUES
('t-alice-1', '2026-11-20T09:01:00+00:00', 'c-alice-1', 'u-alice', 'p-minimax-v1',
 '整理会议纪要', '请把会议纪要整理成项目周报', 0.010000000000, 'completed',
 '本周完成了数据库设计与接口联调，下一步是补充回归测试。', '', '2026-11-20T09:03:00+00:00'),
('t-alice-2', '2026-11-20T09:10:00+00:00', 'c-alice-1', 'u-alice', 'p-minimax-v1',
 '核对预算表', '读取预算表并列出超额项目', 0.000500000000, 'stopped_budget',
 '', '费用已达到预算，后续调用已停止；最后一次调用可能超额', '2026-11-20T09:11:00+00:00'),
('t-alice-3', '2026-11-22T14:01:00+00:00', 'c-alice-2', 'u-alice', 'p-minimax-v2',
 '核对合同条款', '检查合同中的交付与违约条款', 0.010000000000, 'awaiting_usage',
 '', '模型连接中断或超时，用量待核实', '2026-11-22T14:02:00+00:00'),
('t-bob-1', '2026-11-23T08:35:00+00:00', 'c-bob-1', 'u-bob', 'p-minimax-v1',
 '整理待办', '把待办清单按优先级排序', 0.010000000000, 'cancelled',
 '', '用户停止任务；已发出的模型调用仍会记录用量', '2026-11-23T08:36:00+00:00')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 资料：同一对话后续轮次可见，但每次读取仍检查本轮授权
-- ---------------------------------------------------------------------------
INSERT INTO materials (id, created_at, task_id, name, kind, content) VALUES
('mat-01', '2026-11-20T09:01:00+00:00', 't-alice-1', '会议纪要.txt', 'txt',
 '周一：确认数据库表结构。周三：完成接口联调。周五：补充用量与费用展示。'),
('mat-02', '2026-11-20T09:01:00+00:00', 't-alice-1', '粘贴资料', 'text',
 '项目本周状态：数据库设计完成，前后端接口已对齐。'),
('mat-03', '2026-11-20T09:10:00+00:00', 't-alice-2', '项目预算.pdf', 'pdf',
 '前端 300 USD；后端 400 USD；模型调用 200 USD。'),
('mat-04', '2026-11-22T14:01:00+00:00', 't-alice-3', '合同条款.txt', 'txt',
 '交付时间：每月 15 日。逾期按日 0.5% 计违约金。'),
('mat-05', '2026-11-23T08:35:00+00:00', 't-bob-1', '待办清单.txt', 'txt',
 '1. 写报告 2. 复测费用边界 3. 整理演示数据')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 每轮工具授权：覆盖有效、已撤销、已过期、显式拒绝四种状态。
-- v1.2 C3：资料工具即使未获授权也保留一行（revoked_at 非空），
--          委派工具按 EXEC-01 预定义角色各保留一行有效授权。
-- ---------------------------------------------------------------------------
INSERT INTO task_tool_grants (id, created_at, task_id, tool, expires_at, revoked_at) VALUES
('g-alice-01-read',   '2026-11-20T09:01:00+00:00', 't-alice-1', 'read_material',    NULL, NULL),
('g-alice-01-search', '2026-11-20T09:01:00+00:00', 't-alice-1', 'search_materials', NULL, NULL),
('g-alice-02-read',   '2026-11-20T09:10:00+00:00', 't-alice-2', 'read_material',    '2026-12-31T00:00:00+00:00', NULL),
('g-alice-02-search', '2026-11-20T09:10:00+00:00', 't-alice-2', 'search_materials', NULL, '2026-11-20T09:12:00+00:00'),
('g-alice-03-read',   '2026-11-22T14:01:00+00:00', 't-alice-3', 'read_material',    '2026-11-22T15:00:00+00:00', NULL),
('g-alice-03-search', '2026-11-22T14:01:00+00:00', 't-alice-3', 'search_materials', NULL, '2026-11-22T14:01:00+00:00'),
('g-bob-01-read',     '2026-11-23T08:35:00+00:00', 't-bob-1',   'read_material',    NULL, '2026-11-23T08:35:00+00:00'),
('g-bob-01-search',   '2026-11-23T08:35:00+00:00', 't-bob-1',   'search_materials', NULL, '2026-11-23T08:35:00+00:00'),
('g-alice-01-dsum',   '2026-11-20T09:01:00+00:00', 't-alice-1', 'delegate_summary', NULL, NULL),
('g-alice-01-drev',   '2026-11-20T09:01:00+00:00', 't-alice-1', 'delegate_review',  NULL, NULL),
('g-alice-02-dsum',   '2026-11-20T09:10:00+00:00', 't-alice-2', 'delegate_summary', NULL, NULL),
('g-alice-02-drev',   '2026-11-20T09:10:00+00:00', 't-alice-2', 'delegate_review',  NULL, NULL),
('g-alice-03-dsum',   '2026-11-22T14:01:00+00:00', 't-alice-3', 'delegate_summary', NULL, NULL),
('g-alice-03-drev',   '2026-11-22T14:01:00+00:00', 't-alice-3', 'delegate_review',  NULL, NULL),
('g-bob-01-dsum',     '2026-11-23T08:35:00+00:00', 't-bob-1',   'delegate_summary', NULL, NULL),
('g-bob-01-drev',     '2026-11-23T08:35:00+00:00', 't-bob-1',   'delegate_review',  NULL, NULL)
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Agent 执行记录：子执行通过 parent_id 体现委派关系
-- ---------------------------------------------------------------------------
INSERT INTO agent_runs
(id, created_at, task_id, parent_id, role, status, instruction, output, finished_at) VALUES
('r-alice-01', '2026-11-20T09:01:10+00:00', 't-alice-1', NULL,         'coordinator', 'completed', '请把会议纪要整理成项目周报', '本周完成了数据库设计与接口联调，下一步是补充回归测试。', '2026-11-20T09:03:00+00:00'),
('r-alice-02', '2026-11-20T09:01:30+00:00', 't-alice-1', 'r-alice-01', 'summary',     'completed', '提取三条关键进展', '数据库设计完成；接口联调完成；费用展示待补充。', '2026-11-20T09:02:00+00:00'),
('r-alice-03', '2026-11-20T09:02:10+00:00', 't-alice-1', 'r-alice-01', 'review',      'completed', '核对摘要是否遗漏', '摘要与资料一致。', '2026-11-20T09:02:40+00:00'),
('r-alice-04', '2026-11-20T09:10:10+00:00', 't-alice-2', NULL,         'coordinator', 'stopped',    '读取预算表并列出超额项目', '', '2026-11-20T09:11:00+00:00'),
('r-alice-05', '2026-11-22T14:01:10+00:00', 't-alice-3', NULL,         'coordinator', 'stopped',    '检查合同中的交付与违约条款', '', '2026-11-22T14:02:00+00:00'),
('r-bob-01',   '2026-11-23T08:35:10+00:00', 't-bob-1',   NULL,         'coordinator', 'stopped',    '把待办清单按优先级排序', '', '2026-11-23T08:36:00+00:00')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 模型调用与费用
-- 费用 = ((输入 - 缓存) * 输入单价 + 缓存 * 缓存单价 + 输出 * 输出单价) / 1,000,000
-- call-01: (800*0.50 + 200*0.10 + 100*2.00)/1e6 = 0.000620000000
-- call-02: (800*0.50 +   0*0.10 + 300*2.00)/1e6 = 0.001000000000
-- call-03: (500*0.50 + 100*0.10 + 200*2.00)/1e6 = 0.000660000000
-- call-04: (1200*0.50 +  0*0.10 + 400*2.00)/1e6 = 0.001400000000（最后一次调用超过软预算）
-- call-05: 用量未知，cost = NULL，不得记 0
-- call-06: 供应商明确拒绝，可确定零用量，记已知 0
-- ---------------------------------------------------------------------------
-- v1.2 C1：每笔调用写入实际费率快照。call-01~04 来自 p-minimax-v1，
-- call-05 来自 p-minimax-v2，call-06 来自 p-minimax-v1（供应商明确拒绝，零用量）。
INSERT INTO model_calls
(id, created_at, run_id, price_id, currency, input_rate_snapshot, output_rate_snapshot,
 cached_rate_snapshot, rate_unit, provider_request_id, status, usage_status,
 input_tokens, output_tokens, cached_tokens, cost, raw_usage, response_text, error, finished_at) VALUES
('call-01', '2026-11-20T09:01:15+00:00', 'r-alice-01', 'p-minimax-v1', 'USD',
 0.500000000000, 2.000000000000, 0.100000000000, 'per_1m_tokens', 'gen-001', 'succeeded', 'known',
 1000, 100, 200, 0.000620000000,
 '{"prompt_tokens":1000,"completion_tokens":100,"prompt_tokens_details":{"cached_tokens":200}}'::json,
 '', '', '2026-11-20T09:01:25+00:00'),
('call-02', '2026-11-20T09:01:40+00:00', 'r-alice-02', 'p-minimax-v1', 'USD',
 0.500000000000, 2.000000000000, 0.100000000000, 'per_1m_tokens', 'gen-002', 'succeeded', 'known',
 800, 300, 0, 0.001000000000,
 '{"prompt_tokens":800,"completion_tokens":300,"prompt_tokens_details":{"cached_tokens":0}}'::json,
 '', '', '2026-11-20T09:01:55+00:00'),
('call-03', '2026-11-20T09:02:20+00:00', 'r-alice-03', 'p-minimax-v1', 'USD',
 0.500000000000, 2.000000000000, 0.100000000000, 'per_1m_tokens', 'gen-003', 'succeeded', 'known',
 600, 200, 100, 0.000660000000,
 '{"prompt_tokens":600,"completion_tokens":200,"prompt_tokens_details":{"cached_tokens":100}}'::json,
 '', '', '2026-11-20T09:02:35+00:00'),
('call-04', '2026-11-20T09:10:20+00:00', 'r-alice-04', 'p-minimax-v1', 'USD',
 0.500000000000, 2.000000000000, 0.100000000000, 'per_1m_tokens', 'gen-004', 'succeeded', 'known',
 1200, 400, 0, 0.001400000000,
 '{"prompt_tokens":1200,"completion_tokens":400,"prompt_tokens_details":{"cached_tokens":0}}'::json,
 '', '', '2026-11-20T09:10:40+00:00'),
('call-05', '2026-11-22T14:01:20+00:00', 'r-alice-05', 'p-minimax-v2', 'USD',
 0.600000000000, 2.500000000000, 0.120000000000, 'per_1m_tokens', NULL, 'usage_unknown', 'unknown',
 NULL, NULL, NULL, NULL, NULL,
 '', '模型连接中断或超时，用量待核实', '2026-11-22T14:02:00+00:00'),
('call-06', '2026-11-23T08:35:20+00:00', 'r-bob-01', 'p-minimax-v1', 'USD',
 0.500000000000, 2.000000000000, 0.100000000000, 'per_1m_tokens', NULL, 'failed', 'known',
 0, 0, 0, 0.000000000000, NULL,
 '', '供应商拒绝请求（HTTP 429），请检查模型、密钥、上下文或供应商额度', '2026-11-23T08:35:25+00:00')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 工具调用审计：v1.2 C3 要求每笔调用都有 grant_id，
-- tc-03 挂委派角色授权行；tc-07 挂显式拒绝的授权行。
-- ---------------------------------------------------------------------------
INSERT INTO tool_calls (id, created_at, run_id, grant_id, tool, arguments, status, output) VALUES
('tc-01', '2026-11-20T09:01:20+00:00', 'r-alice-01', 'g-alice-01-read',
 'read_material', '{"material_id":"mat-01"}'::json, 'completed', '会议纪要全文'),
('tc-02', '2026-11-20T09:01:30+00:00', 'r-alice-01', 'g-alice-01-search',
 'search_materials', '{"query":"联调"}'::json, 'completed', '[{"id":"mat-01","position":18}]'),
('tc-03', '2026-11-20T09:01:35+00:00', 'r-alice-01', 'g-alice-01-dsum',
 'delegate_summary', '{"instruction":"提取三条关键进展"}'::json, 'completed', '摘要已生成'),
('tc-04', '2026-11-20T09:01:45+00:00', 'r-alice-02', 'g-alice-01-read',
 'read_material', '{"material_id":"mat-02"}'::json, 'completed', '粘贴资料全文'),
('tc-05', '2026-11-20T09:10:30+00:00', 'r-alice-04', 'g-alice-02-search',
 'search_materials', '{"query":"超额"}'::json, 'denied', '工具未获授权、已撤销或已过期'),
('tc-06', '2026-11-22T14:01:30+00:00', 'r-alice-05', 'g-alice-03-read',
 'read_material', '{"material_id":"mat-04"}'::json, 'denied', '工具未获授权、已撤销或已过期'),
('tc-07', '2026-11-23T08:35:30+00:00', 'r-bob-01', 'g-bob-01-read',
 'read_material', '{"material_id":"mat-05"}'::json, 'denied', '工具未获授权、已撤销或已过期')
ON CONFLICT (id) DO NOTHING;
