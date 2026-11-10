# Phase 8 XCTest Target Integration

The Phase 8 reliability tests are now integrated into `PocketPixelsBooth.xcodeproj` as an app-hosted iOS XCTest bundle with a file-system-synchronized test group. The generated `PocketPixelsBooth` scheme discovers and runs the tests without a shared scheme change.

## Target

- Target name: `PocketPixelsBoothTests`
- Product type: `com.apple.product-type.bundle.unit-test`
- Platform: iOS / iPad-compatible
- Tested application: `PocketPixelsBooth`
- Test host: `$(BUILT_PRODUCTS_DIR)/PocketPixelsBooth.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/PocketPixelsBooth`
- Bundle loader: `$(TEST_HOST)`
- Bundle identifier: `com.pocketpixels.PocketPixelsBoothTests`

## Source Files

Add these files only to the `PocketPixelsBoothTests` target:

- `PocketPixelsBoothTests/ReliabilityTestSupport.swift`
- `PocketPixelsBoothTests/PrintReliabilityTests.swift`
- `PocketPixelsBoothTests/ReceiptAndRasterRegressionTests.swift`
- `PocketPixelsBoothTests/SessionIsolationAndRecoveryTests.swift`

Do not add these files to the production `PocketPixelsBooth` app target.

## Dependencies

- Add a target dependency from `PocketPixelsBoothTests` to `PocketPixelsBooth`.
- Ensure `@testable import PocketPixelsBooth` resolves.
- Preserve the existing app target bundle identifier, signing, deployment target, and file-system-synchronized app group.

## Build Settings

Use settings compatible with the app target:

- `IPHONEOS_DEPLOYMENT_TARGET = 18.0`
- `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"`
- `TARGETED_DEVICE_FAMILY = 2`
- `SWIFT_VERSION = 5.0`
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`
- Debug: `SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)"`

## Scheme

Ensure the existing `PocketPixelsBooth` scheme includes `PocketPixelsBoothTests` in the Test action. If the scheme is automatically generated and `xcodebuild test -scheme PocketPixelsBooth` discovers the test target, no shared scheme change is required.

## Expected Validation

After integration, run:

```sh
xcodebuild -list -project PocketPixelsBooth.xcodeproj
xcodebuild build -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth -configuration Debug -destination 'platform=iOS Simulator,name=<available iPad simulator>'
xcodebuild build-for-testing -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth -configuration Debug -destination 'platform=iOS Simulator,name=<available iPad simulator>'
xcodebuild test -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth -configuration Debug -destination 'platform=iOS Simulator,name=<available iPad simulator>'
```

Expected targets:

- `PocketPixelsBooth`
- `PocketPixelsBoothTests`

## Physical Device Validation Scope

The automated tests and DEBUG chaos harness validate software invariants only. They do not prove real VOZY G80 BLE, cutter, thermal head, or paper-feed reliability.

Recommended manual hardware sequence after automated tests pass:

1. Run 10 sequential single-copy live sessions.
2. Run 10 live sessions alternating 1, 2, 3, and 5 copies.
3. Run 50 or more sequential physical receipts and inspect image correctness, copy count, cut behavior, BLE stability, and malformed output.
4. Disconnect Bluetooth before a print begins and verify safe failure without recovery lock.
5. Interrupt Bluetooth only after printing has begun and verify `Print Status Unknown` / recovery required with no automatic retry, no fallback, and no next copy.

## Completed Validation — 2026-09-07

- PASS: `xcodebuild -list`, Debug app build, and build-for-testing.
- PASS: `@testable import PocketPixelsBooth`, app dependency, test host/loader, and test-only source membership.
- PASS: full XCTest suite — 29 tests, 0 failures (15 print reliability, 4 receipt/raster, 10 session/recovery).
- PASS: `testOneThousandSessionsHaveZeroCrossSessionContamination` — 1,000 synthetic sessions, 42.574 seconds.
- Simulator: iPad Pro 11-inch (M5), iOS 26.5, `20AA9450-8E52-4E01-B3EC-EF189945625A`.
- Fixed the test-only raster generator repeating every 256 seeds by preserving the full seed; added a seed 1/257 regression. No existing assertions were weakened.
- No production source was changed during target integration and test fixes. No automatic print retry behavior was introduced.
- Scope: synthetic sessions and test-local callback/recovery models do not replace end-to-end customer-session or physical printer validation.
