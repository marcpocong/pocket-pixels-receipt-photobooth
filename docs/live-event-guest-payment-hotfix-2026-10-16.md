# October 16 guest/payment hotfix — Stage 1 candidate

Baseline: clean `main` at `f30a6a4488826f984975d252f616d385282c720e`.

## Corrections

- An unknown order-creation response could enter reconciliation without polling because there was no order ID. Reconciliation now looks up the original checkout session, then polls its existing order. Empty/mismatched/unreachable responses retain uncertainty and the durable record; they never authorize another payment.
- Polls have their own cancellation/ownership identity, separate from checkout/camera work. Generation and cancellation checks protect UI updates after order creation, claims, event-policy loading and paid-session recovery. Cancellation retains a running original-order poll. Foreground recovery restarts a read of the original checkout. Network failures revoke stale replacement permission.
- Reconciliation and QR waiting offer Call Attendant / Get Help. Reconciliation also offers a read-only retry. The existing authenticated operator recovery can resume the matching waiting guest using the original entitlement, with server revalidation and existing print guards. Other guests and authorized camera sessions cannot be replaced. Admin dismissal tolerates the current guest consuming the resume notification first.
- Welcome's full-poster positioning bases and decorative notice layers are explicitly noninteractive. The wordmark hold is 2.5 seconds with 44-point movement tolerance. A discreet 48-point ellipsis button provides authenticated attendant access across guest states. Recognition gives tactile feedback. Duplicate Admin presentations are ignored.
- Welcome shows event-readiness progress. Privacy-safe OSLog records Start taps, rejection reasons, operator entry, current screen, transition state and Guided Access status. No credentials, photographs, gallery tokens or QR URLs are added to these logs.

These are source-level failure mechanisms and protections. The intermittent physical touch failure, Guided Access masks and device main-thread stalls have not been reproduced or ruled out on Carlo.

## Validation

- Focused simulator gate: 147 tests passed (103 XCTest plus 44 Swift Testing). Covers synthetic payment unknown/timeout/expiry/claim/recovery, cancellation, foreground, stale callbacks, 20 rapid Start actions, existing print accounting, authentication, gallery recovery, session isolation, layouts and timeout policy. Includes eleven new recovery regression cases.
- A subsequent 19-test focused integration run rebuilt the final Admin-dismissal correction and passed (12 XCTest plus 7 authentication tests).
- Payments Worker: all 207 tests passed. No backend source or production infrastructure changed.
- Signed device Release candidate uses the existing project, bundle `com.pocketpixels.PocketPixelsBooth`, team `PQ26682725`, version 1.0 (1). The signed Release build and strict `codesign --verify --deep --strict` verification passed.
- The gallery implementation, original tokens, queues, migrations, financial records and 60+15-second Thank You policy are unchanged. No dependencies or project/signing changes.

## Carlo and release boundary

Carlo is paired and available at the previously verified device identity. No installation, termination, launch, payment or physical print has been performed for this candidate. Read-only inventory and payment metadata copies are held outside Git in `/tmp/pocket-stage1-*`.

At the observation point, Carlo had 58 checkout checkpoints, one unresolved claimed entitlement (created 14:45, last updated 16:13 Asia/Manila), and no print-outbox entries for that checkout. Its 267 outbox entries were all recorded delivered; no App Recovery snapshot was present. This does not establish that the booth is idle or that the saved entitlement is resolved.

Before an in-place installation, the owner must confirm no active guest/payment/capture/print or recovery operation will be interrupted and account for the saved paid checkout. Preserve its record. Take fresh container/preferences safeguards, verify the candidate signature and device identity again, install without uninstalling, and compare retained data/preferences before launch. Operator observation must verify touch/hold/fallback authentication, Return to Booth, settings, camera/printer readiness and a safe thank-you cycle. No live payment or physical print is authorized for testing.

Stage 2 reporting, durable event runs, event resets, archive cleanup and workflow changes have not begun. The owner's sequencing requires Stage 1 to be independently committed and production stable first. Stage 2 installation and backend releases retain separate approval gates.

## In-place installation confirmed

After the owner confirmed Carlo was ready and idle, source `00c482725ef5a0531bf50287125e6b82b1a65c99` was installed in place on the verified Carlo device and launched successfully (PID 1270). Fresh private safeguards retain 3,534 Application Support files and 18 preference files (about 411 MiB). Before launch all 4,121 protected inventory entries remained present at unchanged sizes; all 18 preferences and four payment-state files matched byte-for-byte. After launch all preferences still matched, all 58 checkout identities and all 267 print-outbox identities remained present, and the one claimed entitlement remained recoverable. No uninstall, container erase, financial transaction or physical print occurred.

The owner then confirmed normal Welcome taps, wordmark hold, ellipsis authentication, Return to Booth, current settings and camera/printer readiness all passed and Carlo was behaving normally. This is owner-observed physical validation; no automated device touch test, repeated-interaction stress test, physical print or full thank-you cycle was performed. The source Production Gate backend job passed; the complete iOS suite was still running at this observation: https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/38878974354 . Stage 2 may now proceed in source only and requires separate installation approval.
