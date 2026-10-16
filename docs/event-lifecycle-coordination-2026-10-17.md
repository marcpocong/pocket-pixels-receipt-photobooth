# Coordinated event lifecycle and reporting — Stage 3

Source baseline: `9fa57830ab1f390b7555c80af13dbe123f9e1ab5`. App-only change. **No Payments Worker, Gallery Worker, Apps Script, D1 or credential change is required.** The deployed TEST (`f4eac4ea…`) and LIVE (`76afce7c…`) Payments Workers already provide every capability used here (version-checked `pause`/`resume`/`end`/`archive`, one active event per account, checkout-session identities on order reports).

## Problems fixed

| | Root cause | Fix |
|---|---|---|
| A | `startAccepting` reactivated only a *paused* matching run; a completed one stayed current, so Setup said "Accepting guests" while `runForAdmission` rejected every guest. | Setup computes an explicit **occurrence plan** before any change (`continue`, `resume paused`, `switch setup`, `requires new occurrence`). An ended run is never reopened: Start is refused (admission stays closed) until the operator chooses **Start New Occurrence**, which creates a new run linked by `previousRunID`. The run is committed **before** the admission barrier opens. |
| A′ | The first guest's tap created or replaced runs, so report identity could change mid-event. | Guest admission now only *uses* the committed run. A mismatched setup fails closed with "ask the attendant". Sole exception: an install with no run at all (upgrade path) creates its first run on first admission. |
| B | Session Setup's "Pause" paused the shared server event for every iPad; local End didn't touch the server; maintenance End didn't touch the local run. | **Pause This Booth** is local only. **Pause Paid Event** is a separate, explicit, server-wide action. **End Event** asks for scope (this iPad / this iPad and the paid event). Server ends/pauses from maintenance now complete/pause the matching local run. |
| C | One design → one commercial event per environment; once ended, the design couldn't take payments again. | **Start New Paid Occurrence** creates a fresh commercial event, moves the ended one to the design's append-only `retiredServerEvents`, and carries the reviewed price/methods into an unpublished draft. Old runs keep their `commercialEventID`; orders are never reassigned. The library now owns links: a stale design draft can't replace one. |
| D | The commercial event list awaited the offline ledger, payment-recovery refresh **and** a booth-device check before listing events. | Read-only report listing loads first and independently; device/diagnostics/recovery run afterwards (maintenance view only) and their failure is shown separately. On failure the last list stays visible, labeled stale with its time, and only for the same payments connection. |
| E | Pre-run sessions were silently missing from run totals. | Read-only **Historical Activity** diagnostic (History tab) — see below. |
| F | Event operations spread across eight places. | Operator home = **Current Event** card + Event Setup, Reports & Statistics, Event Library & History, Branding, Equipment, Advanced. Reports is one tabbed screen: Overview · Activity · Sales · History · Manage. |

## Architecture

- **Event Design** (`EventDesignLibraryStore`): reusable creative template. New optional `retiredServerEvents` (and `retiredRegularServerEvents`) record every commercial event a design was ever linked to.
- **Event Run** (`EventRunStore`): one occurrence. New optional `endedAt`, `archivedAt`, `historical`, `previousRunID`, and a manifest-level `pendingTransition`.
- **Commercial Event** (Payments Worker): unchanged authority for prices, methods, orders, entitlements and money.
- **`EventLifecycleCoordinator`** (new): composes the run journal, the durable admission barrier, the local prepaid policy and the server. It owns pause/resume/end, the truthful status, and reconciliation. It has no payment or print authority of its own. Start/Resume still goes through the reviewed `SessionSetupCoordinator.startAccepting`.

### Transition rules

1. Close the admission barrier before any unsafe change; a failed write keeps it closed.
2. For server-scoped changes, write a durable `EventTransitionIntent` first.
3. Mutate with the server's version check; read the event back.
4. Commit the local run only after the read-back confirms the required state; then clear the intent.
5. On an ambiguous result the intent stays, the status reads **Recovery Required**, guest admission is refused, and **Check Status** resolves it from a read-back. A committed mutation is never repeated automatically.
6. Admission reopens only through the reviewed Start, after run, payment policy and barrier agree.

### Status model

`EventStatusModel.derive` combines run status, admission barrier, policy source, local prepaid readiness, the confirmed server lifecycle, the accepted event identity, recovery obligations, storage health and any pending intent. States: No Event, Draft, Ready, Starting, Accepting Guests, Server Status Not Confirmed, Paused on This iPad, Paid Event Paused, Needs Operator Review, Ending, Event Ended, Event Archived, Recovery Required. A local `.active` run or an active server event alone never yields "Accepting Guests".

## Reporting

- **Operational** (Activity): exact session journal only; per run; unchanged counting rules. CSV now includes event name and not-started copies, neutralizes spreadsheet formulas, and contains no tokens, URLs or customer details.
- **Financial** (Sales): per-run totals from fully paginated server orders matched by saved order ID, original checkout ID or claimed session ID (unchanged rules). New: the count of the paid event's orders **not linked to any run on this iPad** (other iPads, pre-run sessions) — shown, never allocated. Failures display "unavailable — does not mean zero"; last refresh time is shown. Physical cash counts and the complete financial CSV remain in the paid-event report.
- **Historical** (History): archives are classified as *exact* (archive run ID or session-journal identity), *operator-attributed*, or *unassigned*. Unassigned activity is grouped by day with formats and receipt names, with the reason it can't be attributed. An operator can attribute a day to an existing run or to a new **earlier-event record** (completed, never current, no commercial link). Attributions are authenticated, append-only (`EventRunsV1/legacy-attributions.json`), audited with a required reason, never move, never touch receipts/galleries/orders, never attribute sales, and are always shown separately from exact counts.

**Remaining legacy limitation:** sessions recorded before Event Runs (Stage 2) have no immutable run identity. They cannot be counted in any run automatically; their paid orders remain fully visible in the commercial event reports.

## Compatibility and rollback

All new fields are optional and additive; manifests keep `schemaVersion = 1`. Stage 2 builds ignore unknown keys (tested). No new `OperatorWorkspaceRoute` cases were added, so saved navigation stays readable by older builds. Rolling back to Stage 2 drops `pendingTransition`/new fields the next time Stage 2 writes the manifest; pause guest admission and confirm the paid event's status in maintenance before a rollback. Nothing deletes customer data.

## Validation

See the final engineering report in the commit/PR for test counts and the Production Gate run. Physical Carlo validation is pending owner approval and an idle window.

## Attendant walkthrough

1. **Create / reuse** — Event Setup → choose a saved design or create one; pick No Payment, QR Ph, Cash or QR Ph + Cash; set copies/price.
2. **Start** — Review & Start. If the design's last run ended, turn on *Start New Occurrence*. If its paid event ended, tap *Start New Paid Occurrence* first.
3. **Monitor** — the Current Event card on the operator home shows status, payment, printer, admission and waiting galleries.
4. **Pause / Resume** — *Pause Booth* affects this iPad only; *Pause Paid Event* affects every booth. *Resume Event* rechecks everything before reopening.
5. **End** — *End Event*, choose the scope, confirm. Nothing is deleted.
6. **Review** — View Reports: Overview, Activity, Sales (exact LIVE/TEST/cash categories), History.
7. **Archive** — Reports → Manage: archive ended runs and unused designs; paid-event archive under History.
8. **Reuse** — Event Setup with the same design → Start New Occurrence (fresh statistics; old history kept).
