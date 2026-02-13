-- Migration: Add tenant_id and external_api columns to openclaw_logs
-- Purpose: Multi-tenant cost tracking across APIs
-- Run this against the Supabase SQL editor

-- Tenant identification (which Fly app sent the log)
ALTER TABLE openclaw_logs ADD COLUMN IF NOT EXISTS tenant_id TEXT;

-- External API classification for exec tool calls
ALTER TABLE openclaw_logs ADD COLUMN IF NOT EXISTS external_api TEXT;

-- Indexes for dashboard queries
CREATE INDEX IF NOT EXISTS idx_openclaw_logs_tenant_ts
  ON openclaw_logs(tenant_id, entry_timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_openclaw_logs_ext_api
  ON openclaw_logs(tenant_id, external_api, entry_timestamp DESC);

-- Backfill existing logs (all current logs are from the primary instance)
UPDATE openclaw_logs SET tenant_id = 'cobroker-openclaw' WHERE tenant_id IS NULL;
