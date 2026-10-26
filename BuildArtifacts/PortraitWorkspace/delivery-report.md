# Delivery record

## Final 27 October handoff

The owner accepts the remaining **16–17 mm G80 bottom gap** and has closed the investigation. Normal digital margins and footer-first, paper-only blank-row trimming remain. The failed cut-and-return controls have been retired from the sample screen; the probe is retained only under `DEBUG`. The final change also fixes empty sample placeholders and multi-copy authorization for Regular Booth/private-prepaid events, while retaining purchased-copy limits.

Use the [current development handoff](../../docs/development-handoff-2026-10-27.md) for implementation, tests, signed installation and the CI repair. The old shared iOS job exceeded its 60-minute limit; the complete UI and production suites now have separate runners and a required aggregate check. [Production Gate on main](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/workflows/ci.yml?query=branch%3Amain) records the exact delivered commit's result.

The sections below are historical checkpoints. Their deferred/pending statements and descriptions of installed diagnostic controls do not describe the final build. Named raw logs and full container comparisons remain local; [the evidence index](README.md) identifies the curated, versioned evidence.

## 27 October: code-only top-gap workaround

Physical compatibility result: the owner reports **A did not cut; only B cut**, and supplies printer identity **`80-VI 80.C-z04-AA`**. The 23 mm bar-to-bar measurements are the diagnostic's fixed graphic spacing. The tested paper-return command did not perform its required cut-and-return operation and is not enabled for ordinary receipts. No supported alternative for this exact firmware has been verified; the physical 16–17 mm margin remains unresolved. The diagnostic now requires explicit clean-cut observation before B and stops on no-cut/catching, rather than treating transmission success as a physical cut. **47 focused tests**, simulator build, signed Release build and strict codesign passed. The correction was installed in place on Carlo and launched normally. Normal printing, digital margins, customer data and printer settings are unchanged. No further physical diagnostic was sent by the agent; CI remains deferred.

Measurement correction and next hardware check: the owner remeasured the remaining bottom gap as **16–17 mm**, superseding the earlier 12 mm estimate. The outgoing raster still has zero programmed blank bottom rows. A manual **Paper Return Compatibility Check** is now installed under Print Display Samples, below the print controls. Strip A tests the per-job ESC/POS cut-and-return command; strip B measures the next print start and ends with the normal cut. This is unverified on G80 and is never selected by ordinary receipts. Both strips require explicit button presses, use diagnostic audit identities, honor existing operational gates and never auto-retry. No saved printer setting, preview/gallery margin or customer record was changed. **51 focused tests**, signed Release build and strict codesign passed; installed in place on Carlo and launched normally. No physical diagnostic was sent by the agent. The owner must observe the cut/feed and compare A/B gaps before any reduction can be claimed or enabled for normal receipts. See [test instructions and evidence](../../docs/receipt-footer-first-printing.md).

Latest follow-up: the owner reports **12 mm** still remains on paper and requested normal digital margins. Black & White, Thermal Raster, gallery and Photos images now retain the normal receipt canvas; **only outgoing print packets trim all entirely white bottom rows** before footer-first rotation. There are zero programmed bottom blank rows in the packet, with all ink preserved. Packet dimensions, byte counts, sanitizer offsets and fingerprints reflect the shortened paper copy. Stored archives and previously uploaded images are not rewritten. **106 focused tests passed**, signed Release/codesign passed, and both preview styles were visually checked. This build was installed in place on Carlo and launched normally. The remaining physical gap is unresolved; this removes only the prior build's remaining 1–1.375 mm of digital blank space. No printer setting or CI run was changed.

Follow-up after the owner's paper test: the top is acceptable, but the approximately 20 mm gap at the bottom remains awkward. A second change now removes the hidden sample session-ID area and reduces rendered bottom padding from 28 to 8 dots. Standard samples shorten by **7.5 mm**, and newly composed guest receipts by **2.5 mm**. Final digital bottom borders measure **1–1.375 mm** across all six formats and three footer styles. All **88** focused tests and the signed Release build passed. The signed build was installed in place on Carlo and the normal app launched successfully; paper measurements are still pending. Printer settings and CI runs remain untouched. Full removal of any remaining printer-added gap is unresolved.

The owner approved footer-first receipt output. A new implementation rotates receipt packets by 180 degrees and omits the three extra line feeds before the existing feed-and-cut command. It covers live receipts, samples and archived reprints while keeping previews upright. All 78 focused regressions passed; simulator and signed device Release builds passed, along with strict codesign verification. At the owner's request, this build was installed over the existing app on Carlo's connected iPad and the normal production app launched successfully. No uninstall or data reset occurred. No printer setting was changed and no physical print ran. Paper testing and failed CI-run repairs are deferred at the owner's request; the resulting paper margin remains unverified. See [implementation and paper acceptance](../../docs/receipt-footer-first-printing.md). This work is separate from the commits and earlier installation record below.

Commit: `6db31336d4024a53b57833869c40d1488be6a372` (follow-up to `876f24d8e0ed3be9f24dbf83b7295b7e45b69e1f`), pushed directly to `origin/main`. No branch, PR, or force push was used.

Production Gate: [#146](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/40367600418). Final historical status: cancelled after exceeding the 60-minute job limit; build, backend and all 19 native UI cases had passed. See the final handoff above for the repaired workflow.

## Implementation and files

The [implementation record](../../docs/portrait-event-workspace.md) covers before/after behavior, storage precedence, all five Gate #144 root causes and repairs, and visual review. `final-changed-files.txt` records the complete delivered file set, including the follow-up application delegate. Debug and Release generated plists declare only `UIInterfaceOrientationPortrait` in `UISupportedInterfaceOrientations~ipad`; `UIRequiresFullScreen` remains true. Bundle ID and signing were preserved.

Routine event payment, copy, format, receipt, guest and gallery controls now expand inline. A 180-point thumbnail replaces the former 580-point overview preview; the compact preview stays pinned while editing. Expanded previews retain zoom, six formats, Black & White/Thermal Raster, Photos export, and sample printing. Footer/gallery values resolve to actual names, edits create event values, and reset copies studio values. New events snapshot the studio configuration; legacy inheritance stays compatible.

The optional `EventProfile.stickerStudioEnabled` persists with drafts, saved designs, applied profiles and live edits. Explicit event decisions override the Regular Booth preference in either direction. Regular Booth settings and device-wide collections/limits/rights remain independent. The existing per-guest snapshot freezes the choice: staged live edits reach future guests through the existing between-session safety checks and never change current guest configuration, event/run IDs, purchases, counts, print evidence or gallery obligations.

## Verification

- Final focused unit run: 165 passed, 0 failed, 0 skipped; `UnitsFinal.xcresult` and `units-final.log`.
- Native UI: all 19 distinct cases passed across full and corrective focused runs. The consolidated run found one new summary-accessibility assertion; the product now explicitly exposes that status, and its extended interaction test passed on simulator and device.
- Physical acceptance: all seven distinct UUID-isolated cases passed on Carlo's iPad Pro 11-inch (4th generation), iPadOS 26.6.1. Simulator: matching device class, iOS 26.5.
- Both prior menu regressions and all five Gate #144 cases passed. Tests remain enabled; no sleeps or coordinate taps were substituted for controls.
- Actual interactions covered orientation requests, inline payment and prints, footer caption, logo-control reachability, typography selection, pinned/expanded previews, Photo Pass, both raster display modes, guest/sticker choices, save/reopen/relaunch, review, live-event identity retention, checkout evidence retention, keyboard use and larger text.
- The physical camera check opened the real front-camera preview and retained its portrait bounds after an orientation request. It captured no photograph and made no durable camera-check record.
- Debug, signed device, and Release builds passed. Generated orientation declarations were inspected.

## Physical installation and data

The signed app was installed over the existing `com.pocketpixels.PocketPixelsBooth` app. The normal production app was launched afterward and its process was verified. No uninstall or reset occurred.

All 3,982 original Application Support entries had identical counts, sizes and modification dates before/after the isolated fixture checks: 0 added, 0 removed, 0 changed. Fixtures use temporary UUID namespaces and do not perform real payment or print operations. Customer archives, receipts, original payment references, gallery obligations and device settings were retained. See `customer-data-comparison.json`, `normal-launch-final.log`, and `validation-summary.json`.

## Screenshot review

Actual portrait captures were reviewed for overview, expanded payment/print settings, receipt caption/logo/typography controls, guest experience with stickers OFF/ON, compact and full previews, Photo Pass, gallery/footer settings, review, live editing, validation and accessibility text sizes. The review confirmed consistent margins, compact cards, wrapping format chips, aligned copy controls, a neutral Save for Later action, usable keyboard dismissal, and a preview that stays visible while typography is changed.

Examples: [logo controls](carlo-portrait-receipt-header-logo-controls.png), [typography](carlo-portrait-receipt-typography-controls.png), [review status](carlo-portrait-review-sticker-enabled.png). Additional simulator/device screenshots and logs remain local.

## Remaining hardware limits

No real paid transaction, physical thermal-paper print, manual physical device turn, or physical Photos/Files logo import was performed. Device orientation was exercised through XCTest; import/rendering/crop behavior has synthetic unit coverage. These checks do not claim production paper quality, a new real camera capture, or real payment-provider connectivity.

## Interrupted-thread continuation

Gate #145 failed three UI cases; their individual causes and repairs are documented in `docs/portrait-event-workspace.md`. The follow-up adds portrait delegate enforcement, an identifier for the existing Close Receipt Controls action, and Debug-only local camera geometry evidence. Rename selection, rotated display coordinates, native numeric keypad dismissal, and transition completion checks now use explicit assertions and waits. No tests were disabled or skipped.

Continuation: build-for-testing PASS; signed Release device build PASS. Corrected iOS 27 workspace and rename cases passed in RebootAcceptance.xcresult; final camera test passed in CameraBackSync.xcresult, including portrait scene/local layout invariance and an actual Back navigation after rotation. The earlier corrected rename test also passed on iOS 26.5. Original unit/header results remain valid: receipt rendering and printer transport were not changed by the follow-up.

The owner confirmed that Carlo's iPad was disconnected. Earlier physical checks and customer-data comparison apply to 876f24d; 6db3133 has not been installed or tested on the disconnected iPad. No physical data was accessed or changed during this continuation.

The reported VOZY G80 paper-only approximately 20 mm top gap is unresolved. All six-format composed/final-raster header spacing checks passed; receiptPrintHeading adds no leading feed. Cutter-to-head clearance is a hypothesis, not a confirmed G80 diagnosis. No authoritative G80 command manual was found and no physical printer test ran. No reverse-feed command was introduced. See the implementation record for the verified print bytes and reference.

## Current device and spacing status

The owner requested a Wi-Fi handoff, then put installation on hold until the reported paper gap is investigated. The signed Release build passed codesign verification. Wi-Fi connection/install attempts failed before any installation; Carlo was later reconnected by cable for read-only inspection. No follow-up build has been installed, no firmware/persistent printer setting was changed, and no customer record was edited or removed.

The owner reports approximately 20 mm blank above Made to Keep across Sample Print Studio formats and remembers smaller spacing previously. Inspection confirmed standard header topSpacing 8 dots, inactive event profile, Bluetooth transport and current operator-sample print audit entries. Source comparison shows the previous 6 mm masthead reduction is still present, and production feed/cut commands have not changed since that correction.

The owner requested software-only investigation after being unable to locate diagnostics. The reply “20 mm” is therefore **not** evidence that a text-only diagnostic ran. All printer-command experiments stopped. The Mac-only diagnostic discovered the G80 but timed out connecting before any payload send; its log contains zero SEND INTENT records. No Mac test strip was printed.

A new focused regression now exercises the exact SamplePrintComposer.prepare → PrintJobEnvelope pipeline across six formats × three footer styles. All 18 combinations passed with first ink at **34 dots / 4.25 mm**, no leading paper-feed command, and identical frozen raster bytes at dispatch. Build-for-testing and the focused test passed. This new test is local and is not included in commit 6db3133 or Gate #146.

**The physical 20 mm gap remains unresolved.** The current Thermal Raster PNG and corresponding paper photograph were requested to compare the actual reported output against the verified software path. No speculative spacing/cutter change was committed as a fix.
