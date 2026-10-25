# Operator Workspace V4.1.1

## Baseline and delivery scope

Fetched `origin/main` before edits: `46b0a4a7c429692553beb6502e9246d585fdeaca` (V4.1 / PR #18). Local branch: `feature/operator-v4-1-1-ux-freedom`. The owner's untracked `.claude/` directory is outside this change.

All implementation and native acceptance stay local until the candidate, focused tests and screenshots are ready. The PR and post-merge Production Gates remain mandatory. Final GitHub URLs and merge/main SHAs belong in the PR description and handoff; no evidence-only commit is needed after a passing gate.

No dependencies, bundle/signing settings, backend environments, payment authorization, camera behavior, receipt composition or printer transport changed. No installation on Carlo, production cleanup, live payment, physical printing or backend deployment is part of this release.

## Problems and repairs

V4.1 laid out each session as an HStack containing an external checkbox, the card, and an external menu. Every control reduced the photo width; selection mode changed the card footprint. Multiple permanent tool rows and footer results crowded portrait. Baseline screenshots show four narrow photo columns with detached controls.

Sessions now defaults to the photo grid. An adaptive minimum of 235 points gives three balanced columns at 11-inch portrait width; accessibility sizes use 320 points and reduced widths naturally use fewer columns. Square display crops use the existing downsampled thumbnails; source media is unchanged. The card has rounded corners, time, two-line event identity, format and compact print/gallery status. Its top trailing 44-point menu is a sibling of the body button, within the card boundary. Selection replaces that menu with a visible indicator in the same position. The body toggles selection instead of navigating; selected borders and VoiceOver values expose state without covering the photo.

Search and Select/Done share a surface. Date, Filters, grid/list and More form one adaptive tools area. More groups Gallery Actions and Show Hidden. Selection adds a compact count / Select All Visible / Deselect header. Only a nonempty selection presents Hide and reviewed Delete in the safe-area bottom inset. Filtering intersects selection with visible IDs. List mode uses the same integrated controls and removes the redundant chevron.

The existing cleanup review, per-record dependency checks, original Photos exports, receipt Fit/zoom, gallery verification identity/proof, serial requests, cancellation and rate-limit handling remain. Success feedback uses a shared six-second dismissible banner; failures persist until dismissed or addressed. Reports and Events use the same surface. Events mutation failures appear immediately in a native alert, rather than below Local Event Runs. Printer setup explains why a working job blocks reconnect and transport changes.

### Saved designs, occurrences and commercial records

Date-only checks previously treated any later archive (including Regular Booth) without an event ID as usage of every older design/run. Both live-archive and media-removed evidence checks now use exact supported IDs. Unassigned activity stays unassigned. Genuine run journals, explicit operator attributions, exact media references and commercial dependencies still protect permanent deletion of an unused run.

`removeSavedDesign` removes reusable configuration while atomically appending an identity-only reference in the existing library file: original design ID/name, creation/removal times, and original per-binding commercial event IDs. It retains no image, QR, receipt design or guest-screen configuration. Reports resolve the original name from this reference; event runs and archives retain their original IDs. Removed identities remain reserved against stale saves and commercial-event adoption/relinking. The History/Manage view exposes retained references with archived history.

A normal unused design offers Delete Event; known used designs offer Remove Saved Design. One confirmation names the record and explains that history/media/financial records remain. Both call the same store policy. No unrelated archive scan, payment-server read or archive-first workflow is needed. Applied designs, active/paused occurrences of that design, pending event creation, unreadable operational run state, unauthorized access and failed durable writes remain protected. A failed write changes neither the in-memory library nor the durable design/reference pair.

Events offers Switch to Regular Booth / End Event on This iPad. An applied-design removal alert also names that action directly. It reuses the existing lifecycle journal and fresh guest/print/recovery checks; a blocked transition stays visible. Nothing silently ends a live event, clears recovery, alters a guest's frozen setup or deletes a server event. Archive/Restore remains a separate reversible visibility action; restoring a run produces a completed historical occurrence, never an active run.

## Restriction audit

| Area | Classification and outcome |
| --- | --- |
| Design deletion from later unassigned media | Overly broad identity inference removed, including deleted-session evidence. |
| Historically used reusable configuration | Workflow limitation repaired with atomic removal plus minimal identity history. |
| Unrelated guest blocking local design archive/restore/removal | Narrowed: unrelated configuration does not change guest settings. Applied/active identities remain protected. |
| Inactive applied design | Direct lifecycle transition to Regular Booth; no unrelated event setup needed. |
| Session/bulk cleanup | Essential per-record current ownership, unfinished sends, acknowledged recovery and retained gallery payload checks preserved. Partial results stay explicit. |
| Drafts and booth defaults | Existing staged saves/discard scopes retained. Removed identity rejects a late save; a fresh event uses a fresh ID. Saving defaults remains separate from applying guest settings. |
| Printer reconnect / transport | Working-job and recovery safeguards retained; working-job reason made visible. |
| Home / System recovery | Existing primary recovery actions and original receipt acknowledgement retained. Historical print evidence remains separate from current operational gates. |
| Reports / payment maintenance | Financial binding, pairing, credential, uncertain-payment and reconciliation safeguards retained. Management feedback moved to the shared visible surface. |

Broader payment-maintenance or transport changes belong in V4.2 and require separate state-machine validation. This release does not redesign them to reduce taps.

## Validation approach

Baseline simulator build and the existing 50/250/500/1,000 synthetic archive benchmark passed. Baseline native event management acceptance passed. Xcode 27.1 / iOS 27.0 delayed optional diagnostic collection after those passing cases; subsequent local runs disable verbose sysdiagnose collection only. Test results, assertions and screenshots remain enabled.

Native tests use an explicit DEBUG simulator fixture, isolated temporary storage and synthetic illustrations. The production ContentView, cameras, payment workers and physical printers are never constructed. Relaunch acceptance reopens the same explicit fixture ID without reseeding deleted records. Photos success/denial uses an injected writer; it proves UI feedback and byte-export flow, not a real Photos-library transaction.

The first native pass caught an alert-to-confirmation presentation defect; the management alert now names the transition directly and its result uses the persistent feedback surface. No push or PR was used to discover or debug that defect.

Focused test totals, final screenshot review and performance comparisons are recorded below after final acceptance. Existing full receipt-composition and backend suites are intentionally left to the mandatory PR gate rather than repeatedly run locally for this UI/configuration change.

## Practical limits

Simulator evidence cannot establish physical camera quality, Photos-library permissions on Carlo, thermal-paper output, VoiceOver audio/hardware gestures or real payment/gallery connectivity. Native accessibility labels/selected values, larger text, actual menu touches, portrait/landscape layout, synthetic storage failures and exact history retention are covered locally. Production hardware and customer records remain untouched.

## Local regression evidence

- Functional pass: 27 event lifecycle integration cases and 11 design/run archive cases passed. This includes explicit idle detachment, paid-design removal with unchanged original financial totals/sessions/server identity, and acknowledgement → relaunch → next Regular Booth guest → next event.
- Cleanup pass: all 13 existing management cases passed, including per-record bulk results, paid-media cleanup, unfinished physical sends, pending galleries and acknowledged-recovery relaunch behavior.
- Final focused pass (`FocusedC`): 58 unit cases and four native UI cases passed, zero failures/skips. Unit scope: event/run deletion (now 12 cases, including manual attribution after media removal), historical reporting, media byte retention/export, gallery verification, saved drafts and archive scaling. Native scope: actual archive/restore/historical removal, failed storage feedback, Photos denial/gallery/Health, and receipt gestures plus reviewed bulk deletion.
- Earlier native acceptance also passed actual successful unused deletion/relaunch, applied-design detachment/removal, active-guest protection, card selection/filter/hide/export, transient feedback, portrait/landscape and accessibility/empty-state interaction. The local archive-toggle test now touches the actual switch thumb and the cleanup test selects the visible sheet Done button; assertions and real mutations remain.
- Snapshot review caught captures made during native symbol/glass animation. Screenshot capture now settles for 0.6 seconds before recording evidence. Reduced-width accessibility review also tightened header sizing and made the fallback bulk bar fill its safe-area width.

The Mac entered lid/maintenance sleep during the earlier native run despite idle-sleep inhibition. Its long durations are excluded from performance acceptance. The awake focused rerun passed all repaired interactions; local failure investigation did not trigger remote CI.

## Performance observations

The same synthetic 50/250/500/1,000 archive harness ran on the same iPad Pro 11-inch (M4), iOS 27.0 simulator. These are warm filesystem observations, not controlled cold-start or physical-iPad measurements. Metadata parsing and the ImageIO/cache implementation are unchanged.

| Sessions | Baseline metadata ms | Candidate metadata ms | Candidate average filter ms |
| ---: | ---: | ---: | ---: |
| 50 | 18.17 | 12.23 | 0.157 |
| 250 | 71.61 | 29.94 | 0.789 |
| 500 | 87.81 | 56.69 | 1.535 |
| 1,000 | 177.70 | 111.53 | 3.126 |

These samples show no load/filter regression; the lower values should not be interpreted as a measured algorithmic speedup. At 1,000 sessions both retained 64 decoded entries / 12,582,912 bytes. Cards still decode at most 256-pixel thumbnails through the bounded cache, never ordinary full-resolution originals. Filtering and selection do not rescan disk or invalidate immutable image identities.

The four-second programmatic list-scroll sample had zero callback gaps over 34 ms, p95 16.74 ms. Exact scroll restoration passed through detail, rotation and workspace reconstruction. This is CADisplayLink sampling, not physical-device FPS or Instruments hitch analysis. Candidate process footprint after cache warmup was about 41.8 MB versus baseline 36.4 MB; the candidate host had already run other unit fixtures, unlike the isolated baseline process, so this is not an isolated UI memory comparison. The cache bound is asserted independently.

Raw synthetic measurements, baseline screenshots, final native screenshots and compact result summaries are in `BuildArtifacts/OperatorWorkspaceV4.1.1/`. Full `.xcresult` bundles remain local and in the ordinary GitHub gate artifacts.

## CI behavior

The only workflow change is concurrency: superseded PR candidates share a cancelable group; each main run has its own run-ID group and remains uncanceled. No jobs, suites, backend checks, UI tests, timeouts or protection policies were removed. Only a completed candidate will be pushed. The one required PR gate and automatic post-merge main gate are expected.

The iOS 26.5 compatibility pass completed all 11 native UI cases plus the reduced-width SwiftUI rendering case: 12 passed, zero failures/skips. Final review additionally keeps a retention failure independent of routine success, shows export progress, and presents individual-photo export feedback within the open photo sheet. These receive focused final-head coverage before push.

Final feedback/accessibility acceptance: five passed, zero failures/skips (retention warning surviving an unrelated export, reduced-width selection, visible export failure inside the photo sheet, portrait card/filter/export interaction, and landscape/accessibility/empty state). The final ownership regression also covers refusing to bind a removed design's original commercial event to Regular Booth. Signing and bundle ID settings were not edited; generic-device Release validation uses only a command-line signing override.

The final simulator build-for-testing, commercial-ownership regression (one passed) and unsigned generic-device Release build all passed. The final source diff is clean under `git diff --check`. Main was fetched again immediately before delivery and remained the original V4.1 baseline. Thirty-two synthetic native screenshots are included and reviewed. Local implementation, targeted tests and screenshot validation completed before the feature branch's first push.
