# Payments Phase 3 — TEST-mode staging runbook

> **Superseded by `docs/payments-test-staging-runbook.md`** (adds migration 0005, recovery and print-accounting checks, PayMongo doc reconciliation).

> **Status: prepare-only.** No command in this document was executed against Cloudflare or PayMongo during Phase 3. Running any remote step requires separate, explicit owner authorization. **Production go-live is NOT AUTHORIZED.**

## Environment model (why `--env test`)

`Backend/PaymentsWorker/wrangler.toml` now defines three scopes (Phase 3 chose **option A: an explicit `[env.test]`**):

| Scope | Worker name | D1 database | Cron | Purpose |
|---|---|---|---|---|
| top level (no `--env`) | `pocket-pixels-payments-local` | `pocket-pixels-payments-local`, placeholder ID `00000000-…` | none | local `wrangler dev` / tests only |
| `--env test` | `pocket-pixels-payments-test` | `pocket-pixels-payments-test` | `*/5 * * * *` | TEST staging |
| `--env live` | `pocket-pixels-payments-live` | `pocket-pixels-payments-live` | none | inert; `LIVE_PAYMENTS_ENABLED=false` |

Why option A: the Phase 2 runbook already used `--env test`, but the config had no such environment (verified: `wrangler deploy --dry-run --env test` failed with *"No environment found in configuration with name "test""*, log `wrangler-dryrun-test-ORIGINAL-config.log`). With option A every remote command names its target explicitly, and the top level can no longer silently mean "test" — a forgotten `--env` lands on an inert local config with a placeholder database ID instead of real TEST data. `vars`, `triggers` and `d1_databases` are non-inheritable in Wrangler, so each environment redeclares them.

All commands below run from `Backend/PaymentsWorker` with the pinned Wrangler (`npx wrangler`, 4.149.0). Never run a command with `--env live` during TEST staging.

## 0. Local gates (safe; no network writes)

```sh
npm ci
npm test                  # 186 tests incl. route tests in workerd + Wrangler local migration apply
npm run check
npm run validate:config   # wrangler deploy --dry-run --env test / --env live (no upload)
```

All must pass on the exact commit being staged.

## 1. Create and migrate the TEST D1 database (owner-authorized)

```sh
npx wrangler d1 create pocket-pixels-payments-test
# Copy the printed database_id into [[env.test.d1_databases]] database_id in wrangler.toml; review the diff.
npx wrangler d1 migrations list  pocket-pixels-payments-test --env test --remote
npx wrangler d1 migrations apply pocket-pixels-payments-test --env test --remote
npx wrangler d1 execute pocket-pixels-payments-test --env test --remote --command "SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name"
```

Expected: migrations `0001`–`0004` applied; at least 15 triggers listed. Migrations are forward-only; before applying to any database with data, export it (`npx wrangler d1 export pocket-pixels-payments-test --env test --remote --output backup.sql`).

## 2. Secrets (TEST only; values never in source, chat, logs or screenshots)

Each command prompts for the value (or reads stdin). `wrangler secret put` may publish a new Worker version.

```sh
npx wrangler secret put PAYMONGO_SECRET_KEY_TEST     --env test
npx wrangler secret put PAYMONGO_PUBLIC_KEY_TEST     --env test
npx wrangler secret put PAYMONGO_WEBHOOK_SECRET_TEST --env test   # after step 5 creates the webhook
npm run offline-key:generate -- test-k1 ./offline-test.private.pkcs8.b64
npx wrangler secret put OFFLINE_POLICY_SIGNING_KEY   --env test < ./offline-test.private.pkcs8.b64
printf 'test-k1' | npx wrangler secret put OFFLINE_POLICY_KEY_ID --env test
rm -P ./offline-test.private.pkcs8.b64
npx wrangler secret list --env test
```

Do not set any `*_LIVE` secret in the TEST Worker. Keep the printed `test-k1:<publicKey>` line for step 6.

## 3. Deploy the TEST Worker

```sh
npx wrangler deploy --env test --dry-run
npx wrangler deploy --env test
curl -s https://<test-worker-host>/v1/health
```

Expected health: `{"environment":"test","liveEnabled":false,...}`. Confirm in the dashboard that only the TEST Worker has the `*/5` Cron trigger.

## 4. Provision device credentials

```sh
node scripts/device-credential.mjs ipad-booth-1 "Booth iPad 1" booth,operator acct-main ./ipad-booth-1.token
# Prints only an INSERT containing the SHA-256 hash; run it against TEST:
npx wrangler d1 execute pocket-pixels-payments-test --env test --remote --command "<printed INSERT>"
```

Enter the token from the 0600 file on the iPad (**Operator → Manage Event → Commercial Events & Sales → Device Pairing**), then `rm -P ./ipad-booth-1.token`. Revoke with `UPDATE devices SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id='ipad-booth-1'`. Use one account ID per business; never reuse a credential across iPads.

## 5. PayMongo TEST webhook

In the PayMongo dashboard (**test mode**), create a webhook to exactly `https://<test-worker-host>/v1/webhooks/paymongo/test` for `payment.paid`, `payment.failed`, `qrph.expired`. Store its signing secret with step 2's `PAYMONGO_WEBHOOK_SECRET_TEST`. Never register the `/live` URL during staging.

## 6. iPad build for TEST

- Add `PAYMENTS_OFFLINE_POLICY_PUBLIC_KEYS` = `test-k1:<publicKey>` to the app's Info.plist for the TEST build only (public key — not secret). Without it, offline paid cash stays disabled by design.
- Build and install; pair (step 4). The environment shown is reported by the server.
- **Operator → Booth Charging Mode → Paid events (server-managed)**.

## 7. Authorized PayMongo `test_url` E2E (use the simulator URL only)

Never scan a TEST QR with a real bank or e-wallet app. For each case, open the attempt's `testURL` (shown in operator diagnostics / order status) in a browser and choose the outcome.

| # | Scenario | Expected |
|---|---|---|
| 1 | Create event, save draft ₱50.00, publish & activate | Booth shows ₱50.00; detail shows revision 1 live |
| 2 | Guest QR, `test_url` → success | Webhook `PAID_VERIFIED` (intent re-read), camera unlocks, N copies print |
| 3 | Guest QR, `test_url` → failure / let it expire | No camera; after expiry + 60 s "Start a New Checkout" appears; old order `SUPERSEDED` |
| 4 | QR shown, then guest asks for cash | Cash option absent; server would answer `payment_method_locked` |
| 5 | Kill Wi-Fi after QR shown, pay via `test_url`, restore | Status reconciles to the same order; no second charge |
| 6 | Disable webhook temporarily, pay via `test_url` | Cron (≤5 min) settles the order |
| 7 | Replay a delivered webhook from the dashboard | `duplicate: true`; one entitlement |
| 8 | Publish revision 2 at ₱75 while a guest is on copies | Guest sees "price updated" before paying; earlier orders keep ₱50 |
| 9 | Pause with an outstanding paid entitlement | Entitlement still claimable; no new checkout |
| 10 | Offline cash: enable offline, load event online, go offline, declare cash, reconnect | Session runs; record syncs as `CASH_SELF_REPORTED_OFFLINE_SYNCED` |
| 11 | Offline: set iPad clock back / let policy expire | Offline cash refused with a visible reason |
| 12 | Cash count ₱X, then correction | Two appended counts; variance shown; provisional while offline records are pending |
| 13 | CSV export | Opens in Numbers; no QR images, provider IDs or secrets |

Record each run (date, commit SHA, result) in the test report before any further phase.

## 8. iPad + VOZY G80 validation (physical)

Run on the real iPad and VOZY G80 576-dot printer: 1/3/10-copy paid sessions; Passport/Photo Pass; stickers; gallery upload + QR; ambiguous print (power-cycle mid-copy) → `UNCERTAIN` recorded, no automatic reprint; kill/relaunch during QR wait; VoiceOver, Dynamic Type XXL, portrait/landscape on checkout and operator screens.

## Rollback

`npx wrangler rollback --env test` restores the previous TEST Worker version. D1 migrations are not rolled back automatically; restore from the step 1 export if needed. Switching the iPad to **Private / Prepaid (this iPad)** removes any dependency on the Payments Worker; galleries and printing are unaffected.
