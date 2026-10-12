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
