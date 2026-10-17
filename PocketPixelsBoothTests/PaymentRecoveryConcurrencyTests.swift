import XCTest
@testable import PocketPixelsBooth

/// A read-only Payments Worker view whose answers can be held in flight, so an older response
/// can be made to arrive after a newer one. It has no mutation methods at all.
@MainActor private final class HeldRecoveryReader: CheckoutRecoveryReading {
    nonisolated let environment = "test"
    var serverState: [String: String] = [:]   // session → order JSON (or "unreachable")
    var calls: [String] = []
    var holdNext = false
    private var held: [CheckedContinuation<Void, Never>] = []

    @MainActor func checkoutRecovery(checkoutSessionID: String) async throws -> CheckoutRecoveryResponse {
        calls.append(checkoutSessionID)
        // The answer reflects the server at the moment the request was handled...
        let state = serverState[checkoutSessionID]
        if holdNext { holdNext = false; await withCheckedContinuation { held.append($0) } }
        // ...and may be delivered much later.
        guard let state, state != "unreachable" else { throw PaymentsAPIError.unavailable }
        let json = #"{"checkoutSessionId":"\#(checkoutSessionID)","orders":[\#(state)],"openOrderId":"o1","serverTime":"2026-10-17T04:00:00.000Z"}"#
        return try PaymentsAPIClient.makeDecoder().decode(CheckoutRecoveryResponse.self, from: Data(json.utf8))
    }
    var holding: Bool { !held.isEmpty }
    func release() { let pending = held; held = []; pending.forEach { $0.resume() } }
}

@MainActor final class PaymentRecoveryConcurrencyTests: XCTestCase {
    private var root: URL!
    private var store: CheckoutCheckpointStore!
    private var reader: HeldRecoveryReader!
    private var coordinator: PaymentRecoveryCoordinator!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID())")
        store = try CheckoutCheckpointStore(directory: root)
        reader = HeldRecoveryReader()
        let store = store!, reader = reader!
        coordinator = PaymentRecoveryCoordinator(checkpointStore: { store }, reader: { reader }, outboxClient: { nil })
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func checkout(_ id: String, phase: CheckoutPhase = .awaitingProvider) throws {
        let now = Date()
        try store.begin(CheckoutCheckpoint(id: id, environment: "test", deviceID: nil, accountID: nil, eventID: "ev", policyRevisionID: "r1", unitPriceCentavos: 5000,
                                           copies: 3, format: "solo", method: "QRPH", orderID: nil, entitlementID: nil, offlineRecordID: nil, phase: phase,
                                           lastServerState: nil, createdAt: now, updatedAt: now, resolution: nil, resolvedAt: nil))
    }
    private func order(state: String, attempt: String, entitlement: String? = nil) -> String {
        let ent = entitlement.map { #"{"id":"e1","orderId":"o1","eventId":"ev","policyRevisionId":"r1","sessionId":null,"selectedFormat":"solo","purchasedCopies":3,"unitPriceCentavos":5000,"totalCentavos":15000,"authorizationSource":"VERIFIED_QRPH","authorizedAt":"2026-10-17T03:00:00.000Z","state":"\#($0)","receiptFingerprint":null}"# } ?? "null"
        return #"{"order":{"id":"o1","eventId":"ev","policyRevisionId":"r1","format":"solo","copies":3,"unitPriceCentavos":5000,"totalCentavos":15000,"currency":"PHP","state":"\#(state)","paymentMethod":"QRPH","expiresAt":null},"attempt":{"id":"a1","method":"QRPH","state":"\#(attempt)","qrImageDataURL":null,"testURL":null,"expiresAt":null},"entitlement":\#(ent),"newCheckout":{"allowed":false,"reason":"x"},"printOutcomes":[]}"#
    }
    private func waitUntilHolding() async {
        for _ in 0..<200 where !reader.holding { await Task.yield() }
        XCTAssertTrue(reader.holding)
    }

    func testOlderResponseArrivingLateNeverOverwritesNewerClassification() async throws {
        try checkout("PP-1")
        reader.serverState["PP-1"] = order(state: "PAYMENT_PENDING", attempt: "AWAITING_PAYMENT")
        reader.holdNext = true
        let startup = Task { await coordinator.refresh() }           // launch
        await waitUntilHolding()
        reader.serverState["PP-1"] = order(state: "AUTHORIZED", attempt: "PAID_VERIFIED", entitlement: "AUTHORIZED")
        let foreground = Task { await coordinator.refresh() }        // scene became active
        await Task.yield()
        reader.release()                                              // the old answer arrives last
        await startup.value; await foreground.value
        XCTAssertEqual(coordinator.items.map(\.classification), [.paidUnclaimed(verified: true)], "The newest server answer wins")
        XCTAssertEqual(coordinator.completedRefreshPasses, 2)
        XCTAssertEqual(reader.calls, ["PP-1", "PP-1"], "Passes never overlap")
        XCTAssertFalse(store.checkpoint(id: "PP-1")!.isResolved, "A paid checkout is never resolved by refresh")
    }

    func testManySimultaneousRequestsCoalesceIntoOneFollowUpPass() async throws {
        try checkout("PP-1"); try checkout("PP-2")
        reader.serverState["PP-1"] = order(state: "PAYMENT_PENDING", attempt: "AWAITING_PAYMENT")
        reader.serverState["PP-2"] = order(state: "PAYMENT_PENDING", attempt: "AWAITING_PAYMENT")
        reader.holdNext = true
        let first = Task { await coordinator.refresh() }
        await waitUntilHolding()
        let others = (0..<4).map { _ in Task { await coordinator.refresh() } }
        await Task.yield()
        reader.release()
        await first.value
        for task in others { await task.value }
        XCTAssertEqual(coordinator.completedRefreshPasses, 2, "Five requests, two passes")
        XCTAssertEqual(reader.calls.count, 4, "Two checkouts × two passes; no duplicate server traffic")
    }

    func testOperatorDismissalDuringARefreshIsNeverResurrectedOrOverwritten() async throws {
        try checkout("PP-1")
        reader.serverState["PP-1"] = order(state: "PAYMENT_PENDING", attempt: "QR_EXPIRED_CONFIRMED")   // would auto-resolve as unpaid
        reader.holdNext = true
        let pass = Task { await coordinator.refresh() }
        await waitUntilHolding()
        coordinator.dismiss(CheckoutRecoveryItem(checkpoint: store.checkpoint(id: "PP-1")!, classification: .paymentPending), reason: "Attendant refunded in person")
        reader.release()
        await pass.value
        XCTAssertTrue(coordinator.items.isEmpty)
        XCTAssertEqual(store.checkpoint(id: "PP-1")?.resolution, "operator:Attendant refunded in person", "The operator's recorded decision stands")
    }

    func testTimeoutUnknownAndPossiblyPaidExpiredStatesStayPendingAndUnresolved() async throws {
        try checkout("PP-timeout"); try checkout("PP-unknown"); try checkout("PP-expired"); try checkout("PP-late")
        reader.serverState["PP-timeout"] = "unreachable"
        reader.serverState["PP-unknown"] = order(state: "PAYMENT_PENDING", attempt: "UNKNOWN_RECONCILIATION")
        reader.serverState["PP-expired"] = order(state: "PAYMENT_PENDING", attempt: "QR_EXPIRED")     // expired, not confirmed unpaid
        reader.serverState["PP-late"] = order(state: "LATE_PAID_REVIEW", attempt: "PAID_VERIFIED", entitlement: "REVIEW_REQUIRED")
        await coordinator.refresh()
        let byID = Dictionary(uniqueKeysWithValues: coordinator.items.map { ($0.id, $0.classification) })
        XCTAssertEqual(byID["PP-timeout"], .paymentPending)
        XCTAssertEqual(byID["PP-unknown"], .paymentPending)
        XCTAssertEqual(byID["PP-expired"], .paymentPending, "An expired QR may still have been paid")
        XCTAssertEqual(byID["PP-late"], .needsReview("late payment on a replaced checkout"))
        XCTAssertTrue(store.unresolved.count == 4, "Unknown financial outcomes stay unknown")
        XCTAssertTrue(coordinator.lastRefreshMessage.contains("unreachable"))
        XCTAssertNil(coordinator.lastRefreshCompletedAt, "A partial check is not reported as a successful one")
    }

    func testVerifiedPaymentStaysResumableAndArmedResumeFollowsTheNewestAnswer() async throws {
        try checkout("PP-1")
        reader.serverState["PP-1"] = order(state: "AUTHORIZED", attempt: "PAID_VERIFIED", entitlement: "AUTHORIZED")
        await coordinator.refresh()
        let item = try XCTUnwrap(coordinator.items.first)
        XCTAssertEqual(item.classification, .paidUnclaimed(verified: true))
        XCTAssertTrue(coordinator.armResume(item))
        // The server now reports the entitlement is under review: the armed resume is withdrawn.
        reader.serverState["PP-1"] = order(state: "AUTHORIZED", attempt: "PAID_VERIFIED", entitlement: "REVIEW_REQUIRED")
        await coordinator.refresh()
        XCTAssertNil(coordinator.armedResume, "A stale armed resume can't start a session the server now holds")
        XCTAssertNil(coordinator.takeArmedResume())
        XCTAssertFalse(store.checkpoint(id: "PP-1")!.isResolved)
        XCTAssertNotNil(coordinator.lastRefreshCompletedAt)
    }
}
