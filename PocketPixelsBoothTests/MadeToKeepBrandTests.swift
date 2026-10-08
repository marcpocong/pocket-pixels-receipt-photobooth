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

    // MARK: Editorial photo review

    func testEveryFormatReviewRendersOnElevenInchCanvas() async throws {
        let hues: [CGFloat] = [0.07, 0.58, 0.32, 0.92, 0.14, 0.75]
        for format in BoothFormat.allCases {
            for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
                let model = BoothSessionViewModel()
                model.selectedBoothFormat = format
                model.capturedPhotos = (0..<format.photoCount).map { Self.duoFixturePhoto(hue: hues[$0 % hues.count]) }
                model.state = .review
                let image = try await renderBooth(model: model, size: size)
                let name = "flow-Review-\(format.rawValue)-\(Int(size.width))x\(Int(size.height))"
                attach(image, name: name)
                writeArtifact(image, name: "\(name).png")
                XCTAssertEqual(image.size, size)
                model.cancelSession()
            }
        }
    }

    func testDuoReviewLayoutFitsPortraitWithoutScrolling() {
        // 11-inch iPad portrait, minus status bar and home indicator safe areas.
        let layout = MadeToKeepPhotoReviewLayout(available: CGSize(width: 834, height: 1194 - 24 - 20), spec: .spec(for: .duo))
        XCTAssertEqual(layout.arrangement.rows, [[0], [1]])
        XCTAssertEqual(layout.arrangement.cellStyle, .stacked)
        XCTAssertFalse(layout.requiresScrolling)
        XCTAssertEqual(layout.gapScale, MadeToKeepPhotoReviewLayout.minimumGapScale)
        XCTAssertGreaterThanOrEqual(layout.photoHeight, 270)
        let size = layout.photoSize(at: 0)
        XCTAssertGreaterThanOrEqual(size.width, 360)
        XCTAssertEqual(size.width / size.height, ReceiptComposer.landscapePresentationAspectRatio, accuracy: 0.02)
    }

    func testDuoReviewPhotoAreaIncreasesByAtLeastFortyPercentFromPreviousGeometry() {
        let previousPhotoSize = CGSize(width: 302, height: 227)
        let layout = MadeToKeepPhotoReviewLayout(
            available: CGSize(width: 834, height: 1194 - 44),
            spec: .spec(for: .duo)
        )
        let revised = layout.photoSize(at: 0)
        let widthIncrease = revised.width / previousPhotoSize.width - 1
        let areaIncrease = (revised.width * revised.height) / (previousPhotoSize.width * previousPhotoSize.height) - 1

        XCTAssertGreaterThanOrEqual(widthIncrease, 0.19)
        XCTAssertGreaterThanOrEqual(areaIncrease, 0.40)
        XCTAssertFalse(layout.requiresScrolling)
    }

    func testEveryFormatReviewFitsElevenInchIPadInBothOrientations() {
        for format in BoothFormat.allCases {
            let spec = MadeToKeepReviewFormatSpec.spec(for: format)
            XCTAssertEqual(spec.photoCount, format.photoCount, "\(format)")
            for available in [CGSize(width: 834, height: 1194 - 44), CGSize(width: 1194, height: 834 - 44)] {
                let layout = MadeToKeepPhotoReviewLayout(available: available, spec: spec)
                XCTAssertFalse(layout.requiresScrolling, "\(format) \(available)")
                XCTAssertGreaterThanOrEqual(layout.photoHeight, spec.minimumPhotoHeight, "\(format) \(available)")
                XCTAssertLessThanOrEqual(
                    layout.contentHeight,
                    available.height - MadeToKeepReviewSpacing.topInset - MadeToKeepReviewSpacing.bottomInset + 0.5,
                    "\(format) \(available)"
                )
                // Every photo appears exactly once, in reading order.
                XCTAssertEqual(layout.arrangement.rows.flatMap { $0 }, Array(0..<format.photoCount), "\(format)")
                for index in 0..<format.photoCount {
                    let size = layout.photoSize(at: index)
                    XCTAssertEqual(size.width / size.height, spec.aspectRatios[index], accuracy: 0.02, "\(format) photo \(index)")
                }
            }
        }
    }

    func testPortraitReviewMirrorsPrintedArrangement() {
        let available = CGSize(width: 834, height: 1194 - 44)
        func rows(_ format: BoothFormat) -> [[Int]] {
            MadeToKeepPhotoReviewLayout(available: available, spec: .spec(for: format)).arrangement.rows
        }
        XCTAssertEqual(rows(.grid), [[0, 1], [2, 3]])
        XCTAssertEqual(rows(.gridSix), [[0, 1], [2, 3], [4, 5]])
        XCTAssertEqual(rows(.strip), [[0], [1], [2]])
        XCTAssertEqual(rows(.passport), [[0, 1]])
    }

    func testShortWindowsScrollInsteadOfClippingControls() {
        let short = MadeToKeepPhotoReviewLayout(available: CGSize(width: 600, height: 700), spec: .spec(for: .duo))
        XCTAssertGreaterThanOrEqual(short.photoHeight, 150)
        XCTAssertTrue(short.requiresScrolling)
    }

    /// Photo-like 4:3 fixture (soft backdrop, two silhouettes) for judging the print frames.
    private static func duoFixturePhoto(hue: CGFloat) -> UIImage {
        let size = CGSize(width: 1600, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let colors = [
                UIColor(hue: hue, saturation: 0.12, brightness: 0.86, alpha: 1).cgColor,
                UIColor(hue: hue, saturation: 0.22, brightness: 0.58, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            UIColor(white: 0.18, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 420, y: 330, width: 330, height: 400))
            cg.fillEllipse(in: CGRect(x: 280, y: 760, width: 620, height: 700))
            UIColor(white: 0.30, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 840, y: 230, width: 340, height: 420))
            cg.fillEllipse(in: CGRect(x: 720, y: 680, width: 640, height: 760))
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
