-- Migration: Backfill provider, model, usage, cost, and external_api from raw JSONB
-- Purpose: Fix ~4300 entries where structured fields are null because the ingestion
--          code was reading from the wrong nesting level (top-level instead of raw.message).
-- Run this against the Supabase SQL editor AFTER deploying the fixed ingestion code.

-- Step 1: Backfill provider and model from raw->message (for message-type entries)
UPDATE openclaw_logs
SET
  provider = COALESCE(raw->'message'->>'provider', raw->>'provider', raw->'data'->>'provider'),
  model    = COALESCE(raw->'message'->>'model', raw->>'model', raw->>'modelId', raw->'data'->>'modelId')
WHERE provider IS NULL
  AND raw IS NOT NULL;

-- Step 2: Backfill token counts and cost from raw->message->usage
UPDATE openclaw_logs
SET
  token_input       = (raw->'message'->'usage'->>'input')::numeric,
  token_output      = (raw->'message'->'usage'->>'output')::numeric,
  token_cache_read  = (raw->'message'->'usage'->>'cacheRead')::numeric,
  token_cache_write = (raw->'message'->'usage'->>'cacheWrite')::numeric,
  tokens_total      = (raw->'message'->'usage'->>'totalTokens')::numeric,
  cost_total        = (raw->'message'->'usage'->'cost'->>'total')::numeric,
  stop_reason       = COALESCE(raw->'message'->>'stopReason', raw->>'stopReason')
WHERE token_input IS NULL
  AND raw->'message'->'usage' IS NOT NULL;

-- Step 3: Classify external_api = 'anthropic' for assistant messages with cost data
UPDATE openclaw_logs
SET external_api = 'anthropic'
WHERE external_api IS NULL
  AND role = 'assistant'
  AND COALESCE(raw->'message'->>'provider', raw->>'provider') = 'anthropic'
  AND (raw->'message'->'usage'->'cost'->>'total')::numeric > 0;

-- Step 4: Classify external_api for exec tool calls by pattern-matching the raw content
UPDATE openclaw_logs
SET external_api = CASE
  WHEN raw->'message'->'content'->0->'args'->>'command' LIKE '%generativelanguage.googleapis.com%' THEN 'gemini'
  WHEN raw->'message'->'content'->0->'args'->>'command' LIKE '%api.parallel.ai%' THEN 'parallel-ai'
  WHEN raw->'message'->'content'->0->'args'->>'command' LIKE '%/places/%' THEN 'google-places'
  WHEN raw->'message'->'content'->0->'args'->>'command' LIKE '%/demographics%' THEN 'esri'
  WHEN raw->'message'->'content'->0->'args'->>'command' LIKE '%api.search.brave.com%' THEN 'brave'
END
WHERE external_api IS NULL
  AND tool_name = 'exec'
  AND raw->'message'->'content'->0->'args'->>'command' IS NOT NULL;

-- Verify results
SELECT
  COUNT(*) as total,
  COUNT(provider) as with_provider,
  COUNT(cost_total) as with_cost,
  COUNT(external_api) as with_external_api,
  SUM(CASE WHEN external_api = 'anthropic' THEN 1 ELSE 0 END) as anthropic_entries,
  SUM(cost_total) as total_anthropic_cost
FROM openclaw_logs;
