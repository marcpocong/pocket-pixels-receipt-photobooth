import XCTest
@testable import PocketPixelsBooth

@MainActor
final class CustomerExperienceTests: XCTestCase {
    func testControlledThemesHaveNamesAndDescriptions() {
        XCTAssertEqual(CustomerScreenTheme.allCases.count, 5)
        for theme in CustomerScreenTheme.allCases {
            XCTAssertFalse(theme.displayName.isEmpty)
            XCTAssertFalse(theme.summary.isEmpty)
        }
    }

    func testCustomerContentNormalizesWhitespaceAndLimitsLength() {
        let profile = EventProfile(
            isEnabled: false,
            eventName: "Receipt Event",
            subtitle: "Host",
            includeEventDate: false,
            eventDate: Date(timeIntervalSince1970: 1_000),
            shortMessage: "",
            customerScreenEnabled: true,
            customerTitle: "  Marc\n&   Alex  ",
            customerSubtitle: String(repeating: "S", count: 100),
            customerWelcomeMessage: " Welcome\n to   our party ",
            customerThankYouMessage: String(repeating: "T", count: 140),
            customerTheme: .warmCelebration
        ).normalized()

        XCTAssertEqual(profile.customerTitle, "Marc & Alex")
        XCTAssertEqual(profile.customerWelcomeMessage, "Welcome to our party")
        XCTAssertEqual(profile.customerSubtitle.count, EventProfile.customerSubtitleLimit)
        XCTAssertEqual(profile.customerThankYouMessage.count, EventProfile.customerMessageLimit)
        XCTAssertEqual(profile.customerTheme, .warmCelebration)
    }

    func testCustomerIdentityFallbackDoesNotCoupleScreenAndReceiptMessages() {
        let profile = EventProfile(
            isEnabled: true,
            eventName: "Graduation Night",
            subtitle: "Class of 2026",
            includeEventDate: false,
            eventDate: Date(),
            shortMessage: "Receipt-only message",
            customerScreenEnabled: true,
            customerWelcomeMessage: "Screen-only message"
        )

        XCTAssertEqual(profile.customerDisplayTitle, "Graduation Night")
        XCTAssertEqual(profile.customerDisplaySubtitle, "Class of 2026")
        XCTAssertEqual(profile.receiptBlockContent?.message, "Receipt-only message")
        XCTAssertEqual(profile.activeCustomerSnapshot?.customerWelcomeMessage, "Screen-only message")
    }

    func testEventModeSummaryClearlyDistinguishesScreenAndReceiptActivation() {
        var profile = EventProfile.pocketPixelsDefault
        XCTAssertFalse(profile.isEventModeActive)
        XCTAssertEqual(profile.eventModeSummary, "Pocket Pixels standard mode")

        profile.eventName = "Wedding Night"
        profile.customerScreenEnabled = true
        XCTAssertEqual(profile.eventModeSummary, "Guest screens only")

        profile.customerScreenEnabled = false
        profile.isEnabled = true
        XCTAssertEqual(profile.eventModeSummary, "Printed receipts only")

        profile.customerScreenEnabled = true
        XCTAssertTrue(profile.isEventModeActive)
        XCTAssertEqual(profile.eventModeSummary, "Guest screens and printed receipts")
    }

    func testReceiptOutputSelectionsUseControlledProductionProfiles() {
        XCTAssertEqual(ReceiptBluetoothTransferMode.balanced.transportPolicy, .experimentalBalanced)
        XCTAssertEqual(ReceiptBluetoothTransferMode.compatibility.transportPolicy, .safeIntegrity)
        XCTAssertEqual(CustomerReceiptPhotoTone.lighter.profile, .light1)
        XCTAssertEqual(CustomerReceiptPhotoTone.lightest.profile, .light2)
    }

    func testOlderPersistedProfileDecodesWithSafeCustomerDefaults() throws {
        let oldJSON = """
        {
          "isEnabled": true,
          "eventName": "Legacy Wedding",
          "subtitle": "A & B",
          "includeEventDate": false,
          "eventDate": 0,
          "location": "Cebu",
          "shortMessage": "Thank you"
        }
        """.data(using: .utf8)!

        let profile = try JSONDecoder().decode(EventProfile.self, from: oldJSON)
        XCTAssertFalse(profile.customerScreenEnabled)
        XCTAssertEqual(profile.customerTheme, .classic)
        XCTAssertEqual(profile.customerTitle, "")
        XCTAssertEqual(profile.eventName, "Legacy Wedding")
        XCTAssertNotNil(profile.activeReceiptSnapshot)
    }

    func testIdleResetIsLimitedToConservativeCustomerStates() {
        for state in [BoothSessionState.choosingFormat, .cameraReady, .review, .receiptPreview, .thankYou] {
            XCTAssertTrue(isIdleEligible(state), "Expected idle reset eligibility for \(state.title)")
        }

        for state in [BoothSessionState.welcome, .preparingCamera, .countdown(photoIndex: 0, value: 3), .capturing(photoIndex: 0), .betweenPhotos(nextPhotoIndex: 1), .retaking(photoIndex: 0), .composingReceipt, .connectingToPrinter, .printing, .recoveryRequired("unknown"), .error("error")] {
            XCTAssertFalse(isIdleEligible(state), "Unexpected idle reset eligibility for \(state.title)")
        }
    }

    func testIdleResetIsBlockedByEveryPrintSafetyCondition() {
        XCTAssertFalse(isIdleEligible(.review, printerWorking: true))
        XCTAssertFalse(isIdleEligible(.review, printBatchActive: true))
        XCTAssertFalse(isIdleEligible(.review, recoveryLocked: true))
        XCTAssertFalse(isIdleEligible(.review, unresolvedPrint: true))
    }

    func testThankYouUsesShorterButConservativeTimeout() {
        XCTAssertEqual(CustomerIdleResetPolicy.initialDelay(for: .thankYou), CustomerIdleResetPolicy.thankYouInactivityDuration)
        XCTAssertEqual(CustomerIdleResetPolicy.initialDelay(for: .review), CustomerIdleResetPolicy.inactivityDuration)
        XCTAssertGreaterThanOrEqual(CustomerIdleResetPolicy.warningDuration, 30)
    }

    func testCustomerErrorClassificationDoesNotExposeTechnicalDetail() {
        let camera = CustomerErrorKind.classify(technicalMessage: "AVCaptureSession device permission failed")
        let printer = CustomerErrorKind.classify(technicalMessage: "BLE UUID write timeout")
        XCTAssertEqual(camera, .camera)
        XCTAssertEqual(printer, .printer)
        XCTAssertFalse(camera.title.contains("AVCapture"))
        XCTAssertFalse(printer.guidance.contains("UUID"))
    }

    func testStaticPreviewPolicyHasNoProductionSideEffects() {
        XCTAssertFalse(CustomerExperiencePreviewPolicy.createsGallery)
        XCTAssertFalse(CustomerExperiencePreviewPolicy.createsArchive)
        XCTAssertFalse(CustomerExperiencePreviewPolicy.sendsPrint)
        XCTAssertFalse(CustomerExperiencePreviewPolicy.changesEventCounters)
    }

    func testDoneResetStillClearsCustomerIdentityAndCopyCount() {
        let model = BoothSessionViewModel()
        model.state = .thankYou
        model.sessionIdentifier = "finished-session"
        model.galleryToken = "finished-token"
        model.selectedPrintCopies = 6

        model.resetAfterDone()
        XCTAssertEqual(model.state, .welcome)
        XCTAssertNil(model.sessionIdentifier)
        XCTAssertNil(model.galleryToken)
        XCTAssertEqual(model.selectedPrintCopies, 1)
    }

    private func isIdleEligible(
        _ state: BoothSessionState,
        printerWorking: Bool = false,
        printBatchActive: Bool = false,
        recoveryLocked: Bool = false,
        unresolvedPrint: Bool = false
    ) -> Bool {
        CustomerIdleResetPolicy.isEligible(
            state: state,
            printerWorking: printerWorking,
            printBatchActive: printBatchActive,
            recoveryLocked: recoveryLocked,
            unresolvedPrint: unresolvedPrint
        )
    }
}
