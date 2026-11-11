import XCTest

/// Uses the real workspace shell with synthetic archives and no guest/service root.
final class OperatorWorkspaceV5UITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    private func launch(accessible: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--operator-v5-ui-fixture", "--fixture-id", UUID().uuidString]
        if accessible { app.launchArguments.append("--fixture-accessibility") }
        app.launch()
        XCTAssertTrue(app.buttons["operator-nav-home"].waitForExistence(timeout: 20))
        return app
    }
    private func capture(_ name: String) throws {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = "V5 \(name)"; attachment.lifetime = .keepAlways; add(attachment)
        let output = URL(fileURLWithPath: "/tmp/pp-v5-release-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try shot.pngRepresentation.write(to: output.appendingPathComponent("ui-\(name).png"))
    }
    func testPersistentFiveTabNavigationAndNestedBack() throws {
        let app = launch()
        for tab in ["home", "booth", "sessions", "events", "reports"] {
            app.buttons["operator-nav-\(tab)"].tap()
            for item in ["home", "booth", "sessions", "events", "reports"] {
                XCTAssertTrue(app.buttons["operator-nav-\(item)"].isHittable)
            }
            try capture(tab)
            app.swipeUp()
            XCTAssertTrue(app.buttons["operator-nav-\(tab)"].isHittable, "Navigation must remain reachable after scrolling")
        }
        app.buttons["operator-system"].tap()
        XCTAssertTrue(app.buttons["Gallery Setup"].waitForExistence(timeout: 5))
        try capture("system")
        app.buttons["Gallery Setup"].tap()
        XCTAssertTrue(app.navigationBars["Gallery Setup"].waitForExistence(timeout: 5))
        try capture("gallery-form")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Gallery Setup"].waitForExistence(timeout: 5))
        app.buttons["operator-help"].tap()
        XCTAssertTrue(app.navigationBars["Help & Recovery"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["operator-return-to-booth"].isHittable)
        try capture("recovery")
    }
    func testLargerTextNavigationSearchKeyboardAndDetail() throws {
        let app = launch(accessible: true)
        XCTAssertTrue(app.buttons["operator-help"].isHittable)
        XCTAssertTrue(app.buttons["operator-return-to-booth"].isHittable)
        try capture("home-accessibility")
        app.buttons["operator-nav-sessions"].tap()
        let search = app.textFields["sessions-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Synthetic")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        try capture("sessions-keyboard-accessibility")
        search.typeText("\n")
        app.buttons["Clear search"].tap()
        let receipt = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-")).firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 5)); receipt.tap()
        XCTAssertTrue(app.buttons["sessions-back"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sessions-back"].isHittable)
        try capture("session-detail-accessibility")
        app.buttons["sessions-back"].tap()
        app.buttons["operator-nav-booth"].tap()
        XCTAssertTrue(app.buttons["save-regular-defaults"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["save-regular-defaults"].isHittable)
        try capture("booth-accessibility")
    }
}
