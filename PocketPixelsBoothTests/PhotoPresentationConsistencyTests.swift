import UIKit
import XCTest
@testable import PocketPixelsBooth

/// Proves the photo a guest approves is the photo that prints, for every slot of every format.
///
/// Each test photo carries asymmetric markers positioned on the edges of the *approved* crop:
/// dark top-left and bottom-right corner blocks plus a dark "up" tab at the top centre. Any
/// rotation, mirror, or extra print-time crop moves a marker away from where it is sampled.
final class PhotoPresentationConsistencyTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_788_692_040)

    /// Marker samples in normalized upright-crop coordinates and whether each should be dark.
    private let markerSamples: [(name: String, point: CGPoint, dark: Bool)] = [
        ("top-left corner", CGPoint(x: 0.035, y: 0.035), true),
        ("top-right corner", CGPoint(x: 0.965, y: 0.035), false),
        ("bottom-left corner", CGPoint(x: 0.035, y: 0.965), false),
        ("bottom-right corner", CGPoint(x: 0.965, y: 0.965), true),
        ("top-centre up tab", CGPoint(x: 0.5, y: 0.035), true),
        ("bottom-centre", CGPoint(x: 0.5, y: 0.965), false),
        ("centre", CGPoint(x: 0.5, y: 0.5), false)
    ]

    /// Camera frames for the upright portrait mount and the supported landscape-right mount.
    private let cameraFrames = [CGSize(width: 1_200, height: 1_600), CGSize(width: 1_600, height: 1_200)]

    func testEveryFormatPrintsExactlyTheApprovedCropWithoutRotationOrMirroring() throws {
        for format in BoothFormat.allCases {
            for cameraFrame in cameraFrames {
                let stored = (0..<format.photoCount).map { index in
                    markerPhoto(format: format, photoIndex: index, cameraFrame: cameraFrame)
                }

                // 1. Capture confirmation and review use the shared geometry crop.
                for index in stored.indices {
                    let confirmation = CapturePhotoPresentation.resolve(format: format, photoIndex: index)
                        .confirmationPhoto(from: stored[index], format: format, photoIndex: index)
                    let review = PhotoPresentationGeometry.resolve(format: format, photoIndex: index).uprightPhoto(from: stored[index])
                    try assertMarkers(in: confirmation, frame: CGRect(origin: .zero, size: confirmation.size), rotation: .none,
                                      context: "\(format) photo \(index + 1) confirmation \(cameraFrame)")
                    try assertMarkers(in: review, frame: CGRect(origin: .zero, size: review.size), rotation: .none,
                                      context: "\(format) photo \(index + 1) review \(cameraFrame)")
                    XCTAssertEqual(confirmation.size.width / confirmation.size.height, review.size.width / review.size.height, accuracy: 0.01)
                }

                // 2. The composed receipt places that same crop in each printed opening.
                let passport: PassportSessionData? = format == .passport ? .photoPassDebugFixture : nil
                let receipt = try ReceiptComposer.compose(
                    photos: stored,
                    sessionIdentifier: "PP-ORIENT-\(format.rawValue)",
                    date: date,
                    format: format,
                    passport: passport,
                    photoQualityProfile: .neutral
                )
                let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
                let plan = try ReceiptComposer.makeLayoutPlan(format: format, includesGalleryQRCode: false, passport: passport, date: date)
                for frame in plan.photoFrames {
                    let geometry = PhotoPresentationGeometry.resolve(format: format, photoIndex: frame.photoIndex)
                    XCTAssertEqual(frame.rect.width / frame.rect.height, geometry.printedOpeningAspectRatio, accuracy: 0.02,
                                   "\(format) photo \(frame.photoIndex + 1) opening shape differs from the approved crop")
                    try assertMarkers(in: image, frame: frame.rect, rotation: geometry.printRotation,
                                      context: "\(format) photo \(frame.photoIndex + 1) printed \(cameraFrame)")
                }
            }
        }
    }

    func testPhotoPassHeroIsApprovedAsTheUprightPortraitThatPrintsSideways() {
        let hero = PhotoPresentationGeometry.resolve(format: .passport, photoIndex: 1)
        XCTAssertEqual(hero.orientation, .portrait)
        XCTAssertEqual(hero.printRotation, .counterclockwise90)
        XCTAssertEqual(CapturePhotoPresentation.resolve(format: .passport, photoIndex: 1), .portrait)
        XCTAssertEqual(MadeToKeepReviewFormatSpec.spec(for: .passport).aspectRatios[1], 3.0 / 4.0, accuracy: 0.001)

        // Archived legacy Passport sessions keep their landscape hero for faithful reprints.
        let legacy = PhotoPresentationGeometry.resolve(format: .passport, photoIndex: 1, passportDesign: .legacyPassport)
        XCTAssertEqual(legacy.orientation, .landscape)
        XCTAssertEqual(legacy.printRotation, .none)
    }

    func testPresentationNeverModifiesTheStoredSource() {
        let source = markerPhoto(format: .passport, photoIndex: 1, cameraFrame: CGSize(width: 1_200, height: 1_600))
        let before = source.pngData()
        for index in 0..<2 {
            _ = PhotoPresentationGeometry.resolve(format: .passport, photoIndex: index).uprightPhoto(from: source)
            _ = CapturePhotoPresentation.resolve(format: .passport, photoIndex: index).confirmationPhoto(from: source, format: .passport, photoIndex: index)
        }
        XCTAssertEqual(source.pngData(), before)
        XCTAssertEqual(source.size, CGSize(width: 1_200, height: 1_600))
    }

    func testThermalPreparationDoesNotCropTheApprovedPhotoAgain() throws {
        for format in BoothFormat.allCases {
            let passport: PassportSessionData? = format == .passport ? .photoPassDebugFixture : nil
            let plan = try ReceiptComposer.makeLayoutPlan(format: format, includesGalleryQRCode: false, passport: passport, date: date)
            let stored = (0..<format.photoCount).map { markerPhoto(format: format, photoIndex: $0, cameraFrame: CGSize(width: 1_200, height: 1_600)) }
            let prepared = try ReceiptComposer.preparePhotos(stored, for: plan, profile: .neutral)
            for (index, photo) in prepared.enumerated() {
                let geometry = PhotoPresentationGeometry.resolve(format: format, photoIndex: index)
                let approved = ThermalPhotoProcessor.pixelSize(of: geometry.uprightPhoto(from: stored[index]))
                XCTAssertEqual(photo.croppedPixelSize.width, approved.width, accuracy: 1, "\(format) photo \(index + 1) was cropped again")
                XCTAssertEqual(photo.croppedPixelSize.height, approved.height, accuracy: 1, "\(format) photo \(index + 1) was cropped again")
                let frame = try XCTUnwrap(plan.photoFrames.first { $0.photoIndex == index })
                XCTAssertEqual(photo.finalPixelSize, geometry.preparedPixelSize(forOpening: frame.rect.size))
            }
        }
    }

    // MARK: Helpers

    /// A stored capture (after the production normalization for the format) whose markers sit on
    /// the edges of the slot's approved crop.
    private func markerPhoto(format: BoothFormat, photoIndex: Int, cameraFrame: CGSize) -> UIImage {
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true
        let raw = UIGraphicsImageRenderer(size: cameraFrame, format: rendererFormat).image { context in
            UIColor(white: 0.92, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: cameraFrame))
        }
        let stored = format == .passport
            ? PassportPhotoProcessor.normalizedSource(from: raw)
            : BoothPhotoProcessor.normalizedPortraitPhoto(from: raw)
        let storedSize = ThermalPhotoProcessor.pixelSize(of: stored)
        let crop = PhotoPresentationGeometry.resolve(format: format, photoIndex: photoIndex).cropRect(sourceSize: storedSize)

        return UIGraphicsImageRenderer(size: storedSize, format: rendererFormat).image { context in
            stored.draw(in: CGRect(origin: .zero, size: storedSize))
            UIColor(white: 0.05, alpha: 1).setFill()
            let block = CGSize(width: crop.width * 0.07, height: crop.height * 0.07)
            context.fill(CGRect(x: crop.minX, y: crop.minY, width: block.width, height: block.height))
            context.fill(CGRect(x: crop.maxX - block.width, y: crop.maxY - block.height, width: block.width, height: block.height))
            context.fill(CGRect(x: crop.midX - block.width, y: crop.minY, width: block.width * 2, height: block.height))
        }
    }

    /// Maps a normalized upright-crop point into the printed opening, applying the print rotation.
    private func printedPoint(_ point: CGPoint, in frame: CGRect, rotation: PhotoPresentationGeometry.PrintRotation) -> CGPoint {
        switch rotation {
        case .none:
            CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
        case .counterclockwise90:
            // Upright top lands on the opening's left edge; upright left lands on its bottom edge.
            CGPoint(x: frame.minX + point.y * frame.width, y: frame.maxY - point.x * frame.height)
        }
    }

    private func assertMarkers(
        in image: UIImage,
        frame: CGRect,
        rotation: PhotoPresentationGeometry.PrintRotation,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let pixels = try rgba(image)
        for sample in markerSamples {
            let point = printedPoint(sample.point, in: frame, rotation: rotation)
            let value = luminance(pixels, at: point)
            if sample.dark {
                XCTAssertLessThan(value, 0.35, "\(context): \(sample.name) marker missing (\(value))", file: file, line: line)
            } else {
                XCTAssertGreaterThan(value, 0.6, "\(context): \(sample.name) unexpectedly dark (\(value))", file: file, line: line)
            }
        }
    }

    private func rgba(_ image: UIImage) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return (pixels, cgImage.width, cgImage.height)
    }

    /// Averages a 3×3 neighbourhood so a single dithered or anti-aliased pixel cannot decide.
    private func luminance(_ data: (pixels: [UInt8], width: Int, height: Int), at point: CGPoint) -> Double {
        var total = 0.0
        var count = 0.0
        for dy in -1...1 {
            for dx in -1...1 {
                let x = min(max(Int(point.x) + dx, 0), data.width - 1)
                let y = min(max(Int(point.y) + dy, 0), data.height - 1)
                let offset = (y * data.width + x) * 4
                total += (0.2126 * Double(data.pixels[offset]) + 0.7152 * Double(data.pixels[offset + 1]) + 0.0722 * Double(data.pixels[offset + 2])) / 255
                count += 1
            }
        }
        return total / count
    }
}
