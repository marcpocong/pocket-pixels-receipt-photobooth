-- Additive: existing heartbeat, incident and notification evidence is untouched.
CREATE TABLE telegram_rate (window INTEGER PRIMARY KEY, count INTEGER NOT NULL);
CREATE TABLE telegram_commands (
    update_id INTEGER PRIMARY KEY, created_at INTEGER NOT NULL, reply_text TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL,
    delivered_at INTEGER, lease_until INTEGER
);
CREATE INDEX telegram_commands_due ON telegram_commands(delivered_at,next_at);
CREATE TABLE backend_health (id TEXT PRIMARY KEY, checked_at INTEGER NOT NULL, available INTEGER NOT NULL, reconciliation_fresh INTEGER);
