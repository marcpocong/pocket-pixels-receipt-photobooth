-- Event-creation idempotency. A booth sends one stable operation ID per operator-authorized
-- creation; a repeated request with the same ID returns the original event instead of minting a
-- second commercial draft, and a lost response can be resolved by exact lookup. Additive only:
-- existing rows keep NULL (older clients never send an ID), and older Workers ignore the columns.

ALTER TABLE events ADD COLUMN creation_operation_id TEXT;
ALTER TABLE events ADD COLUMN creation_fingerprint TEXT;

CREATE UNIQUE INDEX events_creation_operation_per_account
    ON events(account_id, creation_operation_id) WHERE creation_operation_id IS NOT NULL;
