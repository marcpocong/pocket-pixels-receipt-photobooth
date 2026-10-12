import UIKit
import XCTest
@testable import PocketPixelsBooth

/// The optional "As printed" preview must be the exact raster the printer receives, for every
/// format, with and without Event Mode branding and the printed gallery QR.
final class ReceiptPreviewAccuracyTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_788_692_040)
    private let galleryURL = URL(string: "https://gallery.example.com/g/\(String(repeating: "d", count: 64))")!

    func testPreviewModeDefaultsToKeepsakeAndFallsBackUntilThermalIsReady() {
        let keepsake = UIImage()
        let thermal = UIImage()
        XCTAssertEqual(ReceiptPreviewMode.allCases.first, .keepsake)
        XCTAssertTrue(ReceiptPreviewMode.keepsake.image(keepsake: keepsake, thermal: thermal) === keepsake)
        XCTAssertTrue(ReceiptPreviewMode.thermal.image(keepsake: keepsake, thermal: thermal) === thermal)
        XCTAssertTrue(ReceiptPreviewMode.thermal.image(keepsake: keepsake, thermal: nil) === keepsake)
        XCTAssertNil(ReceiptPreviewMode.thermal.image(keepsake: nil, thermal: nil))
    }

    func testThermalPreviewIsTheExactOneBitRasterForEveryConfiguration() throws {
        let event = EventProfile(
            isEnabled: true,
            eventName: "Made to Keep Launch Night With An Intentionally Long Event Title",
            subtitle: "Cebu City Waterfront Pavilion",
            includeEventDate: true,
            eventDate: date,
            location: "Cebu City",
            shortMessage: "Thank you for keeping this little moment with us tonight."
        )
        for format in BoothFormat.allCases {
            for eventProfile in [nil, event] {
                for includesQR in [false, true] {
                    let context = "\(format) event=\(eventProfile != nil) qr=\(includesQR)"
                    var options = ReceiptPrintOptions.default
                    options.includesPrintedGalleryQR = includesQR
                    let receipt = try ReceiptComposer.compose(
                        photos: (0..<format.photoCount).map { ReliabilityFixtures.syntheticPhoto(session: 900, photo: $0 + 1, format: format) },
                        sessionIdentifier: "PP-PREVIEW-\(format.rawValue)",
                        date: date,
                        galleryURL: galleryURL,
                        format: format,
                        eventProfile: eventProfile,
                        passport: format == .passport ? .photoPassDebugFixture : nil,
                        printOptions: options
                    )
                    let composed = try XCTUnwrap(UIImage(data: receipt.imagePNGData), context)
                    let rasterized = try ThermalImageRasterizer.rasterize(composed, purpose: .completeReceipt)
                    let preview = try XCTUnwrap(UIImage(data: rasterized.previewPNGData), context)
                    let previewPixels = try XCTUnwrap(preview.cgImage, context)

                    // Same geometry as what prints: printer width, same length as the composition.
                    XCTAssertEqual(previewPixels.width, rasterized.width, context)
                    XCTAssertEqual(previewPixels.height, rasterized.height, context)
                    XCTAssertEqual(Double(previewPixels.height) / Double(previewPixels.width),
                                   Double(receipt.height) / Double(receipt.width), accuracy: 0.01, context)
                    try assertOneBit(previewPixels, context: context)
                    try assertPreviewMatchesRasterBits(previewPixels, rasterized: rasterized, context: context)

                    // Long receipts stay readable: either whole at a usable width, or scrollable.
                    let layout = BoothSessionView.ReceiptPreviewLayout.make(imageSize: preview.size, maxWidth: 420, maxHeight: 560)
                    // Sub-point tolerance only absorbs floating-point scaling, never real overflow.
                    XCTAssertLessThanOrEqual(layout.displaySize.width, 420 + 0.001, context)
                    XCTAssertLessThanOrEqual(layout.viewportHeight, 560 + 0.001, context)
                    XCTAssertGreaterThanOrEqual(layout.displaySize.width, BoothSessionView.ReceiptPreviewLayout.minimumWholeReceiptWidth, context)
                }
            }
        }
    }

    private func assertOneBit(_ image: CGImage, context: String) throws {
        let pixels = try gray(image)
        let midTones = pixels.filter { $0 > 8 && $0 < 247 }.count
        XCTAssertEqual(midTones, 0, "\(context): thermal preview must be pure black and white")
    }

    /// Spot-checks rows of the preview against the raster bits actually sent to the printer.
    private func assertPreviewMatchesRasterBits(_ image: CGImage, rasterized: ThermalRasterizedImage, context: String) throws {
        let pixels = try gray(image)
        let rows = stride(from: 0, to: rasterized.height, by: max(1, rasterized.height / 40))
        let bits = [UInt8](rasterized.rasterData)
        var mismatches = 0
        for y in rows {
            for x in 0..<rasterized.width {
                let byte = bits[y * rasterized.widthBytes + x / 8]
                let printsDot = byte & (0x80 >> UInt8(x % 8)) != 0
                let previewDark = pixels[y * image.width + x] < 128
                if printsDot != previewDark { mismatches += 1 }
            }
        }
        XCTAssertEqual(mismatches, 0, "\(context): preview differs from the printer raster")
    }

    private func gray(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }
}
