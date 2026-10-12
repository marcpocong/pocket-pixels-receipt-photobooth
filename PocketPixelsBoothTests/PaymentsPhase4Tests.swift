import Foundation
import Testing
@testable import PocketPixelsBooth

// MARK: - Fixtures

private func tempDirectory(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
}

/// Injectable writer that can simulate disk-full at any step.
private final class FlakyWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    var fail: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func write(_ data: Data, _ url: URL) throws {
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
        try DurableFileWriter.write(data, to: url)
    }
}

nonisolated private let fingerprint = String(repeating: "ab", count: 32)

@MainActor
private func beginCopy(_ outbox: PrintOutcomeOutbox, _ copy: Int, of count: Int = 3, batch: String = "batch-1", entitlement: String? = "ent-1", fp: String = fingerprint) throws {
    try outbox.beginCopy(batchID: batch, sessionID: "PP-1", entitlementID: entitlement, receiptFingerprint: fp, copyIndex: copy, copyCount: count, transport: "bluetooth")
}

@Test @MainActor func selectedTransportIsDurableBeforeOutcome() throws {
    let directory = tempDirectory("selected-transport")
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = try PrintOutcomeOutbox(directory: directory)
    try outbox.beginCopy(
        batchID: "batch-transport", sessionID: "session", entitlementID: "entitlement",
        receiptFingerprint: fingerprint, copyIndex: 1, copyCount: 1,
        transport: PrinterTransportSelection.none.rawValue
    )

    try outbox.selectTransportBeforeBytes(batchID: "batch-transport", copyIndex: 1, transport: .bluetooth)

    #expect(outbox.entries.first?.transport == PrinterTransportSelection.bluetooth.rawValue)
    #expect(outbox.entries.first?.localState == .inFlight)
}

/// URLProtocol stub separate from the Phase 3 one so parallel suites never share handlers.
final class Phase4StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var captured: [(path: String, body: [String: Any])] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        } else if let httpBody = request.httpBody {
            body = httpBody
        }
        Self.captured.append((request.url?.path ?? "", (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]))
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private struct Phase4Credential: PaymentCredentialProviding {
    func load() throws -> String? { String(repeating: "p", count: 40) }
}

private func stubClient() -> PaymentsAPIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [Phase4StubProtocol.self]
    Phase4StubProtocol.captured = []
    return PaymentsAPIClient(configuration: PaymentsConfiguration(baseURL: URL(string: "https://payments.example.test")!, environment: "test"),
                             credentialStore: Phase4Credential(), session: URLSession(configuration: configuration))
}

// MARK: - Print outbox: crash points and replay

@Suite("Durable print outbox", .serialized)
@MainActor
struct PrintOutboxTests {
    @Test func crashBeforeJournalWriteSendsNothing() throws {
        let root = tempDirectory("outbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = FlakyWriter()
        writer.fail = true
        let outbox = try PrintOutcomeOutbox(directory: root, writer: writer.write)
        #expect(throws: PrintOutcomeOutbox.OutboxError.self) { try beginCopy(outbox, 1) }
        #expect(outbox.entries.isEmpty, "a failed intent write leaves no record and the spooler sends no bytes")
        writer.fail = false
        #expect(outbox.nextCopyToPrint(batchID: "batch-1", copyCount: 3) == 1)
    }

    @Test(arguments: ["after journal write, before send", "while sending", "after hardware response, before local update"])
    func crashWithCopyInFlightBecomesUncertainAndIsNeverResent(point: String) throws {
        let root = tempDirectory("outbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try PrintOutcomeOutbox(directory: root)
        try beginCopy(first, 1)
        // The process dies here: no finishCopy for copy 1.
        let relaunched = try PrintOutcomeOutbox(directory: root)
        #expect(relaunched.recoverAfterLaunch() == 1)
        let entry = try #require(relaunched.entries.first)
        #expect(entry.localState == .uncertain, "\(point): ambiguous, not confirmed")
        #expect(entry.reportState == .pending, "\(point): the uncertain outcome will be reported, not lost")
        #expect(relaunched.nextCopyToPrint(batchID: "batch-1", copyCount: 3) == 2, "copy 1 is never sent again")
        #expect(throws: PrintOutcomeOutbox.OutboxError.copyAlreadyAttempted(1)) { try beginCopy(relaunched, 1) }
    }

    @Test func crashAfterCopyNMinusOneContinuesWithCopyN() throws {
        let root = tempDirectory("outbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try PrintOutcomeOutbox(directory: root)
        for copy in 1...2 {
            try beginCopy(outbox, copy)
            #expect(outbox.finishCopy(batchID: "batch-1", copyIndex: copy, state: .delivered))
        }
        let relaunched = try PrintOutcomeOutbox(directory: root)
        #expect(relaunched.recoverAfterLaunch() == 0)
        #expect(relaunched.nextCopyToPrint(batchID: "batch-1", copyCount: 3) == 3)
        try beginCopy(relaunched, 3)
        relaunched.finishCopy(batchID: "batch-1", copyIndex: 3, state: .delivered)
        #expect(relaunched.nextCopyToPrint(batchID: "batch-1", copyCount: 3) == nil, "no paid copy beyond the purchased quantity")
    }

    @Test func diskFullWhenRecordingOutcomeIsResolvedConservatively() throws {
        let root = tempDirectory("outbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = FlakyWriter()
        let outbox = try PrintOutcomeOutbox(directory: root, writer: writer.write)
        try beginCopy(outbox, 1)
        writer.fail = true
        #expect(!outbox.finishCopy(batchID: "batch-1", copyIndex: 1, state: .delivered))
        writer.fail = false
        let relaunched = try PrintOutcomeOutbox(directory: root)
        relaunched.recoverAfterLaunch()
        #expect(relaunched.entries.first?.localState == .uncertain, "evidence weakens to uncertain; it is never upgraded or dropped")
    }

    @Test func notStartedCopyIsRetriedWithoutAServerReport() throws {
        let root = tempDirectory("outbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try PrintOutcomeOutbox(directory: root)
        try beginCopy(outbox, 1)
        outbox.finishCopy(batchID: "batch-1", copyIndex: 1, state: .notStarted)
        #expect(outbox.entries.first?.reportState == .notApplicable)
        #expect(outbox.nextCopyToPrint(batchID: "batch-1", copyCount: 3) == 1, "conclusively unprinted copy may be retried")
        try beginCopy(outbox, 1)
        #expect(outbox.entries.count == 2, "both attempts stay as evidence")
        #expect(Set(outbox.entries.map(\.idempotencyKey)).count == 1, "one server record per copy")
    }

    @Test func changedReceiptIsRefusedForTheSamePaidBatch() throws {
        let root = tempDirectory("outbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try PrintOutcomeOutbox(directory: root)
        try beginCopy(outbox, 1)
        outbox.finishCopy(batchID: "batch-1", copyIndex: 1, state: .delivered)
        #expect(throws: PrintOutcomeOutbox.OutboxError.receiptChanged) { try beginCopy(outbox, 2, fp: String(repeating: "cd", count: 32)) }
    }

    @Test func corruptJournalIsQuarantinedAndBlocksPaidCopies() throws {
        let root = tempDirectory("outbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("PaymentState", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{\"entries\":[{\"id\":".utf8).write(to: folder.appendingPathComponent("print-outbox.json"))
        let outbox = try PrintOutcomeOutbox(directory: root)
        #expect(outbox.integrityFault != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix("print-outbox.corrupt-") })
        #expect(throws: PrintOutcomeOutbox.OutboxError.self) { try beginCopy(outbox, 1) }
    }

    @Test func prepaidCopiesAreJournaledButNeverReported() throws {
        let root = tempDirectory("outbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try PrintOutcomeOutbox(directory: root)
        try beginCopy(outbox, 1, entitlement: nil)
        outbox.finishCopy(batchID: "batch-1", copyIndex: 1, state: .delivered)
        #expect(outbox.entries.first?.reportState == .notApplicable)
        #expect(outbox.dueReports().isEmpty)
    }

    @Test func replayUsesUnchangedKeysAndTreatsServerReplayAsSuccess() async throws {
        let root = tempDirectory("outbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = FlakyWriter()
        let outbox = try PrintOutcomeOutbox(directory: root, writer: writer.write)
        try beginCopy(outbox, 1)
        outbox.finishCopy(batchID: "batch-1", copyIndex: 1, state: .delivered)
        try beginCopy(outbox, 2)
        outbox.finishCopy(batchID: "batch-1", copyIndex: 2, state: .uncertain)
        outbox.enqueueCompletion(batchID: "batch-1", sessionID: "PP-1", entitlementID: "ent-1")

        let client = stubClient()
        Phase4StubProtocol.handler = { request in
            if request.url?.path.hasSuffix("/complete") == true { return (200, Data(#"{"entitlement":{}}"#.utf8)) }
            return (200, Data(#"{"accepted":true,"replay":false}"#.utf8))
        }
        // Server processed every request but the local ACK could not be written (crash/disk full).
        writer.fail = true
        let firstPass = await outbox.sync(using: client)
        #expect(firstPass.sent == 2, "completion waits until copy reports have left the device")
        let firstKeys = Phase4StubProtocol.captured.compactMap { $0.body["idempotencyKey"] as? String }
        writer.fail = false
        let reopened = try PrintOutcomeOutbox(directory: root)
        #expect(reopened.dueReports().count == 2, "unacknowledged reports are still pending after relaunch")
        Phase4StubProtocol.captured = []
        Phase4StubProtocol.handler = { request in
            if request.url?.path.hasSuffix("/complete") == true { return (200, Data(#"{"entitlement":{}}"#.utf8)) }
            return (200, Data(#"{"accepted":true,"replay":true}"#.utf8))
        }
        _ = await reopened.sync(using: client)
        let replayKeys = Phase4StubProtocol.captured.compactMap { $0.body["idempotencyKey"] as? String }
        #expect(replayKeys == firstKeys, "replays carry the original idempotency keys")
        let outcomes = Phase4StubProtocol.captured.compactMap { $0.body["outcome"] as? String }
        #expect(outcomes == ["DELIVERED", "UNCERTAIN"], "never upgraded to CONFIRMED")
        #expect(Phase4StubProtocol.captured.allSatisfy { ($0.body["receiptFingerprint"] as? String).map { $0.count == 64 } ?? true })
        _ = await reopened.sync(using: client)
        #expect(Phase4StubProtocol.captured.contains { $0.path.hasSuffix("/entitlements/ent-1/complete") })
        #expect(reopened.summary.pending == 0)
    }

    @Test func serverConflictIsQuarantinedAndUnavailabilityBacksOff() async throws {
        let root = tempDirectory("outbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try PrintOutcomeOutbox(directory: root)
        try beginCopy(outbox, 1)
        outbox.finishCopy(batchID: "batch-1", copyIndex: 1, state: .delivered)
        try beginCopy(outbox, 2)
        outbox.finishCopy(batchID: "batch-1", copyIndex: 2, state: .delivered)
        let client = stubClient()
        var calls = 0
        Phase4StubProtocol.handler = { _ in
            calls += 1
            return calls == 1
                ? (409, Data(#"{"error":"print_batch_conflict","message":"conflict"}"#.utf8))
                : (503, Data(#"{"error":"request_failed","message":"down"}"#.utf8))
        }
        let result = await outbox.sync(using: client)
        #expect(result.conflicts == 1)
        #expect(result.retries == 1)
        #expect(outbox.conflicts.first?.lastError == "print_batch_conflict")
        #expect(outbox.dueReports().isEmpty, "the 503 copy waits for its backoff; the conflict is never retried blindly")
        let retry = try #require(outbox.entries.first { $0.copyIndex == 2 })
        #expect(retry.attempts == 1 && retry.nextAttemptAt != nil)
        #expect(outbox.dueReports(now: Date().addingTimeInterval(60)).count == 1)
    }
}

// MARK: - Checkout checkpoints and recovery classification

@Suite("Checkout checkpoint recovery")
@MainActor
struct CheckoutCheckpointTests {
    private func checkpoint(_ id: String = "PP-20261011-120000", method: String? = "QRPH", phase: CheckoutPhase = .orderRequested, orderID: String? = nil) -> CheckoutCheckpoint {
        CheckoutCheckpoint(id: id, environment: "test", deviceID: "dev-booth", accountID: "acct-a", eventID: "ev", policyRevisionID: "r1",
                           unitPriceCentavos: 5_000, copies: 3, format: "solo", method: method, orderID: orderID, entitlementID: nil,
                           offlineRecordID: nil, phase: phase, lastServerState: nil, createdAt: Date(), updatedAt: Date(), resolution: nil, resolvedAt: nil)
    }

    @Test func checkpointMustBeDurableBeforeAnyServerMutation() throws {
        let root = tempDirectory("checkpoints")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = FlakyWriter()
        writer.fail = true
        let store = try CheckoutCheckpointStore(directory: root, writer: writer.write)
        #expect(throws: CheckoutCheckpointStore.StoreError.self) { try store.begin(checkpoint()) }
        #expect(store.all.isEmpty)
    }

    @Test func phasesNeverMoveBackwardsAndSurviveRelaunch() throws {
        let root = tempDirectory("checkpoints")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CheckoutCheckpointStore(directory: root)
        try store.begin(checkpoint())
        store.update(id: "PP-20261011-120000") { $0.phase = .claimed; $0.orderID = "o1" }
        store.update(id: "PP-20261011-120000") { $0.phase = .paymentRequested }
        let reopened = try CheckoutCheckpointStore(directory: root)
        let saved = try #require(reopened.checkpoint(id: "PP-20261011-120000"))
        #expect(saved.phase == .claimed)
        #expect(saved.orderID == "o1")
        // A superseding checkout in the same session keeps the history and only changes method.
        try reopened.begin(checkpoint(method: "CASH_DECLARED"))
        #expect(reopened.checkpoint(id: "PP-20261011-120000")?.orderID == "o1")
        #expect(reopened.checkpoint(id: "PP-20261011-120000")?.method == "CASH_DECLARED")
        reopened.resolve(id: "PP-20261011-120000", reason: "completed")
        #expect(reopened.unresolved.isEmpty)
    }

    @Test func corruptCheckpointFileFailsClosedAndIsKept() throws {
        let root = tempDirectory("checkpoints")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("PaymentState", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("checkout-checkpoints.json"))
        let store = try CheckoutCheckpointStore(directory: root)
        #expect(store.integrityFault != nil)
        #expect(throws: CheckoutCheckpointStore.StoreError.self) { try store.begin(checkpoint()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix("checkout-checkpoints.corrupt-") })
        try store.acknowledgeIntegrityFault()
        try store.begin(checkpoint())
    }

    @Test func checkpointCarriesNoSecretsOrGuestData() throws {
        let data = try PaymentsJSON.encoder().encode(checkpoint())
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["token", "secret", "Bearer", "qrImage", "data:image", "photo", "galleryToken", "name"] {
            #expect(!text.localizedCaseInsensitiveContains(forbidden), "checkpoint must not contain \(forbidden)")
        }
    }

    // Server views in the Worker's exact JSON shape (snake_case print rows as the Worker emits them).
    private func server(_ ordersJSON: String, open: String? = "o1", session: String = "PP-20261011-120000") throws -> CheckoutRecoveryResponse {
        let json = #"{"checkoutSessionId":"\#(session)","orders":[\#(ordersJSON)],"openOrderId":\#(open.map { "\"\($0)\"" } ?? "null"),"serverTime":"2026-10-11T04:00:00.000Z"}"#
        return try PaymentsAPIClient.makeDecoder().decode(CheckoutRecoveryResponse.self, from: Data(json.utf8))
    }

    private func orderJSON(id: String = "o1", state: String, method: String? = "QRPH", attemptState: String?, entitlementState: String? = nil,
                           source: String = "VERIFIED_QRPH", sessionID: String? = nil, prints: String = "[]") -> String {
        let attempt = attemptState.map { #"{"id":"a-\#(id)","method":"\#(method ?? "QRPH")","state":"\#($0)","qrImageDataURL":null,"testURL":null,"expiresAt":null}"# } ?? "null"
        let entitlement = entitlementState.map {
            #"{"id":"e-\#(id)","orderId":"\#(id)","eventId":"ev","policyRevisionId":"r1","sessionId":\#(sessionID.map { "\"\($0)\"" } ?? "null"),"selectedFormat":"solo","purchasedCopies":3,"unitPriceCentavos":5000,"totalCentavos":15000,"authorizationSource":"\#(source)","authorizedAt":"2026-10-11T03:00:00.000Z","state":"\#($0)","receiptFingerprint":null}"#
        } ?? "null"
        return #"{"order":{"id":"\#(id)","eventId":"ev","policyRevisionId":"r1","format":"solo","copies":3,"unitPriceCentavos":5000,"totalCentavos":15000,"currency":"PHP","state":"\#(state)","paymentMethod":\#(method.map { "\"\($0)\"" } ?? "null"),"expiresAt":null},"attempt":\#(attempt),"entitlement":\#(entitlement),"newCheckout":{"allowed":false,"reason":"x"},"printOutcomes":\#(prints)}"#
    }

    @Test func classifiesEveryServerState() throws {
        let cp = checkpoint()
        let session = cp.id
        func classify(_ view: CheckoutRecoveryResponse?, printed: Bool = false, checkpoint: CheckoutCheckpoint? = nil) -> CheckoutRecoveryClassification {
            CheckoutRecoveryClassifier.classify(checkpoint: checkpoint ?? cp, server: view, localPrintStarted: printed, offlineRecordExists: false)
        }
        #expect(classify(try server("", open: nil)) == .nothingCharged)
        #expect(classify(try server(orderJSON(state: "AWAITING_PAYMENT", method: nil, attemptState: nil))) == .nothingCharged)
        #expect(classify(try server(orderJSON(state: "PAYMENT_PENDING", attemptState: "UNKNOWN_RECONCILIATION"))) == .paymentPending)
        #expect(classify(try server(orderJSON(state: "PAYMENT_PENDING", attemptState: "AWAITING_PAYMENT"))) == .paymentPending)
        #expect(classify(try server(orderJSON(state: "PAYMENT_PENDING", attemptState: "QR_EXPIRED_CONFIRMED"))) == .unpaidClosed)
        #expect(classify(try server(orderJSON(state: "AUTHORIZED", attemptState: "PAID_VERIFIED", entitlementState: "AUTHORIZED"))) == .paidUnclaimed(verified: true))
        #expect(classify(try server(orderJSON(state: "AUTHORIZED", method: "CASH_DECLARED", attemptState: "SELF_REPORTED", entitlementState: "AUTHORIZED", source: "UNVERIFIED_CASH_DECLARED"))) == .paidUnclaimed(verified: false), "cash stays unverified")
        #expect(classify(try server(orderJSON(state: "IN_SESSION", attemptState: "PAID_VERIFIED", entitlementState: "IN_SESSION", sessionID: session))) == .claimedNotPrinted(verified: true))
        #expect(classify(try server(orderJSON(state: "IN_SESSION", attemptState: "PAID_VERIFIED", entitlementState: "IN_SESSION", sessionID: session)), printed: true) == .printStarted)
        #expect(classify(try server(orderJSON(state: "IN_SESSION", attemptState: "PAID_VERIFIED", entitlementState: "IN_SESSION", sessionID: session, prints: #"[{"copy_index":1,"outcome":"DELIVERED"}]"#))) == .printStarted)
        #expect(classify(try server(orderJSON(state: "COMPLETE", attemptState: "PAID_VERIFIED", entitlementState: "CONSUMED", sessionID: session))) == .completed)
        #expect(classify(try server(orderJSON(state: "LATE_PAID_REVIEW", attemptState: "PAID_VERIFIED", entitlementState: "REVIEW_REQUIRED"))) == .needsReview("late payment on a replaced checkout"))
        #expect(classify(try server(orderJSON(state: "IN_SESSION", attemptState: "PAID_VERIFIED", entitlementState: "IN_SESSION", sessionID: "PP-another"))) == .inconsistent("entitlement bound to another session"))
        #expect(classify(try server(orderJSON(state: "AUTHORIZED", attemptState: "PAID_VERIFIED", entitlementState: "AUTHORIZED"), session: "PP-other")) == .inconsistent("session mismatch"))
        #expect(classify(try server(orderJSON(state: "AUTHORIZED", attemptState: "PAID_VERIFIED", entitlementState: "AUTHORIZED")), checkpoint: checkpoint(orderID: "o-missing")) == .inconsistent("recorded order not found for this iPad"))
        #expect(classify(nil) == .inconsistent("server view unavailable"))
    }

    @Test func offlineCashRecoveryDependsOnTheLocalLedgerRecord() {
        let offline = checkpoint(method: "OFFLINE_CASH", phase: .entitled)
        #expect(CheckoutRecoveryClassifier.classify(checkpoint: offline, server: nil, localPrintStarted: false, offlineRecordExists: true) == .offlineCashDeclared(printStarted: false))
        #expect(CheckoutRecoveryClassifier.classify(checkpoint: offline, server: nil, localPrintStarted: true, offlineRecordExists: true) == .offlineCashDeclared(printStarted: true))
        #expect(CheckoutRecoveryClassifier.classify(checkpoint: offline, server: nil, localPrintStarted: false, offlineRecordExists: false) == .inconsistent("offline cash record missing"))
        #expect(!CheckoutRecoveryClassification.offlineCashDeclared(printStarted: true).isResumable)
    }

    @Test func autoCompletionOnlyWhenEveryPaidCopyWasDelivered() throws {
        let root = tempDirectory("outbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try PrintOutcomeOutbox(directory: root)
        for copy in 1...3 {
            try beginCopy(outbox, copy)
            outbox.finishCopy(batchID: "batch-1", copyIndex: copy, state: copy == 3 ? .uncertain : .delivered)
        }
        let copies = outbox.copiesThatMayHavePrinted(sessionID: "PP-1")
        #expect(!PaymentRecoveryCoordinator.allPaidCopiesDelivered(copies, paidCopies: 3), "an uncertain copy needs the operator")
        #expect(!PaymentRecoveryCoordinator.allPaidCopiesDelivered(Array(copies.prefix(2)), paidCopies: 3), "a missing copy is not complete")
        #expect(PaymentRecoveryCoordinator.allPaidCopiesDelivered(Array(copies.prefix(2)), paidCopies: 2))
        #expect(!PaymentRecoveryCoordinator.allPaidCopiesDelivered([], paidCopies: 1))
    }

    @Test func resumeIsOperatorArmedSingleUseAndExpires() {
        let coordinator = PaymentRecoveryCoordinator()
        let resumable = CheckoutRecoveryItem(checkpoint: checkpoint(), classification: .paidUnclaimed(verified: true))
        let printed = CheckoutRecoveryItem(checkpoint: checkpoint(), classification: .printStarted)
        #expect(!coordinator.armResume(printed), "paper may exist: never resumable")
        #expect(coordinator.takeArmedResume() == nil, "nothing armed: a walk-up guest gets a normal new session")
        let now = Date()
        #expect(coordinator.armResume(resumable, now: now))
        #expect(coordinator.takeArmedResume(now: now.addingTimeInterval(10))?.id == resumable.id)
        #expect(coordinator.takeArmedResume(now: now.addingTimeInterval(11)) == nil, "single use")
        #expect(coordinator.armResume(resumable, now: now))
        #expect(coordinator.takeArmedResume(now: now.addingTimeInterval(PaymentRecoveryCoordinator.armedResumeLifetime + 1)) == nil, "expired")
    }
}

// MARK: - Recovery API

@Suite("Recovery API client", .serialized)
struct RecoveryAPIClientTests {
    @Test func recoveryLookupAndAuditedClaim() async throws {
        let client = stubClient()
        Phase4StubProtocol.handler = { request in
            if request.url?.path.hasSuffix("/claim") == true {
                return (200, Data(#"{"entitlement":{"id":"e1","orderId":"o1","eventId":"ev","policyRevisionId":"r1","sessionId":"PP-1","selectedFormat":"solo","purchasedCopies":2,"unitPriceCentavos":5000,"totalCentavos":10000,"authorizationSource":"VERIFIED_QRPH","authorizedAt":"2026-10-11T03:00:00.000Z","state":"IN_SESSION","receiptFingerprint":null},"replay":false}"#.utf8))
            }
            return (200, Data(#"{"checkoutSessionId":"PP-1","orders":[],"openOrderId":null,"serverTime":"2026-10-11T04:00:00.000Z"}"#.utf8))
        }
        let view = try await client.checkoutRecovery(checkoutSessionID: "PP-1")
        #expect(view.orders.isEmpty)
        #expect(Phase4StubProtocol.captured.first?.path == "/v1/checkouts/PP-1")
        let claimed = try await client.claim(entitlementID: "e1", sessionID: "PP-1", idempotencyKey: "claim-e1", recovery: true)
        #expect(claimed.sessionID == "PP-1")
        #expect(Phase4StubProtocol.captured.last?.body["recovery"] as? Bool == true)
        _ = try await client.claim(entitlementID: "e1", sessionID: "PP-1", idempotencyKey: "claim-e1")
        #expect(Phase4StubProtocol.captured.last?.body["recovery"] == nil, "ordinary claims carry no recovery flag")
    }
}

@Suite("Provider limits")
struct ProviderLimitTests {
    @Test func qrPhRequiresOnePesoButCashOnlyMayBeLower() {
        var draft = ServerPolicyDraft()
        draft.priceText = "0.99"
        #expect(draft.validationMessage() == "QR Ph needs a price of at least ₱1.00 per copy.")
        draft.priceText = "1.00"
        #expect(draft.validationMessage() == nil)
        draft.priceText = "0.50"
        draft.qrPhEnabled = false
        draft.cashEnabled = true
        #expect(draft.validationMessage() == nil, "cash-only events have no provider minimum")
    }
}

// MARK: - Worker timestamp parsing (iOS 18+ independent)

@Suite("Worker timestamp parsing")
struct WorkerTimestampTests {
    @Test(arguments: [
        ("2026-10-11T04:00:00.000Z", 0.0), ("2026-10-11T04:00:00Z", 0.0), ("2026-10-11T04:00:00.250Z", 0.25),
        ("2026-10-11T12:00:00+08:00", 0.0), ("2026-10-11T12:00:00.500+08:00", 0.5)
    ])
    func parsesWorkerAndOffsetForms(text: String, fraction: Double) throws {
        let date = try #require(PaymentsJSON.parseDate(text))
        let base = try #require(PaymentsJSON.parseDate("2026-10-11T04:00:00Z"))
        #expect(abs(date.timeIntervalSince(base) - fraction) < 0.001)
    }

    @Test(arguments: ["", "2026-10-11", "yesterday", "2026-13-40T99:00:00Z", "1760155200"])
    func rejectsNonTimestamps(text: String) {
        #expect(PaymentsJSON.parseDate(text) == nil)
    }

    @Test func decodeErrorIsExplicit() {
        struct Box: Decodable { let at: Date }
        #expect(throws: DecodingError.self) { try PaymentsJSON.decoder().decode(Box.self, from: Data(#"{"at":"not-a-date"}"#.utf8)) }
    }

    @Test func roundTripsThroughTheWorkerFormat() throws {
        let original = try #require(PaymentsJSON.parseDate("2026-10-11T04:00:00.123Z"))
        #expect(PaymentsJSON.string(from: original) == "2026-10-11T04:00:00.123Z")
    }
}
