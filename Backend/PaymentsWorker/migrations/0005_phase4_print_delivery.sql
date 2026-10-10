-- Phase 4: record "transport delivered, paper not verified" distinctly from operator-confirmed
-- paper. SQLite cannot alter a CHECK constraint, so print_copy_outcomes is rebuilt with every
-- existing row preserved and its append-only triggers recreated.

CREATE TABLE print_copy_outcomes_v5 (
    id TEXT PRIMARY KEY,
    batch_id TEXT NOT NULL REFERENCES print_batches(id),
    copy_index INTEGER NOT NULL,
    outcome TEXT NOT NULL CHECK (outcome IN ('CONFIRMED','DELIVERED','UNCERTAIN','FAILED','NOT_STARTED')),
    transport TEXT NOT NULL,
    idempotency_key TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    UNIQUE(batch_id, copy_index)
);

INSERT INTO print_copy_outcomes_v5(id, batch_id, copy_index, outcome, transport, idempotency_key, created_at)
    SELECT id, batch_id, copy_index, outcome, transport, idempotency_key, created_at FROM print_copy_outcomes;

DROP TRIGGER print_copy_outcomes_append_only;
DROP TRIGGER print_copy_outcomes_no_delete;
DROP TABLE print_copy_outcomes;
ALTER TABLE print_copy_outcomes_v5 RENAME TO print_copy_outcomes;

CREATE INDEX print_outcomes_batch_idx ON print_copy_outcomes(batch_id, copy_index);

CREATE TRIGGER print_copy_outcomes_append_only BEFORE UPDATE ON print_copy_outcomes
BEGIN SELECT RAISE(ABORT, 'print_outcome_append_only'); END;

CREATE TRIGGER print_copy_outcomes_no_delete BEFORE DELETE ON print_copy_outcomes
BEGIN SELECT RAISE(ABORT, 'print_outcome_append_only'); END;

CREATE INDEX entitlements_order_state_idx ON entitlements(order_id, state);
CREATE INDEX orders_device_checkout_idx ON orders(device_id, checkout_session_id, created_at);
