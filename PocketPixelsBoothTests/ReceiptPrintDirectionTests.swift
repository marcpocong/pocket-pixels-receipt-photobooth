import UIKit
import XCTest
@testable import PocketPixelsBooth

final class ReceiptPrintDirectionTests: XCTestCase {
    func testGuestReceiptsKeepTheirDigitalBorderAndIdentifierWhilePaperEndsAtInk() throws {
        for format in BoothFormat.allCases {
            for footer in ReceiptFooterStyle.allCases {
                let passport: PassportSessionData? = format == .passport ? .photoPassDebugFixture : nil
                let date = Date(timeIntervalSince1970: 1_788_692_040)
                let receipt = try ReceiptComposer.compose(
                    photos: (0..<format.photoCount).map { ReliabilityFixtures.syntheticPhoto(session: 723, photo: $0, format: format) },
                    sessionIdentifier: "PP-20260907-161400", date: date,
                    galleryURL: URL(string: "https://example.com/gallery")!, format: format,
                    passport: passport, printOptions: ReceiptPrintOptions(footerStyle: footer)
                )
                let plan = try ReceiptComposer.makeLayoutPlan(format: format, passport: passport, date: date, footerStyle: footer)
                let raster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receipt.imagePNGData)), purpose: .completeReceipt)
                let lastInk = try XCTUnwrap((0..<raster.height).reversed().first { row in
                    raster.rasterData[(row * raster.widthBytes)..<((row + 1) * raster.widthBytes)].contains { $0 != 0 }
                })
                XCTAssertGreaterThan(plan.sessionIdentifierFrame.height, 0)
                XCTAssertGreaterThanOrEqual(CGFloat(lastInk), plan.sessionIdentifierFrame.minY, "Guest support ID must still print")
                XCTAssertLessThan(CGFloat(lastInk), plan.sessionIdentifierFrame.maxY)
                XCTAssertGreaterThanOrEqual(raster.height - lastInk - 1, 28, "\(format) / \(footer): retain the digital receipt's normal border")
                let envelope = try makeEnvelope(raster)
                XCTAssertEqual(envelope.imageHeight, lastInk + 1)
                XCTAssertEqual(envelope.rasterByteCount, (lastInk + 1) * raster.widthBytes)
                assertRotatedPixels(envelope.payload.subdata(in: envelope.rasterDataRange), match: raster)
                print("Guest bottom margin: \(format.rawValue), \(footer.rawValue), digital \(raster.height - lastInk - 1) dots, paper 0 dots")
            }
        }
    }

    func testFooterFirstRotatesEveryPixelWithoutMirroringClippingOrChangingThePreview() throws {
        // Unequal corner marks and an odd height spanning two header bytes catch a
        // vertical flip, a horizontal flip, a byte-only reversal and lost edge rows.
        let height = 267
        let image = UIGraphicsImageRenderer(size: CGSize(width: 576, height: height)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 576, height: height))
            UIColor.black.setFill()
            for rect in [CGRect(x: 0, y: 0, width: 1, height: 1),
                         CGRect(x: 560, y: 3, width: 16, height: 5),
                         CGRect(x: 7, y: 240, width: 9, height: 27),
                         CGRect(x: 550, y: 260, width: 26, height: 7),
                         CGRect(x: 103, y: 97, width: 61, height: 37)] {
                context.fill(rect)
            }
        }
        let raster = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        let preview = raster.previewPNGData
        let uprightCommand = raster.rasterCommand
        let envelope = try makeEnvelope(raster)
        let printed = envelope.payload.subdata(in: envelope.rasterDataRange)

        assertRotatedPixels(printed, match: raster)
        XCTAssertEqual(envelope.imageWidth, 576)
        XCTAssertEqual(envelope.imageHeight, height)
        XCTAssertEqual(envelope.payload[8], 11)
        XCTAssertEqual(envelope.payload[9], 1)
        XCTAssertEqual(raster.previewPNGData, preview)
        XCTAssertEqual(raster.rasterCommand, uprightCommand, "Preparing a send must not rotate the stored receipt")
        try envelope.verifyPayloadIntegrity()
    }

    func testAllReceiptSourcesAndCopiesShareOneFooterFirstPayload() throws {
        let raster = try legacyRaster()
        let originalCommand = raster.rasterCommand
        let batchID = UUID()
        let expected = try makeEnvelope(raster).payload
        for source in PrintJobSource.allCases {
            for policy in ProductionPrintTransportPolicy.allCases {
                for copy in 1...3 {
                    let envelope = try PrintJobEnvelope.receipt(
                        rasterizedImage: raster, sessionIdentifier: "PP-DIRECTION",
                        source: source, copyIndex: copy, copyCount: 3,
                        batchID: batchID, transportPolicy: policy
                    )
                    XCTAssertEqual(envelope.payload, expected, "\(source) / \(policy) / copy \(copy)")
                    XCTAssertEqual(envelope.source, source)
                    XCTAssertEqual(envelope.copyIndex, copy)
                    XCTAssertEqual(envelope.batchID, batchID)
                    XCTAssertEqual(envelope.rasterDataRange.lowerBound, 10)
                    XCTAssertEqual(envelope.imageHeight, 3, "Only the entirely blank tail of this archived fixture is removed")
                    XCTAssertEqual(envelope.rasterByteCount, envelope.imageHeight * raster.widthBytes)
                    XCTAssertEqual(envelope.sanitizationReport.originalByteCount, envelope.rasterByteCount)
                    XCTAssertEqual(envelope.sanitizationReport.sanitizedByteCount, envelope.rasterByteCount)
                    XCTAssertEqual(envelope.payload.prefix(2), Data([0x1B, 0x40]))
                    XCTAssertEqual(envelope.payload.subdata(in: envelope.rasterDataRange.upperBound..<envelope.payload.count),
                                   Data([0x1D, 0x56, 0x42, 0x00]), "No extra feed between header and cut")
                    try envelope.verifyPayloadIntegrity()
                }
            }
        }
        XCTAssertEqual(raster.rasterCommand, originalCommand, "Copies and archived reprints always start from the upright frozen raster")
    }

    func testOldArchivesAreSanitizedAfterRotationWithoutChangingTheirStoredRaster() throws {
        let raster = try legacyRaster()
        let upright = raster.rasterData
        XCTAssertEqual(raster.sanitizationReport.modifiedByteCount, 0)
        let envelope = try makeEnvelope(raster, source: .archivedReprint)
        let pixels = envelope.payload.subdata(in: envelope.rasterDataRange)
        // These harmless upright pixels become DLE EOT / DLE DC4 when rotated.
        XCTAssertEqual(envelope.sanitizationReport.dleEOTPatternCount, 1)
        XCTAssertEqual(envelope.sanitizationReport.dleDC4PatternCount, 1)
        XCTAssertEqual(envelope.sanitizationReport.modifiedByteCount, 2)
        XCTAssertTrue(envelope.sanitizationReport.finalSafetyScanPassed)
        try RasterCommandSanitizer.validateNoReservedPatterns(in: pixels)
        XCTAssertEqual(raster.rasterData, upright)
        XCTAssertEqual(envelope.payload, try makeEnvelope(raster, source: .archivedReprint).payload)
    }

    func testNewReceiptPreviewAlreadyIncludesAnyRotatedSafetyCorrections() throws {
        let legacy = try legacyRaster()
        let image = UIGraphicsImageRenderer(size: CGSize(width: legacy.width, height: legacy.height)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: legacy.width, height: legacy.height))
            UIColor.black.setFill()
            for y in 0..<legacy.height {
                for x in 0..<legacy.width where isBlack(legacy.rasterData, x: x, y: y, widthBytes: legacy.widthBytes) {
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        let raster = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        XCTAssertEqual(raster.sanitizationReport.modifiedByteCount, 2)
        try RasterCommandSanitizer.validateNoReservedPatterns(in: raster.rasterData)
        let envelope = try makeEnvelope(raster)
        assertRotatedPixels(envelope.payload.subdata(in: envelope.rasterDataRange), match: raster)
        XCTAssertEqual(envelope.sanitizationReport.modifiedByteCount, raster.sanitizationReport.modifiedByteCount,
                       "No additional dot changes after preparing the upright preview")
        XCTAssertEqual(envelope.sanitizationReport.modifiedByteOffsets,
                       raster.sanitizationReport.modifiedByteOffsets.map { envelope.rasterByteCount - 1 - $0 }.sorted())
    }

    func testPrintPreparationLeavesNormalGalleryAndPreviewCopiesUntouched() throws {
        for footer in ReceiptFooterStyle.allCases {
            let receipt = try ReceiptComposer.compose(
                photos: [ReliabilityFixtures.syntheticPhoto(session: 724, photo: 0, format: .solo)],
                sessionIdentifier: "PP-DIGITAL-BORDER", format: .solo,
                printOptions: ReceiptPrintOptions(footerStyle: footer)
            )
            let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
            let monochrome = try MonochromeReceiptRenderer.render(image)
            let raster = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
            let thermalPNG = raster.previewPNGData
            let command = raster.rasterCommand
            if footer == .integratedGalleryQR {
                for (name, bytes) in [("balanced-digital-black-and-white", monochrome.pngData),
                                      ("balanced-digital-thermal", thermalPNG)] {
                    let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.png")
                    attachment.name = name
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
            let first = try makeEnvelope(raster)
            let second = try makeEnvelope(raster)
            XCTAssertLessThan(first.imageHeight, receipt.height)
            XCTAssertEqual(first.payload, second.payload)
            XCTAssertEqual(raster.rasterCommand, command)
            XCTAssertEqual(raster.previewPNGData, thermalPNG)
            for bytes in [receipt.imagePNGData, monochrome.pngData, thermalPNG,
                          try GalleryUploadPreparation.preparedReceiptData(from: image),
                          try GalleryUploadPreparation.preparedMonochromeReceiptData(from: image)] {
                let digital = try XCTUnwrap(UIImage(data: bytes)?.cgImage)
                XCTAssertEqual(digital.width, receipt.width)
                XCTAssertEqual(digital.height, receipt.height, "Gallery, smooth and thermal images keep the full digital canvas")
            }
        }
    }

    func testEntirelyBlankReceiptKeepsAValidHeight() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 576, height: 17)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 576, height: 17))
        }
        let raster = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        let envelope = try makeEnvelope(raster)
        XCTAssertEqual(envelope.imageHeight, 17)
        XCTAssertEqual(envelope.rasterByteCount, 72 * 17)
        try envelope.verifyPayloadIntegrity()
    }

    func testPhotoDiagnosticsKeepTheCallersOrientationAndFeedSequence() throws {
        let raster = try legacyRaster()
        let heading = ThermalImageRasterizer.photoTestHeading()
        let finishing = ThermalImageRasterizer.photoTestFinishing()
        let envelope = try PrintJobEnvelope.diagnostic(
            heading: heading, rasterizedImage: raster, finishing: finishing,
            sessionIdentifier: "diagnostic", copyIndex: 1, copyCount: 1,
            batchID: UUID(), transportPolicy: .safeIntegrity
        )
        XCTAssertEqual(envelope.payload, heading + raster.rasterCommand + finishing)
        XCTAssertEqual(envelope.payload.subdata(in: envelope.rasterDataRange), raster.rasterData)
    }

    private func makeEnvelope(_ raster: ThermalRasterizedImage, source: PrintJobSource = .liveCustomer) throws -> PrintJobEnvelope {
        try PrintJobEnvelope.receipt(
            rasterizedImage: raster, sessionIdentifier: "PP-DIRECTION", source: source,
            copyIndex: 1, copyCount: 1, batchID: UUID(), transportPolicy: .safeIntegrity
        )
    }

    /// Simulates an older archive, safe in its stored orientation only.
    private func legacyRaster() throws -> ThermalRasterizedImage {
        let height = 17
        var data = Data(repeating: 0, count: 72 * height)
        data.replaceSubrange(80..<83, with: [0x80, 0x20, 0x08])
        data.replaceSubrange(170..<175, with: [0x10, 0x80, 0x80, 0x28, 0x08])
        let sanitized = try RasterCommandSanitizer.sanitizeRasterData(data)
        let command = Data([0x1D, 0x76, 0x30, 0x00, 0x48, 0x00, UInt8(height), 0]) + sanitized.data
        return ThermalRasterizedImage(
            width: 576, height: height, widthBytes: 72, previewPNGData: Data(),
            rasterData: sanitized.data, rasterCommand: command, sanitizationReport: sanitized.report,
            yL: UInt8(height), yH: 0
        )
    }

    private func assertRotatedPixels(_ printed: Data, match raster: ThermalRasterizedImage, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(printed.count % raster.widthBytes, 0, file: file, line: line)
        let printHeight = printed.count / raster.widthBytes
        XCTAssertGreaterThan(printHeight, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(printHeight, raster.height, file: file, line: line)
        guard printHeight > 0, printHeight <= raster.height else { return }
        XCTAssertFalse(raster.rasterData.dropFirst(printed.count).contains { $0 != 0 }, "Only entirely white rows may be removed", file: file, line: line)
        var mismatches = 0
        for y in 0..<printHeight {
            for x in 0..<raster.width {
                if isBlack(printed, x: x, y: y, widthBytes: raster.widthBytes) !=
                    isBlack(raster.rasterData, x: raster.width - 1 - x, y: printHeight - 1 - y, widthBytes: raster.widthBytes) {
                    mismatches += 1
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "Printed pixels must be a complete 180-degree rotation", file: file, line: line)
    }

    private func isBlack(_ pixels: Data, x: Int, y: Int, widthBytes: Int) -> Bool {
        pixels[y * widthBytes + x / 8] & (0x80 >> UInt8(x % 8)) != 0
    }
}
