# Local validation — 30 October 2026

Initial clean main / fetched origin/main: c422b59cfa5a994da49871e43a7c73226fd745cd.
Baseline hosted Production Gate #166 was independently confirmed successful:
https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/40986589868
This is baseline evidence, not verification of V3. Final hosted status is reported after push in the release response; no CI VERIFIED claim is made by this pre-push record.

Xcode 27.1 (27A9275), existing iPad Pro 11-inch M4 simulator, iOS 27.0,
C50E23DD-050E-4E94-A232-BE106C121698. No new simulator/device, dependency, project setting,
signing/provisioning change, physical installation, production migration or live bot send.
Existing /tmp/mtk-v2-derived was reused to bound build storage. Automatic bulky simulator
diagnostics were disabled; tests, timeouts, assertions and normal attachments remained enabled.

## Results actually obtained

| Check | Actual result / evidence |
|---|---|
| Simulator builds after meaningful Swift changes | Passed; /tmp/mtk-v3-build*.log, latest /tmp/mtk-v3-build-candidate.log |
| Initial focused iOS/nearby regressions | 67 passed, 0 failed/skipped; results/targeted.json |
| Final focused iOS/nearby regressions | 68 passed, 0 failed/skipped; results/targeted-final.json |
| First complete production suite | 979 named tests passed (881 XCTest + 98 Swift Testing), 0 failed/skipped; results/production.json |
| Complete native UI suite | 28 passed, 0 failed/skipped; results/native-ui.json |
| Final complete production suite | 980 named tests passed (882 XCTest + 98 Swift Testing), 0 failed/skipped; results/production-final.json |
| Monitoring Worker | 57 real-local-D1 tests passed, 0 failed/skipped; /tmp/mtk-v3-monitor-verified.log |
| Payments Worker | 223 passed, 0 failed/skipped; /tmp/mtk-v3-payments.log |
| Gallery Worker | 39 passed, 0 failed/skipped; /tmp/mtk-v3-gallery.log |
| Apps Script schema/storage/readiness checks | Passed; /tmp/mtk-v3-appsscript.log |
| Wrangler dry-run package | Passed; /tmp/mtk-v3-worker-package-verified.log (40.99 KiB before gzip; no deployment) |
| Diff whitespace / scope / secrets / main integration | Passed whitespace and final source/configuration review; staged scope reviewed before direct-main commit |

Xcode summary device execution counts include parameterized test invocations; the top-level
979 count is named tests (not the 1,014 per-device executions). The final event-context test
adds one named test. Native UI ran before the last telemetry-only event/runtime-camera
refinement; production UI, guest transitions and local recovery behavior were not changed by
that refinement. The final full production rerun covers the final app binary.

The final production rerun is justified by a verified review finding: unreadable event/admission
storage previously could imply idle. V3 now reports unknown, while V2/V1 compatibility omits
that unsupported value. A passive camera runtime-error flag also now retains recovery_required
until successful existing initialization. These changes do not modify capture/recovery flow.

## Added coverage

Nine Swift tests added to BoothMonitoringTelemetryTests (12 total) cover selected transports,
connected/disconnected/connecting/diagnostic/busy/recovery states, explicit versus unknown
print evidence, reconnect with uncertainty, old Wi-Fi observation, V1/V2/V3 mapping and size,
passive camera readiness/permission/interruption/runtime recovery, legitimate guest waiting,
read-only snapshot/privacy, and unreadable event-context downgrade.

The focused run includes CloseContinueRecoveryTests (durable acknowledgment → relaunch →
new batch, original uncertainty retained/no resend), PrintDurabilityTests,
PrintReliabilityTests, PaymentCameraHandoffTests and GallerySchedulerV2Tests. Complete
production additionally covers event lifecycle/run history, payment recovery, gallery
reconciliation/public verification, receipt/raster rendering, operator settings and
1,000-session isolation. No production test, assertion or CI coverage was disabled/weakened.

Monitoring grows from 20 to 57 tests. New cases cover idle/transient/active printer policy,
normal busy work versus immediate recovery, standalone uncertainty with unknown connection,
component correlation/history/recovery/escalation/recurrence, lower-capability/missing fields,
stale/out-of-order reports, exact heartbeat boundaries/no enrollment/suspension, passive
camera states and legitimate waits, concurrent Worker evaluations, real database restart,
real frozen V2 code rollback/compatibility, queue/replay preservation, bounded retries,
pending unknown recoveries, failed metadata/backend observations, atomic ingestion failure,
lease takeover/fencing, in-flight warning/recovery ordering, critical queue priority, prompt active-guest/unavailable-transport attention, legacy V2 idle-context policy,
strict V3 privacy/schema and forwarded/edited/security/mutation rejection. A test-only
D1 proxy enforces <=40 API requests including deferred delivery on heavy invocations.

## Failures found and corrected during development

- The initial 20-case Worker run passed 19; the old cooldown assertion expected delayed
  recovery. It now explicitly requires prompt recovery and deduplicated follow-up checks.
- Initial expanded tests exposed a V2 bridge accidentally promoting a V3 idle observation;
  bridge creation is now restricted to genuine pre-V3 evidence without V3 observations.
- Synthetic threshold tests initially advanced Cron beyond the next real sample. Fixtures
  now progress monotonically at boundary times; real out-of-order protection was retained.
- Pinned Miniflare 5 uses resourcePersistencePath, not the old d1Persist option. Restart tests
  now use real disk persistence and verify the loaded V2 /health identity during rollback.
- An ancient synthetic delivered-row fixture correctly expired under existing 30-day
  retention. The migration-preservation fixture now uses a recent retained row, and checks
  all of its original values remain identical. Retention policy/assertions were not weakened.
- Review found unknown V3-only codes unsafe in the V2 notification queue, old exhausted
  command cleanup, late-writer lease ownership and non-atomic device/incident ingestion.
  Additive queue separation, retained failures, transactional fencing and one atomic
  ingestion batch fix these verified defects; regressions exercise each.

## Reproduce

From repository root, use existing dependencies and the same simulator (or another existing
available iPad simulator). Build before testing, preserving invocation-only simulator signing:

```sh
xcodebuild build-for-testing -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth \
  -destination 'platform=iOS Simulator,id=C50E23DD-050E-4E94-A232-BE106C121698' \
  -derivedDataPath /tmp/mtk-v2-derived \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
```

Run test-without-building with the same project/scheme/destination/derived data and signing,
`-parallel-testing-enabled NO -collect-test-diagnostics never -test-timeouts-enabled YES
-default-test-execution-time-allowance 600 -maximum-test-execution-time-allowance 900`, and
unique /tmp result/log paths. Select the focused classes above, the entire
PocketPixelsBoothTests target, or entire PocketPixelsBoothUITests target respectively.

```sh
npm --prefix Backend/PaymentsWorker run test:monitoring
npm --prefix Backend/PaymentsWorker test
npm --prefix Backend/CloudflareGalleryProxy test
node Backend/GoogleAppsScript/GridSixValidation.test.cjs
Backend/PaymentsWorker/node_modules/.bin/wrangler deploy \
  --config Backend/MonitoringWorker/wrangler.toml --dry-run --outdir /tmp/mtk-v3-monitor-package
node --check Backend/MonitoringWorker/src/index.js
git diff --check
```

Full tests regenerate tracked browser comparison images. Restore only those generated test
artifacts before staging; initial repository was clean. Do not stage credentials, test media,
temporary app data, result bundles, .wrangler state or build products. Compact result summaries
are intentionally retained here. Final staging must preserve project identity/signing and
all existing production configuration. No PR or feature branch is part of this assignment.

## Independent challenge / remaining acceptance

This fixes classification rather than deleting evidence: internal components/history remain,
unknown cannot clear them, new components/critical priority can alert, and only explicit
resolution recovers. Passive snapshots cannot authorize or mutate guest work. Physical paper,
radio behavior, device suspension and live Telegram delivery/version remain unverified.
Exactly-once Telegram delivery and independence from a platform-wide Cloudflare outage are
not promised. Free-plan API request headroom is locally checked; actual account-wide quotas,
CPU/runtime behavior and live webhook health still need authorized deployment observation.
Automated guest stall detection is intentionally deferred because no trustworthy global
transition deadline exists. See HARDWARE-ACCEPTANCE.md and ROLLOUT.md.

## Hosted Gate #167 and the corrective UI-test navigation change

Source release edf18424dc7c286831dbce4c4f2e176c9112c31d was pushed directly to main once.
[Production Gate #167](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/41026590705)
passed backend and complete production checks, but its native UI suite passed 27/28. The overall gate therefore failed solely on that UI visibility precondition (results/ci167-jobs.json). The failure was
EventOperationsUITests/testPortraitInlineControlsPreviewAndStickerReview: its existing
visibility helper could not reach review-sticker-status before the unchanged Enabled-value
assertion. The hosted iPad Pro 11-inch M5 ran iOS 26.2. The prior local complete native suite
passed on iOS 27.0; this hosted failure is retained separately in results/ci167-native-ui.json.

The downloaded [failure screenshot](results/ci167-review-scroll.png) shows the Review sheet
with the target below its visible Form content. The XCTest activity log shows twelve full
swipes alternating up/down without positioning the short row inside the header/action-bar
bounds. The test now drags only the measured overflow, bounded to one third of the actual
visible viewport, when an existing Review row is outside those bounds. Other scrolling,
the iteration bound, complete visibility requirement and Enabled-value assertion remain.
No sleep, blind test retry, disabled assertion, product layout or production flow change.

Build-for-testing passed after this test-only correction. Both focused UI flows passed on
iOS 27.0 (results/ci-fix-focused27.json), including the exact failed flow and accessibility
save/relaunch/reopen. The complete native suite on the existing iOS 26.5 simulator passed **28/28**, zero failures/skips (results/ci-fix-native26.json), before the corrective commit. No new simulator was created.
The production app debug dylib hash before/after that build is identical:
21b18fd2a7abb34074e853d2375779a3dec43c63e9b2dc782ae772d5494bb79f.
The 980-test final production pass therefore still covers the unchanged production binary;
no redundant local production rerun is needed for a UI-test navigation-only correction.
The normal hosted gate will run both complete suites again on the corrective main commit.

## Hosted Gate #168: separate historical-event feedback sequencing

The bounded Review-sheet navigation passed on hosted iOS 26.2 in
[Gate #168](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/41032421373).
Its backend and complete production jobs passed. Its native suite passed 27/28; a different existing case,
OperatorWorkspaceV41UITests/testHistoricalRemovalAndArchiveRestoreKeepOccurrence,
failed waiting for the removal success banner (results/ci168-native-ui.json).
The [captured removal review](results/ci168-feedback-before-removal.png) shows the previous
restore banner still active behind the sheet. Its six-second deadline coincides with the
next Remove Event tap in the XCTest log; the test had not finished the prior feedback phase.
This timing evidence does not establish a monitoring or event-durability regression.

The test now requires archive and restore success feedback, dismisses it through the existing
visible control, and waits for that prior feedback to disappear before the next action.
All original removal-success, missing-design and hidden-linked-occurrence assertions remain;
archive/restore feedback assertions are additional. There is no production change, timeout
increase, blind retry or disabled assertion. The existing iOS 26.5 simulator passed the three
focused cases: historical archive/restore/removal, successful removal across relaunch, and
storage-failure preservation (results/ci168-fix-focused.json). Build-for-testing passed and
the production debug dylib hash remains unchanged. The final complete native suite passed **28/28**, zero failures/skips on iOS 26.5 (results/native-final26.json), before the next minimal test-only corrective commit. Both earlier hosted attempts passed backend and complete production jobs; their separate UI failures are retained in results/ci167-jobs.json and results/ci168-jobs.json. The next normal gate validates the final test-only correction.
