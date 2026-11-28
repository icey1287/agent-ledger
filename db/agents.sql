-- Additive upgrade: agents/task_agents are created by metadata (or schema.sql).
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS execution_mode VARCHAR(16) NOT NULL DEFAULT 'sequential';
ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS task_agent_id VARCHAR(36) REFERENCES task_agents(id);
ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS price_id VARCHAR(36) REFERENCES model_prices(id);
-- Existing runs retain exactly the price used before this upgrade.
UPDATE agent_runs r SET price_id = t.price_id FROM tasks t WHERE r.task_id = t.id AND r.price_id IS NULL;
ALTER TABLE agent_runs DROP CONSTRAINT IF EXISTS ck_agent_runs_role;
ALTER TABLE agent_runs ADD CONSTRAINT ck_agent_runs_role CHECK (role IN ('coordinator','summary','review','worker'));
DO $$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='ck_tasks_execution_mode' AND conrelid='tasks'::regclass) THEN
 ALTER TABLE tasks ADD CONSTRAINT ck_tasks_execution_mode CHECK (execution_mode IN ('sequential','parallel'));
END IF;
END $$;
