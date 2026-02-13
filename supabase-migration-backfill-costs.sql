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

-- Step 3: Classify external_api = 'anthropic' for assistant messages with cost data.
-- IMPORTANT: Exclude exec tool calls — those get classified by Step 4 based on the curl command.
UPDATE openclaw_logs
SET external_api = 'anthropic'
WHERE external_api IS NULL
  AND role = 'assistant'
  AND tool_name IS DISTINCT FROM 'exec'
  AND COALESCE(raw->'message'->>'provider', raw->>'provider') = 'anthropic'
  AND (raw->'message'->'usage'->'cost'->>'total')::numeric > 0;

-- Step 4: Classify external_api for exec tool calls by pattern-matching the raw content.
-- The toolCall block uses "arguments" (not "args") and may be at any index in the content array.
UPDATE openclaw_logs ol
SET external_api = sub.api
FROM (
  SELECT ol2.id,
    CASE
      WHEN cmd LIKE '%generativelanguage.googleapis.com%' THEN 'gemini'
      WHEN cmd LIKE '%api.parallel.ai%' THEN 'parallel-ai'
      WHEN cmd LIKE '%/places/%' THEN 'google-places'
      WHEN cmd LIKE '%/demographics%' THEN 'esri'
      WHEN cmd LIKE '%api.search.brave.com%' THEN 'brave'
    END AS api
  FROM openclaw_logs ol2,
    LATERAL (
      SELECT elem->>'command' AS cmd
      FROM jsonb_array_elements(ol2.raw->'message'->'content') block,
           LATERAL (SELECT COALESCE(block->'arguments', block->'args') AS elem) x
      WHERE block->>'type' = 'toolCall'
        AND elem->>'command' IS NOT NULL
      LIMIT 1
    ) tc
  WHERE ol2.external_api IS NULL
    AND ol2.tool_name = 'exec'
) sub
WHERE ol.id = sub.id
  AND sub.api IS NOT NULL;

-- Verify results (summary)
SELECT
  COUNT(*) as total,
  COUNT(provider) as with_provider,
  COUNT(cost_total) as with_cost,
  COUNT(external_api) as with_external_api,
  SUM(CASE WHEN external_api = 'anthropic' THEN 1 ELSE 0 END) as anthropic_entries,
  SUM(cost_total) as total_anthropic_cost
FROM openclaw_logs;

-- Verify results (by external_api)
SELECT external_api, COUNT(*) as count
FROM openclaw_logs
WHERE external_api IS NOT NULL
GROUP BY external_api
ORDER BY count DESC;
