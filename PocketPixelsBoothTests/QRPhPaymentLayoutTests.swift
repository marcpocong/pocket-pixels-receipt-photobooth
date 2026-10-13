import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import PocketPixelsBooth

@MainActor
final class QRPhPaymentLayoutTests: XCTestCase {
    private let fixturePayload = "MADE-TO-KEEP-LAYOUT-FIXTURE-NOT-A-PAYMENT"

    func testReadyCodeScansAndIsCenteredInBothOrientations() async throws {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            let (image, scroll) = try await render(size: size, qr: fixtureQR(), name: "ready-\(Int(size.width))x\(Int(size.height))")
            let code = try XCTUnwrap(detectQR(image).first)
            XCTAssertEqual(code.messageString, fixturePayload, "The rendered QR must still decode exactly")
            XCTAssertEqual(code.bounds.midX / size.width, 0.5, accuracy: 0.01)
            XCTAssertEqual(code.bounds.midY / size.height, 0.5, accuracy: 0.10)
            XCTAssertEqual(code.bounds.width, code.bounds.height, accuracy: 2)
            XCTAssertLessThanOrEqual(scroll.contentSize.height, scroll.bounds.height + 1, "Standard layout should fit without scrolling")
            let text = try recognizedText(image)
            XCTAssertNotNil(text.range(of: "[0-9]+:[0-9]{2}", options: .regularExpression), "The live countdown must be visible. OCR: \(text)")
            XCTAssertTrue(text.contains("Scan to Pay"))
            XCTAssertTrue(text.contains("Waiting for payment confirmation"))
        }
    }

    func testLoadingAndUnavailableKeepAmountVisibleWithoutInventingCodeOrExpiry() async throws {
        for unavailable in [false, true] {
            let (image, _) = try await render(size: CGSize(width: 834, height: 1194), qr: nil, hasPayload: unavailable, expiry: nil, name: unavailable ? "unavailable" : "loading")
            let text = try recognizedText(image)
            XCTAssertTrue(text.contains(unavailable ? "QR code unavailable" : "Preparing your QR Ph code"))
            XCTAssertTrue(text.contains("1,234"), "Amount stays visible in both states")
            XCTAssertFalse(text.replacingOccurrences(of: " ", with: "").contains("TIMEREMAINING"), "An absent expiry must not get a countdown")
            XCTAssertTrue(try detectQR(image).isEmpty)
        }
    }

    func testAccessibilityAndSmallWindowScrollToAllContent() async throws {
        _ = try await render(size: CGSize(width: 420, height: 700), qr: fixtureQR(), type: .accessibility3, total: 999_999_999, name: "accessibility-long-amount-top")
        let (image, scroll) = try await render(size: CGSize(width: 420, height: 700), qr: fixtureQR(), type: .accessibility3, total: 999_999_999, name: "accessibility-long-amount", scrollToEnd: true)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1, "No horizontal clipping or scrolling")
        XCTAssertTrue(try recognizedText(image).contains("TIME REMAINING"), "Countdown remains reachable at the end")
    }

    func testNonSquareProviderImageRetainsItsAspectRatio() async throws {
        let qr = try fixtureQR()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            qr.draw(in: CGRect(x: 100, y: 0, width: 400, height: 400))
        }
        let (image, _) = try await render(size: CGSize(width: 834, height: 1194), qr: wide, name: "non-square-payload")
        let code = try XCTUnwrap(detectQR(image).first)
        XCTAssertEqual(code.messageString, fixturePayload)
        XCTAssertEqual(code.bounds.width, code.bounds.height, accuracy: 2)
    }

    private func fixtureQR() throws -> UIImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(fixturePayload.utf8)
        filter.correctionLevel = "M"
        let output = try XCTUnwrap(filter.outputImage)
        return UIImage(cgImage: try XCTUnwrap(CIContext().createCGImage(output, from: output.extent)))
    }

    private func detectQR(_ image: UIImage) throws -> [CIQRCodeFeature] {
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        return detector.features(in: CIImage(cgImage: try XCTUnwrap(image.cgImage))).compactMap { $0 as? CIQRCodeFeature }
    }

    private func recognizedText(_ image: UIImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func render(size: CGSize, qr: UIImage?, hasPayload: Bool = true, expiry: Date? = Date().addingTimeInterval(300), type: DynamicTypeSize = .large, total: Int = 123_456, name: String, scrollToEnd: Bool = false) async throws -> (UIImage, UIScrollView) {
        let content = QRPhPaymentContent(totalCentavos: total, copies: 2, image: qr, hasImagePayload: hasPayload, expiresAt: expiry)
            .background { MadeToKeepPaperBackground() }
            .environment(\.dynamicTypeSize, type)
            .preferredColorScheme(.light)
        let host = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        host.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(findScroll(in: host.view))
        if scrollToEnd {
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
            host.view.layoutIfNeeded()
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "qr-payment-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Also write into the simulator's Documents folder for easy local visual inspection.
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("QRPaymentEvidence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try image.pngData()?.write(to: directory.appendingPathComponent("\(name).png"))
        return (image, scroll)
    }

    private func findScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
    }
}
