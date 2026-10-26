import XCTest

/// Runs unchanged on the simulator and Carlo's iPad. All data is explicitly isolated in the
/// app's Debug acceptance mode; these tests cannot issue a payment or physical print.
final class EventOperationsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch() -> XCUIApplication {
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
        app.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["New event saved. It is not accepting guests."].waitForExistence(timeout: 10))
        for _ in 0..<3 { app.buttons["setup-continue"].tap() }
        XCTAssertTrue(app.buttons["Start Event"].waitForExistence(timeout: 10))
        app.buttons["Start Event"].tap()
        XCTAssertTrue(app.staticTexts["Accepting guests. The next session will use the reviewed setup."].waitForExistence(timeout: 10))
        capture("created-and-activated")
        app.navigationBars.buttons["Event Validation"].tap()
        let run = app.staticTexts["validation-run-id"].label
        app.buttons["Edit Live Event"].tap()
        let caption = app.textFields["Receipt footer caption (optional)"]
        visible(caption, in: app); caption.tap(); caption.typeText("DEVICE NEXT SESSION")
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
    func testCommercialHistoryRemovalAndRestore() throws {
        let app = launch()
        app.buttons["Manage Test Events"].tap()
        let manage = app.buttons["Manage Synthetic Paid History"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10)); manage.tap()
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
