-- Additive. V1/V2 tables and records remain valid for a code-only rollback.
CREATE TABLE monitoring_observations (
    code TEXT PRIMARY KEY, value INTEGER, observed_at INTEGER NOT NULL,
    source_version INTEGER NOT NULL, unhealthy_since INTEGER
);
CREATE TABLE incident_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT NOT NULL, active INTEGER NOT NULL,
    changed_at INTEGER NOT NULL
);
CREATE TABLE notification_episodes (
    code TEXT PRIMARY KEY, active INTEGER NOT NULL, severity TEXT NOT NULL,
    components INTEGER NOT NULL, revision INTEGER NOT NULL,
    changed_at INTEGER NOT NULL, observed_at INTEGER NOT NULL
);
ALTER TABLE notifications ADD COLUMN episode_revision INTEGER;
CREATE TABLE monitoring_locks (id TEXT PRIMARY KEY, owner TEXT NOT NULL, expires_at INTEGER NOT NULL);
-- A V2 code rollback must not consume unknown V3-only printer/camera notifications.
CREATE TABLE v3_notifications (
    id TEXT PRIMARY KEY, code TEXT NOT NULL, active INTEGER NOT NULL,
    created_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
    next_at INTEGER NOT NULL, delivered_at INTEGER, lease_until INTEGER,
    superseded_at INTEGER, episode_revision INTEGER
);
CREATE INDEX v3_notifications_due ON v3_notifications(delivered_at,next_at);
