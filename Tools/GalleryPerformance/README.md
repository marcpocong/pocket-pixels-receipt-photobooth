# Local gallery performance validation

Run from the repository root. The local tests below need no credentials and make
no external requests. The isolated Google experiments are separate, explicitly
authorized operations; do not substitute their timings for full gallery delivery.
Google Drive remains permanent storage.

## Actual durable recovery and paced TCP

`GalleryPipelineBenchmarkTests.testDurableBacklogRecovery` invokes
`retryPendingQueue()` on 20/50/100 records saved to disk. It supplements the older
independently submitted-task benchmark. Its 20 ms POST / 80 ms verification delays
remain controlled mocks, not upstream bandwidth measurements.

For real local TCP byte pacing, use:

```sh
python3 Tools/GalleryPerformance/run-network-benchmarks.py \
  --device-id <isolated-iPad-simulator> \
  --profiles strong20 strong50 strong100 weak20 improved20 interrupted50
```

The runner temporarily adds `ManualBacklogBenchmarks.swift` to the synchronized
test target, starts a server bound only to `127.0.0.1`, and removes the temporary
source/configuration on exit. Do not launch another build in the same checkout
while it runs. It refuses to overwrite an existing temporary test source. Output
is `DerivedData/gallery-network-results.json` (each run replaces it).

The fixture uses actual prepared JPEGs/receipts, durable queue persistence and the
production recovery service. Synthetic Google/public URLs are bridged to the
local TCP origin. `weak20` paces aggregate upstream reception at 0.5 Mbps;
`improved20` changes 0.25 Mbps to unrestricted after four seconds;
`interrupted50` accepts a chunk then drops its response. Both legacy and forced
binary protocols use equivalent bytes within the matrix. It checks publication
counts, duplicate publication, pending cleanup and exact binary media bytes, and
records first-ready, drain, p50/p95, resident memory and main-actor heartbeat gaps.
It does **not** model Google's execution/Drive latency, public CDN geography,
radio changes, iPadOS suspension or physical printer/camera contention.

Run `--profiles adaptive-strong100 adaptive-improved20` to exercise automatic
transport selection. The fixture explicitly resets path cost and measured rate
between cases. The app starts with resumable protection on unknown/weak paths;
recent acknowledged throughput of at least 256 KiB/s permits the single-request
path on unconstrained connections. A saved resumable journal always resumes its
chosen protocol. The measured tradeoff and full results are in the
[release record](../../docs/gallery-delivery-reliability-2026-11-11.md).

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

This DriveApp-versus-Advanced-Drive experiment has no live timing result. If running
it in an authorized isolated project, enable Advanced Drive v3 only there and run
one matrix cell per execution, for example:

```js
benchmarkIsolatedDriveCreate({confirmIsolated:true, photoCount:3, guests:5});
```

The experiment alternates writer order, retains synthetic scratch output, and returns per-file create/verification and per-session total times. Repeat cells on multiple occasions and summarize p50/p95/max before selecting a writer. The 6-minute Apps Script execution limit can interrupt large cells; retain partial output and never substitute an incomplete run for a complete measurement. It does not change sharing, delete existing files, call gallery upload routes, or touch payments. **Do not infer which remote API is faster from its local mocks.** The legacy protocol retains DriveApp; the new transport uses direct resumable Drive REST sessions.

The November resumable HTTPS microexperiment was separate: scoped session PUTs,
server-confirmed offsets and SHA-256 verification against real Google Drive,
using private synthetic 1 MiB binary files. Its 0.25/0.5 Mbps paced samples validate
the underlying upload mechanism, not Apps Script deployment, image rendering or
complete production-gallery latency. Numeric evidence is checked in under
`BuildArtifacts/GalleryDeliveryReliability`; private resource IDs/capabilities and
raw logs stay outside Git.

`ResumableLiveValidation.gs` is an owner-only live diagnostic template, not a
production backend file. A temporary editor wrapper supplies an isolated versioned
Web App URL, a private synthetic JPEG larger than one chunk, and a private evidence
folder. It obtains the existing device credential server-side, tests repeated
initialization, discards a chunk ACK and probes Google's persisted offset, completes
binary assets, finalizes twice and verifies the actual Worker readiness/page.
Only numeric results are logged. Remove the temporary diagnostic from HEAD after
validation; never include its private wrapper/configuration in Git or an activated
production version. Failed diagnostics retain private evidence and synthetic
resources for review.

## Public gallery read path (11 November 2026)

The raw public document uses progressive inline originals: layout and handlers first,
then one record per asset, photographs before receipts. All origin validation completes
before any response is returned. This improves transfer/paint scheduling, not streaming
from Drive. The direct HtmlService representation remains compatible.

Run the browser diagnostic on macOS with Xcode installed, from the repository root:

```sh
PROGRESSIVE=1 node Tools/GalleryPerformance/browser-fixtures.cjs /tmp/gallery-read-after
python3 Tools/GalleryPerformance/browser-benchmark.py /tmp/gallery-read-after
```

For a baseline, extract the baseline Apps Script directory into a separate temporary
folder and pass `GALLERY_SOURCE=/absolute/path/to/Backend/GoogleAppsScript` to the
fixture generator, with `PROGRESSIVE=0`. Run the **same** browser runner against it.
The runner compiles a standalone Apple WebKit probe into each output directory.
It paces gzip HTML over loopback at 8 Mbps and 1.6 Mbps, using a 390×844 viewport.
Seeded 960×720 JPEGs are approximately 385 KB each; receipt originals are JPEGs too.
The initial two 1600×1200 experiments exceeded the six-photo render budget and were
excluded; the checked-in comparison uses the valid identical 960×720 fixtures.

Metrics cover navigation, FCP/LCP, a decoded photograph in the viewport sampled on
animation frames, all decoded photo previews, control availability, receipt readiness,
and maximum 20 ms heartbeat gaps. They do not separately measure GPU presentation or
image-decoder CPU time. Peak RSS samples only new macOS WebContent processes; it is
process memory, not JS heap. WebKit provides no `performance.memory` here. RSS is noisy,
includes caches, and is not a physical iPhone memory qualification. The runner rejects
missing/failed photo results instead of accepting an error page as a fast gallery.

These are controlled **browser/network simulations**, not mobile CPU, cellular radio,
DNS, Google execution, or regional edge-cache simulations. Live samples and the source/
deployment rollback references are in
[the read-performance release record](../../docs/gallery-read-performance-2026-11-11.md).
No new dependency, service, subscription or preview storage is required.
