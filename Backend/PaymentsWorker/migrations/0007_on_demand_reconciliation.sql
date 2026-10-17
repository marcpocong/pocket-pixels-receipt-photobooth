-- Additive coordination only. No existing financial rows are removed or rewritten.
ALTER TABLE payment_attempts ADD COLUMN reconcile_lease_until TEXT;
ALTER TABLE payment_attempts ADD COLUMN last_on_demand_at TEXT;
