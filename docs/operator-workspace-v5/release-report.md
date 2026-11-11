# Operator Workspace V5 — release report

Date: November 12, 2026 (Asia/Manila). Repository: `marcpocong/pocket-pixels-receipt-photobooth`, branch `main`. Latest main was fetched before implementation and again before delivery; the baseline remained `4f601eada932131f6118c930f4033e975fd9dfc7`. The release is identified by the commit containing this report.

## Delivered

The five primary destinations and nested operator surfaces now share a consolidated SwiftUI presentation system. `OperatorDesignSystem.swift` extends the original palette with spacing, typography, card, section, navigation, status and state components. Native forms, lists, navigation bars and sheets share the canvas, tint, row sizing and header treatment. Setup, artwork, printer diagnostics and sample studio custom containers use the shared card surface. The [inventory](screen-inventory.md) and [consistency matrix](consistency-matrix.md) include inline destinations and sheets as well as typed routes.

Home now reads current event → current follow-ups → separate system observations → exact event activity → relevant shortcuts. Every current summary issue has its own destination. Ordinary gallery queues are separate from manual attention, and parked financial follow-ups remain separate from current guest interruptions. Equipment, network path, payment-server observations, gallery verification and monitoring acceptance retain distinct meanings. Monitoring freshness updates its visible text without sending a new request. Queue read errors display unavailable counts rather than invented zeroes. Waiting Galleries uses transfer telemetry and public verification counts, and labels per-item stages as last recorded.

Primary navigation remains outside scrolling content. The header adapts to larger text; nested pages use one inline native Back bar. Receipt Studio uses its existing Receipt/Tools focus layout at accessibility sizes. Existing landscape tests remain intact, while production portrait settings are unchanged.

No printer transport, camera service, receipt renderer, payment authorization, event lifecycle, gallery scheduler, storage schema or guest flow was rewritten. No dependency, project-signing change, backend deployment, automatic reprint, payment action or new admission gate was added. The only health-model behavior change is read-only: normal gallery work is `In progress`, while queue storage faults and explicitly flagged items remain review items. Its precise classification assertion was updated and additional tests preserve the distinction.

## Executed validation

All counts below describe actual execution, with runner/report limitations separated from test assertions. The full run preceded the final read-only health/queue refinements; the final focused run built and exercised the final source.

| Execution | Actual outcome |
| --- | --- |
| Debug simulator builds after meaningful UI changes | Passed; final standalone Debug build also ended `BUILD SUCCEEDED` |
| Signed Release build for Carlo | `BUILD SUCCEEDED`; strict code-signature verification passed |
| Earlier portrait V5 unit/UI focus, iOS 26.5 | 6 passed, 0 failed; `TEST SUCCEEDED` |
| Complete unit target, iOS 26.5 | 907 XCTest cases passed; 2 artifact-producing cases failed during low disk space. Additionally, Swift Testing reported 98 tests in 17 suites passed. Overall command correctly ended `TEST FAILED`. |
| Final focused unit execution, iOS 26.5 | 13 passed, 0 failed, including both exact previously affected cases |
| Final focused UI execution, iOS 26.5 | 3 passed, 0 failed: normal PIN journey, five persistent tabs/nested Back, large text/search keyboard/session detail |
| Supplementary iOS 27 execution | 44 unit cases and 3 UI cases passed; result finalization stalled after suites completed |
| Hosted GitHub Actions | Not rerun or used as release evidence; the owner reported an existing billing limitation |

The complete XCTest target ran 909 cases. The affected cases were `HardwareQualificationTests.testHundredSimulatedSessionsHaveHundredDistinctIdentities` and `ReceiptFooterModeTests.testAllModesFormatsAndFinalThermalQRWithVisualArtifacts`. The first explicitly reported an out-of-space archive failure; the second failed while writing its visual artifacts during the same low-disk period. An intermediate screenshot write also explicitly reported ENOSPC. Generated Xcode caches were cleared and the secondary simulator was shut down. Both exact original regression tests passed unchanged in the final run: 100 distinct simulated sessions passed in 64.152 seconds, and the complete footer/format/thermal-QR test passed in 19.794 seconds. No renderer or assertion was relaxed to obtain those results.

The final 13 unit and 3 UI cases and both target suites reported passed. Xcode subsequently stalled in result finalization while logging `IDESchemeActionSDKRecord ... invalidDigitCount(94232)`; that idle finalizer was terminated after the suites completed. Consequently, this report does **not** claim a successful final overall XCResult status or a single clean green full-suite artifact. Counts are retained from the XCTest/Swift Testing execution logs in [validation-results.json](validation-results.json). The standalone final build completed successfully. Existing orientation deprecation, concurrency and simulator hosting diagnostics were observed rather than suppressed by changing product configuration.

Coverage includes typed-route round trips, section/draft restoration, all current follow-ups, normal queue vs manual review, unknown/fresh/stale monitoring evidence, portrait rendering, large text, keyboard avoidance, original archived receipts and explicit printer-unavailable explanations. The full run and supplementary focused run also executed acknowledgment → relaunch → next Regular Booth guest → unrelated event start/end and parked paid guest recovery cycles. Existing original-copy duplicate protection remains unchanged.

## Visual evidence

[Eighteen curated portrait captures](screenshots/README.md) cover all five roots, System, Help & Recovery, Waiting Galleries, settings forms, archived session detail, sample/receipt studios, long event names, simultaneous issues and accessibility text with the keyboard. Captures use synthetic data on the matching fourth-generation 11-inch iPad Pro simulator. They were reviewed for common margins, surfaces, hierarchy, navigation, readable wrapping and preserved receipt pixels. The screenshot manifest records their hashes. These are visual review baselines, not an assertion of exhaustive OS-independent pixel comparison or physical VoiceOver acceptance.

## Carlo installation and data retention

The validated Release package was installed **in place**, then launched successfully. A subsequent process listing confirmed the app running. Carlo was not uninstalled, reset or erased. The fresh pre-update read-only snapshot contained no current recovery checkpoint or checkout journal.

The bundle identifier remains `com.pocketpixels.PocketPixelsBooth`; team `PQ26682725` and portrait-only iPad orientation are preserved. Strict signature verification passed and the embedded profile explicitly covers Carlo. Its expiration is **November 18, 2026 at 7:28:56 PM Manila time** (11:28:56 UTC). The currently valid development profile supports this installation; it must be renewed before operation beyond that date and should not be treated as unattended future-event provisioning.

Before/after comparisons found all **19 protected paths** present. All **four existing protected files** (three Application Support files and one preferences file) were byte-for-byte unchanged immediately after installation. After launch, all original support files remained byte-for-byte unchanged and all original preference values were retained. Aggregate evidence is in [preservation-summary.json](preservation-summary.json); private file contents and customer data were not committed. Bundle/signature evidence and the installed package's binary hash are in [signing-summary.json](signing-summary.json). No Keychain reset, migration or signing-identity change was performed.

## Remaining physical acceptance

The VOZY G80 was unavailable. Bluetooth connection, actual paper output, feed/cutting and hardware recovery remain unverified. Simulator transport/qualification fixtures do not establish those facts. Real camera capture, physical VoiceOver use and payment-provider acceptance also require the appropriate real-device checks. Installation, launch and data retention are verified independently of those hardware checks. No physical receipt, LIVE payment or production event change was initiated for this release.
