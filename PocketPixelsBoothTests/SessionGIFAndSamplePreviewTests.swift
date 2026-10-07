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
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertLessThanOrEqual(max(image.width, image.height), SessionGIFRenderer.maximumLongestSide)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            let delay = try XCTUnwrap(gif[kCGImagePropertyGIFDelayTime] as? Double)
            XCTAssertEqual(delay, SessionGIFRenderer.frameDelay, accuracy: 0.01)
        }
    }

    func testGIFRejectsMissingFrames() {
        XCTAssertThrowsError(try SessionGIFRenderer.render(images: []))
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
}
