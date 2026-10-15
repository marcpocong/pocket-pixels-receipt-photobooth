import CoreImage
import SwiftUI
import UIKit
import WebKit
import Vision
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

    func testPaymentAndCashBackPreserveSessionAndCopiesWithoutCreatingOrders() {
        let model = BoothSessionViewModel()
        model.configurePaidCheckoutForTesting(qrPhEnabled: true, cashEnabled: true)
        let session = model.sessionIdentifier
        model.confirmCopySelection()
        XCTAssertTrue(model.canLeavePaymentSelection)
        model.backFromPaymentSelection()
        XCTAssertEqual(model.state, .choosingCopies)
        model.confirmCopySelection()
        model.chooseCash()
        model.backFromPaymentSelection()
        XCTAssertEqual(model.state, .choosingPayment)
        XCTAssertEqual(model.sessionIdentifier, session)
        XCTAssertEqual(model.selectedCheckoutCopies, 2)
        XCTAssertNil(model.paymentOrder)
        XCTAssertNil(model.checkoutEntitlement)
        XCTAssertFalse(model.checkoutGuard.serverCheckoutStarted)
        model.cancelSession()
        XCTAssertEqual(model.state, .welcome)

        for authority: PolicyAuthority in [.serverConfirmed(fetchedAt: Date()), .signedOffline(snapshotID: "fixture", expiresAt: Date().addingTimeInterval(3600))] {
            model.configurePaidCheckoutForTesting(qrPhEnabled: false, cashEnabled: true, authority: authority)
            model.confirmCopySelection()
            XCTAssertEqual(model.state, .cashAttestation)
            XCTAssertTrue(model.canLeavePaymentSelection)
            model.backFromPaymentSelection()
            XCTAssertEqual(model.state, .choosingCopies, "Cash-only Back must not lead to an empty method screen")
            model.confirmCopySelection()
            model.cancelSession()
            XCTAssertEqual(model.state, .welcome)
        }
    }

    func testPaymentScreenNavigationCannotAbandonAnUnresolvedRequest() {
        for state: BoothSessionState in [.choosingPayment, .cashAttestation] {
            let model = BoothSessionViewModel()
            model.configurePaidCheckoutForTesting(qrPhEnabled: true, cashEnabled: true)
            model.state = state
            model.configureUnresolvedCheckoutForTesting()
            XCTAssertFalse(model.canLeavePaymentSelection)
            XCTAssertFalse(model.canLeaveCashPayment)
            model.backFromPaymentSelection()
            model.leaveCashPayment()
            XCTAssertEqual(model.state, state)
            model.cancelSession()
            XCTAssertEqual(model.state, .paymentReconciliation)
            XCTAssertTrue(model.checkoutGuard.qrAttemptUnresolved)
        }
    }

    func testCancelAtPaidCameraReadyReturnsToWelcomeAndRetainsRecoveryForEveryPaidSource() throws {
        let store = try XCTUnwrap(CheckoutCheckpointStore.shared)
        for source: CheckoutAuthorizationSource in [.verifiedQRPh, .unverifiedCashDeclared, .localUnsyncedCashDeclared] {
            let model = BoothSessionViewModel()
            model.configureAuthorizedCameraReadyForTesting(authorizationSource: source)
            let session = try XCTUnwrap(model.sessionIdentifier)
            let now = Date()
            let checkpoint = CheckoutCheckpoint(id: session, environment: "test", deviceID: nil, accountID: nil,
                eventID: "test", policyRevisionID: "test", unitPriceCentavos: 2500, copies: 1,
                format: BoothFormat.solo.rawValue, method: source == .verifiedQRPh ? "QRPH" : "CASH_DECLARED",
                orderID: nil, entitlementID: model.checkoutEntitlement?.id, offlineRecordID: nil,
                phase: .claimed, lastServerState: nil, createdAt: now, updatedAt: now, resolution: nil, resolvedAt: nil)
            try store.begin(checkpoint)
            defer { store.resolve(id: session, reason: "test_cleanup") }
            model.galleryToken = String(repeating: "a", count: 64)
            model.installAuthorizationTaskForTesting()
            XCTAssertFalse(model.isCustomerResetSafe, "Automatic idle reset remains conservative")
            model.cancelSession()
            XCTAssertEqual(model.state, .welcome)
            XCTAssertNil(model.checkoutEntitlement)
            XCTAssertNil(model.sessionIdentifier)
            XCTAssertNil(model.galleryToken)
            XCTAssertNil(model.galleryQRCodeImage)
            XCTAssertTrue(model.capturedPhotos.isEmpty)
            XCTAssertFalse(model.hasActiveTaskForTesting)
            XCTAssertEqual(store.checkpoint(id: session), checkpoint, "Cancel must not resolve or alter the paid checkout")
            model.configurePaidCheckoutForTesting(qrPhEnabled: true, cashEnabled: true)
            XCTAssertNotEqual(model.sessionIdentifier, session)
            XCTAssertNil(model.checkoutEntitlement, "A new customer cannot inherit the cancelled customer's payment")
        }
    }

    func testPaymentAndCashScreensFitAndCenterInBothCarloOrientations() async throws {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            let model = BoothSessionViewModel()
            model.configurePaidCheckoutForTesting(qrPhEnabled: true, cashEnabled: true)
            model.confirmCopySelection()
            for cash in [false, true] {
                if cash { model.chooseCash() }
                let content = cash ? AnyView(CashAttestationView(viewModel: model)) : AnyView(CheckoutPaymentMethodView(viewModel: model))
                let (image, scroll) = try await render(content, size: size, name: "payment-\(cash ? "cash" : "methods")-\(Int(size.width))")
                XCTAssertLessThanOrEqual(scroll.contentSize.height, scroll.bounds.height + 1)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                let lines = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    return (text, observation.boundingBox)
                }
                XCTAssertTrue(lines.contains { $0.0.contains("Back") })
                XCTAssertTrue(lines.contains { $0.0.contains("Cancel") })
                let contentBounds = lines.filter { text, _ in
                    cash ? (text.contains("Please pay") || text.contains("QR Ph instead"))
                         : (text.contains("How would") || text.contains("Pay Cash"))
                }.map(\.1).reduce(CGRect.null) { $0.union($1) }
                XCTAssertFalse(contentBounds.isNull)
                XCTAssertEqual(contentBounds.midY, 0.5, accuracy: 0.12, "Payment content should be centered, not top aligned")
            }
        }
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
            let (web, window) = hostedBrowser(configuration: configuration)
            defer { web.stopLoading(); window.isHidden = true }
            try await loadFixture(html, in: web)
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
        // Keep one visible browser alive for the matrix rather than launching 45 WebContent
        // processes. Each fixture still loads independently and every viewport is asserted.
        let (web, window) = hostedBrowser()
        defer { web.stopLoading(); window.isHidden = true }
        for count in [1, 2, 3, 4, 6] {
            let html = try String(contentsOf: root.appendingPathComponent("gallery-\(count).html"), encoding: .utf8)
            try await loadFixture(html, in: web)
            for (width, height) in [(320, 900), (375, 900), (390, 900), (430, 900), (768, 1024), (1024, 768), (1440, 900), (844, 390), (1194, 834)] {
                window.frame = CGRect(x: 0, y: 0, width: width, height: height)
                web.frame = window.bounds
                window.layoutIfNeeded()
                web.layoutIfNeeded()
                try await waitForViewport(width, in: web)
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

    private func hostedBrowser(configuration: WKWebViewConfiguration? = nil) -> (WKWebView, UIWindow) {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration ?? WKWebViewConfiguration())
        let controller = UIViewController()
        controller.view = web
        let window = UIWindow(frame: web.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (web, window)
    }

    private func loadFixture(_ html: String, in web: WKWebView) async throws {
        let observer = GalleryFixtureNavigationObserver()
        web.navigationDelegate = observer
        defer { web.navigationDelegate = nil }
        web.loadHTMLString(html, baseURL: URL(string: "https://gallery.example.test"))
        await fulfillment(of: [observer.finished], timeout: 15)
        if let error = observer.error { throw error }
        guard observer.didFinish else {
            throw NSError(domain: "GalleryBrowserFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Visible gallery fixture navigation did not finish within 15 seconds."])
        }
        let ready = try await web.evaluateJavaScript("document.readyState === 'complete' && typeof photoItems !== 'undefined' && !!document.getElementById('shareAll') && !!document.getElementById('allHint')") as? Bool
        XCTAssertEqual(ready, true, "Navigation must finish with the actual gallery script and controls ready")
        guard ready == true else {
            throw NSError(domain: "GalleryBrowserFixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Gallery fixture loaded without its required script or controls."])
        }
    }

    private func waitForViewport(_ width: Int, in web: WKWebView) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var actual: Int?
        repeat {
            actual = try await web.evaluateJavaScript("innerWidth") as? Int
            if actual == width { return }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        XCTFail("Browser viewport did not resize to \(width); actual: \(String(describing: actual))")
        throw NSError(domain: "GalleryBrowserFixture", code: 3)
    }

}


@MainActor
private final class GalleryFixtureNavigationObserver: NSObject, WKNavigationDelegate {
    let finished = XCTestExpectation(description: "Visible gallery fixture navigation")
    private(set) var didFinish = false
    private(set) var error: Error?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish = true
        finished.fulfill()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
        finished.fulfill()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        finished.fulfill()
    }
}
