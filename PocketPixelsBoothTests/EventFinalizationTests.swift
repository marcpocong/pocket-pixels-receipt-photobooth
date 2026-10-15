import CoreImage
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import PocketPixelsBooth

@MainActor
final class EventFinalizationTests: XCTestCase {
    func testBackAndCancelBeforeCheckoutPreserveIdentityAndCreateNoPayment() throws {
        let model = BoothSessionViewModel()
        model.configurePaidCheckoutForTesting(qrPhEnabled: false, cashEnabled: true)
        let token = String(repeating: "d", count: 64)
        let url = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: URL(string: "https://gallery.example.com")!, galleryToken: token)
        model.galleryToken = token
        model.galleryURL = url
        let session = model.sessionIdentifier
        model.backToFormatSelection()
        XCTAssertEqual(model.state, .choosingFormat)
        XCTAssertEqual(model.galleryURL, url)
        model.selectBoothFormat(.duo)
        XCTAssertEqual(model.state, .choosingCopies)
        XCTAssertEqual(model.sessionIdentifier, session)
        XCTAssertEqual(model.galleryToken, token)
        XCTAssertEqual(model.galleryURL, url)
        XCTAssertNil(model.paymentOrder)
        XCTAssertFalse(model.checkoutGuard.serverCheckoutStarted)
        model.cancelSession()
        XCTAssertEqual(model.state, .welcome)
        XCTAssertNil(model.galleryToken)
        XCTAssertNil(model.galleryQRCodeImage)
        XCTAssertTrue(model.capturedPhotos.isEmpty)
        XCTAssertNil(model.paymentOrder)
    }

    func testUnresolvedPaymentCannotNavigateBackCancelOrChangeQuantity() {
        let model = BoothSessionViewModel()
        model.configurePaidCheckoutForTesting(qrPhEnabled: true, cashEnabled: true)
        model.configureUnresolvedCheckoutForTesting()
        let copies = model.selectedCheckoutCopies
        XCTAssertFalse(model.canLeaveCopySelection)
        XCTAssertFalse(model.isCustomerResetSafe)
        model.backToFormatSelection()
        XCTAssertEqual(model.state, .choosingCopies)
        model.adjustCheckoutCopies(by: 1)
        XCTAssertEqual(model.selectedCheckoutCopies, copies)
        model.confirmCopySelection()
        XCTAssertEqual(model.state, .choosingCopies)
        model.cancelSession()
        XCTAssertEqual(model.state, .paymentReconciliation)
        XCTAssertTrue(model.checkoutGuard.qrAttemptUnresolved)
        XCTAssertNotNil(model.sessionIdentifier)
    }

    func testConclusivePolicyRejectionReopensCopyReviewButUnresolvedPaymentDoesNot() {
        let details = Data(#"{"currentPolicy":{"id":"ev","name":"Gala","venue":"","lifecycle":"ACTIVE","policyRevisionId":"r2","revision":2,"commercialMode":"PAY_PER_PRINT","unitPriceCentavos":7500,"maxCopies":5,"defaultCopies":1,"cashEnabled":true,"qrphEnabled":true,"prepaidGuestCopyChoice":false,"supportedFormats":["solo"],"features":{},"offlineValidUntil":null}}"#.utf8)
        let error = PaymentsAPIError.rejected(code: "policy_changed", message: "Review the updated price", status: 409, details: details)
        for unresolved in [false, true] {
            let model = BoothSessionViewModel()
            model.configurePaidCheckoutForTesting(qrPhEnabled: true, cashEnabled: true)
            model.configureUnresolvedCheckoutForTesting(qrAttemptUnresolved: unresolved)
            model.handleCheckoutErrorForTesting(error)
            if unresolved {
                XCTAssertEqual(model.state, .paymentReconciliation)
                XCTAssertFalse(model.canLeaveCopySelection)
            } else {
                XCTAssertEqual(model.state, .choosingCopies)
                XCTAssertTrue(model.canLeaveCopySelection)
                XCTAssertEqual(model.commercialEvent.activePolicy.unitPriceCentavos, 7_500)
                model.confirmCopySelection()
                XCTAssertEqual(model.state, .choosingPayment)
                XCTAssertNil(model.paymentOrder)
            }
        }
    }

    func testQuantityLimitsUseConfiguredPolicyAndRepeatedContinueDoesNotStartAnOrder() {
        let model = BoothSessionViewModel()
        model.configurePaidCheckoutForTesting(qrPhEnabled: false, cashEnabled: true)
        let maximum = model.commercialEvent.activePolicy.maxCopies
        for _ in 0..<maximum + 2 { model.adjustCheckoutCopies(by: -1) }
        XCTAssertEqual(model.selectedCheckoutCopies, 1)
        for count in 1...maximum {
            XCTAssertEqual(model.commercialEvent.activePolicy.totalCentavos(for: model.selectedCheckoutCopies), count * model.commercialEvent.activePolicy.unitPriceCentavos)
            model.adjustCheckoutCopies(by: 1)
        }
        XCTAssertEqual(model.selectedCheckoutCopies, maximum)
        model.confirmCopySelection()
        model.confirmCopySelection()
        XCTAssertEqual(model.state, .cashAttestation)
        XCTAssertNil(model.paymentOrder, "Entering cash instructions does not declare or charge payment")
        XCTAssertNil(model.checkoutEntitlement)
    }

    func testCopySelectionAndThankYouFitCarloPortraitAndLandscape() async throws {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            let model = BoothSessionViewModel()
            model.configurePaidCheckoutForTesting(qrPhEnabled: false, cashEnabled: true)
            for count in [1, 2, 3, model.commercialEvent.activePolicy.maxCopies] {
                model.selectedCheckoutCopies = count
                let (_, scroll) = try await render(CheckoutCopySelectionView(viewModel: model), size: size, name: "copies-\(count)-\(Int(size.width))")
                XCTAssertLessThanOrEqual(scroll.contentSize.height, scroll.bounds.height + 1)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
            }
            let url = URL(string: "https://gallery.example.com/?g=" + String(repeating: "c", count: 64))!
            let qr = try GalleryQRCodeGenerator.makeQRCodeImage(for: url)
            let (image, scroll) = try await render(SessionThankYouContent(qrImage: qr, status: "Still uploading — your QR will remain the same", startAnotherSession: {}), size: size, name: "thank-you-\(Int(size.width))")
            XCTAssertLessThanOrEqual(scroll.contentSize.height, scroll.bounds.height + 1)
            let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let codes = detector.features(in: CIImage(cgImage: try XCTUnwrap(image.cgImage))).compactMap { $0 as? CIQRCodeFeature }
            let code = try XCTUnwrap(codes.first)
            XCTAssertEqual(code.messageString, url.absoluteString)
            XCTAssertEqual(code.bounds.midX / size.width, 0.5, accuracy: 0.02)
            XCTAssertEqual(code.bounds.midY / size.height, 0.5, accuracy: 0.12)
        }
    }

    func testAccessibilityCopySelectionScrollsWithoutHorizontalClipping() async throws {
        let model = BoothSessionViewModel()
        model.configurePaidCheckoutForTesting(qrPhEnabled: false, cashEnabled: true)
        let (_, scroll) = try await render(CheckoutCopySelectionView(viewModel: model).environment(\.dynamicTypeSize, .accessibility3), size: CGSize(width: 834, height: 1194), name: "copies-accessibility")
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
    }

    private func render<V: View>(_ content: V, size: CGSize, name: String) async throws -> (UIImage, UIScrollView) {
        let host = UIHostingController(rootView: content.background { MadeToKeepPaperBackground() }.preferredColorScheme(.light))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(findScroll(host.view))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("EventFinalizationEvidence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try image.pngData()?.write(to: directory.appendingPathComponent(name + ".png"))
        return (image, scroll)
    }
    private func findScroll(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll($0) }.first
    }
}

@MainActor
final class GalleryBrowserLayoutTests: XCTestCase {
    func testMobileShareAndDownloadFallbackPreserveFilesAndAccurateGuidance() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DerivedData/gallery-fixtures")
        let html = try String(contentsOf: root.appendingPathComponent("gallery-2.html"), encoding: .utf8)
        for sharing in [true, false] {
            let configuration = WKWebViewConfiguration()
            let stub = """
            window.sharedFiles=[];window.downloadedFiles=[];
            Object.defineProperty(navigator,'userAgent',{get:()=> 'iPhone Safari'});
            Object.defineProperty(navigator,'canShare',{value:()=> \(sharing ? "true" : "false")});
            Object.defineProperty(navigator,'share',{value:async data=>{window.sharedFiles.push(data.files.map(f=>({name:f.name,type:f.type,size:f.size})));}});
            HTMLAnchorElement.prototype.click=function(){window.downloadedFiles.push(this.download);};
            """
            configuration.userContentController.addUserScript(WKUserScript(source: stub, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
            web.loadHTMLString(html, baseURL: URL(string: "https://gallery.example.test"))
            var loaded = false
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(50))
                if (try? await web.evaluateJavaScript("typeof photoItems !== 'undefined' && !!document.getElementById('shareAll')")) as? Bool == true { loaded = true; break }
            }
            XCTAssertTrue(loaded)
            if sharing {
                let hint = try await web.evaluateJavaScript("document.getElementById('allHint').textContent") as? String
                XCTAssertTrue(hint?.contains("Opens the share sheet") == true)
                _ = try await web.evaluateJavaScript("document.getElementById('shareAll').click(); document.querySelector('[data-download=\"photo-01.jpg\"]').click(); document.querySelector('[data-download=\"receipt-color.jpg\"]').click(); document.querySelector('[data-download=\"receipt-bw.png\"]').click()")
                let shares = try await web.evaluateJavaScript("window.sharedFiles") as! [[[String: Any]]]
                XCTAssertEqual(shares.count, 4)
                XCTAssertEqual(shares[0].compactMap { $0["name"] as? String }, ["photo-01.jpg", "photo-02.jpg"])
                XCTAssertEqual(shares[1][0]["type"] as? String, "image/jpeg")
                XCTAssertEqual(shares[2][0]["name"] as? String, "receipt-color.jpg")
                XCTAssertEqual(shares[3][0]["type"] as? String, "image/png")
                XCTAssertTrue(shares.flatMap { $0 }.allSatisfy { ($0["size"] as? Int ?? 0) > 0 })
            } else {
                let hidden = try await web.evaluateJavaScript("document.getElementById('shareAll').hidden") as? Bool
                XCTAssertEqual(hidden, true)
                let hint = try await web.evaluateJavaScript("document.getElementById('allHint').textContent") as? String
                XCTAssertTrue(hint?.contains("Use Save under each photo") == true)
                _ = try await web.evaluateJavaScript("document.querySelector('[data-download=\"photo-01.jpg\"]').click()")
                let downloads = try await web.evaluateJavaScript("window.downloadedFiles") as? [String]
                XCTAssertEqual(downloads, ["photo-01.jpg"])
                let message = try await web.evaluateJavaScript("document.getElementById('message').textContent") as? String
                XCTAssertTrue(message?.contains("Files") == true)
            }
        }
    }

    func testSyntheticGalleriesFitAllWidthsAndOpenPhotosAndReceipts() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DerivedData/gallery-fixtures")
        for count in [1, 2, 3, 4, 6] {
            let html = try String(contentsOf: root.appendingPathComponent("gallery-\(count).html"), encoding: .utf8)
            for (width, height) in [(320, 900), (375, 900), (390, 900), (430, 900), (768, 1024), (1024, 768), (1440, 900), (844, 390), (1194, 834)] {
                let web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height))
                let window = UIWindow(frame: web.frame)
                let controller = UIViewController()
                controller.view = web
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                web.loadHTMLString(html, baseURL: URL(string: "https://gallery.example.com"))
                var loaded = false
                for _ in 0..<100 {
                    try await Task.sleep(for: .milliseconds(50))
                    if (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('shareAll')")) as? Bool == true { loaded = true; break }
                }
                XCTAssertTrue(loaded)
                let checks = try await web.evaluateJavaScript("""
                (()=>{const buttons=[...document.querySelectorAll('button')].filter(b=>b.getBoundingClientRect().width>0);return {overflow:document.documentElement.scrollWidth>innerWidth, photos:document.querySelectorAll('.shot').length, gif:document.querySelectorAll('[data-open="session.gif"]').length, small:buttons.filter(b=>b.getBoundingClientRect().height<43).length, save:!document.getElementById('shareAll').hidden}})()
                """) as! [String: Any]
                XCTAssertEqual(checks["overflow"] as? Bool, false, "\(count) photos at \(width)")
                XCTAssertEqual(checks["photos"] as? Int, count)
                XCTAssertEqual(checks["gif"] as? Int, 0)
                XCTAssertEqual(checks["small"] as? Int, 0)
                XCTAssertEqual(checks["save"] as? Bool, true)
                let opened = try await web.evaluateJavaScript("document.querySelector('[data-open]').click(); !document.getElementById('lightbox').hidden") as? Bool
                XCTAssertEqual(opened, true)
                _ = try await web.evaluateJavaScript("document.getElementById('lightboxClose').click()")
                let closed = try await web.evaluateJavaScript("document.getElementById('lightbox').hidden") as? Bool
                XCTAssertEqual(closed, true)
                if count == 2 && [390, 1440].contains(width) {
                    let shot = try await web.takeSnapshot(configuration: nil)
                    let attachment = XCTAttachment(image: shot)
                    attachment.name = "gallery-\(width)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }
}
