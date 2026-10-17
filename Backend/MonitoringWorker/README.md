# Made to Keep monitoring

A separate Free-plan Worker/D1 service observes Carlo and the LIVE Payments Worker. It cannot create orders, grant entitlements, print, change events or resolve incidents on Carlo. Its overview is an authenticated JSON API; no remote control is exposed.

Deploy using the existing pinned Wrangler in `../PaymentsWorker/node_modules/.bin/wrangler`, with `--config ../MonitoringWorker/wrangler.toml` when running from PaymentsWorker. No new npm dependencies are needed. Verify the account is still Free and has room for one Cron trigger and D1 database before provisioning another environment. Never activate paid services.

Secrets (put through Wrangler stdin, never command arguments or source):

- `DEVICE_TOKEN`: one high-entropy credential for Carlo heartbeat writes only.
- `OWNER_READ_TOKEN`: separate high-entropy owner credential for overview and the fixed test-message action.
- `PAYMENTS_HEALTH_TOKEN`: the Payments Worker's `MONITOR_READ_TOKEN`; it reads only minimal health.
- `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`: owner-controlled private bot/chat. Never include either in diagnostics or URLs shown to guests.

Endpoints:

| Route | Credential | Purpose |
|---|---|---|
| GET `/health` | None | Public service identity only |
| POST `/v1/heartbeat` | Device | Bounded, allowlisted health telemetry |
| GET `/v1/overview` | Owner | Read-only status, heartbeat, incidents and delivery state |
| POST `/v1/test-notification` | Owner | Fixed nonfinancial test message, at most one queued per hour |

Normal heartbeats run every five minutes. The device is stale after fifteen minutes; Cron checks every five minutes. Incident transitions are deduplicated, recovered states are explicit, notifications have a fifteen-minute per-incident cooldown and at most five delivery attempts. Failed delivery remains visible. Obsolete notifications are retained with `superseded_at`, separately from successful delivery, so failed alerts for recovered incidents cannot block new alerts. Completed/superseded delivery history is retained for thirty days; active incidents and exhausted retries remain visible. An unconfigured/unseen device is not falsely announced as offline before enrollment. Do not simulate a stale LIVE device by editing production rows; use the local tests.

On Carlo, **Operator → Remote Monitoring** stores the device credential in Keychain and the HTTPS endpoint in preferences. For an authorized in-place release, `devicectl` may provision `MTK_MONITOR_ENDPOINT` and `MTK_MONITOR_DEVICE_TOKEN` in the launch environment; the app consumes them into the same settings/Keychain. Keep this environment private and do not log it. The Telegram token and owner credential never belong on the iPad.

Run tests from PaymentsWorker with `npm run test:monitoring`. They run the production module with real local D1 under the existing Miniflare dependency, using synthetic outbound Telegram responses. They cover auth scopes, input redaction, stale heartbeat/recovery, deduplication, bounded Telegram failures, obsolete-alert queue starvation, payment-backend failure/recovery, environment/gate checks and stale reconciliation. A simulated send is not an actual owner delivery; deployment acceptance records the separate real test.

Before upgrading an existing deployment, privately export its D1, apply the additive migrations in order, then deploy the Worker. Migration `0002_notification_supersession.sql` preserves all existing rows and is compatible with the previous Worker for code rollback; do not restore an old database over newer incidents or heartbeat evidence.

Limitations: keep the kiosk app foregrounded; iPadOS background suspension can produce offline alerts. This Worker detects Payments Worker failure independently but shares Cloudflare's infrastructure. A platform-wide Cloudflare outage needs an external independent observer, outside this zero-subscription deployment.
