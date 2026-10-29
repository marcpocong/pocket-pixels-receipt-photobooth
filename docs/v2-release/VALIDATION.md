# Validation record

Repository: `marcpocong/pocket-pixels-receipt-photobooth` (private).
Fetched main: `ff4c06d5ecadabcd32001b5e560bc1c96b4b8253`.
Branch: `feat/operations-studio-monitor-v2`.
Draft PR: https://github.com/marcpocong/pocket-pixels-receipt-photobooth/pull/20
Local tools: Xcode 27.1 (27A9275), iPad Pro 11-inch M4 simulators, iOS 26.5 / 27.0.
No physical iPad or printer. No deployment or live Telegram delivery.

## Commands and initial results

- `git status --short --branch`, `git fetch origin main`, `git log`, `git diff`, root `AGENTS.md`,
  `.github/workflows/ci.yml`, current source/tests and recent fixes inspected before edits.
- `xcodebuild build-for-testing -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth
  -destination 'platform=iOS Simulator,id=C50E23DD-050E-4E94-A232-BE106C121698'
  -derivedDataPath /tmp/mtk-v2-derived CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=` passed at the gallery, receipt, monitoring
  and integration checkpoints. Overrides are invocation-only; project signing is unchanged.
- `xcodebuild test-without-building` using that project/scheme/derived data, `-parallel-testing-enabled
  NO`, and the corresponding `-only-testing` selections produced:
  - `/tmp/mtk-v2-gallery-reviewed.xcresult`: 28 passed (gallery scheduler, hardening, front-door).
  - `/tmp/mtk-v2-studio-model.xcresult`: 42 passed, 2 legacy whole-reset assertions failed. Those
    assertions were updated to verify the requested reset against original production frames.
  - `/tmp/mtk-v2-studio-ui.xcresult`: all 5 selected native editor flows passed.
  - `/tmp/mtk-v2-studio-monitor-verified.xcresult`: 47 passed (receipt/raster/co-brand/telemetry).
  - `/tmp/mtk-v2-fairness-check.xcresult`: 7 passed on iOS 26.5 (six scheduler tests including
    sequential fast-job fairness / rapid reconnection, plus the guest receipt screenshot test).
- `npm --prefix Backend/PaymentsWorker test`: 223 passed.
- `npm --prefix Backend/CloudflareGalleryProxy test`: 39 passed.
- `npm --prefix Backend/PaymentsWorker run test:monitoring`: 19 passed; real local D1 and mocked
  Telegram/payment-health responses. No external messages sent. Test harness now waits for
  concurrent delivery leases to settle and applies complete SQL statements, including multiline
  additive migrations. Existing assertions and retry bounds remain.
- `node Backend/GoogleAppsScript/GridSixValidation.test.cjs --fixtures`: passed and produced the
  synthetic browser fixtures used by full iOS validation.
- `Backend/PaymentsWorker/node_modules/.bin/wrangler deploy --dry-run --config
  Backend/MonitoringWorker/wrangler.toml --outdir /tmp/mtk-v2-monitor-dry-run`: passed (no deploy).
- `git diff --check`: passed at checkpoints.

## Full gate and follow-up

Complete local production and native UI suites run separately on two isolated simulators with
CI-equivalent `-test-timeouts-enabled YES -default-test-execution-time-allowance 600
-maximum-test-execution-time-allowance 900`. Results are recorded below when complete.

The first full local production run flagged a guest passport landscape screenshot color
fraction (0.003922 versus >0.004). The test and guest screen have not been weakened/changed;
the same test passed separately on iOS 26.5. Further iOS 27 investigation is recorded below.

A focused standalone probe additionally exposed sequential recovery starvation behind fast
completed jobs. Adding a yield only at completed operation boundaries moved the second recovery
from position 21 to position 3; a real simulator XCTest now covers it. Public-reconciliation
failures now count attempts, so repeated failed GETs grow backoff instead of staying at the
first delay. No in-flight operation is cancelled.

Hosted Production Gate run 40894983896:
https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/40894983896
All jobs failed **before any steps ran**. GitHub's check annotation states:
“The job was not started because an Actions budget is preventing further use.”
No paid plan, budget, workflow checks or test coverage were changed to bypass this external
blocker. The connector returned no job steps/logs; the annotation was confirmed using the
read-only `gh api .../check-runs/123521515981/annotations` call. Hosted CI is not passing.

Historical pre-existing `/tmp/mtk-v2-baseline-tests.log` / gallery test logs include simulator
stalls and result-save failures lasting hours. They are not counted as successful test runs.

## Remaining manual acceptance

See [HARDWARE-ACCEPTANCE.md](HARDWARE-ACCEPTANCE.md). Physical receipt output, weak real networks,
background behavior on Carlo and live owner-only Telegram behavior remain pending. No simulator
or mock result proves these hardware/live properties.

## Completed full-pass review and environment recovery

`/tmp/mtk-v2-full-production.xcresult` completed with **955 passed, 3 failed, 0 skipped (958 total)**.
Failures were the archived-image reset policy, live-publisher interference in a gallery fixture,
and a guest screenshot captured during its entrance fade. All three were investigated and
corrected. The exported failing passport screenshot confirms the action was mid-fade; the
unchanged guest screenshot passed independently on main and the updated app. Follow-up
`/tmp/mtk-v2-viewport-snapshot-regression.xcresult` passed **60** tests, and
`/tmp/mtk-v2-proof-isolation.xcresult` passed **17**.

`/tmp/mtk-v2-full-native-ui.xcresult` completed with **27 passed, 1 failed (28 total)**. Its sole
failure was the archive success banner timing check, now reordered without reducing assertions.
The additional iOS 26.5 run flagged an accessibility Sticker Studio navigation test before the
later host storage failure; it passed in the complete iOS 27 pass and independently in the
latest Save acceptance run. The iOS 26.5 observation is kept separate from iOS 27 results.

The next parallel reruns encountered host disk exhaustion (`NSCocoaErrorDomain 640` / POSIX 28)
and simulator install failures. They were stopped and are **not** counted as passing complete
runs. Their logs are `/tmp/mtk-v2-final-production.log`, `/tmp/mtk-v2-final-native-ui.log` and
`/tmp/mtk-v2-save-final-acceptance.log`. Before interruption, all seven ReceiptStudioV2Tests,
including the new merge-preserves-commercial/guest-data regression, passed; the selected
portrait accessibility save/reopen UI test also passed.

Cleanup removed only the task-created extra simulators and the temporary untouched-main
worktree/build. Existing simulator app/customer records were not erased. More than 5 GiB was
recovered. Simulator testmanager services initially retained missing socket paths after the
storage failure; shutdown/boot repaired them without erasing device data.

The complete current-candidate gate is running on one iOS 27 simulator in
`/tmp/mtk-v2-complete-gate-rebooted.xcresult`, using the same timeout/signing flags and
`-collect-test-diagnostics never`. This disables bulky automatic sysdiagnose collection only;
all unit/UI tests, assertions, screenshot attachments and result reporting remain enabled.
Final outcome is recorded below after completion.
