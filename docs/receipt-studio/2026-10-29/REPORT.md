# Receipt Studio visual editing refinement — 29 October 2026

Baseline: local and fetched remote `main` both `8f3236ffe1a83887a378e4ee2d3387e89c6f4ea4`; working tree initially clean.

## Changes

- Preserved the existing two-pane editor and draft/checkpoint lifecycle. Header / Footer / Text remain visible, including at accessibility text sizes.
- Added in-memory editor geometry from the exact production composition plan. Focus changes only the existing image viewport, never the renderer, photo processing, or printer raster.
- Header framing uses measured wordmark, separator and logo bounds, retaining neighboring context. Viewport height follows the focused content. Full Receipt retains fit-width scrolling, pinch and double-tap zoom.
- Direct single taps select the actual rendered header elements and route to Header controls even from another section. UIKit handles zoom/scroll coordinate conversion; exact bounds win over expanded 44-point touch targets. Accessible preview targets and explicit selection controls remain available. Single selection waits for double-tap recognition.
- Selection outlines are UIKit layers only. Saved PNGs, exports, archives, galleries and print jobs never include them.
- Default target is Made to Keep. Logo thumbnail, replacement and removal remain available regardless of selection. Size, movement and reset controls are contextual; Whole Header, overall size/position, spacing, Center & Fit and Reset Header live in Layout & Spacing. Reset Header keeps imported artwork.
- Position feedback compares resolved element centers with the recommended header for the same artwork. Directional enablement compares actual candidate frames, with concise margin/gap explanations. Size ranges are resolved through production frames to exclude clamped plateaus; a completely unresponsive slider is disabled with a “Fitted to space” explanation. Top spacing respects the production engine's eight-dot minimum without changing legacy saved values on entry.
- Footer framing includes the measured QR/barcode, monogram, timestamp and associated content. Text has explicit event-detail, title, subtitle, date/location, message and caption targets; unprinted text is explained. Field focus and typography changes select relevant text regions.
- Thermal Raster remains the default; smooth Black & White and Print Sample remain directly accessible. A deterministic sample QR uses a reserved invalid domain and is labeled as having no live gallery.
- Extended the synthetic photograph's background gradient across both endpoints and made its canvas opaque. Customer photograph processing is unchanged.
- Retained debounce, cancellation and render-generation checks. The last valid image survives updates and errors; manual full-receipt focus, zoom and pan survive ordinary changes.

## Validation

The focused runs passed 43 distinct unit tests and six distinct simulator UI tests. Carlo also passed the full staged-design acceptance UI test (83.1 seconds). The existing Production Gate workflow, signing settings, bundle identifier, orientation, persisted design models, receipt drawing/layout calculations, thermal processing and printer pipeline are unchanged.

No real event is activated or ended, and no physical print is requested during validation.

### Passing coverage

| Suite / checks | Tests |
| --- | ---: |
| Receipt Studio: framing, exact hit testing through zoom/pan, viewport preservation, element moves/resets, replacement, nonresponsive size ranges, sample opacity and every format | 9 |
| Co-Branded Receipt: legacy geometry, independent movement, margins, collisions, scaling and raster coverage | 19 |
| Printed Footer modes and all formats | 9 |
| Printed session identifier regressions | 4 |
| Frozen session artwork and archived reprint artwork | 2 |
| Simulator UI: staged editing, new-event save/reopen, accessibility, pinch/pan/double-tap, shared header controls and PIN boundary | 6 |
| Carlo: real portrait SwiftUI staged-editing flow, direct taps, resizing, movement, manual Full Receipt zoom persistence, Footer → preview → Header routing, Done, reopen and relaunch persistence | 1 |

Result bundles (local): `/tmp/pp-studio-regression-final.xcresult`, `/tmp/pp-studio-routing-acceptance.xcresult`, `/tmp/pp-studio-final-verification.xcresult`, `/tmp/pp-studio-size-validation.xcresult`, `/tmp/pp-studio-carlo-acceptance.xcresult`.

- Final signed Debug build: **BUILD SUCCEEDED** (`/tmp/pp-studio-final-build.log`). Original bundle `com.pocketpixels.PocketPixelsBooth`, team `PQ26682725`, version 1.0 / build 3 retained.
- Installed in place on Carlo, iPad Pro 11-inch (4th generation), using `devicectl device install app`. The normal application package was installed again after UI verification to remove testing-only embedded bundles.
- Preservation audit after installation and physical UI testing: all **3,528 original protected files** remained present. **3,527 SHA-256 hashes matched** exactly; `OperatorWorkspaceV1/setup.json` had identical decoded JSON with serialization-key ordering differences only. No original file content changed. The fixture added temporary staged-test records and a new immutable synthetic logo. No uninstall, container erase, Keychain reset, or real guest/event operation was performed.
- Physical screenshots were exported from Carlo's successful XCTest result and visually inspected. Text focusing was additionally inspected on the portrait simulator.

### Portrait evidence

- [Carlo — selected event logo](carlo-event-selected.png)
- [Carlo — selected separator](carlo-separator-selected.png)
- [Carlo — complete footer](carlo-footer.png)
- [Simulator — edited subtitle](simulator-text-focus.png)

### Scope and limits

Physical acceptance used an isolated staged design through the real Session Setup → Customize Receipt entry point and production preview path. It did not edit CIM INTRAMS or any real saved event, activate/terminate an event, contact payments, or issue a physical print. The preview QR is an illustrative code with no live gallery. Physical paper quality was not retested because no print was authorized.

Production Gate configuration is unchanged. The implementation and Xcode 16.4 compatibility follow-ups are on `main`.

## CI follow-up

Run [40783333852](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/40783333852) confirmed both hosted Xcode 16.4 builds pass. The complete production suite passed all 945 tests. Native UI passed 24 of 27 tests; the three failures were investigated using its logs, screen recordings and accessibility hierarchy:

- Receipt inspector gestures queried the image while the screen still showed “Rendering receipt…”. The test now waits for the visible rendered preview and its scroll view before exercising the same gestures and zoom assertions.
- Historical archive/restore tapped Manage as the six-second success banner disappeared and shifted the list. The test now explicitly dismisses and waits for that banner before locating the restored row. Rename, archive, restore and cancellation assertions remain intact.
- The simulator-only active-guest fixture supplied the general setup blocker but omitted the separate End Event blocker. It now supplies both and isolates follow-up retention from normal simulator state. This failure reproduced locally before the correction. Production lifecycle and recovery behavior are unchanged.

The app and test targets were rebuilt after the corrections. The receipt gesture, historical rename/archive/restore, active-guest removal refusal and idle applied-event removal UI tests passed locally. No test is skipped, retried or disabled, and no workflow requirement is reduced. Hosted verification of the follow-up is reported separately.
