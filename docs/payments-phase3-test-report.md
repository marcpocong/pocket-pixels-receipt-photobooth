# Payments Phase 3 — test report

> **Correction (Phase 4, 2026-10-11):** the simulator used for the Phase 3 Swift runs (`20AA9450…`, iPad Pro 11-inch M5) runs the **iOS 26.5** runtime, not iOS 27.0 as stated below; the SDK was iOS 27.0. The `.iso8601` observation was therefore made on iOS 26.5. Phase 4 runs on both 26.5 and 27.0 (`payments-phase4-test-report.md`).

Executed 2026-10-10 (Asia/Manila) in an isolated no-hardlink clone of `codex/madetokeep-payments-phase2` (base PR head `39401e3`), on macOS with Xcode 27.0 (27A266a), iOS 27.0 SDK/simulator runtime, Node 24.16.0, Wrangler 4.149.0, Miniflare 5.20261006.1-alpha (workerd 1.20261006.1). No Cloudflare, D1-remote, PayMongo or live endpoint was contacted; nothing was deployed.

## Summary

| Gate | Command | Exit | Result |
|---|---|---|---|
| Worker syntax | `npm run check` | 0 | pass |
| Worker tests (all) | `npm test` (`node --test test/*.test.js`) | 0 | **186 / 186 pass**, repeated ≥ 4 full runs |
| — route tests in workerd + local D1 | `routes-*.test.js` | 0 | 94 pass |
| — migration tests (incl. Wrangler local runner) | `migrations.test.js` | 0 | 5 pass |
| — pure domain/unit | `domain-*.test.js`, `security-and-pricing.test.js` | 0 | 87 pass |
| Wrangler config, original | `wrangler deploy --dry-run --env test` | **1** | *No environment found … "test"* (reproduces the finding) |
| Wrangler config, new | `wrangler deploy --dry-run --env test` / `--env live` / no env | 0 / 0 / 0 | bindings resolve to test / live / local DBs; no upload |
| iOS baseline PR head | `xcodebuild … build-for-testing` (iPad Pro 11-inch M5 sim, iOS 27) | **0** | Phase 2's exit 65 does **not** reproduce on this host → it was the Phase 2 sandbox, not the code |
| iOS candidate build | `xcodebuild … build` and `build-for-testing` | 0 | no new warnings in payment files |
| iOS candidate tests | `xcodebuild … test-without-building -parallel-testing-enabled NO` | 65 | **261 tests: 258 pass, 3 fail** (pre-existing, see below) |
| iOS baseline tests | same, PR head `39401e3` | 65 | 234 tests: 230 pass, 4 fail (same 3 + a test-host crash) |
| `main` check | the 3 failing tests on `main` `934a76d` | 65 | **all 3 fail on main too** |
| Launch smoke | `simctl install/launch` candidate, screenshot | 0 | welcome screen renders (Private/Prepaid default) |
| Payment Swift suites alone | `-only-testing:` 8 payment suites | 0 after fix | 58 pass (one OS-dependent assertion removed, see notes) |

Logs (kept outside the repository; contain no secrets): `worker-tests-final.log`, `wrangler-dryrun-{test,live,toplevel}.log`, `wrangler-dryrun-test-ORIGINAL-config.log`, `baseline-build-for-testing.log`, `baseline-test.log`, `candidate-build-for-testing-2.log`, `candidate-full-tests.log`, `main-3tests.log`, `candidate-launch-welcome.png`, xcresult bundles.

## Commands

```sh
# Worker
cd Backend/PaymentsWorker && npm ci && npm test && npm run check && npm run validate:config

# iOS (clean derived data outside the repo)
xcodebuild -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
  -derivedDataPath /tmp/pp-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
  -derivedDataPath /tmp/pp-dd -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test-without-building
```

`-parallel-testing-enabled NO` is recommended: with parallel simulator clones this host exceeded the per-user process limit (`fork failed`; ~2,850 processes vs `kern.maxprocperuid` 2,666), which stalled one run. No system setting was changed.

## How route tests work (and their limits)

Each test starts the real Worker module in `workerd` via Miniflare with a fresh in-memory D1, applies `migrations/0001…0004` (trigger bodies kept intact), seeds devices across two accounts, and sends real HTTP requests with `dispatchFetch`. Concurrent cases fire requests with `Promise.all`, so they interleave inside workerd at every D1 await, and D1 `batch()` is a real transaction (verified: a constraint failure in a batch rolls back earlier statements). PayMongo is an `outboundService` stub that can return 4xx/5xx, throw (transport failure), or delay past `PROVIDER_TIMEOUT_MS` (real `AbortSignal.timeout`). Cron is invoked through the Worker's `scheduled()` handler.

Limits: local D1 is SQLite inside workerd, not the distributed D1 service; latency and cross-region behavior are untested. The stub models PayMongo's documented shapes, not its live behavior.

**Mutation check** (credibility of the suite): removing the order-lock guard and the single-attempt trigger produced 8 failures in the exclusivity suite; making late payments on superseded orders `AUTHORIZED` produced 2 failures. Sources were restored and diffed.

## Bugs found and fixed by these tests / this audit

1. Concurrent `POST /v1/orders` with the **same** idempotency key could return `409 checkout_already_open` instead of the replay (SQLite reported the other unique index). Fixed: any unique violation re-checks the key first. Same class fixed in offline sync.
2. `PATCH` on version conflict committed an orphan policy revision (insert ran before the guarded update). Fixed: insert conditional on the winning mutation marker; 5 concurrent writers → exactly 1 revision.
3. Print summary over-counted purchased copies (join fan-out). Fixed with separate aggregates.
4. Offline sync was not account-scoped. Fixed and tested.
5. Cash-count `provisional` relied on a column that is never NULL (always false). Now driven by device-reported pending count and server conflicts.
6. iOS client used `URL.appending(path:)` for paths with queries → `/v1/admin/events%3Flimit=100` (verified with `swift`). Fixed; regression test added.
7. iOS had no pairing UI or base-URL setting, so `PaymentsConfiguration.bundled` was always nil. Added operator pairing.
8. iOS offline ledger mutated memory before a failed write (phantom authorization) and silently restarted at sequence 1 on a corrupt file. Fixed; tests inject a failing writer and corrupt files.
9. Phase 2 VM never claimed entitlements, recorded prints, or synced offline cash. Added.

## Notable assertions

- Mixed concurrent cash/QR on one order (6 rounds × 8 requests) → exactly one attempt, method == lock, entitlements only for cash.
- 6 concurrent QR creates → 1 provider intent; 6 concurrent cash taps → 1 entitlement.
- Provider attach timeout → `UNKNOWN_RECONCILIATION`; cash `409 payment_method_locked`; new checkout `409 previous_payment_unresolved`; Cron with paid provider → entitlement on the original order; one intent total.
- Late paid on superseded order → `LATE_PAID_REVIEW`, entitlement not claimable, excluded from verified revenue, surfaced as review.
- Duplicate webhook ×6 concurrent → 1 event row, 1 entitlement, revenue once; Cron+webhook race ×4 → 1 entitlement each.
- Signed webhook: wrong secret, ±301 s, `li` on test endpoint, tampered raw body, missing header, malformed JSON, livemode mismatch → rejected.
- Claims from 4 concurrent sessions → exactly 1 bound; consumed/reused refused; outstanding entitlement claimable after pause → end.
- Offline: Ed25519 grant verifies with the public key; tamper fails; 10 rejection reasons persisted replay-safely; device/account binding; sequence duplicates and declaration cap; post-revocation declarations flagged.
- Migration upgrade with legacy dual-attempt order: no rows dropped, quarantined + `MANUAL_REVIEW`, triggers active; Wrangler `d1 migrations apply --env test --local` applies all four and ≥ 15 triggers exist.
- Swift: Node-signed Ed25519 vector verified by CryptoKit; 13 fail-closed verifier cases; peso parsing (no floating point) incl. `49.999` rejected; journal disk-full, corruption quarantine, inconsistent sequence, clock rollback, declaration cap; client error-code mapping, transport-failure → `outcomeUnknown` for writes; `CheckoutGuard` exclusivity rules.

## Pre-existing failures (not caused by Phase 3)

`PassportFormatTests.testPassportRequiresExactlyTwoPhotosAndFollowsDetailsSignaturePreviewFlow`, `PhotoPassFormatTests.testPhotoPassFlowKeepsPhotosNameNoteAndSignatureWhenGoingBack`, `SessionIsolationAndRecoveryTests.testSixPhotoSequenceReachesReviewOnlyAfterSixAndRejectsExtraSamples` fail identically on `main` `934a76d`, the PR head, and the candidate. They call `addSamplePhoto` synchronously, while `main`'s capture presentation now advances state after `capturedPhotoDisplayDuration` asynchronously. Left unchanged (outside payment scope); flagged for the owner.

## Correction to an earlier hypothesis

During the audit I expected Foundation's `.iso8601` decoder to reject the Worker's millisecond timestamps. On the iOS 27 simulator it **accepted** them, so that assertion was removed. The explicit decoder is kept because the classic `ISO8601DateFormatter` path (without `.withFractionalSeconds`) rejects them and the deployment target is iOS 18; this was **not** verified on an iOS 18 runtime.

## Not tested (requires authorization, credentials or hardware)

PayMongo `test_url` E2E; deployed webhook delivery; deployed Cron; remote D1; real iPad; VOZY G80 printing and ambiguous-print recovery; VoiceOver/Dynamic Type/orientation on checkout and operator screens (simulator available but interactive UI navigation was not automated in this phase); iOS 18 runtime.
