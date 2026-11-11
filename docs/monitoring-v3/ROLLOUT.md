# Production rollout - 12 November 2026

Monitoring V3 is deployed. Physical VOZY G80 acceptance remains **NOT VERIFIED**.
The owner explicitly authorized production investigation, additive migrations, existing
credential provisioning, deployment, private Telegram tests and direct integration to main.
This record supersedes the October source-only/non-deployment instructions.

## Verified baseline and source

- Fetched clean GitHub main: `e6709de885b6cae56ebef16bda5f03c3e6e3a3dc`.
- Worker/initial native correction: `c3bd757e3278b3f8f7c5a0e510223a58596fa86f`.
- Final native implementation, including passive gallery metadata reads:
  `fc21679c6b0fcc00194c17b3a08245702895b170`. Worker source is unchanged by that commit.
- Previous production Worker: `/health` returned service `made-to-keep-monitor`, version 1;
  active Cloudflare version `fb17170b-267b-41b0-98bc-18a8ad7cf9c3` (17 October).
- Before rollout D1 had only 0001 and 0002, five configured secret names, V1 device evidence
  dated 30 October and overdue contact. Telegram bot identity was valid, webhook URL empty,
  pending updates zero. These are live findings, not conclusions inferred from old docs.
- Current Worker version: `4d318023-b9bf-4818-a3a8-f629871cea96`, deployed from the implementation
  above. Public `/health` verified version 3, telemetryVersion 3, galleryActivityVersion 2,
  release `monitoring-v3-2026-11-12`. Deployment message includes the full source SHA.

## Database and production configuration

Private pre-migration export `before.sql` was restored into local SQLite and passed
`PRAGMA integrity_check = ok`. Its SHA-256 is
`70224891a8e190232701ef8739f9a01c7ed423d85309ee4a6169918cbc32724d`.
The ledger was inspected before applying **only 0003 and 0004**. All four migration names
are now in the live ledger; required observations/history/episode/lease/V3-queue tables
were verified. No extra schema was needed for queue activity stored in state JSON.

A second private export after deployment restored successfully and passed integrity check.
All 215 original notification IDs and all five original incident codes remained present.
Current incident values can legitimately change on accepted real observations; old database
contents were never restored over production. The fixed test added one notification record.

Existing Worker name, URL, D1 identity `562d5551-c884-43a2-8743-4562f1ed33d1`, payment-health
URL, DEVICE_ALIAS, STALE_SECONDS=900 and `*/5 * * * *` Cron were verified and preserved.
All six required secrets exist. Only the previously absent TELEGRAM_WEBHOOK_SECRET was
created privately through stdin. Device, owner, payment-health, bot and owner-chat credentials
were preserved. Payments and Gallery Workers were not modified or deployed.

## Real Telegram results

The existing bot identity was verified privately with getMe. The webhook was registered at
`https://made-to-keep-monitor.madetokeepstudios.workers.dev/v1/telegram`, using the distinct
secret, allowed_updates=[message] and drop_pending_updates=false. getWebhookInfo afterward
reported that URL, zero pending updates and no delivery error.

All five commands were sent through the authenticated Telegram owner account and replies
were observed in the existing private bot conversation:

| Command | Actual result |
|---|---|
| /status | First correctly reported stale V1 evidence; repeated after enrollment reported fresh V3 printer dimensions, no verified physical output and passive device observations. Full durable reply included camera, payment/backend and event context. |
| /event | Real idle event and idle guest; no event name, session or payment identifiers. |
| /uploads | Real empty queue: pending 0, uploading 0, verifying 0, attention 0; activity/oldest times not reported. Public verification remains required. |
| /incidents | Existing historical printer-readiness condition retained, with transition time, current connection/readiness and operator guidance. No fabricated physical-print uncertainty. |
| /help | Exactly the five supported commands and explicit read-only limitations. |

The fixed /v1/test-notification endpoint was called once. Its labeled monitoring test
appeared in Telegram; D1 records one attempt and delivered_at, no supersession. The initial six command
replies (including the second /status) each recorded one attempt and delivered_at; a later
/status during interruption correctly showed stale evidence. This is
observed delivery for these requests, not a claim of universal exactly-once Telegram delivery.
Local tests cover durable replay, owner-only private authorization, webhook-secret checks,
forwarded/edited/group rejection, rate limiting, bounded retries, Retry-After and ordering.
No unauthorized people or groups were contacted and no synthetic equipment/payment incident
was inserted into production. A combined printer warning bridged pre-existing availability
evidence during migration; the underlying historical record remains intact.

## Carlo installation and evidence

Carlo was connected. Native changes required an in-place update; the original bundle
`com.pocketpixels.PocketPixelsBooth` and team `PQ26682725` were preserved. Simulator and
physical-device builds passed. Library and Documents were copied privately before install.
All three pre-existing protected Application Support files compared byte-for-byte identical
afterward; Documents and the pending gallery queue were empty. No app uninstall, container
restore, event edit, recovery acknowledgment, payment or print was performed.

The initial ordinary launch did not enroll. The saved existing device-only credential was
provisioned privately via the supported launch environment into the existing device Keychain.
The server then stored a real accepted V3 observation at **12 November 00:13:14 PHT**:
idle event/guest, no pending galleries, selected auto transport connecting, readiness unknown,
no unresolved print evidence, physical output unverified. Authenticated overview reported
online=true and the expected V3 dimensions. Monitoring did not connect to a printer or
activate the camera to obtain this observation.

The signed development profile includes Carlo and expires **18 November 2026, 19:28:56 PHT**.
The final passive-read correction was built, tested and installed in place while Carlo
was already stopped for the contact test. No extra Worker deployment was needed.
This build is not suitable for unattended event use beyond that expiration without renewed
valid signing. No paid membership, signing identity or bundle-setting change was made.

Controlled idle contact interruption was verified with real elapsed time. The last accepted
sample remained 00:13:14 PHT. At 00:28:27 overview reported overdue; /status correctly showed
STALE. Cron observed missing contact at 00:30:37 PHT, recording and delivering one warning
on its first attempt. Telegram explicitly said current equipment is unknown and missing
contact does not diagnose failure. No camera incident or new printer episode was generated.
The existing printer episode remained revision 1, without repeats. No threshold or production
timestamp was edited.

Restoration verification is pending device unlock: Carlo auto-locked during the wait and
iPadOS refused the ordinary relaunch at 00:31. Contact stayed overdue, with no invented
recovery. The owner was asked to unlock Carlo. The final protected-file copy was likewise
refused while locked; earlier complete post-install comparison passed. This is a hardware
access limitation, not evidence of file loss.

## Validation, costs and limits

- Relevant complete Worker suite: 59 passed, zero failed/skipped; real local D1 persistence,
  migrations, frozen V2 rollback, incident safety and request budgets included.
- Final affected Swift telemetry/scheduler suites: 26 passed, zero failed/skipped.
- Existing gallery migration/delivery suites: 26 passed, zero failed/skipped (52 distinct
  targeted Swift tests total).
- Simulator build-for-testing, signed Carlo build, Node syntax, Wrangler dry-run and whitespace
  checks passed. Build/install preserved signing settings. See VALIDATION.md.
- Package 41.35 KiB, gzip 11.00 KiB; reported Worker startup 2 ms. Existing local heavy-request
  tests enforce <=40 D1 API calls. No new dependency, Worker, database, service or paid setting.
  Independent Cron payment health was available with fresh reconciliation after deployment.
  Account subscriptions API was unavailable to the existing OAuth scope (403), so billing-plan
  status/account-wide runtime usage is not independently certified. No new recurring expense
  was introduced by this rollout.
- Existing hosted gate on baseline main could not start: GitHub annotation explicitly says
  the account is locked due to a billing issue. No workflow rerun or application workaround.
- One real empty-queue sample proves reporting integration. One POST plus two verifiers and
  accepted-POST capacity waiting are verified with actual isolated scheduler states; no real
  customer gallery was generated to manufacture busy production telemetry.
- Final read-only audit found general queue summaries could migrate DEBUG placeholder URLs
  and create their directory. Monitoring now uses a passive read that preserves both absent
  storage and existing metadata; normal gallery migration behavior is unchanged. The queue
  was empty throughout live verification, so no real saved gallery was affected.
- Real printer paper/radio, venue Wi-Fi faults, active-event interruption, camera permission/
  runtime interruption and physical acknowledgment/relaunch/next-guest acceptance remain
  deferred. Their software policies are covered locally. Never infer equipment failure from
  missing contact or a printed receipt from a successful transfer.

Private evidence is outside Git under `/Users/marc/.codex/private/monitoring-v3-20261112/`.
Credentials, chat identifiers, customer media and raw private data are excluded from source.

## Rollback

Preserve all additive D1 schema and newer evidence. Never restore the backup over current data.
The exact pre-assignment production Worker version is
`fb17170b-267b-41b0-98bc-18a8ad7cf9c3` (V1); code can be rolled back with the existing Wrangler
rollback command. V1 has no command endpoint, so privately remove its webhook while preserving
pending Telegram updates if that rollback becomes necessary. Keep the new webhook secret;
there is no reason to rotate working credentials.

Repository pre-change rollback reference is `e6709de885b6cae56ebef16bda5f03c3e6e3a3dc`;
its source is the earlier V3 implementation, **not** the previously deployed V1 binary.
Frozen V2 in test/fixtures is compatibility evidence, not a new deployment target.
V2 code can use the migrated schema and cannot consume the dedicated V3 printer/camera queue.
V1/V2 clients remain accepted; the updated app negotiates down and retries legacy on rollback
422. Relaunch/reconfigure after changing server capability because negotiation is process-cached.
An app rollback must also install in place with the original bundle/team and valid profile,
preserving Keychain and all customer/recovery/gallery data. Physical uncertainty is never
cleared or automatically resent as part of rollback.
