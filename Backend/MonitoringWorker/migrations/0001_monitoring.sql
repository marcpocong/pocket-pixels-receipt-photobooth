CREATE TABLE devices (id TEXT PRIMARY KEY, last_seen INTEGER NOT NULL, state_json TEXT NOT NULL);
CREATE TABLE incidents (code TEXT PRIMARY KEY, active INTEGER NOT NULL, changed_at INTEGER NOT NULL);
CREATE TABLE notifications (id TEXT PRIMARY KEY, code TEXT NOT NULL, active INTEGER NOT NULL, created_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL, delivered_at INTEGER, lease_until INTEGER);
CREATE INDEX notifications_due ON notifications(delivered_at,next_at);
