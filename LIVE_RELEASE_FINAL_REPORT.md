# Made to Keep Studios — supervised LIVE release closeout

October 14, 2026 · Manila time

**PASS: supervised ₱1 cash-to-paper pilot, including app-restart recovery.**
**NEEDS OWNER ACTION: provisioning renewal and broader hardware qualification before unrestricted commercial operation.** Full CI for supervised-pilot source `3ab7d6d` subsequently passed both jobs. The draft-shortcut follow-up has separate focused validation and will have its own CI result.

## A. MacBook and Carlo

- **PASS:** Carlo remains a connected physical iPad Pro 11-inch (4th generation), iPadOS 26.6.1. Supervised-pilot app source was `3ab7d6d199966a0df5624e1acb567bec63c09032`; the subsequent draft-shortcut update is recorded in the readiness report.
- **PASS:** Release builds and strict code-signature checks. Bundle ID `com.pocketpixels.PocketPixelsBooth`, signing team and iPad-only configuration preserved; no dependencies added.
- **PASS:** fresh private backups before in-place updates; no uninstall/reset. Final restart succeeded. All 300 original archive files and 210 baseline artwork files retain their hashes. Saved settings/designs and pairing retained. The completed pilot adds its own archive without replacing earlier files.
- **PASS:** zero unresolved local checkouts after restart; all nine print-outbox entries delivered/reported; zero queued gallery files.
- **PASS:** operator inactivity timeout removed. Genuine unlock remains required; returning to the booth/backgrounding locks operator controls.
- **NEEDS OWNER ACTION:** installed provisioning expires **October 19, 2026, 4:10 PM Manila**.

## B. Browser and physical interaction

- **PASS:** existing Chrome computer-use integration was verified earlier; authenticated GitHub/PayMongo read-only evidence collected. Cloudflare inspection/deployment used existing CLI authentication.
- Physical iPad touch automation was unavailable through enabled surfaces. Supported device screenshots and diagnostics were used; owner performed unlock, cash confirmation, camera/print and pause/count interactions. No authentication was bypassed or fabricated.

## C. Cloudflare LIVE

- **PASS:** owner-approved deployment of Payments Worker `pocket-pixels-payments-live`; active version `ccdc2798-96e5-46e5-b34c-c113d8534818` at 100%. Previous version `043c9012-0b3e-4b0d-a8ad-0e0c71172fd6` retained as a reviewed predecessor.
- **PASS:** LIVE health enabled; expected LIVE D1, three existing secret bindings and five-minute Cron preserved. No migration, TEST/gallery deployment or credential change.
- **PASS:** baseline records in all six inspected historical financial tables unchanged. Private post-pilot LIVE export loaded into local SQLite; integrity and foreign-key checks pass. Backups/payment snapshots/secrets remain outside Git.
- **PASS:** inspected reconciliation runs have no failure/conflict. Historical PayMongo LIVE QR and enabled webhook evidence remain intact; no extra QR transaction/redelivery was initiated.
- Rollback is not authorized automatically. The predecessor lacks new staff cash confirmation/reporting; after this cash record, prefer a reviewed forward fix or explicitly assess compatibility.

## D. Cash, reporting and recovery

- **PASS:** owner confirms receiving the actual ₱1 and authenticating through the original attendant button. Exactly one new cash order/attempt/entitlement, one purchased copy; attempt is `OPERATOR_CONFIRMED`. The purchase is COMPLETE and its entitlement CONSUMED after fulfillment.
- **PASS:** restart interrupted capture before any print. A recovery race had falsely marked the local checkout “no payment taken” before the successful response arrived. The repair reopens only contradictory automatic resolutions, preserves explicit operator dismissals, and prevents an empty recovery response from declaring a known purchase unpaid.
- **PASS:** same original checkout resumed to camera and printed without a second payment/order/entitlement. Resume confirmation now returns directly to the booth and keeps drafts without an exit prompt.
- **PASS:** owner saved actual cash count ₱1; expected cash ₱1, variance ₱0, non-provisional. Zero unresolved server orders or outstanding entitlements.
- At owner request, the current online cash UI instead offers **I’ve paid the attendant**, without Face ID. It uses the existing booth-scoped declaration endpoint and records `SELF_REPORTED`, separate from staff-confirmed cash. Signed offline cash retains attendant authentication.
- **PASS (local):** customer-declaration endpoint/credential/provenance and authentication tests; cash UI visually centered in portrait/landscape. Initial focused checks passed 28 XCTest tests plus a render test; repair checks passed 11 XCTest and 24 Swift Testing tests (35 total). Navigation Release build/signature verification passed, and owner confirms recovery reaches the camera.
- **NOT TESTED in a new LIVE transaction:** the new customer-declaration button. This pilot was authenticated through the old attendant button before the UI update; it cannot prove the new flow physically. No additional transaction was created solely to repeat existing payment evidence.
- Latest full app CI: [Production Gate 38580783813](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/38580783813), subsequently passed both iOS and backend. New follow-up changes require their own result.

## E. Printer and paper

- **PASS:** one new one-copy Bluetooth print batch COMPLETE with one DELIVERED outcome; owner reports paper “looks okay.” Transport evidence and owner paper acceptance are recorded separately.
- Earlier supervised samples: three standard, one Co-Branded Solo and one compact-header Duo. Owner accepted the Duo top spacing; Co-Branded/generic artwork preview and paper were checked. No feed/cut setting changed.
- **NOT TESTED:** physical ambiguous-print recovery or 100-session endurance. The successful interrupted-camera recovery and six total sample/pilot jobs do not satisfy endurance qualification.

## F. Final operational state

- **PASS:** Supervised LIVE Pilot **PAUSED**, version 11, ₱1, Cash Only, one copy, offline cash disabled. No new public acceptance enabled.
- **PASS:** Regular Sessions **DRAFT**, version 2, unchanged **₱25/copy**, default 1/max 3, QR-only. No duplicate event or commercial activation.
- **PASS:** installed app, deployed Worker, genuine staff-confirmed cash, restart recovery, receipt output, cash reconciliation and retained customer data verified under supervision.
- Recommendation: retain attended operation while finishing follow-up CI and completing the separate hardware checklist. Provisioning covers the October 16 event and needs renewal before October 19. Normal commercial activation remains under owner control. Do not call this full production qualification.

For chronological evidence and checkpoint limitations, see [LIVE_RELEASE_READINESS_REPORT.md](LIVE_RELEASE_READINESS_REPORT.md). Current cash/recovery instructions are in [docs/payment-operations.md](docs/payment-operations.md).

## October 15 printer endurance follow-up

The earlier NOT TESTED status for physical printer endurance is superseded by [Carlo Mode B evidence](docs/hardware-qualification/2026-10-15/REPORT.md): 100 sessions passed and 125 receipts printed and operator-confirmed, with zero recorded violations. Original UNVERIFIED was caused by out-of-scope checks always blocking PASS; the updated app reports PASS specifically for printer endurance. Live-camera Mode C, ambiguous-print fault drills and multi-hour operation remain outstanding. The tested build did not record its commit SHA.
