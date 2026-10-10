PRAGMA foreign_keys = ON;

CREATE TABLE devices (
    id TEXT PRIMARY KEY,
    credential_hash TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    scopes TEXT NOT NULL,
    revoked_at TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE events (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    venue TEXT NOT NULL DEFAULT '',
    lifecycle TEXT NOT NULL CHECK (lifecycle IN ('DRAFT','ACTIVE','PAUSED','ENDED','ARCHIVED')),
    active_policy_revision_id TEXT,
    starts_at TEXT,
    ends_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE event_policy_revisions (
    id TEXT PRIMARY KEY,
    event_id TEXT NOT NULL REFERENCES events(id),
    revision INTEGER NOT NULL,
    commercial_mode TEXT NOT NULL CHECK (commercial_mode IN ('PRIVATE_PREPAID','PAY_PER_PRINT')),
    unit_price_centavos INTEGER NOT NULL CHECK (unit_price_centavos >= 0),
    max_copies INTEGER NOT NULL CHECK (max_copies BETWEEN 1 AND 10),
    default_copies INTEGER NOT NULL CHECK (default_copies BETWEEN 1 AND 10),
    cash_enabled INTEGER NOT NULL CHECK (cash_enabled IN (0,1)),
    qrph_enabled INTEGER NOT NULL CHECK (qrph_enabled IN (0,1)),
    prepaid_guest_copy_choice INTEGER NOT NULL CHECK (prepaid_guest_copy_choice IN (0,1)),
    supported_formats_json TEXT NOT NULL,
    features_json TEXT NOT NULL,
    offline_valid_until TEXT,
    created_at TEXT NOT NULL,
    activated_at TEXT,
    UNIQUE(event_id, revision)
);

CREATE TABLE orders (
    id TEXT PRIMARY KEY,
    event_id TEXT NOT NULL REFERENCES events(id),
    policy_revision_id TEXT NOT NULL REFERENCES event_policy_revisions(id),
    device_id TEXT NOT NULL REFERENCES devices(id),
    booth_format TEXT NOT NULL,
    copies INTEGER NOT NULL CHECK (copies BETWEEN 1 AND 10),
    unit_price_centavos INTEGER NOT NULL CHECK (unit_price_centavos > 0),
    total_centavos INTEGER NOT NULL CHECK (total_centavos > 0),
    currency TEXT NOT NULL CHECK (currency = 'PHP'),
    state TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    expires_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(device_id, idempotency_key)
);

CREATE TABLE payment_attempts (
    id TEXT PRIMARY KEY,
    order_id TEXT NOT NULL REFERENCES orders(id),
    method TEXT NOT NULL CHECK (method IN ('QRPH','CASH_DECLARED')),
    provider_payment_intent_id TEXT UNIQUE,
    provider_payment_method_id TEXT,
    provider_payment_id TEXT UNIQUE,
    livemode INTEGER NOT NULL CHECK (livemode IN (0,1)),
    state TEXT NOT NULL,
    qr_image_data_url TEXT,
    provider_test_url TEXT,
    expires_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(order_id, method)
);

CREATE TABLE payment_webhook_events (
    provider_event_id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    livemode INTEGER NOT NULL,
    provider_created_at INTEGER NOT NULL,
    processing_outcome TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE entitlements (
    id TEXT PRIMARY KEY,
    order_id TEXT NOT NULL UNIQUE REFERENCES orders(id),
    device_id TEXT NOT NULL REFERENCES devices(id),
    session_id TEXT UNIQUE,
    purchased_copies INTEGER NOT NULL,
    authorization_source TEXT NOT NULL CHECK (authorization_source IN ('VERIFIED_QRPH','UNVERIFIED_CASH_DECLARED','PRIVATE_PREPAID')),
    state TEXT NOT NULL,
    claim_idempotency_key TEXT,
    receipt_fingerprint TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE print_batches (
    id TEXT PRIMARY KEY,
    entitlement_id TEXT NOT NULL REFERENCES entitlements(id),
    session_id TEXT NOT NULL,
    receipt_fingerprint TEXT NOT NULL,
    authorized_copies INTEGER NOT NULL,
    state TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(entitlement_id, receipt_fingerprint)
);

CREATE TABLE print_copy_outcomes (
    id TEXT PRIMARY KEY,
    batch_id TEXT NOT NULL REFERENCES print_batches(id),
    copy_index INTEGER NOT NULL,
    outcome TEXT NOT NULL CHECK (outcome IN ('CONFIRMED','UNCERTAIN','FAILED','NOT_STARTED')),
    transport TEXT NOT NULL,
    idempotency_key TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    UNIQUE(batch_id, copy_index)
);

CREATE TABLE offline_cash_sync_records (
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(id),
    local_event_id TEXT NOT NULL,
    local_sequence INTEGER NOT NULL,
    event_id TEXT NOT NULL REFERENCES events(id),
    policy_revision_id TEXT NOT NULL REFERENCES event_policy_revisions(id),
    order_id TEXT NOT NULL UNIQUE REFERENCES orders(id),
    synced_at TEXT NOT NULL,
    UNIQUE(device_id, local_event_id),
    UNIQUE(device_id, local_sequence)
);

CREATE TABLE operator_audit_log (
    id TEXT PRIMARY KEY,
    actor_device_id TEXT NOT NULL REFERENCES devices(id),
    event_id TEXT,
    order_id TEXT,
    action TEXT NOT NULL,
    safe_summary_json TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE INDEX orders_event_state_idx ON orders(event_id, state);
CREATE INDEX attempts_order_state_idx ON payment_attempts(order_id, state);
CREATE INDEX entitlements_device_state_idx ON entitlements(device_id, state);
CREATE INDEX print_outcomes_batch_idx ON print_copy_outcomes(batch_id, copy_index);
