# Operator Workspace V4.1 evidence

All media and records here are synthetic. The QR codes point to test domains with fixture tokens. No customer media, private customer gallery URL, payment token or credential was used.

See the [implementation and Carlo acceptance report](../../docs/operator-workspace-v4-1.md), [PR #18 delivery record](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/pull/18) and [final-head checks](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/pull/18/checks).

Baseline main was `211c7e44b977e75f05410f0b845ba35809c8d5f5`, with [passing Production Gate](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/40115475524). Final implementation source is `16b19feb0577e90c9b37ea352c5ee441cc78b5bb`; evidence-only commits can follow it.

## Validation records

- `local-full-core.json`: complete initial implementation suite, 820 passed / 0 failed, plus the optional interactive harness skipped. That harness was subsequently replaced with native UI tests and removed.
- `local-focused.json`: 66 focused cases passed / 0 failed / 0 skipped after review-presentation and historical-reporting fixes.
- Supplemental acceptance: 12 gallery cases and five native UI cases passed, including actual deletion of two synthetic local archives, selected-count assertions, pinch/pan/double-tap, historical recheck success, offline failure and denied-Photos feedback. Final CI retains the native screenshots in its xcresult artifact.
- `backend-validation.txt`: payments 223, monitoring 9 and gallery proxy 39 passed, plus Apps Script schema/manifest/readiness checks.
- `local-toolchain.txt`: Xcode 27.1. The generic-device Release build also passed with signing disabled only for that compile command; project bundle/signing settings are unchanged.
- `local-full-release-candidate.json` records 828 passed / 0 failed / 0 skipped; `local-final-safety.json` records the final 37 safety/identity/viewer cases passed / 0 failed / 0 skipped. Exact final PR head and post-merge main gate are linked in the PR's delivery record. Only the final-head gate authorizes merge.

## Performance

`performance-baseline.json` / `performance-final.json` and `scroll-baseline.json` / `scroll-final.json` are sequential fresh-process runs on the same M4 iPad simulator and iOS 27.0 runtime. Metadata at 1,000 records was 71.81 → 112.89 ms; the added 41 ms is explicit. Scrolling had zero >34 ms callback gaps in either four-second sample, with approximately 16.74 ms p95 intervals. The decoded cache stayed bounded at 12 MiB. These are simulator samples, not physical FPS, an Instruments trace or controlled cold-disk measurements. Full results and storage implications are in the report.

## Screenshot inspection

The `screenshots` directory has 22 inspected PNGs. `ui-` files are actual native XCUI system-menu/dialog/gesture captures. Other files are real hosted SwiftUI views at portrait, landscape or accessibility sizes. The top segmented fixture chooser appears only in debug simulator tests, not the production workspace.

| Evidence | Screenshots |
| --- | --- |
| Checkout groups, parked history, Manage and review | `ui-checkout-*.png` |
| Events Manage, confirmation and protected-use reason | `ui-event-*.png` |
| Sessions Manage, bulk selection, selected review, actual synthetic cleanup results | `ui-session-*.png`, `ui-bulk-selection.png`, `ui-synthetic-session-deletion-results.png` |
| Ready and Not Yet Verified, original versus thumbnail-only media | `original-photos-and-gallery.png`, `thumbnail-only-and-unverified-gallery.png` |
| Verification success and offline failure/results | `ui-gallery-*.png` |
| Fit without preset toolbar, double-tap zoom | `ui-receipt-*.png` |
| Explicit Photos actions and denied-permission feedback | `ui-individual-photo-export-actions.png`, `ui-photos-permission-failure.png` |
| Active versus parked Health | `ui-health-active-and-parked.png` |
| Portrait, landscape and accessibility-size session browsing | `sessions-*.png` |

Inspection caught a checkout presenter attached to a Section and initial empty-selection sheet captures. Both were fixed before these native acceptance captures. Final tests check the actual selected record count and cleanup results, rather than accepting an empty review merely because its title appeared. Destructive controls are separate from export and reprint, and routine feedback is inline.

Remaining Carlo checks are physical camera dimensions/orientation, system Photos transactions/permissions under actual storage pressure, human touch/VoiceOver, and physical printer/network qualification. No installation or destructive customer-record test on Carlo was performed.
