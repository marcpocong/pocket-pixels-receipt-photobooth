import UIKit
import XCTest
@testable import PocketPixelsBooth

@MainActor
final class SessionMotionPreviewTests: XCTestCase {
    func testMotionIsOfferedForEveryMultiPhotoFormatButNeverSolo() {
        for format in BoothFormat.allCases {
            XCTAssertEqual(SessionMotionPreview.isAvailable(format: format, photoCount: format.photoCount), format != .solo, format.rawValue)
            XCTAssertFalse(SessionMotionPreview.isAvailable(format: format, photoCount: max(0, format.photoCount - 1)), "\(format.rawValue): incomplete sessions do not animate")
        }
        XCTAssertFalse(SessionMotionPreview.isAvailable(format: nil, photoCount: 4))
        XCTAssertEqual(ReceiptPreviewMode.available(motion: false), [.keepsake, .thermal])
        XCTAssertEqual(ReceiptPreviewMode.available(motion: true), [.keepsake, .thermal, .motion])
        XCTAssertEqual(ReceiptPreviewMode.motion.title, "In Motion")
    }

    func testPreviewTimingMatchesTheGalleryGIFAndLoopsInOrder() {
        XCTAssertEqual(SessionMotionPreview.frameInterval, SessionGIFRenderer.frameDelay)
        let start = Date(timeIntervalSince1970: 0)
        let indexes = (0..<12).map { SessionMotionPreview.frameIndex(at: start.addingTimeInterval(Double($0) * SessionGIFRenderer.frameDelay + 0.01), start: start, frameCount: 4) }
        XCTAssertEqual(indexes, [0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3])
        XCTAssertEqual(SessionMotionPreview.frameIndex(at: start.addingTimeInterval(-5), start: start, frameCount: 3), 0)
        XCTAssertEqual(SessionMotionPreview.frameIndex(at: start, start: start, frameCount: 0), 0)
    }

    func testFramesKeepPhotoOrderAndFitMixedOrientationsWithoutCropping() throws {
        let colors: [UIColor] = [.red, .green, .blue, .black, .orange, .purple]
        for count in [2, 3, 4, 6] {
            let photos = (0..<count).map { photo(color: colors[$0], portrait: $0.isMultiple(of: 2)) }
            let frames = SessionMotionPreview.makeFrames(from: photos, side: 200)
            XCTAssertEqual(frames.count, count)
            for (index, frame) in frames.enumerated() {
                XCTAssertEqual(frame.size, CGSize(width: 200, height: 200))
                let cg = try XCTUnwrap(frame.cgImage)
                XCTAssertTrue(pixel(cg, x: 100, y: 100).isClose(to: colors[index]), "Frame \(index) is out of order")
                // Portrait photos are letterboxed left/right, landscape top/bottom, on the GIF ivory.
                let edge = index.isMultiple(of: 2) ? pixel(cg, x: 3, y: 100) : pixel(cg, x: 100, y: 3)
                XCTAssertTrue(edge.isClose(to: SessionGIFRenderer.canvasBackgroundColor), "Frame \(index) was cropped instead of fitted")
            }
        }
    }

    func testEveryMultiPhotoFormatUploadsAGIFAndSoloDoesNot() throws {
        for format in BoothFormat.allCases {
            let photos = (0..<format.photoCount).map { photo(color: .gray, portrait: $0.isMultiple(of: 2)) }
            let payload = try GoogleDriveGalleryUploadService.preparePayload(
                photos: photos,
                composedReceipt: photos[0],
                sessionID: "PP-20261014-120000",
                createdAt: Date(timeIntervalSince1970: 1_760_400_000),
                galleryToken: String(repeating: "b", count: 64),
                customerGalleryBaseURL: try XCTUnwrap(URL(string: "https://gallery.example.com/"))
            )
            XCTAssertEqual(payload.gif != nil, format != .solo, format.rawValue)
            XCTAssertEqual(payload.photos.count, format.photoCount)
        }
    }

    private func photo(color: UIColor, portrait: Bool) -> UIImage {
        let size = portrait ? CGSize(width: 300, height: 400) : CGSize(width: 400, height: 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> RGB {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return RGB(r: CGFloat(data[0]) / 255, g: CGFloat(data[1]) / 255, b: CGFloat(data[2]) / 255)
    }
}

private struct RGB {
    let r: CGFloat, g: CGFloat, b: CGFloat

    func isClose(to color: UIColor, tolerance: CGFloat = 0.08) -> Bool {
        var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
        color.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
        return abs(r - cr) <= tolerance && abs(g - cg) <= tolerance && abs(b - cb) <= tolerance
    }
}
