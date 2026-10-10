# Payments Phase 4 — test report and acceptance matrix

Executed 2026-10-11 in the isolated clone (`~/Desktop/PP-phase3/repo`), base `a3707c4`. Xcode 27.0 (27A266a), iOS 27.0 SDK; simulators iPad Pro 11-inch (M5) on **iOS 27.0** (`8A1D9769…`) and **iOS 26.5** (`20AA9450…`) — OS versions taken from the result bundles. Node 24.16.0, Wrangler 4.149.0, Miniflare 5.20261006.1-alpha. Nothing was deployed; no PayMongo or Cloudflare API was called.

## Results

| Gate | Command | Exit | Result |
|---|---|---|---|
| Clean install | `npm ci` | 0 | lockfile install |
| Worker tests | `npm test` | 0 | **195 / 195** (186 Phase 3 + 8 Phase 4 route/D1 tests + 1 QR Ph minimum case) |
| Worker syntax | `npm run check` | 0 | pass |
| Config isolation | `npm run validate:config` (`wrangler deploy --dry-run --env test` and `--env live`) | 0 | TEST → `pocket-pixels-payments-test`; LIVE → `pocket-pixels-payments-live`, `LIVE_PAYMENTS_ENABLED=false`; nothing uploaded |
| Wrangler local D1 migration runner | in `migrations.test.js` | 0 | `0001`–`0005` applied |
| Advisories | `npm audit --omit=dev`; `npm audit` | 0 | **0 production, 0 total** (Phase 3's 3 dev-only highs no longer reported after `npm ci`) |
| Whitespace | `git diff --check` | 0 | clean |
| iOS build-for-testing | concrete iPad destination, fresh DerivedData | 0 | no new warnings in Phase 4 files |
| iOS payment suites (12 suites) | `test-without-building -parallel-testing-enabled NO -only-testing:…` | 0 / 0 | **57 / 57 on iOS 27.0** and **57 / 57 on iOS 26.5** |
| iOS full suite | `test-without-building -parallel-testing-enabled NO` | 65 / 65 | **282 / 285 on iOS 27.0** and **282 / 285 on iOS 26.5**; the 3 failures are the pre-existing ones below |
| Launch smoke | `simctl install/launch`, screenshot (iOS 27.0) | 0 | welcome screen unchanged; recovery coordinator starts without error |
| Mutation (Worker) | Phase 3 checks still valid | — | — |
| Mutation (iOS outbox) | allow `uncertain` copies to be resent (on a separate copy of the tree) | 65 | crash-point test failed for all 3 arguments (6 issues): the guard is exercised |

Swift baseline comparison: Phase 3 candidate 258/261 (iOS 26.5); Phase 4 282/285 on both runtimes (+24 tests). Failing set identical.

### Pre-existing failures (not payment regressions)

`PassportFormatTests.testPassportRequiresExactlyTwoPhotosAndFollowsDetailsSignaturePreviewFlow`, `PhotoPassFormatTests.testPhotoPassFlowKeepsPhotosNameNoteAndSignatureWhenGoingBack`, `SessionIsolationAndRecoveryTests.testSixPhotoSequenceReachesReviewOnlyAfterSixAndRejectsExtraSamples`. Root cause: `main` commit `f5c8603` ("Redesign receipt presentation and camera capture flow") made `addSamplePhoto` show each capture for `BoothConfiguration.capturedPhotoDisplayDuration` (0.8 s) and advance state asynchronously; these XCTests assert synchronously after each call. They fail identically on `main` `934a76d`. Not fixed here: the fix belongs with the capture work (which continues in the owner's working tree) and is unrelated to payments.

### iOS 18

**NOT TESTED at runtime** — no iOS 18 simulator runtime is installed (only 26.5 and 27.0) and no device was used. Static evidence: the app compiles with `IPHONEOS_DEPLOYMENT_TARGET = 18.0`, so the compiler has checked API availability (`Date.ISO8601FormatStyle` iOS 15+, CryptoKit `Curve25519` iOS 13+, `NSLock.withLock` iOS 16+, `Task.sleep(for:)` iOS 16+, SwiftUI `onChange(of:_:)` two-parameter iOS 17+, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `FileProtectionType.completeUntilFirstUserAuthentication`). Runtime risks to verify on an iOS 18 device: ISO-8601 parsing of `.000Z` and `+08:00` forms (covered by `WorkerTimestampTests`, run on 26.5/27.0 only), Swift Testing availability on the test host, and Keychain behaviour after reinstall.

### Commands

```sh
cd Backend/PaymentsWorker && npm ci && npm test && npm run check && npm run validate:config && npm audit --omit=dev
xcodebuild -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth \
  -destination 'platform=iOS Simulator,id=<iPad UDID>' -derivedDataPath /tmp/pp-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth \
  -destination 'platform=iOS Simulator,id=<iPad UDID>' -derivedDataPath /tmp/pp-dd \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test-without-building
```

Note for zsh users: pass multiple `-only-testing:` flags directly (or with `${=VAR}`); an unsplit variable silently selects zero tests. A zero-test run was observed, rejected and rerun during this phase.

## New tests (what they prove)

**Worker (`test/routes-phase4-recovery.test.js`, workerd + local D1):** lookup by checkout session after a crash creates no order/charge and omits the QR image; device- and account-scoped; full supersede history with cash kept unverified; recovery claim is idempotent, audited (`ENTITLEMENT_RECOVERY_CLAIM`) and cannot rebind to another session; paid entitlement survives pause/end and is listed by the `outstanding` filter; outbox replay semantics (exact replay = success, concurrent replays, `UNCERTAIN` cannot be upgraded, second batch refused, no copy beyond paid quantity, idempotent completion, late reports after completion); migration `0005` preserves rows byte-for-byte and keeps outcomes append-only.

**iOS (`PaymentsPhase4Tests.swift`):** crash before journal write (nothing recorded, nothing sent); crash after journal write / while sending / after hardware response before local update (→ `uncertain`, reported, never resent); crash after copy N−1 of N (continues with copy N, never beyond N); disk full when recording the outcome (conservatively `uncertain`); `notStarted` retry without a server report; changed receipt refused; corrupt journal quarantined and blocks paid copies; prepaid copies never reported; replay after "server processed, local ACK lost" uses identical keys and never sends `CONFIRMED`; 409 quarantined, 503 backs off; checkpoint fail-closed before server mutation; monotonic phases across relaunch; corrupt checkpoint file; checkpoint contains no secrets/guest data; 16-case recovery classifier table; offline-cash recovery; operator-armed single-use expiring resume; auto-completion only when every paid copy was delivered; recovery API path and `recovery` flag; ₱1.00 QR Ph minimum; timestamp parsing (ms, none, `+08:00`, rejects garbage).

## Acceptance matrix

| Requirement | Status | Evidence |
|---|---|---|
| Custody: original tree untouched | PASS | status fingerprint identical at start and end (see PR) |
| Audit + flow diagram before code | PASS | `payments-phase4-audit.md` |
| Durable checkout checkpoint before irreversible transitions | PASS | fail-closed before first server mutation; enrichments best-effort with server lookup fallback |
| Paid-unclaimed recovery without new charge | PASS (local) | route + Swift tests |
| Claimed-not-printed recovery to the original session only | PASS (local) | classifier + route rebind test |
| Pending/unknown QR stays unresolved | PASS | classifier `paymentPending`; not resumable |
| Corrupt checkpoint fails closed, evidence kept | PASS | Swift test |
| Cash stays unverified in recovery | PASS | route + classifier |
| Guest privacy (no data to next walk-up guest) | PASS (design + unit) / NOT TESTED (UI runtime) | operator-armed resume; generic notice |
| Pause/end does not invalidate prior entitlements | PASS | route test |
| Durable print intent before bytes; fail closed | PASS | spooler gate + Swift tests |
| No automatic resend after in-flight | PASS | crash-point tests + mutation check |
| Conservative outcomes (`DELIVERED` ≠ paper confirmed) | PASS | Worker 0005 + outbox; Phase 3 `CONFIRMED` overclaim fixed |
| Replay with unchanged keys, bounded backoff, conflicts visible | PASS | Swift + route tests; operator Print Accounting |
| Printing never blocked by unreachable Worker | PASS (logic) | reports queue; prints gated only by local journal |
| Paid retry continues same batch, no quantity inflation | PASS (unit) / NOT TESTED (hardware) | outbox `nextCopyToPrint`; Phase 3 restart-from-copy-1 bug fixed |
| Full receipt fingerprint reported | PASS | 64-hex asserted (Phase 3 sent a 12-hex fingerprint the Worker rejects) |
| iOS 18 runtime | NOT TESTED | no runtime available |
| PayMongo docs reconciliation | PASS (docs) / BLOCKED (live shape) | ₱1.00 minimum enforced; expiry range matches; `test_url` path undocumented → runbook step 7.1 |
| Provider `test_url` E2E, deployed webhook/Cron | BLOCKED | needs owner authorization |
| Physical iPad, VOZY G80, accessibility runtime | BLOCKED / NOT TESTED | needs hardware |
| Single owner TEST runbook | PASS | `payments-test-staging-runbook.md` |
