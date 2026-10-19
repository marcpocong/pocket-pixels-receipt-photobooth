# Gallery upload speed — October 20, 2026

Follow-up to `f3205d722f86bbf208b7abec703ded66c49f1545` on `feat/qr-gallery-receipt-styles`. The ending implementation commit is the commit containing this report. Remote main remains `7ab80c82ca7ac437bf3781a95434d86c16593325`; unrelated `.claude/` work is preserved.

## Changes

- Removed full-resolution JPEG encodes that existed only to estimate a diagnostic size. Photo preparation retains its exact existing dimensions, JPEG quality and adaptive size policy. The optional `originalDecodedBytes` diagnostic is now nil; real prepared byte counts remain accurate.
- Moved Base64/JSON request encoding off the main actor.
- New style-aware sessions use explicit **schema 4**: original and optional Share-Friendly color receipts remain authentic, privacy-safe composer output. Both smooth B&W PNGs are derived in the customer browser with the existing grayscale/tone-curve function. This removes one uploaded PNG and one Drive write. Manifest field `thermalReceiptDerivedFrom: "receipt-color.jpg"` makes that contract explicit. The two cards, filenames, selector and selected-file Save/Share/lightbox behavior remain intact. Browser derivation can require a brief preparation state; failure never substitutes a QR-bearing receipt for Share-Friendly.
- Schemas **1, 2 and 3** retain their stored assets and semantics. Durable old queues are decoded and uploaded as originally prepared. No gallery folder, completed manifest, print journal or customer record is migrated or deleted. Legacy preparation callers without style metadata continue using schema 2.
- Added a **readiness query through the existing public gallery domain**. It validates the complete manifest, exact file set, nonempty file sizes and unchanged render budgets, without loading image blobs or generating HTML. Worker JSON fields are whitelisted, identity checked, and responses are `no-store`, separate from the HTML cache. The app requires the persisted token/session/schema/file count before clearing its queue. Historical front doors that ignore the query still work through the original HTML-marker verification.
- Readiness schedules normal gallery HTML cache warming with `waitUntil`, outside the iPad's completion response. It checks for an existing completed HTML cache entry first. Customer gallery URLs and the one-hour completed-page cache namespace are unchanged. The first immediate scan can still arrive before warming finishes.
- Removed the second identical folder listing during gallery lookup; exact expected-file checks reuse the first inspection and still reject unexpected/duplicate/missing files. Upload mutation locks, idempotency and conservative retry handling remain.
- Added release-visible `GalleryPerformance` OSLog timings for image preparation, JSON encoding, POST response and public verification, plus Apps Script validation/lock/Drive/total milliseconds in the successful upload response. These logs contain durations and sizes, without tokens, credentials, photo contents or customer identifiers. POST timing includes transfer and server work; server timings separate those costs approximately.

## Measurements

The same synthetic noisy six-photo Grid Six/event-branding test:

| Measurement | Previous schema 3 | Schema 4 |
| --- | ---: | ---: |
| Decoded upload assets | 2,977,829 B | 2,632,016 B |
| JSON body | 4,032,443 B | 3,564,600 B |
| Extra stored B&W PNG | 345,813 B | 0 B |
| Image preparation | 0.612 s | 0.403 s |

JSON is **467,843 bytes / 11.6% smaller**. Prepared photograph bytes are asserted identical. Encoding measurements are from separate iOS 26.5 simulator runs and are not a controlled Carlo CPU benchmark or an end-to-end upload guarantee. No upload/render limit was raised.

One existing historical production gallery, using a standard curl client on the desktop network after deployment:

| Request | Response bytes | Elapsed |
| --- | ---: | ---: |
| Uncached Apps Script raw full gallery | 704,978 | 7.370 s |
| New public readiness | 225 | 3.625 s |
| Public HTML, initial cache miss | 704,978 | 7.706 s |

Both full documents contained the completed marker and two receipt cards; readiness matched the same gallery and schema 2. This is one sequential sample with variable network/service latency, not a before/after POST benchmark. Readiness avoids transferring the embedded images to the iPad. A Python client was rejected by Cloudflare's browser-integrity filter (1010); the standard curl client succeeded without overriding its user agent or changing security settings. Customer image content and gallery tokens were kept out of repository evidence.

## Validation

- Apps Script Node validation/storage suite passed, including schemas 1–4, partial repairs/retries, six schema-4 footer/default combinations, incorrect extra B&W uploads, derived manifest roles, budgets, exact-file rejection, and a readiness integration test proving **one folder listing and zero image-blob reads**.
- Cloudflare Worker: **39 passed, 0 failed**. New cases cover malformed identities/protocols, pending/unavailable responses, uncached JSON isolation, login HTML rejection, HEAD and background warming.
- Focused iOS 26.5 suites: **51 passed, 0 failed, 0 skipped**, `Test-PocketPixelsBooth-2026.10.20_01-25-03-+0800.xcresult`.
- iOS 27 browser matrix: **10 passed, 0 failed, 0 skipped**, `Test-PocketPixelsBooth-2026.10.20_01-31-51-+0800.xcresult`.
- Full iOS 26.5 suite: **706 passed, 0 failed, 0 skipped** (741 parameter-expanded executions), 580.95 seconds, no reported runtime warnings; `Test-PocketPixelsBooth-2026.10.20_01-26-57-+0800.xcresult`..
- Final Release-visible timing addition: **1 passed, 0 failed**, readiness/identity/queue test covering eight response scenarios on iOS 27, `Test-PocketPixelsBooth-2026.10.20_01-33-50-+0800.xcresult`. This recheck followed the final logging-only addition..
- Final simulator and signed device Release builds: passed with CI ad hoc simulator signing and the existing Apple Development identity/team for the device; final device signing time 1:34:48 AM Manila..
- Apps Script's Phase 6C self-checks also passed in the authenticated editor before deployment.

Synthetic schema-4 screenshot evidence: [phone and desktop](../BuildArtifacts/GalleryUploadSpeed/README.md). The original schema-3 before/after evidence remains unchanged in its earlier folder. Browser assertions cover all seven widths, smooth grayscale, rapid switching, errors, actions, touch targets, focus and historical galleries. Physical printing and payment implementations were not changed; no real transaction or print was performed.

## Deployment

| Component | State |
| --- | --- |
| Apps Script Web App | **Version 29**, October 20 at 1:29 AM Manila; same project/deployment ID |
| Backend version | `made-to-keep-gallery-v8-fast-upload-20261020` |
| Tested/saved source | 123,161 characters; matching full-text FNV-1a fingerprint `4079900871` |
| Previous Apps Script | Version 28, schema-v3 receipt styles |
| Gallery Worker | **`3b3bf21d-d108-413d-be07-732108a3d0df`**, existing `gallery` service |
| Previous Worker | `2d21941f-e3a5-4d34-84be-c2d9371e6414` |
| Host/cache namespace | `gallery.madetokeepstudios.workers.dev` / `made-to-keep-fit-20261018`, unchanged |

Worker deployed with `--keep-vars`. No credentials, Drive root, routes, app bundle ID, signing team or dependencies changed. Public diagnostic confirms the new Worker and v8 backend with healthy upstream HTTP 200. Production readiness and historical HTML were independently verified.

**Rollback:** version 28 cannot consume schema 4. Once this app creates new galleries, retain schema-4 read/write support when reverting other behavior. Reverting only the Worker restores full-HTML verification because it ignores the readiness query and still proxies gallery HTML. Do not delete or rewrite stored galleries.

## Carlo and limitations

Installed and launched in place on Carlo after the full suite passed. The existing bundle `com.pocketpixels.PocketPixelsBooth`, version 1.0/build 3, signing team `PQ26682725`, and Apple Development identity were preserved. A fresh private Library backup and screen capture confirmed the idle welcome screen, no unresolved checkouts, no recovery snapshot or queued gallery assets, and 267 locally delivered print-outbox entries. Post-launch comparison retained **all 3,247 files** outside caches/snapshots/HTTP storage, with none missing, added or changed; this includes Application Support records and preferences. The new app launched to the welcome screen. No uninstall, reset, container replacement, real print or payment occurred. Keychain contents were not independently inspected. Backups are under the private `speed-before/Library` and `speed-after/Library` folders.

A new synthetic production POST/public-gallery round trip and actual Carlo upload timing remain unverified. The new schema's storage/upload contract and browser behavior have been tested separately, and the live readiness route has been verified with an existing gallery. The release adds telemetry to measure real POST stages on future authorized sessions without changing their photos or payment/print behavior. Real iOS/Android share sheets, printer and camera hardware are not qualified by simulator tests.

Detailed local logs/result summaries are under locally excluded `TestResults/GalleryReceiptStyles/speed-*`; device safeguards remain outside the repository under `/Users/marc/.codex/attachments/gallery-receipt-style-release-private/`.

## Files changed

`GoogleDriveGalleryUploadService.swift` and `GalleryUploadModels.swift`; `GalleryDeliveryHardeningTests.swift`, `GalleryReceiptStyleTests.swift`, and new `GalleryUploadPerformanceTests.swift`; Apps Script `Code.gs` and `GridSixValidation.test.cjs`; Gallery Proxy `src/index.js` and `test/index.test.js`; this report; follow-up links in the preceding receipt-style report/screenshot index; `BuildArtifacts/GalleryUploadSpeed/README.md` and two synthetic screenshots.
