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

-- Low-balance warning tracking (cron sets this, Stripe webhook clears it)
ALTER TABLE tenant_registry ADD COLUMN IF NOT EXISTS low_balance_warned_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_tenant_registry_user ON tenant_registry(user_id);
CREATE INDEX IF NOT EXISTS idx_tenant_registry_status ON tenant_registry(status);

-- 3. USD Balance: User's total dollar budget
CREATE TABLE IF NOT EXISTS usd_balance (
  user_id UUID PRIMARY KEY REFERENCES user_identity_map(app_user_id),
  total_budget_usd NUMERIC(10,2) DEFAULT 10.00,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. Pricing Config: Editable per-service costs and global markup multiplier
CREATE TABLE IF NOT EXISTS pricing_config (
  service_key   TEXT PRIMARY KEY,
  label         TEXT NOT NULL,
  cost_per_unit NUMERIC(10,6) NOT NULL,
  note          TEXT,
  sort_order    INT DEFAULT 0,
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

-- Seed with current cost values (no-op if already populated)
INSERT INTO pricing_config (service_key, label, cost_per_unit, note, sort_order) VALUES
  ('_multiplier',      'Markup Multiplier',   4.000000, 'Global multiplier applied to all costs', 0),
  ('llm',              'Claude (LLM)',        0.000000, 'Actual cost from API response (varies per request)', 1),
  ('brave',            'Brave Search',        0.005000, NULL, 2),
  ('gemini',           'Gemini',              0.001000, NULL, 3),
  ('parallel-findall', 'Parallel AI FindAll', 2.500000, NULL, 4),
  ('parallel-ultra',   'Parallel AI Ultra',   0.300000, NULL, 5),
  ('parallel-ai',      'Parallel AI',         0.300000, 'Fallback tier', 6),
  ('google-places',    'Google Places',       0.032000, NULL, 7),
  ('esri',             'ESRI',                0.010000, NULL, 8),
  ('app-features',     'App Features',        0.005000, 'Per credit used', 9)
ON CONFLICT (service_key) DO NOTHING;

-- 5. View: Joins budget with actual spend, reads costs from pricing_config table
CREATE OR REPLACE VIEW v_user_usd_balance AS
SELECT
  ub.user_id,
  ub.total_budget_usd,
  (COALESCE(llm.spent, 0) * m.markup)::NUMERIC(10,6) AS llm_spent_usd,
  (COALESCE(ext.spent, 0) * m.markup)::NUMERIC(10,6) AS ext_spent_usd,
  (COALESCE(app.spent, 0) * m.markup)::NUMERIC(10,6) AS app_spent_usd,
  (ub.total_budget_usd
    - COALESCE(llm.spent, 0) * m.markup
    - COALESCE(ext.spent, 0) * m.markup
    - COALESCE(app.spent, 0) * m.markup)::NUMERIC(10,6) AS remaining_usd
FROM usd_balance ub
CROSS JOIN (
  SELECT cost_per_unit AS markup
  FROM pricing_config WHERE service_key = '_multiplier'
) m
LEFT JOIN (
  -- LLM: actual cost from Claude API response (unchanged)
  SELECT tr.user_id, SUM(ol.cost_total) AS spent
  FROM tenant_registry tr
  JOIN openclaw_logs ol ON ol.tenant_id = tr.fly_app_name
  WHERE ol.role = 'assistant' AND ol.cost_total > 0
  GROUP BY tr.user_id
) llm ON llm.user_id = ub.user_id
LEFT JOIN (
  -- External APIs: cost_per_unit from pricing_config table
  SELECT tr.user_id, SUM(COALESCE(pc.cost_per_unit, 0)) AS spent
  FROM tenant_registry tr
  JOIN openclaw_logs ol ON ol.tenant_id = tr.fly_app_name
  LEFT JOIN pricing_config pc ON pc.service_key = ol.external_api
  WHERE ol.external_api IS NOT NULL
    AND ol.external_api != 'anthropic'
  GROUP BY tr.user_id
) ext ON ext.user_id = ub.user_id
LEFT JOIN (
  -- App features: read per-credit rate from pricing_config
  SELECT cul.user_id,
    SUM(cul.credits_charged * COALESCE(pc.cost_per_unit, 0.005)) AS spent
  FROM credit_usage_log cul
  LEFT JOIN pricing_config pc ON pc.service_key = 'app-features'
  WHERE cul.success = true
  GROUP BY cul.user_id
) app ON app.user_id = ub.user_id;
