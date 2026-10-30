# Local gallery performance validation

Run from the repository root. These tools do not need credentials and do not make external requests. Keep Google Drive as permanent storage; do not deploy either backend while validating this change.

The Swift `GalleryPipelineBenchmarkTests` use seeded 1600×1200 noisy photographs and authentic ReceiptComposer output for 1/3/6 photos, with 1/5/20 queued guest sessions. Image preparation and atomic persistence are real. URLProtocol intercepts **every** request; POST takes a controlled 20 ms and public verification 80 ms. Measurements include main-actor handoffs, disk reads, Base64/JSON encoding and URLSession overhead. Queue-to-POST includes encoding and loading after scheduler admission. Completion starts when the prepared queue is submitted and ends when public proof is saved and the pending directory is cleared. Preparation and persistence are reported separately. This is a repeatable backlog test, not a promise about event Wi-Fi or natural guest arrival rates.

```sh
xcodebuild test -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth \
  -destination 'platform=iOS Simulator,id=<isolated-iPad-simulator>' \
  -derivedDataPath DerivedData/GalleryPerformance -parallel-testing-enabled NO \
  -only-testing:PocketPixelsBoothTests/GalleryPipelineBenchmarkTests CODE_SIGNING_ALLOWED=NO
```

Read `DerivedData/gallery-benchmark-latest.json` and the `GALLERY_JPEG_CANDIDATE` line in the test log. No application signing settings are edited by the command. The JPEG candidate uses the same image and nominal compression quality; differing bytes prevent its adoption here.

```sh
node Backend/GoogleAppsScript/GridSixValidation.test.cjs --fixtures
node --test Backend/CloudflareGalleryProxy/test/index.test.js Tools/GalleryPerformance/isolated-drive-contract.test.cjs
node Tools/GalleryPerformance/benchmark.mjs > DerivedData/gallery-node-latest.json
```

The Node benchmark executes the actual Apps Script entry points in a VM with in-memory Drive/Properties/Cache/Lock services. Signature-valid deterministic buffers are 300,000 B per photo and 180,000 B per receipt. They test transfer/storage budgets, not visual JPEG decoding. Public-page timing consumes the entire HTML response body with an origin delay of 15 ms and cache-put delay of 25 ms. A warm request runs after background cache completion. The operation counts are useful evidence; mock Drive operation duration is **not** evidence of Google Drive latency. No browser paint, image decoding, real network transfer or edge geography is modeled.

To reproduce the backend baseline without changing main, extract the two source files from `dd209cc` to temporary paths and pass them as arguments (Worker first, Apps Script second). Use an `.mjs` extension for the extracted Worker:

```sh
git show dd209cc:Backend/CloudflareGalleryProxy/src/index.js > /tmp/gallery-baseline-worker.mjs
git show dd209cc:Backend/GoogleAppsScript/Code.gs > /tmp/gallery-baseline-Code.gs
node Tools/GalleryPerformance/benchmark.mjs /tmp/gallery-baseline-worker.mjs /tmp/gallery-baseline-Code.gs
```

The native baseline was recorded before production code edits, using the identical benchmark test source against `dd209cc`. For an independent native rerun, use a disposable detached worktree of that revision and copy only `GalleryPipelineBenchmarkTests.swift` into its synchronized test folder. Keep it separate from the main workspace and existing device containers.

## Isolated Drive API experiment

`Tools/GalleryPerformance/DriveCreateBenchmark.gs` is **not** part of `Code.gs`, and must not be copied into the deployed gallery project. Its local contract test verifies both writer implementations use identical bytes, the same synthetic parent, and exact name/size/type/parent checks. It refuses a project containing production root/device-token properties.

Real API timing has not been performed. If an isolated account/project is later authorized and available, enable Advanced Drive v3 only there and run one matrix cell per execution, for example:

```js
benchmarkIsolatedDriveCreate({confirmIsolated:true, photoCount:3, guests:5});
```

The experiment alternates writer order, retains synthetic scratch output, and returns per-file create/verification and per-session total times. Repeat cells on multiple occasions and summarize p50/p95/max before selecting a writer. The 6-minute Apps Script execution limit can interrupt large cells; retain partial output and never substitute an incomplete run for a complete measurement. It does not change sharing, delete existing files, call gallery upload routes, or touch payments. **Do not infer which remote API is faster from its local mocks.** DriveApp remains the production writer.
