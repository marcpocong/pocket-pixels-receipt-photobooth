# Event Integrity & Recovery release

Source baseline: `34777dc6886f7186a684e300a1576d79f42036f3` (Stage 3 merged and installed on Carlo). Branch: `event-integrity-recovery`.

This release fixes correctness gaps in the existing Stage 3 architecture (`EventLifecycleCoordinator`, `EventRunStore`, `SessionSetupCoordinator`, `EventDesignLibraryStore`, `EventRunReportingView`, `LegacyAttributionStore`, `PaymentRecoveryCoordinator`). It adds no new event-management architecture.

## Confirmed findings

| # | Finding | Classification | Evidence |
|---|---|---|---|
| P0 | Upgraded paid booth with no event run shows **No Event Configured** | Reproducible defect | Regression test reproduced Carlo's recorded state (LIVE paid event active, admission open, no run): status `noEvent`, `linkedCommercialEventID == nil`, server never checked. |
| P1a | Lost `createEvent` response can leave an unlinked commercial draft; a retry creates a duplicate | High-risk gap (confirmed mechanism) | Worker minted `crypto.randomUUID()` with no idempotency key. A 500 after the insert (audit write) also left an event. `connectPaidCheckout` had the same risk as `startNewPaidOccurrence`. |
| P1b | Reports → Manage reset statistics outside the reviewed lifecycle | Architectural gap / UX | `EventRunReportingView` called `EventRunStore.startNewRun` directly; it ended the current run with no setup review. |
| P1c | Historical attribution by whole calendar day, written entry by entry | Reproducible defect | Two events on one day could only be attributed together; a failed write mid-loop left a day partly attributed. |
| P2a | Overlapping payment-recovery refreshes could publish stale results | Confirmed race | `ContentView.onAppear` → `launch()` → `refresh()` and the first `scenePhase == .active` → `refresh()` run concurrently at launch; no single-flight. A late older answer overwrote a newer one; a dismissed item could reappear and its operator resolution could be overwritten. |
| P2b | Long payment verification gave no escalation | UX improvement | `pollQRStatus()` polls indefinitely with one static message. |
| — | Reports reloaded everything on every journal revision | Performance (identified) | Each `store.revision` bump re-read all session files and archives and re-fetched every order page. |

## What changed

### P0 — upgraded events with no run
- `EventStatusModel.derive` has an explicit no-run path. The committed admission barrier (`SessionAcceptanceStore`: event ID + payments binding) is the only evidence of which paid event the iPad was started for; the server confirms its lifecycle.
  - Paid, admission open, server active for the account → **Accepting Guests**. Before the server answers → **Server Status Not Confirmed**, never success.
  - Admission paused → **Paused on This iPad**; server paused → **Paid Event Paused**.
  - Server ended/archived/draft, event missing in this account (404), different payments connection, or open paid admission with no committed event → **Needs Operator Review**.
  - Prepaid: open + valid → Accepting; paused with a valid policy → Paused on This iPad.
- `linkedCommercialEventID` falls back to the committed admission identity when there's no run, so Check Status, Pause Paid Event and diagnostics work.
- **Record Event Run** (Current Event card, operator-protected): re-verifies the paid event on the server, then writes the first run in one atomic manifest write (`recordedAfterUpgrade = true`, paused if admission is paused). Idempotent: a repeat or relaunch returns the same run; a different identity is refused. It never creates or changes a paid event, never changes admission/prices/policy, never assigns earlier sessions. The first-guest upgrade path is unchanged.
- Pause Booth works without a run.

### P1 — exactly-once paid-event creation
- App: every creation (Connect to Paid Checkout, regular paid sessions, Start New Paid Occurrence) writes a durable `CommercialEventCreationIntent` (`EventCreationV1/intents.json`) with a stable operation ID **before** the request, sends it as `Idempotency-Key`, and links the design only after the server event is identified. Only 4xx refusals close an intent automatically; timeouts and 5xx stay open.
- While an intent is open on a connection, no further creation is possible there. Event Setup shows **Event creation needs confirmation**: Check Original Request (exact lookup), Complete Linking, Review Existing Draft (explicit, reason required, recorded as `operator-selected`), Close Original Request (reason required, recorded as `operator-abandoned`; nothing deleted). Intents never cross TEST/LIVE connections.
- Worker (`Backend/PaymentsWorker`): migration `0006_event_creation_idempotency.sql` adds `events.creation_operation_id`, `events.creation_fingerprint` and a partial unique index per account. `POST /v1/admin/events` with a key replays the original event (200, `replayed: true`), refuses a different payload (`422 idempotency_mismatch`), and survives concurrent duplicates. New read-only `GET /v1/admin/event-creations/:operationId` returns the event or `404 creation_not_found`. Event and audit rows now commit in one batch. Keyless requests are unchanged and use the original column set.

### P1 — occurrences vs statistics
- Reports → Manage no longer starts runs; it links to Event Setup. Fresh statistics = End Event (this iPad) → Start New Occurrence (reviewed setup, `previousRunID` link). Multiple runs can share one commercial event deliberately; revenue is matched per run by exact order/checkout/session identity. No separate "reporting segment" concept was added. `EventLifecycleCoordinator.startNewRun` (unused) was removed; `EventRunStore.startNewRun` remains only as a low-level fixture API.

### P1 — historical attribution
- History lists unassigned sessions individually (grouped by day for display), with explicit per-session selection; nothing is auto-selected. The sheet reviews the exact selection (time, format, receipt name), requires a reason and shows what was saved.
- `LegacyAttributionStore.attribute(_:to:knownRuns:note:exact:)` validates the whole batch first (exact identity, already attributed, duplicates, future time, real-run bounds, unknown run, empty reason) and appends it in one durable write with a shared `batchID`. Any failure writes nothing. An earlier-event record is created only after the batch validates. Old journal entries decode unchanged.

### P2 — payment recovery and verification
- `PaymentRecoveryCoordinator.refresh()` is single-flight with one coalesced follow-up pass; callers await a pass that began after their request. A checkpoint resolved during a pass is skipped; an armed resume follows the newest classification and is withdrawn when no longer resumable. `lastRefreshCompletedAt` is set only when every checkout was checked. The classifier and checkout state machine are unchanged.
- Guest verification escalates **Checking Payment → Taking Longer Than Expected → Attendant Assistance Required** (45 s / 180 s past the later of start and QR expiry; 3 / 15 consecutive failed checks; immediately on a server review hold). Interface only: polling continues, no outcome is inferred, no new checkout or cash fallback is offered. Foregrounding keeps the clock; only a deliberate new checkout or a new guest restarts it.

### Diagnostics
- Current Event → **Booth Health**: admission, event state and identity, payments server, printer/print recovery (cached state is reported as "last reported", never as live), payment recovery, pending galleries, creation recovery and local storage as Ready / Warning / Unavailable / Needs Operator Review. Observational only. **Share Support Summary** exports text with shortened IDs; URLs, paths and token-like strings are scrubbed.

## Deployment

### Backend (requires owner approval — not deployed)
The app works against the **currently deployed** Workers: creation still succeeds (the header is ignored), and after a lost response Check Original Request reports that exact lookup isn't available, leaving the explicit draft review. Exact recovery needs the Worker update.

Order (TEST first, then LIVE):
1. `npx wrangler d1 migrations apply pocket-pixels-payments-test --env test --remote` (applies `0006` only; additive).
2. `npx wrangler deploy --env test`; verify `/v1/health`, create with a key twice (same ID returned), then look it up.
3. After approval: the same with `pocket-pixels-payments-live` / `--env live`.

The migration must precede the Worker: a keyed create on an un-migrated database fails with 500 and creates nothing (tested), while keyless creates keep working.

Rollback: redeploy the previous Worker version; leave the columns and index (older Workers ignore them). No data is rewritten either way.

### App (requires owner approval — not installed)
All new files and fields are additive; manifests keep `schemaVersion = 1`. New files: `EventCreationV1/intents.json`. New optional fields: `EventRunRecord.recordedAfterUpgrade`, `LegacySessionAttribution.batchID`. No new `OperatorWorkspaceRoute` cases. Rolling back to Stage 3 ignores these (Stage 3 drops unknown run fields only when it next rewrites the manifest).

Before installing on Carlo: confirm idle (no guest, print or payment in progress), Payment Recovery shows nothing unresolved, take the same private Application Support + preferences safeguard as Stage 3, install in place (never uninstall), relaunch, compare file counts and preferences.

### Operator acceptance on Carlo (after install, during an idle window)
1. Operator home: Current Event shows the LIVE event as **Accepting Guests** (or a truthful paused/review state), not "No Event Configured". Booth Health lists every item.
2. If no run exists: Record Event Run → confirm; status stays Accepting, admission unchanged.
3. Reports → History: open a day, select one session, review; cancel without saving.
4. Optional, TEST connection only: Connect to Paid Checkout on a scratch design; confirm one draft is created.

No live payment is needed for acceptance.
