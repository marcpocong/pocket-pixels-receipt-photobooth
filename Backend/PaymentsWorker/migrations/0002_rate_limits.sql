CREATE TABLE request_rate_limits (
    key TEXT NOT NULL,
    minute_window INTEGER NOT NULL,
    request_count INTEGER NOT NULL,
    PRIMARY KEY(key, minute_window)
);
