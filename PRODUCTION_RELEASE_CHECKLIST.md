# Pocket Pixels Production Release Gate

Qualify the exact signed release-candidate build on the intended iPad and VOZY G80. Automated checks are necessary but do not replace this hardware run. The booth mount supports upright portrait and one controlled landscape-right orientation; upside-down and the opposite landscape orientation are intentionally disabled.

## Automated gate

- Xcode build-for-testing and the complete XCTest suite pass on an available iPad simulator.
- Session isolation/recovery, receipt/raster regression, Passport, Event Header, Event Typography, and print durability suites pass without disabled or weakened assertions.
- Cloudflare Worker tests and Apps Script pure validation checks pass.
- Release build introduces no new warnings in modified code.

## Mandatory physical release-candidate qualification

- Complete at least 100 sequential real sessions across Solo, Duo, every Grid format, and Passport.
- Exercise Event Artwork with transparent PNG, JPEG, and single-page vector PDF; use multiple typography presets and long event text.
- Print 1, 2, 3, and 5 copies, plus several 10-copy stress runs; verify exact counts and serialized jobs.
- Run rapid back-to-back customers and a multi-hour continuous booth operation.
- Disconnect BLE before bytes and during bytes; power-cycle the printer; run the recovery text-test workflow; test paper-out/reload.
- Background/foreground and force-quit/relaunch around receipt composition and uncertain print status.
- Remove Wi-Fi/internet, accumulate a gallery backlog, restore service, and verify backlog recovery.
- Generate a large burst of repeated completed-gallery scans and confirm edge-cache hits.
- Change event configuration between sessions and prove the earlier session remains frozen.
- Reprint an archived receipt after active settings change and compare it with the original frozen output.

## Hard pass criteria

There must be zero wrong-customer or stale photos, malformed receipts, duplicate prints, unexpected automatic reprints, incorrect copy counts, cross-session leakage, unsafe continuation after unknown print state, unrecoverable printer state, or archive/reprint corruption.

Record the app commit SHA, signed build number, iPad model/iPadOS, VOZY G80 identifier/firmware if available, transport mode, paper stock, start/end times, session count, and operator. Balanced Bluetooth transport remains conditional on this exact physical qualification; Safe Integrity mode must remain available.

## Intentionally outside this phase

- Operator PIN
- A new privacy/consent/retention framework
- Cloudflare R2 migration
