# Operator Workspace V4 evidence

Actual SwiftUI views rendered by XCTest in an iPad simulator, with isolated synthetic data. These are not mockups or physical iPad/printer/payment tests.

Implementation, source boundaries, safety details and the physical acceptance checklist: [operator-workspace-v4.md](../../docs/operator-workspace-v4.md). Draft review: [PR #17](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/pull/17).

## Automated evidence

| Check | Evidence |
| --- | --- |
| Repaired baseline: 42 passed | [Summary](baseline-tests.json) · [Original Xcode 16.4 failure](ci-failure.txt) |
| Supporting full iOS 26.5 suite: 787 passed, no failures/skips/runtime warnings | [Summary](production-ios26.json) |
| Final app full iOS 27.0 suite: 788 passed, no failures/skips/runtime warnings | [Summary](production-final-ios27.json) |
| Native-scroll full iOS 26.5 suite: 788 passed, no failures/skips/runtime warnings | [Summary](production-scroll-fix-ios26.json) |
| Final recovery/lifecycle/Regular Booth/workspace scope: 58 passed | [Summary](recovery-scope-final-ios26.json) |
| Metadata entry/cache/benchmark: 6 passed | [Summary](sessions-entry-final-ios26.json) |
| Final-source Xcode 16.4 Production Gate: 788 passed + backend passed | [Completed result](ci-final-production-gate.json) · [GitHub run](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/40107876873) |
| Signed Release build and strict signature verification | [Record](release-verification.txt) |
| Backend: 223 payments, 9 monitoring, 39 gallery; syntax/Apps Script passed | [Results](backend-results.txt) |
| Existing compiler warnings; no new Release warning messages | [Deduplicated messages](compiler-warnings.txt) |
| App/test source SHA-256 manifest | [Manifest](source-manifest.json) |

The `.xcresult` bundles remain under `/tmp/pp-v4-*.xcresult`. GitHub retains independent Production Gate logs and result artifacts. Final-source CI passed on `83f97cb`; the report/evidence and independently verified assertion refinement follow without an app-source change.

## Performance

[Measured results and limitations](performance-results.md), [original loader](performance-baseline.json), [final simulator measurements](performance-final.json), [same-runtime optimized iOS 26.5 measurements](performance-ios26.json), [four-second callback pacing](scroll-final.json).

[Time Profiler summary](instruments-summary.json), [recording metadata](instruments-toc.xml), [potential-hang export](instruments-hangs.xml), [recording warning](instruments-recording.txt), [raw trace ZIP](sessions-time-profiler.trace.zip). Extract the ZIP and open the `.trace` bundle in Instruments. The profile includes test fixture and screenshot work; its screenshot/cleanup pauses are distinguished from app browsing. No physical-device FPS or baseline footprint improvement is claimed.

## Screenshot review

Portrait: 834 × 1194 points. Landscape: 1194 × 834. Accessibility: 700 × 1024 with Accessibility 3. The captures use actual UIWindow/UIHostingController content. Long scrollable screens intentionally continue below the viewport. Header utilities, navigation, safe-area layout, visible actions, readable statuses, grid density and detail hierarchy were inspected. Receipt identity and print recovery are also checked by regression tests; a PNG alone does not prove those semantics.

| Area | Portrait | Landscape / accessibility |
| --- | --- | --- |
| Home · Regular Booth | [Portrait](home-regular-portrait.png) | [Active event, landscape](home-event-landscape.png) |
| Home · active event | [Portrait](home-event-portrait.png) | [Accessibility](home-accessibility.png) |
| Booth defaults | [Portrait](booth-portrait.png) | [Landscape](booth-landscape.png) · [Accessibility](booth-accessibility.png) |
| Receipt & Footer | [Portrait](footer-portrait.png) | [Landscape](footer-landscape.png) |
| Sessions · list | [Portrait](sessions-list-portrait.png) | [Accessibility](sessions-accessibility.png) |
| Sessions · photo grid | [Portrait](sessions-grid-portrait.png) | [Selected session, landscape](sessions-split-landscape.png) |
| Session detail | [Original receipt](session-detail-portrait.png) | [Original photos, QR and explicit reprint](original-gallery-portrait.png) |
| Events | [Portrait](events-portrait.png) | [Setup, landscape](setup-1-landscape.png) |
| Event setup | [Details](setup-1-portrait.png) · [Payment & prints](setup-2-portrait.png) · [Receipt & branding](setup-3-portrait.png) · [Review](setup-4-portrait.png) | [Review, landscape](setup-4-landscape.png) · [Accessibility](setup-accessibility.png) |
| Reports | [Overview](reports-portrait.png) · [Printing](reports-printing-portrait.png) · [Galleries](reports-galleries-portrait.png) · [Sales](reports-sales-portrait.png) | [Landscape](reports-landscape.png) |
| System | [Portrait](system-portrait.png) | [Landscape](system-landscape.png) |
| Help & Recovery | [Portrait](help-recovery-portrait.png) | [Landscape](help-recovery-landscape.png) |
| Browser states | [Loading](sessions-loading.png) · [Empty](sessions-empty.png) · [Storage error](sessions-storage-error.png) | Error state keeps originals and offers Retry |

Inspection corrected the hidden Booth Save bar, three-column portrait quick actions, accessibility navigation word splitting, redundant root title and excessive summary facts. Stateful checks also caught the generated fallback-profile date and stale-parent footer risks. Final scope checks keep Regular Booth drafts separate from event Resume, while metadata refresh on entry retains filters/selection/cache.

The return-position regression has [before-fix failure evidence](scroll-restoration-before-fix.json), [passing native restoration](scroll-restoration-verified-ios27.json), [measured offsets](scroll-restoration.txt) and [recreated-view re-entry evidence](section-reentry-verified-ios26.json). The offset assertion was retained and passed with zero observed return displacement.

Physical acceptance remains required for Carlo touch scrolling, real keyboard and rotation, VoiceOver, camera, paper/printer recovery, force quit/relaunch and separately authorized payment reconciliation. The owner subsequently authorized an in-place Carlo update; [installation/retention evidence](carlo-installation.json) and the report record successful build/install/launch and the remaining physical acceptance limits.
