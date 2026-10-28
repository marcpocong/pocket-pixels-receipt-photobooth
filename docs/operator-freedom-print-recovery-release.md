# Operator freedom and print recovery — 2026-10-29

The repository and remote `main` were both verified at `4551ab37585d24f8b071452b06f4ab34a3499ef6` before implementation. Bundle ID, signing configuration, PIN system, guest artwork, production feed/cut commands and dependencies are unchanged.

## Audit and cause

The previous implementation used receipt inspection and checkout recovery as global equipment gates. `ArchivedReceiptReprintController` and `SamplePrintPolicy` refused unrelated operator jobs; Home classified history as current printer state. `confirmPrinterRestarted` introduced a mandatory diagnostic-text cycle. Reconnect cancelled an existing connection. Event ending reused the Start/change-event gate, so an interrupted guest could prevent an otherwise safe End. Imports already filled **unused** sample slots, but incomplete layouts and preparation/readiness gates could leave Print Sample disabled. Thank You could be published before deferred batch cleanup, so its one-time timer eligibility check could miss scheduling permanently.

| Concern | Authoritative state and release behavior |
| --- | --- |
| Active physical job | Coordinator reservation, spooler ownership and Bluetooth transmission; another operator command cannot overlap or queue through repeated taps. The spooler retains its physical handoff delay. |
| Current hardware | Usable transport plus one explicit hardware-readiness acknowledgment after uncertain output; no mandatory paper test. |
| Historical uncertainty | Existing per-copy outbox and audit. Acknowledgment changes inspection metadata, never the original copy outcome or payment entitlement. No automatic resend. |
| Financial obligation | Original checkout, order, entitlement and reports remain in their existing stores. Closing/ending parks interaction follow-ups without settling money. |
| Archived replacement | Verified frozen archive/raster; original session association, new batch, editable 1–10 copies, no payment or guest metrics. |
| Samples | Existing sample preparation/rendering, explicit photo reuse, current readiness and active-guest gates; historical outcomes alone do not prohibit a sample. |
| Event lifecycle | Admission closes, current transport and storage are checked, follow-ups are retained, then existing scoped server/local End semantics apply. |
| Completed guest | One generation-specific deadline, started after batch cleanup using frozen print options. Upload completion does not control reset. |

## Operator workflow

Home, Printer Setup, Help & Recovery, archived reprints and Sample Print Studio share `OperatorPrinterControls` and coordinator readiness. The interrupted guest button targets protected Recovery directly. An incident shows journal counts and a direct original-archive link; a missing/corrupt archive produces an explanation rather than regenerated customer artwork. Archived replacement quantity remains operator-selected, including after event ending.

Reconnect preserves healthy links and joins existing connection attempts. Connection/service/characteristic discovery has an eight-second watchdog and two bounded retries; safe reconnection also resumes after Bluetooth returns. Cancelled scan timers cannot stop a newer scan. No retry path sends physical print bytes. Connection requests/results and hardware acknowledgment are recorded in the existing outbox, with new operator jobs journaled before bytes. Entire uncertain batches survive pruning, including their earlier successful transport reports.

Quick Test Print renders a 576 × 220 diagnostic containing only MADE TO KEEP / PRINTER TEST / PAPER CHECK / TEST ONLY. It uses the existing diagnostic envelope, coordinator, spooler and receipt heading/finishing commands. Success says **“Test sent. Check the paper.”** An uncertain diagnostic remains uncertain and needs hardware acknowledgment; it is never retried automatically.

Sample Studio exposes Fill Empty Slots and an explicitly labeled reuse action. Missing slots, imports, preview preparation/failure, active guests, busy transport and unavailable hardware have visible explanations. Preparation continues automatically after edits. Samples retain `.operatorSample` and create no guest checkout or gallery.

End Event retains the original snapshot/photos and parks outstanding financial follow-ups before detaching the run. A retention failure leaves admission closed and the event uncompleted. The existing choice between this iPad and the shared paid event remains explicit. Server verification failure cannot select free operation. Reports, queued uploads, archived sessions and payment follow-up remain accessible afterward.

Thank You uses **30 seconds with a printed gallery QR**, **60 seconds without one**, and repeatable **30-second extensions** during the final ten seconds. There is no completed-session “Still there?” overlay. The deadline survives background/foreground and view updates; generation checks prevent an old timer from resetting the next guest. Existing unfinished-guest abandonment and financial protections remain separate.

## Local validation

`/tmp/PocketPixelsFreedomAcceptance.xcresult`: **234 tests passed, zero failures, zero skips**, on the portrait 11-inch iPad Pro simulator, iOS 27. Includes normal ContentView → Welcome → PIN → Home → Recovery → Printer Setup → Sample Studio UI navigation, without a special application-root fixture or a physical print.

The 14 new `OperatorFreedomReleaseTests` cover:

- Controlled CIM eight-copy batch: six reported sends, uncertain bytes on copy seven, no copy eight; relaunch, acknowledgment, exact saved-raster replacement with operator-selected two copies, separate audit batch, optional diagnostic, sample, retained paid follow-up, scoped event End, and a next regular guest.
- First/final-copy interruption before and after bytes; operator source failure matrix; no automatic retry.
- Duplicate taps, operator authentication, successful-send/outcome-save failure, conservative launch recovery, and retention failure.
- Complete uncertain-batch evidence after more than 300 later prints.
- Replacement prints excluded from original paid fulfillment, checkout classification and guest event statistics, including reconciliation after relaunch.
- Explicit sample photo reuse and automatic preparation; visible unavailable reasons.
- Frozen 30/60-second deadlines, repeated extension, blocked unsafe expiration, foreground elapsed time, stale-generation isolation and temporary-state-only reset.
- Idempotent reconnect policy and the established diagnostic finishing bytes.

Related suites exercised print durability/reliability, close/continue, event lifecycle/integrity/operations/reporting, regular booth, prepaid authorization, paid recovery, gallery delivery, sample studio, customer experience and session isolation (including the existing 1,000-session test).

The final signed arm64 build for Carlo succeeded with the existing Apple Development identity and `com.pocketpixels.PocketPixelsBooth`. Machine-local build/test results and installation receipts are under `/tmp/PocketPixelsFreedom*` and `/tmp/pp-carlo-*`; no app binaries or customer data are committed.

A navigation and release-regression follow-up after the direct guest-error routing change also passed: **23 tests, zero failures/skips** (`/tmp/PocketPixelsFreedomNavigation.xcresult`). After the final financial-source isolation change, **124 focused tests passed** (`/tmp/PocketPixelsFreedomFinancialIsolation.xcresult`), followed by **79 journal/checkout/event compatibility tests** (81 executions with parameter cases, `/tmp/PocketPixelsFreedomJournalCompatibility.xcresult`), all with zero failures/skips.

The final corrected signed build was installed **in place** on Carlo with `devicectl`; normal application launch succeeded. Actual iPad operator-control interaction was not inspected; the protected control journey was verified in the simulator.

Curated simulator screenshots: [Home](../BuildArtifacts/OperatorFreedom/home-printer.png), [Recovery](../BuildArtifacts/OperatorFreedom/recovery.png), [Sample readiness](../BuildArtifacts/OperatorFreedom/sample-readiness.png). Git delivery and the eventual Production Gate conclusion are reported with the release commit; CI is not inferred from local results.

## Physical validation boundary

Automated printing used simulated transports. No physical paper test, real payment, real CIM receipt reprint, historical-record clearing, real event End, uninstall, container reset or Keychain reset was performed. Software test success does not verify VOZY G80 paper movement, cutting, power-cycle recovery or physical customer delivery.

With the operator present and explicitly authorizing paper use, validate a printer restart/reconnect, one readiness acknowledgment, optional Quick Test Print and a deliberate synthetic archived replacement/sample. Inspect the actual paper and cutter. Validate 30/60-second guest displays on Carlo. The real interrupted CIM session remains an operator review item; its physical outcome is not claimed recovered by this release.
