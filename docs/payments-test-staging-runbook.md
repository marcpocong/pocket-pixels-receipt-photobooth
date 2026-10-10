# Made to Keep Studios — Payments TEST-only staging runbook (owner)

> **TEST MODE ONLY. Nothing here has been executed against Cloudflare or PayMongo.** Every remote step needs your separate, explicit authorization at the time you run it. **PRODUCTION IS NOT AUTHORIZED.** Never run a command with `--env live`. Never scan a TEST QR code with a real bank or e-wallet app — PayMongo documents that test-mode QR Ph codes are real and would move real money; use the `test_url` simulator only.

This replaces `payments-phase3-test-staging-runbook.md` and `payments-phase2-staging-runbook.md`.

## Facts this runbook relies on (checked against the repository)

| Item | Value |
|---|---|
| Wrangler config | `Backend/PaymentsWorker/wrangler.toml` — `[env.test]` (`pocket-pixels-payments-test`, D1 `pocket-pixels-payments-test`, Cron `*/5 * * * *`), `[env.live]` (inert, no Cron, `LIVE_PAYMENTS_ENABLED=false`), top level local-only |
| Migrations | `0001`–`0005` (forward-only; `0005` rebuilds `print_copy_outcomes` preserving rows) |
| Worker secrets (TEST) | `PAYMONGO_SECRET_KEY_TEST`, `PAYMONGO_PUBLIC_KEY_TEST`, `PAYMONGO_WEBHOOK_SECRET_TEST`, `OFFLINE_POLICY_SIGNING_KEY`, `OFFLINE_POLICY_KEY_ID` |
| Webhook events | `payment.paid`, `payment.failed`, `qrph.expired` → `https://<test-host>/v1/webhooks/paymongo/test` |
| iPad pairing | Operator → Manage Event → **Commercial Events & Sales** → Device Pairing (credential stored only in Keychain) |
| iPad offline key | Info.plist `PAYMENTS_OFFLINE_POLICY_PUBLIC_KEYS` = `keyId:base64PublicKey` (TEST build only) |
| Charging mode | Operator → **Booth Charging Mode** → Paid events (server-managed) |
| Recovery | Commercial Events & Sales → **Interrupted Paid Checkouts** and **Print Accounting** |
| PayMongo limits (docs.paymongo.com, read 2026-10-11) | QR Ph minimum ₱1.00 (enforced by Worker and editor); `expiry_seconds` 60–9000 (Worker uses 300); `test_url` location in the attach response is **not documented** — the Worker reads `next_action.code.test_url` then `next_action.test_url`; confirm in step 7.1 |

## Step 1 — Clean baseline (local, safe)

```sh
git fetch origin
git rev-parse origin/codex/madetokeep-payments-phase2     # record this SHA
cd Backend/PaymentsWorker && npm ci && npm test && npm run check && npm run validate:config
```

Pass gate: Worker 195/195; dry-runs print the TEST bindings for `--env test` and LIVE bindings with `LIVE_PAYMENTS_ENABLED ("false")` for `--env live`. iOS (Xcode, iPad simulator, `-parallel-testing-enabled NO`): all tests pass except the three pre-existing capture-flow tests that also fail on `main` (`PassportFormatTests…TwoPhotos…`, `PhotoPassFormatTests…GoingBack`, `SessionIsolationAndRecoveryTests…SixPhoto…`).

**Checkpoint:** write down the SHA and both pass counts. Stop if anything else fails.

## Step 2 — TEST D1 (needs authorization: remote TEST infrastructure)

```sh
npx wrangler d1 create pocket-pixels-payments-test
# put the printed database_id into [[env.test.d1_databases]] only; commit that one-line change for review
npx wrangler d1 migrations list  pocket-pixels-payments-test --env test --remote
npx wrangler d1 migrations apply pocket-pixels-payments-test --env test --remote
npx wrangler d1 execute pocket-pixels-payments-test --env test --remote --command "SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name"
npx wrangler d1 export  pocket-pixels-payments-test --env test --remote --output test-backup-$(date +%Y%m%d).sql
```

**Checkpoint:** five migrations applied; at least 15 triggers; backup file saved off the repository.

## Step 3 — TEST secrets (needs authorization)

Values are typed at the prompt or piped from a local file — never pasted into chat, GitHub, screenshots or the app.

```sh
npx wrangler secret put PAYMONGO_SECRET_KEY_TEST --env test
npx wrangler secret put PAYMONGO_PUBLIC_KEY_TEST --env test
npm run offline-key:generate -- test-k1 ./offline-test.private.pkcs8.b64
npx wrangler secret put OFFLINE_POLICY_SIGNING_KEY --env test < ./offline-test.private.pkcs8.b64
printf 'test-k1' | npx wrangler secret put OFFLINE_POLICY_KEY_ID --env test
rm -P ./offline-test.private.pkcs8.b64
npx wrangler secret list --env test
```

Pin the printed `test-k1:<publicKey>` only in the TEST app build. If the key is missing, revoked or mismatched, offline paid cash stays off (by design). Rotate by generating `test-k2`, setting both secrets, shipping a build that pins `test-k2`, then removing `test-k1` from the build.

## Step 4 — Deploy the TEST Worker (needs authorization)

```sh
npx wrangler deploy --env test --dry-run
npx wrangler deploy --env test
curl -s https://<test-host>/v1/health
```

**Checkpoint:** `{"environment":"test","liveEnabled":false,"version":"3"}`. Only the TEST Worker has a Cron trigger. No gallery Worker, Apps Script or production app setting is touched.

## Step 5 — TEST webhook (needs authorization)

In the PayMongo dashboard (**test mode**) create a webhook for `https://<test-host>/v1/webhooks/paymongo/test` with `payment.paid`, `payment.failed`, `qrph.expired`, then:

```sh
npx wrangler secret put PAYMONGO_WEBHOOK_SECRET_TEST --env test
```

## Step 6 — Pair the iPad (needs authorization: credential provisioning)

```sh
node scripts/device-credential.mjs ipad-booth-1 "Booth iPad 1" booth,operator acct-main ./ipad-booth-1.token
npx wrangler d1 execute pocket-pixels-payments-test --env test --remote --command "<printed INSERT (hash only)>"
```

Enter the token from the 0600 file on the iPad's Device Pairing screen, then `rm -P ./ipad-booth-1.token`. Revoke at any time: `UPDATE devices SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id='ipad-booth-1'`.

**Checkpoint:** the operator screen shows `TEST`, the device ID and account. Create an event, save a draft at ₱50.00, publish & activate; the booth shows ₱50.00 before any capture.

## Step 7 — E2E matrix (TEST mode, `test_url` only)

Record date, SHA, result and evidence for every row.

| # | Scenario | Expected |
|---|---|---|
| 7.1 | First QR: inspect the order status / attempt `testURL` | Non-null. If null, the documented `test_url` location differs: stop and report (provider E2E stays BLOCKED) |
| 7.2 | Cash self-report, 1 copy | Session starts; reports show **Cash self-reported (unverified)** |
| 7.3 | QR success via `test_url` | Webhook + intent re-read → `PAID_VERIFIED`; camera unlocks; copies fixed |
| 7.4 | QR failure via `test_url` | No camera; after expiry + 60 s "Start a New Checkout"; old order `SUPERSEDED` |
| 7.5 | QR timeout (let 5 min pass) | `QR_EXPIRED_CONFIRMED` via webhook or Cron; no cash fallback |
| 7.6 | Late paid: new checkout after expiry, then pay the old `test_url` | Old order `LATE_PAID_REVIEW`, shown as refund review; no second entitlement |
| 7.7 | Replay a delivered webhook | `duplicate: true`; one entitlement |
| 7.8 | Price change mid-checkout | Guest sees "price updated" before paying |
| 7.9 | Pause, then end with an outstanding paid entitlement | No new checkout; entitlement still resumable |
| 7.10 | **Crash before claim**: pay via `test_url`, force-quit the app before the camera appears, relaunch | Welcome shows only "Was your session interrupted? Please ask our attendant."; operator sees *Paid by QR Ph (verified) — session never started*; **Resume for This Guest** → next tap continues with the same copies; no new charge; server audit has `ENTITLEMENT_RECOVERY_CLAIM` |
| 7.11 | Print 1, 3 and 10 copies | Print Accounting shows N **Delivered**; server `delivered = N`; entitlement consumed |
| 7.12 | **Mid-copy app kill** (3 copies, kill during copy 2) | Relaunch: printer recovery lock; copy 2 `UNCERTAIN`, copy 1 delivered; nothing reprinted automatically; operator inspects paper in Fix Printer |
| 7.13 | Worker unreachable while printing | Printing continues; reports wait in Print Accounting and send after reconnect with the same keys |
| 7.14 | Offline signed cash + reconnect | Session runs offline; ledger syncs as offline self-reported |
| 7.15 | Offline sync conflict (e.g. revoke device, declare offline, reconnect) | Conflict visible on iPad and server; nothing dropped |
| 7.16 | VOZY G80 ambiguous print (power-cycle mid-copy) | `UNCERTAIN`; recovery lock; manual reprint only from Recent Sessions |
| 7.17 | Regression | Historical gallery URLs open; Passport, Photo Pass and stickers unchanged; Private / Prepaid mode works with the Worker unreachable |
| 7.18 | Accessibility | VoiceOver labels and Dynamic Type XXL on checkout, recovery and operator screens; portrait 11-inch |

## Step 8 — Operations

- **Backups:** export TEST D1 before every migration (step 2). Migrations are forward-only; restore from the export to roll back data.
- **Worker rollback:** `npx wrangler rollback --env test`.
- **Secrets rotation:** re-run step 3 for the affected secret; rotate the webhook secret in PayMongo then `secret put`.
- **Device revoke:** step 6 SQL; the iPad immediately loses online access; offline policies expire within their window (≤ 4 h by default).
- **Diagnostics:** `GET /v1/admin/diagnostics`; operator screen *Payments Server*, *Interrupted Paid Checkouts*, *Print Accounting*.
- **Cash reconciliation:** count cash, enter it in pesos, keep corrections append-only; reconcile only after offline cash has synced.
- **Production:** any live step (live D1, live secrets, live webhook, `LIVE_PAYMENTS_ENABLED=true`) needs a separate written owner authorization and a separate review. Not part of this runbook.
