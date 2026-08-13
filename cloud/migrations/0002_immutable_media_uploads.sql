PRAGMA foreign_keys = ON;

-- Idempotent and non-destructive: legacy meeting media columns remain intact.
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
