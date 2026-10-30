# Made to Keep Studios — Google Drive gallery performance

Validation date: October 30, 2026 (Asia/Manila). Repository: `marcpocong/pocket-pixels-receipt-photobooth`, local `main`. Baseline: `dd209cc` (before production source edits). The implementation commit is `c0c84f4bea979eeb4c9276097011f25bde419037`. Measurements below belong to that implementation. It was subsequently pushed to GitHub `main` at the owner's request, with a CI follow-up described below. No live service was deployed.

Google Drive remains the permanent storage backend. No R2, storage migration, new dependency, production gallery/payment, media deletion, credential change, signing change, bundle-ID change or PR was introduced. All generated photos and files are synthetic and local. The separate Drive API experiment has not been run against Google.

## Measured native results

Apple M4, macOS 27.0.1, Xcode 27.1 (27A9275), iPad Pro 11-inch simulator, iOS 26.5. Debug builds, same simulator and fixtures before/after. Baseline focused validation passed before production edits. Final figures below come from the full validation run. Each cell is one run of 1, 5 or 20 consecutive queued sessions, with a fresh local pending store. Inputs are seeded 1600×1200 noisy photographs and authentic ReceiptComposer output. Preparation/persistence run before submitting the queue; all guests are then enqueued together to make backlog effects reproducible. POST and verification delays are controlled at 20/80 ms, with real URLSession, encoding and disk overhead. These are simulator/backlog measurements, not real event-network latency.

Triples are **p50 / p95 / maximum**, in milliseconds, using nearest-rank percentiles. With one guest all three values coincide; with five guests p95 equals maximum. The 20-session tail has limited statistical power.

| Photos | Guests | Completion before | Completion after | Queue-to-POST before | Queue-to-POST after | Request bytes, unchanged |
| ---: | ---: | --- | --- | --- | --- | ---: |
| 1 | 1 | 124.7/124.7/124.7 | 121.3/121.3/121.3 | 10.7/10.7/10.7 | 7.6/7.6/7.6 | 1,195,981 |
| 1 | 5 | 386.5/660.0/660.0 | 212.9/301.9/301.9 | 269.4/537.6/537.6 | 68.2/164.1/164.1 | 5,979,905 |
| 1 | 20 | 1264.8/2387.5/2532.2 | 509.4/923.6/959.8 | 1152.6/2260.7/2400.5 | 394.9/786.8/840.9 | 23,919,620 |
| 3 | 1 | 135.6/135.6/135.6 | 130.1/130.1/130.1 | 17.9/17.9/17.9 | 15.3/15.3/15.3 | 2,805,400 |
| 3 | 5 | 425.7/729.2/729.2 | 218.8/310.5/310.5 | 304.5/610.8/610.8 | 89.9/184.8/184.8 | 14,027,000 |
| 3 | 20 | 1359.2/2736.0/2886.3 | 549.6/951.0/991.5 | 1239.1/2607.6/2760.2 | 428.2/828.9/872.0 | 56,108,000 |
| 6 | 1 | 145.7/145.7/145.7 | 142.9/142.9/142.9 | 31.8/31.8/31.8 | 27.6/27.6/27.6 | 5,142,246 |
| 6 | 5 | 449.7/751.3/751.3 | 242.7/337.2/337.2 | 333.4/629.9/629.9 | 125.2/221.1/221.1 | 25,711,230 |
| 6 | 20 | 1622.6/2994.0/3149.9 | 579.3/1017.4/1068.8 | 1498.5/2868.7/3018.3 | 463.7/902.9/953.4 | 102,844,920 |

Completion begins at prepared-queue submission and ends after public verification, durable local proof and queue cleanup. The maximum is total batch drain time; it excludes the separately measured preparation/persistence. Queue-to-POST includes queue waiting plus media loading, Base64/JSON encoding and URLSession dispatch. The production scheduler also records queue waiting alone.

| Photos | 20-session preparation before | Preparation after | Atomic persistence before | Persistence after |
| ---: | --- | --- | --- | --- |
| 1 | 88.5/91.6/106.2 | 88.4/91.0/114.8 | 2.0/2.8/3.0 | 1.5/1.7/1.7 |
| 3 | 267.2/274.4/293.4 | 266.5/270.8/285.0 | 2.6/2.8/3.4 | 2.3/2.6/2.6 |
| 6 | 514.4/527.8/535.9 | 515.0/538.2/538.7 | 3.8/4.4/4.6 | 3.5/4.7/5.3 |

Preparation and persistence variations are small and are **not claimed as improvements**. Their implementations retain the existing image-quality policy and atomic staging/rename. The substantial modeled queue improvement comes from releasing the POST lane during public verification, bounded at two concurrent public reads. Real savings depend on network/service latency and arrival spacing. An isolated guest has little scheduling benefit.

## Measured customer-response model

Node v24.16.0 executes the actual Worker and Apps Script entry points with in-memory Drive/Properties/Cache/Lock implementations. Every photo is a deterministic 300,000-byte signature-valid buffer; the receipt is 180,000 bytes. This exercises budgets/storage and rendering, not JPEG visual decoding. Origin delay is 15 ms and cache-put delay is 25 ms. Cold/warm durations include consuming the entire HTML body. Warm requests wait for background cache completion first. They do **not** measure browser paint, image decode, real first-byte transfer, Google latency, edge geography or an actual customer connection.

| Photos | Guests | Cold page before | Cold page after | Warm page before | Warm page after |
| ---: | ---: | --- | --- | --- | --- |
| 1 | 1 | 60.2/60.2/60.2 | 26.1/26.1/26.1 | 0.7/0.7/0.7 | 0.6/0.6/0.6 |
| 1 | 5 | 50.6/54.6/54.6 | 22.1/23.1/23.1 | 0.6/2.3/2.3 | 0.5/0.5/0.5 |
| 1 | 20 | 52.8/57.7/58.6 | 21.5/22.6/22.7 | 0.8/2.9/5.7 | 0.4/0.9/1.5 |
| 3 | 1 | 69.5/69.5/69.5 | 25.9/25.9/25.9 | 1.6/1.6/1.6 | 0.6/0.6/0.6 |
| 3 | 5 | 66.1/79.7/79.7 | 27.5/29.5/29.5 | 1.5/2.4/2.4 | 0.7/0.7/0.7 |
| 3 | 20 | 65.3/73.6/102.6 | 27.7/29.0/29.6 | 1.1/2.1/2.7 | 0.5/0.6/0.7 |
| 6 | 1 | 86.4/86.4/86.4 | 36.4/36.4/36.4 | 3.5/3.5/3.5 | 0.9/0.9/0.9 |
| 6 | 5 | 87.1/92.4/92.4 | 36.7/36.9/36.9 | 2.2/7.2/7.2 | 0.9/1.4/1.4 |
| 6 | 20 | 80.5/85.4/94.3 | 36.6/38.7/51.7 | 1.5/2.9/3.3 | 0.8/1.3/3.1 |

The measured cold-response improvement includes moving the simulated 25 ms cache write outside the response path. Extra differences include local allocation/GC/clone effects and are not attributable to a remote-service improvement. No warm-cache speedup is claimed: its architectural path and one-hour completed-page cache namespace remain unchanged. Background cache work still consumes resources; it is postponed, not eliminated. Cold/warm total run times, request bytes, HTML bytes, local CPU timings and individual mock operation counts for all nine cells are in the JSON evidence.

Across each upload + readiness + cold customer page, permanent index writes fall **3 → 0**, Properties reads **7 → 5**, with identical HTML/transfer byte counts in this model. Creation counts and validation/inspection work are preserved. Real Drive operations were not timed.

## Implementation and safety

- Swift media is loaded once after acquiring the token lease, rather than once before queueing and again before transmitting. Verification/recovery uses metadata without reopening media; even an accepted gallery with unavailable local photo files can finish only when its exact public target verifies. Retain-state and queue-sweep checks no longer read all photographs. Save reuses one metadata decode rather than five; repeat saves still compare every byte to reject conflicts.
- A shared gallery disk actor runs delivery persistence, media loads, state writes, evidence writes and cleanup off the main actor. A recursive lock serializes these with existing synchronous operator metadata readers across store instances. Operator summary/configuration initialization APIs remain synchronous; this change targets the blocking delivery path rather than rewriting unrelated reporting stores.
- Atomic photo/metadata staging and final directory rename still precede every transmission. Ambiguity is persisted before POST, and accepted state before releasing the transmission lane. The process-wide scheduler keeps one owner per token through verification, including joined/cancelled callers, one POST lane, and at most two public reads. A third accepted upload can wait for verification capacity while retaining the POST lane, bounding both memory and public-origin work.
- Fresh traffic may take at most two queued slots before the oldest eligible recovery job. Sequential recovery yields between results so an older item can claim its fair slot. Recovery deadlines, Retry-After and operator-attention classifications remain.
- `.posted` recovery is GET-only. Uncertain deliveries first reconcile the frozen public URL; existing same-token, locked backend idempotent repair remains for unreconciled incomplete attempts. No replacement token/folder or concurrent same-token POST is created. Local failures after successful public verification cannot fall through toward POST. Navigation cancellation never releases a live owner.
- Ready requires public completion with the persisted identity/schema/file count (or the historical completed-page fallback), followed by local proof. Failed, stale, malformed, rate-limited and incomplete responses retain the queue. Print history and report sync are not operational gates. Printer/payment/camera/rendering implementations were not changed.
- Schemas 1–4, receipt variants and derived monochrome behavior, historical GIFs, frozen QR URLs, auth, image signatures, byte budgets, duplicate/unexpected-file rejection, global Drive mutation locking, idempotency and conflict handling remain. The incomplete-repair path reuses its first manifest object but still performs independent post-repair inspection/manifest validation.
- Guest stages now include Preparing, Uploading, Processing, Verifying, Ready. Preparing follows image preparation; Uploading starts at network dispatch; Processing means the POST response has arrived and its acknowledgement is being validated; Verifying is the actual public check. Ready follows saved proof and cleanup. Processing does not pretend to know remote server progress. Token guards prevent an older guest changing the current guest’s stage.
- Worker completed-page writes use `waitUntil`; missing contexts use a safe awaited fallback. Failed cache reads/writes cannot invalidate valid gallery HTML. Pending, invalid, malformed and readiness responses never enter the completed HTML cache. Completion markers quoted inside scripts/comments or truncated markup are not cache evidence. Existing valid completed entries and HEAD handling remain.

## Instrumentation

Native `GalleryPerformance` logs use fixed stage names, monotonic elapsed time, numeric sizes and outcome flags: image preparation, durable persistence, disk load, metadata writes, scheduler queue wait, Base64 encoding, JSON encoding, POST (including failure), response validation, public verification (including failure), and total delivery attempt. No photo contents, paths, URLs, customer/session identifiers, gallery tokens or credentials are added to these performance records. Existing identity-bearing upload diagnostics were removed from this delivery log path. Timings are aggregate telemetry rather than a persistent per-customer trace.

Apps Script returns numeric upload timings and logs request-size-only summaries. Measurements cover validation, root/folder lookup, lock waiting (including busy outcomes), folder creation, each image create by ordinal, folder inspection, manifest read/create, and total Drive/POST work. Readiness logs inspection/manifest and each file-size operation even for unsuccessful checks; HTML rendering measures each asset read/Base64 operation and total output. Nested timings overlap and must not be added as independent costs. Error telemetry uses controlled classifications rather than underlying exception strings.

Worker `Server-Timing` and safe structured logs cover cache lookup, upstream fetch, body read, response total and separate background cache-write duration/outcome. The worker response metric excludes subsequent client network transfer and browser rendering. Upload response timing keys are whitelisted before native logging. No external analytics dependency or new telemetry service was added.

## PropertiesService quota findings

Google documents 500 KB per property store, and 50,000 consumer / 500,000 Workspace property read/write operations daily. A permanent key per gallery grows without bound and repeated completed-gallery property writes also consume daily quota. Exact exhaustion depends on existing configuration and actual key/value sizes; no production property inventory or cleanup was performed. [Google quotas](https://developers.google.com/apps-script/guides/services/quotas).

New index entries use the disposable Script Cache with a six-hour requested TTL, deduplicated writes and safe miss/failure fallback. Legacy permanent entries remain readable and are not bulk-migrated or rewritten. The cache is capped by Google at 1,000 items and may evict early, so it never establishes completeness or ownership. After eviction the original folder-name lookup and strict inspection remain available; old galleries may have a cold-lookup cost, which is not remotely measured here. Stale acceleration entries can self-heal; media/manifests/configuration are not deleted. [Google Cache reference](https://developers.google.com/apps-script/reference/cache/cache).

## Rejected or unproven alternatives

- **ImageIO JPEG writer rejected.** Ten paired encodes of the same normalized noisy image at nominal quality 0.78: baseline UIKit p50/p95/max 11.69/13.14/13.14 ms; ImageIO 11.62/12.41/12.41 ms. Bytes differ and median gain is negligible. Existing JPEG quality thresholds, adaptive resize policy and receipt encoding stay unchanged.
- **Advanced Drive writer not adopted.** The isolated experiment implements both `Drive.Files.create` and `folder.createFile` with identical bytes, alternating order and exact size/name/type/parent checks. Its local contract passes. There is no configured isolated Apps Script environment in this repository and no actual Google API run was performed; mock timing cannot choose a winner. The production writer remains DriveApp. Running the isolated script requires a separate project with Advanced Drive v3 enabled; no production service/scope/dependency was changed. [Advanced Drive service](https://developers.google.com/apps-script/advanced/drive).
- **Alternate image delivery not adopted.** Direct Drive/thumbnail URLs and per-image Apps Script requests have no measured advantage here and would alter authentication, request count, sharing, fidelity or historical delivery behavior. The existing self-contained gallery, browser File/object-URL cache and browser-derived monochrome receipts remain. No external image source, R2 or storage migration was introduced.
- **Removing inspection, shortening verification, optimistic readiness or parallel POSTs rejected.** These would weaken completeness/identity checks or put more pressure on the global Drive mutation lock.

Cloudflare explicitly supports post-response cache writes through `waitUntil`; completion is best-effort within runtime limits, so a missed write simply leaves the next request cold. [Cloudflare context reference](https://developers.cloudflare.com/workers/runtime-apis/context/).

## Validation

Full native validation (complete `PocketPixelsBoothTests` target, including XCTest, Swift Testing, WKWebView and hosted UI snapshots): **980 passed, 6 failed, 0 skipped**, 837.1 s; parameter-expanded device summary: 1,015 passed / 6 failed. All gallery, receipt, print, payment, session/recovery and snapshot XCTest cases passed. The six failing authentication tests reported missing Keychain access, including `errSecMissingEntitlement` (-34018), because this run used `CODE_SIGNING_ALLOWED=NO`. The SDK Security header confirms that code means a required entitlement is absent. No authentication implementation or credential was changed. A simulator-only ad hoc signed rerun of both affected suites passed **18/18**, including every failed case; the failed full-run evidence is retained. The XCUITest automation target was outside this validation pass. Backend validation: **323 passed, 0 failed, 0 skipped** across Gallery Worker (42), isolated experiment (1), Payments and Monitoring; Apps Script validation/storage/readiness/POST integration and synthetic browser-fixture generation passed. The Debug simulator/focused test builds and **unsigned iOS Release device build passed**. Ad hoc signing was a command-line override for the simulator-only authentication rerun; project signing, team, bundle identifier and credentials are unchanged. The build emitted existing actor-isolation warnings in unrelated code; the xcresult summaries report zero runtime warnings. Baseline: 16 focused native tests passed, Worker 39/39, Apps Script schema/storage/readiness suite passed. Initial implementation: 35 focused native tests passed. A subsequent simulator preflight launch failed before tests ran; booting the same simulator without erasing it resolved the infrastructure failure. The final disk-commit regression was then built and passed (three focused tests). A new POST-entry test initially lacked its local customer-front-door configuration; the fixture was corrected, with no production validation removed.

Coverage includes offline/lost connection, timeout/ambiguous response, cancellation and joined duplicate requests, accepted-state relaunch, exact/stale public identity/schema/count, malformed JSON, auth/rate limiting, incomplete and duplicate/conflicting Drive folders/files/manifests, verification failure, disk commit failure, retained media and retry deadlines. The relaunch regression verifies an acknowledged gallery without opening photo files, then accepts a distinct next guest identity. Existing close/acknowledgement/relaunch/next-operation, print durability, payment, session isolation, receipt and gallery browser tests run in the full native target. No test was disabled.

## Evidence and reproduction

- [Native baseline](../BuildArtifacts/GalleryPerformance/baseline-swift.json) and [native after](../BuildArtifacts/GalleryPerformance/after-swift.json): all nine cells, stage statistics and exact request bytes.
- [Backend/Worker baseline](../BuildArtifacts/GalleryPerformance/baseline-node.json) and [after](../BuildArtifacts/GalleryPerformance/after-node.json): all nine cells, full response statistics, transfer bytes, total durations and operation counts.
- [Validation summaries](../BuildArtifacts/GalleryPerformance/) and [commands, definitions and isolated experiment](../Tools/GalleryPerformance/README.md). Regenerated tracked synthetic screenshots/rasters were preserved under `DerivedData/gallery-generated-regression-artifacts` and their tracked originals restored. Raw xcresults/logs remain locally under `DerivedData/gallery-*.xcresult` and `/tmp/gallery-*.log`; synthetic browser fixtures are under `DerivedData/gallery-fixtures`.

## Remaining checks and limits

No live Apps Script or Worker was deployed or edited, and no production gallery or payment was created. Actual Drive file-operation/lock timings, real cold/warm customer loads, first visual paint, image decoding, first-scan cache-warm races and Advanced Drive versus DriveApp performance remain unmeasured. No production improvement in seconds is promised. One-run simulator/mock percentiles are local evidence only.

On the physical iPad: measure capture/receipt preparation and main-thread responsiveness under 1/3/6-photo sessions, memory/thermal behavior with a 20-session backlog, offline → relaunch → reconnect, lost POST acknowledgement, bounded verification overlap and old pending fairness on event Wi-Fi. Confirm old guest stages never overwrite the next guest/event, and verify the actual printed frozen QR opens the correct historical/current gallery. Confirm printed photo/receipt fidelity and acknowledge → relaunch → next guest/event with the printer attached, including an uncertain physical copy that must never automatically resend. Check real iOS/Android Save/Share, first paint and decoded image display. These checks cannot be qualified by an unavailable camera/printer or a synthetic network.

## GitHub main and CI follow-up

The owner subsequently requested the push to GitHub `main` and fixes for CI failures. The original local-only state in `validation.json` is retained as historical evidence; it does not describe the later publication status.

The previous main run [41042463113](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/41042463113) passed native UI and backend checks but failed one production test: `OperatorWorkspaceV4Tests/testOpeningBoothDoesNotCreateDraftAndReturningFromFooterKeepsLatestEdits`. The test assumed each legacy SwiftUI navigation redirect completed within 300 ms. Its exact destination/path assertions are retained, with a bounded five-second wait for those actual states. The gallery verification-capacity test also observes the first two started operations rather than assuming child-task scheduling order. These are test synchronization changes; no navigation, gallery delivery or authentication behavior was weakened.

The local focused build/test passed 13/13 workspace and scheduler tests; the previously failing navigation case also passed five consecutive iterations, with no retries on failure. CI now also runs the isolated Drive experiment contract test. The first pushed gallery run [41055039528](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/41055039528) passed backend checks and was deliberately cancelled before completing the iOS suites because the synchronization fix supersedes it. The follow-up commit runs the complete existing native UI and production targets, plus backend checks; no test is skipped or disabled. The final handoff records the verified commit and resulting CI run. [Production Gate runs for main](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/workflows/ci.yml?query=branch%3Amain).
