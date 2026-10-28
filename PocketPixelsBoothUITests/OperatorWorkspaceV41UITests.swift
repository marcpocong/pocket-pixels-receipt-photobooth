import XCTest

/// Native system menus, dialogs and gestures against isolated simulator-only SwiftUI fixtures.
final class OperatorWorkspaceV41UITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    private func launch(_ screen: String = "Sessions", galleryReady: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--operator-v41-ui-fixture", "--fixture-id", UUID().uuidString] + extra
        if galleryReady { app.launchArguments.append("--gallery-ready-response") }
        app.launch()
        XCTAssertTrue(app.buttons["Sessions"].waitForExistence(timeout: 30))
        if screen != "Sessions" { app.buttons[screen].tap() }
        return app
    }
    private func capture(_ name: String) throws {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try shot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/v41-ui-\(name).png"))
    }
    private func tapWhenVisible(_ name: String, in app: XCUIApplication, attempts: Int = 6) {
        let button = app.buttons[name].firstMatch
        for _ in 0..<attempts {
            if button.exists && button.isHittable { button.tap(); return }
            app.swipeUp()
        }
        XCTFail("Missing action: \(name)")
    }
    private func hittableElement(in query: XCUIElementQuery, timeout: TimeInterval = 10) throws -> XCUIElement {
        var target: XCUIElement?
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            target = query.allElementsBoundByIndex.first(where: \.isHittable)
            return target != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: timeout), .completed)
        return try XCTUnwrap(target)
    }
    private func tapVisibleMenu(_ button: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(button.isHittable)
        button.tap()
    }
    func testSessionMenusSelectionReceiptFitAndZoom() throws {
        let app = launch()
        let manage = app.buttons["Manage session"].firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 20)); manage.tap()
        XCTAssertTrue(app.buttons["Save Receipt to Photos"].waitForExistence(timeout: 5))
        try capture("session-manage-menu")
        app.buttons["View Original Receipt"].tap()
        tapWhenVisible("Full Screen", in: app)
        // A sheet can leave the covered inline preview in the accessibility tree. Only the
        // visible inspector is the gesture target; zoom assertions still verify real input.
        let receipt = try hittableElement(in: app.otherElements.matching(identifier: "operator-receipt-preview"))
        try capture("receipt-fit-full-screen")
        receipt.doubleTap()
        XCTAssertTrue((receipt.value as? String)?.contains("200%") == true)
        try capture("receipt-zoomed")
        receipt.pinch(withScale: 1.2, velocity: 1)
        XCTAssertFalse((receipt.value as? String)?.contains("100%") == true)
        receipt.swipeUp()
        receipt.doubleTap()
        XCTAssertTrue((receipt.value as? String)?.contains("100%") == true)
        app.buttons["Done"].tap(); app.buttons.matching(identifier: "Sessions").allElementsBoundByIndex.last!.tap()
        tapWhenVisible("Select", in: app)
        app.buttons["Select All Visible"].tap()
        try capture("bulk-selection")
        app.buttons["Delete Selected"].tap()
        XCTAssertTrue(app.navigationBars["Delete Sessions?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '2 sessions'")).firstMatch.waitForExistence(timeout: 5))
        try capture("session-deletion-confirmation")
        let delete = try hittableElement(in: app.buttons.matching(identifier: "Delete Selected"))
        XCTAssertTrue(delete.isEnabled); delete.tap()
        XCTAssertTrue(app.staticTexts["No sessions yet"].waitForExistence(timeout: 5))
    }
    func testSuccessfulUnusedEventDeletionPersistsAcrossRelaunchWithLaterRegularSessions() throws {
        let app = launch("Events")
        try capture("events-saved-designs")
        tapVisibleMenu(app.buttons["Manage Unused Test Setup"], in: app)
        XCTAssertTrue(app.buttons["Remove Event"].waitForExistence(timeout: 5))
        try capture("event-manage-menu")
        app.buttons["Remove Event"].tap()
        XCTAssertTrue(app.buttons["Remove Event"].waitForExistence(timeout: 5))
        try capture("event-deletion-confirmation")
        app.buttons["Remove Event"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Event removed.'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Manage Unused Test Setup"].exists)
        XCTAssertTrue(app.buttons["Manage Garden Celebration"].exists)
        try capture("event-deletion-success")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["Events"].waitForExistence(timeout: 30)); app.buttons["Events"].tap()
        XCTAssertTrue(app.buttons["Manage Garden Celebration"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Manage Unused Test Setup"].exists)
        try capture("event-deletion-after-relaunch")
    }

    func testHistoricalRemovalAndArchiveRestoreKeepOccurrence() throws {
        let app = launch("Events")
        tapVisibleMenu(app.buttons["Manage Garden Celebration"], in: app)
        app.buttons["Archive"].tap()
        XCTAssertFalse(app.buttons["Manage Garden Celebration"].exists)
        let archived = app.switches["Show Archived Events"]
        XCTAssertTrue(archived.exists)
        archived.switches.firstMatch.tap()
        XCTAssertEqual(archived.value as? String, "1")
        XCTAssertTrue(app.buttons["Manage Garden Celebration"].waitForExistence(timeout: 5))
        try capture("event-archived-design")
        tapVisibleMenu(app.buttons["Manage Garden Celebration"], in: app)
        app.buttons["Restore"].tap()
        try capture("event-restored-design")
        tapVisibleMenu(app.buttons["Manage Garden Celebration"], in: app)
        app.buttons["Remove Event"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'linked historical runs'")).firstMatch.waitForExistence(timeout: 5))
        try capture("historical-design-removal-explanation")
        app.buttons["Remove Event"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Event removed.'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Manage Garden Celebration"].exists)
        XCTAssertFalse(app.staticTexts["Garden Celebration"].exists, "Removed events hide linked occurrences from normal lists")
        try capture("historical-design-removed-run-retained")
    }

    func testInactiveAppliedDesignCanSwitchToRegularAndThenBeRemoved() throws {
        let app = launch("Events", extra: ["--fixture-applied"])
        tapVisibleMenu(app.buttons["Manage Garden Celebration"], in: app)
        app.buttons["End Event then Remove"].tap(); app.buttons["End Event then Remove"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Event removed.'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Manage Garden Celebration"].exists)
        try capture("inactive-applied-design-removed")
    }

    func testEventStorageFailureShowsImmediateErrorWithoutRemovingDesign() throws {
        let app = launch("Events", extra: ["--fixture-storage-failure"])
        tapVisibleMenu(app.buttons["Manage Unused Test Setup"], in: app)
        app.buttons["Remove Event"].tap(); app.buttons["Remove Event"].tap()
        XCTAssertTrue(app.alerts["Event action could not finish"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS 'could not be saved'")).firstMatch.exists)
        try capture("event-storage-failure")
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["Manage Unused Test Setup"].exists)
    }

    func testActiveGuestCannotLoseAppliedDesignOrEndEvent() throws {
        let app = launch("Events", extra: ["--fixture-active-guest"])
        tapVisibleMenu(app.buttons["Manage Garden Celebration"], in: app)
        app.buttons["End Event then Remove"].tap(); app.buttons["End Event then Remove"].tap()
        XCTAssertTrue(app.alerts["Event action could not finish"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Finish the active guest first'")).firstMatch.exists)
        try capture("active-event-deletion-explanation")
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["Manage Garden Celebration"].exists)
        try capture("active-guest-transition-blocked")
    }

    func testCheckoutManageReviewAndParkedHistory() throws {
        let app = launch("Checkouts")
        XCTAssertTrue(app.staticTexts["Active Interruptions · 1"].waitForExistence(timeout: 10))
        try capture("checkout-management-and-parked-history")
        tapVisibleMenu(app.buttons["Manage"].firstMatch, in: app)
        XCTAssertTrue(app.buttons["Delete Eligible Checkout"].waitForExistence(timeout: 5))
        try capture("checkout-manage-menu")
        app.buttons["Delete Eligible Checkout"].tap()
        XCTAssertTrue(app.navigationBars["Review Checkout Deletion"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Archive keeps reconciliation'")).firstMatch.waitForExistence(timeout: 10))
        try capture("checkout-delete-review")
    }
    func testPortraitGridSelectionFiltersListAndTransientExport() throws {
        let app = launch(extra: ["--fixture-many-sessions", "--fixture-photos-success"])
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(app.buttons.matching(identifier: "Manage session").count, 3)
        try capture("sessions-grid-portrait")
        // Three equal columns on the selected 11-inch portrait simulator.
        let first = cards.element(boundBy: 0).frame, second = cards.element(boundBy: 1).frame, third = cards.element(boundBy: 2).frame
        XCTAssertEqual(first.minY, second.minY, accuracy: 2); XCTAssertEqual(second.minY, third.minY, accuracy: 2)
        XCTAssertEqual(first.width, third.width, accuracy: 2)
        app.buttons["Select"].tap()
        XCTAssertFalse(app.buttons["Delete Selected"].exists)
        XCTAssertFalse(app.buttons["Manage session"].exists)
        try capture("sessions-selection-empty")
        cards.element(boundBy: 0).tap(); cards.element(boundBy: 1).tap()
        XCTAssertEqual(cards.element(boundBy: 0).value as? String, "Selected")
        XCTAssertTrue(app.buttons["Delete Selected"].isHittable)
        try capture("sessions-several-selected-bulk-bar")
        app.buttons["Select All Visible"].tap()
        XCTAssertTrue(app.staticTexts.matching(identifier: "8 selected").firstMatch.exists)
        try capture("sessions-select-all-visible")
        // Search narrows both visible records and the selection set.
        let search = app.textFields["sessions-search"]
        search.tap(); search.typeText("120000")
        try capture("sessions-selection-keyboard")
        search.typeText("\n")
        XCTAssertTrue(app.staticTexts.matching(identifier: "1 selected").firstMatch.exists)
        app.buttons["Clear search"].tap()
        app.buttons["Hide Selected"].tap()
        XCTAssertTrue(app.staticTexts["1 session hidden."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Delete Selected"].exists)
        app.buttons["Done"].tap()
        app.buttons["List"].tap()
        XCTAssertTrue(app.buttons["Photos"].exists)
        try capture("sessions-list-portrait")
        app.buttons["Manage session"].firstMatch.tap()
        try capture("sessions-integrated-menu")
        app.buttons["Save Receipt to Photos"].tap()
        XCTAssertTrue(app.staticTexts["Receipt saved to Photos"].waitForExistence(timeout: 10))
        try capture("sessions-export-success")
        let disappears = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["Receipt saved to Photos"])
        XCTAssertEqual(XCTWaiter.wait(for: [disappears], timeout: 10), .completed)
        let galleryActions = app.buttons["sessions-gallery-actions"]
        XCTAssertEqual(app.buttons.matching(identifier: "sessions-gallery-actions").count, 1)
        XCTAssertTrue(galleryActions.isHittable)
        galleryActions.tap()
        XCTAssertTrue(app.buttons["Recheck Unverified Galleries"].waitForExistence(timeout: 5))
        try capture("sessions-gallery-actions-menu")
    }

    func testSessionsLandscapeAccessibilityAndEmptyState() throws {
        let app = launch(extra: ["--fixture-many-sessions", "--fixture-accessibility"])
        XCTAssertTrue(app.buttons["Manage session"].firstMatch.waitForExistence(timeout: 15))
        try capture("sessions-accessibility-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width < app.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 10), .completed)
        try capture("sessions-portrait-after-rotation")
        app.buttons["Select"].tap(); app.buttons["Select All Visible"].tap()
        XCTAssertTrue(app.buttons["Delete Selected"].isHittable)
        try capture("sessions-accessibility-portrait-after-rotation-selection")
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
        let empty = launch(extra: ["--fixture-empty"])
        XCTAssertTrue(empty.staticTexts["No sessions yet"].waitForExistence(timeout: 15))
        try capture("sessions-empty")
    }

    func testHistoricalGalleryRecheckShowsReadyAndResultCounts() throws {
        let app = launch(galleryReady: true)
        app.buttons["Gallery Actions and More"].tap()
        tapWhenVisible("Recheck Unverified Galleries", in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '1 verified' AND label CONTAINS '0 failed'")).firstMatch.waitForExistence(timeout: 15))
        try capture("gallery-recheck-results-ready")
    }

    func testIndividualPhotoExportFeedbackIsVisibleInsidePhotoSheet() throws {
        let app = launch()
        app.buttons["Manage session"].firstMatch.tap(); app.buttons["View Session"].tap()
        tapWhenVisible("View photo 1, Original capture", in: app)
        XCTAssertTrue(app.navigationBars["Photo 1"].waitForExistence(timeout: 5))
        app.buttons["Save Photo to Photos"].tap()
        let feedback = try hittableElement(in: app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'permission required'")))
        XCTAssertTrue(feedback.isHittable)
        try capture("photo-sheet-export-error")
    }

    func testGalleryFailurePhotosPermissionAndHealth() throws {
        let app = launch()
        app.buttons["Manage session"].firstMatch.tap(); app.buttons["View Session"].tap()
        tapWhenVisible("Save Receipt to Photos", in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'permission required'")).firstMatch.waitForExistence(timeout: 10))
        app.swipeUp()
        try capture("photos-permission-failure")
        tapWhenVisible("Save All Photos", in: app)
        try capture("individual-photo-export-actions")
        // Return to list and select the thumbnail-only, unverified second fixture.
        app.buttons.matching(identifier: "Sessions").allElementsBoundByIndex.last!.tap()
        app.buttons.matching(identifier: "Manage session").element(boundBy: 1).tap(); app.buttons["View Session"].tap()
        tapWhenVisible("Verify Gallery", in: app)
        XCTAssertTrue(app.staticTexts["Needs Attention"].waitForExistence(timeout: 10))
        try capture("gallery-verification-failure-and-results")
        app.buttons["Health"].tap()
        XCTAssertTrue(app.navigationBars["Booth Health"].waitForExistence(timeout: 10))
        tapWhenVisible("Check Event Status Now", in: app)
        try capture("health-active-and-parked")
    }
}
