# Customer gallery read performance — 11 November 2026

## Scope and release

Base: latest fetched `main`, `aaa56146bebfb101e29cc62ad1b03707f3e223ee`.
Production was independently confirmed as Apps Script **31**, backend
`made-to-keep-gallery-v10-resumable-20261111`, and gallery Worker
`ef02c41b-ca24-47aa-bf9b-8630929da2c2` at 100%. Source/configuration rollback
snapshots are retained privately outside Git. No customer capabilities, media,
Drive IDs, credentials, or session identities are included in this record.

Deployment details and final live samples are recorded below after activation.
The native application, bundle ID, signing, payment/printer/camera/session logic,
resumable uploads, upload journals and frozen customer URLs are unchanged.
`ResumableUploads.gs` is byte-identical to the production-31 source.

## Findings and selected implementation

A live three-photo origin request took **9.321 s TTFB / 10.033 s complete** for
**2,788,434 decoded HTML bytes**. Independent cold Worker requests were **9.742 /
14.607 s** and **9.902 / 12.368 s**, both MISS; their edges were SIN and NRT.
They were different regional caches, so the second request is not a warm result.
A persistent SIN connection then produced HITs: fresh connection **0.458 / 1.404 s**,
reused connection **0.119 / 0.302 s**, then **0.123 / 0.273 s**. Wire sizes varied
slightly with compression, about 2.062 MB. DNS/TCP/TLS and cache/timing headers are
preserved in the sanitized JSON evidence. These are individual live observations,
not controlled latency percentiles or an estimate of global cache hit ratio.

Staged numeric instrumentation separated origin costs on the same private gallery:

| Stage | Serial Drive / Utilities | Parallel Drive + local encoding |
|---|---:|---:|
| Validated folder + manifest | 1.475 s | 1.569 s |
| Drive media reads (five files) | 4.250 s serial | 1.290 s parallel |
| Base64 conversion | 1.173 s | 0.259 s |
| All media preparation | 5.423 s | 1.549 s |
| Total Apps Script render | 6.943 s | 3.166 s |

These are live staged executions, each one observation, with exact original-asset
comparison. The intermediate parallel-only experiment rendered in 5.427 s; it
still spent 2.279 s in Utilities encoding. This justified the small local encoder.
There is no claim that lookup time improved. Google startup/redirect, transfer,
regional differences and service variability remain outside these render timings.

The renderer batches media GETs through the **existing** server-side Drive REST
permission. IDs come exclusively from the fully validated folder/manifest. Size
mismatch, HTTP failure or missing REST capability falls back to the established
DriveApp path, per asset. Completeness/identity checks and render budgets remain.
A bounded local encoder handles signed bytes and standard Base64 padding without
another conversion service boundary; original bytes and MIME/name mappings match.

The old browser script could execute only after receiving and parsing every image
inside one enormous `galleryData` literal. The raw public representation now sends
small descriptors and working navigation first, then individual original assets,
photos before receipts. Each original occurs once. Photo actions become available
as their own bytes arrive; Download All waits for all photographs. The receipt-style
controller owns receipt validation and selection, including stale-selection guards.
Decoded previews retain placeholders until load and cannot start a duplicate load.
Consumed asset script nodes are removed. Lazy File/object-URL caching remains.

No separate public asset endpoint, thumbnail storage, image re-encoding or new
processing service was introduced. Gzip already removes most Base64 transfer
inflation; the measured improvement comes from origin work and critical-path
scheduling. A metadata-only response with separate media requests could further
reduce initial bytes but needs a new authenticated/cache-coordination protocol and
additional cold origin work. It was not adopted without end-to-end evidence.
Full originals still transfer on every uncached page; offscreen network lazy loading
is not claimed. Hero photographs are delivered first at original quality.

The Worker retains completed-only one-hour caching and uncached readiness. Its
bounded transient coordinator shares the same gallery/origin request while rendering
or writing the optional cache, including readiness warming. Independent bodies avoid
one visitor consuming another's response. Pending/errors are never stored; failure
releases the entry. This is **per isolate**, not a cross-region or distributed lock.
The internal namespace changes; customer URLs and production bindings do not.
Cache warming never gates a successful readiness response. Query-string redaction,
no-referrer, noindex and the existing security headers stay enabled.

## Controlled browser comparison

Real macOS WebKit at 390×844; identical seeded 960×720 JPEGs (~385 KB/photo), gzip
HTML paced over loopback. 8 Mbps and 1.6 Mbps are network simulations. No mobile CPU,
Google startup, DNS or cellular radio is modeled. The same final runner/probe was
used for both versions. One sample per cell, not a statistical mobile benchmark.
Times below are navigation-relative **first decoded photograph in the viewport**,
polled on animation frames. GPU presentation/decoder CPU are not separately timed.

| Profile | Photos | First photo before → after | All photo previews before → after |
|---|---:|---:|---:|
| 8 Mbps | 1 | 0.555 → 0.467 s | 0.555 → 0.467 s |
| 8 Mbps | 3 | 1.338 → 0.422 s | 1.388 → 1.188 s |
| 8 Mbps | 6 | 2.514 → 0.413 s | 2.568 → 2.363 s |
| 1.6 Mbps | 1 | 2.734 → 2.023 s | 2.734 → 2.023 s |
| 1.6 Mbps | 3 | 6.622 → 2.022 s | 6.670 → 5.921 s |
| 1.6 Mbps | 6 | 12.471 → 2.023 s | 12.540 → 11.723 s |

The six-photo gzip response is **2,490,509 → 2,490,925 bytes** (about +0.017%);
decoded HTML is **3,331,746 → 3,335,334 bytes**. Total page completion stays near the
transfer bound: at 1.6 Mbps **12.468 → 12.471 s**. This is earlier usability, not a
claim of a smaller total download. After six photos at 1.6 Mbps, first-photo actions
were ready at 2.023 s; Download All at 11.723 s; receipts at 12.490 s. Gallery-link
controls initialized at 0.107 s instead of 12.471 s. First-photo Save/Share still
perform synchronous File preparation on the user's click, preserving native sharing.

FCP was already early: six photos, 8 Mbps **16 → 26 ms**, slow **16 → 22 ms**.
LCP improved **2.528 → 0.428 s** (8 Mbps), **12.484 → 2.040 s** (slow).
A first-run one-photo FCP outlier rose 17 → 112 ms; no universal FCP improvement is
claimed. Heartbeat gaps were generally 51–59 ms, with one 95 ms first-run outlier.
No Long Tasks entry type or JS heap measurement is available in this WebKit build.
New WebContent process peak RSS is recorded, including caches; individual samples
are noisy. Typical six-photo RSS was 78.4 → 65.5 MB; one slow six-photo sample grew
74.6 → 142.9 MB. This is not proof of a persistent leak or a memory improvement;
physical-device memory pressure remains unqualified. After consumed-script cleanup, a focused final slow six-photo check recorded
**58.4 MB peak**, **2.031 s first photo**, **11.743 s all photos**, **12.508 s page
load** and **2.040 s LCP**. It ran alongside a simulator build (108 ms maximum
heartbeat gap); timings are in the separate final JSON. The full table above is
the preceding controlled matrix. Final gzip size is 2,490,966 bytes (+0.018%).

The original live page also ran in a real WebKit viewport: TTFB **0.259 s**, FCP
**0.354 s**, first photo **1.157 s**, all photos **1.182 s**, LCP **1.168 s**.
Its original HTML/body sizes matched the live origin. Post-release live results
are recorded below. These naturally vary with network and edge cache state.

## Maintainability and verification

Apps Script global functions now have cohesive files: routing/upload/validation in
`Code.gs`; presentation in `GalleryPresentation.gs`; design in `GalleryStyles.gs`;
browser behavior in `GalleryClient.gs`; progressive packaging in `GalleryDelivery.gs`;
server-only media reads/encoding in `GalleryMedia.gs`. `ResumableUploads.gs` stays
unchanged. There are no ES imports or top-level order-dependent initializers.
Production deploys all seven `.gs` files with the original manifest. Local harnesses
load the same globals. Worker coordination is isolated in `origin-coordination.js`.

Validation executed:

- Apps Script pure/storage/index/readiness suite, schemas 1–4, 1/3/6 photo delivery
  ordering and exact bytes; historical GIF manifests, stored smooth B&W, historical
  raster derivation, Share-Friendly / As Printed variants and privacy behavior.
- Parallel REST identity/size and partial/total failure fallbacks; no credential/ID
  disclosure. Base64 coverage: all octets, signed bytes, padding, 12,288-byte chunk
  boundaries and a large fixture; staged originals match exactly.
- Worker **45 passed**, resumable **6 passed**, isolated Drive contract **1 passed**.
  Includes eight concurrent cold visitors → one mock origin render, warm/scan/write
  race, token isolation, pending→complete, absent/failed cache, redirects/login errors,
  security headers and HEAD. These counts are controlled local evidence.
- Payments **224 passed**, monitoring **57 passed** as one integrated backend gate.
- iPad simulator build succeeded without signing/bundle changes. Existing browser
  suite initially had 9 passes / 2 failures. Fixed duplicate delayed loads and the
  receipt-controller bypass; four affected tests then passed, including progressive
  partial arrival and receipt style/lightbox/action races across mobile/desktop widths.
  The same four focused tests passed after the final script-node cleanup.
- Synthetic screenshot inspected at 390 px. No redesign or missing controls observed.
- Worker Wrangler production-config dry build passed. No iPad install or deployment.

The hosted Actions account was already blocked before job execution. Its latest
pre-change runs had no executed steps. Final push status is checked once; no billing
settings are changed and blocked jobs are not repeatedly retriggered.

## Rollback and limitations

Restore **Apps Script 31 on the same existing deployment**, then restore Worker
`ef02c41b-ca24-47aa-bf9b-8630929da2c2` or deploy its exact source with a fresh rollback
cache namespace to bypass any newer cached HTML. Both representations are self-contained,
so cached newer documents remain functional during rollback. Preserve existing route,
origin, manifest, execution identity, properties, credentials, folders and all media.
No migration/deletion is involved. Temporary staging deployments are retired only after
production verification; the versioned sources remain available.

Physical iOS/Android devices, actual native OS share sheets, venue Wi-Fi, background
memory pressure, global cache hit ratios and cross-region warming are not qualified.
Browser sharing is covered with iOS/Android feature-detection stubs and original-file
assertions; it is not a claim of a physical Android Chrome test. Existing legacy
workers.dev DNS reachability remains an infrastructure limitation independently of
token/schema compatibility. No recurring infrastructure cost, dependency or subscription
was added. Request coalescing is best effort within an isolate and normal cache misses
always retain authoritative origin validation/fallback.

Evidence: [sanitized measurements and selected synthetic screenshot](../BuildArtifacts/GalleryReadPerformance/README.md).

## Production activation and post-release evidence

Released backend/Worker source:
[`4dd9c642f7711550f53021401fa1c29956bf8dc4`](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/commit/4dd9c642f7711550f53021401fa1c29956bf8dc4).
Apps Script **38** is active on the original deployment, with backend
`made-to-keep-gallery-v11-progressive-20261111`. The versioned source was compared
byte-for-byte with that commit, including the unchanged production manifest and
resumable source. Worker **`6d0f62f1-19ee-4468-be76-f460b713a2df`** is active at 100%.
The original Worker settings matched exactly after allowing only the new release
message annotation. Origin, bindings, routes, compatibility date, workers.dev,
preview settings and query-string redaction are preserved.

Live post-release browser observations on the same existing three-photo gallery:

| Metric | First miss | Subsequent warm visit |
|---|---:|---:|
| TTFB | 5.214 s | 0.218 s |
| FCP | 5.241 s | 0.385 s |
| First visible photograph / photo actions | 9.340 s | 0.712 s |
| All photo previews / Download All | 16.787 s | 1.053 s |
| LCP | 9.356 s | 0.728 s |
| Complete page | 18.779 s | 1.044 s |
| Receipts ready | 18.804 s | 1.060 s |
| Worker response processing | 4.923 s | 0.021 s |

The first response's Server-Timing contains upstream work (4.025 s plus 0.866 s
body read), confirming an actual miss. The warm response has cache lookup only.
Its browser-compressed body was about 1.761 MB; curl negotiated a different gzip
representation around 2.062 MB. A separate served-page comparison confirmed all
five original photo/receipt payloads exactly match before release. Production origin
instrumentation recorded **3.207 s** render, **1.230 s** parallel media reads and
approximately **0.303 s** encoding. No image quality was traded for speed.

Compare live cold TTFB **9.742 → 5.214 s** and warm browser first photo **1.157 →
0.712 s**, with the limitations of unpaired, naturally varying live samples. There
is **no matched pre-release cold browser-paint sample**. Live cold total completion
was **14.607 s before (curl) versus 18.779 s after (WebKit)** on different clients
and transfers; it did not
improve in these observations. Do not label that transfer variation a controlled
regression or claim a total-load win. Controlled paced browser results isolate the
much earlier photograph/control availability while total bytes remain similar.

Persistent-connection warm curl samples after release were **0.142 / 0.863 s** and
**0.244 / 1.303 s** (TTFB / complete), with SIN HITs and 7/6 ms cache lookups.
The pre-release comparable observations were 0.119 / 0.302 and 0.123 / 0.273 s.
These show variable transfer/network conditions, not an improved warm server path.
The first fresh post-release connection alone spent 1.099 s in TCP connection setup.

Production diagnostics, completed readiness, invalid-link 404, and a missing valid
capability's pending page passed. Pending remained BYPASS/no-store; readiness and
errors remained no-store. noindex/nofollow, no-referrer and nosniff were verified.
Several public Google/Worker requests timed out during diagnosis; failed transports
were recorded as failures, never fast-gallery results. Focused retries completed
successfully without changing production data or availability rules.

The existing pre-release completed schema-4 gallery passed live; local schema 1–4,
historical raster, receipt-style and GIF-manifest checks passed. Two previously saved
legacy test capabilities returned pending in staging; they do not prove historical
completed-gallery rendering. Broader old Drive-manifest enumeration was unavailable
through the CLI credential's Drive access. No permissions were widened to obtain it.
Physical iPhone/Android and older real-gallery qualification remain limitations.

Temporary staging deployments were retired after production checks. Their versioned
sources remain available; production 38 and rollback 31 remain intact. No temporary
owner diagnostic is in HEAD or production. The Swift diagnostic accepts version strings generically and the uploader selects
resumable transport by the unchanged advertised protocol, so no native interface
change was required. No native app was redeployed.

GitHub's latest pre-change backend annotation explicitly stated: **“The job was not
started because your account is locked due to a billing issue.”** Final hosted status
is reported with the final push; no failed job is manually retriggered. Executed local
gates and sanitized production/browser evidence are the verification record.
