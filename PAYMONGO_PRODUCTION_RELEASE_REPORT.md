# PayMongo Production Release Report

Date: 2026-10-13 (Asia/Manila)

**CONTROLLED LIVE PILOT VERIFIED — FULL ROLLOUT PENDING**

## Operator workspace

The owner reproduced returning from Safari to the general operator page with the unsaved ₱2 value reset to ₱1. Process identity was unchanged: this was view-state loss, with no observed crash. Authentication previously removed the controls subtree on locking/backgrounding; recreating the editor then loaded server values over local state.

The authenticated controls now mount once and remain behind a concealed, disabled, accessibility-hidden lock overlay. A UIKit window cover protects inactive/app-switcher snapshots, including sheets. Backgrounding revokes the operator permit; Face ID cancellation keeps controls concealed. Face ID and the explicit native iPad-passcode option remain available.

A stable workspace retains typed navigation. Versioned non-sensitive forms and navigation are written atomically to a protected on-device setup file. Resume Operator Setup requires authentication after relaunch. No credential, authentication state, photo or customer record is persisted there. Corrupt original snapshots are preserved; storage failures display an error. Returning to the booth offers an explicit keep/discard choice for unfinished drafts.

Restored server drafts retain their original version and exact environment/endpoint binding. Refresh preserves edits; a newer server version blocks saving/publishing until explicit review or confirmed discard. Recovery never submits or activates a draft.

Changed files: `OperatorWorkspace.swift`, `OperatorAuthentication.swift`, `ContentView.swift`, `OperatorDashboardView.swift`, `ServerEventEditorView.swift`, `PaymentsOperatorView.swift`, `PaymentsAPIClient.swift`, `CommercialEventSetupView.swift`, `EventProfile.swift`, and `OperatorWorkspaceTests.swift`.

## Validation and preservation

- Focused simulator suite: **45 tests / 50 executions**, zero failures/skips. Workspace persistence, retained native SwiftUI hierarchy, authorization denial, API behavior, checkout recovery, camera handoff, print outbox and pricing covered.
- Physical Carlo suite: **8/8 passed**, including retained view hierarchy and setup recovery tests.
- Owner reported the requested Safari/background, cancelled Face ID, passcode reauthentication and force-termination/resume checks now work. Duration and individual interactions were owner-observed, not independently instrumented.
- A metadata-only update advanced the existing server event from version 2 to 3 for a real version-conflict check. The owner reported a conflict and its resolution through Discard Local Edits; an independent device-file copy confirmed zero remaining server drafts. Price and policy revision remained unchanged; no order was created for this check.
- Final Release build and signature verification passed. The corrected app was installed and launched in place on Carlo, iPad Pro 11-inch (4th generation), iPadOS 26.6.1. Bundle `com.pocketpixels.PocketPixelsBooth`, signing team `PQ26682725` and Release 1.0 (1) unchanged.
- All **288 pre-existing customer archive files** matched their original hashes after installation. Private backups remain outside Git. Camera, receipt renderer, printer transport and gallery implementation were not changed. Existing artwork, pairing and printer settings preserved.
- Backend syntax checks and **7 focused runtime tests** passed for LIVE gate, webhook verification/idempotency, entitlement and reconciliation behavior. The prior 196-test baseline remains recorded in the previous release evidence; no new full campaign or TEST payment was run.
- No new dependency, clone, worktree, alternate project or migration. Existing owner stash preserved. TEST infrastructure was not modified.

## Controlled LIVE pilot

The owner explicitly authorized exactly one real **₱1.00 QR Ph payment / one physical receipt**, using the existing event. Restricted external withdrawals and the absence of 100-session hardware qualification are not engineering blockers for this private supervised pilot. Merchant eligibility does not establish tax or invoicing compliance.

- Worker: `pocket-pixels-payments-live`, environment `live`.
- Endpoint: `https://pocket-pixels-payments-live.madetokeepstudios.workers.dev`.
- D1: existing isolated LIVE database `3417d35d-3d47-457a-bd45-0d6371fadc8f`.
- LIVE secret names/presence verified without retrieving their values. Enabled LIVE webhook was inspected in PayMongo for `payment.paid`, `payment.failed`, `qrph.expired` at the existing LIVE endpoint.
- Reconciliation schedule: every five minutes. Operational gate enabled with a runtime CLI override, Worker version `a032df55-fd37-442b-ab9e-9e715e4f7b03`; checked-in configuration remains false. New acceptance is stopped by the event lifecycle while verification remains operational.
- Pilot: **Made to Keep Studios — Supervised LIVE Pilot**, event `3e056cab-264f-446f-875d-6c8d13668b0e`; existing revision 1, `1718beb4-2cc4-45ac-a86c-a94ba5bb2dd7`; PAY_PER_PRINT, 100 centavos, default/max one copy, QR Ph only, cash/offline cash disabled, existing six formats. Venue remains empty.
- Carlo remains paired to LIVE with separate booth/operator credentials and server-managed charging. Temporary release administration used an operator-only principal, now independently verified revoked; its temporary token transfer file was removed. Carlo's booth/operator credentials remain unchanged and unrevoked.
- Exactly **one LIVE ₱1 order and QR attempt** created on Carlo. PayMongo dashboard independently confirms QR Ph, API origin, Live mode, PAID, gross ₱1.00, actual fee ₱0.02, withholding ₱0.00 and net ₱0.98. Settlement is Scheduled; no completed settlement or withdrawal is claimed.
- Owner paid once but the QR page initially did not advance. Tail captured LIVE webhook HTTP **401**, with no verified webhook row; the initial signing-secret configuration failed verification. No signature protection was bypassed.
- Scheduled reconciliation at `2026-10-12T20:50:39Z` independently retrieved provider evidence, resolved one attempt with no failure, and reached **PAID_VERIFIED**. Exactly one VERIFIED_QRPH entitlement was issued and claimed (**IN_SESSION**). The camera became available for the same session. Final D1 reread confirms one **COMPLETE order**, one **COMPLETE batch**, one **DELIVERED copy**, and one **CONSUMED entitlement**. The owner confirmed one complete readable physical VOZY G80 receipt and return to Welcome. Paper confirmation is separate from the transport’s DELIVERED outcome; no outcome was manually rewritten.
- Event **PAUSED**, version 5, preserving the same active ₱1 revision. No second payment/order created. LIVE gate/webhook/Cron remain enabled to reconcile the accepted payment.
- Independent post-pilot device copy: both checkout journals completed; all five historical/current outbox entries delivered, including this pilot’s copy and completion reports. All original 288 archives still match; the pilot added six archive files (294 total).
- Owner securely replaced the LIVE webhook secret in Wrangler. Current Worker version **`043c9012-0b3e-4b0d-a8ad-0e0c71172fd6`**; health still confirms `liveEnabled: true`. The existing payment event subsequently delivered successfully in PayMongo. D1 records one signed LIVE `payment.paid` event with **ALREADY_PAID**: reconciliation had already verified it, so redelivery issued no duplicate entitlement. No second payment was attempted.
- Final reconciliation run at `2026-10-12T20:55:39Z` finished with zero pending attempts inspected, zero conflicts and no failure. All recorded pilot states are final; no outstanding payment/print recovery remains. Settlement remains scheduled, not completed.

The operational gate is enabled without committing `LIVE_PAYMENTS_ENABLED=true`. Further acceptance is paused through the event lifecycle; webhook/provider reconciliation for the accepted payment remains available.

## Source and rollout

- Starting local/fetched remote main: `0ab3bed45253b90176a575b02ac21f4b5ecf7423`.
- Reviewed implementation: `93c000140167818d925e97ab05496a282b0a77b6` — committed and pushed normally to the existing main branch. The final report commit is identified in Git history and the handoff; this file cannot contain its own SHA.
- No secrets, customer images, payment records, setup snapshots or local backups staged. Repository visibility unchanged.
- Full unattended rollout is not verified. Historical 100-session simulation is not physical qualification; no new endurance result is claimed. Normal event pricing and any broader rollout remain owner decisions.

Final acceptance state: **existing pilot PAUSED; LIVE verification/webhook/Cron operational; no additional payment authorized.** The operator usability fix and one supervised payment-to-paper acceptance are complete. No remaining engineering blocker for this completed pilot; broader commercial rollout and scheduled settlement are separate.

## Second LIVE ₱1 Verification

2026-10-13, Asia/Manila. **Fresh webhook-first authorization verified.** This run used the owner's separate authorization for exactly one additional ₱1 payment and one receipt. New order reference: `4058e955…` (redacted).

- Source at execution: `20530e54c8bb011bd590e4caf00d5f6f9a03b0bb`, independently fetched and matched remote main. App/backend source unchanged; no build, redeployment, secret rotation, infrastructure change or broad test campaign was necessary. The report-only final commit is identified in the handoff/Git history.
- LIVE Worker unchanged: `043c9012-0b3e-4b0d-a8ad-0e0c71172fd6`; health confirms LIVE enabled. Existing webhook and five-minute Cron remain operational; checked-in gate remains false. TEST untouched.
- Same event/revision and ₱1/default-max-one/QR-only policy checked remotely. Owner authenticated on Carlo and resumed through the existing operator API: PAUSED version 5 → ACTIVE version 6 → **PAUSED version 7** after completion. Both lifecycle calls returned HTTP 200. Credentials unchanged; no temporary principal created.

All times below are **2026-10-13, Asia/Manila (UTC+8)**. Provider timestamps have one-second precision; Worker/D1 timestamps have milliseconds.

| Evidence | Time |
|---|---|
| New order persisted, one copy / 100 centavos | 05:08:06.159 |
| QR API request / successful HTTP 201 response | 05:08:06.488 / approximately 05:08:07.898 |
| Provider payment confirmed (`paid_at`) | 05:08:22 |
| New signed `payment.paid` webhook received | 05:08:23.662 |
| Provider independently reread; PAID_VERIFIED and one entitlement persisted | 05:08:24.052 |
| Webhook finished, HTTP 200 | approximately 05:08:24.236 |
| Carlo claim request / successful HTTP 200 response | 05:08:26.564 / approximately 05:08:26.920 |
| Order COMPLETE / entitlement CONSUMED | 05:09:00.046 |
| Pause request, HTTP 200 | 05:10:07.423 |

The webhook recorded **PAID_VERIFIED**, not ALREADY_PAID; PayMongo shows **Success, zero retries**. The new attempt's reconciliation count is **zero**. Cron at 05:05:39 inspected zero attempts, and the next run at 05:10:39 also inspected zero: the webhook authorized first, with no reconciliation fallback or manual webhook retry.

Payment-to-verification was about **2.1 seconds**; payment-to-successful camera entitlement claim was about **4.9 seconds**. The owner reached photo selection promptly and completed the session. Exact QR rendering and physical camera-open instants were not separately instrumented; QR API completion and entitlement-claim completion are timestamped proxies, not claims of exact screen-render timing.

Exactly one new LIVE order/attempt, one VERIFIED_QRPH entitlement, one COMPLETE print batch and one DELIVERED copy. The entitlement is CONSUMED and the order COMPLETE. The owner confirmed **one good physical receipt**. The owner initially described remaining on the QR screen after printing; this was the gallery thank-you screen rather than a pending payment. That screen intentionally offers Start Another Session to reset to Welcome without creating a checkout. The owner subsequently confirmed Carlo was already back at Home/Welcome. No payment or navigation defect was observed, and no customer-screen change was made.

PayMongo confirms Live mode, PAID, gross **₱1.00**, actual fee **₱0.02**, withholding **₱0.00**, net **₱0.98**. Settlement is scheduled/forecast for October 15; completed settlement or withdrawal is not claimed.

All six sets of previous payment/print/webhook records compared unchanged. All **294 pre-run archive files** retain identical hashes; the second session added six files (**300 total**). All three checkout journals completed and all seven historical/current print-outbox reports delivered. No duplicate payment, entitlement or print; no unresolved financial/print record. Final acceptance state: **pilot PAUSED; LIVE webhook and reconciliation operational**.

Second verification final status: **webhook-first LIVE payment-to-paper verified; Carlo at Home/Welcome; pilot PAUSED; zero outstanding payment/print recovery.** Across the two separately authorized runs there are exactly two COMPLETE orders, two CONSUMED entitlements, two COMPLETE batches and two DELIVERED outcomes; this run added exactly one of each.
