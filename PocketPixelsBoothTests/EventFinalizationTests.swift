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
    func testReceiptStylesSwitchBothCardsActionsAndLightboxAcrossWidths() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DerivedData/gallery-fixtures")
        let (web, window) = hostedBrowser()
        defer { web.stopLoading(); window.isHidden = true }
        for footer in ["integratedGalleryQR", "classicBarcodeAndGalleryQR", "decorativeBarcodeOnly"] {
            for style in ["shareFriendly", "asPrinted"] {
                let html = try String(contentsOf: root.appendingPathComponent("gallery-styles-\(footer)-\(style).html"), encoding: .utf8)
                try await loadFixture(html, in: web)
                try await waitForReceiptStyles(in: web)
                let selectorCount = try await web.evaluateJavaScript("document.querySelectorAll('[data-receipt-style]').length") as? Int
                XCTAssertEqual(selectorCount, footer == "decorativeBarcodeOnly" ? 0 : 2)
                for width in [320,375,390,430,768,1024,1440] {
                    window.frame.size = CGSize(width: width, height: 1000)
                    web.frame = window.bounds
                    web.superview?.layoutIfNeeded()
                    try await waitForViewport(width, in: web)
                    let valid = try await web.evaluateJavaScript("document.documentElement.scrollWidth<=innerWidth && document.querySelectorAll('.receipt-card').length===2 && [...document.querySelectorAll('[data-receipt-style]')].every(b=>b.getBoundingClientRect().height>=44)") as? Bool
                    XCTAssertEqual(valid, true, "\(footer)/\(style)/\(width)")
                }
                guard footer != "decorativeBarcodeOnly" else { continue }
                for selected in ["shareFriendly", "asPrinted", "shareFriendly"] {
                    _ = try await web.evaluateJavaScript("document.querySelector('[data-receipt-style=\(selected)]').click(); true")
                    try await waitForReceiptStyles(in: web)
                    let share = selected == "shareFriendly"
                    let color = share ? "receipt-share-color.jpg" : "receipt-color.jpg"
                    let bw = share ? "receipt-share-bw.png" : "receipt-bw.png"
                    let state = try await web.evaluateJavaScript("""
                    (()=>{const cards=[...document.querySelectorAll('.receipt-card')];return cards.every((card,i)=>{
                      const name=i===0?'\(color)':'\(bw)';return card.querySelector('img').id==='image-'+name && !card.querySelector('img').hidden && ['data-open','data-download','data-share'].every(key=>card.querySelector('['+key+']').getAttribute(key)===name);
                    }) && document.getElementById('receiptPrivacy').hidden===\(share ? "true" : "false") && document.querySelector('[data-receipt-style=\(selected)]').getAttribute('aria-pressed')==='true';})()
                    """) as? Bool
                    XCTAssertEqual(state, true)
                    _ = try await web.evaluateJavaScript("window.savedVariants=[];window.sharedVariants=[];saveItem=item=>savedVariants.push(fileForItem(item).name);shareItem=item=>sharedVariants.push(fileForItem(item).name);document.querySelector('.receipt-card [data-download]').click();document.querySelectorAll('.receipt-card [data-share]')[1].click();document.querySelectorAll('.receipt-card [data-open]')[1].click();true")
                    let actionFiles = try await web.evaluateJavaScript("savedVariants[0]+'|'+sharedVariants[0]+'|'+lightboxItems[0].filename") as? String
                    XCTAssertEqual(actionFiles, "\(color)|\(bw)|\(bw)")
                    _ = try await web.evaluateJavaScript("closeLightbox();true")
                }
                // Several competing async preparations must leave the last selected style in control.
                _ = try await web.evaluateJavaScript("['asPrinted','shareFriendly','asPrinted','shareFriendly'].forEach(s=>document.querySelector('[data-receipt-style='+s+']').click());true")
                try await waitForReceiptStyles(in: web)
                let finalImage = try await web.evaluateJavaScript("document.querySelector('.receipt-card img').id") as? String
                XCTAssertEqual(finalImage, "image-receipt-share-color.jpg")
            }
        }
    }

    func testUnavailableShareFriendlyAssetNeverShowsOrSavesTheQRReceipt() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DerivedData/gallery-fixtures")
        let html = try String(contentsOf: root.appendingPathComponent("gallery-styles-integratedGalleryQR-shareFriendly.html"), encoding: .utf8)
            .replacingOccurrences(of: "const startedAt=performance.now();", with: "galleryData.shareColorReceipt.base64Data='invalid-image';const startedAt=performance.now();")
        let (web, window) = hostedBrowser()
        defer { web.stopLoading(); window.isHidden = true }
        try await loadFixture(html, in: web)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var failed = false
        repeat {
            failed = try await web.evaluateJavaScript("document.getElementById('receiptStyleStatus').textContent.includes('Receipt unavailable')") as? Bool == true
            if !failed { try await Task.sleep(for: .milliseconds(30)) }
        } while !failed && ContinuousClock.now < deadline
        XCTAssertTrue(failed)
        let safe = try await web.evaluateJavaScript("[...document.querySelectorAll('.receipt-card img')].every(i=>i.hidden&&!i.getAttribute('src')) && [...document.querySelectorAll('.receipt-card button')].every(b=>b.disabled)") as? Bool
        XCTAssertEqual(safe, true, "No QR-bearing fallback or enabled wrong-file actions")
        _ = try await web.evaluateJavaScript("document.querySelector('[data-receipt-style=asPrinted]').click();true")
        try await waitForReceiptStyles(in: web)
    }

    func testReceiptStyleBeforeAfterScreenshots() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent("DerivedData/gallery-fixtures")
        let output = root.appendingPathComponent("BuildArtifacts/GalleryReceiptStyles")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let (web, window) = hostedBrowser()
        defer { web.stopLoading(); window.isHidden = true }
        for (name, file) in [("before", "gallery-styles-before.html"), ("after", "gallery-styles-integratedGalleryQR-shareFriendly.html")] {
            try await loadFixture(String(contentsOf: fixtures.appendingPathComponent(file), encoding: .utf8), in: web)
            try await waitForReceiptStyles(in: web)
            for width in [320,375,390,430,768,1024,1440] {
                window.frame.size = CGSize(width: width, height: 1000); web.frame = window.bounds
                web.superview?.layoutIfNeeded()
                try await waitForViewport(width, in: web)
                for region in ["hero", "receipts"] {
                    _ = try await web.evaluateJavaScript(region == "hero" ? "window.scrollTo({top:0,behavior:'instant'});true" : "window.scrollTo({top:document.getElementById('receipts').offsetTop-20,behavior:'instant'});true")
                    _ = try await web.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return true", arguments: [:], contentWorld: .page)
                    let snapshotConfiguration = WKSnapshotConfiguration()
                    snapshotConfiguration.afterScreenUpdates = true
                    let image: UIImage = try await withCheckedThrowingContinuation { continuation in
                        web.takeSnapshot(with: snapshotConfiguration) { image, error in
                            if let image { continuation.resume(returning: image) }
                            else { continuation.resume(throwing: error ?? NSError(domain: "GallerySnapshot", code: 1)) }
                        }
                    }
                    let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
                    XCTAssertGreaterThan(Set(pixels).count, 16, "Screenshot must contain rendered content")
                    try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("\(name)-\(region)-\(width).png"))
                }
            }
        }
    }

    private func waitForReceiptStyles(in web: WKWebView) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        repeat {
            let ready = try await web.evaluateJavaScript("[...document.querySelectorAll('.receipt-card img')].every(i=>!i.hidden&&i.complete&&i.naturalWidth>0) && [...document.querySelectorAll('.receipt-card button')].every(b=>!b.disabled)") as? Bool
            if ready == true { return }
            try await Task.sleep(for: .milliseconds(30))
        } while ContinuousClock.now < deadline
        XCTFail("Receipt variants failed to become ready")
        throw NSError(domain: "GalleryReceiptStyles", code: 1)
    }

    func testSlowImageDecodeKeepsPlaceholdersAndTouchTargetsUntilLoad() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DerivedData/gallery-fixtures")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: """
        window.heldPreviews = [];
        const originalSource = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
        Object.defineProperty(HTMLImageElement.prototype, 'src', {
            get: originalSource.get,
            set: function(value) {
                if (this.id.startsWith('image-')) { heldPreviews.push({image:this, source:value}); }
                else { originalSource.set.call(this, value); }
            }
        });
        window.releasePreviews = function() {
            window.releasedPreviews = heldPreviews.slice();
            heldPreviews.forEach(item => originalSource.set.call(item.image, item.source));
        };
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let (web, window) = hostedBrowser(configuration: configuration)
        defer { web.stopLoading(); window.isHidden = true }
        try await loadFixture(String(contentsOf: root.appendingPathComponent("gallery-2.html"), encoding: .utf8), in: web)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var prepared = false
        repeat {
            prepared = try await web.evaluateJavaScript("heldPreviews.length === 4") as? Bool == true
            if !prepared { try await Task.sleep(for: .milliseconds(20)) }
        } while !prepared && ContinuousClock.now < deadline
        XCTAssertTrue(prepared, "All previews must reach the deliberately delayed image loader")
        let retained = try await web.evaluateJavaScript("""
        heldPreviews.every(item => item.image.hidden
            && document.getElementById(item.image.id.replace('image-', 'placeholder-'))
            && item.image.closest('button').getBoundingClientRect().height >= 44)
        """) as? Bool
        XCTAssertEqual(retained, true, "Loading photos and receipts keep their placeholder and usable target")
        _ = try await web.evaluateJavaScript("releasePreviews(); true")
        var displayed = false
        let loadedDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            displayed = try await web.evaluateJavaScript("releasedPreviews.every(item => !item.image.hidden && item.image.complete && item.image.naturalWidth > 0 && !document.getElementById(item.image.id.replace('image-', 'placeholder-')))") as? Bool == true
            if !displayed { try await Task.sleep(for: .milliseconds(20)) }
        } while !displayed && ContinuousClock.now < loadedDeadline
        XCTAssertTrue(displayed, "Actual load events reveal every preview and remove its placeholder")
    }

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
                XCTAssertEqual(hidden, false)
                let hint = try await web.evaluateJavaScript("document.getElementById('allHint').textContent") as? String
                XCTAssertTrue(hint?.contains("Use Save under each photo") == true)
                _ = try await web.evaluateJavaScript("document.getElementById('shareAll').click()")
                let fallback = try await web.evaluateJavaScript("document.getElementById('message').textContent") as? String
                XCTAssertTrue(fallback?.contains("one photo at a time") == true)
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
        for count in [1, 2, 3, 4, 5, 6] {
            let html = try String(contentsOf: root.appendingPathComponent("gallery-\(count).html"), encoding: .utf8)
            try await loadFixture(html, in: web)
            for (width, height) in [(320, 900), (375, 900), (390, 900), (430, 900), (768, 1024), (1024, 768), (1440, 900), (844, 390), (1194, 834)] {
                window.frame = CGRect(x: 0, y: 0, width: width, height: height)
                web.frame = window.bounds
                window.layoutIfNeeded()
                web.layoutIfNeeded()
                try await waitForViewport(width, height: height, in: web)
                // Viewport synchronization is independent of the measured outcome.
                // A real overflow or collapsed target fails on this first settled measurement.
                let checks = try await web.evaluateJavaScript("""
                (()=>{const buttons=[...document.querySelectorAll('button')].filter(b=>b.getBoundingClientRect().width>0);return {overflow:document.documentElement.scrollWidth>innerWidth, photos:document.querySelectorAll('.shot').length, gif:document.querySelectorAll('[data-open="session.gif"]').length, small:buttons.filter(b=>b.getBoundingClientRect().height<43).length, save:!document.getElementById('shareAll').hidden, viewport:[innerWidth,innerHeight,document.documentElement.clientWidth], smallControls:buttons.filter(b=>b.getBoundingClientRect().height<43).map(b=>({id:b.id,label:b.getAttribute('aria-label'),height:b.getBoundingClientRect().height})), overflowElements:[...document.querySelectorAll('body *')].filter(e=>{const r=e.getBoundingClientRect();return r.width>0&&(r.right>innerWidth+1||r.left< -1);}).map(e=>({tag:e.tagName,id:e.id,class:e.getAttribute('class'),rect:[e.getBoundingClientRect().left,e.getBoundingClientRect().right]}))}})()
                """) as! [String: Any]
                XCTAssertEqual(checks["overflow"] as? Bool, false, "\(count) photos at \(width): \(checks)")
                XCTAssertEqual(checks["photos"] as? Int, count)
                XCTAssertEqual(checks["gif"] as? Int, 0)
                XCTAssertEqual(checks["small"] as? Int, 0, "\(count) photos at \(width): \(checks)")
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

    func testEditorialMenuReceiptsCollageAndPrivateInstagramNavigation() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DerivedData/gallery-fixtures")
        let (web, window) = hostedBrowser()
        defer { web.stopLoading(); window.isHidden = true }
        try await loadFixture(String(contentsOf: root.appendingPathComponent("gallery-2.html"), encoding: .utf8), in: web)
        let checks = try await web.evaluateJavaScript("""
        (()=>{const a=document.querySelector('.instagram-cta');return {receipts:document.querySelectorAll('.receipt-card').length, collapsed:document.querySelectorAll('details').length, collage:[...document.querySelectorAll('[data-collage]')].every(i=>i.src===document.getElementById('image-'+i.dataset.collage).src), instagram:a.href, referrer:a.referrerPolicy, rel:a.rel, order:!!(document.querySelector('.receipt-section').compareDocumentPosition(document.querySelector('.instagram-card'))&Node.DOCUMENT_POSITION_FOLLOWING)}})()
        """) as! [String: Any]
        XCTAssertEqual(checks["receipts"] as? Int, 2)
        XCTAssertEqual(checks["collapsed"] as? Int, 0)
        XCTAssertEqual(checks["collage"] as? Bool, true)
        XCTAssertEqual(checks["instagram"] as? String, "https://www.instagram.com/madetokeep.studios/")
        XCTAssertEqual(checks["referrer"] as? String, "no-referrer")
        XCTAssertEqual(checks["rel"] as? String, "noopener noreferrer")
        XCTAssertEqual(checks["order"] as? Bool, true)
        _ = try await web.evaluateJavaScript("document.getElementById('menuToggle').click()")
        let browserResult1 = try await web.evaluateJavaScript("document.getElementById('menuToggle').getAttribute('aria-expanded')") as? String
        XCTAssertEqual(browserResult1, "true")
        _ = try await web.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))")
        let browserResult2 = try await web.evaluateJavaScript("document.getElementById('galleryMenu').hidden") as? Bool
        XCTAssertEqual(browserResult2, true)
        let outbound = GalleryOutboundNavigationObserver()
        web.navigationDelegate = outbound
        _ = try await web.evaluateJavaScript("document.querySelector('.instagram-cta').click()")
        await fulfillment(of: [outbound.requested], timeout: 5)
        XCTAssertEqual(outbound.url?.absoluteString, "https://www.instagram.com/madetokeep.studios/")
        XCTAssertNil(outbound.referrer)
        web.navigationDelegate = nil
        try await loadFixture(String(contentsOf: root.appendingPathComponent("legacy.html"), encoding: .utf8), in: web)
        let browserResult3 = try await web.evaluateJavaScript("document.querySelectorAll('.receipt-card').length") as? Int
        XCTAssertEqual(browserResult3, 1)
    }

    func testGalleryLinkShareClipboardAndLightboxFocus() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: """
        window.linkShares=[];window.copiedLinks=[];
        Object.defineProperty(navigator,'share',{configurable:true,value:async data=>window.linkShares.push(data)});
        Object.defineProperty(navigator,'clipboard',{value:{writeText:async value=>window.copiedLinks.push(value)}});
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let (web, window) = hostedBrowser(configuration: configuration)
        defer { web.stopLoading(); window.isHidden = true }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DerivedData/gallery-fixtures")
        try await loadFixture(String(contentsOf: root.appendingPathComponent("gallery-2.html"), encoding: .utf8), in: web)
        _ = try await web.evaluateJavaScript("document.querySelector('[data-share-gallery]').click()")
        let browserResult4 = try await web.evaluateJavaScript("window.linkShares[0].url") as? String
        XCTAssertEqual(browserResult4, "https://gallery.example.test/?g=" + String(repeating: "c", count: 64))
        _ = try await web.evaluateJavaScript("Object.defineProperty(navigator,'share',{value:undefined});document.querySelector('[data-share-gallery]').click()")
        let browserResult5 = try await web.evaluateJavaScript("window.copiedLinks[0]") as? String
        XCTAssertEqual(browserResult5, "https://gallery.example.test/?g=" + String(repeating: "c", count: 64))
        _ = try await web.evaluateJavaScript("document.querySelector('[data-open]').focus();document.querySelector('[data-open]').click();document.getElementById('lightboxShare').focus();document.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}))")
        let browserResult6 = try await web.evaluateJavaScript("document.activeElement.id") as? String
        XCTAssertEqual(browserResult6, "lightboxClose")
        _ = try await web.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}))")
        let browserResult7 = try await web.evaluateJavaScript("document.getElementById('lightboxCount').textContent") as? String
        XCTAssertEqual(browserResult7, "2 / 2")
        _ = try await web.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))")
        let browserResult8 = try await web.evaluateJavaScript("document.activeElement.hasAttribute('data-open') && !document.querySelector('main').inert") as? Bool
        XCTAssertEqual(browserResult8, true)
    }

    func testFullSizePortraitLandscapeAndReceiptsFitViewport() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DerivedData/gallery-fixtures")
        let (web, window) = hostedBrowser()
        defer { web.stopLoading(); window.isHidden = true }
        try await loadFixture(String(contentsOf: root.appendingPathComponent("gallery-orientations.html"), encoding: .utf8), in: web)
        for (width, height) in [(320, 568), (390, 844), (844, 390), (768, 1024), (1440, 900)] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            web.frame = window.bounds
            window.layoutIfNeeded()
            web.layoutIfNeeded()
            try await waitForViewport(width, height: height, in: web)
            for name in ["photo-01.jpg", "photo-02.jpg", "receipt-color.jpg", "receipt-bw.png"] {
                _ = try await web.evaluateJavaScript("document.querySelector('[data-open=\"\(name)\"]').click()")
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                var loaded = false
                repeat {
                    loaded = try await web.evaluateJavaScript("document.getElementById('lightboxImage').complete && document.getElementById('lightboxImage').naturalWidth > 0") as? Bool == true
                    if !loaded { try await Task.sleep(for: .milliseconds(20)) }
                } while !loaded && ContinuousClock.now < deadline
                XCTAssertTrue(loaded)
                let fit = try await web.evaluateJavaScript("""
                (()=>{const image=document.getElementById('lightboxImage'),i=image.getBoundingClientRect(),s=document.querySelector('.lightbox-stage').getBoundingClientRect();return {contained:i.left>=s.left-1&&i.right<=s.right+1&&i.top>=s.top-1&&i.bottom<=s.bottom+1, visible:s.height>0&&s.top>=-1&&s.bottom<=innerHeight+1, fit:getComputedStyle(image).objectFit, width:document.documentElement.scrollWidth<=innerWidth, viewport:[innerWidth,innerHeight], stage:[s.top,s.bottom,s.height]};})()
                """) as! [String: Any]
                XCTAssertEqual(fit["contained"] as? Bool, true, "\(name) at \(width)×\(height)")
                XCTAssertEqual(fit["visible"] as? Bool, true, "\(name) at \(width)×\(height): \(fit)")
                XCTAssertEqual(fit["fit"] as? String, "contain")
                XCTAssertEqual(fit["width"] as? Bool, true)
                _ = try await web.evaluateJavaScript("document.getElementById('lightboxClose').click()")
            }
        }
    }

    /// Historical galleries stored the 1-bit printer raster as receipt-bw.png. Customers instead get a
    /// smooth grayscale copy derived in the browser from the color receipt, and saving/sharing it
    /// produces a genuinely monochrome PNG. New galleries keep the booth's grayscale bytes unchanged.
    func testBlackAndWhiteReceiptIsSmoothForHistoricalAndNewGalleries() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DerivedData/gallery-fixtures")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: """
        window.sharedFiles=[];
        Object.defineProperty(navigator,'userAgent',{get:()=> 'iPhone Safari'});
        Object.defineProperty(navigator,'canShare',{value:()=> true});
        Object.defineProperty(navigator,'share',{value:async data=>{window.sharedFiles.push(data.files);}});
        window.inspectGray=async function(blobOrImage){const image=blobOrImage instanceof Blob?await createImageBitmap(blobOrImage):blobOrImage;const c=document.createElement('canvas');c.width=image.naturalWidth||image.width;c.height=image.naturalHeight||image.height;const x=c.getContext('2d');x.drawImage(image,0,0);const d=x.getImageData(0,0,c.width,c.height).data;let colored=0;const levels=new Set();for(let i=0;i<d.length;i+=4){if(d[i]!==d[i+1]||d[i+1]!==d[i+2]){colored++;}levels.add(d[i]);}return {colored,levels:levels.size,width:c.width,height:c.height};};
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let (web, window) = hostedBrowser(configuration: configuration)
        defer { web.stopLoading(); window.isHidden = true }

        try await loadFixture(String(contentsOf: root.appendingPathComponent("gallery-historical-raster.html"), encoding: .utf8), in: web)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var shown = false
        repeat {
            shown = try await web.evaluateJavaScript("(()=>{const i=document.getElementById('image-receipt-bw.png');return !i.hidden&&i.src.startsWith('blob:')&&i.complete&&i.naturalWidth>0;})()") as? Bool == true
            if !shown { try await Task.sleep(for: .milliseconds(50)) }
        } while !shown && ContinuousClock.now < deadline
        XCTAssertTrue(shown, "Derived black & white receipt is displayed")
        let card = try await web.evaluateJavaScript("""
        (()=>{const cards=[...document.querySelectorAll('.receipt-card h3')].map(h=>h.textContent);return {cards, raster:typeof galleryData.thermalReceipt.base64Data, derive:galleryData.thermalReceipt.deriveFrom, fallback:document.querySelectorAll('.mono-fallback').length};})()
        """) as! [String: Any]
        XCTAssertEqual(card["cards"] as? [String], ["Color Receipt", "Black & White Receipt"])
        XCTAssertEqual(card["raster"] as? String, "undefined", "The legacy raster is not embedded")
        XCTAssertEqual(card["derive"] as? String, "receipt-color.jpg")
        XCTAssertEqual(card["fallback"] as? Int, 0)
        let displayed = try await web.callAsyncJavaScript("return await inspectGray(document.getElementById('image-receipt-bw.png'))", contentWorld: .page) as! [String: Any]
        XCTAssertEqual(displayed["colored"] as? Int, 0, "Displayed receipt is pure grayscale")
        XCTAssertGreaterThan(displayed["levels"] as? Int ?? 0, 32, "Smooth tones, not a 1-bit raster: \(displayed)")
        XCTAssertEqual(displayed["width"] as? Int, 576)
        XCTAssertEqual(displayed["height"] as? Int, 1112, "Same geometry as the color receipt")

        _ = try await web.evaluateJavaScript("document.querySelector('[data-download=\"receipt-bw.png\"]').click()")
        let saved = try await web.callAsyncJavaScript("""
        for(let i=0;i<100&&!window.sharedFiles.length;i++){await new Promise(r=>setTimeout(r,30));}
        const file=window.sharedFiles[0][0];const gray=await inspectGray(file);return {name:file.name,type:file.type,size:file.size,...gray};
        """, contentWorld: .page) as! [String: Any]
        XCTAssertEqual(saved["name"] as? String, "receipt-bw.png")
        XCTAssertEqual(saved["type"] as? String, "image/png")
        XCTAssertGreaterThan(saved["size"] as? Int ?? 0, 0)
        XCTAssertEqual(saved["colored"] as? Int, 0, "Saved file is genuinely monochrome")
        XCTAssertGreaterThan(saved["levels"] as? Int ?? 0, 32)

        _ = try await web.evaluateJavaScript("document.querySelector('[data-open=\"receipt-bw.png\"]').click()")
        let lightbox = try await web.evaluateJavaScript("[!document.getElementById('lightbox').hidden, document.getElementById('lightboxCount').textContent, document.getElementById('lightboxImage').alt]") as? [Any]
        XCTAssertEqual(lightbox?[0] as? Bool, true)
        XCTAssertEqual(lightbox?[1] as? String, "black & white receipt")
        XCTAssertEqual(lightbox?[2] as? String, "Made to Keep Studios black and white receipt")
        _ = try await web.evaluateJavaScript("document.getElementById('lightboxClose').click()")

        // New gallery: the booth's smooth grayscale PNG is used byte-for-byte, with no derivation.
        try await loadFixture(String(contentsOf: root.appendingPathComponent("gallery-2.html"), encoding: .utf8), in: web)
        let fresh = try await web.callAsyncJavaScript("""
        const item=galleryData.thermalReceipt;const file=fileForItem(item);const stored=atob(item.base64Data);const bytes=new Uint8Array(await file.arrayBuffer());let same=bytes.length===stored.length;for(let i=0;same&&i<bytes.length;i++){same=bytes[i]===stored.charCodeAt(i);}return {derive:item.deriveFrom||null,same,colorType:bytes[25],depth:bytes[24]};
        """, contentWorld: .page) as! [String: Any]
        XCTAssertTrue(fresh["derive"] is NSNull)
        XCTAssertEqual(fresh["same"] as? Bool, true)
        XCTAssertEqual(fresh["colorType"] as? Int, 0)
        XCTAssertEqual(fresh["depth"] as? Int, 8)
    }

    private func hostedBrowser(configuration: WKWebViewConfiguration? = nil) -> (WKWebView, UIWindow) {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration ?? WKWebViewConfiguration())
        let controller = UIViewController()
        controller.view = web
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = web.frame
        } else { window = UIWindow(frame: web.frame) }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (web, window)
    }

    private func loadFixture(_ html: String, in web: WKWebView) async throws {
        let observer = GalleryFixtureNavigationObserver()
        web.navigationDelegate = observer
        defer { web.navigationDelegate = nil }
        // Mark the current document so a stale page can never satisfy the readiness check below.
        _ = try? await web.evaluateJavaScript("window.__previousFixture = true; true")
        // A unique ignored parameter per load: the iOS 27 simulator's WebKit stalls when the same
        // view reloads an identical fragment URL. The gallery drops every parameter except `g`.
        web.loadHTMLString(html, baseURL: URL(string: "https://gallery.example.test/?g=" + String(repeating: "c", count: 64) + "&ignored=private&fixture=\(UUID().uuidString)#photos"))
        // Poll the new document directly rather than relying only on didFinish.
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        var loadedNewDocument = false
        repeat {
            if let error = observer.error { throw error }
            loadedNewDocument = (try? await web.evaluateJavaScript("window.__previousFixture !== true && document.readyState === 'complete'") as? Bool) == true
            if !loadedNewDocument { try await Task.sleep(for: .milliseconds(50)) }
        } while !loadedNewDocument && ContinuousClock.now < deadline
        guard loadedNewDocument else {
            throw NSError(domain: "GalleryBrowserFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Visible gallery fixture navigation did not finish within 45 seconds."])
        }
        let ready = try await web.evaluateJavaScript("document.readyState === 'complete' && typeof photoItems !== 'undefined' && !!document.getElementById('shareAll') && !!document.getElementById('allHint')") as? Bool
        XCTAssertEqual(ready, true, "Navigation must finish with the actual gallery script and controls ready")
        guard ready == true else {
            throw NSError(domain: "GalleryBrowserFixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Gallery fixture loaded without its required script or controls."])
        }
    }

    private func waitForViewport(_ width: Int, height: Int? = nil, in web: WKWebView) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var actual: Int?
        repeat {
            actual = try await web.evaluateJavaScript("innerWidth") as? Int
            if actual == width {
                let actualHeight = try await web.evaluateJavaScript("innerHeight") as? Int
                if height == nil || actualHeight == height {
                    // WebKit can expose innerWidth before committing the matching media-query
                    // layout. Wait for two rendered frames, then recheck both viewport owners.
                    // Assertions below still reject every overflow and undersized control.
                    let stable = try await web.callAsyncJavaScript("""
                    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
                    return innerWidth === width && document.documentElement.clientWidth === width
                        && (height === null || innerHeight === height)
                        && matchMedia('(width: ' + width + 'px)').matches;
                    """, arguments: ["width": width, "height": height.map { $0 as Any } ?? NSNull()], contentWorld: .page) as? Bool
                    if stable == true { return }
                }
            }
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

@MainActor
private final class GalleryOutboundNavigationObserver: NSObject, WKNavigationDelegate {
    let requested = XCTestExpectation(description: "Approved Instagram navigation")
    var url: URL?
    var referrer: String?
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        url = navigationAction.request.url
        referrer = navigationAction.request.value(forHTTPHeaderField: "Referer")
        requested.fulfill()
        decisionHandler(.cancel)
    }
}
