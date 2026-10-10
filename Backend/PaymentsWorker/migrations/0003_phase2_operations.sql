ALTER TABLE devices ADD COLUMN account_id TEXT NOT NULL DEFAULT 'default';
ALTER TABLE events ADD COLUMN account_id TEXT NOT NULL DEFAULT 'default';
ALTER TABLE events ADD COLUMN version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE payment_attempts ADD COLUMN reconcile_after TEXT;
ALTER TABLE payment_attempts ADD COLUMN reconcile_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE payment_attempts ADD COLUMN last_reconcile_error TEXT;

CREATE TABLE cash_reconciliations (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    event_id TEXT NOT NULL REFERENCES events(id),
    actor_device_id TEXT NOT NULL REFERENCES devices(id),
    counted_centavos INTEGER NOT NULL CHECK (counted_centavos >= 0),
    reason TEXT NOT NULL,
    supersedes_id TEXT REFERENCES cash_reconciliations(id),
    provisional INTEGER NOT NULL CHECK (provisional IN (0,1)),
    created_at TEXT NOT NULL
);

CREATE TABLE reconciliation_runs (
    id TEXT PRIMARY KEY,
    environment TEXT NOT NULL CHECK (environment IN ('test','live')),
    started_at TEXT NOT NULL,
    finished_at TEXT,
    inspected_count INTEGER NOT NULL DEFAULT 0,
    resolved_count INTEGER NOT NULL DEFAULT 0,
    conflict_count INTEGER NOT NULL DEFAULT 0,
    failure_summary TEXT
);

CREATE TABLE operational_counters (
    name TEXT PRIMARY KEY,
    value INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);

CREATE INDEX events_account_updated_idx ON events(account_id, updated_at DESC);
CREATE INDEX attempts_reconcile_idx ON payment_attempts(method, state, reconcile_after, updated_at);
CREATE INDEX cash_reconciliation_event_idx ON cash_reconciliations(account_id, event_id, created_at DESC);
