-- New local/manual facts are isolated from legacy financial/entitlement tables.
-- Kiosk authorization uses its durable existing local print journal; imports never grant copies.
CREATE TABLE manual_receivers (
    id TEXT PRIMARY KEY, account_id TEXT NOT NULL, configuration_json TEXT NOT NULL,
    enabled INTEGER NOT NULL CHECK(enabled IN (0,1)), created_at TEXT NOT NULL
);
CREATE TABLE manual_checkouts (
    id TEXT PRIMARY KEY, local_id TEXT NOT NULL, device_id TEXT NOT NULL REFERENCES devices(id),
    account_id TEXT NOT NULL, environment TEXT NOT NULL, session_id TEXT NOT NULL,
    snapshot_hash TEXT NOT NULL, snapshot_json TEXT NOT NULL, receiving_json TEXT,
    capability_nonce TEXT NOT NULL, capability_hash TEXT NOT NULL,
    acknowledged_at TEXT, late_acknowledged_at TEXT, closed_at TEXT, completed_at TEXT,
    created_at TEXT NOT NULL, expires_at TEXT NOT NULL, receipt_expires_at TEXT NOT NULL,
    UNIQUE(device_id,local_id), UNIQUE(device_id,session_id)
);
CREATE INDEX manual_checkouts_account_created ON manual_checkouts(account_id,created_at DESC,id);
CREATE TRIGGER manual_checkout_identity_immutable BEFORE UPDATE OF local_id,device_id,account_id,environment,session_id,snapshot_hash,snapshot_json,receiving_json ON manual_checkouts
BEGIN SELECT RAISE(ABORT,'manual_snapshot_immutable'); END;
CREATE TABLE manual_receipts (
    id TEXT PRIMARY KEY, checkout_id TEXT NOT NULL REFERENCES manual_checkouts(id),
    request_hash TEXT NOT NULL, content_hash TEXT NOT NULL, mime_type TEXT NOT NULL, bytes INTEGER NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('RESERVED','STORED_PRIVATE','REVIEW_REQUIRED')),
    storage_json TEXT, created_at TEXT NOT NULL, stored_at TEXT, trashed_at TEXT,
    UNIQUE(checkout_id,request_hash)
);
CREATE INDEX manual_receipts_checkout_state ON manual_receipts(checkout_id,state);
CREATE TABLE manual_reviews (
    id TEXT PRIMARY KEY, checkout_id TEXT NOT NULL REFERENCES manual_checkouts(id),
    actor_device_id TEXT NOT NULL REFERENCES devices(id), outcome TEXT NOT NULL,
    confirmed_centavos INTEGER, note TEXT NOT NULL, created_at TEXT NOT NULL,
    payload_hash TEXT NOT NULL
);
CREATE INDEX manual_reviews_checkout_created ON manual_reviews(checkout_id,created_at DESC,id);
CREATE TRIGGER manual_reviews_append_only BEFORE UPDATE ON manual_reviews
BEGIN SELECT RAISE(ABORT,'manual_review_append_only'); END;
CREATE TRIGGER manual_reviews_no_delete BEFORE DELETE ON manual_reviews
BEGIN SELECT RAISE(ABORT,'manual_review_append_only'); END;

-- Evidence imports never participate in print authorization or provider financial totals.
CREATE TABLE manual_print_evidence (
    checkout_id TEXT NOT NULL REFERENCES manual_checkouts(id), id TEXT NOT NULL,
    payload_json TEXT NOT NULL, updated_at TEXT NOT NULL,
    PRIMARY KEY(checkout_id,id)
);
CREATE TABLE manual_retention_policies (
    account_id TEXT PRIMARY KEY, days INTEGER NOT NULL CHECK(days BETWEEN 1 AND 3650),
    actor_device_id TEXT NOT NULL, established_at TEXT NOT NULL
);
CREATE TABLE manual_receipt_trash_audit (
    receipt_id TEXT PRIMARY KEY REFERENCES manual_receipts(id), actor_device_id TEXT NOT NULL,
    reason TEXT NOT NULL, retention_days INTEGER NOT NULL, created_at TEXT NOT NULL
);
