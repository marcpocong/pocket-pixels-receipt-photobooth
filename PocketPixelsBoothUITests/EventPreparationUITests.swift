import XCTest

final class EventPreparationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    private func launch(accessible: Bool = false, id: String = UUID().uuidString) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--operator-v5-ui-fixture", "--fixture-prepare-event", "--fixture-id", id]
        if accessible { app.launchArguments.append("--fixture-accessibility") }
        app.launch()
        XCTAssertTrue(app.navigationBars["Prepare Event"].waitForExistence(timeout: 20))
        return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
    private func capture(_ name: String) throws {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let output = URL(fileURLWithPath: "/tmp/pp-v51-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try shot.pngRepresentation.write(to: output.appendingPathComponent(name + ".png"))
    }
    func testSavedStagedToolsAndRelaunch() throws {
        let id = UUID().uuidString
        let app = launch(id: id)
        XCTAssertTrue(app.staticTexts["Unsaved changes available"].exists)
        XCTAssertTrue(app.staticTexts["Saved design · configuration & preview"].exists)
        XCTAssertTrue(app.buttons["prepare-continue"].isHittable)
        try capture("01-saved-overview")
        app.buttons["prepare-source"].tap()
        app.buttons["Staged draft"].tap()
        XCTAssertTrue(app.staticTexts["Garden Celebration — staged changes"].exists)
        try capture("02-staged-overview")
        let receipt = app.buttons["Preview Receipt"]
        reveal(receipt, app: app); receipt.tap()
        XCTAssertTrue(app.buttons["Expand receipt thumbnail"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Preview Actions"].exists, "The preparation preview offers no export or print action")
        try capture("08-staged-receipt-preview")
        receipt.tap()
        let printer = app.buttons["Printer Setup"]
        reveal(printer, app: app); try capture("03-preparation-tools")
        printer.tap()
        XCTAssertTrue(app.navigationBars["Printer Setup"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Prepare Event"].exists)
        let gallery = app.buttons["Gallery Setup"]
        reveal(gallery, app: app); gallery.tap()
        XCTAssertTrue(app.navigationBars["Gallery Setup"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Prepare Event"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Prepare Event"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Unsaved changes available"].exists)
        XCTAssertTrue(app.staticTexts["Saved design · configuration & preview"].exists)
    }
    func testPortraitAccessibilityPreviewAndBackToEvents() throws {
        let app = launch(accessible: true)
        XCTAssertTrue(app.buttons["prepare-continue"].isHittable)
        try capture("04-accessibility-overview")
        let preview = app.buttons["Preview Guest Experience"]
        reveal(preview, app: app); preview.tap()
        app.swipeUp()
        try capture("05-accessibility-guest-preview")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["operator-nav-events"].waitForExistence(timeout: 5))
        let prepare = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "prepare-event-" )).firstMatch
        reveal(prepare, app: app); prepare.tap()
        XCTAssertTrue(app.navigationBars["Prepare Event"].waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars.buttons.firstMatch.tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "edit-event-")).firstMatch
        reveal(edit, app: app); edit.tap()
        let name = app.textFields["event-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(name.isHittable)
        XCTAssertTrue(app.buttons["event-finish-editing"].isHittable)
        try capture("09-contextual-editor-accessibility-keyboard")
        app.buttons["event-finish-editing"].tap()
    }
    func testContinueUsesExistingSetupAndReceiptEditor() throws {
        let app = launch()
        let customize = app.buttons["Customize Receipt & Branding"]
        reveal(customize, app: app); customize.tap()
        XCTAssertTrue(app.buttons["receipt-studio-done"].waitForExistence(timeout: 10))
        try capture("06-contextual-receipt-editor")
        app.buttons["receipt-studio-done"].tap()
        XCTAssertTrue(app.textFields["event-name"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["event-name"].value as? String, "Garden Celebration — staged changes")
        // Returning from the existing editor keeps this preparation page in the stack.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Prepare Event"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["prepare-continue"].tap()
        XCTAssertTrue(app.textFields["event-name"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["event-name"].value as? String, "Garden Celebration — staged changes")
        let review = app.buttons["review-setup"]
        XCTAssertTrue(review.waitForExistence(timeout: 5)); review.tap()
        XCTAssertTrue(app.navigationBars["Review Setup"].waitForExistence(timeout: 5))
        try capture("07-existing-review")
    }
}
