-- Phase 3: authoritative single payment method per order, superseding checkouts,
-- signed offline policy snapshots, immutable financial snapshots and lifecycle rules.
--
-- Invariants are enforced with triggers instead of new UNIQUE indexes on existing columns so
-- the migration cannot fail on (or silently delete) legacy rows. Legacy rows that already
-- violate an invariant are quarantined for manual review below.

-- Orders: checkout session, method lock and supersede chain.
ALTER TABLE orders ADD COLUMN checkout_session_id TEXT;
ALTER TABLE orders ADD COLUMN payment_method TEXT CHECK (payment_method IS NULL OR payment_method IN ('QRPH','CASH_DECLARED'));
ALTER TABLE orders ADD COLUMN method_lock_token TEXT;
ALTER TABLE orders ADD COLUMN supersedes_order_id TEXT REFERENCES orders(id);
-- No FK: the replacing order is inserted after this column is set, inside the same transaction.
ALTER TABLE orders ADD COLUMN superseded_by_order_id TEXT;

ALTER TABLE events ADD COLUMN last_mutation_id TEXT;

ALTER TABLE offline_cash_sync_records ADD COLUMN snapshot_id TEXT;
ALTER TABLE offline_cash_sync_records ADD COLUMN declared_at TEXT;
ALTER TABLE offline_cash_sync_records ADD COLUMN review_flag TEXT;

-- Legacy quarantine: orders that already had more than one payment attempt.
CREATE TABLE legacy_payment_conflicts (
    order_id TEXT PRIMARY KEY REFERENCES orders(id),
    reason TEXT NOT NULL,
    detected_at TEXT NOT NULL
);
INSERT INTO legacy_payment_conflicts(order_id, reason, detected_at)
    SELECT order_id, 'MULTIPLE_PAYMENT_ATTEMPTS', strftime('%Y-%m-%dT%H:%M:%fZ','now')
    FROM payment_attempts GROUP BY order_id HAVING COUNT(*) > 1;
UPDATE orders SET payment_method = (SELECT a.method FROM payment_attempts a WHERE a.order_id = orders.id)
    WHERE payment_method IS NULL AND (SELECT COUNT(*) FROM payment_attempts a WHERE a.order_id = orders.id) = 1;
UPDATE orders SET state = 'MANUAL_REVIEW' WHERE id IN (SELECT order_id FROM legacy_payment_conflicts);
UPDATE entitlements SET state = 'REVIEW_REQUIRED' WHERE state = 'AUTHORIZED' AND order_id IN (SELECT order_id FROM legacy_payment_conflicts);

-- One open (non-superseded) order per device checkout session. Legacy rows have NULL sessions.
CREATE UNIQUE INDEX orders_one_open_checkout ON orders(device_id, checkout_session_id)
    WHERE checkout_session_id IS NOT NULL AND superseded_by_order_id IS NULL;
CREATE INDEX orders_supersedes_idx ON orders(supersedes_order_id);

-- Exactly one payment attempt per order, and it must match the order's locked method.
CREATE TRIGGER payment_attempts_single_per_order BEFORE INSERT ON payment_attempts
WHEN EXISTS (SELECT 1 FROM payment_attempts WHERE order_id = NEW.order_id)
BEGIN SELECT RAISE(ABORT, 'payment_method_locked'); END;

CREATE TRIGGER payment_attempts_match_order_lock BEFORE INSERT ON payment_attempts
WHEN NOT EXISTS (SELECT 1 FROM orders WHERE id = NEW.order_id AND payment_method = NEW.method)
BEGIN SELECT RAISE(ABORT, 'payment_method_mismatch'); END;

CREATE TRIGGER payment_attempts_identity_immutable BEFORE UPDATE OF order_id, method, livemode ON payment_attempts
WHEN NEW.order_id IS NOT OLD.order_id OR NEW.method IS NOT OLD.method OR NEW.livemode IS NOT OLD.livemode
BEGIN SELECT RAISE(ABORT, 'payment_attempt_identity_immutable'); END;

CREATE TRIGGER payment_attempts_paid_is_final BEFORE UPDATE OF state ON payment_attempts
WHEN OLD.state = 'PAID_VERIFIED' AND NEW.state IS NOT 'PAID_VERIFIED'
BEGIN SELECT RAISE(ABORT, 'paid_state_is_final'); END;

CREATE TRIGGER orders_payment_method_immutable BEFORE UPDATE OF payment_method ON orders
WHEN OLD.payment_method IS NOT NULL AND NEW.payment_method IS NOT OLD.payment_method
BEGIN SELECT RAISE(ABORT, 'payment_method_immutable'); END;

CREATE TRIGGER orders_supersede_is_final BEFORE UPDATE OF superseded_by_order_id ON orders
WHEN OLD.superseded_by_order_id IS NOT NULL AND NEW.superseded_by_order_id IS NOT OLD.superseded_by_order_id
BEGIN SELECT RAISE(ABORT, 'supersede_is_final'); END;

CREATE TRIGGER orders_price_snapshot_immutable
BEFORE UPDATE OF event_id, policy_revision_id, device_id, booth_format, copies, unit_price_centavos, total_centavos, currency, checkout_session_id ON orders
WHEN NEW.event_id IS NOT OLD.event_id OR NEW.policy_revision_id IS NOT OLD.policy_revision_id OR NEW.device_id IS NOT OLD.device_id
  OR NEW.booth_format IS NOT OLD.booth_format OR NEW.copies IS NOT OLD.copies OR NEW.unit_price_centavos IS NOT OLD.unit_price_centavos
  OR NEW.total_centavos IS NOT OLD.total_centavos OR NEW.currency IS NOT OLD.currency OR NEW.checkout_session_id IS NOT OLD.checkout_session_id
BEGIN SELECT RAISE(ABORT, 'order_snapshot_immutable'); END;

-- Entitlements require matching payment evidence. Not affected by INSERT OR IGNORE.
CREATE TRIGGER entitlements_require_payment BEFORE INSERT ON entitlements
WHEN NEW.authorization_source <> 'PRIVATE_PREPAID' AND NOT EXISTS (
    SELECT 1 FROM orders o JOIN payment_attempts a ON a.order_id = o.id
    WHERE o.id = NEW.order_id AND (
        (NEW.authorization_source = 'VERIFIED_QRPH' AND o.payment_method = 'QRPH' AND a.method = 'QRPH' AND a.state = 'PAID_VERIFIED')
        OR (NEW.authorization_source = 'UNVERIFIED_CASH_DECLARED' AND o.payment_method = 'CASH_DECLARED' AND a.method = 'CASH_DECLARED')))
BEGIN SELECT RAISE(ABORT, 'entitlement_without_payment'); END;

CREATE TRIGGER entitlements_identity_immutable BEFORE UPDATE OF order_id, device_id, purchased_copies, authorization_source ON entitlements
WHEN NEW.order_id IS NOT OLD.order_id OR NEW.device_id IS NOT OLD.device_id
  OR NEW.purchased_copies IS NOT OLD.purchased_copies OR NEW.authorization_source IS NOT OLD.authorization_source
BEGIN SELECT RAISE(ABORT, 'entitlement_identity_immutable'); END;

CREATE TRIGGER entitlements_session_binding_final BEFORE UPDATE OF session_id, receipt_fingerprint ON entitlements
WHEN (OLD.session_id IS NOT NULL AND NEW.session_id IS NOT OLD.session_id)
  OR (OLD.receipt_fingerprint IS NOT NULL AND NEW.receipt_fingerprint IS NOT OLD.receipt_fingerprint)
BEGIN SELECT RAISE(ABORT, 'entitlement_binding_final'); END;

-- One print batch (one receipt) per entitlement; recorded copy outcomes are append-only.
CREATE TRIGGER print_batches_one_per_entitlement BEFORE INSERT ON print_batches
WHEN EXISTS (SELECT 1 FROM print_batches WHERE entitlement_id = NEW.entitlement_id)
BEGIN SELECT RAISE(ABORT, 'print_batch_exists'); END;

CREATE TRIGGER print_copy_outcomes_append_only BEFORE UPDATE ON print_copy_outcomes
BEGIN SELECT RAISE(ABORT, 'print_outcome_append_only'); END;

CREATE TRIGGER print_copy_outcomes_no_delete BEFORE DELETE ON print_copy_outcomes
BEGIN SELECT RAISE(ABORT, 'print_outcome_append_only'); END;

CREATE TRIGGER cash_reconciliations_append_only BEFORE UPDATE ON cash_reconciliations
BEGIN SELECT RAISE(ABORT, 'cash_reconciliation_append_only'); END;

-- Published policy revisions are immutable snapshots (only activated_at may be stamped).
CREATE TRIGGER policy_revisions_immutable
BEFORE UPDATE OF event_id, revision, commercial_mode, unit_price_centavos, max_copies, default_copies, cash_enabled, qrph_enabled,
    prepaid_guest_copy_choice, supported_formats_json, features_json, offline_valid_until, created_at ON event_policy_revisions
BEGIN SELECT RAISE(ABORT, 'policy_revision_immutable'); END;

-- Event lifecycle: DRAFT -> ACTIVE <-> PAUSED -> ENDED -> ARCHIVED, and DRAFT -> ARCHIVED.
CREATE TRIGGER events_lifecycle_transitions BEFORE UPDATE OF lifecycle ON events
WHEN NEW.lifecycle IS NOT OLD.lifecycle AND NOT (
    (OLD.lifecycle = 'DRAFT' AND NEW.lifecycle IN ('ACTIVE','ARCHIVED'))
    OR (OLD.lifecycle = 'ACTIVE' AND NEW.lifecycle IN ('PAUSED','ENDED'))
    OR (OLD.lifecycle = 'PAUSED' AND NEW.lifecycle IN ('ACTIVE','ENDED'))
    OR (OLD.lifecycle = 'ENDED' AND NEW.lifecycle = 'ARCHIVED'))
BEGIN SELECT RAISE(ABORT, 'invalid_lifecycle_transition'); END;

-- At most one ACTIVE event per account so every booth in the account resolves the same policy.
CREATE TRIGGER events_single_active_per_account BEFORE UPDATE OF lifecycle ON events
WHEN NEW.lifecycle = 'ACTIVE' AND EXISTS (
    SELECT 1 FROM events WHERE account_id = NEW.account_id AND lifecycle = 'ACTIVE' AND id <> NEW.id)
BEGIN SELECT RAISE(ABORT, 'another_event_active'); END;

-- Server-signed offline cash policy snapshots, bound to device, account, event and revision.
CREATE TABLE offline_policy_snapshots (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    device_id TEXT NOT NULL REFERENCES devices(id),
    event_id TEXT NOT NULL REFERENCES events(id),
    policy_revision_id TEXT NOT NULL REFERENCES event_policy_revisions(id),
    key_id TEXT NOT NULL,
    environment TEXT NOT NULL CHECK (environment IN ('test','live')),
    unit_price_centavos INTEGER NOT NULL CHECK (unit_price_centavos > 0),
    max_copies INTEGER NOT NULL CHECK (max_copies BETWEEN 1 AND 10),
    supported_formats_json TEXT NOT NULL,
    max_declarations INTEGER NOT NULL CHECK (max_declarations BETWEEN 1 AND 500),
    payload_b64 TEXT NOT NULL,
    signature_b64 TEXT NOT NULL,
    issued_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    revoked_at TEXT,
    revoked_reason TEXT
);
CREATE INDEX offline_snapshots_device_idx ON offline_policy_snapshots(device_id, policy_revision_id, expires_at);
CREATE INDEX offline_snapshots_event_idx ON offline_policy_snapshots(event_id, revoked_at);
CREATE INDEX offline_sync_snapshot_idx ON offline_cash_sync_records(snapshot_id);

-- Offline declarations the server could not accept stay visible and replay-safe.
CREATE TABLE offline_cash_sync_conflicts (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    device_id TEXT NOT NULL REFERENCES devices(id),
    local_event_id TEXT NOT NULL,
    local_sequence INTEGER,
    snapshot_id TEXT,
    event_id TEXT,
    session_id TEXT,
    booth_format TEXT,
    copies INTEGER,
    unit_price_centavos INTEGER,
    declared_at TEXT,
    reason TEXT NOT NULL,
    received_at TEXT NOT NULL,
    UNIQUE(device_id, local_event_id)
);
CREATE INDEX offline_conflicts_event_idx ON offline_cash_sync_conflicts(account_id, event_id, received_at);
