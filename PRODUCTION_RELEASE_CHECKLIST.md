# Pocket Pixels Production Release Gate

Qualify the exact signed release-candidate build on the intended iPad and VOZY G80. Automated checks are necessary but do not replace this hardware run. The booth mount supports upright portrait and one controlled landscape-right orientation; upside-down and the opposite landscape orientation are intentionally disabled.

## Automated gate

- Xcode build-for-testing and the complete XCTest suite pass on an available iPad simulator.
- Session isolation/recovery, receipt/raster regression, Passport, Event Header, Event Typography, and print durability suites pass without disabled or weakened assertions.
- Cloudflare Worker tests and Apps Script pure validation checks pass.
- Release build introduces no new warnings in modified code.

## In-app Hardware Qualification (Operator → Advanced → Hardware Qualification)

The app ships a preprogrammed, operator-approved qualification tool. It supports the physical run below; it does not replace any item in it.

- Mode A · Software Simulation — mock transport, synthetic photos. Always reported as **SIMULATION ONLY**; never evidence of hardware.
- Mode B · Physical Printer Endurance — watermarked diagnostic photos through the production composer, raster, `PrinterCoordinator` and `PrintSpooler` to the real VOZY G80. Tests printer/paper/transport, not the camera.
- Mode C · End-to-End Physical Sessions — drives the production booth state machine with the real front camera for every session, Photo Pass details and signature entered by the operator on the real screens, real printing, diagnostic archive and reset.
- Default plan: 100 sessions, balanced round-robin over all six formats (16–17 each), separate 1/2/3/5/10/10-copy print-load sessions, a high-frequency block, a Grid 6/Strip multi-photo window, a frozen-configuration pair, supervised printer power-cycle and background/return drills, and a gallery-delivery attestation. Seeded and reproducible; the plan fingerprint is recorded.
- Safety: opens in simulation; physical runs need **Approve & Start Hardware Test**, bound to that run, plan, launch and receipt budget, renewed at each batch boundary (default 10 sessions) with an operator paper count. Every physical job re-checks customer session, printer ownership, unresolved print, recovery lock, connected transport, a durable pre-print checkpoint, and budget. An uncertain print halts the run, is never resent, and blocks customer printing until inspected. Relaunch marks a run INTERRUPTED and resumes nothing.
- Isolation: qualification sessions use `QA-` identities, an isolated diagnostic archive/recovery namespace, no gallery preparation or upload, and no event session counts. Cleanup is per run, requires typing the run code, and never touches customer archives, waiting galleries or unresolved prints.
- Verdicts: PASS only for a completed physical run with zero violations and every paper confirmation and supervised checkpoint satisfied; otherwise FAILED, INCOMPLETE, INTERRUPTED or UNVERIFIED. Export the text report and CSV via Share and attach them to the release record.

## Mandatory physical release-candidate qualification

- Complete at least 100 sequential real sessions across Solo, Duo, Grid, Strip, Grid 6 and Photo Pass — run Hardware Qualification Mode C (100 sessions) and attach its report. A Mode A or Mode B result does not satisfy this item.
- Verify on paper that every reviewed photo matches its print, including the Photo Pass upper card (approved as an upright portrait; printed a quarter turn on the sideways card).
- Exercise Event Artwork with transparent PNG, JPEG, and single-page vector PDF; use multiple typography presets and long event text.
- Print 1, 2, 3, and 5 copies, plus several 10-copy stress runs; verify exact counts and serialized jobs.
- Run rapid back-to-back customers and a multi-hour continuous booth operation.
- Disconnect BLE before bytes and during bytes; power-cycle the printer; run the recovery text-test workflow; test paper-out/reload. (Qualification only automates between-session power cycles; the during-bytes drill, paper-out and multi-hour operation remain manual.)
- Background/foreground and force-quit/relaunch around receipt composition and uncertain print status.
- Remove Wi-Fi/internet, accumulate a gallery backlog, restore service, and verify backlog recovery. Qualification never uploads; perform this with an approved diagnostic gallery.
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
