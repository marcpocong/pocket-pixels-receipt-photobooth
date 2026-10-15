# Made to Keep Studios — October 16 event readiness

**Verdict: NOT READY — BLOCKERS REMAIN for the updated candidate.** The October 15 physical
qualification is useful baseline evidence, but the changed guest screens/status-bar behavior
still need an authorized in-place install and a short physical smoke test. The legacy printed
hostname also needs investigation. No new physical print or financial transaction was made.

## Source and build

- Baseline: `9dfd258b9f1a808a075cf8a4a91095ccad878d77`; clean workspace and fetched `origin/main`
  matched at start. Existing Desktop repository/project only; no dependencies added.
- Implementation: `e931c90ad8b8076dd96f910ecd6e723e86b3a8e6`; final durable-attempt follow-up:
  **`25a90d82f654ebdf21fb2c2b99a7418fd1dfbce3`**. Subsequent documentation commits do not change the candidate.
- Signed candidate CDHash: `7418a91de54d8c5aa5cfa83b1bad9c1bed24129a`.
- Existing bundle `com.pocketpixels.PocketPixelsBooth`, version **1.0 (1)**, existing team and
  Apple Development signing preserved. Release product:
  `build/EventRelease/Build/Products/Release-iphoneos/PocketPixelsBooth.app`.
- Carlo is connected: iPad Pro 11-inch (4th generation), iPadOS **26.6.1**. Candidate not installed;
  existing app, protected container, operator settings, prices and customer data are untouched.

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
| Complete local iOS suite before final refinements | 513 passed, 0 failed, 0 skipped |
| Final UI / payment / browser / gallery regressions (`e931c90`) | 47 passed, 0 failed, 0 skipped |
| Durable-attempt / historical URL follow-up (`25a90d8`, separate iPad simulator) | 20 passed, 0 failed, 0 skipped |
| Signed Release build for Carlo, final candidate | Passed; no new warnings in changed production code |
| Apps Script pure validation/rendering | Passed, including old GIF manifests and still-only galleries |
| Gallery Worker | 29 passed, 0 failed |
| Payments Worker | 207 passed, 0 failed |

A second complete local run and GitHub Actions are checked separately in the final handoff.
[Production Gate runs](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/workflows/ci.yml)
identify the pushed SHA; do not treat a pending job as a pass. Pre-existing Swift actor-isolation
warnings remain in untouched operator/sample infrastructure; no gate assertions were relaxed.
Initial test iterations exposed a browser-load readiness race and debug fixture-host migration;
those fixtures were corrected. Browser checks also found undersized image-button targets,
which now have a 44px minimum. One overlapping local Release invocation hit Xcode's build-database
lock; it was rerun serially. No failing assertion was disabled or weakened.

Visual evidence uses synthetic images, never customer photos. WebKit and desktop Chrome checks
cover the requested widths, with additional phone/tablet landscape checks. Emulation does not
prove native iPhone Safari / Android Chrome share sheets or actual filesystem saving.
Existing recovery, payment, print checkpoint and receipt regressions are retained. See
[October 15 physical Mode B and owner-confirmed Mode C evidence](hardware-qualification/2026-10-15/REPORT.md):
100 live-camera sessions / 125 physical print jobs; omitted supervised drills remain separate.

## Live backend release

Production remains Apps Script **version 22**, backend
`made-to-keep-gallery-v2-optional-gif-20261009`, on the existing `/exec` deployment. The healthy
front door is `https://gallery.madetokeepstudios.workers.dev/`. The October 14 editorial source
was never deployed. Prepared source is `made-to-keep-gallery-v3-stills-20261016`.

The documented legacy `pocket-pixels-gallery.pocketpixels-ceb.workers.dev` returns NXDOMAIN from both 1.1.1.1 and 8.8.8.8. Historical-token compatibility passes locally, but hostname availability is not
proven. Authenticated Apps Script browser access and the exact existing deployment were inspected;
Cloudflare inspection reached existing-account sign-in. No deployment or credential change occurred.

Owner approval is required before updating the existing Apps Script deployment and verified
existing Worker(s). [Deployment and rollback instructions](gallery-redesign-deployment.md) preserve
version 22, all tokens, Drive data, authentication and URLs. No PayMongo deployment is needed.

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

- Approve in-place candidate installation while Carlo is idle. Never uninstall or erase its data.
- On Carlo: launch and transition through guest screens; verify hidden status bar, centered copies,
  Back/Cancel, camera, review/stickers, QR/receipt identity, one deliberately controlled print with
  exact copies, then return to welcome with no previous guest content. Use existing event settings;
  no live test payment without separate explicit consent.
- With a consented diagnostic session, disconnect/restore Wi-Fi and confirm queue recovery and
  phone access. Do not delete waiting galleries or interpret pending/unknown as lost.
- Authorize backend release separately; check a private historical link and diagnostic gallery,
  actual iPhone Safari / Android Chrome saving, both receipt views, and the legacy hostname.
- Configure/rehearse the kiosk checklist. Complete any still-required supervised physical drills
  from the production checklist; the new candidate is not hardware-qualified merely by building.
