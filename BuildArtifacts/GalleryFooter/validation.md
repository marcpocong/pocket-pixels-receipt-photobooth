# Validation record — October 17, 2026

Repository: `main` at `8ade190a85c186558a7110a561a14974540cd4ab`, with the local changes listed in `changed-files.txt`.

- Initial baseline simulator build: passed, including the pre-existing footer-model edits.
- Incremental simulator Debug builds after implementation phases: passed.
- Generic iPad Release compilation with signing disabled: passed. This is compilation evidence, not an installable signed release package.
- Initial footer test run: 5 tests passed, 0 failures. Includes 36 combinations of final thermal QR scan checks and legacy Passport composition.
- Final affected-test run after the Core Image border correction: **64 passed, 0 failed, 0 skipped** on iPad Pro 13-inch (M5), iOS 26.5 simulator. This includes all 9 footer tests, gallery front-door migration, receipt/raster regression, thermal preview accuracy, Sample Print Studio, and paid-checkout recovery. See `focused-test-summary.json`.
- Signed generic iPad Debug build: passed using existing project signing. `codesign --verify --deep --strict` passed. Build: `/tmp/PocketPixelsFooterDeviceBuild/Build/Products/Debug-iphoneos/PocketPixelsBooth.app`.
- Final generic iPad Release build with signing disabled: passed after the QR border correction.
- Full regression run: **570 passed, 0 failed, 0 skipped**, approximately 16 minutes 19 seconds of test execution on iPad Pro 11-inch (M5), iOS 26.5 simulator. See `full-test-results.txt` and `full-test-summary.json`. This run started during implementation, before the final QR border correction and two additional footer tests; the final 64-test affected-area run checked the final code.
- Full-run result-bundle limitation: Xcode could not save its `.xcresult` activity log (`mkstemp: No such file or directory`). The console contains all 570 passing individual test results and `TEST SUCCEEDED`; these results were retained. Its summary JSON was generated from that console, while the focused summary was exported directly using `xcresulttool`.
- Final artifact review: integrated Strip and Solo, plus co-branded Photo Pass comparisons, inspected visually. 72 receipt PNGs, 36 packed 1-bit rasters, and six comparisons retained. `raster-manifest.json` describes every packed raster.
- CI was not triggered because no commit or push was requested.
- One affected-test invocation was canceled before tests ran because an overlapping local build held Xcode's build database lock. It was rerun sequentially and passed; no test failure was bypassed.
- Physical VOZY G80 paper scans, live customer gallery delivery, and Carlo installation: not performed.

Commands used (derived-data directories are disposable build output outside the source tree):

```sh
xcodebuild -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth \
  -configuration Debug -sdk iphonesimulator -derivedDataPath /tmp/PocketPixelsFooterBuild build

xcodebuild -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth \
  -configuration Debug -sdk iphonesimulator -derivedDataPath /tmp/PocketPixelsFooterBuild \
  -destination 'platform=iOS Simulator,id=20AA9450-8E52-4E01-B3EC-EF189945625A' \
  -parallel-testing-enabled NO test

xcodebuild -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth \
  -configuration Debug -sdk iphonesimulator -derivedDataPath /tmp/PocketPixelsFooterBuild \
  -destination 'platform=iOS Simulator,id=AAB946E9-673F-4A7A-BF00-E9F830F58271' \
  -parallel-testing-enabled NO -only-testing:PocketPixelsBoothTests/ReceiptFooterModeTests test

xcodebuild -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/PocketPixelsFooterDeviceBuild CODE_SIGNING_ALLOWED=NO build

xcodebuild -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/PocketPixelsFooterDeviceBuild build
```

The full suite's XCTest runner and its two simulator destinations are isolated from Carlo. Backend request tests use existing test doubles. No CI check was bypassed and no live worker migration or deployment was run.

Measured QR fixtures: production-length URL → 49 actual symbol modules, 4-module explicit quiet zones, 4 dots/module, 228-dot rendered symbol-plus-zone within 236 dots. Largest accepted integrated fixture → 245 URL bytes, 61 modules, 276 dots; it decoded exactly from the final raster. Oversized URLs are explicitly rejected.

Install readiness: the signed development build is ready for an approved installation on Carlo. Its signature verifies and its existing embedded development profile includes Carlo. The profile expires **October 19, 2026 at 4:10 PM Asia/Manila**; the existing signing setup must renew it for use beyond that point. Carlo was listed as disconnected, on iPadOS 26.6.1. No installation or physical print was attempted. Hardware validation remains required before production sign-off.
