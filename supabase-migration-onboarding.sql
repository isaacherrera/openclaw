-- ============================================================
-- ClawBroker Self-Service Onboarding — Database Migration
-- Run against the shared CoBroker Supabase instance
-- ============================================================

-- 1. Bot Pool: Pre-created Telegram bots paired with pre-deployed Fly VMs
CREATE TABLE IF NOT EXISTS bot_pool (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bot_token TEXT NOT NULL,
  bot_username TEXT NOT NULL,
  fly_app_name TEXT NOT NULL,
  fly_machine_id TEXT,
  assigned_to UUID REFERENCES user_identity_map(app_user_id),
  status TEXT DEFAULT 'available' CHECK (status IN ('available', 'assigned', 'retired')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  assigned_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_bot_pool_status ON bot_pool(status);
CREATE INDEX IF NOT EXISTS idx_bot_pool_assigned ON bot_pool(assigned_to);

-- 2. Tenant Registry: Links users to their bot + VM
CREATE TABLE IF NOT EXISTS tenant_registry (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES user_identity_map(app_user_id),
  bot_id UUID REFERENCES bot_pool(id),
  fly_app_name TEXT,
  telegram_user_id TEXT,
  telegram_username TEXT,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'provisioning', 'active', 'suspended', 'terminated')),
  provisioned_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tenant_registry_user ON tenant_registry(user_id);
CREATE INDEX IF NOT EXISTS idx_tenant_registry_status ON tenant_registry(status);

-- 3. USD Balance: User's total dollar budget
CREATE TABLE IF NOT EXISTS usd_balance (
  user_id UUID PRIMARY KEY REFERENCES user_identity_map(app_user_id),
  total_budget_usd NUMERIC(10,2) DEFAULT 10.00,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. View: Joins budget with actual spend from LLM costs + app feature costs
CREATE OR REPLACE VIEW v_user_usd_balance AS
SELECT
  ub.user_id,
  ub.total_budget_usd,
  COALESCE(llm.spent, 0)::NUMERIC(10,6) AS llm_spent_usd,
  COALESCE(app.spent, 0)::NUMERIC(10,6) AS app_spent_usd,
  (ub.total_budget_usd - COALESCE(llm.spent, 0) - COALESCE(app.spent, 0))::NUMERIC(10,6) AS remaining_usd
FROM usd_balance ub
LEFT JOIN (
  SELECT tr.user_id, SUM(ol.cost_total) AS spent
  FROM tenant_registry tr
  JOIN openclaw_logs ol ON ol.tenant_id = tr.fly_app_name
  WHERE ol.role = 'assistant' AND ol.cost_total > 0
  GROUP BY tr.user_id
) llm ON llm.user_id = ub.user_id
LEFT JOIN (
  SELECT user_id, SUM(credits_charged * 0.005) AS spent
  FROM credit_usage_log
  WHERE success = true
  GROUP BY user_id
) app ON app.user_id = ub.user_id;
