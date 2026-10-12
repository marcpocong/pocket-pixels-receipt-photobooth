import CoreImage
import Foundation
import UIKit
import XCTest
@testable import PocketPixelsBooth

/// Editorial receipt redesign: branding modes, printed-QR toggle, captions, persistence,
/// session freezing and archive integrity. Every composition uses the production renderer.
final class ReceiptDesignSystemTests: XCTestCase {
    private static let date: Date = {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = ReceiptComposer.sessionIdentifierTimeZone
        components.year = 2026
        components.month = 10
        components.day = 8
        components.hour = 23
        components.minute = 45
        return components.date!
    }()
    private static let galleryURL = URL(string: "https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/?g=\(String(repeating: "d", count: 64))")!
    private static let artifactDirectory = URL(fileURLWithPath: "/Users/marc/Desktop/PocketPixelsBooth/BuildArtifacts/ReceiptRedesign", isDirectory: true)

    // MARK: Visual artifacts

    func testRenderEveryFormatAndBrandingCombination() throws {
        let artwork = try makeArtworkIdentifier(kind: .wideBanner)
        let monogram = try makeArtworkIdentifier(kind: .monogram)
        for format in BoothFormat.allCases {
            for qr in [false, true] {
                let name = "\(format.rawValue)_studio_\(qr ? "qr_on" : "qr_off")"
                try render(format: format, profile: nil, qr: qr, name: name)
            }
            try render(format: format, profile: eventProfile(mode: .studioFirst, artwork: monogram), qr: true, name: "\(format.rawValue)_event_studio_first_signature")
            try render(format: format, profile: eventProfile(mode: .eventFirst, artwork: artwork), qr: false, name: "\(format.rawValue)_event_first")
        }
        var credit = eventProfile(mode: .eventFirst, artwork: artwork)
        credit.receiptHeader.showsStudioCredit = true
        try render(format: .duo, profile: credit, qr: true, name: "duo_event_first_credit")
    }

    func testPrintedQRSettingDefaultsOnAndPersistsIndependently() throws {
        let suiteName = "ReceiptDesignSystemTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(ReceiptPrintSettingsStore.load(defaults: defaults).includesPrintedGalleryQR)
        ReceiptPrintSettingsStore.save(ReceiptPrintOptions(includesPrintedGalleryQR: false), defaults: defaults)
        XCTAssertFalse(ReceiptPrintSettingsStore.load(defaults: defaults).includesPrintedGalleryQR)
    }

    func testPrintedQRChoiceReflowsEveryFormatWithoutRemovingGalleryURL() throws {
        for format in BoothFormat.allCases {
            let withQR = try compose(format: format, profile: nil, qr: true)
            let withoutQR = try compose(format: format, profile: nil, qr: false)

            XCTAssertTrue(withQR.includesPrintedGalleryQR, format.rawValue)
            XCTAssertFalse(withoutQR.includesPrintedGalleryQR, format.rawValue)
            XCTAssertLessThan(withoutQR.height, withQR.height, format.rawValue)
        }
    }

    func testCommittedSessionFreezesPhysicalPrintOptions() {
        let session = CommittedGallerySession(
            sessionIdentifier: "PP-FROZEN",
            createdAt: Self.date,
            galleryToken: String(repeating: "f", count: 64),
            galleryURL: Self.galleryURL,
            photos: samplePhotos(for: .solo),
            format: .solo,
            eventProfile: nil,
            printOptions: ReceiptPrintOptions(includesPrintedGalleryQR: false)
        )

        XCTAssertFalse(session.printOptions.includesPrintedGalleryQR)
        XCTAssertEqual(session.galleryURL, Self.galleryURL)
        XCTAssertFalse(session.galleryToken.isEmpty)
    }

    func testEventFirstWithoutArtworkUsesSafeStudioFallback() throws {
        let profile = eventProfile(mode: .eventFirst, artwork: nil)
        let plan = try ReceiptComposer.makeLayoutPlan(
            format: .duo,
            includesGalleryQRCode: false,
            eventProfile: profile,
            date: Self.date
        )

        XCTAssertEqual(plan.branding.placement, .studioFirst)
        XCTAssertTrue(plan.branding.showsStudioMasthead)
        XCTAssertEqual(plan.branding.warnings, [.eventFirstArtworkHidden])
    }

    func testEditorialCaptionNormalizesToTwoPrintSafeLines() {
        let caption = ReceiptEditorialCaption.normalized("  Another year with many wonderful memories to keep  ")
        let lines = caption.components(separatedBy: "\n")

        XCTAssertLessThanOrEqual(lines.count, ReceiptEditorialCaption.maximumLines)
        XCTAssertTrue(lines.allSatisfy { $0.count <= ReceiptEditorialCaption.maximumLineLength })
    }

    // MARK: Helpers

    private func render(format: BoothFormat, profile: EventProfile?, qr: Bool, name: String) throws {
        let receipt = try compose(format: format, profile: profile, qr: qr)
        let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        let raster = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        let thermal = try XCTUnwrap(UIImage(data: raster.previewPNGData))
        writeArtifact(image, name: "\(name).png")
        writeArtifact(thermal, name: "\(name)_1bit.png")
        print("RECEIPT_ARTIFACT \(name) \(receipt.width)x\(receipt.height) \(String(format: "%.1f", receipt.estimatedLengthMillimeters))mm")
    }

    private func compose(format: BoothFormat, profile: EventProfile?, qr: Bool, passport: PassportSessionData? = nil) throws -> ComposedReceipt {
        try ReceiptComposer.compose(
            photos: samplePhotos(for: format),
            sessionIdentifier: ReceiptComposer.makeSessionIdentifier(date: Self.date),
            date: Self.date,
            galleryURL: Self.galleryURL,
            format: format,
            eventProfile: profile,
            passport: format == .passport ? (passport ?? .photoPassDebugFixture) : nil,
            printOptions: ReceiptPrintOptions(includesPrintedGalleryQR: qr)
        )
    }

    private func eventProfile(mode: ReceiptBrandingMode?, artwork: String?, caption: String = "") -> EventProfile {
        var profile = EventProfile(
            isEnabled: true,
            eventName: "Anna & Mark",
            subtitle: "Our Wedding Day",
            includeEventDate: true,
            eventDate: Self.date,
            location: "Cebu City",
            shortMessage: "Thank you for celebrating"
        )
        profile.receiptHeader.brandingMode = mode
        if let artwork {
            profile.receiptHeader.mode = .customEventHeader
            profile.receiptHeader.assetIdentifier = artwork
        }
        profile.receiptDesign.editorialCaption = caption
        return profile
    }

    private enum ArtworkKind { case wideBanner, monogram, tall }

    private func makeArtworkIdentifier(kind: ArtworkKind) throws -> String {
        let size: CGSize = switch kind {
        case .wideBanner: CGSize(width: 1200, height: 300)
        case .monogram: CGSize(width: 600, height: 600)
        case .tall: CGSize(width: 300, height: 1500)
        }
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setStroke()
            context.cgContext.setLineWidth(size.width / 60)
            context.cgContext.stroke(CGRect(origin: .zero, size: size).insetBy(dx: size.width / 20, dy: size.height / 20))
            let text = kind == .monogram ? "A&M" : "ANNA & MARK"
            let font = UIFont(name: "Didot-Bold", size: size.height * (kind == .tall ? 0.06 : 0.28)) ?? .boldSystemFont(ofSize: 60)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            let textSize = NSString(string: text).size(withAttributes: attributes)
            NSString(string: text).draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
        }
        return try EventHeaderAssetStore().importImageData(XCTUnwrap(image.pngData()))
    }

    /// Development-only sample photographs: crops of the reference mockup when it is present,
    /// otherwise synthetic portraits.
    private func samplePhotos(for format: BoothFormat) -> [UIImage] {
        let referenceCrops: [CGRect] = [
            CGRect(x: 212, y: 300, width: 345, height: 520),
            CGRect(x: 700, y: 228, width: 360, height: 320),
            CGRect(x: 672, y: 566, width: 360, height: 310)
        ]
        if let reference = UIImage(contentsOfFile: Self.artifactDirectory.appendingPathComponent("reference.png").path)?.cgImage {
            let scale = CGFloat(reference.width) / 1230
            let crops = referenceCrops.compactMap { rect -> UIImage? in
                let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
                return reference.cropping(to: pixelRect).map { UIImage(cgImage: $0) }
            }
            if crops.count == referenceCrops.count {
                switch format {
                case .solo: return [crops[0]]
                case .duo: return [crops[1], crops[2]]
                default: return (0..<format.photoCount).map { crops[$0 % crops.count] }
                }
            }
        }
        return (0..<format.photoCount).map { ReliabilityFixtures.syntheticPhoto(session: 900, photo: $0 + 1, format: format) }
    }

    private func writeArtifact(_ image: UIImage, name: String) {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/StickerStudio/ReceiptRedesign", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: output.appendingPathComponent(name))
    }
}
