//
//  MadeToKeepBrandTests.swift
//  PocketPixelsBoothTests
//
//  Phase 1 visible rebrand: Made to Keep Studios. These tests distinguish visible copy (must be
//  Made to Keep) from legacy compatibility identifiers (may still contain `pocketPixels`).
//

import SwiftUI
import UIKit
import XCTest
@testable import PocketPixelsBooth

@MainActor
final class MadeToKeepBrandTests: XCTestCase {
    /// Legacy internal storage key; intentionally unchanged by the visible rebrand.
    private let eventProfileStorageKey = "pocketPixels.eventProfile.v1"
    private var savedEventProfileData: Data?

    override func setUp() async throws {
        try await super.setUp()
        savedEventProfileData = UserDefaults.standard.data(forKey: eventProfileStorageKey)
        UserDefaults.standard.removeObject(forKey: eventProfileStorageKey)
    }

    override func tearDown() async throws {
        if let savedEventProfileData {
            UserDefaults.standard.set(savedEventProfileData, forKey: eventProfileStorageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: eventProfileStorageKey)
        }
        try await super.tearDown()
    }

    // MARK: Welcome screenshots

    func testWelcomeScreenMatchesReferenceCanvasSizes() async throws {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            let model = BoothSessionViewModel()
            model.state = .welcome
            let image = try await renderBooth(model: model, size: size)
            let name = "welcome-\(Int(size.width))x\(Int(size.height))"
            attach(image, name: name)
            writeArtifact(image, name: "\(name).png")
            XCTAssertEqual(image.size, size)
        }
    }

    func testEventModeWelcomeKeepsMadeToKeepPoster() async throws {
        let profile = EventProfile(
            isEnabled: true,
            eventName: "Anna & Mark",
            subtitle: "Our Wedding Day",
            includeEventDate: false,
            eventDate: Date(),
            shortMessage: "",
            customerScreenEnabled: true,
            customerWelcomeMessage: "Thank you for celebrating with us."
        )
        EventProfileStore.save(profile)
        let model = BoothSessionViewModel()
        model.state = .welcome
        let image = try await renderBooth(model: model, size: CGSize(width: 834, height: 1194))
        attach(image, name: "welcome-event-834x1194")
        writeArtifact(image, name: "welcome-event-834x1194.png")
    }

    // MARK: Customer-flow screenshots

    func testCustomerFlowScreensUseMadeToKeepDesignSystem() async throws {
        let size = CGSize(width: 834, height: 1194)
        let gridPhotos = (0..<4).map { ReliabilityFixtures.syntheticPhoto(session: 812, photo: $0 + 1, format: .grid) }
        let passPhotos = (0..<2).map { ReliabilityFixtures.syntheticPhoto(session: 813, photo: $0 + 1, format: .passport) }
        let galleryURL = try XCTUnwrap(URL(string: "https://example.com/?g=\(String(repeating: "a", count: 64))"))

        struct Screen {
            let name: String
            let configure: @MainActor (BoothSessionViewModel) throws -> Void
            var settle: Duration = .seconds(1)
        }

        let screens: [Screen] = [
            Screen(name: "ChooseKeepsake") { $0.state = .choosingFormat },
            Screen(name: "Camera") { model in
                model.selectedBoothFormat = .grid
                model.state = .cameraReady
            },
            Screen(name: "Review") { model in
                model.selectedBoothFormat = .grid
                model.capturedPhotos = gridPhotos
                model.state = .review
            },
            Screen(name: "PhotoPassDetails") { model in
                model.selectedBoothFormat = .passport
                model.capturedPhotos = passPhotos
                model.passportDraft = .photoPassDebugFixture
                model.state = .passportDetails
            },
            Screen(name: "PhotoPassSignature") { model in
                model.selectedBoothFormat = .passport
                model.capturedPhotos = passPhotos
                model.passportDraft = .photoPassDebugFixture
                model.state = .passportSignature
            },
            Screen(name: "PhotoPassPreview", configure: { model in
                model.selectedBoothFormat = .passport
                model.capturedPhotos = passPhotos
                model.passportDraft = .photoPassDebugFixture
                model.state = .passportSignature
                model.continueFromPassportSignature()
            }, settle: .seconds(4)),
            Screen(name: "ReceiptPreview") { model in
                let receipt = try ReceiptComposer.compose(photos: gridPhotos, sessionIdentifier: "PP-20261008-101500", date: Self.fixtureDate, galleryURL: galleryURL, format: .grid)
                let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
                model.selectedBoothFormat = .grid
                model.capturedPhotos = gridPhotos
                model.composedReceipt = receipt
                model.receiptImage = image
                model.receiptRasterizedImage = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
                model.state = .receiptPreview
            },
            Screen(name: "ThankYou") { model in
                model.galleryURL = galleryURL
                model.galleryQRCodeImage = try GalleryQRCodeGenerator.makeQRCodeImage(for: galleryURL)
                model.state = .thankYou
            }
        ]

        for screen in screens {
            let model = BoothSessionViewModel()
            try screen.configure(model)
            let image = try await renderBooth(model: model, size: size, settle: screen.settle)
            let name = "flow-\(screen.name)-834x1194"
            attach(image, name: name)
            writeArtifact(image, name: "\(name).png")
            model.cancelSession()
        }
    }

    // MARK: Receipts

    func testDefaultReceiptIsMadeToKeepBrandedInColorAndThermal() throws {
        let photos = (0..<4).map { ReliabilityFixtures.syntheticPhoto(session: 820, photo: $0 + 1, format: .grid) }
        let galleryURL = try XCTUnwrap(URL(string: "https://example.com/?g=\(String(repeating: "b", count: 64))"))
        let receipt = try ReceiptComposer.compose(photos: photos, sessionIdentifier: "PP-20261008-101500", date: Self.fixtureDate, galleryURL: galleryURL, format: .grid)
        let color = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        let thermal = try XCTUnwrap(UIImage(data: ThermalImageRasterizer.rasterize(color, purpose: .completeReceipt).previewPNGData))
        XCTAssertEqual(receipt.width, BoothConfiguration.receiptWidth)
        attach(color, name: "receipt-default-made-to-keep")
        attach(thermal, name: "receipt-default-made-to-keep-thermal")
        writeArtifact(color, name: "receipt-default-made-to-keep.png")
        writeArtifact(thermal, name: "receipt-default-made-to-keep-thermal-1bit.png")

        let noQR = try ReceiptComposer.compose(photos: photos, sessionIdentifier: "PP-20261008-101500", date: Self.fixtureDate, galleryURL: nil, format: .grid)
        writeArtifact(try XCTUnwrap(UIImage(data: noQR.imagePNGData)), name: "receipt-default-no-qr.png")
    }

    func testEventAndPhotoPassReceiptRegressionFixtures() throws {
        let galleryURL = try XCTUnwrap(URL(string: "https://example.com/?g=\(String(repeating: "c", count: 64))"))
        let event = EventProfile(
            isEnabled: true,
            eventName: "Anna & Mark",
            subtitle: "Our Wedding Day",
            includeEventDate: true,
            eventDate: Self.fixtureDate,
            location: "Cebu City",
            shortMessage: "Thank you for celebrating"
        )
        let duo = (0..<2).map { ReliabilityFixtures.syntheticPhoto(session: 830, photo: $0 + 1, format: .duo) }
        let eventReceipt = try ReceiptComposer.compose(photos: duo, sessionIdentifier: "PP-20261008-101500", date: Self.fixtureDate, galleryURL: galleryURL, format: .duo, eventProfile: event)
        let eventImage = try XCTUnwrap(UIImage(data: eventReceipt.imagePNGData))
        writeArtifact(eventImage, name: "receipt-event-regression.png")
        writeArtifact(try XCTUnwrap(UIImage(data: ThermalImageRasterizer.rasterize(eventImage, purpose: .completeReceipt).previewPNGData)), name: "receipt-event-regression-thermal-1bit.png")

        let pass = (0..<2).map { ReliabilityFixtures.syntheticPhoto(session: 831, photo: $0 + 1, format: .passport) }
        let passReceipt = try ReceiptComposer.compose(photos: pass, sessionIdentifier: "PP-20261008-101500", date: Self.fixtureDate, galleryURL: galleryURL, format: .passport, passport: .photoPassDebugFixture)
        let passImage = try XCTUnwrap(UIImage(data: passReceipt.imagePNGData))
        XCTAssertLessThanOrEqual(passReceipt.height, BoothConfiguration.receiptMaximumHeight)
        writeArtifact(passImage, name: "receipt-photo-pass-regression.png")
        writeArtifact(try XCTUnwrap(UIImage(data: ThermalImageRasterizer.rasterize(passImage, purpose: .completeReceipt).previewPNGData)), name: "receipt-photo-pass-regression-thermal-1bit.png")
    }

    // MARK: Visible copy vs. compatibility identifiers

    func testAppDisplayNameIsMadeToKeepStudios() throws {
        let appBundle = Bundle(for: BoothSessionViewModel.self)
        XCTAssertEqual(appBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Made to Keep Studios")
        // The customer gallery key and host are Phase 2 work and must be unchanged.
        XCTAssertEqual(appBundle.object(forInfoDictionaryKey: "POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL") as? String, "https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/")
    }

    func testBrandConstantsMatchReference() {
        XCTAssertEqual(MadeToKeepBrand.fullName, "Made to Keep Studios")
        XCTAssertEqual(MadeToKeepBrand.wordmark, "made to keep")
        XCTAssertEqual(MadeToKeepBrand.secondary, "studios")
        XCTAssertEqual(MadeToKeepBrand.descriptor, "RECEIPT PHOTOBOOTH")
        XCTAssertEqual(MadeToKeepBrand.tagline, "little moments, made to keep.")
        XCTAssertEqual(MadeToKeepBrand.welcomeCallToAction, "MAKE A MEMORY")
        XCTAssertEqual(MadeToKeepBrand.welcomeHelper, "tap to begin")
        XCTAssertEqual(MadeToKeepBrand.signature, "BY M&K")
        XCTAssertEqual(MadeToKeepBrand.edition, "081719")
    }

    func testDefaultVisibleCopyNeverShowsRetiredBrand() {
        let profile = EventProfile.pocketPixelsDefault
        let visible: [String] = [
            profile.eventModeSummary,
            ReceiptHeaderMode.pocketPixelsDefault.displayName,
            CustomerScreenTheme.classic.displayName,
            CustomerScreenTheme.classic.summary,
            ReceiptComposer.mastheadEstablishedText,
            ReceiptComposer.footerBrandLine,
            MadeToKeepBrand.standardModeGuestDescription,
            MadeToKeepBrand.defaultEventName,
            MadeToKeepBrand.defaultReceiptTitle,
            MadeToKeepBrand.operatorHeaderTitle,
            PassportTitleSource.pocketPixels.displayName
        ]
        for text in visible {
            for retired in MadeToKeepBrand.retiredVisibleStrings {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(retired), "\(text) still shows \(retired)")
            }
        }
        XCTAssertEqual(profile.eventModeSummary, "Made to Keep standard mode")
        XCTAssertEqual(ReceiptHeaderMode.pocketPixelsDefault.displayName, "Made to Keep")
    }

    func testLegacyCompatibilityIdentifiersAreUnchanged() throws {
        // Persisted raw values and storage keys stay legacy so stored profiles and archives decode.
        XCTAssertEqual(ReceiptHeaderMode.pocketPixelsDefault.rawValue, "pocketPixelsDefault")
        XCTAssertEqual(BoothFormat.passport.rawValue, "passport")
        XCTAssertTrue(ReceiptComposer.makeSessionIdentifier(date: Self.fixtureDate).hasPrefix("PP-"))

        let stored = try JSONEncoder().encode(EventProfile.pocketPixelsDefault)
        XCTAssertTrue(String(decoding: stored, as: UTF8.self).contains("\"pocketPixelsDefault\""), "Stored header mode keeps its legacy raw value")
        let decoded = try JSONDecoder().decode(EventProfile.self, from: stored)
        XCTAssertEqual(decoded.receiptHeader.mode, .pocketPixelsDefault)
    }

    func testWelcomePosterLayoutMatchesElevenInchCanvas() {
        let portrait = MadeToKeepPosterLayout(container: CGSize(width: 834, height: 1194))
        XCTAssertEqual(portrait.scale, 834.0 / 1048.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(portrait.posterSize.width, 834)
        XCTAssertGreaterThanOrEqual(portrait.posterSize.height, 1194)

        let landscape = MadeToKeepPosterLayout(container: CGSize(width: 1194, height: 834))
        XCTAssertLessThanOrEqual(landscape.posterSize.width, 1194)
        XCTAssertGreaterThan(landscape.scale, 0.5)
    }

    func testWordmarkFontResolvesToHighContrastItalicSerif() {
        let font = MadeToKeepTheme.Typography.italicSerifUIFont(size: 100)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitItalic), "\(font.fontName) must be italic")
        XCTAssertNotEqual(font.familyName, UIFont.systemFont(ofSize: 100).familyName)
    }

    private static let fixtureDate = Date(timeIntervalSince1970: 1_791_454_500)

    // MARK: - Helpers

    private func renderBooth(model: BoothSessionViewModel, size: CGSize, settle: Duration = .seconds(1)) async throws -> UIImage {
        let controller = UIHostingController(rootView: BoothSessionView(viewModel: model))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: settle)
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        return image
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Optional local artifacts for visual inspection: set MADE_TO_KEEP_ARTIFACT_DIR for the run.
    private func writeArtifact(_ image: UIImage, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["MADE_TO_KEEP_ARTIFACT_DIR"], !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: url.appendingPathComponent(name))
    }
}
