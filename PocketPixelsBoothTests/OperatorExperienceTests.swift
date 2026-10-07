import Foundation
import UIKit
import XCTest
@testable import PocketPixelsBooth

@MainActor
final class OperatorExperienceTests: XCTestCase {
    func testSamplePrintPolicyBlocksUnresolvedStateAndPreparationDoubleTap() {
        XCTAssertTrue(SamplePrintPolicy.canStart(hasPreview: true, printerBusy: false, recoveryLocked: false, unresolvedPrint: false, operationActive: false))
        XCTAssertFalse(SamplePrintPolicy.canStart(hasPreview: true, printerBusy: false, recoveryLocked: false, unresolvedPrint: true, operationActive: false))
        XCTAssertFalse(SamplePrintPolicy.canStart(hasPreview: true, printerBusy: false, recoveryLocked: false, unresolvedPrint: false, operationActive: true))
    }

    func testBackendOverridesValidatePersistAndResetWithoutStoringCredentials() throws {
        let suiteName = "GalleryBackendOverrideTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GalleryBackendOverrideStore(defaults: defaults)

        try store.save(
            uploadURL: "https://script.google.com/macros/s/TEST_DEPLOYMENT/exec",
            customerURL: "https://gallery.example.com/"
        )
        XCTAssertEqual(store.uploadURLOverride(), "https://script.google.com/macros/s/TEST_DEPLOYMENT/exec")
        XCTAssertEqual(store.customerURLOverride(), "https://gallery.example.com/")
        let persistedKeys = defaults.persistentDomain(forName: suiteName).map { Array($0.keys) } ?? []
        XCTAssertTrue(persistedKeys.allSatisfy { !$0.localizedCaseInsensitiveContains("token") })

        XCTAssertThrowsError(try store.save(uploadURL: "http://script.google.com/macros/s/TEST/exec", customerURL: ""))
        store.reset()
        XCTAssertNil(store.uploadURLOverride())
        XCTAssertNil(store.customerURLOverride())
    }
    private let date = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: Saved profile compatibility

    func testSavedProfileWithAdvancedHeaderAndPassportOverrideDecodesUnchanged() throws {
        var profile = makeProfile()
        profile.receiptHeader.mode = .customEventHeader
        profile.receiptHeader.assetIdentifier = "saved-event-image"
        profile.receiptHeader.scale = 0.66
        profile.receiptHeader.alignment = .left
        profile.receiptHeader.layoutMode = .fill
        profile.receiptHeader.topSpacing = 31
        profile.receiptHeader.bottomSpacing = 7
        profile.receiptHeader.cropPositionX = -0.5
        profile.receiptHeader.cropPositionY = 0.25
        profile.receiptHeader.cropZoom = 2.2
        profile.passport.titleSource = .eventHeaderGraphic
        profile.passport.title = "MEMORY PASS"
        profile.customerScreenEnabled = false

        let data = try JSONEncoder().encode(profile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let header = try XCTUnwrap(object["receiptHeader"] as? [String: Any])
        let passport = try XCTUnwrap(object["passport"] as? [String: Any])
        // Persisted raw values must stay stable even though the UI now says "Event Image".
        XCTAssertEqual(header["mode"] as? String, "customEventHeader")
        XCTAssertEqual(passport["titleSource"] as? String, "eventHeaderGraphic")
        XCTAssertEqual(object["showEventTextBlock"] as? Bool, true)

        let decoded = try JSONDecoder().decode(EventProfile.self, from: data).normalized()
        XCTAssertEqual(decoded.receiptHeader, profile.receiptHeader.normalized())
        XCTAssertEqual(decoded.passport.titleSource, .eventHeaderGraphic)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertFalse(decoded.customerScreenEnabled, "A receipts-only split configuration must survive")
    }

    func testOperatorFacingHeaderNames() {
        XCTAssertEqual(ReceiptHeaderMode.pocketPixelsDefault.displayName, "Pocket Pixels")
        XCTAssertEqual(ReceiptHeaderMode.customEventHeader.displayName, "Event Artwork")
        XCTAssertEqual(ReceiptHeaderMode.none.displayName, "None")
    }

    // MARK: Event image defaults

    func testNewlyImportedTallImageUsesSafeDefaultsWithinPrintableBounds() throws {
        let tall = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 3_000)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 20, y: 20, width: 260, height: 2_960))
        }
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 4_000, height: 200)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 40, width: 4_000, height: 120))
        }

        for image in [tall, wide] {
            var configuration = ReceiptHeaderConfiguration.default
            configuration.scale = ReceiptHeaderConfiguration.maximumScale
            configuration.layoutMode = .fill
            configuration.mode = .customEventHeader
            configuration.assetIdentifier = "new-image"
            configuration.resetAdjustments()

            XCTAssertEqual(configuration.alignment, .center)
            XCTAssertEqual(configuration.layoutMode, .fit)
            XCTAssertEqual(configuration.scale, ReceiptHeaderConfiguration.default.scale)

            let receiptWidth = CGFloat(BoothConfiguration.receiptWidth)
            let size = EventHeaderImageProcessor.frameSize(sourceSize: image.size, configuration: configuration)
            XCTAssertLessThanOrEqual(size.width, receiptWidth - EventHeaderImageProcessor.horizontalInset * 2)
            XCTAssertLessThanOrEqual(size.height, EventHeaderImageProcessor.maximumPrintedHeight)
            XCTAssertGreaterThanOrEqual(size.height, EventHeaderImageProcessor.minimumPrintedHeight)

            let rendered = EventHeaderImageProcessor.renderedHeader(source: image, configuration: configuration)
            XCTAssertLessThanOrEqual(rendered.image.size.width, receiptWidth)
        }
    }

    // MARK: Passport branding

    func testPassportEventBrandingSwitchPreservesAdvancedOverrides() {
        var configuration = PassportConfiguration.default
        XCTAssertTrue(configuration.usesEventBranding, "Automatic is the default experience")

        configuration.usesEventBranding = false
        XCTAssertEqual(configuration.titleSource, .pocketPixels)
        configuration.usesEventBranding = true
        XCTAssertEqual(configuration.titleSource, .automatic)

        for override in [PassportTitleSource.eventText, .eventHeaderGraphic] {
            var custom = PassportConfiguration(titleSource: override)
            XCTAssertTrue(custom.usesEventBranding)
            custom.usesEventBranding = true
            XCTAssertEqual(custom.titleSource, override, "Re-enabling must not discard an override")
        }
    }

    func testAutomaticPassportBrandingPrefersImageThenNameThenPocketPassport() {
        var passport = PassportSessionData.debugFixture
        passport.configuration = .default

        let named = makeProfile()
        XCTAssertEqual(resolve(passport, named, header: true).titleMode, .headerGraphic)
        XCTAssertEqual(resolve(passport, named, header: false).titleMode, .eventText)

        var unnamed = makeProfile()
        unnamed.eventName = ""
        unnamed.showEventTextBlock = false
        XCTAssertEqual(resolve(passport, unnamed, header: false).titleMode, .pocketPixels)

        XCTAssertEqual(resolve(passport, nil, header: false).titleMode, .pocketPixels)

        var forced = passport
        forced.configuration.usesEventBranding = false
        XCTAssertEqual(resolve(forced, named, header: true).titleMode, .pocketPixels)

        var nameOverride = passport
        nameOverride.configuration.titleSource = .eventText
        XCTAssertEqual(resolve(nameOverride, named, header: true).titleMode, .eventText)
    }

    // MARK: Activation

    func testEventModeActivationControlsBothOutputsAndFreezesSnapshot() {
        var profile = makeProfile()
        profile.isEnabled = false
        profile.customerScreenEnabled = false
        XCTAssertFalse(profile.isEventModeActive)

        // Save & Activate
        profile.isEnabled = true
        profile.customerScreenEnabled = true
        XCTAssertNotNil(profile.activeReceiptSnapshot)
        XCTAssertNotNil(profile.activeCustomerSnapshot)
        let frozen = profile.activeReceiptSnapshot

        // Later edits do not change a snapshot already taken for a session.
        profile.eventName = "Changed Later"
        XCTAssertEqual(frozen?.eventName, "Anna & Mark")

        // Turn Off Event Mode
        profile.isEnabled = false
        profile.customerScreenEnabled = false
        XCTAssertNil(profile.activeReceiptSnapshot)
        XCTAssertNil(profile.activeCustomerSnapshot)
    }

    // MARK: Preview Event

    func testPreviewShowsActivatedLookWhileEventModeIsOff() {
        var draft = makeProfile()
        draft.isEnabled = false
        draft.customerScreenEnabled = false

        XCTAssertTrue(EventSetupPreview.showsActivatedPreview(for: draft))
        let preview = EventSetupPreview.previewProfile(for: draft)
        XCTAssertNotNil(preview.activeReceiptSnapshot)
        XCTAssertNotNil(preview.activeCustomerSnapshot)
        // The draft itself is a value and remains off; previewing never activates Event Mode.
        XCTAssertFalse(draft.isEventModeActive)
    }

    func testPreviewKeepsExplicitSplitConfiguration() {
        var draft = makeProfile()
        draft.isEnabled = true
        draft.customerScreenEnabled = false

        XCTAssertFalse(EventSetupPreview.showsActivatedPreview(for: draft))
        let preview = EventSetupPreview.previewProfile(for: draft)
        XCTAssertTrue(preview.isEnabled)
        XCTAssertFalse(preview.customerScreenEnabled)
    }

    func testReceiptPreviewIsSideEffectFreeForEveryFormat() async throws {
        let auditCountBefore = (try? PrintAuditStore().load().count) ?? 0
        let spooler = PrintSpooler.shared
        let queuedBefore = spooler.queuedJobCount
        let activeBefore = spooler.activeJobID
        let storedProfileBefore = UserDefaults.standard.data(forKey: "pocketPixels.eventProfile.v1")

        var draft = makeProfile()
        draft.isEnabled = false
        draft.customerScreenEnabled = false
        let preview = EventSetupPreview.previewProfile(for: draft)

        for format in BoothFormat.allCases {
            let receipt = try await EventReceiptComposerPreview.makePreviewReceipt(profile: preview, format: format)
            XCTAssertEqual(receipt.format, format)
            XCTAssertLessThanOrEqual(receipt.width, BoothConfiguration.receiptWidth)
        }

        XCTAssertEqual((try? PrintAuditStore().load().count) ?? 0, auditCountBefore, "Preview must not create print audit records")
        XCTAssertEqual(spooler.queuedJobCount, queuedBefore, "Preview must not enqueue print jobs")
        XCTAssertEqual(spooler.activeJobID, activeBefore, "Preview must not start a print job")
        XCTAssertEqual(
            UserDefaults.standard.data(forKey: "pocketPixels.eventProfile.v1"),
            storedProfileBefore,
            "Preview must not save the event profile"
        )
    }

    // MARK: Operator status

    func testStatusBeforeBoothCheckAsksOperatorToRunIt() {
        let summary = makeSummary(EventReadinessReport(checks: [], generatedAt: date))
        XCTAssertEqual(summary.headline, "NOT READY")
        XCTAssertEqual(summary.summary, "Run Booth Check before welcoming guests.")
    }

    func testAllPassingChecksAreReadyForGuestsWithoutClutter() {
        let summary = makeSummary(report(failing: [:]))
        XCTAssertEqual(summary.headline, "READY FOR GUESTS")
        XCTAssertEqual(summary.summary, "Camera, printer and gallery are ready.")
        XCTAssertTrue(summary.allSystemsReady)
        XCTAssertTrue(summary.attentionItems.isEmpty)
    }

    func testUncertainPrintSurfacesRecoveryWithoutSofteningReadiness() {
        let summary = makeSummary(
            report(failing: ["Unsafe Print State": .fail]),
            hasUnresolvedPrint: true
        )
        XCTAssertEqual(summary.readiness, .notReady)
        XCTAssertEqual(summary.headline, "NOT READY")
        XCTAssertEqual(summary.summary, "Previous print result needs confirmation before continuing.")
        XCTAssertEqual(summary.printer, .attention("Needs attention"))
        XCTAssertEqual(summary.attentionItems.first?.destination, .recovery)
        XCTAssertEqual(summary.attentionItems.first?.actionTitle, "Open Recovery")
    }

    func testPrinterRecoveryLockOffersFixPrinter() {
        let summary = makeSummary(report(failing: ["Printer Recovery": .fail]), printerRequiresRecovery: true)
        XCTAssertEqual(summary.attentionItems.first?.actionTitle, "Fix Printer")
        XCTAssertEqual(summary.summary, "Printer needs attention before starting.")
    }

    func testWaitingGalleriesAndOfflineAreAttentionNotFailure() {
        let summary = makeSummary(
            report(failing: ["Internet": .warning, "Pending Uploads": .warning]),
            pendingUploadCount: 3
        )
        XCTAssertEqual(summary.headline, "NEEDS ATTENTION")
        XCTAssertEqual(summary.internet, .offline("Offline"))
        XCTAssertEqual(summary.gallery, .attention("3 waiting"))
        XCTAssertTrue(summary.attentionItems.contains {
            $0.message == "3 galleries waiting to upload" && $0.destination == .waitingGalleries
        })
    }

    func testCheckDisplayNamesAvoidInternalTerminology() {
        XCTAssertEqual(OperatorStatusSummary.displayName(forCheckTitle: "Pending Uploads"), "Waiting Galleries")
        XCTAssertEqual(OperatorStatusSummary.displayName(forCheckTitle: "Gallery Credentials"), "Gallery Setup")
        XCTAssertEqual(OperatorStatusSummary.displayName(forCheckTitle: "Unsafe Print State"), "Previous Print Result")
    }

    // MARK: Helpers

    private static let checkTitles: [(String, EventReadinessCheck.Severity)] = [
        ("Camera Initialization", .critical), ("Pending Gallery Storage", .critical),
        ("Camera Authorization", .critical), ("Printer", .critical), ("Print Queue", .critical),
        ("Printer Recovery", .critical), ("Unsafe Print State", .critical),
        ("Archive Storage", .critical), ("Recovery Storage", .critical),
        ("Internet", .important), ("Pending Uploads", .important),
        ("Gallery Credentials", .important), ("Free Disk Space", .important),
        ("Event Profile", .optional), ("Printer Mode", .optional), ("App Uptime", .optional)
    ]

    private func report(failing: [String: EventReadinessCheck.Status]) -> EventReadinessReport {
        EventReadinessReport(
            checks: Self.checkTitles.map { title, severity in
                EventReadinessCheck(severity: severity, title: title, status: failing[title] ?? .pass, detail: "")
            },
            generatedAt: date
        )
    }

    private func makeSummary(
        _ report: EventReadinessReport,
        hasUnresolvedPrint: Bool = false,
        printerRequiresRecovery: Bool = false,
        pendingUploadCount: Int = 0
    ) -> OperatorStatusSummary {
        OperatorStatusSummary(
            report: report,
            hasUnresolvedPrint: hasUnresolvedPrint,
            printerRequiresRecovery: printerRequiresRecovery,
            pendingUploadCount: pendingUploadCount,
            galleryStorageError: false
        )
    }

    private func resolve(_ passport: PassportSessionData, _ profile: EventProfile?, header: Bool) -> PassportReceiptContent {
        var passport = passport
        if let profile {
            var config = profile.passport
            config.titleSource = passport.configuration.titleSource
            var profile = profile
            profile.passport = config
            return PassportReceiptContent.resolve(passport: passport, eventProfile: profile, headerGraphicAvailable: header, referenceDate: date)
        }
        passport.configuration = .default
        return PassportReceiptContent.resolve(passport: passport, eventProfile: nil, headerGraphicAvailable: header, referenceDate: date)
    }

    private func makeProfile() -> EventProfile {
        EventProfile(
            isEnabled: true,
            eventName: "Anna & Mark",
            subtitle: "Our Wedding Day",
            includeEventDate: true,
            eventDate: date,
            location: "Cebu City",
            shortMessage: "Thank you"
        )
    }
}
