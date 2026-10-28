import Foundation
import UIKit
import XCTest
@testable import PocketPixelsBooth

/// Co-Branded receipt header: Made to Keep wordmark × event logo. Every composition uses the
/// production composer and rasterizer; artifacts are attached for visual inspection.
final class CoBrandedReceiptTests: XCTestCase {
    private static let date: Date = {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = ReceiptComposer.sessionIdentifierTimeZone
        components.year = 2026; components.month = 10; components.day = 13
        components.hour = 2; components.minute = 50
        return components.date!
    }()
    private static let galleryURL = URL(string: "https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/?g=\(String(repeating: "c", count: 64))")!

    enum LogoKind: String, CaseIterable { case wideSeal, square, veryWide, tall, vectorPDF, largeTransparent }

    // MARK: Visual artifacts

    func testRenderEveryFormatCoBrandedWithNormalAndThermalArtifacts() throws {
        let wide = try logoIdentifier(.wideSeal)
        for format in BoothFormat.allCases {
            try render(format: format, profile: coBranded(wide), qr: false, name: "\(format.rawValue)_cobranded_wide")
            try render(format: format, profile: coBranded(wide), qr: true, name: "\(format.rawValue)_cobranded_wide_qr")
            try render(format: format, profile: nil, qr: false, name: "\(format.rawValue)_standard")
        }
        for kind in LogoKind.allCases where kind != .wideSeal {
            try render(format: .solo, profile: coBranded(try logoIdentifier(kind)), qr: false, name: "solo_cobranded_\(kind.rawValue)")
        }
        try render(format: .passport, profile: coBranded(wide), qr: true, name: "passport_legacy_cobranded", passport: .debugFixture)
    }

    // MARK: Geometry

    func testDefaultStandardAndCoBrandedMastheadsStartWithinSixMillimetres() throws {
        let branded = coBranded(try logoIdentifier(.wideSeal))
        for format in BoothFormat.allCases {
            for profile in [nil, branded] as [EventProfile?] {
                let receipt = try compose(format: format, profile: profile, qr: false)
                let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
                let raster = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
                // Measure the final bytes sent to the printer, including font ascenders
                // and thermal conversion, rather than only the layout's text boxes.
                let blankTop = try XCTUnwrap((0..<min(raster.height, 160)).first { row in
                    raster.rasterData[(row * raster.widthBytes)..<((row + 1) * raster.widthBytes)].contains { $0 != 0 }
                })
                if format == .solo {
                    let name = profile == nil ? "compact_standard" : "compact_cobranded"
                    attachPNG(receipt.imagePNGData, name: name)
                    attachPNG(raster.previewPNGData, name: "\(name)_thermal")
                }
                XCTAssertLessThan(blankTop, 48, "\(format): digital top blank must stay below 6 mm")
                XCTAssertGreaterThan(blankTop, 0, "Keep a small clear border; don't clip the masthead")
            }
        }
    }

    func testCoBrandedHeaderPlacesWordmarkSeparatorAndLogoOnOneMidlineForEveryFormat() throws {
        for kind in LogoKind.allCases {
            let profile = coBranded(try logoIdentifier(kind))
            for format in BoothFormat.allCases {
                let plan = try ReceiptComposer.makeLayoutPlan(format: format, includesGalleryQRCode: true, eventProfile: profile,
                                                              passport: format == .passport ? .photoPassDebugFixture : nil)
                XCTAssertEqual(plan.branding.placement, .coBranded)
                let separator = try XCTUnwrap(plan.coBrandSeparatorFrame, "\(format) \(kind)")
                let logo = try XCTUnwrap(plan.customHeaderFrame)
                XCTAssertEqual(plan.mastheadFrames.count, 2)
                XCTAssertEqual(separator.midX, CGFloat(BoothConfiguration.receiptWidth) / 2, accuracy: 1)
                XCTAssertLessThanOrEqual(plan.mastheadFrames.map(\.maxX).max()! - 1, separator.minX)
                XCTAssertGreaterThanOrEqual(logo.minX, separator.maxX)
                XCTAssertLessThanOrEqual(logo.maxX, CGFloat(BoothConfiguration.receiptWidth - BoothConfiguration.receiptHorizontalMargin))
                XCTAssertGreaterThanOrEqual(plan.mastheadFrames.map(\.minX).min()!, CGFloat(BoothConfiguration.receiptHorizontalMargin))
                // One shared optical midline.
                let block = plan.mastheadFrames.reduce(CGRect.null) { $0.union($1) }
                XCTAssertEqual(logo.midY, separator.midY, accuracy: 1.5)
                XCTAssertEqual(block.midY, separator.midY, accuracy: 2)
                // The header ends before the photographs and never exceeds the printed-header cap.
                let firstPhoto = plan.photoFrames.map(\.rect.minY).min()!
                XCTAssertLessThan(max(block.maxY, logo.maxY), firstPhoto)
                XCTAssertLessThanOrEqual(logo.height, CoBrandedHeaderGeometry.maximumLogoHeight)
                XCTAssertLessThanOrEqual(plan.height, BoothConfiguration.receiptMaximumHeight)
            }
        }
    }

    func testLogoKeepsItsProportionsForWideSquareAndTallArtwork() throws {
        let config = ReceiptHeaderConfiguration.coBrandedRecommended
        for source in [CGSize(width: 1200, height: 400), CGSize(width: 600, height: 600), CGSize(width: 300, height: 1500), CGSize(width: 4000, height: 200)] {
            let size = CoBrandedHeaderGeometry.logoFrameSize(sourceSize: source, configuration: config)
            XCTAssertEqual(size.width / size.height, source.width / source.height, accuracy: 0.08 * source.width / source.height)
            XCTAssertLessThanOrEqual(size.width, CoBrandedHeaderGeometry.slotWidth())
            XCTAssertLessThanOrEqual(size.height, CoBrandedHeaderGeometry.maximumLogoHeight)
        }
        let square = CoBrandedHeaderGeometry.logoFrameSize(sourceSize: CGSize(width: 600, height: 600), configuration: config)
        XCTAssertEqual(square.height, CoBrandedHeaderGeometry.maximumLogoHeight)
        var smaller = config; smaller.scale = 0.6
        XCTAssertLessThan(CoBrandedHeaderGeometry.logoFrameSize(sourceSize: CGSize(width: 600, height: 600), configuration: smaller).height, square.height)
    }

    func testPhotographsKeepTheirSizeAndHeaderStaysCompactComparedWithStandard() throws {
        let profile = coBranded(try logoIdentifier(.wideSeal))
        for format in BoothFormat.allCases {
            let passport: PassportSessionData? = format == .passport ? .photoPassDebugFixture : nil
            let standard = try ReceiptComposer.makeLayoutPlan(format: format, includesGalleryQRCode: false, passport: passport)
            let branded = try ReceiptComposer.makeLayoutPlan(format: format, includesGalleryQRCode: false, eventProfile: profile, passport: passport)
            XCTAssertEqual(standard.photoFrames.map(\.rect.size), branded.photoFrames.map(\.rect.size), "\(format)")
            // The co-branded header adds at most a few millimetres of paper.
            XCTAssertLessThanOrEqual(branded.height - standard.height, 72, "\(format)")
            // The footer composition is unchanged: barcode, rules, monogram and date keep their columns.
            XCTAssertEqual(standard.footer.monogramFrame.midX, branded.footer.monogramFrame.midX)
            XCTAssertEqual(standard.footer.barcodeFrame.width, branded.footer.barcodeFrame.width)
            XCTAssertEqual(standard.footer.dateTexts.map(\.text), branded.footer.dateTexts.map(\.text))
        }
    }

    func testMissingLogoFallsBackToStandardHeaderWithoutBlankSpace() throws {
        var profile = coBranded(UUID().uuidString.lowercased())
        let standard = try ReceiptComposer.makeLayoutPlan(format: .duo, includesGalleryQRCode: false)
        let missing = try ReceiptComposer.makeLayoutPlan(format: .duo, includesGalleryQRCode: false, eventProfile: profile)
        XCTAssertEqual(missing.branding.placement, .studioFirst)
        XCTAssertEqual(missing.branding.warnings, [.coBrandedMissingArtwork])
        XCTAssertNil(missing.coBrandSeparatorFrame)
        XCTAssertNil(missing.customHeaderFrame)
        XCTAssertEqual(missing.photoFrames.map(\.rect), standard.photoFrames.map(\.rect))
        XCTAssertEqual(ReceiptComposer.brandingResolution(for: profile).warnings, [.coBrandedMissingArtwork])
        profile.receiptHeader.mode = .pocketPixelsDefault
        XCTAssertNil(try ReceiptComposer.makeLayoutPlan(format: .duo, includesGalleryQRCode: false, eventProfile: profile).coBrandSeparatorFrame)
    }

    func testStickersNeverCoverTheCoBrandedHeader() throws {
        let profile = coBranded(try logoIdentifier(.wideSeal))
        let plan = try ReceiptComposer.makeLayoutPlan(format: .solo, includesGalleryQRCode: true, eventProfile: profile)
        let protected = ReceiptComposer.stickerProtectedRects(for: plan)
        XCTAssertTrue(protected.contains(try XCTUnwrap(plan.coBrandSeparatorFrame)))
        XCTAssertTrue(protected.contains(try XCTUnwrap(plan.customHeaderFrame)))
    }

    func testLegacyStudioAndEventFirstProfilesStillResolveAsBefore() throws {
        let wide = try logoIdentifier(.wideSeal)
        var studio = coBranded(wide); studio.receiptHeader.brandingMode = .studioFirst
        var event = coBranded(wide); event.receiptHeader.brandingMode = .eventFirst
        var legacy = coBranded(wide); legacy.receiptHeader.brandingMode = nil
        XCTAssertEqual(try ReceiptComposer.makeLayoutPlan(format: .duo, eventProfile: studio).branding.placement, .studioFirst)
        XCTAssertEqual(try ReceiptComposer.makeLayoutPlan(format: .duo, eventProfile: event).branding.placement, .eventFirst)
        XCTAssertEqual(try ReceiptComposer.makeLayoutPlan(format: .duo, eventProfile: legacy).branding.placement, .legacyHeader)
        for profile in [studio, event, legacy] {
            XCTAssertNil(try ReceiptComposer.makeLayoutPlan(format: .duo, eventProfile: profile).coBrandSeparatorFrame)
        }
    }

    func testCoBrandedModePersistsAndOlderProfilesDecodeUnchanged() throws {
        let profile = coBranded("8a6f3a8e-4a52-4cc4-9a1b-8bb1f0d3a111")
        let decoded = try JSONDecoder().decode(EventProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.receiptHeader.brandingMode, .coBranded)
        XCTAssertEqual(decoded.receiptHeader.horizontalPosition, -1)
        let legacyJSON = #"{"isEnabled":true,"eventName":"Gala","subtitle":"","includeEventDate":false,"eventDate":0,"shortMessage":""}"#
        let legacy = try JSONDecoder().decode(EventProfile.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.receiptHeader.brandingMode)
    }

    func testThermalRasterKeepsTheSeparatorAndWordmarkInk() throws {
        let receipt = try compose(format: .solo, profile: coBranded(try logoIdentifier(.wideSeal)), qr: false)
        let plan = try ReceiptComposer.makeLayoutPlan(format: .solo, includesGalleryQRCode: false, eventProfile: coBranded(try logoIdentifier(.wideSeal)), date: Self.date)
        let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        let raster = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        let thermal = try XCTUnwrap(UIImage(data: raster.previewPNGData)?.cgImage)
        let separator = try XCTUnwrap(plan.coBrandSeparatorFrame)
        XCTAssertGreaterThan(darkFraction(in: thermal, rect: separator), 0.08, "the × survives 1-bit conversion")
        XCTAssertGreaterThan(darkFraction(in: thermal, rect: plan.mastheadFrames[0]), 0.05, "the wordmark survives 1-bit conversion")
        XCTAssertGreaterThan(darkFraction(in: thermal, rect: try XCTUnwrap(plan.customHeaderFrame)), 0.03, "the logo survives 1-bit conversion")
    }

    func testIndependentHeaderMigrationPersistenceAndGeometry() throws {
        for kind in [LogoKind.square, .veryWide, .tall, .largeTransparent] {
            var profile = coBranded(try logoIdentifier(kind))
            profile.receiptHeader.scale = 0.7
            profile.receiptHeader.horizontalPosition = 0.35
            let old = try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: profile)
            profile.receiptHeader.editCoBranded { _ in }
            let migrated = try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: profile)
            XCTAssertEqual(old.mastheadFrames, migrated.mastheadFrames)
            XCTAssertEqual(old.customHeaderFrame, migrated.customHeaderFrame)
            XCTAssertEqual(old.photoFrames.map(\.rect), migrated.photoFrames.map(\.rect))
            profile.receiptHeader.editCoBranded { $0.studioScale = 0.65; $0.studioPosition = 1; $0.studioY = 16 }
            let studio = try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: profile)
            XCTAssertEqual(migrated.customHeaderFrame, studio.customHeaderFrame)
            XCTAssertNotEqual(studio.mastheadFrames, migrated.mastheadFrames)
            profile.receiptHeader.scale = 0.5
            profile.receiptHeader.editCoBranded { $0.eventPosition = 1; $0.eventY = -48 }
            let event = try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: profile)
            XCTAssertEqual(studio.mastheadFrames, event.mastheadFrames)
            let saved = try JSONDecoder().decode(EventProfile.self, from: JSONEncoder().encode(profile))
            XCTAssertEqual(saved.receiptHeader, profile.receiptHeader)
            let restored = try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: saved)
            XCTAssertEqual(restored.mastheadFrames, event.mastheadFrames)
            XCTAssertEqual(restored.customHeaderFrame, event.customHeaderFrame)
            for x in [-48.0, 48] {
                for y in [-48.0, 48] {
                    profile.receiptHeader.editCoBranded { $0.compositionScale = 0.75 }
                    profile.receiptHeader = ReceiptComposer.translateCoBrandedHeader(profile.receiptHeader, horizontal: x, vertical: y)
                    let plan = try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: profile)
                    let cross = try XCTUnwrap(plan.coBrandSeparatorFrame)
                    let logo = try XCTUnwrap(plan.customHeaderFrame)
                    XCTAssertEqual(cross.midX, 288)
                    XCTAssertGreaterThanOrEqual(logo.minY, 8)
                    XCTAssertGreaterThanOrEqual(logo.minX, cross.maxX)
                    XCTAssertLessThanOrEqual(logo.maxX, 540)
                    XCTAssertLessThan(max(logo.maxY, plan.mastheadFrames.map(\.maxY).max()!), plan.photoFrames[0].rect.minY)
                }
            }
            let studioBeforeReset = profile.receiptHeader.coBrandedAdjustments!.studioScale
            profile.receiptHeader.resetEventIdentity()
            XCTAssertEqual(profile.receiptHeader.coBrandedAdjustments!.studioScale, studioBeforeReset)
            let eventBeforeReset = profile.receiptHeader.coBrandedAdjustments!.eventPosition
            profile.receiptHeader.resetStudioIdentity()
            XCTAssertEqual(profile.receiptHeader.coBrandedAdjustments!.eventPosition, eventBeforeReset)
        }
    }

    func testMovingBothPreservesAlignmentAndIndependentEditsAtBoundaries() throws {
        var profile = coBranded(try logoIdentifier(.square))
        profile.receiptHeader.scale = 0.6
        profile.receiptHeader.editCoBranded { $0.studioScale = 0.6; $0.studioPosition = 0; $0.eventPosition = 0 }
        let before = try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: profile)
        profile.receiptHeader = ReceiptComposer.translateCoBrandedHeader(profile.receiptHeader, horizontal: 12, vertical: 8)
        let moved = try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: profile)
        XCTAssertEqual(moved.mastheadFrames[0].minX - before.mastheadFrames[0].minX, 12, accuracy: 0.01)
        XCTAssertEqual(moved.customHeaderFrame!.minX - before.customHeaderFrame!.minX, 12, accuracy: 0.01)
        XCTAssertEqual(moved.mastheadFrames[0].minY - before.mastheadFrames[0].minY, 8, accuracy: 0.01)
        XCTAssertEqual(moved.customHeaderFrame!.minY - before.customHeaderFrame!.minY, 8, accuracy: 0.01)
        profile.receiptHeader = ReceiptComposer.translateCoBrandedHeader(profile.receiptHeader, horizontal: 48, vertical: -48)
        let boundary = try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: profile)
        profile.receiptHeader.scale = 1
        profile.receiptHeader.editCoBranded { $0.eventPosition = 1; $0.eventY = -48 }
        let edited = try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: profile)
        XCTAssertEqual(edited.mastheadFrames, boundary.mastheadFrames)
        let logo = edited.customHeaderFrame
        profile.receiptHeader.editCoBranded { $0.studioScale = 1; $0.studioY = 48 }
        XCTAssertEqual(try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: profile).customHeaderFrame, logo)
    }

    func testAdjustedHeaderUsesProductionStripAndThermalRaster() throws {
        var profile = coBranded(try logoIdentifier(.square))
        profile.receiptHeader.editCoBranded { $0.studioScale = 0.7; $0.studioY = -12; $0.eventY = 24; $0.compositionScale = 0.8 }
        let receipt = try compose(format: .solo, profile: profile, qr: false)
        let strip = ReceiptComposer.renderHeaderStrip(eventProfile: profile)
        let plan = try ReceiptComposer.makeLayoutPlan(format: .solo, includesGalleryQRCode: false, eventProfile: profile, date: Self.date)
        XCTAssertEqual(strip.artworkFrame, plan.customHeaderFrame)
        let raster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receipt.imagePNGData)), purpose: .completeReceipt)
        XCTAssertEqual(raster.width, 576)
        let thermal = try XCTUnwrap(UIImage(data: raster.previewPNGData)?.cgImage)
        XCTAssertGreaterThan(darkFraction(in: thermal, rect: plan.mastheadFrames[0]), 0.02)
        XCTAssertGreaterThan(darkFraction(in: thermal, rect: try XCTUnwrap(plan.coBrandSeparatorFrame)), 0.04)
    }

    // MARK: Helpers

    private func coBranded(_ identifier: String) -> EventProfile {
        var profile = EventProfile(isEnabled: true, eventName: "Sample Institute", subtitle: "", includeEventDate: false, eventDate: Self.date, shortMessage: "")
        profile.showEventTextBlock = false
        profile.receiptHeader = .coBrandedRecommended
        profile.receiptHeader.assetIdentifier = identifier
        return profile
    }

    private func render(format: BoothFormat, profile: EventProfile?, qr: Bool, name: String, passport: PassportSessionData? = nil) throws {
        let receipt = try compose(format: format, profile: profile, qr: qr, passport: passport)
        attachPNG(receipt.imagePNGData, name: name)
        let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        let raster = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        attachPNG(raster.previewPNGData, name: "\(name)_thermal")
        XCTAssertEqual(receipt.width, BoothConfiguration.receiptWidth)
    }

    private func attachPNG(_ data: Data, name: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func compose(format: BoothFormat, profile: EventProfile?, qr: Bool, passport: PassportSessionData? = nil) throws -> ComposedReceipt {
        try ReceiptComposer.compose(
            photos: (0..<format.photoCount).map(samplePhoto),
            sessionIdentifier: ReceiptComposer.makeSessionIdentifier(date: Self.date),
            date: Self.date,
            galleryURL: Self.galleryURL,
            format: format,
            eventProfile: profile,
            passport: format == .passport ? (passport ?? .photoPassDebugFixture) : nil,
            printOptions: ReceiptPrintOptions(includesPrintedGalleryQR: qr)
        )
    }

    /// A tonal ceiling-light scene, similar to the reference photograph.
    private func samplePhoto(_ index: Int) -> UIImage {
        let size = CGSize(width: 1200, height: 1600)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let colors = [UIColor(white: 0.72, alpha: 1).cgColor, UIColor(white: 0.42, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            UIColor(white: 0.2, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 300, width: 110, height: 700))
            cg.fill(CGRect(x: 700, y: 0, width: 360, height: 90))
            let center = CGPoint(x: size.width * (0.45 + 0.1 * CGFloat(index % 3)), y: size.height * 0.55)
            let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: [UIColor.white.cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
            cg.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 420, options: [])
            UIColor(white: 0.3, alpha: 1).setStroke()
            cg.setLineWidth(8)
            cg.strokeEllipse(in: CGRect(x: center.x - 130, y: center.y - 110, width: 260, height: 220))
        }
    }

    /// Generic stand-in event marks (never a real organisation's logo).
    private func logoIdentifier(_ kind: LogoKind) throws -> String {
        let store = try EventHeaderAssetStore()
        if kind == .vectorPDF {
            let data = NSMutableData()
            let bounds = CGRect(x: 0, y: 0, width: 360, height: 120)
            UIGraphicsBeginPDFContextToData(data, bounds, nil)
            UIGraphicsBeginPDFPage()
            drawSealLogo(in: bounds, context: UIGraphicsGetCurrentContext()!)
            UIGraphicsEndPDFContext()
            return try store.importArtworkData(data as Data)
        }
        let size: CGSize = switch kind {
        case .wideSeal, .vectorPDF: CGSize(width: 1080, height: 360)
        case .square: CGSize(width: 800, height: 800)
        case .veryWide: CGSize(width: 2400, height: 220)
        case .tall: CGSize(width: 300, height: 1200)
        case .largeTransparent: CGSize(width: 2400, height: 1600)
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            switch kind {
            case .square, .tall: drawSeal(in: CGRect(x: 0, y: (size.height - size.width) / 2, width: size.width, height: size.width).insetBy(dx: size.width * 0.04, dy: size.width * 0.04), context: context.cgContext)
            default: drawSealLogo(in: CGRect(origin: .zero, size: size), context: context.cgContext)
            }
        }
        return try store.importArtworkData(XCTUnwrap(image.pngData()))
    }

    private func drawSealLogo(in rect: CGRect, context: CGContext) {
        let sealSide = rect.height * 0.92
        drawSeal(in: CGRect(x: rect.minX + rect.height * 0.04, y: rect.midY - sealSide / 2, width: sealSide, height: sealSide), context: context)
        let navy = UIColor(red: 0.07, green: 0.12, blue: 0.24, alpha: 1)
        let textX = rect.minX + rect.height * 1.08
        let big = UIFont.systemFont(ofSize: rect.height * 0.52, weight: .black)
        NSString(string: "SIM").draw(at: CGPoint(x: textX, y: rect.minY + rect.height * 0.08), withAttributes: [.font: big, .foregroundColor: navy])
        let small = UIFont.systemFont(ofSize: rect.height * 0.085, weight: .bold)
        NSString(string: "SAMPLE INSTITUTE OF MEDICINE").draw(at: CGPoint(x: textX + rect.height * 0.02, y: rect.minY + rect.height * 0.72), withAttributes: [.font: small, .foregroundColor: navy])
    }

    private func drawSeal(in rect: CGRect, context: CGContext) {
        let navy = UIColor(red: 0.07, green: 0.12, blue: 0.24, alpha: 1)
        navy.setStroke()
        context.setLineWidth(rect.width * 0.035)
        context.strokeEllipse(in: rect.insetBy(dx: rect.width * 0.02, dy: rect.width * 0.02))
        context.setLineWidth(rect.width * 0.015)
        context.strokeEllipse(in: rect.insetBy(dx: rect.width * 0.2, dy: rect.width * 0.2))
        context.setLineWidth(rect.width * 0.03)
        context.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.3))
        context.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.3))
        context.strokePath()
        let font = UIFont.systemFont(ofSize: rect.width * 0.08, weight: .bold)
        NSString(string: "1957").draw(at: CGPoint(x: rect.midX - rect.width * 0.1, y: rect.maxY - rect.height * 0.18), withAttributes: [.font: font, .foregroundColor: navy])
    }

    private func darkFraction(in image: CGImage, rect: CGRect) -> Double {
        let width = Int(rect.width), height = Int(rect.height)
        guard width > 0, height > 0, let cropped = image.cropping(to: rect.integral) else { return 0 }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Double(pixels.filter { $0 < 128 }.count) / Double(pixels.count)
    }
}
