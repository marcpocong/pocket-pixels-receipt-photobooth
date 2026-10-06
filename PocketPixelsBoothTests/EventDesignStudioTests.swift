import Foundation
import UIKit
import XCTest
@testable import PocketPixelsBooth

/// Event Design Studio: artwork editor geometry, transparent PNG, vector PDF, thermal preview
/// parity and receipt typography.
final class EventDesignStudioTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_793_000_000)
    private let receiptWidth = CGFloat(BoothConfiguration.receiptWidth)
    private let inset = EventHeaderImageProcessor.horizontalInset

    // MARK: Artwork — formats

    func testTransparentPNGCompositesToWhiteInReceiptAndThermalPreview() throws {
        let store = try EventHeaderAssetStore()
        let identifier = try store.importArtworkData(try XCTUnwrap(transparentMark().pngData()))
        let artwork = try XCTUnwrap(store.loadArtwork(identifier: identifier))
        XCTAssertEqual(artwork.kind, .bitmap)

        let configuration = artworkConfiguration(identifier)
        let strip = EventHeaderImageProcessor.receiptStrip(source: artwork, configuration: configuration)
        // A transparent corner of the artwork frame is paper white, never black.
        let corner = try rgba(strip.image, x: Int(strip.frame.minX) + 2, y: Int(strip.frame.minY) + 2)
        XCTAssertEqual(corner.r, 255); XCTAssertEqual(corner.g, 255); XCTAssertEqual(corner.b, 255)

        let thermal = try EventHeaderImageProcessor.thermalPreview(source: artwork, configuration: configuration)
        XCTAssertEqual(try rgba(thermal, x: Int(strip.frame.minX) + 2, y: Int(strip.frame.minY) + 2).r, 255, "Transparent area prints as blank paper")
        XCTAssertEqual(try rgba(thermal, x: Int(strip.frame.midX), y: Int(strip.frame.midY)).r, 0, "Opaque mark prints black")

        var profile = makeProfile()
        profile.receiptHeader = configuration
        profile.showEventTextBlock = false
        let receipt = try compose(profile, format: .solo)
        let frame = try XCTUnwrap(try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: profile).customHeaderFrame)
        let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        XCTAssertEqual(try rgba(image, x: Int(frame.minX) + 2, y: Int(frame.minY) + 2).r, 255)
        XCTAssertLessThan(try rgba(image, x: Int(frame.midX), y: Int(frame.midY)).r, 20)
    }

    func testJPEGArtworkRemainsSupported() throws {
        let jpeg = try XCTUnwrap(solid(CGSize(width: 900, height: 300), .black).jpegData(compressionQuality: 0.9))
        let store = try EventHeaderAssetStore()
        let identifier = try store.importArtworkData(jpeg)
        let artwork = try XCTUnwrap(store.loadArtwork(identifier: identifier))
        XCTAssertEqual(artwork.kind, .bitmap)
        var profile = makeProfile()
        profile.receiptHeader = artworkConfiguration(identifier)
        for format in BoothFormat.allCases {
            XCTAssertNoThrow(try compose(profile, format: format), "\(format)")
        }
    }

    func testSinglePagePDFImportsAsVectorAndRendersAtReceiptResolution() throws {
        // A 60 × 20 pt page: tiny as a bitmap, but vector artwork renders sharply at 520+ dots.
        let pdf = makePDF(pages: 1, size: CGSize(width: 60, height: 20)) { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
        }
        let store = try EventHeaderAssetStore()
        let identifier = try store.importArtworkData(pdf)
        let artwork = try XCTUnwrap(store.loadArtwork(identifier: identifier))
        XCTAssertEqual(artwork.kind, .vector)
        XCTAssertEqual(artwork.size, CGSize(width: 60, height: 20))
        XCTAssertTrue(store.contains(identifier: identifier))

        let configuration = artworkConfiguration(identifier)
        let rendered = EventHeaderImageProcessor.renderedHeader(source: artwork, configuration: configuration)
        XCTAssertEqual(rendered.frameSize.width, receiptWidth - inset * 2)
        // Left half black, right half white, with a crisp edge at the vector boundary.
        let midY = Int(rendered.frameSize.height / 2)
        let edge = Int(rendered.frameSize.width / 2)
        XCTAssertLessThan(try rgba(rendered.image, x: edge - 3, y: midY).r, 10)
        XCTAssertGreaterThan(try rgba(rendered.image, x: edge + 3, y: midY).r, 245)

        XCTAssertTrue(EventHeaderImageProcessor.qualityWarnings(for: artwork, configuration: configuration).allSatisfy { $0 != .lowResolution },
                      "Vector artwork is never flagged as low resolution")

        var profile = makeProfile()
        profile.receiptHeader = configuration
        for format in BoothFormat.allCases {
            let receipt = try compose(profile, format: format)
            XCTAssertLessThanOrEqual(receipt.height, BoothConfiguration.receiptMaximumHeight)
        }
    }

    func testMultiPageAndUnreadableArtworkAreRejectedCleanly() throws {
        let store = try EventHeaderAssetStore()
        let twoPages = makePDF(pages: 2, size: CGSize(width: 100, height: 40)) { _ in }
        XCTAssertThrowsError(try store.importArtworkData(twoPages)) { error in
            XCTAssertEqual(error as? EventArtworkError, .multiPagePDF(pageCount: 2))
        }
        XCTAssertThrowsError(try store.importArtworkData(Data("%PDF-1.7 broken".utf8)))
        XCTAssertThrowsError(try store.importArtworkData(Data([0x00, 0x01, 0x02])))
        XCTAssertNil(store.loadArtwork(identifier: "not-a-uuid"))
        XCTAssertNil(store.loadArtwork(identifier: UUID().uuidString.lowercased()))
    }

    // MARK: Artwork — geometry and safety

    func testArtworkFrameAlwaysStaysInsidePrintableBounds() {
        let sources = [CGSize(width: 4_000, height: 10), CGSize(width: 10, height: 4_000), CGSize(width: 300, height: 300), .zero, CGSize(width: CGFloat.nan, height: 5)]
        let positions: [Double?] = [nil, -50, -1, -0.37, 0, 0.5, 1, 50, .nan, .infinity]
        for source in sources {
            for mode in ReceiptHeaderLayoutMode.allCases {
                for position in positions {
                    for scale in [-3, 0, 0.5, 0.77, 1, 1.35, 9, Double.nan] {
                        var config = ReceiptHeaderConfiguration.default
                        config.layoutMode = mode
                        config.horizontalPosition = position
                        config.scale = scale
                        config.fillHeightRatio = 4
                        let frame = EventHeaderImageProcessor.frameRect(sourceSize: source, configuration: config, y: 10)
                        XCTAssertTrue(frame.minX.isFinite && frame.width.isFinite && frame.height.isFinite)
                        XCTAssertGreaterThan(frame.width, 0)
                        XCTAssertGreaterThanOrEqual(frame.minX, inset - 0.001)
                        XCTAssertLessThanOrEqual(frame.maxX, receiptWidth - inset + 0.001)
                        XCTAssertLessThanOrEqual(frame.height, EventHeaderImageProcessor.maximumPrintedHeight)
                        XCTAssertGreaterThanOrEqual(frame.height, EventHeaderImageProcessor.minimumPrintedHeight)
                    }
                }
            }
        }
    }

    func testLegacyAlignmentAndNewHorizontalPositionAgree() {
        var config = ReceiptHeaderConfiguration.default
        config.scale = 0.6
        let source = CGSize(width: 600, height: 200)
        let expectations: [(ReceiptHeaderAlignment, Double)] = [(.left, -1), (.center, 0), (.right, 1)]
        for (alignment, position) in expectations {
            var legacy = config
            legacy.alignment = alignment
            var explicit = config
            explicit.horizontalPosition = position
            XCTAssertEqual(
                EventHeaderImageProcessor.frameRect(sourceSize: source, configuration: legacy, y: 0),
                EventHeaderImageProcessor.frameRect(sourceSize: source, configuration: explicit, y: 0)
            )
        }
        let left = EventHeaderImageProcessor.frameRect(sourceSize: source, configuration: { var c = config; c.align(.left); return c }(), y: 0)
        XCTAssertEqual(left.minX, inset)
    }

    func testFillBannerHeightAndZoomAreBoundedAndDeterministic() {
        let artwork = EventArtwork(image: solid(CGSize(width: 1_000, height: 1_000), .black))
        var config = ReceiptHeaderConfiguration.default
        config.layoutMode = .fill
        let defaultFrame = EventHeaderImageProcessor.frameSize(sourceSize: artwork.size, configuration: config)
        XCTAssertEqual(defaultFrame.height, floor(defaultFrame.width / 3), "Legacy fill banner is 1:3")

        config.fillHeightRatio = 0.4
        XCTAssertEqual(EventHeaderImageProcessor.frameSize(sourceSize: artwork.size, configuration: config).height, floor(defaultFrame.width * 0.4))
        config.fillHeightRatio = 1
        XCTAssertEqual(EventHeaderImageProcessor.frameSize(sourceSize: artwork.size, configuration: config).height, EventHeaderImageProcessor.maximumPrintedHeight, "Tall banners stop at the safe maximum height")
        config.fillHeightRatio = 0.01
        XCTAssertEqual(config.normalized().fillHeightRatio, ReceiptHeaderConfiguration.fillHeightRatioRange.lowerBound)
        config.cropZoom = 99
        XCTAssertEqual(config.normalized().cropZoom, ReceiptHeaderConfiguration.maximumZoom)

        let first = EventHeaderImageProcessor.receiptStrip(source: artwork, configuration: config).image.pngData()
        let second = EventHeaderImageProcessor.receiptStrip(source: artwork, configuration: config).image.pngData()
        XCTAssertEqual(first, second)
    }

    func testResetClearsEditorAdjustmentsButKeepsArtwork() {
        var config = ReceiptHeaderConfiguration.default
        config.mode = .customEventHeader
        config.assetIdentifier = "abc"
        config.horizontalPosition = 0.4
        config.fillHeightRatio = 0.7
        config.layoutMode = .fill
        config.cropZoom = 2
        config.resetAdjustments()
        XCTAssertNil(config.horizontalPosition)
        XCTAssertNil(config.fillHeightRatio)
        XCTAssertEqual(config.layoutMode, .fit)
        XCTAssertEqual(config.cropZoom, 1)
        XCTAssertEqual(config.assetIdentifier, "abc")
        XCTAssertEqual(config.mode, .customEventHeader)
    }

    func testExtremeArtworkSettingsKeepEveryFormatWithinMaximumHeight() throws {
        let tallPDF = makePDF(pages: 1, size: CGSize(width: 20, height: 900)) { context in
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 900))
        }
        let identifier = try EventHeaderAssetStore().importArtworkData(tallPDF)
        var profile = makeProfile()
        profile.receiptHeader = artworkConfiguration(identifier)
        profile.receiptHeader.topSpacing = 1_000
        profile.receiptHeader.bottomSpacing = 1_000
        profile.receiptHeader.scale = 50
        profile.receiptDesign.typography.preset = .bold
        applyLongestText(&profile)
        for format in BoothFormat.allCases {
            let plan = try ReceiptComposer.makeLayoutPlan(format: format, eventProfile: profile)
            XCTAssertLessThanOrEqual(plan.height, BoothConfiguration.receiptMaximumHeight)
            XCTAssertLessThanOrEqual(try XCTUnwrap(plan.customHeaderFrame).height, EventHeaderImageProcessor.maximumPrintedHeight)
            if let photoTop = plan.photoFrames.map(\.rect.minY).min(), format != .passport {
                XCTAssertLessThanOrEqual(try XCTUnwrap(plan.customHeaderFrame).maxY, photoTop, "Artwork never overlaps photos")
            }
        }
    }

    /// The editor's Thermal view must be what the printer receives for those rows.
    func testThermalPreviewMatchesProductionReceiptRaster() throws {
        let identifier = try EventHeaderAssetStore().importArtworkData(try XCTUnwrap(gradientArtwork().pngData()))
        let artwork = try XCTUnwrap(try EventHeaderAssetStore().loadArtwork(identifier: identifier))
        var profile = makeProfile()
        profile.receiptHeader = artworkConfiguration(identifier)
        profile.receiptHeader.scale = 0.8
        profile.receiptHeader.horizontalPosition = 0.3
        profile.showEventTextBlock = false

        let plan = try ReceiptComposer.makeLayoutPlan(format: .solo, includesGalleryQRCode: false, eventProfile: profile)
        let headerFrame = try XCTUnwrap(plan.customHeaderFrame)
        let stripTop = Int(headerFrame.minY) - Int(profile.receiptHeader.topSpacing.rounded())

        let receipt = try compose(profile, format: .solo, gallery: false)
        let receiptRaster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receipt.imagePNGData)), purpose: .completeReceipt)
        let strip = EventHeaderImageProcessor.receiptStrip(source: artwork, configuration: profile.receiptHeader)
        let stripRaster = try ThermalImageRasterizer.rasterize(strip.image, purpose: .completeReceipt)

        let bytesPerRow = ThermalImageRasterizer.widthBytes
        // Compare the artwork rows themselves (frame top to frame bottom).
        let firstRow = Int(strip.frame.minY)
        let lastRow = Int(strip.frame.maxY)
        let fromReceipt = receiptRaster.rasterData.subdata(in: ((stripTop + firstRow) * bytesPerRow)..<((stripTop + lastRow) * bytesPerRow))
        let fromStrip = stripRaster.rasterData.subdata(in: (firstRow * bytesPerRow)..<(lastRow * bytesPerRow))
        XCTAssertEqual(fromReceipt, fromStrip)

        let preview = try EventHeaderImageProcessor.thermalPreview(source: artwork, configuration: profile.receiptHeader)
        XCTAssertEqual(preview.pngData(), UIImage(data: stripRaster.previewPNGData)?.pngData())
    }

    // MARK: Artwork — sessions and archives

    func testSessionArtworkIsFrozenAndCannotLeakIntoLaterSession() throws {
        let store = try EventHeaderAssetStore()
        let blackID = try store.importArtworkData(makePDF(pages: 1, size: CGSize(width: 300, height: 100)) { context in
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
        })
        var active = makeProfile()
        active.receiptHeader = artworkConfiguration(blackID)
        active.showEventTextBlock = false
        let sessionA = try XCTUnwrap(active.activeReceiptSnapshot)

        // Operator replaces the artwork while A is in progress.
        let whiteID = try store.importArtworkData(try XCTUnwrap(solid(CGSize(width: 300, height: 100), .white).pngData()))
        active.receiptHeader = artworkConfiguration(whiteID)
        let sessionB = try XCTUnwrap(active.activeReceiptSnapshot)

        let frameA = try XCTUnwrap(try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: sessionA).customHeaderFrame)
        let imageA = try XCTUnwrap(UIImage(data: try compose(sessionA, format: .solo).imagePNGData))
        let imageB = try XCTUnwrap(UIImage(data: try compose(sessionB, format: .solo).imagePNGData))
        XCTAssertLessThan(try rgba(imageA, x: Int(frameA.midX), y: Int(frameA.midY)).r, 20, "A keeps its own artwork")
        XCTAssertGreaterThan(try rgba(imageB, x: Int(frameA.midX), y: Int(frameA.midY)).r, 235, "B never shows A's artwork")
        XCTAssertEqual(sessionA.receiptHeader.assetIdentifier, blackID)
    }

    func testArchivedReprintKeepsFrozenArtworkAfterSettingsChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try RecentSessionArchiveStore(directoryURL: directory)
        let assets = try EventHeaderAssetStore()
        let artworkA = try assets.importArtworkData(try XCTUnwrap(transparentMark().pngData()))

        var profile = makeProfile()
        profile.receiptHeader = artworkConfiguration(artworkA)
        profile.receiptDesign.typography.preset = .editorial
        let token = String(repeating: "e", count: 64)
        let committed = CommittedGallerySession(
            sessionIdentifier: "PP-ART-ARCHIVE",
            createdAt: date,
            galleryToken: token,
            galleryURL: URL(string: "https://example.com/?g=\(token)")!,
            photos: [ReliabilityFixtures.syntheticPhoto(session: 31, photo: 1, format: .solo)],
            format: .solo,
            eventProfile: profile.activeReceiptSnapshot
        )
        let receipt = try ReceiptComposer.compose(photos: committed.photos, sessionIdentifier: committed.sessionIdentifier, date: date, galleryURL: committed.galleryURL, format: .solo, eventProfile: committed.eventProfile)
        let raster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receipt.imagePNGData)), purpose: .completeReceipt)
        try archive.save(RecentSessionArchivePayload(committedSession: committed, composedReceipt: receipt, receiptPreviewPNGData: receipt.imagePNGData, thermalPreviewPNGData: raster.previewPNGData, rasterizedImage: raster, photoThumbnailData: [Data([1])]))

        // Later: new artwork, new typography.
        profile.receiptHeader = artworkConfiguration(try assets.importArtworkData(try XCTUnwrap(solid(CGSize(width: 50, height: 50), .black).pngData())))
        profile.receiptDesign.typography.preset = .bold

        let loaded = try RecentSessionArchiveStore(directoryURL: directory).load(archiveID: token)
        XCTAssertEqual(loaded.rasterizedImage.rasterCommand, raster.rasterCommand, "Reprint sends the frozen raster")
        XCTAssertEqual(loaded.eventProfile?.receiptHeader.assetIdentifier, artworkA)
        XCTAssertEqual(loaded.eventProfile?.receiptDesign.typography.preset, .editorial)
    }

    // MARK: Compatibility

    func testLegacyProfileWithoutNewFieldsDecodesToClassicAndAlignmentPlacement() throws {
        var profile = makeProfile()
        profile.receiptHeader.mode = .customEventHeader
        profile.receiptHeader.assetIdentifier = "legacy"
        profile.receiptHeader.alignment = .right
        profile.receiptHeader.scale = 0.6
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        object.removeValue(forKey: "receiptDesign")
        var header = try XCTUnwrap(object["receiptHeader"] as? [String: Any])
        header.removeValue(forKey: "horizontalPosition")
        header.removeValue(forKey: "fillHeightRatio")
        object["receiptHeader"] = header

        let decoded = try JSONDecoder().decode(EventProfile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.receiptDesign, .default)
        XCTAssertEqual(decoded.receiptDesign.typography.preset, .classic)
        XCTAssertNil(decoded.receiptHeader.horizontalPosition)
        XCTAssertNil(decoded.receiptHeader.fillHeightRatio)
        XCTAssertEqual(decoded.receiptHeader.effectiveHorizontalPosition, 1)
        XCTAssertEqual(decoded.receiptHeader.alignment, .right)
        XCTAssertEqual(decoded.receiptHeader.scale, 0.6)
    }

    func testUnknownOrCorruptDesignValuesNeverMakeTheProfileUnreadable() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(makeProfile())) as? [String: Any])
        object["receiptDesign"] = ["typography": ["preset": "futuristicNeon", "custom": ["titleFont": "comicSans", "titleSize": "huge", "alignment": 7]]]
        let decoded = try JSONDecoder().decode(EventProfile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.eventName, "MARK & ANNA", "Event data survives")
        XCTAssertEqual(decoded.receiptDesign.typography.preset, .classic)
        XCTAssertEqual(decoded.receiptDesign.typography.custom.titleFont, EventTypographyCustomStyle.default.titleFont)
        XCTAssertEqual(decoded.receiptDesign.typography.custom.titleSize, EventTypographyCustomStyle.default.titleSize)

        object["receiptDesign"] = "not an object"
        let corrupt = try JSONDecoder().decode(EventProfile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(corrupt.receiptDesign, .default)
    }

    func testDesignRoundTripsThroughPersistence() throws {
        var profile = makeProfile()
        profile.receiptHeader.horizontalPosition = -0.25
        profile.receiptHeader.fillHeightRatio = 0.45
        profile.receiptDesign.typography = EventTypographyConfiguration(
            preset: .custom,
            custom: EventTypographyCustomStyle(titleFont: .typewriter, titleWeight: .heavy, titleSize: 30, titleTracking: 1.2, detailsFont: .roundedSans, detailsWeight: .medium, detailsSize: 13, detailsTracking: 0.5, lineSpacing: 2, alignment: .left)
        )
        let decoded = try JSONDecoder().decode(EventProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
    }

    // MARK: Typography

    func testEveryFontFaceIsInstalledAndResolvesDeterministically() {
        for family in EventFontFamily.allCases {
            for weight in EventFontWeight.allCases {
                XCTAssertTrue(EventFontLibrary.isPreferredFaceAvailable(family, weight: weight), "\(family) \(weight) must be installed on iPadOS")
                let first = EventFontLibrary.font(family: family, weight: weight, size: 17)
                let second = EventFontLibrary.font(family: family, weight: weight, size: 17)
                XCTAssertEqual(first.fontName, second.fontName)
                XCTAssertEqual(first.pointSize, 17)
                if let expected = EventFontLibrary.namedFaces[family]?[weight] {
                    XCTAssertEqual(first.fontName, expected)
                }
            }
        }
        XCTAssertEqual(EventFontLibrary.font(family: .modernSans, weight: .bold, size: .nan).pointSize, 12, "Invalid sizes resolve safely")
    }

    func testClassicPresetIsTheLegacyReceiptTypography() {
        XCTAssertEqual(EventTypographyConfiguration.default.preset, .classic)
        XCTAssertEqual(EventProfile.pocketPixelsDefault.receiptDesign.typography.preset, .classic)
        let classic = ResolvedEventTypography.preset(.classic)
        XCTAssertEqual(classic.title.face, EventFontSpec(family: .classicSerif, weight: .bold))
        XCTAssertEqual(classic.title.candidateSizes, [22, 20, 18, 17], "Legacy 22/20/18 → 17 title fitting")
        XCTAssertEqual(classic.title.wrapping, .characters)
        XCTAssertEqual(classic.subtitle.candidateSizes, [13])
        XCTAssertEqual(classic.metadata.face, EventFontSpec(family: .modernSans, weight: .medium, monospacedDigits: true))
        XCTAssertEqual(classic.eyebrow.face, EventFontSpec(family: .monospaced, weight: .semibold))
        XCTAssertTrue(classic.message.uppercased)
        XCTAssertEqual(classic.alignment, .center)
        let legacySerif = UIFont.systemFont(ofSize: 22, weight: .bold).fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 22) }
        XCTAssertEqual(classic.title.face.font(size: 22).fontName, legacySerif?.fontName)
    }

    func testEveryPresetFitsLongestTextInEveryFormatWithoutOverlap() throws {
        let configurations = EventTypographyPreset.allCases.map { EventTypographyConfiguration(preset: $0) } + [
            EventTypographyConfiguration(preset: .custom, custom: EventTypographyCustomStyle(titleFont: .condensedSans, titleWeight: .heavy, titleSize: 40, titleTracking: 4, detailsFont: .typewriter, detailsWeight: .bold, detailsSize: 18, detailsTracking: 4, lineSpacing: 8, alignment: .right)),
            EventTypographyConfiguration(preset: .custom, custom: EventTypographyCustomStyle(titleFont: .editorialSerif, titleWeight: .regular, titleSize: 14, titleTracking: -0.5, detailsFont: .roundedSans, detailsWeight: .regular, detailsSize: 9, detailsTracking: -0.5, lineSpacing: 0, alignment: .left))
        ]
        for configuration in configurations {
            for header in ReceiptHeaderMode.allCases {
                var profile = makeProfile()
                profile.receiptHeader.mode = header
                profile.receiptDesign.typography = configuration
                applyLongestText(&profile)
                for format in BoothFormat.allCases {
                    let plan = try ReceiptComposer.makeLayoutPlan(format: format, eventProfile: profile)
                    XCTAssertLessThanOrEqual(plan.height, BoothConfiguration.receiptMaximumHeight)
                    guard format != .passport else {
                        XCTAssertTrue(plan.eventTextFrames.isEmpty, "Passport keeps its own title area")
                        continue
                    }
                    XCTAssertEqual(plan.eventTextFrames.map(\.role), EventTextRole.allCases, "\(configuration.preset)")
                    var previousBottom: CGFloat = 0
                    for frame in plan.eventTextFrames {
                        XCTAssertTrue(EventTextBlockLayout.fitsHorizontally(frame), "\(configuration.preset) \(frame.role) overflows")
                        XCTAssertGreaterThanOrEqual(frame.rect.minY, previousBottom, "\(frame.role) overlaps the section above")
                        XCTAssertGreaterThanOrEqual(frame.rect.minX, 0)
                        XCTAssertLessThanOrEqual(frame.rect.maxX, receiptWidth)
                        XCTAssertGreaterThanOrEqual(frame.fontSize, 6)
                        previousBottom = frame.rect.maxY
                    }
                    XCTAssertLessThanOrEqual(previousBottom, plan.photoFrames.map(\.rect.minY).min() ?? .greatestFiniteMagnitude)
                }
                // Full render also passes composer validation.
                XCTAssertNoThrow(try compose(profile, format: .duo))
            }
        }
    }

    func testLongTitleShrinksWithinSafeRangeAndShortTitleKeepsPreferredSize() {
        let modern = ResolvedEventTypography.preset(.modern)
        let width = BoothConfiguration.receiptWidth - (BoothConfiguration.receiptHorizontalMargin + 28) * 2
        let short = EventTextBlockLayout.fit("ANNA", style: modern.title, width: width)
        XCTAssertEqual(short.size, modern.title.preferredSize)
        let long = EventTextBlockLayout.fit(String(repeating: "CELEBRATION ", count: 8), style: modern.title, width: width)
        XCTAssertLessThan(long.size, modern.title.preferredSize)
        XCTAssertGreaterThanOrEqual(long.size, modern.title.minimumSize)
    }

    func testCustomTypographyValuesClampAndNormalize() {
        var custom = EventTypographyCustomStyle.default
        custom.titleSize = 400
        custom.detailsSize = -2
        custom.titleTracking = .infinity
        custom.detailsTracking = .nan
        custom.lineSpacing = 99
        let normalized = custom.normalized()
        XCTAssertEqual(normalized.titleSize, EventTypographyCustomStyle.titleSizeRange.upperBound)
        XCTAssertEqual(normalized.detailsSize, EventTypographyCustomStyle.detailsSizeRange.lowerBound)
        XCTAssertTrue(EventTypographyCustomStyle.trackingRange.contains(normalized.titleTracking))
        XCTAssertTrue(EventTypographyCustomStyle.trackingRange.contains(normalized.detailsTracking))
        XCTAssertEqual(normalized.lineSpacing, EventTypographyCustomStyle.lineSpacingRange.upperBound)

        let resolved = ResolvedEventTypography.custom(custom)
        for role in EventTextRole.allCases {
            let style = resolved.style(for: role)
            XCTAssertTrue(style.candidateSizes.allSatisfy { $0.isFinite && $0 >= 6 })
            XCTAssertLessThanOrEqual(style.minimumSize, style.preferredSize)
        }
    }

    func testTypographyLayoutIsDeterministic() throws {
        for preset in EventTypographyPreset.allCases {
            var profile = makeProfile()
            profile.receiptDesign.typography.preset = preset
            let first = try ReceiptComposer.makeLayoutPlan(format: .grid, eventProfile: profile).eventTextFrames
            let second = try ReceiptComposer.makeLayoutPlan(format: .grid, eventProfile: profile).eventTextFrames
            XCTAssertEqual(first, second)
        }
    }

    func testPassportLayoutIsIndependentOfReceiptTypography() throws {
        var classic = makeProfile()
        classic.receiptDesign.typography.preset = .classic
        let reference = try ReceiptComposer.makeLayoutPlan(format: .passport, eventProfile: classic, passport: .debugFixture, date: date)
        for preset in EventTypographyPreset.allCases {
            var profile = classic
            profile.receiptDesign.typography.preset = preset
            let plan = try ReceiptComposer.makeLayoutPlan(format: .passport, eventProfile: profile, passport: .debugFixture, date: date)
            XCTAssertEqual(plan.height, reference.height)
            XCTAssertEqual(plan.photoFrames.map(\.rect), reference.photoFrames.map(\.rect))
            XCTAssertEqual(plan.passportContent?.titleMode, reference.passportContent?.titleMode)
            XCTAssertNoThrow(try compose(profile, format: .passport))
        }
    }

    func testTypographyChangeAffectsOnlySessionsFrozenAfterIt() throws {
        var active = makeProfile()
        active.receiptDesign.typography.preset = .classic
        let sessionA = try XCTUnwrap(active.activeReceiptSnapshot)
        active.receiptDesign.typography.preset = .bold
        let sessionB = try XCTUnwrap(active.activeReceiptSnapshot)
        let titleA = try XCTUnwrap(try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: sessionA).eventTextFrames.first { $0.role == .title })
        let titleB = try XCTUnwrap(try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: sessionB).eventTextFrames.first { $0.role == .title })
        XCTAssertEqual(titleA.face.family, .classicSerif)
        XCTAssertEqual(titleB.face.family, .condensedSans)
        XCTAssertEqual(titleB.text, sessionB.eventName.uppercased())
    }

    // MARK: Helpers

    private func makeProfile() -> EventProfile {
        EventProfile(isEnabled: true, eventName: "MARK & ANNA", subtitle: "OUR WEDDING", includeEventDate: true, eventDate: date, location: "CEBU", shortMessage: "THANK YOU")
    }

    private func artworkConfiguration(_ identifier: String) -> ReceiptHeaderConfiguration {
        var config = ReceiptHeaderConfiguration.default
        config.mode = .customEventHeader
        config.assetIdentifier = identifier
        return config
    }

    private func applyLongestText(_ profile: inout EventProfile) {
        profile.eventName = String(String(repeating: "W", count: 30) + " MAXIMILIAN & ALEXANDRIA").prefix(EventProfile.eventNameLimit).description
        profile.subtitle = String(repeating: "WIDE SUBTITLE ", count: 6).prefix(EventProfile.subtitleLimit).description
        profile.location = String(repeating: "MMMM ", count: 15).prefix(EventProfile.locationLimit).description
        profile.shortMessage = String(repeating: "Thank you for celebrating ", count: 4).prefix(EventProfile.shortMessageLimit).description
        profile.includeEventDate = true
    }

    private func compose(_ profile: EventProfile, format: BoothFormat, gallery: Bool = true) throws -> ComposedReceipt {
        try ReceiptComposer.compose(
            photos: (0..<format.photoCount).map { ReliabilityFixtures.syntheticPhoto(session: 21, photo: $0 + 1, format: format) },
            sessionIdentifier: "PP-DESIGN",
            date: date,
            galleryURL: gallery ? URL(string: "https://example.com/?g=design") : nil,
            format: format,
            eventProfile: profile,
            passport: format == .passport ? .debugFixture : nil
        )
    }

    private func makePDF(pages: Int, size: CGSize, draw: (CGContext) -> Void) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            for _ in 0..<pages {
                context.beginPage()
                draw(context.cgContext)
            }
        }
    }

    private func transparentMark() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 200), format: format).image { context in
            UIColor.clear.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 200))
            UIColor.black.setFill(); context.fill(CGRect(x: 200, y: 50, width: 200, height: 100))
        }
    }

    private func gradientArtwork() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 400, height: 160), format: format).image { context in
            for x in 0..<400 {
                UIColor(white: CGFloat(x) / 400, alpha: x.isMultiple(of: 7) ? 0.4 : 1).setFill()
                context.fill(CGRect(x: x, y: 0, width: 1, height: 160))
            }
        }
    }

    private func solid(_ size: CGSize, _ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func rgba(_ image: UIImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }
}
