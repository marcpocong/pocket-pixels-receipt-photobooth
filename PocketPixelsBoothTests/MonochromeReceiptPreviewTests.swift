import CoreImage
import UIKit
import XCTest
@testable import PocketPixelsBooth

/// The customer "Black & White" receipt (iPad preview and QR gallery `receipt-bw.png`) is a smooth
/// grayscale digital copy. It never replaces or alters the 1-bit raster that physically prints.
final class MonochromeReceiptPreviewTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_788_692_040)
    private let galleryURL = URL(string: "https://gallery.example.com/g/\(String(repeating: "d", count: 64))")!
    private let token = String(repeating: "e", count: 64)

    // MARK: Image processing

    func testGradientKeepsSmoothGrayLevelsAndGeometry() throws {
        let gradient = makeImage(width: 576, height: 300) { context, size in
            for x in 0..<Int(size.width) {
                UIColor(hue: CGFloat(x) / size.width, saturation: 0.7, brightness: CGFloat(x) / size.width, alpha: 1).setFill()
                context.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: size.height / 2))
                UIColor(white: CGFloat(x) / (size.width - 1), alpha: 1).setFill()
                context.fill(CGRect(x: CGFloat(x), y: size.height / 2, width: 1, height: size.height / 2))
            }
        }
        let output = try MonochromeReceiptRenderer.render(gradient)
        XCTAssertEqual(output.width, 576)
        XCTAssertEqual(output.height, 300)
        XCTAssertEqual(output.image.size, gradient.size)
        XCTAssertTrue(MonochromeReceiptRenderer.isSmoothMonochromePNG(output.pngData))

        let pixels = try grayPixels(output.image)
        let distinct = Set(pixels)
        XCTAssertGreaterThan(distinct.count, 200, "A gradient must keep intermediate gray levels")
        let midTones = pixels.filter { $0 > 24 && $0 < 231 }.count
        XCTAssertGreaterThan(Double(midTones) / Double(pixels.count), 0.6, "Not collapsed into binary black and white")

        // The neutral ramp stays monotonic (no posterization reversals) and keeps paper white.
        let row = (0..<576).map { pixels[225 * 576 + $0] }
        XCTAssertEqual(row.first, 0)
        XCTAssertEqual(row.last, 255)
        XCTAssertEqual(row, row.sorted())
    }

    func testOutputIsGrayscaleDeterministicAndMatchesThePublishedLumaMath() throws {
        let colorful = makeImage(width: 64, height: 64) { context, _ in
            UIColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
            UIColor(red: 0.1, green: 0.6, blue: 0.9, alpha: 1).setFill(); context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        }
        let first = try MonochromeReceiptRenderer.render(colorful)
        let second = try MonochromeReceiptRenderer.render(colorful)
        XCTAssertEqual(first.pngData, second.pngData, "Rendering is deterministic")

        let cgImage = try XCTUnwrap(first.image.cgImage)
        XCTAssertEqual(cgImage.colorSpace?.model, .monochrome)
        XCTAssertEqual(cgImage.bitsPerPixel, 8)

        let source = try rgbaPixels(colorful)
        let gray = try grayPixels(first.image)
        for (x, y) in [(5, 5), (50, 40)] {
            let offset = (y * 64 + x) * 4
            let weights = MonochromeReceiptRenderer.lumaWeights
            let luma = (weights.red * Int(source[offset]) + weights.green * Int(source[offset + 1]) + weights.blue * Int(source[offset + 2]) + 128) >> 8
            XCTAssertEqual(gray[y * 64 + x], MonochromeReceiptRenderer.toneCurve[luma])
        }
        XCTAssertEqual(MonochromeReceiptRenderer.toneCurve.first, 0)
        XCTAssertEqual(MonochromeReceiptRenderer.toneCurve.last, 255)
    }

    func testOrientationIsBakedInWithoutCroppingOrMoving() throws {
        // A 40x20 landscape bitmap with a black left half, displayed rotated to portrait.
        let landscape = makeImage(width: 40, height: 20) { context, _ in
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let rotated = UIImage(cgImage: try XCTUnwrap(landscape.cgImage), scale: 1, orientation: .right)
        let output = try MonochromeReceiptRenderer.render(rotated)
        XCTAssertEqual(output.width, 20)
        XCTAssertEqual(output.height, 40)
        let pixels = try grayPixels(output.image)
        // .right rotates clockwise: the black left half becomes the top half.
        XCTAssertEqual(pixels[5 * 20 + 10], 0)
        XCTAssertEqual(pixels[35 * 20 + 10], 255)
    }

    func testTransparencyFlattensOntoWhitePaper() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let transparent = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10), format: format).image { _ in }
        let pixels = try grayPixels(try MonochromeReceiptRenderer.render(transparent).image)
        XCTAssertTrue(pixels.allSatisfy { $0 == 255 })
    }

    func testLegacyPrinterRasterPNGIsDistinguishableFromSmoothPreview() throws {
        let receipt = try compose(.duo, eventProfile: nil, includesQR: true)
        let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        let raster = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        XCTAssertFalse(MonochromeReceiptRenderer.isSmoothMonochromePNG(raster.previewPNGData), "The gallery backend relies on this signature")
        XCTAssertTrue(MonochromeReceiptRenderer.isSmoothMonochromePNG(try MonochromeReceiptRenderer.render(image).pngData))
        XCTAssertFalse(MonochromeReceiptRenderer.isSmoothMonochromePNG(Data([0x89, 0x50])))
    }

    // MARK: Every receipt format

    func testEveryFormatKeepsGeometryPhotoToneTypographyAndQR() throws {
        for format in BoothFormat.allCases {
            for eventProfile in [nil, longEventProfile()] {
                for includesQR in [false, true] {
                    let context = "\(format) event=\(eventProfile != nil) qr=\(includesQR)"
                    let receipt = try compose(format, eventProfile: eventProfile, includesQR: includesQR)
                    let keepsake = try XCTUnwrap(UIImage(data: receipt.imagePNGData), context)
                    try assertSmoothCopy(of: keepsake, context: context, expectsQR: includesQR)
                }
            }
        }
    }

    func testStickersAndMixedOrientationPhotosKeepTheirComposition() throws {
        let decorations = [
            FrozenStickerDecoration(placement: StickerFixtures.placement(target: .photo(index: 0), x: 0.3, y: 0.3, scale: 0.4, rotation: 0.3), printImage: try StickerPrintPreparation.prepare(XCTUnwrap(BundledStickerFactory.image(for: "builtin.heart"))))
        ]
        let stickered = try StickerFixtures.compose(.strip, stickers: decorations)
        try assertSmoothCopy(of: try XCTUnwrap(UIImage(data: stickered.imagePNGData)), context: "strip stickers", expectsQR: false)

        let photos = [syntheticPhoto(width: 480, height: 320), syntheticPhoto(width: 320, height: 480)]
        let mixed = try ReceiptComposer.compose(photos: photos, sessionIdentifier: "PP-MONO-MIXED", date: date, galleryURL: galleryURL, format: .duo)
        try assertSmoothCopy(of: try XCTUnwrap(UIImage(data: mixed.imagePNGData)), context: "duo mixed orientation", expectsQR: true)
    }

    // MARK: Printer separation

    func testRenderingTheCustomerPreviewNeverChangesThePrinterRaster() throws {
        for format in BoothFormat.allCases {
            let receipt = try compose(format, eventProfile: nil, includesQR: true)
            let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
            let before = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
            _ = try MonochromeReceiptRenderer.render(image)
            let after = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
            XCTAssertEqual(before.rasterCommand, after.rasterCommand, "\(format)")
            XCTAssertEqual(RecentSessionArchiveStore.rasterFingerprint(for: before), RecentSessionArchiveStore.rasterFingerprint(for: after), "\(format)")
            XCTAssertEqual(before.width, ThermalImageRasterizer.printWidth)
            XCTAssertEqual(before.rasterData.count, before.widthBytes * before.height, "Printed output stays packed 1-bit")
        }
    }

    // MARK: Customer interface

    func testBlackAndWhiteModeShowsOnlyTheSmoothPreview() throws {
        let keepsake = UIImage()
        let monochrome = UIImage()
        XCTAssertEqual(ReceiptPreviewMode.allCases.first, .keepsake)
        XCTAssertEqual(ReceiptPreviewMode.available(motion: false).map(\.title), ["Keepsake", "Black & White"])
        XCTAssertTrue(ReceiptPreviewMode.keepsake.image(keepsake: keepsake, monochrome: monochrome) === keepsake)
        XCTAssertTrue(ReceiptPreviewMode.blackAndWhite.image(keepsake: keepsake, monochrome: monochrome) === monochrome)
        XCTAssertNil(ReceiptPreviewMode.blackAndWhite.image(keepsake: keepsake, monochrome: nil), "Loading state, never a raster or color fallback")
        XCTAssertFalse(ReceiptPreviewMode.printNote.localizedCaseInsensitiveContains("as printed"))
        XCTAssertFalse(ReceiptPreviewMode.allCases.map(\.title).contains { $0.localizedCaseInsensitiveContains("printed") })
    }

    // MARK: Gallery upload

    func testGalleryUploadCarriesSmoothMonochromeForEveryFormatWithinBudget() throws {
        for format in BoothFormat.allCases {
            let receipt = try compose(format, eventProfile: longEventProfile(), includesQR: true)
            let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
            let photos = (0..<format.photoCount).map { syntheticPhoto(width: 1_600, height: 1_200, seed: $0) }
            let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: photos, composedReceipt: image, sessionID: "PP-20261018-120000", createdAt: date, galleryToken: token, customerGalleryBaseURL: URL(string: "https://example.com/")!)
            let bw = try XCTUnwrap(payload.thermalReceipt, "\(format)")
            XCTAssertEqual(bw.filename, "receipt-bw.png")
            XCTAssertEqual(bw.mimeType, "image/png")
            XCTAssertTrue(MonochromeReceiptRenderer.isSmoothMonochromePNG(bw.data), "\(format): new galleries never upload the printer raster")
            let bwImage = try XCTUnwrap(UIImage(data: bw.data))
            let colorImage = try XCTUnwrap(UIImage(data: payload.colorReceipt.data))
            XCTAssertEqual(bwImage.size, colorImage.size, "\(format): both gallery receipts share geometry")
            XCTAssertEqual(Int(bwImage.size.width), BoothConfiguration.receiptWidth)
            XCTAssertLessThanOrEqual(payload.metrics.totalDecodedBytes, GalleryPreparedUploadBudget.maximumPreparedDecodedBytes)
            print("[MonochromeReceipt] \(format.rawValue) bw=\(bw.data.count)B color=\(payload.colorReceipt.data.count)B total=\(payload.metrics.totalDecodedBytes)B")
        }
    }

    func testWorstCaseNoisyGridSixStaysWithinTheGalleryBudget() throws {
        // Sensor-noise-like photos are the hardest case for lossless grayscale PNG compression.
        let photos = (0..<6).map { noisyPhoto(width: 1_600, height: 1_200, seed: UInt64($0 + 1)) }
        let receipt = try ReceiptComposer.compose(photos: photos, sessionIdentifier: "PP-MONO-NOISE", date: date, galleryURL: galleryURL, format: .gridSix, eventProfile: longEventProfile())
        let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: photos, composedReceipt: try XCTUnwrap(UIImage(data: receipt.imagePNGData)), sessionID: "PP-20261018-120001", createdAt: date, galleryToken: token, customerGalleryBaseURL: URL(string: "https://example.com/")!)
        let bw = try XCTUnwrap(payload.thermalReceipt)
        XCTAssertTrue(MonochromeReceiptRenderer.isSmoothMonochromePNG(bw.data))
        XCTAssertLessThan(bw.data.count, 1_500_000)
        XCTAssertLessThanOrEqual(payload.metrics.totalDecodedBytes, GalleryPreparedUploadBudget.maximumPreparedDecodedBytes)
        print("[MonochromeReceipt] noisy gridSix bw=\(bw.data.count)B total=\(payload.metrics.totalDecodedBytes)B")
        let session = CommittedGallerySession(sessionIdentifier: "PP-20261018-120001", createdAt: date, galleryToken: token,
            galleryURL: galleryURL, photos: photos, format: .gridSix, eventProfile: longEventProfile())
        let alternative = try BoothSessionViewModel.shareFriendlyGalleryReceiptImage(for: session, photoQualityProfile: .customerPrintDefault)
        let variants = try GoogleDriveGalleryUploadService.preparePayload(photos: photos, composedReceipt: try XCTUnwrap(UIImage(data: receipt.imagePNGData)),
            sessionID: session.sessionIdentifier, createdAt: date, galleryToken: token, customerGalleryBaseURL: URL(string: "https://example.com/")!,
            shareFriendlyReceipt: alternative, receiptVariants: GalleryReceiptVariants(originalFooterStyle: .integratedGalleryQR, defaultStyle: .shareFriendly))
        let body = try JSONEncoder().encode(GoogleDriveGalleryUploadService.makeRequestBody(payload: variants, deviceToken: String(repeating: "test", count: 8)))
        XCTAssertEqual(variants.photos.map(\.data), payload.photos.map(\.data), "Digital variants leave the prepared photos byte-identical")
        XCTAssertLessThanOrEqual(variants.metrics.totalDecodedBytes, GalleryPreparedUploadBudget.maximumPreparedDecodedBytes)
        print("[GalleryStylesWorstCase] decoded=\(variants.metrics.totalDecodedBytes)B json=\(body.count)B share=\(variants.shareColorReceipt?.data.count ?? 0)B preparation=\(variants.metrics.timing?.imagePreparationDuration ?? 0)s")

    }

    func testPhotoPassGalleryMonochromeComesFromTheRedactedReceipt() throws {
        let passport = PassportSessionData.photoPassDebugFixture.committed(at: date)
        let photos = (0..<BoothFormat.passport.photoCount).map { syntheticPhoto(width: 600, height: 800, seed: $0) }
        let committed = CommittedGallerySession(sessionIdentifier: "PP-20261018-PASS", createdAt: date, galleryToken: token, galleryURL: galleryURL, photos: photos, format: .passport, eventProfile: nil, passport: passport)
        let printed = try ReceiptComposer.compose(photos: photos, sessionIdentifier: committed.sessionIdentifier, date: date, galleryURL: galleryURL, format: .passport, passport: passport)
        let printedImage = try XCTUnwrap(UIImage(data: printed.imagePNGData))
        let galleryImage = try BoothSessionViewModel.galleryReceiptImage(for: committed, printedReceiptImage: printedImage, photoQualityProfile: .customerPrintDefault)
        XCTAssertNotEqual(galleryImage.pngData(), printedImage.pngData(), "Gallery receipt is the redacted copy")

        let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: photos, composedReceipt: galleryImage, sessionID: committed.sessionIdentifier, createdAt: date, galleryToken: token, customerGalleryBaseURL: URL(string: "https://example.com/")!)
        let bw = try XCTUnwrap(UIImage(data: try XCTUnwrap(payload.thermalReceipt).data))
        let expected = try MonochromeReceiptRenderer.render(galleryImage.normalizedForGalleryUpload().resizedForGalleryUpload(width: BoothConfiguration.receiptWidth))
        XCTAssertEqual(try grayPixels(bw), try grayPixels(expected.image), "Uploaded black & white is the redacted gallery copy")
        let fromPrinted = try MonochromeReceiptRenderer.render(printedImage.normalizedForGalleryUpload().resizedForGalleryUpload(width: BoothConfiguration.receiptWidth))
        XCTAssertNotEqual(try grayPixels(bw), try grayPixels(fromPrinted.image), "Private printed fields never reach the gallery")

        let layout = try ReceiptComposer.makeLayoutPlan(format: .passport, passport: passport.redactedForGallery(), date: date)
        if let photoPass = layout.photoPassLayout {
            let pixels = try grayPixels(bw)
            let box = photoPass.template.signatureBoxRect.insetBy(dx: 4, dy: 4)
            let width = Int(bw.size.width)
            var ink = 0
            for y in Int(box.minY)..<Int(box.maxY) { for x in Int(box.minX)..<Int(box.maxX) where pixels[y * width + x] < 100 { ink += 1 } }
            XCTAssertEqual(ink, 0, "No signature ink in the public black & white receipt")
        }
    }

    // MARK: Helpers

    private func assertSmoothCopy(of keepsake: UIImage, context: String, expectsQR: Bool) throws {
        let output = try MonochromeReceiptRenderer.render(keepsake)
        let source = try XCTUnwrap(keepsake.cgImage, context)
        XCTAssertEqual(output.width, source.width, context)
        XCTAssertEqual(output.height, source.height, context)
        XCTAssertTrue(MonochromeReceiptRenderer.isSmoothMonochromePNG(output.pngData), context)

        let gray = try grayPixels(output.image)
        let rgba = try rgbaPixels(keepsake)
        let weights = MonochromeReceiptRenderer.lumaWeights
        var maxDeviation = 0
        var darkTextLost = 0
        for index in stride(from: 0, to: gray.count, by: 7) {
            let o = index * 4
            let luma = (weights.red * Int(rgba[o]) + weights.green * Int(rgba[o + 1]) + weights.blue * Int(rgba[o + 2]) + 128) >> 8
            maxDeviation = max(maxDeviation, abs(Int(gray[index]) - luma))
            if luma < 60 && gray[index] > 60 { darkTextLost += 1 }
        }
        // Each pixel keeps its place and tone (only the restrained contrast curve differs).
        XCTAssertLessThanOrEqual(maxDeviation, 8, "\(context): content moved or tone was distorted")
        XCTAssertEqual(darkTextLost, 0, "\(context): typography stays dark and legible")
        let midTones = gray.filter { $0 > 24 && $0 < 231 }.count
        XCTAssertGreaterThan(midTones, gray.count / 50, "\(context): photos keep smooth gray tones, not a 1-bit raster")
        if expectsQR {
            let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let messages = detector.features(in: CIImage(cgImage: try XCTUnwrap(output.image.cgImage))).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            XCTAssertTrue(messages.contains(galleryURL.absoluteString), "\(context): QR stays decodable")
        }
    }

    private func compose(_ format: BoothFormat, eventProfile: EventProfile?, includesQR: Bool) throws -> ComposedReceipt {
        var options = ReceiptPrintOptions.default
        options.includesPrintedGalleryQR = includesQR
        return try ReceiptComposer.compose(
            photos: (0..<format.photoCount).map { ReliabilityFixtures.syntheticPhoto(session: 910, photo: $0 + 1, format: format) },
            sessionIdentifier: "PP-MONO-\(format.rawValue)",
            date: date,
            galleryURL: galleryURL,
            format: format,
            eventProfile: eventProfile,
            passport: format == .passport ? .photoPassDebugFixture : nil,
            printOptions: options
        )
    }

    private func longEventProfile() -> EventProfile {
        EventProfile(
            isEnabled: true,
            eventName: "Made to Keep Launch Night With An Intentionally Long Event Title",
            subtitle: "Cebu City Waterfront Pavilion",
            includeEventDate: true,
            eventDate: date,
            location: "Cebu City",
            shortMessage: "Thank you for keeping this little moment with us tonight."
        )
    }

    private func syntheticPhoto(width: Int, height: Int, seed: Int = 0) -> UIImage {
        makeImage(width: width, height: height) { context, size in
            let colors = [UIColor(red: 0.95, green: 0.78, blue: 0.66, alpha: 1).cgColor, UIColor(red: 0.25, green: 0.12, blue: 0.2 + CGFloat(seed % 3) * 0.1, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            UIColor(red: 0.6, green: 0.3, blue: 0.25, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: size.width * 0.3, y: size.height * 0.2, width: size.width * 0.4, height: size.height * 0.5))
        }
    }

    private func noisyPhoto(width: Int, height: Int, seed: UInt64) -> UIImage {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let noise = Int((state >> 58) & 0x3F) - 32
                let base = 60 + (x * 120 / width) + (y * 60 / height)
                let o = (y * width + x) * 4
                bytes[o] = UInt8(clamping: base + noise + 30)
                bytes[o + 1] = UInt8(clamping: base + noise)
                bytes[o + 2] = UInt8(clamping: base + noise - 20)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cgImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return UIImage(cgImage: cgImage)
    }

    private func makeImage(width: Int, height: Int, draw: (UIGraphicsImageRendererContext, CGSize) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            draw(context, size)
        }
    }

    private func grayPixels(_ image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return pixels
    }

    private func rgbaPixels(_ image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return pixels
    }
}
