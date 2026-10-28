import XCTest

final class HeaderPINRefinementUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }

    private func launch(accessibility: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--header-pin-ui-fixture", "--fixture-id", UUID().uuidString]
        if accessibility { app.launchArguments.append("--fixture-accessibility") }
        app.launch()
        XCTAssertTrue(app.buttons["operator-pin-1"].waitForExistence(timeout: 20))
        return app
    }
    private func capture(_ name: String) throws {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try shot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/pp-refine-\(name).png"))
    }
    private func enter(_ digits: String, app: XCUIApplication) {
        for digit in digits { app.buttons["operator-pin-\(digit)"].tap() }
    }

    func testKeypadRetryDeleteHeaderControlsAndBackgroundRelock() throws {
        let app = launch()
        XCTAssertLessThanOrEqual(app.secureTextFields["operator-hardware-pin"].frame.width, 8)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        try capture("pin-portrait")
        enter("12", app: app)
        app.buttons["operator-pin-delete"].tap()
        XCTAssertEqual(app.otherElements["operator-pin"].value as? String, "1 of 6 digits entered")
        enter("00000", app: app)
        XCTAssertTrue(app.staticTexts["Incorrect operator passcode. Try again."].waitForExistence(timeout: 5))
        XCTAssertEqual(app.otherElements["operator-pin"].value as? String, "0 of 6 digits entered")
        enter("987654", app: app)
        XCTAssertTrue(app.staticTexts["Header Acceptance"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Live Header Preview"].exists)
        app.buttons["Made to Keep"].tap()
        XCTAssertTrue(app.buttons["Move Made to Keep right"].isEnabled)
        app.buttons["Move Made to Keep right"].tap()
        app.buttons["× Separator"].tap()
        XCTAssertTrue(app.staticTexts["Separator Size"].exists)
        app.buttons["Move × Separator right"].tap()
        app.buttons["Move × Separator down"].tap()
        try capture("header-portrait")
        app.buttons["Event Logo"].tap()
        app.buttons["Advanced Artwork & Crop"].tap()
        XCTAssertTrue(app.sliders["Crop Zoom"].exists)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["operator-pin-1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Header Acceptance"].isHittable)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testHardwareKeyboardAndAccessibilityLayout() throws {
        let app = launch(accessibility: true)
        let hardware = app.secureTextFields["operator-hardware-pin"]
        hardware.typeText("98765")
        XCTAssertEqual(app.otherElements["operator-pin"].value as? String, "5 of 6 digits entered")
        hardware.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(app.otherElements["operator-pin"].value as? String, "4 of 6 digits entered")
        hardware.typeText("54")
        XCTAssertTrue(app.staticTexts["Header Acceptance"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Made to Keep"].exists)
        try capture("header-accessibility")
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.buttons["operator-pin-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["operator-pin-1"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["operator-pin-1"].frame.height, 64)
        try capture("pin-accessibility")
    }
}
