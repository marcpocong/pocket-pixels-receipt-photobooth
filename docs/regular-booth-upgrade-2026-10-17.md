# Regular Booth reliability upgrade — October 17, 2026

## Scope and custody

Starting local and remote main: `8ade190a85c186558a7110a561a14974540cd4ab`. The latest Production Gate for that main passed. Carlo was detected as a paired, available physical iPad Pro 11-inch, UDID ending `E8BC01E`, with `com.pocketpixels.PocketPixelsBooth` 1.0 (1) installed. The existing bundle identifier and development team are preserved. No dependencies were added.

The initial working tree contained the gallery-footer implementation. It was saved privately as a patch, baseline-built successfully, and preserved in a separate commit (`320c40b`) before this upgrade. `.claude/` is left untouched. Private backups, credentials, customer data, and result bundles are outside the repository, under the owner's private Codex directory.

## Operational modes and event ending

`SessionAcceptanceStore.State.boothMode` distinguishes Regular Booth from an applied event. Commercial policy, a reusable design, an operational occurrence, and historical records remain separate. Regular Booth has a local zero-price authorization, no commercial ID or occurrence, no Payments Worker authorization call, independent saved formats/copies, and standard studio branding. It uses the existing capture, sticker, receipt, printer and queued-gallery services.

Only an unbound, unpaused, readable prepaid installation without an applied event or recovery obligation bootstraps automatically. Legacy ended pointers and old paid bindings require the protected **Return to Regular Booth** action. An unavailable server, paused event, unreadable journal or interrupted transition never selects Regular Booth automatically.

End Event first closes admission and records a durable intent. A server-wide end is mutated once and read back; an ambiguous response is reconciled by reads. A local-only end verifies the original connection and event without ending it for other booths. The manifest then atomically completes/detaches the occurrence. Branding and policy configuration commit before the regular admission barrier reopens. History, galleries, financial links and drafts remain intact. Relaunch resumes a verified transition; if a write fails at the final barrier, **Resume Booth** can finish reopening after safety checks.

An interrupted paid Start retains its intended event and connection in the admission journal. It must be reviewed before a different occurrence can be ended or silently substituted. Explicit local return with no recorded occurrence verifies the original intended paid event first.

The dashboard's primary card is **Booth Status**. It shows the operational occurrence rather than a completed pointer, clear pause/recovery explanations, **Set Up an Event**, **Return to Regular Booth**, and **Booth Health**. Regular defaults and Remote Monitoring have direct operator links.

## Library and cleanup

Existing design archive/restore and saved-draft discard remain protected. A design's destructive action is shown only after readable history, local drafts and pending commercial creation have been checked; dependencies are checked again on confirmation. Applied/commercially linked/historically referenced designs remain protected. Archived designs disappear from everyday selections and can be included from management/history.

An unused, noncurrent local historical/draft/completed run can be deleted only when it has no commercial identity, guest-session records, receipt archive, successor occurrence or pending transition, and dependency inspection is complete. Deletion is atomic and idempotent. Used runs are archived instead. No existing event, run, design, customer or financial record was deleted during implementation.

Server commercial drafts retain **Archive**. A hard-delete endpoint is intentionally not exposed: the server cannot prove the absence of offline designs, creation recovery or run references on other booths. That incomplete dependency inspection must fail closed, even when the financial database contains no orders.

## Payments and detached recovery

`POST /v1/orders/:id/reconcile` is authenticated, booth-device scoped, limited per device and leased per attempt. It retrieves the original PayMongo intent using that environment's server credential and the canonical verifier. It creates no replacement checkout. Concurrent webhook/reconciliation uses SQL guards and a unique entitlement per order. Superseded late payment remains held for review. Manual-review evidence cannot be cleared by subsequent automatic success, timeout or expiry observations. Pending provider evidence after a QR timer expires remains unknown, rather than becoming proof of nonpayment.

The iPad reads status first, so a verified entitlement is not delayed by a provider monitoring failure. During an unresolved wait it requests rate-limited reconciliation periodically, retaining the original session/order/QR identity and bounded polling. Background/foreground reads preserve the same ownership.

Opt-in **Unattended · QR Ph only** is committed with reviewed event acceptance. Before order/QR creation, it verifies the current authoritative QR-only event/revision, connectivity, writable checkout storage, printer readiness/recovery and a bounded camera initialization. No capture or paper is produced by readiness checks. Hardware readiness is a point-in-time observation, not a guarantee against later equipment failure.

**Save My Checkout and Leave** durably preserves the original checkpoint and private gallery snapshot before stopping callbacks. It displays a random owner-assisted recovery reference. Only after this durable handoff may the guest return to Welcome. The payment remains unresolved; server/device reconciliation continues. Original recovery never automatically unlocks a later guest, and no uncertain print is automatically resent. Owner authentication and server state are required to arm recovery. The displayed reference alone is not authorization; self-service reclaim is not exposed.

New customer ownership identifiers combine the readable receipt timestamp with a UUID, so rapid handoff, repeated device clocks and different booths cannot reuse a checkout identity. Historical/recovered identifiers remain exact. The existing Apps Script upload deployment was surgically updated from version 23 to version 24 to accept the UUID suffix while preserving legacy IDs; its URL, owner and access configuration are unchanged. Pure validator tests cover both shapes and reject partial/path/URL suffixes. Version 23 remains the rollback target.

## Monitoring and cost

A separate `made-to-keep-monitor` Worker and D1 database observe Carlo. The payment database is not bound to it. Its payment-health token can read only a minimal environment/gate/reconciliation-health endpoint; it has no payment administration authority. A separate device token writes fixed health telemetry, and an owner token protects the overview. Credentials stay in Worker secrets and the iPad Keychain, not source control. Photos, gallery credentials, payment QR payloads, prices, tokens and free-form logs are rejected from telemetry/alerts.

Five-minute heartbeats, a fifteen-minute stale threshold and five-minute scheduled checks detect device absence, backend unavailability/stale reconciliation, unresolved verification/review, verified purchases waiting outside an active guest, printer recovery/uncertainty, storage faults and paused/recovering admission. Notifications are deduplicated by incident transitions with cooldowns and durable, bounded delivery retries. Failed alerts remain visible. The overview is authenticated and read-only. No remote control is provided. iPadOS can suspend a background app; keep Carlo foregrounded during operation. A total Cloudflare outage is outside this independent Worker's detection boundary.

The dashboard was verified to show **Free — Current plan — $0**. Free quotas shown were 100,000 Worker requests/day, five Cron triggers, ten D1 databases, five million D1 rows read/day and 100,000 rows written/day. There were two D1 databases before provisioning and three afterward. One device at five-minute intervals adds about 288 heartbeats/day plus 288 scheduled checks; incident storage is small and delivery history is bounded. No plan upgrade, paid add-on or subscription was activated. Free quotas are shared with existing services; exceeding them can interrupt monitoring.

Telegram bot: `@MadeToKeepCarloAlertsBot`. The owner privately started the bot on their phone. The real owner test notification was accepted by Telegram and its monitoring outbox record shows one delivery attempt and successful delivery. No payment or printing was performed for this test.

## Deployment evidence

- Private pre-migration LIVE and TEST D1 SQL backups were downloaded and permission restricted.
- Additive migration `0007_on_demand_reconciliation.sql` adds only per-attempt coordination timestamps.
- TEST code deployed and verified as TEST, LIVE gate false; authenticated reconciliation health fresh.
- LIVE deployed through `npm run deploy:live`, preserving `LIVE_PAYMENTS_ENABLED=true`; authenticated health verified LIVE and fresh reconciliation.
- LIVE deployed code version: `69aab527-f904-4031-9c21-fe5bf0ebefc2`.
- Pre/post LIVE counts agree: 57 orders, 56 payment attempts, 56 entitlements and 53 print batches. Existing unfinished records were retained. No real-money transaction or refund was created.
- Independent monitoring Worker, schema, schedule and secrets deployed. Unauthorized heartbeat/overview requests are rejected. Final active monitoring version and Carlo enrollment/installation are recorded in the acceptance addendum below.
- Payments automation: 223 tests passed. Monitoring automation: five tests passed. Local D1 migration tests and payment/monitoring dry runs passed. The LIVE dry run used the explicit enabled-gate override.

## Rollback

For a payment-code emergency, the preceding LIVE code version is `48e7850a-a50b-4e80-9235-ee574064d3c8`. Use the explicit LIVE environment and verify `/v1/health` still reports LIVE enabled after rollback. The new columns are additive and can remain. Do not restore a database backup over new financial activity; use it only through a reviewed recovery operation. The earlier code does not expose the monitoring-health endpoint, so monitoring will correctly report that endpoint unavailable after rollback.

For app rollback, retain both the current and pre-upgrade signed artifacts privately and install over the same bundle only when the booth is idle. Never uninstall or clear local/Keychain state. Prior builds ignore additive fields; a paused admission barrier remains fail-closed. The preceding app's signing profile expiry must be checked before any rollback.

## Device acceptance and remaining verification

The owner confirmed Carlo is idle and the physical printer is unavailable. Physical paper delivery, scan quality, printer reconnect behavior and a complete real photo-to-paper-to-online-gallery session are therefore not verified. No simulated print is described as physically successful.

The first broad simulator run exposed old lifecycle/reuse expectations and payment-reader assumptions, which were corrected, plus Keychain errors in an unsigned simulator run. Final verification used the CI's ad-hoc simulator signing: all 673 reported tests passed (708 device executions including parameter cases), zero failures/skips. PR/CI, signed build identity, preservation checks and installation outcome will be appended after they are independently verified.


Carlo was rechecked as paired/available immediately before installation. A fresh 442 MB private Library backup matched the original backup exactly. All 58 checkout checkpoints were resolved; all 267 print-outbox entries were locally delivered, with no uncertain/pending print accounting. Build 1 was upgraded in place to **1.0 (2)** and launched successfully. No uninstall or data reset occurred.

Post-install comparison preserved every Application Support file unchanged, including customer archives, payment journals, designs, event history and workspace. All original preference values matched; only the monitoring endpoint preference was added. OS launch snapshots and runtime caches changed normally. The monitoring device credential was provisioned privately into its separate Keychain service.

The owner completed the protected **Return to Regular Booth** action and confirmed **Make a Memory → Format → Camera** works without payment. Independent device readback confirms `boothMode=regular`, `blocked=false`, local prepaid mode, no current run, and byte-equivalent historical run records. The camera test was cancelled before capture/printing and Carlo returned to Welcome.

The real Carlo heartbeat reports network/storage ready and the unavailable printer accurately. The independent Worker delivered the printer and initial paused-state alerts once each; unauthorized heartbeat and overview requests return 401. Monitoring deployment version is `7cbf7596-d59d-4871-9cdb-660c2f7f818f`. A controlled actual missing-heartbeat/recovery test is in progress while GitHub CI runs; its final delivery results will be included in the release report.

The PayMongo dashboard independently shows the existing LIVE endpoint enabled for `payment.paid`, `payment.failed` and `qrph.expired`. Endpoint, webhook secrets and subscription were preserved. Real provider settlement/webhook delivery and real-money recovery were not manufactured for testing.

Signed Release verification passed with bundle `com.pocketpixels.PocketPixelsBooth`, team `PQ26682725`, Carlo included in provisioning, and executable SHA-256 `3f87f1b683356c55bba0ddf31112ab8c1d9af01039d9f15930ace9c6b54550fc`. The current development profile expires **October 19, 2026 at 4:10:21 PM Asia/Manila** and needs renewal before continued operation beyond that time.

Release candidate branch: `regular-booth-reliability`; PR [#7](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/pull/7). Full release integration/CI status and actual monitoring outage results are recorded in the final release report. This is not a claim of complete physical production acceptance: the VOZY G80 is unavailable, so physical receipt delivery, scan quality, reconnect/recovery and a complete real capture-to-paper-to-gallery flow remain owner acceptance steps.
