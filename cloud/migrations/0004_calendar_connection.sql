-- A Google Calendar connection is independent of the sign-in identity: users
-- keep their storage account while granting read access to any calendar
-- account they choose.
ALTER TABLE users ADD COLUMN google_calendar_refresh_token_cipher TEXT;
ALTER TABLE users ADD COLUMN google_calendar_email TEXT;
