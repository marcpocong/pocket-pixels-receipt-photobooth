import XCTest

/// Native system menus, dialogs and gestures against isolated simulator-only SwiftUI fixtures.
final class OperatorWorkspaceV41UITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ screen: String = "Sessions", galleryReady: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--operator-v41-ui-fixture"]
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
    private func tapNativeButton(_ button: XCUIElement) throws {
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        if button.isHittable { button.tap(); return }
        // Some supported SwiftUI runtimes expose Menu as a labeled wrapper around a native
        // button. Exercise that real button, rather than tapping an unhittable wrapper.
        try hittableElement(in: button.descendants(matching: .button)).tap()
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
        XCTAssertTrue(app.navigationBars["Review Local Deletion"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '2 sessions'")).firstMatch.waitForExistence(timeout: 5))
        try capture("session-deletion-confirmation")
        let delete = app.buttons["Delete Eligible Sessions"]
        XCTAssertTrue(delete.isEnabled); delete.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '2 deleted'")).firstMatch.waitForExistence(timeout: 10))
        try capture("synthetic-session-deletion-results")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["No sessions yet"].waitForExistence(timeout: 5))
    }
    func testEventsExposeManageAndProtectedDeletionExplanation() throws {
        let app = launch("Events")
        let manage = app.buttons["Manage"].firstMatch
        try tapNativeButton(manage)
        XCTAssertTrue(app.buttons["Archive"].waitForExistence(timeout: 5))
        try capture("event-manage-menu")
        app.buttons["Delete Permanently"].tap()
        XCTAssertTrue(app.buttons["Delete Permanently"].waitForExistence(timeout: 5))
        try capture("event-deletion-confirmation")
        app.buttons["Delete Permanently"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'dependencies'")).firstMatch.waitForExistence(timeout: 5))
        try capture("event-deletion-eligibility")
    }
    func testCheckoutManageReviewAndParkedHistory() throws {
        let app = launch("Checkouts")
        XCTAssertTrue(app.staticTexts["Active Interruptions · 1"].waitForExistence(timeout: 10))
        try capture("checkout-management-and-parked-history")
        try tapNativeButton(app.buttons["Manage"].firstMatch)
        XCTAssertTrue(app.buttons["Delete Eligible Checkout"].waitForExistence(timeout: 5))
        try capture("checkout-manage-menu")
        app.buttons["Delete Eligible Checkout"].tap()
        XCTAssertTrue(app.navigationBars["Review Checkout Deletion"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Archive keeps reconciliation'")).firstMatch.waitForExistence(timeout: 10))
        try capture("checkout-delete-review")
    }
    func testHistoricalGalleryRecheckShowsReadyAndResultCounts() throws {
        let app = launch(galleryReady: true)
        tapWhenVisible("Recheck Unverified Galleries", in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '1 verified' AND label CONTAINS '0 failed'")).firstMatch.waitForExistence(timeout: 15))
        try capture("gallery-recheck-results-ready")
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
