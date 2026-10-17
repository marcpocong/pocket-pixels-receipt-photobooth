# Customer gallery release — October 18, 2026

The owner explicitly authorized implementation, production deployment and safe integration of the approved desktop/mobile QR gallery redesign. PR #7 was already merged at the integration base `08a277b213aabaad27a30aa3081763bb12b3963b`; its legacy and UUID-suffixed session ID validation is preserved.

## Active production release

| Component | Verified release |
| --- | --- |
| Public front door | `https://gallery.madetokeepstudios.workers.dev/` |
| Apps Script project | Pocket Pixels Gallery Backend, `1EdArbkIBJzbdyuyqrDcbp898FfudGv2TbrlFNNYrMoiAhkStzc7qJg5h` |
| Existing Web App version | **26**, deployed October 18, 2026 |
| Backend diagnostic | `made-to-keep-gallery-v5-fit-20261018` |
| Cloudflare account | `f4119288ab0fe1f5c0e2f37b86735236`, subdomain `madetokeepstudios` |
| Existing Worker | `gallery` |
| Worker release version | `2d21941f-e3a5-4d34-84be-c2d9371e6414` |
| Completed-page cache namespace | `made-to-keep-fit-20261018` |
| Implementation commits | `d5e65e9` (redesign), `709e335` (caption removal and image-fit correction) |
| Pull request | [#8](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/pull/8) |
| Official outbound Instagram destination | `https://www.instagram.com/madetokeep.studios/` |

The existing `/exec` deployment ID remains `AKfycbxFc4wpaRipbj-xEXt-zW6m5GoaJ1QkJtnw8Ryg4aH5rDeZDXXctXDTCWCWJwK1SwRSdQ`. Manage deployments confirmed execution as the existing owner and Anyone access before release. The editor's saved source was copied back and compared byte for byte against the tested `Code.gs` before publishing. No script properties, upload endpoint, credentials, folders, bindings, domains or routes were changed.

Apps Script was updated first in the existing deployment, its diagnostic verified, then the existing Worker deployed with cached Wrangler 4.151.0 and `--keep-vars`. A dry run passed. Live Cloudflare API comparisons confirmed the original origin binding, compatibility date `2026-10-08`, empty compatibility flags, observability, tail consumers, logpush, placement, tags and usage model were preserved. workers.dev remains enabled and preview URLs disabled. No payment Worker or iPad application runtime was changed.

Version 25 and Worker `5b2600ab-3f04-48ad-8281-e17528dcb136` initially released the redesign. The owner then requested removing “good people”, “same energy” and “little moments, big memories”, and reported cropped/oversized enlarged photos. Version 26 and the current Worker release implement that follow-up on the same endpoints.

## Implementation and design

The active `Code.gs` renderer now includes a compact branded header, accessible mobile menu, editorial hero with up to two actual gallery photos in Polaroids, gallery cards with timestamps and actions, directly visible receipt cards, Instagram promotion, captured-date/privacy strip and branded footer. A one-photo session uses one Polaroid. All three requested decorative phrases and their caption elements are removed; the brand tagline and Instagram copy remain. Enlarged images fill a bounded viewer stage with `object-fit: contain`, and the viewer height is set from the current viewport on opening/resizing. This fixes intrinsic-size overflow and WebKit’s first-open viewport sizing without changing original files. The full original photographs display without cropping; source image proportions affect page height.

Receipts stay paired at 400px and above and stack on narrower phones. The Instagram card reflows at smaller widths for readable text. System fonts, inline SVG icons and ornaments, warm ivory/burgundy colors and subtle paper surfaces follow the approved references. [Seven Chrome screenshots](../BuildArtifacts/GalleryRedesign/README.md) use synthetic assets and contain no customer images or live tokens. This is a responsive interpretation, not a claim of pixel-perfect equivalence across fonts and photograph proportions.

The official Instagram destination appears only in the completed gallery's menu and promotional card. Both links specify `target="_blank"`, `rel="noopener noreferrer"` and `referrerpolicy="no-referrer"`. There are no Instagram embeds, third-party scripts, fonts, trackers or remote photo resources. Tokens are never appended to this destination. The document and Worker retain no-referrer protection.

Save/Share preserve filenames, MIME types and original bytes. The primary bulk action stays visible: native multi-file sharing where supported, desktop download attempts with browser-permission guidance, and an individual-save navigation fallback on unsupported iOS browsers. Gallery sharing uses the current public origin and token, native Web Share or clipboard, and a manual-copy dialog when clipboard access is denied. It explicitly explains that anyone with the link can view the gallery.

## Validation

```sh
node Backend/GoogleAppsScript/GridSixValidation.test.cjs --fixtures
npm test --prefix Backend/CloudflareGalleryProxy
xcodebuild build-for-testing -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth \
  -destination 'platform=iOS Simulator,id=<available-iPad>' -derivedDataPath DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
xcodebuild test-without-building -project PocketPixelsBooth.xcodeproj -scheme PocketPixelsBooth \
  -destination 'platform=iOS Simulator,id=<same-iPad>' -derivedDataPath DerivedData \
  -only-testing:PocketPixelsBoothTests/GalleryBrowserLayoutTests -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
```

- Apps Script pure checks passed: counts 1–6, v1/v2, optional historical GIF storage, legacy/UUID IDs, image/render budgets, escaping, completed-page marker, front-door precedence, exact outbound allowlist, no external resources and privacy.
- **29/29 Worker tests passed**, including internal cache namespace, upstream validation, headers, authentication isolation, invalid/pending behavior and both front-door token contracts.
- Simulator application build and test build passed. Final scoped checks ran against `709e335`; the iPad runtime was unchanged by that follow-up. The initial remote application run on `d5e65e9` reported 673 passes and two gallery failures: a one-photo overflow at 375px and a fixture-navigation startup timeout. The latest caption-free design has no overflow at that width, and the fixture startup allowance is now 45 seconds with all navigation/readiness assertions retained. The full suite is rerunning against the final source; its final result is recorded below when complete. **5/5 WebKit tests passed**, including **54 count/viewport combinations**: 1–6 photos at 320/375/390/430/768/1024/1440/844/1194px. Tests cover original File metadata, native-share and download fallbacks, menu, legacy receipt, collage bindings, gallery URL/token sharing and copying, lightbox focus/navigation and an intercepted Instagram navigation with no Referer header. The new viewer regression adds **20 combinations** of portrait/landscape photos and both receipt versions across phone, landscape and tablet/desktop viewports, asserting that the entire image stays within the visible viewer.
- Chrome screenshots at 320/375/390/430/768/1024/1440px were reviewed and refined. WebKit's initial overflow findings were fixed; the final matrix has no horizontal overflow or undersized button targets.

## Production verification

- Apps Script `?diagnostic=phase6c` and public `?diagnostic=proxy` report the v5 backend, healthy upstream 200 and the existing raw proxy route.
- Three existing completed galleries on the current front door return the new design with dynamic photos and both receipts; two other known links retain pending behavior. No customer token or imagery is included in committed evidence.
- The Worker namespace change caused completed-page MISS responses followed by HITs, with the original `public, max-age=3600` policy. Random unused tokens return the branded pending state with cache BYPASS and no-store. Malformed tokens return a safe 404/no-store response.
- Production Chrome confirmed all photos and receipt previews load, Polaroids reuse the correct gallery images, the mobile menu opens/closes, the lightbox advances through photos, and the Instagram CTA opens the exact official profile without extra parameters. No gallery console errors were observed.
- Individual photo, color receipt and thermal receipt downloads were read from disk and compared with the embedded original data: exact byte matches. With multiple downloads permitted, both bulk-downloaded photographs also matched the originals. Chrome can restrict multiple downloads; the UI provides guidance and individual Save controls. Temporary clipboard and automatic-download permission tests were restored to their original Ask defaults.
- A production manual-copy dialog was observed with clipboard access denied. Native sharing and clipboard success branches are covered by WebKit stubs; real iOS/Android native share sheets were not exercised in this release.
- Production Chrome verified zero decorative caption elements and full-image containment on desktop and a 390×844 mobile viewport, including first-tap opening and next-photo navigation. The original 1056×1408 photo is fully visible; no gallery console errors were observed.
- Original embedded asset hashes were identical before and after the Worker cache switch.

## Rollback

For the caption/viewer correction alone, the immediately preceding release is Apps Script **version 25** and Worker **`5b2600ab-3f04-48ad-8281-e17528dcb136`**. Both remain available. The pre-redesign rollback is recorded below.

Before the initial redesign, the existing Apps Script Web App was **version 24** (October 17 reliability/session-ID update), not the older version 23 mentioned in historical notes. Restore **version 24** on the **same deployment** if rollback is necessary; retain its UUID session compatibility. Version 23 and version 22 remain older historical versions.

The verified previous Worker version is **`aabb760a-95e1-4964-b698-39c7aff376d6`**. Restore that version through the existing `gallery` Worker's deployment rollback in the same account. Recheck both diagnostics and a private consented historical link. No data migration or customer-file deletion is involved in release or rollback. Because Apps Script was released before the Worker cache switch, some entries in the former cache namespace can contain the newer HTML. If an urgent visual rollback must bypass those entries, revert Apps Script first, then deploy the known-good Worker source with a fresh internal rollback cache namespace and `--keep-vars`; keep customer URLs and bindings unchanged. Otherwise completed entries expire within the existing one-hour policy.

## Known limits

The legacy hostname `https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/` still returns **NXDOMAIN from both 1.1.1.1 and 8.8.8.8**, as it did before this release. The current authorized Cloudflare account uses subdomain `madetokeepstudios`; October 16 inspection found no legacy Worker in that account. Restoring the old hostname requires the account/routing that owns the former subdomain; renaming the current account would break the working front door and was not attempted. Historical tokens remain compatible on the current hostname, but this does not make old printed hostnames reachable.

Schema-v1 galleries with only the color receipt pass local rendering and WebKit checks; the three inspected live completed galleries all had both receipt assets. Physical iPhone Safari/Android share-sheet validation remains a device check. No physical printer/payment tests or device install were performed for this gallery-only release.
