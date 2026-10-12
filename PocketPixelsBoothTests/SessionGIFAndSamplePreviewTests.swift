import ImageIO
import UIKit
import XCTest
@testable import PocketPixelsBooth

@MainActor
final class SessionGIFAndSamplePreviewTests: XCTestCase {
    func testGIFFrameCountsTimingLoopDimensionsAndSignature() throws {
        for count in [1, 2, 3, 4, 6] {
            let data = try SessionGIFRenderer.render(images: (0..<count).map(photo))
            XCTAssertEqual(String(data: data.prefix(6), encoding: .ascii), "GIF89a")
            XCTAssertLessThanOrEqual(data.count, SessionGIFRenderer.maximumByteCount)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), count)
            let frames = try (0..<count).map { index in
                try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            }
            let dimensions = Set(frames.map { "\($0.width)x\($0.height)" })
            XCTAssertEqual(dimensions.count, 1, "Every GIF frame must use the same canvas")
            XCTAssertEqual(frames.first?.width, frames.first?.height)
            XCTAssertLessThanOrEqual(frames.first?.width ?? .max, SessionGIFRenderer.maximumLongestSide)
            for index in 0..<count {
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
                let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
                let delay = try XCTUnwrap(gif[kCGImagePropertyGIFDelayTime] as? Double)
                XCTAssertEqual(delay, SessionGIFRenderer.frameDelay, accuracy: 0.01)
            }
            let containerProperties = try XCTUnwrap(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
            let containerGIF = try XCTUnwrap(containerProperties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            XCTAssertEqual(containerGIF[kCGImagePropertyGIFLoopCount] as? Int, 0)
        }
    }

    func testMixedPortraitLandscapeAndOrientedFramesUseOneNeutralCanvas() throws {
        let portrait = photo(1)
        let landscape = photo(2)
        let rotated = UIImage(cgImage: try XCTUnwrap(landscape.cgImage), scale: 1, orientation: .right)
        let data = try SessionGIFRenderer.render(images: [portrait, landscape, rotated])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let frames = try (0..<3).map { try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, $0, nil)) }
        XCTAssertTrue(frames.allSatisfy { $0.width == frames[0].width && $0.height == frames[0].height })
        XCTAssertEqual(frames[0].width, frames[0].height)
    }

    func testGIFPreservesApprovedFrameOrder() throws {
        let data = try SessionGIFRenderer.render(images: (0..<4).map(photo))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))

        for index in 0..<4 {
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            let expected = UIColor(hue: CGFloat(index) / 7, saturation: 0.8, brightness: 0.8, alpha: 1)
            XCTAssertTrue(try XCTUnwrap(centerPixel(of: frame)).isApproximatelyEqual(to: expected))
        }
    }

    func testGIFHonorsCallerByteBudgetAndRejectsAbsurdBudget() throws {
        let images = (0..<6).map(photo)
        let baseline = try SessionGIFRenderer.render(images: images)
        let budget = max(GalleryPreparedUploadBudget.minimumGIFByteBudget, baseline.count)
        let constrained = try SessionGIFRenderer.render(images: images, maximumByteCount: budget)
        XCTAssertLessThanOrEqual(constrained.count, budget)
        XCTAssertThrowsError(try SessionGIFRenderer.render(images: images, maximumByteCount: 1024))
    }

    func testGIFRejectsMissingFrames() {
        XCTAssertThrowsError(try SessionGIFRenderer.render(images: []))
    }

    func testSoloGalleryRemainsSchemaV2WithoutMisleadingGIF() throws {
        let image = photo(0)
        let payload = try GoogleDriveGalleryUploadService.preparePayload(
            photos: [image],
            composedReceipt: image,
            sessionID: "PP-20261009-120000",
            createdAt: Date(timeIntervalSince1970: 1_760_011_200),
            galleryToken: String(repeating: "a", count: 64),
            customerGalleryBaseURL: try XCTUnwrap(URL(string: "https://gallery.example.com/"))
        )
        let request = try GoogleDriveGalleryUploadService.makeRequestBody(
            payload: payload,
            deviceToken: String(repeating: "x", count: 32)
        )

        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertNil(payload.gif)
        XCTAssertNil(request.gif)
        XCTAssertNotNil(request.colorReceipt)
        XCTAssertNotNil(request.thermalReceipt)
    }

    func testImportedPhotosRepeatAndCycleForEveryFormat() {
        let first = photo(0)
        let second = photo(1)
        XCTAssertEqual(EventReceiptComposerPreview.samplePhotos(importedPhotos: [first], count: 1).count, 1)
        XCTAssertEqual(EventReceiptComposerPreview.samplePhotos(importedPhotos: [first], count: 2).count, 2)
        XCTAssertEqual(EventReceiptComposerPreview.samplePhotos(importedPhotos: [first], count: 6).count, 6)
        let grid = EventReceiptComposerPreview.samplePhotos(importedPhotos: [first, second], count: 4)
        XCTAssertTrue(grid[0] === first && grid[1] === second && grid[2] === first && grid[3] === second)
        XCTAssertEqual(EventReceiptComposerPreview.samplePhotos(importedPhotos: (0..<6).map(photo), count: 6).count, 6)
        XCTAssertEqual(EventReceiptComposerPreview.samplePhotos(importedPhotos: [first], count: BoothFormat.passport.photoCount).count, 2)
    }

    private func photo(_ index: Int) -> UIImage {
        let size = index.isMultiple(of: 2) ? CGSize(width: 1200, height: 800) : CGSize(width: 800, height: 1200)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(hue: CGFloat(index) / 7, saturation: 0.8, brightness: 0.8, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func centerPixel(of image: CGImage) -> UIColor? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}

private extension UIColor {
    func isApproximatelyEqual(to other: UIColor, tolerance: CGFloat = 0.08) -> Bool {
        var lhsRed: CGFloat = 0
        var lhsGreen: CGFloat = 0
        var lhsBlue: CGFloat = 0
        var lhsAlpha: CGFloat = 0
        var rhsRed: CGFloat = 0
        var rhsGreen: CGFloat = 0
        var rhsBlue: CGFloat = 0
        var rhsAlpha: CGFloat = 0
        guard getRed(&lhsRed, green: &lhsGreen, blue: &lhsBlue, alpha: &lhsAlpha),
              other.getRed(&rhsRed, green: &rhsGreen, blue: &rhsBlue, alpha: &rhsAlpha) else { return false }
        let lhs = [lhsRed, lhsGreen, lhsBlue, lhsAlpha]
        let rhs = [rhsRed, rhsGreen, rhsBlue, rhsAlpha]
        return zip(lhs, rhs).allSatisfy { abs($0 - $1) <= tolerance }
    }
}
