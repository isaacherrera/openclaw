-- Dedup index: prevent duplicate log entries from truncation-triggered replays.
-- Partial index — only enforces uniqueness where entry_id is NOT NULL.
CREATE UNIQUE INDEX IF NOT EXISTS openclaw_logs_entry_id_session_id_uniq
  ON openclaw_logs (entry_id, session_id)
  WHERE entry_id IS NOT NULL;
