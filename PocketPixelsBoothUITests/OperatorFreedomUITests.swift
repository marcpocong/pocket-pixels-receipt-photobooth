import XCTest

/// Production ContentView, PIN boundary and operator navigation; no synthetic application root.
/// Never taps a physical print command, changes event lifecycle, or creates a payment.
final class OperatorFreedomUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTFail("Operator action was not reachable: \(element)")
    }
    private func capture(_ name: String) throws {
        let shot = XCUIScreen.main.screenshot(), attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try shot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/pp-freedom-\(name).png"))
    }
    func testNormalWelcomePINHomePrinterRecoveryAndSampleExplanation() throws {
        let app = XCUIApplication(); app.launchArguments = []; app.launchEnvironment = [:]; app.launch()
        let open = app.buttons["Open Admin diagnostics"]
        XCTAssertTrue(open.waitForExistence(timeout: 20)); open.tap()
        XCTAssertTrue(app.buttons["operator-pin-9"].waitForExistence(timeout: 10))
        for digit in "987654" { app.buttons["operator-pin-\(digit)"].tap() }
        for _ in 0..<6 {
            if app.buttons["operator-nav-home"].exists { break }
            if app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 3) { app.navigationBars.buttons.firstMatch.tap() }
        }
        XCTAssertTrue(app.buttons["operator-nav-home"].waitForExistence(timeout: 15))
        app.buttons["operator-nav-home"].tap()
        let quick = app.buttons["quick-test-print"]
        reveal(quick, app: app)
        XCTAssertFalse(quick.isEnabled, "Simulator has no writable physical printer")
        XCTAssertTrue(app.buttons["Reconnect Printer"].isEnabled)
        try capture("production-home-printer")
        // The shared recovery controls remain behind the same unlocked workspace.
        app.buttons["operator-help"].tap()
        XCTAssertTrue(app.navigationBars["Help & Recovery"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Reconnect Printer"].exists)
        XCTAssertTrue(app.buttons["quick-test-print"].exists)
        try capture("production-recovery")
        app.buttons["operator-system"].tap()
        let printer = app.buttons["Printer Setup"]
        XCTAssertTrue(printer.waitForExistence(timeout: 10)); printer.tap()
        XCTAssertTrue(app.navigationBars["Printer Setup"].waitForExistence(timeout: 10))
        let studio = app.buttons["Sample Print Studio"]
        reveal(studio, app: app); studio.tap()
        XCTAssertTrue(app.navigationBars["Print Display Samples"].waitForExistence(timeout: 10))
        let printSample = app.buttons["sample-print"]
        reveal(printSample, app: app); XCTAssertFalse(printSample.isEnabled)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Reconnect to print", "photo slot")).firstMatch.exists)
        try capture("production-sample-explanation")
        // Navigation did not ask for another PIN inside this authorization session.
        XCTAssertFalse(app.buttons["operator-pin-9"].exists)
    }
}
