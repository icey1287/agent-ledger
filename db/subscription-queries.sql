-- S1 当前用户订阅历史与有效资格；$1 由应用绑定 user_id。
SELECT id, plan_name, display_price, currency, starts_at, ends_at,
       CASE WHEN status='active' AND ends_at <= now() THEN 'expired' ELSE status END AS effective_status,
       (status='active' AND starts_at <= now() AND ends_at > now()) AS eligible
FROM subscriptions
WHERE user_id=$1
ORDER BY created_at DESC;

-- S2 按开通记录追溯任务与调用用量；套餐展示价不重复相加，也不当作实收。
SELECT s.id, s.plan_name, s.display_price AS plan_display_price, s.currency AS plan_currency,
       p.currency AS usage_currency,
       COUNT(DISTINCT t.id) AS tasks,
       COUNT(c.id) AS model_calls,
       COALESCE(SUM(c.cost),0) AS known_usage_cost,
       COUNT(c.id) FILTER (WHERE c.usage_status='unknown') AS unknown_calls
FROM subscriptions s
LEFT JOIN tasks t ON t.subscription_id=s.id AND t.user_id=s.user_id
LEFT JOIN model_prices p ON p.id=t.price_id
LEFT JOIN agent_runs r ON r.task_id=t.id
LEFT JOIN model_calls c ON c.run_id=r.id
WHERE s.user_id=$1
GROUP BY s.id, s.plan_name, s.display_price, s.currency, p.currency
ORDER BY s.created_at DESC;
-- 同一订阅的用量按任务价格版本币种分组，禁止将不同币种相加。
