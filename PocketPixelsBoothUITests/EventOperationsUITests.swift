import XCTest

/// Runs unchanged on the simulator and Carlo's iPad. All data is explicitly isolated in the
/// app's Debug acceptance mode; these tests cannot issue a payment or physical print.
final class EventOperationsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--event-operations-validation", "--fixture-id", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.navigationBars["Event Validation"].waitForExistence(timeout: 20))
        return app
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func visible(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTFail("Element is not visible: \(element)")
    }
    func testCreateActivateLiveEditAndRestartPreserveRun() throws {
        let app = launch()
        app.buttons["Create Test Event"].tap()
        let name = app.textFields["Event name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("Device Validation Event")
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
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 10), .completed)
        capture("receipt-editor-landscape-two-panels")
        let caption = app.textFields["event-footer-caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5)); XCTAssertTrue(caption.isHittable); caption.tap(); caption.typeText("DEVICE NEXT SESSION")
        XCUIDevice.shared.orientation = .portrait
        app.navigationBars.buttons["Edit Live Event"].tap()
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
        let manage = app.buttons["Manage"].firstMatch
        visible(manage, in: app); manage.tap()
        app.buttons["Force Remove from Workspace"].tap()
        XCTAssertTrue(app.staticTexts["Parked / Outstanding · 0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Financial Follow-up · 1"].exists)
        let archivedManage = app.buttons["Manage"].firstMatch
        visible(archivedManage, in: app); archivedManage.tap()
        app.buttons["Restore Visibility"].tap()
        XCTAssertTrue(app.staticTexts["Parked / Outstanding · 1"].waitForExistence(timeout: 5))
        visible(manage, in: app); manage.tap()
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
        app.navigationBars.buttons["Event Validation"].tap()
        app.terminate(); app.launch()
        app.buttons["Create Test Event"].tap()
        XCTAssertEqual(app.textFields["event-name"].value as? String, "Unfinished Workspace")
        app.navigationBars.buttons["Event Validation"].tap()
        app.buttons["Manage Test Events"].tap()
        let manage = app.buttons["Manage Synthetic Paid History"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10)); manage.tap()
        app.buttons["Rename Event"].tap()
        let field = app.alerts.textFields.firstMatch
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Synthetic Paid History".count) + "Corrected Saved Event")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Manage Corrected Saved Event"].waitForExistence(timeout: 5))
        capture("saved-event-renamed-independently")
        let runMenu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'manage-run-'")).firstMatch
        visible(runMenu, in: app); runMenu.tap()
        app.buttons["Rename Event"].tap()
        let runName = app.alerts.textFields.firstMatch
        runName.tap(); runName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Synthetic Paid History".count) + "Corrected Historical Run")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Corrected Historical Run"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Manage Corrected Saved Event"].exists)
        capture("historical-run-renamed-independently")
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
}
