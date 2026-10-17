# Portrait operator finalization — October 18, 2026

Carlo is mounted vertically. Portrait remains the primary operator layout; landscape is secondary. The existing four-button portrait navigation and persistent Return to Booth control remain in place.

## Follow-up changes

- Home and Reports statistic cards use two columns at the mounted 11-inch iPad portrait width. Wider layouts can use four columns; large text keeps measured, wrapping row heights.
- Session Setup → Guest Experience now includes **Edit Device Gallery Code**, beside the displayed device default. It opens the existing Branding & Design settings and preserves staged setup edits.
- The device Gallery Code Style uses an explicit menu containing Integrated Gallery QR, Classic Barcode + Gallery QR, and Decorative Barcode Only. Saving the preference still uses the existing settings store and notifications; returning to setup reloads the displayed default and preview.
- Device defaults affect future sessions immediately; per-event overrides remain staged until the existing review/start flow. Opening settings does not change any footer mode or activate an event.

## Recovered release evidence

PRs #8, #9 and #10 are already integrated into main `84a0eb8f74ee408ddb18b80071ab1a5fecb42000`. The earlier session installed a signed Release of that exact source on Carlo in place. Its independent XCTest results record successful normal authentication, four-section portrait navigation, report tabs, setup-stage restoration, Return to Booth, and a separately asserted landscape/history check. The initial automation-permission timeout is retained as a failed attempt; successful retries have their own results.

The earlier container comparison retained all 3,247 persistent files, including byte-identical customer archives, artwork, event/design records, payment and print journals. Keychain values were not independently inspected. These are baseline-release facts, not claims that the follow-up is already installed.

## Validation and release record

The follow-up simulator build passed; all 49 focused setup/draft/footer/render tests passed on iOS 26.5 with zero failures, skips, or runtime warnings. Fresh synthetic portrait screenshots show the two-column statistics and the gallery-code edit link in [OperatorDashboardV2](../BuildArtifacts/OperatorDashboardV2). Mandatory Production Gate checks must pass before merge. A signed in-place installation, final source/CI results, device review, and preservation comparison are recorded only after completion in the local release report at `/Users/marc/Desktop/OperatorDashboardV2-Release-2026-10-18.md`.

No camera, printer transport/raster, receipt renderer, cloud service, bundle ID, signing or dependency change is included.
