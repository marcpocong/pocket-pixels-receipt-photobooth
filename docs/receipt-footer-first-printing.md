# Footer-first receipt printing — 27 October 2026

**Current status: accepted and closed for this release.** The owner accepts the remaining **16–17 mm physical bottom gap** on `80-VI 80.C-z04-AA` and requested an end to further printer experiments. Footer-first printing, outgoing-only blank-row trimming and normal digital margins are retained. The unsuccessful paper-return controls are removed from Sample Print Studio; the probe and its tests remain under `DEBUG` as historical development evidence, excluded from Release. See the [final development handoff](development-handoff-2026-10-27.md) for the subsequent preview/copy fixes, CI repair and delivery verification.

The chronological record below preserves decisions and validation at each stage; statements about pending tests, installed diagnostic controls or deferred CI describe those earlier checkpoints.

The owner approved footer-first output as a code-only workaround for the reported approximately 20 mm blank area above the receipt. The owner confirmed the top was acceptable, initially reported 12 mm at the bottom, then corrected that measurement to **16–17 mm**. That physical gap has not been eliminated.

The digital-margin follow-up restores normal digital margins for Black & White, Thermal Raster, gallery images and Photos exports. Only the outgoing receipt packet removes wholly white bottom rows, retaining every ink row and leaving **zero programmed blank bottom rows**. This could save only the preceding build's remaining 1–1.375 mm of digital blank space, not the full reported physical gap. A supported G80 paper-return/cut feature has not been confirmed. No printer setting has been changed.

The earlier compact-header fix (`fd45f91`) is still present. Before this change, the current sample pipeline produced first ink at 34 dots / 4.25 mm across six formats and three footer styles, with no leading feed. Production heading/feed/cut bytes had not changed since the initial app. These facts do not establish the cause of the additional blank paper.

## Behavior

- Receipt packets discard only entirely white rows below the last ink row, then rotate the retained 576-dot raster by 180 degrees without scaling or redithering. The footer prints first and the header prints last, beside the final cut. Blank paper already between head and cutter consequently appears at the bottom when the receipt is held upright. A wholly blank raster retains its valid original height.
- Receipt finishing now sends only the existing `GS V 66 0` feed-and-partial-cut command. It omits the three additional line feeds, which would otherwise become extra top space in the new direction. The rendered header border stays intact.
- `PrintJobEnvelope.receipt` applies this to live customers, operator samples, archived reprints and receipt qualification jobs, before fingerprinting and transport. Bluetooth and Wi-Fi transmit the frozen envelope. The older direct Bluetooth receipt entry points use the same preparation.
- Newly composed receipts restore the 28-dot digital bottom padding and normal sample canvas. Stored receipts, upright previews and exports keep their reading orientation and digital border. Newly rasterized receipts are sanitized in both orientations before their preview is generated, preserving exact preview pixels. Older archived rasters are rechecked after trimming/rotation; any newly exposed real-time command patterns receive the existing one-bit safety correction in the outgoing copy only. Stored archives and previously uploaded gallery copies are not rewritten.
- Packet height, raster byte counts, sanitizer offsets, fingerprints and transport duration estimates describe the cropped paper copy. Source raster dimensions and digital exports are not modified by preparing or sending a print. Photo/text diagnostics retain their original canvas and commands.
- Photo/text connection diagnostics retain their existing output. No persistent printer command, reverse-feed command, firmware setting, printer utility, new dependency, bundle ID change or signing configuration change is involved.
- Print recovery, audit gates, reporting and automatic retry behavior are unchanged. No physical job was sent during these checks.

Epson's [ESC/POS cut-command reference](https://download4.epson.biz/sec_pubs/pos/reference_en/escpos/gs_cv.html) describes the difference between print and cutter positions and the feed-and-cut command. This is a protocol reference, not proof of G80-specific margins or reverse-feed support. A smaller top margin is expected with the new direction; a physical measurement is still required.

## Validation

- Simulator build-for-testing passed after the implementation and after adding regression coverage.
- 78 focused tests passed, 0 failed, 0 skipped, on the iPad Pro 11-inch simulator with iOS 26.5. Coverage includes all six sample formats × three footer styles, pixel-level rotation with asymmetric edge marks and an odd height, legacy archive sanitation, preview fidelity, copy payload stability, print durability, no automatic retries after uncertain sends, and standard/co-branded layouts.
- Release compilation for the iPad device SDK passed. The signed Release build then passed using the existing automatic signing configuration with provisioning downloads allowed. `codesign --verify --deep --strict` passed, with the original `com.pocketpixels.PocketPixelsBooth` bundle ID and team `PQ26682725`. Project signing was not edited.
- `git diff --check` passed. Validation artifacts are under `/tmp/PocketPixelsFooterFirst*`, including `Tests.xcresult`, `TestsBuild.xcresult` and `DeviceCompile.xcresult`.
- At the owner's request, the signed build was installed over the existing app on Carlo's iPad Pro 11-inch (4th generation), device `00008112-000D08463E8BC01E`, and the normal production app launched successfully. No uninstall, data reset, fixture launch or physical print was performed. Existing app data was retained by the in-place update; it was not separately audited in this installation.
- Paper testing and failed CI-run repairs are deferred at the owner's request. No G80 paper output has been measured for this change.

## Paper acceptance

After installing the new build, print one standard Sample Print Studio receipt. Confirm the footer emerges first, then turn the completed paper upright and measure from the cut edge to the first header ink. Confirm the full header is intact. Repeat with one event-branded sample and inspect the QR/photos. A second consecutive sample checks the paper position left by the preceding cut. Do not automatically resend any existing customer copy with an uncertain print outcome.

This moves the mechanical blank area; it does not claim to eliminate all blank paper or guarantee a particular physical margin before testing.

## Bottom-border follow-up

The owner tested the installed build and confirmed the top is acceptable, but reported that the approximately 20 mm area is still awkward at the bottom. That confirms the direction workaround is insufficient for the requested appearance; it does not establish how much of the remaining paper is mechanical clearance.

Read-only inspection of the preceding run's exported raster PNGs measured **69 entirely white rows / 8.625 mm** below the last ink in all six standard display samples. A standard guest receipt had **31 white rows / 3.875 mm**. This is digital blank paper in addition to any printer-added clearance.

The follow-up reduces the composer's bottom border from 28 to 8 dots and removes the hidden identifier block and its preceding gap from display samples. Samples no longer reserve the length of an identifier they do not print. Guest receipts retain their visible support identifier. All other content positions stay the same; the composed image, smooth preview, thermal preview and print raster shorten together. Previously stored archive rasters are not rewritten and keep their original rendered borders.

Savings compared with the first footer-first build: **60 dots / 7.5 mm for standard samples**, and **20 dots / 2.5 mm for newly composed guest receipts**. The final raster checks measure 8–11 white rows / **1–1.375 mm** at the bottom of samples, depending on footer style, and 11 rows / **1.375 mm** for guest receipts. These are digital borders, not a promise that the physical bottom margin will reach 1 mm. Supported G80-specific reverse-feed/top-margin behavior remains unverified; no speculative motion or persistent configuration command was introduced.

The follow-up simulator build and signed Release device build passed. Strict codesign verification passed. **88 focused tests passed, 0 failed, 0 skipped**, including all six formats × three footer styles for both sample and guest bottom borders, visible guest identifiers, sample preview dimensions, pixel rotation, legacy archives, footer layouts and print reliability. Results: `/tmp/PocketPixelsCompactTailTests.xcresult`; build: `/tmp/PocketPixelsCompactTailDevice.xcresult`.

The smaller-border signed Release build was installed in place on Carlo's iPad and the normal app launched successfully. Installation and launch logs: `/tmp/PocketPixelsCompactTailInstall.log` and `/tmp/PocketPixelsCompactTailLaunch.log`. No printer setting was changed. At installation, paper measurement was pending; the owner subsequently reported the 12 mm bottom gap described above. CI repair remains deferred.

## Digital-margin separation follow-up

The owner confirmed approximately 12 mm still remains on paper and requested balanced digital copies. The compact shared canvas from the preceding change was therefore superseded: previews/exports keep their normal border, while outgoing packets alone trim blank bottom rows all the way to the final ink. This does not clip content or claim a zero physical margin. The final cut command remains `GS V 66 0`; no undocumented return-feed or persistent configuration command was added.

The signed Release build and strict codesign verification passed, preserving bundle ID and signing. **106 focused tests passed, 0 failed, 0 skipped** (`/tmp/PocketPixelsDigitalMarginsTests.xcresult`). Coverage includes all six formats × three footer styles, zero programmed paper tail, intact guest IDs and pixels, restored digital borders, smooth/thermal/gallery image geometry, repeated copies, older archives, blank inputs, sanitation offsets and actual outgoing byte counts. Black & White and Thermal comparison PNGs were visually inspected with balanced margins.

The signed build was installed over the existing app on Carlo and the normal production app launched successfully, with no uninstall or data reset. Logs: `/tmp/PocketPixelsDigitalMarginsInstall.log` and `/tmp/PocketPixelsDigitalMarginsLaunch.log`. No physical print was sent by this agent. The new paper margin remains unmeasured. CI repair remains deferred.

## Corrected measurement and controlled paper-return diagnostic

The corrected **16–17 mm** figure is the owner's physical measurement, not a measured software margin. Further cropping of the current outgoing image would remove ink. The measurement is consistent with head/cutter clearance, but it does not prove that the G80 firmware lacks a paper-saving capability.

A separate, manual diagnostic is installed under **Print Display Samples → Paper Return Compatibility Check**, below the sample printing controls. It has two explicit button actions and no automatic printing or retry:

1. **A** starts with a black bar at raster row zero, then sends ESC/POS `GS V 104 0` (`1D 56 68 00`), the documented partial-cut-and-return operation on supported Epson models. G80 support is unverified. Observe the paper; stop if A does not cut or the paper catches.
2. Remove A, then print **B** without using Feed. B has an identical row-zero bar and canvas size, and finishes with the ordinary `GS V 66 0` operation. Compare the top edge to the first bar on A and B. A smaller gap on B would be evidence that this firmware actually returned paper.

Both are independent `.diagnostic` jobs through the existing audited spooler and integrity transport. Guest-session, busy, unresolved-send and recovery gates still apply. Each button is limited to one attempt per screen presentation. No production receipt command, saved printer setting, digital margin, gallery behavior or customer record is changed by preparing the diagnostic. A BLE/TCP success is not proof of return-feed support.

The simulator build, signed Release device build and strict codesign verification passed. **51 focused tests passed, 0 failed, 0 skipped** (`/tmp/PocketPixelsPaperReturnTests.xcresult`), covering both marker-strip packets, command separation from ordinary receipts, pixel/margin integrity, print reliability and sample policy gates. The signed build was installed in place on Carlo and launched normally (`/tmp/PocketPixelsPaperReturnInstall.log`, `/tmp/PocketPixelsPaperReturnLaunch.log`). No physical diagnostic has been sent by the agent. G80 support and the physical margin remain unverified until the owner observes A/B. CI repair remains deferred.

## Physical diagnostic result and firmware identity

The owner reports that **A did not cut; cutting occurred only after B**. The repeated approximately **23 mm bar-to-bar measurements** are the test artwork's fixed 184-dot spacing, not an edge-to-ink margin or evidence of reduced paper clearance. Therefore this run does **not** demonstrate paper-return support. The tested `GS V 104 0` command did not perform the required cut-and-return operation on this printer. Do not repeat the test on this G80 or adopt that command for ordinary receipts based on this result.

The owner supplied model/firmware text **`80-VI 80.C-z04-AA`**. Exact-string and related-model research did not establish a primary command manual for this firmware, an OEM identity, or a supported alternative return command. Similarly named printers are not treated as matches. The remaining physical margin remains **16–17 mm as reported**, and a manufacturer-specific solution is still unverified. No firmware update, persistent printer setting, undocumented alternative command or automatic resend was performed.

The diagnostic UI previously enabled B on transport completion. The follow-up now requires explicit observation that A cut as a separate strip without paper catching. A reported no-cut/catch or transport failure stops that diagnostic run and blocks B and repeats. Stale completions cannot revive it. This confirmation governs only the optional diagnostic; normal receipt/session recovery and history gates are unchanged. The UI also explains that the 23 mm bar spacing is fixed artwork.

The corrected simulator build and signed Release device build passed, strict codesign verification passed, and **47 focused tests passed, 0 failed, 0 skipped** (`/tmp/PocketPixelsPaperReturnGateTests.xcresult`). New regressions cover transport success without physical confirmation, a reported no-cut/catch stopping both further sends, positive observation allowing B once, transport failure, stale completion rejection and no automatic retry. Production receipt recovery and command behavior remain unchanged. The signed build was installed in place on Carlo and launched normally (`/tmp/PocketPixelsPaperReturnGateInstall.log`, `/tmp/PocketPixelsPaperReturnGateLaunch.log`), without uninstalling, resetting data or sending a print. CI remains deferred.

Manufacturer documentation needed for the next step: **VOZY G80, self-test text `80-VI 80.C-z04-AA`; ordinary `GS V 66 0` cuts, while `GS V 104 0` prints but does not cut; approximately 16–17 mm remains before the first raster row despite no programmed blank rows. Is there a documented per-job paper-return or paper-saving cut operation for this exact firmware, and does it support the installed partial cutter without changing persistent settings?** No manufacturer message has been sent by the agent.

## Final owner acceptance and development handoff

The owner accepts the remaining **16–17 mm** bottom gap and requested no further printer investigation. The paper-return controls are retired from Sample Print Studio; only `DEBUG` evidence code/tests remain. Footer-first printing, outgoing-only blank-row trimming and normal digital borders are the accepted baseline. The final release also restores empty sample placeholders, fixes Regular Booth/private-prepaid copy authorization, and repairs CI execution budgets. The signed app is installed in place on Carlo. [The final handoff](development-handoff-2026-10-27.md) records full validation, source/test locations and CI history. No printer setting or firmware change, manufacturer message, further physical probe or automatic resend is pending.
