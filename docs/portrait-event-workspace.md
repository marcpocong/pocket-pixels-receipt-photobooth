# Portrait event workspace

The event workspace uses one vertical page for new, saved, and live events. Payment & Prints, Receipt Design, Guest Experience, Gallery & QR, and Review expand in place. Identity fields and the durable draft status remain at the top. The bottom bar offers neutral Save for Later and primary Review & Start actions, or Cancel Changes and Apply to Next Sessions for a live event. Missing event names are explained at the field; attempting review focuses and reveals it. Paid policy validation and price acknowledgment still run in the existing review and activation coordinator.

## Portrait configuration

Both Debug and Release now set `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad` to `UIInterfaceOrientationPortrait` only. `INFOPLIST_KEY_UIRequiresFullScreen = YES`, iPad device targeting, bundle ID, team, and signing remain unchanged. No private orientation API or rotation instruction is used. The generated Debug and Release app plists were inspected: their `UISupportedInterfaceOrientations~ipad` arrays contain only portrait, and fullscreen is true.

Camera rotation, image normalization, crop geometry, receipt composition, and printer rasterization are unchanged. Interface restrictions do not rewrite photo or print geometry. Rotation regressions retain their original interaction assertions and now require a portrait application frame after a device rotation.

## Editing and previews

Payment choices expand above aligned copy controls and wrapping format chips. Copy minus/plus buttons have explicit 44-point content targets, disabled bounds, accessible labels, and an adaptive arrangement at accessibility text sizes. Server connection details stay in advanced payment tooling. The page provides Done Editing, keyboard dismissal while scrolling, and keyboard dismissal on section/payment changes.

The overview has a 180-point receipt thumbnail. Opening receipt controls pins the compact live preview above the scrolling controls. Closing those controls returns the preview to its overview card. Format and Black & White/Thermal Raster selections survive that transition. Expand Preview opens a portrait sheet with the existing zoomable receipt inspector. Save to Photos and display sample printing are in Preview Actions. Solo, Duo, Grid, Strip, Grid 6, and Photo Pass remain available. Rendering is still asynchronous and generation checked; raster code is unchanged.

Logo controls show the active studio wordmark or event artwork and offer Replace, Remove, and Reset to Studio. Existing co-branding and advanced placement tooling remain. Caption, footer, event details, and typography can be edited independently of a custom logo. Footer and gallery pickers resolve legacy nil values to actual effective layout/style names. Direct editing stores an explicit event value; resets copy the current studio value. New events and template copies snapshot inherited footer/gallery values without rewriting legacy designs.

## Sticker Studio storage and precedence

`EventProfile.stickerStudioEnabled: Bool?` is additive and backward compatible. Missing values decode as nil and preserve the device preference inherited by old events. New workspaces copy the current preference; reusing an old template freezes its effective choice into the new independent event. The field travels with existing draft, library, applied profile, and live-edit storage. Saved Drafts calls it Sticker Studio.

Regular Booth continues to use `StickerStudioSettingsStore`. Production session configuration resolves an explicit event choice before the existing enabled check; event ON works with Regular Booth OFF and vice versa. Event editing never saves global sticker settings. Collection switches, guest limits, offline collections, and rights rules remain device settings. No online source is enabled or constructed.

`BoothSessionViewModel` continues freezing the configuration at guest admission. Publishing a live event updates the stored profile for the next admission; it does not change the current guest's snapshot, event/run IDs, purchased entitlement, counts, or journals. Disabled sessions retain the existing direct-to-receipt path without catalog/provider initialization; enabled guests can skip the editor. Guest previews and Review & Start show the event choice.

## Production Gate #144 repairs

The pre-existing local repairs were preserved and verified alongside this redesign. The failed run's exact logs, xcresult, accessibility snapshots, and screen recordings were retrieved.

| Failure | Cause and repair |
| --- | --- |
| Offline checkout archive/restore/delete | The old SwiftUI Menu exposed an unusable Manage accessibility target. A native, individually identified button now presents management and deletion review in a single sheet. Financial evidence and tombstones remain independent. |
| Workspace draft/history rename | The test terminated without awaiting the background durable save and inspected the new editor immediately after relaunch. It now verifies input, awaits confirmed Saved status, and awaits the exact restored value. Product draft storage remains asynchronous and serialized. |
| Event storage failure | Follow-up presentation from a dismissed management sheet could lose the error. Removal review and its error alert now stay in the presented sheet; failed persistence keeps the saved design. |
| Historical removal/archive/restore | Archive/restore were deferred to a sheet-dismiss callback, allowing stale list observations. They now commit before dismissal; removal review stays in the management sheet until the operation resolves. |
| Inactive applied design removal | The regular-mode transition and removal presentation crossed dismissal boundaries. Removal now awaits the existing lifecycle transition before committing and dismissing. Active-guest/recovery gates remain intact. |

The earlier full-screen receipt and Gallery Actions menu repairs remain enabled. Their tests still verify actual hittable controls, zoom behavior, and unique actions. No tests were deleted, skipped, or replaced by sleeps/coordinate taps. Production Gate runs the entire UI target, then the entire unit/integration target, once each against one build and simulator; both are required.

## Validation and delivery

The final handoff records the exact commit, local results, physical acceptance, screenshot review, and Production Gate URL/status. Validation uses named synthetic fixtures. Physical destructive/financial tests use UUID-scoped temporary storage and do not start production payment, archive, printer, or gallery workers. The camera acceptance route is live preview only and performs no capture or persistent writes. Installation uses the existing bundle over the installed app; no uninstall or data reset is part of delivery.

### Local acceptance record (26–27 October 2026, Asia/Manila)

The local simulator matches Carlo's iPad Pro 11-inch (4th generation), running iOS 26.5. Carlo's physical device runs iPadOS 26.6.1. The final focused unit run passed 165 tests with zero failures and zero skips. Across full and focused runs, all 19 distinct native UI cases and all seven distinct isolated physical acceptance cases passed. The local full UI pass originally exposed the new summary's missing accessible value; its corrected, extended interaction case then passed on both devices. Existing assertions, the five Gate #144 regressions, and both earlier menu regressions remain enabled. Final Production Gate status belongs to the exact delivered commit and is recorded in the handoff.

Physical checks covered creation/activation, live edits and relaunch with the same run ID, checkout archive/restore/deletion and evidence retention, draft restoration and historical naming, larger text, saved sticker choices across relaunch, inline payment/copy/format controls, caption and typography editing, logo-control reachability, pinned and expanded previews, Black & White/Thermal Raster, gallery/footer controls, review status, and device orientation requests. The camera check successfully opened the real front-camera preview and retained portrait bounds after an orientation request. No capture or print was made by that check.

Actual portrait screenshots were reviewed for the workspace overview, expanded payment/print settings, receipt caption/logo/typography controls, enabled and disabled Sticker Studio, gallery/footer settings, Photo Pass preview, Review & Start, live edits, validation, and accessibility text sizes. The preview remains visible while editing typography. Format chips wrap, number controls align, and action bars remain reachable with the keyboard. Review uses a compact preview and one inline title. Covered background controls are excluded from test tap targets; the noninteractive review status has an explicit accessible label/value and stable identifier.

Installation used the existing signed bundle over the installed app. The normal production app was launched afterward. Before/after metadata for all 3,982 original Application Support entries matched exactly: no additions, removals, size changes, or modification-date changes during the isolated fixture checks. No uninstall, data reset, customer deletion, payment settlement, or automatic print resend was performed. Real paid transactions, physical thermal-paper output, manual device rotation, and physical Photos/Files logo import were not exercised; synthetic import/rendering and photo geometry have focused unit coverage.

### Changed files

- `.github/workflows/ci.yml`
- `PocketPixelsBooth.xcodeproj/project.pbxproj`
- `PocketPixelsBooth/BoothSessionEnvironment.swift`
- `PocketPixelsBooth/EventDesignEditorView.swift`
- `PocketPixelsBooth/EventOperationsValidationView.swift`
- `PocketPixelsBooth/EventProfile.swift`
- `PocketPixelsBooth/EventReceiptDesignPanel.swift`
- `PocketPixelsBooth/EventTypographySectionView.swift`
- `PocketPixelsBooth/OperatorWorkspace.swift`
- `PocketPixelsBooth/OperatorWorkspaceView.swift`
- `PocketPixelsBooth/PaymentsOperatorView.swift`
- `PocketPixelsBooth/SavedDrafts.swift`
- `PocketPixelsBooth/SessionSetupCoordinator.swift`
- `PocketPixelsBooth/SessionSetupView.swift`
- `PocketPixelsBooth/StickerStudioSettings.swift`
- `PocketPixelsBooth/StickerStudioView.swift`
- `PocketPixelsBoothTests/SessionSetupTests.swift`
- `PocketPixelsBoothTests/StickerStudioTests.swift`
- `PocketPixelsBoothUITests/EventOperationsUITests.swift`
- `PocketPixelsBoothUITests/OperatorWorkspaceV41UITests.swift`
- `docs/event-workspace-and-checkout-management.md`
- `docs/operator-experience-v3-ipad-checklist.md`
- `docs/operator-workspace-v4-1.md`
- `docs/operator-workspace-v4.md`
- `docs/payments-phase3-test-staging-runbook.md`
- `docs/portrait-event-workspace.md`

## Production Gate #145 follow-up

Gate #145 passed backend checks and the iOS build, then exposed three native UI failures:

- XCTest screen-space camera rectangles swapped axes after rotating the display, while direct telemetry confirmed that UIWindowScene stayed portrait and the local preview remained 717 × 955.5 points. The Debug-only fixture now exposes actual scene orientation and local preview bounds; the test retains both two-point geometry tolerances and explicitly asserts portrait before/after rotation. The application delegate also returns `.portrait` through UIKit's supported orientation callback, supplementing the Debug/Release plist declarations. The camera test waits for the Back control to become hittable after the display transition, taps it, and verifies return to Event Validation.
- The expanded receipt section heading was outside the scroll viewport while the pinned preview remained visible. Its existing Close Receipt Controls action now has an accessibility identifier; the test uses that visible action and verifies that the pinned preview disappears before opening Guest Experience. After exercising the full preview and Done action with the display rotated, the test restores portrait display coordinates before using its vertical scrolling helper. Test teardown also restores orientation after failures.
- Rename input depended on the alert's initial caret/selection state. The UI test now focuses the field, sends the standard Command-A selection shortcut, and asserts the exact replacement value before saving. Saved-design and historical-run rename assertions remain independent.

On iPadOS 27, decimal input uses a floating numeric keypad that temporarily consumes interaction outside its presentation. The keyboard check verifies that the action bar remains on screen, the existing Done Editing action is tappable, and the review action becomes tappable after dismissal. This retains the keyboard escape and action reachability requirements while accommodating the native keypad presentation.

No test was disabled, retried automatically, or replaced with coordinate taps or sleeps.

## VOZY G80 paper-only top gap investigation

The reported approximately 20 mm blank area occurs on printed paper only. The existing compact masthead correction remains present. `CoBrandedReceiptTests.testDefaultStandardAndCoBrandedMastheadsStartWithinSixMillimetres` checks all six formats, both composed and final thermal rasters; the focused header suite passed. The default standard masthead starts at approximately 4.25 mm digitally. `receiptPrintHeading()` sends only ESC @, without a leading paper-feed command.

The finishing sequence includes trailing line feeds and GS V 66 0 (feed and partial cut). Epson's ESC/POS reference describes a physical gap between the cutting and printing positions and model-specific support for returning paper to the print start position: https://download4.epson.biz/sec_pubs/pos/reference_en/escpos/gs_cv.html . That is a plausible explanation, not confirmation of the VOZY G80 mechanism. No authoritative G80 command manual or physical measurement was available. Do not assume support for reverse feed, or reduce receipt padding to claim this paper-only issue fixed. Physical G80 verification remains outstanding.

Continuation verification: simulator build-for-testing and signed Release device build passed. The three Gate #145 cases passed on the iOS 27 matching-class simulator across the corrected focused runs (`RebootAcceptance.xcresult`: workspace and rename; `CameraBackSync.xcresult`: camera). The earlier iOS 26.5 focused camera/receipt checks and corrected rename run also passed. Carlo's iPad was disconnected by the owner during continuation; the final follow-up has not been over-installed or rechecked on physical hardware. Earlier physical acceptance applies to commit 876f24d only.
