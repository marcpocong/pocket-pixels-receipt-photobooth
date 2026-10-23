# Operator Experience V3

Implemented on `feature/operator-experience-v3`, based on `179822a`. Validation date: October 23, 2026 (Asia/Manila).

Merge and release checks: [PR #14](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/pull/14). The owner subsequently authorized merging to main and updating Carlo in place. Physical printing and LIVE payment/event activation remain separately restricted.

## Operator navigation

| Task | Navigation |
| --- | --- |
| Change everyday copies or formats | Home → Regular Booth Settings → adjust → Save in the navigation bar |
| Change everyday footer, gallery style, caption or logo | Home → Regular Booth Settings → Footer, logo & branding → Preview Receipt → Save |
| Change defaults inherited by events | Regular Booth Settings → Device Footer & Gallery Defaults |
| Prepare an event | Home → Quick Start Event → name → Payment & Prints → Receipt & Branding → Review & Start |
| Keep an event for later | Save for Later, Save Event Without Starting, or Save Design |
| Start a free event | Review the setup and preview → Start Event; no second review sheet |
| Start a paid setup / switch from a paid setup | Review & Start → explicit paid review; existing version/price and transition checks still apply |
| Pause, resume or end | Home current-event card; End Event now appears directly among its actions |
| Return to ordinary operation | End Event on This iPad returns to Regular Booth; Return to Regular Booth remains available for detached/completed setups |
| Reconnect or change printer | Home → Printer, or System → Printer Setup |
| Manually test printing | Printer Setup → Manual Test Print → preview → explicit Print (uses paper) |
| Change transport tuning / inspect diagnostics | Printer Setup → Advanced Printer Settings, or System → Advanced → Printer Transport & Diagnostics |
| Handle an interrupted print | System → Help & Recovery → check paper and restart → record check → reconnect → complete any required test |
| Find a customer's receipt or gallery | Home → Recent Sessions → select the session |
| Intentionally print an archived copy | Recent Sessions → receipt → Print Extra Copy → review and confirm |
| See older interrupted photos | Help & Recovery → Retained Interrupted Sessions |

## Completed changes

### Phase 1 — Regular Booth defaults (`1485efd`)

Regular Booth is accessible without creating or activating an event. Copies (1–10), default quantity, guest quantity choice, enabled formats, printed gallery code, digital gallery style, logo, caption and receipt preview are available in its editor. A navigation-bar Save action keeps the common edit path short. Home shortcuts appear above status cards, including on narrow layouts.

Receipt configuration lives alongside the existing Regular Booth defaults, independently of saved events and the applied event profile. Older settings without a receipt profile continue to decode. Standard branding and the existing receipt renderer remain the defaults. New session startup freezes copy/format policy, profile, print footer and digital style; edits made afterwards affect the following guest. Guest quantity choice now governs both increase and decrease controls.

Readable invalid copy/format values stay visible for repair. An unreadable default is reported and cannot silently admit guests with factory settings. Invalid originals are preserved under unique preference backup keys before an explicit replacement is saved. Unknown device footer/gallery preference values also get a visible repair notice and are preserved on replacement. Supported format names are shown to operators rather than persisted identifiers.

Ordinary default editing/saving has no printer-readiness, historical-recovery or active-guest gate. Operator authorization and configuration validity still apply.

### Phase 2 — Printer experience (`592f8de`)

The everyday printer screen shows the selected printer/status, reconnect, change printer, manual test preview and an Advanced link. Transfer policy, photo tone, low-level identifiers and transport diagnostics remain available under Advanced. No new dependencies or print transport implementation were added.

A shared printer state distinguishes disconnected, connected, ready, busy, awaiting a post-recovery paper test and an unresolved prior print. Busy state is not reported as a disconnected printer. Home, equipment, event review, checkout and monitoring use the selected transport. Wi-Fi readiness uses a bounded TCP connection probe through the same network service used for receipt printing; the probe sends no receipt payload. Its observation is invalidated on a foreground cycle, endpoint change or failed Wi-Fi job. Paid checkout rechecks the selected transport. Monitoring refreshes Wi-Fi observations while idle and keeps the deployed monitoring protocol; it does not require an unused Bluetooth radio or interrupt a guest to probe the printer.

Connection and transport completion remain observations, not proof of paper output. A required Bluetooth recovery text test still needs explicit operator paper confirmation. Auto transport fallback remains restricted to failure before any bytes may have started. No automatic reprint or retry was added.

### Phase 3 — Event workflow (`b115ae9`)

Quick Start Event exposes the existing staged event workflow. Receipt & Branding is an explicitly named stage with logo/footer/gallery style/caption controls, deeper typography options and previews. Save for Later and Save Event Without Starting use save-only validation; a missing logo can be saved as unfinished work without activating it. Recovery and guest-session barriers no longer prevent saving a reusable valid configuration.

Activation retains active-session, current unresolved print/payment, event-history, interrupted-transition and server-verification barriers. Historical print outcomes and self-contained reports do not block unrelated operation changes. Paid saves retain version/conflict/binding/policy validation. Paid activation and a switch away from paid operation retain the separate paid review. Free activation uses the already visible summary and preview. Free resume avoids a redundant confirmation; paid resume retains scope review. End Event remains one explicit review with paid scope controls and retained-history explanations.

### Phase 4 — Recovery and usability (`9f67573`)

Help & Recovery separates current actions, interrupted guest context and history. Instructions ask the operator to inspect the receipt, clear a jam/restart and reconnect. Text explicitly distinguishes an uncertain print from a failure before anything was sent. The physical result remains uncertain after acknowledgment.

Before closing/acknowledging an interrupted session, the exact checkpoint and photos are durably retained in `AppRecoveryStateV1/RetainedSessions/<UUID>/last-session.json`. Retention is additive: it does not clear the original checkpoint or alter an archive, journal, gallery, payment or entitlement. A failed retention write leaves the recovery obligation in place. The acknowledgment is scoped to the exact session/checkpoint and persists across relaunch; another checkpoint cannot inherit it. Retained sessions can be viewed read-only from recovery history. An unfinished session can be kept for reference without falsely recording a print or resolving its payment.

Recent Sessions is a Home shortcut, filters have larger touch targets, and reprint labels describe an extra copy. Intentional reprints still create a new confirmed batch from the frozen archived raster. The camera check screen now updates the shared camera status only from a real camera initialization result. App foreground invalidation remains in place.

### Phase 5 — Validation and completion

Expanded the existing actual-SwiftUI rendering test to cover Regular Booth settings, printer setup, device branding, Recent Sessions and retained sessions in both orientations, plus large-text settings/printer screens. Reviewed rendered screens and corrected shortcut placement, Save access, raw format names, duplicate printer titles and stale printer wording. Existing guest artwork, receipt composition and raster algorithms were preserved.

Validation results and screen evidence are recorded below. Paid checkout recovery also restores the original saved receipt profile, including an original standard profile, instead of inheriting the currently applied event. The existing paid-resume test now asserts the original profile is retained.

### Carlo follow-up — historical print warning

The owner's screenshot exposed an additional global gate: `SessionSetupSafety` counted every retained uncertain outcome as pending recovery, including old local receipts with nothing to report. A read-only inspection of Carlo found 300 journal entries, one uncertain local receipt, no outstanding server reports or in-flight copies, and 58 resolved checkout checkpoints. No customer photos or credentials were needed for this diagnosis.

The operation gate now checks current receipt/session recovery, unfinished checkouts, unfinished sends and storage integrity. Historical unknown outcomes, queued reports and server-report conflicts retain their original identities and reporting behavior but do not freeze a different event or Regular Booth. They cannot authorize a payment, change an entitlement or resend a receipt. Payments-server connection changes still require outstanding reports/conflicts to be handled so they cannot be stranded on a different server. Owner monitoring no longer raises a fresh uncertain-print incident solely from history. Payment Maintenance explicitly labels unknown outcomes as history and explains that sending reports never prints.

Five new regression tests cover the historical local receipt after relaunch, current physical/session recovery, pending/conflicted reports, unavailable/corrupt storage and unresolved payment checkpoints. The final focused follow-up passed **92 tests**, zero failures/skips/runtime warnings. An initial new assertion compared a pre-serialization timestamp against the intentionally normalized persisted date; it was corrected to compare persisted state before and after status evaluation. Debug simulator and signed Release device builds passed. The complete production suite is also required on the PR's current head before merge; its final status is recorded in PR #14.

The corrected signed Release app was installed in place on Carlo and launched through Apple's device tools. No uninstall was performed. All 4,168 pre-existing protected Application Support/Preferences paths remained present, and all 3,593 protected files retained their sizes immediately after installation, before launch. This inventory verifies retention, not a full content audit. Physical screen interaction, camera/printer behavior, paper output and venue acceptance are not claimed. No physical print, LIVE event or payment was initiated.

The existing development provisioning profile expires **October 27, 2026 at 1:17:33 AM Manila** (October 26 at 17:17:33 UTC). An ordinary automatic provisioning refresh retained the same expiry. Bundle ID, signing configuration and team were preserved; no profiles or certificates were revoked/deleted. A renewed signed build will be needed before expiry for continued operation.

## Safety and data boundaries

- Bundle identifier, signing configuration and Xcode project configuration are unchanged.
- No dependencies were added. Printer/camera/rendering/cloud services remain separate.
- Existing customer archives, photos, event designs, event history, gallery URLs/tokens, payment infrastructure and print journals are retained.
- An acknowledged uncertain print is never converted to a confirmed success/failure and never automatically resent.
- Recovery acknowledgment does not authorize a payment or settle an outbox obligation. Financial review and ambiguous server transitions continue to block activation where required.
- The initial five-phase implementation did not merge or install. The owner subsequently authorized main integration and an in-place Carlo update; see the follow-up above and PR #14. No production backend deployment, uninstall, device-data deletion, physical print or LIVE event/payment was performed. Full physical acceptance remains pending.
- The pre-existing untracked `.claude/` directory was left untouched.

## Validation results

All test runs below completed with **zero failures and zero skipped tests**. The complete production-gate test target runs in Debug/test configuration; Release simulator compilation was checked separately.

| Validation | Result |
| --- | --- |
| Phase 1: Regular Booth + session isolation/recovery | 25 passed |
| Phase 2: print reliability/durability, payment handoff, operator wording | 51 passed |
| Phase 3: setup/payment matrix, lifecycle, Regular Booth | 75 passed |
| Phase 4: recovery, retention/relaunch, print integrity, session isolation | 65 passed |
| Initial expanded screen/navigation/setup review | 40 passed |
| Complete iOS 26.5 production-gate suite | **751 passed** |
| Complete iOS 27.0 production-gate suite | **752 passed** |
| Final iOS 26.5 focused follow-up (defaults, printer, paid recovery, recovery operations, screens) | **70 passed**, no runtime warnings |
| Debug simulator builds after implementation and final accessibility wording | Passed |
| Release simulator build, arm64 + x86_64 | Passed |
| Payments Worker | 223 passed; syntax check passed |
| Monitoring Worker | 9 passed |
| Gallery proxy | 39 passed |
| Apps Script | Pure checks, schema/storage/retry/readiness checks and synthetic browser fixture generation passed |

The final focused follow-up covers changes made during the full-run review: preserved unknown device defaults, current busy-state wording, original paid recovery profile and refreshed repair notices. A final accessibility-hint wording adjustment was compiled afterwards. Counts from overlapping focused runs should not be added together as unique tests.

Both full runs recorded one internal QoS priority-inversion warning in `CustomerOperatorUIReleaseTests.testSearchGroupingFiltersAndCorruptArchivesInTheCollection()`. It is retained as an outstanding performance diagnostic; no functional test failed. Existing Swift 6 migration/compiler warnings also remain. The focused follow-up recorded no runtime warnings.

The first Phase 3 attempt failed to launch the simulator test runner before tests ran; the same build passed after a simulator restart. After the first complete suite had passed all tests, Xcode stalled in its `simctl diagnose` capture. Only that diagnostic subprocess was stopped; Xcode finalized the bundle with `TEST SUCCEEDED`. The second complete suite's diagnostic capture finished itself. Neither complete suite used test exclusions, expected failures or skipped tests.

Machine-readable summaries are committed at [`BuildArtifacts/OperatorExperienceV3/test-summaries.json`](../BuildArtifacts/OperatorExperienceV3/test-summaries.json). Thirteen reviewed screenshots and their scope are in [the screen-review folder](../BuildArtifacts/OperatorExperienceV3/README.md). The complete local result bundles are `/tmp/pp-v3-production-ios26.xcresult`, `/tmp/pp-v3-production-ios27.xcresult` and `/tmp/pp-v3-final-focused-ios26.xcresult`; detailed phase results are retained in the committed summaries.

The app's actual SwiftUI screens were rendered and visually inspected in portrait, landscape and accessibility text size 3. Existing gallery snapshot files regenerated by the tests were restored rather than included as unrelated changes.

## Remaining acceptance work

Physical camera availability, Bluetooth/Wi-Fi behavior with the actual printer, thermal quality/paper feed/cutting, physical receipt outcomes, VoiceOver operation and real venue connectivity need owner-supervised iPad acceptance. Simulator rendering and transport simulations cannot certify those outcomes. See [the physical acceptance checklist](operator-experience-v3-ipad-checklist.md). Existing Swift 6 migration/compiler warnings outside this revision remain; this change preserves the project's current Swift language configuration.
