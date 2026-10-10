# Pocket Pixels Payments Worker

Standalone authenticated Payments/Event API. It must not share a route, D1 database, or secret with the public gallery proxy.

## Safety defaults

- Default environment is test.
- Live endpoint is inert unless `PAYMENTS_ENVIRONMENT=live`, `LIVE_PAYMENTS_ENABLED=true`, and live secrets exist.
- Test and live use separate Worker names, D1 databases, PayMongo secrets, and webhook secrets.
- No secret is returned to the iPad or logged. QR creation fails closed if credentials are absent.

## API

Authenticated device routes use `Authorization: Bearer <per-device-token>`. Store only the SHA-256 token hash in `devices.credential_hash`. Scopes are comma-separated (`booth`, `operator`).

- `GET /v1/health`
- `GET /v1/events/active`
- `GET /v1/admin/events` and `GET /v1/admin/events/:id`
- `POST /v1/admin/events`
- `PATCH /v1/admin/events/:id`
- `POST /v1/admin/events/:id/activate|pause|resume|end`
- `POST /v1/orders`
- `POST /v1/orders/:id/qrph`
- `POST /v1/orders/:id/cash-declaration`
- `GET /v1/orders/:id/status`
- `POST /v1/entitlements/:id/claim`
- `POST /v1/prints/:batchId/progress`
- `POST /v1/sync/offline-cash`
- `GET /v1/admin/events/:id/summary`
- `GET /v1/admin/events/:id/orders`
- `GET /v1/admin/events/:id/export.csv`
- `POST /v1/admin/events/:id/cash-counts`
- `GET /v1/admin/diagnostics`
- `POST /v1/webhooks/paymongo/test`
- `POST /v1/webhooks/paymongo/live`

All order creation requires `Idempotency-Key`. Amount and currency are server-derived. D1 unique constraints cover order/device idempotency, provider IDs, webhook IDs, offline device/local IDs, entitlements, and print copy indices.

Operator routes are account-scoped; policy edits require `If-Match` or `expectedVersion`. Cash counts are append-only. CSV responses are authenticated and guard spreadsheet formula prefixes.

The Worker exports a non-public `scheduled()` handler. Test Cron checks a bounded batch of unresolved Payment Intents server-to-server with backoff. The live environment has no configured Cron and remains inert behind the live gate.

## Local verification

```sh
cd Backend/PaymentsWorker
npm test
npm run check
```

No dependency install is required. Do not deploy from an implementation run.

## Test setup (manual)

1. Create a test D1 database and replace only the test placeholder ID.
2. Apply migrations with Wrangler after review.
3. Generate a high-entropy device token locally, store its SHA-256 hash/scopes in D1, and provision the token into iOS Keychain through protected operator setup.
4. Configure Worker test secrets: `PAYMONGO_SECRET_KEY_TEST`, `PAYMONGO_PUBLIC_KEY_TEST`, and `PAYMONGO_WEBHOOK_SECRET_TEST`.
5. Deploy only the test environment after owner authorization.
6. Register the exact `/v1/webhooks/paymongo/test` URL for applicable events.
7. Use PayMongo's returned `test_url`. Never scan/pay a test QR with a real bank or wallet app.

`wrangler secret put` may publish a Worker version. Commands are intentionally not automated here.
