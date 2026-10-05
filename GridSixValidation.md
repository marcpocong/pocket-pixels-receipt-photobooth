# Grid 6 validation and device checks

Grid 6 captures six separate normalized portrait photos and prints them in two columns and three rows. Existing format raw values, capture generation guards, frozen event profiles, receipt composition tasks, upload identity, archive raster reprints, and print transport remain in place.

## Receipt dimensions

These values come from `ReceiptComposer` layout plans and composed receipts, using 8 dots/mm. Raster width is **576 dots = 72 mm = 7.2 cm**, on 80 mm paper. Each grid tile uses the existing Grid dimensions: 272 × 362 dots, with 8-dot horizontal and vertical gaps. Grid 6 adds one 370-dot row to Grid.

| Configuration | Raster, dots | Raster, mm | Raster, cm |
| --- | --- | --- | --- |
| Pocket Pixels header, QR footer | 576 × 1511 | 72 × 188.875 | 7.2 × 18.8875 |
| Pocket Pixels header, metadata footer without QR | 576 × 1346 | 72 × 168.25 | 7.2 × 16.825 |
| Pocket Pixels header, maximum-length event text, QR | 576 × 1717 | 72 × 214.625 | 7.2 × 21.4625 |
| No Header, maximum-length event text, QR | 576 × 1596 | 72 × 199.5 | 7.2 × 19.95 |
| Custom header at maximum printed height and spacing, maximum-length event text, QR | 576 × 1906 | 72 × 238.25 | 7.2 × 23.825 |

Maximum-length fixtures use every receipt event field at its limit, filled with wide `W` characters, and include the event date. The custom-header fixture uses a tall image, the 220-dot printed-height cap, maximum scale, and 48-dot top and bottom spacing. Values describe these tested maximum configurations; actual event wording and header proportions can produce shorter receipts. All combinations stay below the 3500-dot safeguard.

For sleeve sizing, the 72 mm value is raster width, while the paper is 80 mm wide. Raster length excludes additional blank paper produced by the printer's feed/cut commands; measure actual cut receipts before ordering sleeves.

## Validation

- `xcodebuild -list` completed with scheme `PocketPixelsBooth`.
- Application build and build-for-testing completed successfully.
- Full `PocketPixelsBoothTests` suite: 80 tests passed, 0 failed, 0 skipped, on iPad Pro 11-inch (M5), iOS 26.5 simulator.
- The existing 1000-session contamination test passed without weakened assertions.
- Native SwiftUI selection/review screenshots were rendered in XCTest at 834 × 1194 and 1194 × 834 points and visually inspected. Five cards fit in both orientations; review shows all six images and retake controls with Continue visible. The landscape review places controls beside the photo grid.
- Complete receipt and thermal receipt QR decoding, deterministic rasterization, all header/event-text/QR combinations, six-image offline queue round-trip/retry, archive raster/thumbnails/reprint count, recovery counts 0...6, and real view-model sample sequence/reset were verified.
- `node Backend/GoogleAppsScript/GridSixValidation.test.cjs` passed. It exercises existing counts, six expected filenames, validation of the sixth image, and rejection above six.
- No new compiler or SwiftUI layout warnings remain. Existing compiler warnings in untouched print audit/coordinator/session code and Xcode's AppIntents metadata notice are outside this feature.

The custom-header maximum-scale test exposed an existing overflow: scale 1.35 produced a 702-dot frame on a 576-dot receipt. `EventHeaderImageProcessor` now caps width at the existing printable region; standard/default-scale header output stays unchanged.

## Backend rollout

The checked-in Google Apps Script backend previously rejected more than four photos. Its maximum is now six, retaining schema version 1, filenames, tokens, session identity and request semantics. The Cloudflare proxy has no four-image limit and needs no format-specific change.

**The live Apps Script deployment has not been updated or tested against Drive.** Replace its `Code.gs` with the checked-in version, run `runPocketPixelsSelfTest`, and update the existing versioned Web App deployment while preserving its deployment URL and script properties. Follow `Backend/GoogleAppsScript/SETUP.md`. Do this before using Grid 6 with live gallery uploads.

## Actual iPad / VOZY G80 checklist

No physical iPad camera or VOZY G80 validation was performed.

- Choose Grid 6; capture six photos and check Photo 1 of 6 through Photo 6 of 6, countdown, delay, and camera restart/cancellation.
- Inspect the two-column, three-row review in both orientations; retake each position and verify Continue stays visible.
- Compose and inspect the full color/thermal receipt, including the third row and footer.
- Scan the printed QR; confirm the deployed gallery contains all six correct images. Check offline upload/retry too.
- Print one copy and multiple copies; check identical photos, thermal quality, feed/cut length and printer recovery behavior.
- Test Custom Event Header and No Header, with Event Text Block both on and off.
- Reprint from Recent Sessions; start another customer and check that no wrong/stale photos, receipt or header settings appear.

## Files changed

- `PocketPixelsBooth/BoothFormat.swift`
- `PocketPixelsBooth/BoothConfiguration.swift`
- `PocketPixelsBooth/BoothSessionView.swift`
- `PocketPixelsBooth/ReceiptComposer.swift`
- `PocketPixelsBooth/EventHeaderImageProcessor.swift`
- `PocketPixelsBooth/GalleryUploadModels.swift`
- `PocketPixelsBooth/GalleryUploadTestView.swift`
- `PocketPixelsBooth/GalleryUploadDebugSelfChecks.swift`
- `PocketPixelsBoothTests/CustomerExperienceTests.swift`
- `PocketPixelsBoothTests/EventHeaderTests.swift`
- `PocketPixelsBoothTests/ReceiptAndRasterRegressionTests.swift`
- `PocketPixelsBoothTests/SessionIsolationAndRecoveryTests.swift`
- `Backend/GoogleAppsScript/Code.gs`
- `Backend/GoogleAppsScript/GridSixValidation.test.cjs`
- `GridSixValidation.md`

The initial tree was clean and local/main matched `e3ef79a`. Bundle ID, signing, dependencies, camera implementation and print transport files were not changed.
