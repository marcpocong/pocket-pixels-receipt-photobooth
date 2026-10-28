import XCTest

/// Runs unchanged on the simulator and Carlo's iPad. All data is explicitly isolated in the
/// app's Debug acceptance mode; these tests cannot issue a payment or physical print.
final class EventOperationsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }
    private func launch(extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--event-operations-validation", "--fixture-id", UUID().uuidString] + extra
        app.launch()
        XCTAssertTrue(app.navigationBars["Event Validation"].waitForExistence(timeout: 20))
        return app
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func replaceRenameText(_ field: XCUIElement, with text: String, in app: XCUIApplication) {
        app.buttons["event-rename-clear"].tap()
        let cleared = field.value as? String ?? ""
        XCTAssertTrue(cleared.isEmpty || cleared == field.placeholderValue, "Delete the complete original name before replacing it")
        XCTAssertFalse(app.buttons["event-rename-save"].isEnabled, "An empty rename cannot be saved")
        field.tap()
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "Save only after replacing the complete original name")
    }
    private func visible(_ element: XCUIElement, in app: XCUIApplication, requireHitTarget: Bool = true) {
        for _ in 0..<12 {
            let reviewing = app.navigationBars["Review Setup"].exists
            let workspace = app.scrollViews["event-workspace-scroll"]
            let studio = app.scrollViews["receipt-studio-controls"]
            let form = app.collectionViews["event-review-form"]
            let reviewScroll = app.scrollViews["event-review-form"]
            let scroll = reviewing ? (form.exists ? form : (reviewScroll.exists ? reviewScroll : app))
                : (studio.exists ? studio : (workspace.exists ? workspace : (app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch : app)))
            let nav = reviewing ? app.navigationBars["Review Setup"] : app.navigationBars.firstMatch
            var top = nav.exists ? nav.frame.maxY : app.frame.minY
            let pinned = app.otherElements["event-pinned-preview"]
            if !reviewing && pinned.exists { top = max(top, pinned.frame.maxY) }
            let primary = reviewing ? app.buttons["Start Accepting Guests"]
                : (app.buttons["apply-live-event"].exists ? app.buttons["apply-live-event"] : app.buttons["review-setup"])
            let bottom = primary.exists ? primary.frame.minY - 10 : app.frame.maxY
            let frame = element.exists ? element.frame : .zero
            if element.exists && (!requireHitTarget || element.isHittable) && frame.height > 0 && frame.width > 0
                && frame.minY >= top && frame.maxY <= bottom { return }
            let done = app.buttons["event-finish-editing"]
            if !reviewing && app.keyboards.firstMatch.exists && done.exists && done.isHittable { done.tap(); continue }
            if element.exists && frame.midY < (top + bottom) / 2 { scroll.swipeDown(velocity: .slow) }
            else { scroll.swipeUp(velocity: .slow) }
        }
        XCTFail("Element is not visible: \(element)")
    }
    private func tapVisible(_ query: XCUIElementQuery) throws {
        var target: XCUIElement?
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let visible = query.allElementsBoundByIndex.filter(\.isHittable)
            guard visible.count == 1 else { return false }
            target = visible[0]
            return true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        try XCTUnwrap(target).tap()
    }

    private func studioSection(_ name: String, in app: XCUIApplication) {
        let picker = app.buttons["receipt-studio-section"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10)); picker.tap()
        app.buttons[name].firstMatch.tap()
    }

    func testReceiptStudioFromNewEventEditsReopensAndSavesWithoutActivation() throws {
        let app = launch()
        let originalRun = app.staticTexts["validation-run-id"].label
        app.buttons["Create Test Event"].tap()
        let name = app.textFields["event-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("CIM INTRAMS")
        app.buttons["event-finish-editing"].tap()
        let customize = app.buttons["event-customize-receipt"]
        visible(customize, in: app)
        XCTAssertEqual(customize.label, "Customize Receipt")
        capture("studio-new-event-entry")
        customize.tap()
        XCTAssertTrue(app.navigationBars["Receipt Studio"].waitForExistence(timeout: 10))
        app.buttons["Add Event Logo"].tap()
        app.buttons["Use Synthetic Test Logo"].tap()
        let mode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Branding Mode,")).firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 15)); mode.tap()
        app.buttons["Co-Branded"].tap()
        XCTAssertTrue(app.buttons["Made to Keep"].waitForExistence(timeout: 10))
        let preview = app.descendants(matching: .any)["operator-receipt-preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 30))
        let originalPreviewFrame = preview.frame
        for target in ["Made to Keep", "× Separator", "Event Logo"] {
            let button = app.buttons[target]
            visible(button, in: app); button.tap()
            let down = app.buttons["Move \(target) down"]
            visible(down, in: app); XCTAssertTrue(down.isEnabled); down.tap()
            XCTAssertTrue(preview.isHittable)
            XCTAssertEqual(preview.frame, originalPreviewFrame, "Control scrolling leaves the preview in place")
        }
        capture("studio-header-portrait")
        studioSection("Footer & QR", in: app)
        app.buttons["receipt-footer-layout"].tap()
        app.buttons["Decorative Barcode Only"].tap()
        let caption = app.textFields["event-footer-caption"]
        visible(caption, in: app); caption.tap(); caption.typeText("MADE FOR CIM")
        capture("studio-footer-portrait")
        studioSection("Text & Style", in: app)
        app.buttons["event-typography-style"].tap(); app.buttons["Editorial"].tap()
        let details = app.switches["Print event details below the footer"]
        visible(details, in: app); details.tap()
        let host = app.textFields["Subtitle / Host"]
        visible(host, in: app); host.tap(); host.typeText("INTRAMS 2026")
        capture("studio-text-portrait")
        app.buttons["receipt-preview-focus"].tap(); app.buttons["Full Receipt"].tap()
        app.buttons["receipt-studio-print-sample"].tap()
        XCTAssertTrue(app.navigationBars["Print Display Samples"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Receipt Studio"].tap()
        app.buttons["receipt-studio-done"].tap()
        XCTAssertTrue(app.navigationBars["New Event"].waitForExistence(timeout: 10))
        customize.tap()
        studioSection("Footer & QR", in: app)
        XCTAssertEqual(caption.value as? String, "MADE FOR CIM")
        XCTAssertTrue(app.buttons["receipt-footer-layout"].label.contains("Decorative Barcode Only"))
        app.buttons["receipt-studio-done"].tap()
        app.buttons["save-setup-draft"].tap()
        XCTAssertTrue(app.navigationBars["Event Validation"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["validation-run-id"].label, originalRun)
        XCTAssertFalse(app.staticTexts["validation-applied-caption"].label.contains("MADE FOR CIM"))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["Reopen Saved Test Event"].waitForExistence(timeout: 20))
        app.buttons["Reopen Saved Test Event"].tap()
        app.buttons["event-customize-receipt"].tap()
        studioSection("Footer & QR", in: app)
        XCTAssertEqual(caption.value as? String, "MADE FOR CIM")
        studioSection("Text & Style", in: app)
        XCTAssertTrue(app.buttons["event-typography-style"].label.contains("Editorial"))
        XCTAssertEqual(host.value as? String, "INTRAMS 2026")
        capture("studio-restored-design")
    }

    func testReceiptInspectorPinchPanAndDoubleTapFromNewEvent() throws {
        let app = launch()
        app.buttons["Create Test Event"].tap()
        let customize = app.buttons["event-customize-receipt"]
        visible(customize, in: app); customize.tap()
        XCTAssertTrue(app.buttons["expand-receipt-preview"].waitForExistence(timeout: 10))
        app.buttons["expand-receipt-preview"].tap()
        XCTAssertTrue(app.navigationBars["Receipt Preview"].waitForExistence(timeout: 10))
        let preview = try XCTUnwrap(app.otherElements.matching(identifier: "operator-receipt-preview").allElementsBoundByIndex.first(where: \.isHittable))
        let scroll = preview.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists)
        scroll.doubleTap()
        let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", "Zoom 100%"), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed)
        let beforePinch = preview.value as? String ?? ""
        scroll.pinch(withScale: 0.8, velocity: -1)
        let pinched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", beforePinch), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [pinched], timeout: 5), .completed)
        scroll.swipeUp()
        scroll.doubleTap()
        let fitted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Zoom 100%"), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [fitted], timeout: 5), .completed)
        capture("studio-full-screen-inspection")
        app.buttons["receipt-inspector-done"].tap()
        XCTAssertTrue(app.navigationBars["Receipt Studio"].waitForExistence(timeout: 5))
    }

    func testReceiptStudioAccessibilityKeepsPreviewAndControlsAvailable() throws {
        let app = launch(extra: ["--fixture-accessibility"])
        app.buttons["Create Test Event"].tap()
        let customize = app.buttons["event-customize-receipt"]
        visible(customize, in: app); customize.tap()
        XCTAssertTrue(app.navigationBars["Receipt Studio"].waitForExistence(timeout: 10))
        let preview = app.descendants(matching: .any)["operator-receipt-preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 30))
        studioSection("Footer & QR", in: app)
        let footer = app.buttons["receipt-footer-layout"]
        visible(footer, in: app)
        XCTAssertTrue(preview.isHittable)
        XCTAssertGreaterThanOrEqual(footer.frame.height, 44)
        XCTAssertGreaterThan(preview.frame.width, app.frame.width * 0.8, "Accessibility sizes use the stacked layout with a persistent preview")
        XCTAssertLessThanOrEqual(footer.frame.maxX, app.frame.maxX)
        capture("studio-accessibility-portrait")
        app.buttons["receipt-studio-done"].tap()
        XCTAssertTrue(app.navigationBars["New Event"].waitForExistence(timeout: 10))
    }

    func testEmptySampleStudioShowsNumberedPlaceholdersInBothModesWithoutLoadingForever() throws {
        let app = launch()
        app.buttons["Preview Empty Sample Studio"].tap()
        XCTAssertTrue(app.navigationBars["Print Display Samples"].waitForExistence(timeout: 10))
        let preview = app.descendants(matching: .any)["sample-rendered-receipt"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 30), "An empty studio must finish preparing its numbered receipt placeholder")
        XCTAssertFalse(app.descendants(matching: .any)["sample-preview-loading"].exists)
        let thermal = app.segmentedControls.buttons["Thermal Raster"]
        visible(thermal, in: app)
        let printButton = app.buttons["sample-print"]
        visible(printButton, in: app, requireHitTarget: false)
        capture("empty-sample-black-and-white-placeholder")
        thermal.tap()
        XCTAssertTrue(preview.exists)
        XCTAssertFalse(app.descendants(matching: .any)["sample-preview-loading"].exists)
        capture("empty-sample-thermal-placeholder")
        XCTAssertTrue(printButton.exists)
        XCTAssertFalse(printButton.isEnabled, "Placeholders cannot be physically printed")
    }

    func testCreateActivateLiveEditAndRestartPreserveRun() throws {
        let app = launch()
        app.buttons["Create Test Event"].tap()
        let name = app.textFields["Event name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("Device Validation Event")
        XCTAssertEqual(name.value as? String, "Device Validation Event")
        capture("new-event-portrait-overview")
        app.buttons["event-finish-editing"].tap()
        let review = app.buttons["review-setup"]
        XCTAssertTrue(review.isEnabled)
        review.tap()
        XCTAssertTrue(app.navigationBars["Review Setup"].waitForExistence(timeout: 10))
        app.buttons["Start Accepting Guests"].tap()
        XCTAssertTrue(app.staticTexts["Accepting guests. The next session will use the reviewed setup."].waitForExistence(timeout: 10))
        capture("created-and-activated")
        app.navigationBars.buttons["Event Validation"].tap()
        let run = app.staticTexts["validation-run-id"].label
        app.buttons["Edit Live Event"].tap()
        app.buttons["event-customize-receipt"].tap()
        capture("receipt-editor-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width < app.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 10), .completed)
        capture("receipt-editor-stays-portrait-after-rotation")
        // The scene stays portrait while newer runtimes rotate display coordinates.
        // Restore them before the vertical scrolling helper measures visible bounds.
        XCUIDevice.shared.orientation = .portrait
        studioSection("Footer & QR", in: app)
        let caption = app.textFields["event-footer-caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5)); visible(caption, in: app); caption.tap(); caption.typeText("DEVICE NEXT SESSION")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["receipt-studio-done"].tap()
        let apply = app.buttons["apply-live-event"]
        XCTAssertTrue(apply.isEnabled); apply.tap()
        let confirmation = app.staticTexts["Changes applied to next sessions. The event and run IDs, existing guests and purchased entitlements are unchanged."]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        capture("live-changes-applied")
        app.navigationBars.buttons["Event Validation"].tap()
        XCTAssertEqual(app.staticTexts["validation-run-id"].label, run)
        XCTAssertTrue(app.staticTexts["validation-applied-caption"].label.contains("DEVICE NEXT SESSION"))
        app.terminate(); app.launch()
        XCTAssertTrue(app.navigationBars["Event Validation"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["validation-run-id"].label, run)
        XCTAssertTrue(app.staticTexts["validation-applied-caption"].label.contains("DEVICE NEXT SESSION"))
        capture("live-changes-survive-relaunch")
    }
    func testOfflineCheckoutArchiveRestoreAndForceDeleteSurviveRestart() throws {
        let app = launch()
        app.buttons["Manage Test Checkouts"].tap()
        XCTAssertTrue(app.staticTexts["Parked / Outstanding · 1"].waitForExistence(timeout: 10))
        let manage = app.buttons["manage-checkout-SYNTHETIC-CHECKOUT-ONLY"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5)); XCTAssertTrue(manage.isHittable); manage.tap()
        app.buttons["Force Remove from Workspace"].tap()
        XCTAssertTrue(app.staticTexts["Parked / Outstanding · 0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Financial Follow-up · 1"].exists)
        let archivedManage = app.buttons["manage-checkout-SYNTHETIC-CHECKOUT-ONLY"]
        XCTAssertTrue(archivedManage.waitForExistence(timeout: 5)); XCTAssertTrue(archivedManage.isHittable); archivedManage.tap()
        app.buttons["Restore Visibility"].tap()
        XCTAssertTrue(app.staticTexts["Parked / Outstanding · 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(manage.isHittable); manage.tap()
        app.buttons["Force Delete Local Checkout"].tap()
        XCTAssertTrue(app.navigationBars["Review Checkout Deletion"].waitForExistence(timeout: 10))
        app.buttons["Force Delete Local Selected"].tap()
        XCTAssertTrue(app.staticTexts["Deleted local checkpoint."].waitForExistence(timeout: 10))
        capture("checkout-independent-evidence-retained")
        app.buttons["Done"].tap()
        app.terminate(); app.launch()
        app.buttons["Manage Test Checkouts"].tap()
        XCTAssertTrue(app.staticTexts["Parked / Outstanding · 0"].waitForExistence(timeout: 10))
        let financial = app.buttons["Financial Follow-up · 1"]
        visible(financial, in: app); financial.tap()
        XCTAssertTrue(app.staticTexts["SYNTHETIC-CHECKOUT-ONLY"].waitForExistence(timeout: 5))
        capture("checkout-tombstone-survives-relaunch")
    }

    func testWorkspaceDraftAndHistoricalRename() throws {
        let app = launch()
        app.buttons["Create Test Event"].tap()
        let name = app.textFields["event-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("Unfinished Workspace")
        XCTAssertEqual(name.value as? String, "Unfinished Workspace")
        let saved = app.descendants(matching: .any).matching(identifier: "event-draft-status").firstMatch
        let committed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Saved on this iPad"), object: saved)
        XCTAssertEqual(XCTWaiter.wait(for: [committed], timeout: 5), .completed)
        app.navigationBars.buttons["Event Validation"].tap()
        app.terminate(); app.launch()
        app.buttons["Create Test Event"].tap()
        let restored = app.textFields["event-name"]
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Unfinished Workspace"), object: restored)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        XCTAssertEqual(restored.value as? String, "Unfinished Workspace")
        app.navigationBars.buttons["Event Validation"].tap()
        app.buttons["Manage Test Events"].tap()
        let manage = app.buttons["Manage Synthetic Paid History"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10)); manage.tap()
        app.buttons["Rename Event"].tap()
        XCTAssertTrue(app.navigationBars["Rename Event"].waitForExistence(timeout: 5))
        let field = app.textFields["event-rename-name"]
        replaceRenameText(field, with: "Corrected Saved Event", in: app)
        capture("event-rename-editor")
        app.buttons["event-rename-save"].tap()
        XCTAssertTrue(app.buttons["Manage Corrected Saved Event"].waitForExistence(timeout: 5))
        capture("saved-event-renamed-independently")
        let runMenu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'manage-run-'")).firstMatch
        visible(runMenu, in: app)
        let originalRunControlID = runMenu.identifier
        runMenu.tap()
        XCTAssertTrue(app.navigationBars["Manage Run"].waitForExistence(timeout: 5))
        app.buttons["Rename Event"].tap()
        XCTAssertTrue(app.navigationBars["Rename Event"].waitForExistence(timeout: 5))
        let runName = app.textFields["event-rename-name"]
        replaceRenameText(runName, with: "Corrected Historical Run", in: app)
        app.buttons["event-rename-save"].tap()
        XCTAssertTrue(app.staticTexts["Corrected Historical Run"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Manage Corrected Saved Event"].exists)
        capture("historical-run-renamed-independently")

        let sameRun = app.buttons[originalRunControlID]
        visible(sameRun, in: app); sameRun.tap()
        XCTAssertTrue(app.navigationBars["Manage Run"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["View History"].isHittable)
        capture("historical-run-management-actions")
        app.buttons["Archive Run"].tap()
        let archived = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sameRun)
        XCTAssertEqual(XCTWaiter.wait(for: [archived], timeout: 5), .completed)
        let showArchived = app.switches["Show Archived Events"]
        visible(showArchived, in: app); showArchived.switches.firstMatch.tap()
        capture("historical-run-archive-visibility")
        XCTAssertEqual(showArchived.value as? String, "1")
        // List can virtualize the restored row while the archive toggle is in view.
        visible(sameRun, in: app)
        XCTAssertTrue(sameRun.waitForExistence(timeout: 5))
        sameRun.tap()
        XCTAssertTrue(app.navigationBars["Manage Run"].waitForExistence(timeout: 5))
        app.buttons["Restore Run"].tap()
        XCTAssertTrue(app.staticTexts["Run restored to history."].waitForExistence(timeout: 5))
        visible(sameRun, in: app); sameRun.tap()
        XCTAssertTrue(app.navigationBars["Manage Run"].waitForExistence(timeout: 5))
        app.buttons["Remove Run"].tap()
        XCTAssertTrue(app.navigationBars["Review Run Removal"].waitForExistence(timeout: 5))
        capture("historical-run-removal-review")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Manage Run"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(sameRun.exists, "Archive/restore and cancelling removal preserve the original run ID")
        XCTAssertTrue(app.staticTexts["Corrected Historical Run"].exists)
        XCTAssertTrue(app.buttons["Manage Corrected Saved Event"].exists)
    }

    func testCommercialHistoryRemovalAndRestore() throws {
        let app = launch()
        app.buttons["Manage Test Events"].tap()
        let manage = app.buttons["Manage Synthetic Paid History"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        XCTAssertTrue(manage.isHittable)
        XCTAssertTrue(manage.identifier.hasPrefix("manage-design-"))
        manage.tap()
        app.buttons["Remove Event"].tap(); app.buttons["Remove Event"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Event removed.'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(manage.exists)
        capture("commercial-history-removed")
        let toggle = app.buttons["Show Removed Events"]
        visible(toggle, in: app)
        toggle.tap()
        XCTAssertTrue(app.buttons["Hide Removed Events"].waitForExistence(timeout: 5))
        capture("removed-events-recovery-list")
        let restore = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'restore-removed-event-'")).firstMatch
        visible(restore, in: app); restore.tap()
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        capture("commercial-history-restored")
    }
    func testPortraitInlineControlsPreviewAndStickerReview() throws {
        let app = launch()
        XCTAssertLessThan(app.frame.width, app.frame.height)
        app.buttons["Create Test Event"].tap()
        app.buttons["review-setup"].tap()
        let name = app.textFields["event-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); XCTAssertTrue(name.isHittable)
        capture("portrait-required-name-validation")
        name.tap(); name.typeText("Portrait Studio Fixture")
        let payment = app.buttons["event-payment-prints"]
        visible(payment, in: app); payment.tap()
        XCTAssertEqual(payment.value as? String, "Expanded")
        let cash = app.buttons["Cash Only"]
        visible(cash, in: app); cash.tap()
        let price = app.textFields["0.00"]
        visible(price, in: app); price.tap(); price.typeText("25.00")
        capture("portrait-inline-paid-settings-keyboard")
        let reviewAction = app.buttons["review-setup"]
        XCTAssertTrue(app.frame.contains(reviewAction.frame), "Keyboard leaves the action bar visible")
        let doneEditing = app.buttons["event-finish-editing"]
        // Newer iPadOS can present the decimal keypad as a modal system popover.
        // Escape dismisses that popover before the app's navigation action can receive taps.
        if !doneEditing.isHittable { price.typeKey(.escape, modifierFlags: []) }
        XCTAssertTrue(doneEditing.isHittable, "The numeric keypad has a reachable dismissal action")
        doneEditing.tap()
        let keyboardActionBar = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: reviewAction)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardActionBar], timeout: 5), .completed, "The action bar is tappable after dismissing input")
        visible(payment, in: app)
        let free = app.buttons["No Payment Required"]
        visible(free, in: app); try tapVisible(app.buttons.matching(identifier: "No Payment Required"))
        let copies = app.buttons["Increase included copies"]
        visible(copies, in: app)
        XCTAssertGreaterThanOrEqual(copies.frame.height, 44)
        capture("portrait-inline-print-settings")
        visible(payment, in: app); payment.tap()
        let receipt = app.buttons["event-customize-receipt"]
        visible(receipt, in: app); receipt.tap()
        studioSection("Footer & QR", in: app)
        let caption = app.textFields["event-footer-caption"]
        visible(caption, in: app); caption.tap(); caption.typeText("MADE FOR THIS EVENT")
        capture("portrait-inline-receipt-controls")
        studioSection("Header & Logo", in: app)
        XCTAssertTrue(app.switches["Use Event Logo"].exists)
        capture("portrait-receipt-header-logo-controls")
        studioSection("Text & Style", in: app)
        app.buttons["event-typography-style"].tap()
        try tapVisible(app.buttons.matching(identifier: "Editorial"))
        capture("portrait-receipt-typography-controls")
        let expand = app.buttons["expand-receipt-preview"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertTrue(expand.isHittable, "The pinned preview is directly reachable while editing")
        XCTAssertGreaterThanOrEqual(expand.frame.height, 44)
        expand.tap()
        XCTAssertTrue(app.navigationBars["Receipt Preview"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertLessThan(app.frame.width, app.frame.height)
        let format = app.buttons["receipt-preview-format-expanded"]
        XCTAssertTrue(format.waitForExistence(timeout: 5)); format.tap()
        try tapVisible(app.buttons.matching(identifier: "Photo Pass"))
        try tapVisible(app.buttons.matching(identifier: "Black & White"))
        capture("portrait-full-preview-photo-pass")
        try tapVisible(app.buttons.matching(identifier: "Thermal Raster"))
        // Restore display coordinates before dismissing this inspector above Receipt Studio.
        XCUIDevice.shared.orientation = .portrait
        let inspectorDone = app.buttons["receipt-inspector-done"]
        XCTAssertTrue(inspectorDone.waitForExistence(timeout: 5))
        try tapVisible(app.buttons.matching(identifier: "receipt-inspector-done"))
        app.buttons["receipt-studio-done"].tap()
        XCTAssertFalse(app.otherElements["event-pinned-preview"].exists)
        let guest = app.buttons["event-guest-experience"]
        visible(guest, in: app); guest.tap()
        let stickers = app.buttons["event-sticker-studio"]
        visible(stickers, in: app)
        XCTAssertEqual(stickers.value as? String, "Disabled")
        capture("portrait-sticker-disabled")
        stickers.tap()
        XCTAssertEqual(stickers.value as? String, "Enabled")
        capture("portrait-sticker-enabled-guest-experience")
        visible(guest, in: app); guest.tap()
        let gallery = app.buttons["event-gallery-qr"]
        visible(gallery, in: app); gallery.tap()
        capture("portrait-inline-gallery-footer")
        XCTAssertTrue(app.buttons["Reset Gallery to Studio"].isHittable)
        app.buttons["review-setup"].tap()
        XCTAssertTrue(app.navigationBars["Review Setup"].waitForExistence(timeout: 5))
        let row = app.collectionViews["event-review-form"].descendants(matching: .any).matching(identifier: "review-sticker-status").firstMatch
        visible(row, in: app, requireHitTarget: false)
        XCTAssertEqual(row.value as? String, "Enabled")
        capture("portrait-review-sticker-enabled")
        XCUIDevice.shared.orientation = .portrait
    }

    func testPortraitAccessibilitySaveAndReopenKeepsStickerChoice() throws {
        let app = launch(extra: ["--fixture-accessibility"])
        app.buttons["Create Test Event"].tap()
        let name = app.textFields["event-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("Accessible Portrait Event")
        let guest = app.buttons["event-guest-experience"]
        visible(guest, in: app); guest.tap()
        let stickers = app.buttons["event-sticker-studio"]
        visible(stickers, in: app); stickers.tap()
        XCTAssertEqual(stickers.value as? String, "Enabled")
        XCTAssertGreaterThanOrEqual(stickers.frame.height, 44)
        XCTAssertGreaterThanOrEqual(stickers.frame.minX, 0)
        XCTAssertLessThanOrEqual(stickers.frame.maxX, app.frame.maxX)
        capture("portrait-accessibility-guest-settings")
        XCTAssertTrue(app.buttons["save-setup-draft"].isHittable)
        app.buttons["save-setup-draft"].tap()
        XCTAssertTrue(app.navigationBars["Event Validation"].waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        let reopen = app.buttons["Reopen Saved Test Event"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 20)); reopen.tap()
        XCTAssertEqual(app.textFields["event-name"].value as? String, "Accessible Portrait Event")
        let reopenedGuest = app.buttons["event-guest-experience"]
        visible(reopenedGuest, in: app); reopenedGuest.tap()
        let reopenedStickers = app.buttons["event-sticker-studio"]
        visible(reopenedStickers, in: app)
        XCTAssertEqual(reopenedStickers.value as? String, "Enabled")
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertLessThan(app.frame.width, app.frame.height)
        capture("portrait-accessibility-saved-event-after-rotation")
        XCUIDevice.shared.orientation = .portrait
    }

    func testPortraitCameraPreviewRemainsReachableAfterRotation() throws {
        let app = launch()
        app.buttons["Check Portrait Camera"].tap()
        let status = app.staticTexts["validation-camera-status"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ OR label == %@", "Camera preview ready", "Camera unavailable on this device"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
#if !targetEnvironment(simulator)
        XCTAssertEqual(status.label, "Camera preview ready", "Physical acceptance requires the real camera")
#endif
        let preview = app.otherElements["validation-camera-preview"]
        XCTAssertTrue(preview.exists)
        let geometryReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (preview.value as? String)?.split(separator: "|").count == 3
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [geometryReady], timeout: 5), .completed)
        func localGeometry() throws -> (orientation: Int, width: Double, height: Double) {
            let parts = try XCTUnwrap(preview.value as? String).split(separator: "|")
            XCTAssertEqual(parts.count, 3)
            return (try XCTUnwrap(Int(parts[0])), try XCTUnwrap(Double(parts[1])), try XCTUnwrap(Double(parts[2])))
        }
        let initial = try localGeometry()
        XCTAssertEqual(initial.orientation, 1, "UIWindowScene must report portrait")
        XCTAssertGreaterThan(initial.height, initial.width)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertLessThan(app.frame.width, app.frame.height)
        let rotated = try localGeometry()
        XCTAssertEqual(rotated.orientation, 1, "The scene must remain portrait after rotating the display")
        // Compare the actual preview layout in scene coordinates. XCTest's screen-space
        // rectangles swap axes on newer iPadOS even when the scene remains portrait.
        XCTAssertEqual(rotated.width, initial.width, accuracy: 2)
        XCTAssertEqual(rotated.height, initial.height, accuracy: 2)
        capture("portrait-live-camera-after-device-rotation")
        let back = app.navigationBars.buttons.firstMatch
        let backReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: back)
        XCTAssertEqual(XCTWaiter.wait(for: [backReady], timeout: 8), .completed, "Camera navigation remains reachable after rotation")
        back.tap()
        XCTAssertTrue(app.navigationBars["Event Validation"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
    }

}
