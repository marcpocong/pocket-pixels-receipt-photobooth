# Made to Keep monitoring

Current source: **Monitoring V3**, release `monitoring-v3-2026-10-30`. Production deployment
is a separate manual operation. See [architecture/policy](../../docs/monitoring-v3/ENGINEERING.md),
[rollout/rollback](../../docs/monitoring-v3/ROLLOUT.md),
[local evidence](../../docs/monitoring-v3/VALIDATION.md) and
[deferred acceptance](../../docs/monitoring-v3/HARDWARE-ACCEPTANCE.md).

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

Normal heartbeats and Cron run every five minutes. Contact becomes overdue at ten minutes
for a last-reported active event, otherwise fifteen minutes. Cron is periodic, not an exact
notification deadline. Missing contact is not a printer/camera diagnosis. Fresh valid evidence
is required for contact/equipment recovery; unknown or omitted metrics never mean healthy.
V3 uses durable incident episodes, contextual printer debounce and a combined printer message;
independent component history remains. Critical evidence is immediate, idle connection changes
are informational. Recovery/escalation bypasses the former fifteen-minute cooldown; unchanged
observations do not create repeat notifications. Delivery allows five attempts and retains
exhausted evidence. Obsolete rows are superseded, never misreported as delivered. Completed /
superseded deliveries expire after thirty days; failed command replies remain visible.
An unconfigured/unseen device is not falsely announced as offline before enrollment.

On Carlo, **Operator → Remote Monitoring** stores the device credential in Keychain and the HTTPS endpoint in preferences. For an authorized in-place release, `devicectl` may provision `MTK_MONITOR_ENDPOINT` and `MTK_MONITOR_DEVICE_TOKEN` in the launch environment; the app consumes them into the same settings/Keychain. Keep this environment private and do not log it. The Telegram token and owner credential never belong on the iPad.

Run tests from PaymentsWorker with `npm run test:monitoring`. They run the production module with real local D1 under the existing Miniflare dependency, using synthetic outbound Telegram responses. They cover auth scopes, input redaction, stale heartbeat/recovery, deduplication, bounded Telegram failures, obsolete-alert queue starvation, payment-backend failure/recovery, environment/gate checks and stale reconciliation. A simulated send is not an actual owner delivery; deployment acceptance records the separate real test.

Before upgrading an existing deployment, privately export its D1, apply only unapplied additive migrations 0001 → 0002 → 0003 → 0004 in order, then deploy the Worker. See the V3 rollout checklist before any live operation. Migration `0002_notification_supersession.sql` preserves all existing rows and is compatible with the previous Worker for code rollback; do not restore an old database over newer incidents or heartbeat evidence.

Limitations: keep the kiosk app foregrounded; iPadOS background suspension can produce offline alerts. This Worker detects Payments Worker failure independently but shares Cloudflare's infrastructure. A platform-wide Cloudflare outage needs an external independent observer, outside this zero-subscription deployment.

## Owner commands (V2 foundation; V3 deployment is manual)

Apply additive migration `0003_owner_commands.sql` before the new Worker. It adds only command
reply/replay/rate tables and an independent payment-health observation. Existing rows remain.
Set a distinct random `TELEGRAM_WEBHOOK_SECRET` (32–256 characters) privately through Wrangler
stdin. Keep `TELEGRAM_CHAT_ID` a private owner user ID. Manually register Telegram's webhook
with `secret_token` and URL `https://<monitor-worker>/v1/telegram` after validation. This task
never registers it. Never put the bot credential, owner credential or webhook secret on iPad.

The POST endpoint verifies the Telegram secret before reading a bounded 4 KiB UTF-8 body.
It accepts only unedited, unforwarded private messages from that same owner user/chat and five
exact commands: `/status`, `/event`, `/uploads`, `/incidents`, `/help` (optional bot suffix).
There are no command arguments or mutation commands. Valid update IDs have durable unique
reply records; replay cannot create a second reply. A D1 transaction limits commands to ten
per minute, replies have atomic leases and at most five attempts. Cron drains due replies;
delivered reply/replay records expire after seven days, with message dates limited to the previous 24 hours
(rejecting timestamps more than five minutes ahead). Unknown commands are ignored. A crash
or network timeout during Telegram delivery can make the remote send outcome uncertain;
Telegram sendMessage has no idempotency key, so replies/alerts retain bounded at-least-once
retry semantics. This never triggers booth, gallery, payment or print side effects.

Each reply identifies report generation and heartbeat times and describes **last reported**
state, with freshness at report time. Payment backend health has its own check timestamp.
Unreported metrics remain unknown; no session counts or event names are invented. `/uploads`
reports an unverified queue, uploading/verifying counts, attention and oldest/activity times.
It never equates accepted POSTs with publicly available galleries. Queue/incident messages
contain no customer content, QR identities, payment identifiers or secrets.

Heartbeats accept additive optional `reportedAt`, `eventState`, `activityAt` and aggregated
`uploads` (pending/uploading/verifying/attention/oldestAt/activityAt), still capped at 2 KiB.
Legacy apps remain accepted. The new app negotiates `telemetryVersion:3` from `/health`, strips V3 fields for V2; a
legacy server receives only legacy fields, and a 422 after Worker rollback retries once
using the legacy schema. Guest activity is observed in this process, never inferred from
historical print outcomes. Missing activity after relaunch is explicitly unknown.

An upload warning requires operator attention or a ten-minute backlog during an active event;
routine idle/offline queued work alone causes no warning. Media remains on iPad. Storage and
paid-camera block alerts are critical, other incidents warnings, and transitions recover
explicitly. Every alert includes its transition time; use `/status` for current heartbeat age.

Rollback: disable/unregister the webhook privately if reverting to the previous Worker. Leave
additive tables and all existing evidence in place. Revert app/Worker code independently;
never overwrite newer monitoring or customer records with an older backup. No production
secrets, production webhook or D1 data are modified by local tests.

## V3 compatibility and release identity

Public GET /health contains only service, version=3, telemetryVersion=3 and the release tag.
Optional V3 fields require telemetryVersion=3 plus reportedAt: printerObservation
(transport/connection/readiness/evidence), camera and guest. Unknown event context is supported
in V3 and omitted when downgrading to V2/V1. The 2 KiB heartbeat limit and all legacy fields
remain. Explicit V3 unknown evidence and lower-capability samples cannot clear higher-capability
printer incidents. Missing queue telemetry cannot clear a gallery incident. No physical output
is verified by telemetry. Passive monitoring never probes a printer or activates a camera.

Migration 0004 adds observations, component transition history, notification episodes, durable
leases, a nullable notification revision, and a separate V3-only printer/camera queue. It leaves
all previous records/tables intact. A code rollback leaves new tables in place and preserves
pending V3 messages for rollforward; V2 resumes its old alert semantics. Frozen V2 source in
test/fixtures is test-only and is not deployed. Owner commands remain exactly the five listed
above; no print, payment, retry, restart, deletion or recovery-acknowledgment command exists.
