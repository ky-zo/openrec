-- A user can connect any number of Google Calendar accounts; events from all
-- of them merge into one list. The sign-in identity is unaffected.
CREATE TABLE IF NOT EXISTS calendar_connections (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  email TEXT NOT NULL,
  refresh_token_cipher TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(user_id, email)
);
CREATE INDEX IF NOT EXISTS idx_calendar_connections_user ON calendar_connections(user_id);

-- Carry over single-connection rows from the previous model.
INSERT OR IGNORE INTO calendar_connections (id, user_id, email, refresh_token_cipher, created_at)
  SELECT lower(hex(randomblob(16))), id, COALESCE(google_calendar_email, email), google_calendar_refresh_token_cipher, updated_at
  FROM users WHERE google_calendar_refresh_token_cipher IS NOT NULL;
