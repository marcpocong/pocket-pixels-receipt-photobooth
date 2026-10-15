# Made to Keep Studios — October 16 event readiness

**Verdict: READY WITH SPECIFIC LIMITATIONS for an attended event using the current Made to Keep
gallery host.** The signed candidate is installed on Carlo. Owner-confirmed guest-flow and
controlled camera/print/QR/reset checks passed; a fresh session also passed on iPhone Safari:
no Google sign-in, all photos and both receipts visible, and individual photo saving works.
Automated gates passed and both gallery backends are released. Configure/rehearse Guided Access
and Focus before opening. The legacy hostname remains unavailable; Android Chrome/native bulk
sharing and a physical offline-recovery drill remain unverified. An attendant must handle
connectivity failures, pending galleries and holders of old-host QR links.

## Source and build

- Baseline: `9dfd258b9f1a808a075cf8a4a91095ccad878d77`; clean workspace and fetched `origin/main`
  matched at start. Existing Desktop repository/project only; no dependencies added.
- Implementation: `e931c90ad8b8076dd96f910ecd6e723e86b3a8e6`; final durable-attempt follow-up:
  **`25a90d82f654ebdf21fb2c2b99a7418fd1dfbce3`**. Subsequent documentation/Worker configuration commits do not change the iPad candidate.
- Signed candidate CDHash: `7418a91de54d8c5aa5cfa83b1bad9c1bed24129a`.
- Existing bundle `com.pocketpixels.PocketPixelsBooth`, version **1.0 (1)**, existing team and
  Apple Development signing preserved. Release product:
  `build/EventRelease/Build/Products/Release-iphoneos/PocketPixelsBooth.app`.
- Carlo is connected: iPad Pro 11-inch (4th generation), iPadOS **26.6.1**. Candidate installed **in place and launched successfully** after owner authorization and confirmation
  that Carlo was at Welcome/idle. All 3,827 Application Support/Preferences inventory entries remain
  present with unchanged sizes. No uninstall, container deletion, price or settings edit occurred.
- Owner confirmed on Carlo: status bar hidden through Welcome → format → copies, centered copy
  selection, working Back and confirmed Cancel. Owner then confirmed a controlled nonfinancial
  session: camera/review, matching onscreen/receipt QR, exact selected print count and clean return
  to Welcome all passed. These are owner observations, not agent screenshots or unattended tests.

## Implemented

- Centered ivory/burgundy copy-selection composition at 834×1194 and 1194×834, configurable
  policy pricing/limits, large accessible quantity controls, Back and confirmed Cancel.
- Pre-checkout Back preserves identity. Unresolved/in-flight payments cannot be cleared by guest
  navigation or idle reset; conclusive policy rejection before order creation allows review again.
  Repeated Continue taps cannot create a second checkout transition.
- Large centered thank-you QR, sharp rendering and white quiet zone. Its frozen URL is also used
  for receipt composition and queue delivery; view rendering never creates a token. Truthful
  preparing/uploading/pending/help states; ready requires backend acceptance AND completed
  public-page verification. Starting another session clears visible photos/QR while queued tasks
  and durable customer payloads remain independent.
- No new gallery GIF generation, end-screen animated tile or guest motion selector. New payloads
  keep every JPEG and both receipts. Optional GIF schema/storage/legacy queue compatibility stays.
- Editorial customer gallery follows the supplied reference: wordmark, large serif headline,
  Save All Photos, refined rules, responsive photos and abstract static paper-strip ornaments.
  Historical GIFs are neither loaded nor presented; historical files are never deleted.
- Gallery preparation fails explicitly if durable storage is unavailable. Ambiguous responses,
  interrupted transfers and public-page verification failures retain payloads for idempotent retry.
  Every attempt is durably marked unknown before POST; checkpoint write failure prevents transmission.
  The verification read has an eight-second request/resource budget and never gates printing.
- Operator → Equipment → Gallery Setup now provides a read-only backend diagnostic and delivery
  explanation alongside existing waiting-gallery count, failure/retry and successful-worker status.
- Guest root requests hidden status bar and system overlays using public SwiftUI APIs. Camera,
  printer transport/spooler/rasterizer and payment production Worker are not refactored.

## Validation and limitations

| Check | Observed result |
| --- | --- |
| Complete local iOS rerun (`e931c90`, final UI/payment/browser source) | 515 passed, 0 failed, 0 skipped |
| Final UI / payment / browser / gallery regressions (`e931c90`) | 47 passed, 0 failed, 0 skipped |
| Durable-attempt / historical URL follow-up (`25a90d8`, separate iPad simulator) | 20 passed, 0 failed, 0 skipped |
| Signed Release build for Carlo, final candidate | Passed; no new warnings in changed production code |
| Apps Script pure validation/rendering | Passed, including old GIF manifests and still-only galleries |
| Gallery Worker | 29 passed, 0 failed |
| Payments Worker | 207 passed, 0 failed |

The complete rerun passed, followed by the 20-test queue-checkpoint follow-up for `25a90d8`.
GitHub Actions full UI-source gate `38794547032` and final candidate gate `38795453578`
passed, including iOS and backend. Final candidate CI ran **426 XCTest + 89 Swift Testing tests**
(515 total), with no failures. Worker configuration preservation also passed a Wrangler dry build.
Candidate-source run: [Production Gate](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/38795453578).
[Production Gate runs](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/workflows/ci.yml)
identify the pushed SHA; do not treat a pending job as a pass. Pre-existing Swift actor-isolation
warnings remain in untouched operator/sample infrastructure; no gate assertions were relaxed.
Initial test iterations exposed a browser-load readiness race and debug fixture-host migration;
those fixtures were corrected. Browser checks also found undersized image-button targets,
which now have a 44px minimum. One overlapping local Release invocation hit Xcode's build-database
lock; it was rerun serially. No failing assertion was disabled or weakened.

Visual evidence uses synthetic images, never customer photos. WebKit and desktop Chrome checks
cover the requested widths, with additional phone/tablet landscape checks. The owner subsequently confirmed fresh-gallery access, both receipts and individual photo saving
on actual iPhone Safari. Native bulk share sheets and Android Chrome saving remain unverified.
Existing recovery, payment, print checkpoint and receipt regressions are retained. See
[October 15 physical Mode B and owner-confirmed Mode C evidence](hardware-qualification/2026-10-15/REPORT.md):
100 live-camera sessions / 125 physical print jobs; omitted supervised drills remain separate.

## Live backend release

Owner-authorized release completed October 16 at approximately 04:14–04:16 Manila time:

- Existing Apps Script deployment updated **22 → 23**, backend
  `made-to-keep-gallery-v3-stills-20261016`. Same deployment ID and `/exec`, owner execution and
  Anyone access; source was copied back and verified identical before publishing.
- Existing `gallery` Worker deployed as **`aabb760a-95e1-4964-b698-39c7aff376d6`** with the new
  internal completed-page cache namespace. Live API comparison confirms unchanged bindings,
  compatibility date/flags, observability, tail consumers and logpush; workers.dev stays enabled,
  preview URLs disabled. The initial CLI deploy briefly disabled dashboard-only observability;
  it was immediately restored and explicitly captured in configuration before final verification.
- Public front door: `https://gallery.madetokeepstudios.workers.dev/`. Proxy diagnostic is healthy,
  upstream 200 and recognizes v3. Native Apple URLSession returns branded invalid (404) and
  random unused-token pending (200), without Google sign-in or completed-page false positives.
- A private historical gallery opens after release with its completed marker and new editorial
  page; its photo, color receipt and printed receipt load. The printed receipt lightbox opens
  and closes. No GIF image is loaded. No private token or customer image was put in source/reports.
- Owner confirmed the fresh controlled-session QR on **iPhone Safari** after release: no Google
  sign-in, all photos and both receipts present, and photo saving passed. This confirms the new
  session delivery path by owner observation; it does not attest Android Chrome or bulk sharing.
  Automated backoff/ambiguity tests pass; a physical disconnect/restore upload drill remains
  unperformed.

The legacy `pocket-pixels-gallery.pocketpixels-ceb.workers.dev` returned NXDOMAIN from both
1.1.1.1 and 8.8.8.8 before release and remains unavailable. Authenticated account inspection
confirms subdomain `madetokeepstudios`, existing `gallery` Worker, no custom domains and no legacy
gallery Worker. Renaming this account would disrupt the working front door; no rename occurred.
Historical tokens work on the current host, but old-host QR availability is **not restored**.
Attendants must assist holders of such old links; do not advertise that hostname for this event.

Python's user agent receives Cloudflare 1010; native Apple URLSession and Chrome public reads work.
No Cloudflare security setting or credential was changed. No PayMongo deployment occurred.
[Deployment and rollback instructions](gallery-redesign-deployment.md) retain Apps Script **22**
and Worker **`c5ccf383-0010-48f1-9fd7-0eb17679078c`**. No data migration/deletion is involved.

## Carlo kiosk setup — operator actions

1. Settings → Accessibility → Guided Access: enable, set a private operator passcode and enable
   Face ID for ending/pausing it. Keep that passcode available to authorized attendants.
2. Open the booth full-screen; triple-click the top button → Guided Access → Options/Session
   Settings. Keep **Touch and Software Keyboards ON**, with no masked control areas, so Photo Pass
   and operator recovery still work. Restrict unwanted top/volume-button use; set Motion according
   to the mounted orientation. Avoid an event time limit; choose suitable Display Auto-Lock.
3. Start; test that Home/app switching is restricted. Rehearse exit: triple-click top button,
   authenticate, then End. Confirm attendant Face ID/passcode access in the actual kiosk setup.
4. Settings → Focus → Do Not Disturb: allow no ordinary people/apps, review repeated-call,
   time-sensitive and intelligent-breakthrough exceptions, then enable it in Control Center for
   the event. Review app critical-alert/emergency exceptions separately.
5. Set brightness, power and enclosure clearance; keep Wi-Fi/Bluetooth enabled. The app keeps
   the display awake while active. Test camera, payment connectivity and printer under Guided Access.
6. System permission/authentication, battery, thermal and other mandatory alerts can still appear.
   This app cannot universally block notifications. An attendant must remain available.

These are manual settings, not app-enforced notification blocking or MDM. References:
[Apple Guided Access](https://support.apple.com/en-us/111795),
[Apple Focus setup](https://support.apple.com/guide/ipad/set-up-a-focus-ipad2789d162/ipados),
[SwiftUI status bar](https://developer.apple.com/documentation/swiftui/view/statusbarhidden(_:)),
[SwiftUI system overlays](https://developer.apple.com/documentation/swiftui/view/persistentsystemoverlays(_:)).

## Remaining owner actions before accepting guests

- With a consented diagnostic session, disconnect/restore Wi-Fi and confirm queue recovery and
  phone access. Do not delete waiting galleries or interpret pending/unknown as lost.
- Test Android Chrome and native bulk share sheets where available. Resolve the unavailable
  legacy hostname separately without
  disrupting the current front door. Historical gallery/receipt reads on the current host passed.
- Configure/rehearse the kiosk checklist. Complete any still-required supervised physical drills
  from the production checklist; the new candidate is not hardware-qualified merely by building.
