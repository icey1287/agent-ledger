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
