-- Retain cancelled delivery evidence without reporting it as a successful Telegram send.
ALTER TABLE notifications ADD COLUMN superseded_at INTEGER;
