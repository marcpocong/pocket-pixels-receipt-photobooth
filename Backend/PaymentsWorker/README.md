# Pocket Pixels Payments Worker

Standalone authenticated Payments/Event API. It must not share a route, D1 database, or secret with the public gallery proxy.

## Safety defaults

- Environments are explicit: `--env test` and `--env live`. The top-level config is local-only (placeholder D1 ID, no Cron), so a command that forgets `--env` cannot reach TEST or LIVE data.
- Live is inert unless `PAYMENTS_ENVIRONMENT=live`, `LIVE_PAYMENTS_ENABLED=true`, and live secrets exist. Live Cron is empty.
- Test and live use separate Worker names, D1 databases, PayMongo keys, webhook secrets and offline signing keys.
- No secret is returned to the iPad or logged. Provider error bodies are never echoed. QR creation fails closed if credentials are absent.

## Payment invariants (enforced in D1, not only in route code)

- **One payment method per order.** QR creation and cash declaration both start with one guarded `UPDATE orders … WHERE state='AWAITING_PAYMENT' AND payment_method IS NULL`, and the attempt row is inserted in the same transaction (`batch`). Triggers reject a second attempt, an attempt whose method differs from the order lock, and any change to a locked method.
- **No silent cash fallback.** A QR order stays locked to QR until the provider is conclusively non-paid (`CREATE_FAILED_NO_QR`, or failed/expired *and* past the QR expiry + 60 s). Only then may a *new* order for the same checkout session supersede it (`supersedesOrderId`); a partial unique index allows one open order per device session. History is retained.
- **Late payments reconcile to the original order.** Paid evidence on a superseded order creates a `REVIEW_REQUIRED` entitlement and `LATE_PAID_REVIEW` order (refund review), never a usable entitlement or a second charge.
- **Verified paid is final.** `PAID_VERIFIED` cannot regress (trigger). Webhook `payment.paid` is HMAC-verified *and* the Payment Intent is re-read server-to-server before authorizing. Webhook IDs are claimed before processing; failed processing is retryable.
- **Entitlements** require matching payment evidence (trigger), bind to one session at first claim, and are consumed at completion.
- **Prints**: one receipt fingerprint and one batch per entitlement; each copy outcome is recorded once (append-only). `DELIVERED` = every byte accepted by the transport (paper not sensor-verified); `UNCERTAIN` = may or may not have printed; `CONFIRMED` is reserved for physically verified paper. The API never authorizes a reprint.
- **Crash recovery**: `GET /v1/checkouts/:checkoutSessionId` returns this device's orders for one checkout session (read-only, no QR image) so an interrupted iPad resumes the original checkout instead of charging again; recovery claims pass `recovery: true` and are audited.
- **Snapshots**: published policy revisions and order price snapshots are immutable. Lifecycle transitions are enforced by trigger; at most one `ACTIVE` event per account.

## Offline cash policy signing

`GET /v1/events/active` returns `offlinePolicy` — an Ed25519-signed, device/account/event/revision-bound cash-only policy — when the active revision has `offlineValidUntil` and the Worker has `OFFLINE_POLICY_SIGNING_KEY` (PKCS#8, base64) and `OFFLINE_POLICY_KEY_ID`. Validity is `min(now + OFFLINE_MAX_WINDOW_SECONDS, offlineValidUntil, ends_at)`; at most `OFFLINE_MAX_DECLARATIONS` declarations per snapshot are accepted. Pause/end/archive/publish revoke issued snapshots; declarations synced after revocation are accepted but flagged for review because a disconnected iPad cannot learn of the revocation.

Generate keys locally (private key goes to a mode-0600 file, never stdout):

```sh
npm run offline-key:generate -- test-k1 ./offline-test.private.pkcs8.b64
```

The printed `keyId:publicKey` is pinned in the iPad build as `PAYMENTS_OFFLINE_POLICY_PUBLIC_KEYS`. Without a pinned key the iPad disables offline paid cash.

## API

Authenticated routes use `Authorization: Bearer <per-device-token>`; D1 stores only the SHA-256 hash. Scopes: `booth` (checkout routes) and `operator` (admin routes). Failed authentication is rate limited per client address.

- `GET /v1/health`, `GET /v1/device`
- `GET /v1/events/active`
- `POST /v1/orders` (requires `Idempotency-Key`, `checkoutSessionId`, `expectedPolicyRevisionId`, `expectedUnitPriceCentavos`; optional `supersedesOrderId`)
- `POST /v1/orders/:id/qrph`, `POST /v1/orders/:id/cash-declaration`, `GET /v1/orders/:id/status` (includes `newCheckout.allowed`)
- `GET /v1/checkouts/:checkoutSessionId` (device-scoped recovery view)
- `POST /v1/entitlements/:id/claim`, `POST /v1/entitlements/:id/complete`
- `POST /v1/prints/:batchId/progress`
- `POST /v1/sync/offline-cash`
- `GET|POST /v1/admin/events`, `GET|PATCH /v1/admin/events/:id` (PATCH saves a *draft* revision; `If-Match` required)
- `POST /v1/admin/events/:id/activate|publish|pause|resume|end|archive` (`If-Match`; publish/activate need `policyRevisionId` + `acknowledgedUnitPriceCentavos`)
- `GET /v1/admin/events/:id/summary|orders|offline-conflicts|export.csv`, `POST /v1/admin/events/:id/cash-counts`
- `GET /v1/admin/diagnostics`
- `POST /v1/webhooks/paymongo/test`, `POST /v1/webhooks/paymongo/live`

Lifecycle: `DRAFT → ACTIVE ⇄ PAUSED → ENDED → ARCHIVED` (and `DRAFT → ARCHIVED`). CSV export is paged (5,000 rows) with `x-export-complete` / `x-export-next-cursor` headers.

## Local verification

```sh
cd Backend/PaymentsWorker
npm ci
npm test                 # domain + route tests in workerd (Miniflare) with local D1
npm run check
npm run validate:config  # wrangler deploy --dry-run for test and live; uploads nothing
```

Route tests run the real Worker module in `workerd` against a freshly migrated local D1 per test; PayMongo is an outbound stub. `test/migrations.test.js` also applies all migrations with Wrangler's own D1 runner (`--local`). See `docs/payments-phase3-test-report.md`.

## Staging

See `docs/payments-test-staging-runbook.md`. Nothing in this repository deploys, migrates remote D1, or sets secrets automatically.
