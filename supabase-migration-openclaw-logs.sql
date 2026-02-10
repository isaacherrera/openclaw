-- OpenClaw Logs Table
-- Run this in Supabase SQL Editor: https://supabase.com/dashboard
-- This stores all forwarded JSONL entries from OpenClaw sessions

CREATE TABLE openclaw_logs (
  id BIGSERIAL PRIMARY KEY,
  entry_id TEXT,                           -- JSONL entry "id" field
  parent_id TEXT,                          -- JSONL "parentId" for threading
  session_id TEXT,                         -- derived from file path
  type TEXT NOT NULL,                      -- message, custom, model_change, thinking_level_change
  subtype TEXT,                            -- for custom: "model-snapshot", "openclaw.cache-ttl"
  role TEXT,                               -- user, assistant, toolResult
  content TEXT,                            -- extracted human-readable text
  thinking TEXT,                           -- AI thinking/reasoning (from thinking blocks)
  tool_name TEXT,                          -- for toolCall/toolResult entries
  tool_call_id TEXT,                       -- links toolCall to its toolResult
  model TEXT,                              -- claude-opus-4-6, etc.
  provider TEXT,                           -- anthropic, openai, etc.
  stop_reason TEXT,                        -- stop, toolUse
  token_input INT,
  token_output INT,
  token_cache_read INT,
  token_cache_write INT,
  tokens_total INT,
  cost_total NUMERIC(10,6),
  is_error BOOLEAN DEFAULT FALSE,
  raw JSONB NOT NULL,                      -- FULL original JSONL line (nothing lost)
  entry_timestamp TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for common query patterns
CREATE INDEX idx_openclaw_logs_timestamp ON openclaw_logs(entry_timestamp DESC);
CREATE INDEX idx_openclaw_logs_session ON openclaw_logs(session_id);
CREATE INDEX idx_openclaw_logs_type ON openclaw_logs(type);
CREATE INDEX idx_openclaw_logs_entry_id ON openclaw_logs(entry_id);

-- Disable RLS to match existing table patterns (all security handled at application level)
ALTER TABLE openclaw_logs DISABLE ROW LEVEL SECURITY;
