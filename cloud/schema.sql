PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  google_sub TEXT NOT NULL UNIQUE,
  email TEXT NOT NULL,
  name TEXT,
  avatar_url TEXT,
  google_refresh_token_cipher TEXT,
  google_calendar_refresh_token_cipher TEXT,
  google_calendar_email TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS auth_codes (
  code_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS meetings (
  id TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  started_at TEXT NOT NULL,
  ended_at TEXT NOT NULL,
  duration_seconds INTEGER NOT NULL,
  call_app TEXT,
  call_title TEXT,
  transcript TEXT,
  title TEXT NOT NULL,
  summary TEXT NOT NULL,
  ai_notes TEXT NOT NULL DEFAULT '',
  participants_json TEXT NOT NULL,
  action_items_json TEXT NOT NULL,
  decisions_json TEXT NOT NULL,
  screen_object_key TEXT,
  audio_object_key TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (id, user_id)
);

CREATE INDEX IF NOT EXISTS meetings_user_started_idx ON meetings(user_id, started_at DESC);
CREATE INDEX IF NOT EXISTS sessions_expiry_idx ON sessions(expires_at);

-- Immutable managed-media pointers. Existing screen_object_key/audio_object_key
-- columns remain populated for backwards compatibility and as a legacy fallback.
CREATE TABLE IF NOT EXISTS meeting_media (
  meeting_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('screen', 'audio')),
  object_key TEXT NOT NULL UNIQUE,
  generation TEXT NOT NULL,
  etag TEXT NOT NULL,
  version TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (meeting_id, user_id, kind),
  FOREIGN KEY (meeting_id, user_id) REFERENCES meetings(id, user_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS media_uploads (
  id TEXT PRIMARY KEY,
  r2_upload_id TEXT NOT NULL UNIQUE,
  meeting_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('screen', 'audio')),
  object_key TEXT NOT NULL UNIQUE,
  generation TEXT NOT NULL,
  replaces_object_key TEXT,
  replaces_generation TEXT,
  status TEXT NOT NULL CHECK (status IN ('uploading', 'completing', 'completed', 'attached', 'aborted')),
  completion_parts_json TEXT,
  completed_etag TEXT,
  completed_version TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (meeting_id, user_id) REFERENCES meetings(id, user_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS media_upload_parts (
  upload_id TEXT NOT NULL REFERENCES media_uploads(id) ON DELETE CASCADE,
  part_number INTEGER NOT NULL CHECK (part_number BETWEEN 1 AND 10000),
  etag TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (upload_id, part_number)
);

CREATE TABLE IF NOT EXISTS meeting_deletions (
  meeting_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (meeting_id, user_id)
);

CREATE INDEX IF NOT EXISTS meeting_media_user_meeting_idx ON meeting_media(user_id, meeting_id);
CREATE INDEX IF NOT EXISTS media_uploads_owner_idx ON media_uploads(user_id, meeting_id, kind, status);

CREATE TABLE IF NOT EXISTS calendar_connections (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  email TEXT NOT NULL,
  refresh_token_cipher TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(user_id, email)
);
CREATE INDEX IF NOT EXISTS idx_calendar_connections_user ON calendar_connections(user_id);
