# Close Session & Continue

Implementation branch: `codex/close-continue-recovery`, based on main `3ff44be`.
Date: October 24, 2026 (Asia/Manila).

## Operator workflow

Open **Home → Help & Recovery**. The same checkout recovery controls are available in Payment Maintenance.

1. Choose **Close Session & Continue** for the guest who left. If paper may exist, the confirmation asks you to inspect the receipt, clear any jam and restart the printer first.
2. Confirm once. Wait for the saved result. A storage failure leaves the interaction open with an explanation; use **Retry Saving Resolution** or retry the Close action after repairing storage.
3. Serve an unrelated guest, open Session Setup, or choose **Return to Regular Booth**. Leaving an active event uses the existing End Event review; it does not automatically end the commercial event for other booths.

Closing ends the local guest interaction. It does **not** cancel, void, refund or settle a payment. Original purchase identifiers, paid quantity, event/policy ownership, photos, receipt previews and gallery identity remain saved. The actual guest model cancels its old polling/camera callbacks only after the durable handoff succeeds. Resuming first retains the original photos and refuses to overwrite another unclosed guest's snapshot.

**Outstanding Payments & Interrupted Checkouts** remains visible in Help & Recovery. Closed interactions are labelled **Outstanding Payment · Guest Interaction Closed**. They remain eligible for server reconciliation. With the original paying guest present, choose **Resume Original Checkout**. Resume is single use and expires after five minutes; the server must reauthorize the original entitlement before capture. A recovery reference alone cannot authorize capture.

| Situation | Result |
| --- | --- |
| Cancel before checkout | Return to Welcome; preserve any captured assets before clearing the screen. |
| Authoritative no-payment / conclusively unpaid response | Resolve automatically only after saving that resolution. A failed save keeps the item visible. |
| QR expired, pending, unknown, timeout or server unreachable | Keep the financial state unresolved. An operator may park the interaction. Never pay again for that checkout while unknown. |
| Verified payment; guest left | Park locally, retain the original entitlement and purchased copies. Resume the same checkout with server authorization. |
| Online self-declared or offline cash | Preserve the original verification category and offline ledger reference. Closing never upgrades cash to provider verified. |
| Current uncertain print, including server-only print evidence | Inspect paper explicitly. Record the exact current receipt/copy check before closing. No automatic resend. |
| Reviewed historical unknown print | Secondary history; no new physical action or unrelated-operation lock. The original uncertainty remains. |
| A transport still running | Wait for it to finish. Close cannot cancel or isolate bytes already being sent. |
| Corrupt/unavailable records or a failed recovery write | Keep the gate and original data. Repair storage and retry; do not delete journals to clear warnings. |

Outstanding payments, offline cash follow-up and pending/conflicting financial reports keep the original payments connection protected. Resolve them against their original server before changing or removing the connection.

## Causes and production changes

The changes preserve the historical-print fixes in [PR #14](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/pull/14) and [PR #15](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/pull/15). Main was fetched and both merged PRs, their production diffs and existing recovery documentation were inspected before implementation.

- `CheckoutCheckpointStore.resolve` previously ignored its write result. `PaymentRecoveryCoordinator.dismiss` removed the UI item unconditionally. Both now return explicit success/failure. Failed resolutions stay visible with retry guidance. Terminal background resolutions follow the same commit-before-publication rule.
- Local workflow closure previously shared the financial-resolution field. A separate durable parked state and closure history now record reason/time while leaving financial recovery unresolved. Repeated closes preserve the first decision; resume followed by another close retains both decisions. Legacy `operator:` dismissals migrate to parked outstanding items, preserving the original reason/time rather than treating an old local dismissal as financial settlement.
- Refresh stays single flight with bounded coalescing. After every awaited server read it checks current durable identity/state. A concurrent local decision cannot be overwritten by an old response or reappear as an active guest. Local UI decisions publish immediately without waiting for a network round trip. Late verified payment can update an outstanding parked checkout without reopening the guest interaction.
- `SessionSetupSafety.Operation` supplies typed decisions and recovery destinations for Regular Booth, unrelated admission, staged settings, event changes, paid checkout, copy sending and payments-connection changes. Event lifecycle and setup continue using the same central policy. A parked financial obligation does not block unrelated setup. Backend payment exclusivity remains authoritative for each checkout.
- Closure saves the full original snapshot into the private detached store and retained-session store before parking. Current photos/previews are saved critically; callbacks are invalidated only after the handoff. The registry points to the mounted SwiftUI StateObject, so temporary View initialization cannot replace the actual guest controller.
- Print launch recovery now returns only the count durably converted from `inFlight` to `uncertain`. Failed writes retain `inFlight`, expose an actionable error and retry only the failed recovery transition. Live sends are never normalized by a background retry.
- Failed final-outcome/completion writes stay explicit and retry their saved transitions without any transport operation. A report is counted as sent only after its local acknowledgement persists. Same-key replay after an ACK write failure remains safe. Reports retain the existing single sync worker, per-pass attempt bounds and exponential backoff.
- Each newly uncertain copy has an inspection marker. The explicit check persists the exact set of copy identities, plus the current snapshot/checkout identity. Older historical entries decode without acquiring a new warning. A new failure cannot inherit an earlier review, even within the same session/timestamp. Server-only print evidence also requires a durable checkout receipt check.
- No-byte outcomes remain `notStarted`; where the durable journal proves no copy may have printed, the current conservative pre-send snapshot is refined to a pre-print stage. An uncertain outcome is never weakened to `notStarted`.
- Unreadable checkout/print files are copied aside while the original stays in place. Every relaunch continues to fail closed. Explicit checkout integrity acknowledgement cannot replace a file unless its original bytes were retained. Generic print writes cannot overwrite an unreadable journal. A corrupt guest checkpoint cannot be removed through normal cancellation.
- New checkpoints retain the original server binding; refresh and resume refuse a different binding. Legacy records still use their original identifiers/environment and keep connection changes gated until their obligations reconcile. Offline ledger state also protects pairing/unpairing.

## Operation boundaries

| Evidence | Regular / unrelated guest / event change | Save staged settings | Paid checkout / print | Change payments connection |
| --- | --- | --- | --- | --- |
| Active guest | Close first | Allowed with existing authorization/validation | Only that guest's authorized operation | Blocked |
| Active print transport | Wait | Allowed | No overlapping send | Blocked |
| Unparked interrupted guest/checkout | Close/resume first | Allowed | Preserve current ownership and recovery | Blocked |
| Safely parked payment/entitlement | Allowed | Allowed | New unrelated checkout only; original exclusivity and entitlement checks remain | Blocked until reconciled |
| Current physical receipt check / unfinished send | Blocked | Allowed | Blocked until safely reviewed/finished | Blocked |
| Background reports / financial report conflict | Allowed | Allowed | Existing per-copy and entitlement protections remain | Blocked |
| Corrupt/unavailable recovery or print storage | Protected gate with repair destination | Staged edits remain independent | Blocked | Blocked |
| Historical reviewed uncertainty | Allowed | Allowed | Original possibly printed copy stays duplicate protected | Allowed only when no server-bound obligations remain |

This table covers the recovery policy. Existing operator authorization, server event/version rules, admission-transition journals, configuration validation and printer readiness still apply.

## Persistence and maintenance

- Financial checkpoints: `PaymentState/checkout-checkpoints.json`. Optional new fields preserve old decoding. Parked records and their closure evidence are excluded from normal resolved-record pruning.
- Physical journal/reports: `PaymentState/print-outbox.json`. Existing batch/copy keys and financial reports are unchanged; optional inspection markers distinguish current review from history.
- Guest snapshot: `AppRecoveryStateV1/last-session.json` with an optional checkpoint UUID. The exact acknowledged identity is flushed to `operator-acknowledgement.txt`; preferences remain a legacy fallback.
- Retained assets: `AppRecoveryStateV1/RetainedSessions/<content hash>/last-session.json`. Repeated retention of identical data is idempotent. Existing UUID-named retained directories remain readable.
- Parked purchase snapshots: `DetachedCheckoutsV1/<hashed session>.json`. The guest pre-camera handoff keeps its strict original restriction. Operator closure uses a separate retention path that also preserves captured photos/previews.

Do not delete these files or reset an iPad to clear a warning. Inspect server orders under the original account/device when records disagree. Cash stays in its original accounting category. No automatic financial void/refund, entitlement replacement or uncertain-copy resend is implemented.

## Regression coverage

New persistence-backed tests live in `CloseContinueRecoveryTests`, `PaymentRecoveryConcurrencyTests`, `LiveEventPaymentRecoveryTests` and `EventLifecycleIntegrationTests`. Existing production suites continue to exercise the printer transports/spooler, payment authorization, event versioning, gallery archives and actual SwiftUI rendering.

| Requested scenarios | Evidence |
| --- | --- |
| 1–4: before checkout, never-started QR, conclusive unpaid, expiry without confirmation | EventFinalization navigation/cancellation; CheckoutCheckpoint classification; automatic-unpaid failure/retry and pending-state concurrency tests. |
| 5–8: late verification, unreachable server, abandoned paid guest, preserved entitlement | Parked-to-verified concurrency; held verification close/new guest; paid-source cancellation; existing verified original resume/claim tests. |
| 9: cash before/after printing | Cash closure category/reference tests; offline recovery classification; existing cash and durable print suites. |
| 10–13: before transport, no bytes, possible bytes, in-flight relaunch | PrintDurability/PrintReliability; no-byte versus uncertain duplicate protection; injected failure of launch normalization. |
| 14–16: durable acknowledgement, distinct newer failure, historical nonblocking state | Exact-copy inspection/relaunch; checkpoint UUID; original acknowledged cycle and new parked paid cycle. |
| 17–18: reports versus setup and server switching | Scoped-operation matrix; durable report/conflict tests and connection tests; unchanged backend exclusivity tests. |
| 19–22: failed resolution, refresh race, double tap, corrupt/unavailable storage | Injected disk writers, held reads, eight concurrent closes, durable terminal retry, repeated corrupt-store relaunch, protected original bytes. |
| 23–24: Regular/Event changes and start/end after parking | Full parked paid guest → inspection → durable handoff → relaunch → Regular guest → unrelated free event → event guest → end back to Regular, with original journal reopened from disk. |
| 25–27: duplicate prevention, assets, genuine blockers | Original copy cannot begin again; entitlement/session unchanged; retained photos/gallery/receipt/thermal previews; transport, physical check, integrity and storage gates. |
| 28: wording and destinations | Shared typed recovery destinations, actual OperatorDashboardV2 SwiftUI portrait/landscape/large-text rendering, and existing customer/operator rendering tests. |

## Verification and delivery

Validation completed: 782 production tests on iOS 27, 781 in the supporting iOS 26.5 full run, and 143 in the final focused iOS 26.5 run, all with zero failures/skips. The signed Release build, signature verification and all backend checks passed. The complete runs retain the pre-existing internal QoS warning. Exact source boundaries, artifacts, file inventory and results are recorded in [the delivery report](../BuildArtifacts/CloseContinueRecovery/README.md) and its `test-summaries.json`.

Bundle identifier, signing/project configuration, release settings, receipt rasterizer, camera service, payment backend and dependencies were preserved. No physical device was uninstalled, reset or updated. No physical print, live payment, event activation, production deployment or merge was performed.

Physical acceptance remains necessary: owner-supervised iPad camera/VoiceOver checks, actual paper inspection/restart and diagnostic-test behavior, offline/online payment recovery with separately authorized payment tests, and force-quit/relaunch on the physical booth. Simulator transport fixtures cannot prove paper output or live-provider acceptance.

Historical local records already pruned by older releases cannot be reconstructed by this migration; the server order list remains the financial source of truth. Partly printed purchases retain their journal and copy counts but are not automatically resumed or resent; use paper review and a separately authorized recovery/reprint process. Storage/integrity failures and non-isolatable active work intentionally retain narrow gates.
