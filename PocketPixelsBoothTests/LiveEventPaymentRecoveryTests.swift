import XCTest
import SwiftUI
@testable import PocketPixelsBooth

private final class LiveRecoveryProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: (LiveRecoveryProtocol) -> Void] = [:]
    static func setHandler(_ handler: ((LiveRecoveryProtocol) -> Void)?, host: String) {
        lock.withLock { handlers[host] = handler }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.lock.withLock { Self.handlers[request.url!.host!] }
        if let handler { handler(self) }
        else { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
    }
    override func stopLoading() { }
    func respond(_ json: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct LiveRecoveryCredential: PaymentCredentialProviding {
    func load() throws -> String? { String(repeating: "x", count: 40) }
}

@MainActor
final class LiveEventPaymentRecoveryTests: XCTestCase {
    private var directory: URL!
    private var store: CheckoutCheckpointStore!
    private var model: BoothSessionViewModel!
    private var requests: [String] = []
    private var host = ""
    private var tearingDown = false
    private let order = #"{"id":"original-order","eventId":"ev","policyRevisionId":"r1","format":"solo","copies":2,"unitPriceCentavos":2500,"totalCentavos":5000,"currency":"PHP","state":"PAYMENT_PENDING","paymentMethod":"QRPH"}"#

    override func setUp() async throws {
        host = UUID().uuidString.lowercased() + ".example.test"
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try CheckoutCheckpointStore(directory: directory)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LiveRecoveryProtocol.self]
        let client = PaymentsAPIClient(configuration: PaymentsConfiguration(baseURL: URL(string: "https://" + host)!, environment: "test"), credentialStore: LiveRecoveryCredential(), session: URLSession(configuration: config))
        var environment = BoothSessionEnvironment.customer
        environment.recoveryDirectory = directory
        environment.archiveDirectory = directory
        environment.deliversGallery = false
        environment.recordsCustomerSessionMetrics = false
        model = BoothSessionViewModel(environment: environment, paymentsClient: client, checkpointStore: store)
        model.configurePaidCheckoutForTesting(qrPhEnabled: true, cashEnabled: true)
        let now = Date()
        try store.begin(CheckoutCheckpoint(id: model.sessionIdentifier!, environment: "test", eventID: "ev", policyRevisionID: "r1", unitPriceCentavos: 2500, copies: 2, format: "solo", method: "QRPH", phase: .paymentRequested, createdAt: now, updatedAt: now))
    }

    override func tearDown() async throws {
        tearingDown = true
        LiveRecoveryProtocol.setHandler(nil, host: host)
        PaymentRecoveryCoordinator.shared.disarmResume()
        model.cancelActiveTaskForTesting()
        model.resetAfterDone()
        model = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func recovery(_ session: String, empty: Bool = false) -> String {
        #"{"checkoutSessionId":"\#(session)","orders":\#(empty ? "[]" : "[{\"order\":" + order + ",\"printOutcomes\":[]}]") ,"openOrderId":\#(empty ? "null" : "\"original-order\""),"serverTime":"2026-10-16T04:00:00.000Z"}"#
    }

    private func status(_ state: String = "UNKNOWN_RECONCILIATION", allowed: Bool = false, entitlement: String = "null") -> String {
        #"{"order":\#(order),"attempt":{"id":"original-attempt","method":"QRPH","state":"\#(state)"},"entitlement":\#(entitlement),"newCheckout":{"allowed":\#(allowed),"reason":"synthetic"},"serverTime":"2026-10-16T04:00:00.000Z"}"#
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for payment state processing")
    }

    private func installHandler(_ body: @escaping @MainActor (LiveRecoveryProtocol) -> Void) {
        LiveRecoveryProtocol.setHandler({ stub in
            Task { @MainActor [weak self] in
                guard let self, !self.tearingDown else { return }
                self.requests.append("\(stub.request.httpMethod!) \(stub.request.url!.path)")
                body(stub)
            }
        }, host: host)
    }

    func testUnknownOrderIsLookedUpWithoutCreatingAnotherPaymentAndCancellationKeepsRecord() async throws {
        let session = model.sessionIdentifier!
        let received = expectation(description: "Original order status read")
        installHandler { stub in
            if stub.request.url!.path.contains("checkouts") { stub.respond(self.recovery(session)) }
            else { stub.respond(self.status()); received.fulfill() }
        }
        model.beginPaymentReconciliationForTesting()
        await fulfillment(of: [received], timeout: 3)
        try await waitFor { self.model.paymentAttempt != nil }
        model.cancelSession()
        XCTAssertEqual(model.state, .paymentReconciliation)
        XCTAssertFalse(model.canStartNewCheckout)
        XCTAssertEqual(store.unresolved.map(\.id), [session])
        XCTAssertTrue(requests.allSatisfy { $0.hasPrefix("GET ") })
        XCTAssertTrue(requests.contains("GET /v1/orders/original-order/status"))
        XCTAssertNil(model.checkoutEntitlement)
    }

    func testEmptyLookupRequiresAttendantAndDoesNotDeclareCheckoutUnpaid() async throws {
        let session = model.sessionIdentifier!
        installHandler { $0.respond(self.recovery(session, empty: true)) }
        model.beginPaymentReconciliationForTesting()
        let task = try XCTUnwrap(model.paymentPollTaskForTesting)
        await task.value
        XCTAssertEqual(model.state, .paymentReconciliation)
        XCTAssertTrue(model.statusMessage.contains("attendant review"))
        XCTAssertFalse(model.canStartNewCheckout)
        XCTAssertFalse(store.unresolved.isEmpty)
        XCTAssertEqual(requests.count, 1)
    }

    func testTimeoutRetainsUnknownOutcomeAndForegroundRecoversOriginalOrder() async throws {
        let session = model.sessionIdentifier!
        let failed = expectation(description: "Timeout")
        installHandler { stub in
            stub.client?.urlProtocol(stub, didFailWithError: URLError(.timedOut))
            failed.fulfill()
        }
        model.beginPaymentReconciliationForTesting()
        await fulfillment(of: [failed], timeout: 3)
        await Task.yield()
        XCTAssertFalse(model.canStartNewCheckout)
        XCTAssertFalse(store.unresolved.isEmpty)
        let recovered = expectation(description: "Foreground original checkout")
        installHandler { stub in
            if stub.request.url!.path.contains("checkouts") { stub.respond(self.recovery(session)) }
            else { stub.respond(self.status()); recovered.fulfill() }
        }
        model.handleScenePhase(.background)
        model.handleScenePhase(.active)
        await fulfillment(of: [recovered], timeout: 3)
        XCTAssertTrue(requests.allSatisfy { $0.hasPrefix("GET ") })
        XCTAssertEqual(model.sessionIdentifier, session)
    }

    func testCancelledPollCannotReturnAuthorizedCameraToPayment() async throws {
        let requested = expectation(description: "Lookup held")
        installHandler { _ in requested.fulfill() }
        model.beginPaymentReconciliationForTesting()
        let task = try XCTUnwrap(model.paymentPollTaskForTesting)
        await fulfillment(of: [requested], timeout: 3)
        model.configureAuthorizedCameraReadyForTesting(authorizationSource: .verifiedQRPh)
        XCTAssertTrue(model.releaseAuthorizationTaskForCamera(generation: 0))
        await task.value
        XCTAssertEqual(model.state, .cameraReady)
        XCTAssertNotNil(model.checkoutEntitlement)
    }

    func testResetCancelsPreviousPollWithoutChangingNextCustomer() async throws {
        let requested = expectation(description: "Lookup held")
        installHandler { _ in requested.fulfill() }
        model.beginPaymentReconciliationForTesting()
        let task = try XCTUnwrap(model.paymentPollTaskForTesting)
        await fulfillment(of: [requested], timeout: 3)
        model.resetAfterDone()
        model.configurePaidCheckoutForTesting(qrPhEnabled: true, cashEnabled: true)
        let nextSession = model.sessionIdentifier
        await task.value
        XCTAssertEqual(model.state, .choosingCopies)
        XCTAssertEqual(model.sessionIdentifier, nextSession)
        XCTAssertNil(model.paymentOrder)
        XCTAssertNil(model.paymentAttempt)
    }

    func testVerifiedPaymentClaimsOriginalEntitlementAndSession() async throws {
        let session = model.sessionIdentifier!
        func entitlement(_ state: String) -> String {
            #"{"id":"original-entitlement","orderId":"original-order","eventId":"ev","policyRevisionId":"r1","sessionId":"\#(session)","selectedFormat":"solo","purchasedCopies":2,"unitPriceCentavos":2500,"totalCentavos":5000,"authorizationSource":"VERIFIED_QRPH","authorizedAt":"2026-10-16T04:00:00.000Z","state":"\#(state)"}"#
        }
        installHandler { stub in
            let path = stub.request.url!.path
            if path.contains("checkouts") { stub.respond(self.recovery(session)) }
            else if path.contains("status") { stub.respond(self.status("PAID_VERIFIED", entitlement: entitlement("AUTHORIZED"))) }
            else if path.hasSuffix("/claim") { stub.respond("{\"entitlement\":\(entitlement("IN_SESSION"))}") }
            else { XCTFail("Unexpected mutation: \(path)") }
        }
        model.beginPaymentReconciliationForTesting()
        let task = try XCTUnwrap(model.paymentPollTaskForTesting)
        try await waitFor { self.model.checkoutEntitlement != nil }
        if model.checkoutEntitlement == nil { model.cancelActiveTaskForTesting() }
        await task.value
        XCTAssertEqual(model.checkoutEntitlement?.id, "original-entitlement")
        XCTAssertEqual(model.checkoutEntitlement?.sessionID, session)
        XCTAssertEqual(model.selectedPrintCopies, 2)
        XCTAssertEqual(store.checkpoint(id: session)?.entitlementID, "original-entitlement")
        XCTAssertEqual(requests.filter { $0.hasPrefix("POST ") }, ["POST /v1/entitlements/original-entitlement/claim"])
    }

    func testOnlyConclusiveUnpaidServerDecisionAllowsDeliberateNewCheckout() async throws {
        let session = model.sessionIdentifier!
        let received = expectation(description: "Conclusive status")
        installHandler { stub in
            if stub.request.url!.path.contains("checkouts") { stub.respond(self.recovery(session)) }
            else { stub.respond(self.status("QR_EXPIRED_CONFIRMED", allowed: true)); received.fulfill() }
        }
        model.beginPaymentReconciliationForTesting()
        await fulfillment(of: [received], timeout: 3)
        // Await response processing, without waiting for a second polling cycle.
        try await waitFor { self.model.canStartNewCheckout }
        XCTAssertTrue(model.canStartNewCheckout)
        model.startNewCheckout()
        XCTAssertEqual(model.state, .choosingPayment)
        XCTAssertNil(model.paymentAttempt)
        XCTAssertTrue(requests.allSatisfy { $0.hasPrefix("GET ") }, "A new financial obligation requires a separate guest choice")
    }
    func testLostConnectionRevokesPreviouslyAllowedReplacement() async throws {
        let session = model.sessionIdentifier!
        installHandler { stub in
            if stub.request.url!.path.contains("checkouts") { stub.respond(self.recovery(session)) }
            else { stub.respond(self.status("QR_EXPIRED_CONFIRMED", allowed: true)) }
        }
        model.beginPaymentReconciliationForTesting()
        try await waitFor { self.model.canStartNewCheckout }
        installHandler { stub in
            stub.client?.urlProtocol(stub, didFailWithError: URLError(.networkConnectionLost))
        }
        model.recheckPayment()
        try await waitFor { !self.model.canStartNewCheckout }
        XCTAssertEqual(model.state, .paymentReconciliation)
        XCTAssertTrue(model.checkoutGuard.qrAttemptUnresolved)
        XCTAssertFalse(store.unresolved.isEmpty)
        XCTAssertTrue(requests.allSatisfy { $0.hasPrefix("GET ") })
    }

    func testRapidStartTapsCannotReplaceAnExistingCustomer() {
        let session = model.sessionIdentifier
        for _ in 0..<20 { model.startSession() }
        XCTAssertEqual(model.state, .choosingCopies)
        XCTAssertEqual(model.sessionIdentifier, session)
        XCTAssertNil(model.paymentOrder)
        XCTAssertFalse(model.hasActiveTaskForTesting)
    }

    func testOperatorArmedResumeFromReconciliationRevalidatesAndClaimsSameCheckout() async throws {
        let checkpoint = try XCTUnwrap(store.unresolved.first)
        let session = checkpoint.id
        var originalProfile = EventProfile.pocketPixelsDefault
        originalProfile.isEnabled = true
        originalProfile.eventName = "Original Paid Event"
        originalProfile.receiptDesign.editorialCaption = "ORIGINAL RECEIPT"
        let saved = AppRecoverySnapshot(schemaVersion: 1, sessionIdentifier: session, createdAt: checkpoint.createdAt,
            format: .solo, eventProfile: originalProfile, galleryToken: String(repeating: "a", count: 64),
            galleryURL: URL(string: "https://example.test/?g=" + String(repeating: "a", count: 64)),
            photoJPEGData: [], receiptPreviewPNGData: nil, thermalPreviewPNGData: nil,
            rasterFingerprint: nil, stage: .formatSelected, updatedAt: Date())
        try AppRecoveryStore(directoryURL: directory).saveCritical(saved)
        func entitlement(_ state: String) -> String {
            #"{"id":"original-entitlement","orderId":"original-order","eventId":"ev","policyRevisionId":"r1","sessionId":"\#(session)","selectedFormat":"solo","purchasedCopies":2,"unitPriceCentavos":2500,"totalCentavos":5000,"authorizationSource":"VERIFIED_QRPH","authorizedAt":"2026-10-16T04:00:00.000Z","state":"\#(state)"}"#
        }
        installHandler { stub in
            if stub.request.url!.path.contains("checkouts") {
                stub.respond(#"{"checkoutSessionId":"\#(session)","orders":[{"order":\#(self.order),"entitlement":\#(entitlement("AUTHORIZED")),"printOutcomes":[]}],"openOrderId":"original-order","serverTime":"2026-10-16T04:00:00.000Z"}"#)
            } else if stub.request.url!.path.hasSuffix("/claim") {
                stub.respond("{\"entitlement\":\(entitlement("IN_SESSION"))}")
            } else { XCTFail("Unexpected request") }
        }
        let recovery = PaymentRecoveryCoordinator.shared
        XCTAssertTrue(recovery.armResume(CheckoutRecoveryItem(checkpoint: checkpoint, classification: .paidUnclaimed(verified: true))))
        model.state = .paymentReconciliation
        model.resumeArmedCheckoutForCurrentGuest()
        await model.activeTaskForTesting?.value
        XCTAssertEqual(model.customerEventProfile.eventName, "Original Paid Event")
        XCTAssertEqual(model.customerEventProfile.receiptDesign.editorialCaption, "ORIGINAL RECEIPT")
        XCTAssertNil(recovery.armedResume)
        XCTAssertEqual(model.checkoutEntitlement?.id, "original-entitlement")
        XCTAssertEqual(model.sessionIdentifier, session)
        XCTAssertEqual(requests.filter { $0.hasPrefix("POST ") }, ["POST /v1/entitlements/original-entitlement/claim"])
    }

    func testOperatorResumeCannotReplaceDifferentGuestOrAuthorizedCamera() throws {
        let checkpoint = try XCTUnwrap(store.unresolved.first)
        let recovery = PaymentRecoveryCoordinator.shared
        XCTAssertTrue(recovery.armResume(CheckoutRecoveryItem(checkpoint: checkpoint, classification: .paidUnclaimed(verified: true))))
        model.state = .paymentReconciliation
        model.sessionIdentifier = "another-customer"
        model.resumeArmedCheckoutForCurrentGuest()
        XCTAssertEqual(model.sessionIdentifier, "another-customer")
        XCTAssertNotNil(recovery.armedResume)
        model.configureAuthorizedCameraReadyForTesting(authorizationSource: .verifiedQRPh)
        model.resumeArmedCheckoutForCurrentGuest()
        XCTAssertEqual(model.state, .cameraReady)
        XCTAssertNotNil(recovery.armedResume)
        XCTAssertFalse(model.hasActiveTaskForTesting)
    }

}
