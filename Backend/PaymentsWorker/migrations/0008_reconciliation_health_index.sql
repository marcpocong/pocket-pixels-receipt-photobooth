-- Monitoring reads the latest run every five minutes, even between events.
-- Cover the filter, sort and result so each check avoids scanning/sorting all
-- retained runs. Keep every historical run and the existing health semantics.
CREATE INDEX reconciliation_runs_environment_started_idx
    ON reconciliation_runs(environment, started_at DESC, finished_at);
