import CryptoKit
import Foundation
import Testing
@testable import PocketPixelsBooth

/// Fixed Ed25519 vector produced by Node's WebCrypto (the same API the Worker uses). Only the
/// public key, the exact signed bytes and the signature are embedded; the private key was discarded.
enum OfflinePolicyFixtures {
    static let publicKeyBase64 = "mKwI2SiRbOXuIuXSKuaQCRw0YAvpBEi4FYUjiKEKmO0="
    static let payloadBase64 = "eyJ2IjoxLCJraWQiOiJ2ZWN0b3ItazEiLCJlbnYiOiJ0ZXN0Iiwic25hcHNob3RJZCI6InNuYXAtdmVjdG9yLTEiLCJhY2NvdW50SWQiOiJhY2N0LWEiLCJkZXZpY2VJZCI6ImRldi1ib290aCIsImV2ZW50SWQiOiJldmVudC12ZWN0b3IiLCJldmVudE5hbWUiOiJWZWN0b3IgRXZlbnQiLCJldmVudExpZmVjeWNsZSI6IkFDVElWRSIsInBvbGljeVJldmlzaW9uSWQiOiJyZXYtdmVjdG9yIiwicmV2aXNpb24iOjMsImNvbW1lcmNpYWxNb2RlIjoiUEFZX1BFUl9QUklOVCIsImN1cnJlbmN5IjoiUEhQIiwidW5pdFByaWNlQ2VudGF2b3MiOjUwMDAsIm1heENvcGllcyI6NSwiZGVmYXVsdENvcGllcyI6MSwicGF5bWVudE1ldGhvZHMiOlsiQ0FTSF9ERUNMQVJFRCJdLCJzdXBwb3J0ZWRGb3JtYXRzIjpbInNvbG8iLCJzdHJpcCJdLCJtYXhEZWNsYXJhdGlvbnMiOjQwLCJpc3N1ZWRBdCI6IjIwMjYtMTAtMTBUMDA6MDA6MDAuMDAwWiIsIm5vdEJlZm9yZSI6IjIwMjYtMTAtMTBUMDA6MDA6MDAuMDAwWiIsImV4cGlyZXNBdCI6IjIwMjYtMTAtMTBUMDQ6MDA6MDAuMDAwWiJ9"
    static let signatureBase64 = "WyTeFI0S8t9QBqsdoYKwNZWlVFTD2bQMlhKgA7ussHAMP+AZGq0mjadWKVNbS8qUJI8w1ejcyQptbwj7bstfBg=="
    static let validNow = date("2026-10-10T01:00:00Z")

    static var grant: SignedOfflinePolicy {
        SignedOfflinePolicy(snapshotId: "snap-vector-1", keyId: "vector-k1", payload: payloadBase64, signature: signatureBase64)
    }

    static func verifier(environment: String = "test") -> OfflinePolicyVerifier {
        OfflinePolicyVerifier(trustedKeys: OfflinePolicyVerifier.parseKeys("vector-k1:\(publicKeyBase64)"), environment: environment)
    }

    static func payload() -> OfflinePolicyPayload {
        // swiftlint:disable:next force_try
        try! verifier().verify(grant, deviceID: "dev-booth", accountID: "acct-a", now: validNow, trustedClockFloor: nil)
    }

    static func date(_ value: String) -> Date {
        PaymentsJSON.parseDate(value) ?? .distantPast
    }
}

@Suite("Peso entry and centavo conversion")
struct PesoAmountTests {
    @Test(arguments: [
        ("50", 5_000), ("50.5", 5_050), ("50.05", 5_005), ("0.01", 1), ("₱1,500.00", 150_000), (" PHP 75 ", 7_500),
        ("100000", 10_000_000), ("100,000.00", 10_000_000), ("0", 0)
    ])
    func acceptsExactPesoAmounts(text: String, centavos: Int) {
        #expect(PesoAmount.centavos(fromPesoText: text) == centavos)
    }

    @Test(arguments: ["", "abc", "-5", "1.234", "1,50", "12,3456", "1e3", ".5", "5.", "100000.01", "1000000", "5..0", "5,00.00", "٣"])
    func rejectsAmbiguousOrOutOfRangeText(text: String) {
        #expect(PesoAmount.centavos(fromPesoText: text) == nil)
    }

    @Test func editingTextRoundTrips() {
        for centavos in [1, 5, 50, 5_005, 150_000, 10_000_000] {
            #expect(PesoAmount.centavos(fromPesoText: PesoAmount.editingText(centavos: centavos)) == centavos)
        }
        #expect(PesoAmount.editingText(centavos: 5_005) == "50.05")
    }

    @Test func serverDraftSendsCentavosAndPrepaidCarriesNoPrice() throws {
        var draft = ServerPolicyDraft()
        draft.priceText = "49.99"
        draft.supportedFormats = ["solo", "strip"]
        let body = try #require(draft.requestBody())
        #expect(body.unitPriceCentavos == 4_999)
        #expect(body.supportedFormats == ["solo", "strip"])
        #expect(body.offlineValidUntil == nil)

        draft.priceText = "49.999"
        #expect(draft.requestBody() == nil)
        #expect(draft.validationMessage() != nil)

        draft.priceText = "50"
        draft.qrPhEnabled = false
        draft.cashEnabled = false
        #expect(draft.validationMessage() == "Enable QR Ph, Cash, or both.")

        var prepaid = ServerPolicyDraft()
        prepaid.commercialMode = .privatePrepaid
        prepaid.priceText = "999"
        let prepaidBody = try #require(prepaid.requestBody())
        #expect(prepaidBody.unitPriceCentavos == 0)
        #expect(!prepaidBody.cashEnabled && !prepaidBody.qrphEnabled)
    }

    @Test func offlineCashDraftRequiresCashAndFutureLimit() {
        var draft = ServerPolicyDraft()
        draft.priceText = "50"
        draft.cashEnabled = true
        draft.offlineCashEnabled = true
        draft.offlineValidUntil = Date().addingTimeInterval(-60)
        #expect(draft.validationMessage() == "The offline cash limit must be in the future.")
        draft.offlineValidUntil = Date().addingTimeInterval(3_600)
        draft.cashEnabled = false
        #expect(draft.validationMessage() == "Offline cash requires Cash to be enabled.")
    }
}

@Suite("Payments JSON dates")
struct PaymentsJSONTests {
    @Test func decodesWorkerTimestampsWithAndWithoutMilliseconds() throws {
        struct Box: Decodable { let a: Date; let b: Date }
        let json = Data(#"{"a":"2026-10-10T08:00:00.123Z","b":"2026-10-10T08:00:00Z"}"#.utf8)
        let box = try PaymentsJSON.decoder().decode(Box.self, from: json)
        #expect(abs(box.a.timeIntervalSince(box.b) - 0.123) < 0.001)
    }
}

@Suite("Signed offline policy verification")
struct OfflinePolicyVerificationTests {
    @Test func verifiesWorkerSignedVector() throws {
        let payload = try OfflinePolicyFixtures.verifier().verify(OfflinePolicyFixtures.grant, deviceID: "dev-booth", accountID: "acct-a", now: OfflinePolicyFixtures.validNow, trustedClockFloor: nil)
        #expect(payload.unitPriceCentavos == 5_000)
        #expect(payload.maxDeclarations == 40)
        let run = payload.eventRun
        #expect(run.activePolicy.cashEnabled)
        #expect(!run.activePolicy.qrPhEnabled, "offline policy never enables QR Ph")
    }

    @Test func rejectsTamperedPayloadOrSignature() {
        let verifier = OfflinePolicyFixtures.verifier()
        var payloadBytes = Data(base64Encoded: OfflinePolicyFixtures.payloadBase64)!
        let text = String(data: payloadBytes, encoding: .utf8)!.replacingOccurrences(of: "\"unitPriceCentavos\":5000", with: "\"unitPriceCentavos\":1")
        payloadBytes = Data(text.utf8)
        let tampered = SignedOfflinePolicy(snapshotId: "snap-vector-1", keyId: "vector-k1", payload: payloadBytes.base64EncodedString(), signature: OfflinePolicyFixtures.signatureBase64)
        #expect(throws: OfflinePolicyError.badSignature) { try verifier.verify(tampered, deviceID: "dev-booth", accountID: "acct-a", now: OfflinePolicyFixtures.validNow, trustedClockFloor: nil) }

        var signature = Data(base64Encoded: OfflinePolicyFixtures.signatureBase64)!
        signature[0] ^= 0x01
        let badSignature = SignedOfflinePolicy(snapshotId: "snap-vector-1", keyId: "vector-k1", payload: OfflinePolicyFixtures.payloadBase64, signature: signature.base64EncodedString())
        #expect(throws: OfflinePolicyError.badSignature) { try verifier.verify(badSignature, deviceID: "dev-booth", accountID: "acct-a", now: OfflinePolicyFixtures.validNow, trustedClockFloor: nil) }

        let garbage = SignedOfflinePolicy(snapshotId: "x", keyId: "vector-k1", payload: "%%%", signature: "%%%")
        #expect(throws: OfflinePolicyError.malformed) { try verifier.verify(garbage, deviceID: "dev-booth", accountID: "acct-a", now: OfflinePolicyFixtures.validNow, trustedClockFloor: nil) }
    }

    @Test func failsClosedOnKeyBindingAndTime() {
        let grant = OfflinePolicyFixtures.grant
        let now = OfflinePolicyFixtures.validNow
        let none = OfflinePolicyVerifier(trustedKeys: [:], environment: "test")
        #expect(throws: OfflinePolicyError.noTrustedKeys) { try none.verify(grant, deviceID: "dev-booth", accountID: "acct-a", now: now, trustedClockFloor: nil) }
        let otherKey = OfflinePolicyVerifier(trustedKeys: ["other": Curve25519.Signing.PrivateKey().publicKey], environment: "test")
        #expect(throws: OfflinePolicyError.untrustedKey) { try otherKey.verify(grant, deviceID: "dev-booth", accountID: "acct-a", now: now, trustedClockFloor: nil) }
        #expect(throws: OfflinePolicyError.wrongEnvironment) { try OfflinePolicyFixtures.verifier(environment: "live").verify(grant, deviceID: "dev-booth", accountID: "acct-a", now: now, trustedClockFloor: nil) }
        let verifier = OfflinePolicyFixtures.verifier()
        #expect(throws: OfflinePolicyError.wrongDevice) { try verifier.verify(grant, deviceID: "dev-other", accountID: "acct-a", now: now, trustedClockFloor: nil) }
        #expect(throws: OfflinePolicyError.wrongAccount) { try verifier.verify(grant, deviceID: "dev-booth", accountID: "acct-b", now: now, trustedClockFloor: nil) }
        #expect(throws: OfflinePolicyError.expired) { try verifier.verify(grant, deviceID: "dev-booth", accountID: "acct-a", now: OfflinePolicyFixtures.date("2026-10-10T04:00:01Z"), trustedClockFloor: nil) }
        #expect(throws: OfflinePolicyError.notYetValid) { try verifier.verify(grant, deviceID: "dev-booth", accountID: "acct-a", now: OfflinePolicyFixtures.date("2026-10-09T23:00:00Z"), trustedClockFloor: nil) }
        #expect(throws: OfflinePolicyError.clockRolledBack) {
            try verifier.verify(grant, deviceID: "dev-booth", accountID: "acct-a", now: now, trustedClockFloor: OfflinePolicyFixtures.date("2026-10-10T03:00:00Z"))
        }
    }

    @Test func malformedTrustStoreEntriesAreIgnored() {
        #expect(OfflinePolicyVerifier.parseKeys("").isEmpty)
        #expect(OfflinePolicyVerifier.parseKeys("nokey, k:%%%, :abc").isEmpty)
        #expect(OfflinePolicyVerifier.parseKeys("a:\(OfflinePolicyFixtures.publicKeyBase64), bad").count == 1)
    }

    @Test func grantStoreKeepsMonotonicClockFloor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grant-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = PaymentDeviceIdentity(id: "dev-booth", accountId: "acct-a")
        try OfflineGrantStore.recordServerContact(device: device, environment: "test", serverTime: OfflinePolicyFixtures.date("2026-10-10T03:00:00Z"), grant: OfflinePolicyFixtures.grant, directory: root)
        try OfflineGrantStore.recordServerContact(device: device, environment: "test", serverTime: OfflinePolicyFixtures.date("2026-10-10T01:00:00Z"), grant: nil, directory: root)
        let record = try #require(OfflineGrantStore.load(directory: root))
        #expect(record.trustedClockFloor == OfflinePolicyFixtures.date("2026-10-10T03:00:00Z"))
        #expect(record.grant == nil, "a server answer without a grant clears the stored grant")
    }
}

/// Thread-safe switch for an injected failing writer.
private final class WriteSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    var fail: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
}

@Suite("Offline cash journal integrity")
struct OfflineCashJournalTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func failedWriteNeverLeavesAPhantomAuthorization() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let toggle = WriteSwitch()
        toggle.fail = true
        let ledger = try OfflineCashLedger(directory: root, writer: { data, url in
            if toggle.fail { throw CocoaError(.fileWriteOutOfSpace) }
            try DurableFileWriter.write(data, to: url)
        })
        let policy = OfflinePolicyFixtures.payload()
        await #expect(throws: OfflineCashLedger.LedgerError.self) {
            _ = try await ledger.declare(policy: policy, sessionID: "s1", format: .solo, copies: 1, at: OfflinePolicyFixtures.validNow)
        }
        #expect(await ledger.allRecords().isEmpty)
        toggle.fail = false
        let (record, _) = try await ledger.declare(policy: policy, sessionID: "s1", format: .solo, copies: 1, at: OfflinePolicyFixtures.validNow)
        #expect(record.localSequence == 1, "the failed attempt consumed no sequence number")
    }

    @Test func corruptJournalIsQuarantinedAndBlocksOfflineCash() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("PaymentState", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{\"nextSequence\": 3, \"records\": [ {\"id\": ".utf8).write(to: folder.appendingPathComponent("offline-cash-ledger.json"))

        let ledger = try OfflineCashLedger(directory: root)
        #expect(await ledger.integrityFault != nil)
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("corrupt") }
        #expect(quarantined.count == 1, "the unreadable journal is kept for audit")
        await #expect(throws: OfflineCashLedger.LedgerError.self) {
            _ = try await ledger.declare(policy: OfflinePolicyFixtures.payload(), sessionID: "s", format: .solo, copies: 1, at: OfflinePolicyFixtures.validNow)
        }

        try await ledger.acknowledgeIntegrityFaultAndStartNewJournal(now: OfflinePolicyFixtures.validNow)
        let (record, _) = try await ledger.declare(policy: OfflinePolicyFixtures.payload(), sessionID: "s", format: .solo, copies: 1, at: OfflinePolicyFixtures.validNow)
        #expect(record.localSequence > 1_000_000, "new journal sequence cannot collide with earlier accepted records")
    }

    @Test func inconsistentJournalIsTreatedAsCorrupt() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try OfflineCashLedger(directory: root)
        _ = try await first.declare(policy: OfflinePolicyFixtures.payload(), sessionID: "s1", format: .solo, copies: 1, at: OfflinePolicyFixtures.validNow)
        let file = root.appendingPathComponent("PaymentState/offline-cash-ledger.json")
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"nextSequence\":2", with: "\"nextSequence\":1")
        try Data(text.utf8).write(to: file)
        let reopened = try OfflineCashLedger(directory: root)
        #expect(await reopened.integrityFault != nil, "a sequence floor below existing records fails closed")
    }

    @Test func boundsDeclarationLimitAndClockRollback() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try OfflineCashLedger(directory: root)
        let policy = OfflinePolicyFixtures.payload()
        let now = OfflinePolicyFixtures.validNow
        await #expect(throws: OfflineCashLedger.LedgerError.invalidAmount) { _ = try await ledger.declare(policy: policy, sessionID: "a", format: .solo, copies: 6, at: now) }
        await #expect(throws: OfflineCashLedger.LedgerError.invalidAmount) { _ = try await ledger.declare(policy: policy, sessionID: "a", format: .passport, copies: 1, at: now) }
        _ = try await ledger.declare(policy: policy, sessionID: "a", format: .solo, copies: 1, at: now.addingTimeInterval(3_600))
        await #expect(throws: OfflineCashLedger.LedgerError.clockRolledBack) {
            _ = try await ledger.declare(policy: policy, sessionID: "b", format: .solo, copies: 1, at: now)
        }
        for index in 0..<(policy.maxDeclarations - 1) {
            _ = try await ledger.declare(policy: policy, sessionID: "bulk-\(index)", format: .strip, copies: 1, at: now.addingTimeInterval(3_600))
        }
        await #expect(throws: OfflineCashLedger.LedgerError.declarationLimitReached) {
            _ = try await ledger.declare(policy: policy, sessionID: "over", format: .solo, copies: 1, at: now.addingTimeInterval(3_600))
        }
    }

    @Test func syncConflictsStayVisibleAndRetriesStayPending() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try OfflineCashLedger(directory: root)
        let policy = OfflinePolicyFixtures.payload()
        let (a, _) = try await ledger.declare(policy: policy, sessionID: "a", format: .solo, copies: 1, at: OfflinePolicyFixtures.validNow)
        let (b, _) = try await ledger.declare(policy: policy, sessionID: "b", format: .solo, copies: 2, at: OfflinePolicyFixtures.validNow)
        try await ledger.applySync([
            OfflineSyncResult(localId: a.id, orderId: nil, result: "conflict", reason: "price_mismatch", reviewFlag: nil),
            OfflineSyncResult(localId: b.id, orderId: nil, result: "retry", reason: "server_error", reviewFlag: nil)
        ])
        #expect(await ledger.conflictRecords().map(\.failureMessage) == ["price_mismatch"])
        #expect(await ledger.pendingRecords().map(\.id) == [b.id])
        let reopened = try OfflineCashLedger(directory: root)
        #expect(await reopened.conflictRecords().count == 1, "conflicts survive restart")
    }
}

@Suite("Checkout exclusivity rules")
struct CheckoutGuardTests {
    private let online = PolicyAuthority.serverConfirmed(fetchedAt: Date())
    private let offline = PolicyAuthority.signedOffline(snapshotID: "s", expiresAt: Date().addingTimeInterval(60))

    @Test func newPaidEventDefaultsToQRPhOnly() {
        let draft = ServerPolicyDraft()

        #expect(draft.qrPhEnabled)
        #expect(!draft.cashEnabled)
        #expect(!draft.offlineCashEnabled)
    }

    @Test func unresolvedQRBlocksCashAndAnotherQR() {
        var guardState = CheckoutGuard()
        #expect(guardState.canChooseCash(authority: online, cashEnabled: true))
        #expect(guardState.canChooseQR(authority: online, qrEnabled: true, online: true))
        guardState.serverCheckoutStarted = true
        guardState.qrAttemptUnresolved = true
        #expect(!guardState.canChooseCash(authority: online, cashEnabled: true))
        #expect(!guardState.canChooseQR(authority: online, qrEnabled: true, online: true))
        #expect(!guardState.canStartNewCheckout())
    }

    @Test func offlineCashIsNeverAFallbackAfterServerCheckout() {
        var guardState = CheckoutGuard()
        #expect(guardState.canChooseCash(authority: offline, cashEnabled: true))
        #expect(!guardState.canChooseQR(authority: offline, qrEnabled: true, online: true), "QR never offline")
        guardState.serverCheckoutStarted = true
        #expect(!guardState.canChooseCash(authority: offline, cashEnabled: true))
    }

    @Test func localPrepaidNeverOffersQR() {
        #expect(!CheckoutGuard().canChooseQR(authority: .localPrepaid, qrEnabled: true, online: true))
        #expect(!CheckoutGuard().canChooseCash(authority: online, cashEnabled: false))
    }

    @Test func testSimulatorIsAvailableOnlyForAnAwaitingTESTAttempt() throws {
        let url = try #require(URL(string: "https://payments.example.test/simulate"))
        let awaiting = PaymentAttempt(
            id: "attempt",
            method: "QRPH",
            state: "AWAITING_PAYMENT",
            qrImageDataURL: nil,
            testURL: url,
            expiresAt: Date().addingTimeInterval(300)
        )
        #expect(awaiting.testSimulatorURL(environment: "test") == url)
        #expect(awaiting.testSimulatorURL(environment: "live") == nil)

        let paid = PaymentAttempt(
            id: "attempt",
            method: "QRPH",
            state: "PAID_VERIFIED",
            qrImageDataURL: nil,
            testURL: url,
            expiresAt: nil
        )
        #expect(paid.testSimulatorURL(environment: "test") == nil)
    }

    @Test func entitlementUnderReviewCannotStartCapture() {
        var entitlement = CheckoutEntitlement(id: "e", orderID: "o", eventID: "ev", policyRevisionID: "r", sessionID: nil, selectedFormatRawValue: "solo",
                                              purchasedCopies: 2, unitPriceCentavos: 5_000, totalCentavos: 10_000, authorizationSource: .verifiedQRPh, authorizedAt: Date(), receiptFingerprint: nil, serverState: "AUTHORIZED")
        #expect(entitlement.requiresServerClaim)
        #expect(entitlement.permitsCapture)
        entitlement.serverState = "REVIEW_REQUIRED"
        #expect(!entitlement.permitsCapture)
        entitlement.serverState = "CONSUMED"
        #expect(!entitlement.permitsCapture)
    }

    @Test func localStoreRefusesPaidPolicy() {
        var run = CommercialEventRun.legacy
        run.activePolicy.commercialMode = .payPerPrint
        run.activePolicy.unitPriceCentavos = 5_000
        #expect(throws: CommercialEventRunStoreError.self) { try CommercialEventRunStore.publish(run) }
    }

    @Test func serverPolicyMapsToGuestRun() throws {
        let json = Data(#"{"id":"ev","name":"Gala","venue":"","lifecycle":"ACTIVE","policyRevisionId":"r9","revision":9,"commercialMode":"PAY_PER_PRINT","unitPriceCentavos":7500,"maxCopies":4,"defaultCopies":2,"cashEnabled":true,"qrphEnabled":true,"prepaidGuestCopyChoice":false,"supportedFormats":["solo"],"features":{},"offlineValidUntil":null}"#.utf8)
        let policy = try PaymentsAPIClient.makeDecoder().decode(ServerEventPolicy.self, from: json)
        let run = policy.eventRun
        #expect(run.id == "ev")
        #expect(run.activePolicy.revisionID == "r9")
        #expect(run.activePolicy.totalCentavos(for: 3) == 22_500)
        #expect(run.activePolicy.totalCentavos(for: 5) == nil)
    }
}

/// URLProtocol stub so the real `PaymentsAPIClient` encodes requests and maps responses.
final class PaymentsStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var captured: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            request.httpBody = data
        }
        Self.captured.append(request)
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["content-type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private struct StaticCredential: PaymentCredentialProviding {
    func load() throws -> String? { String(repeating: "t", count: 40) }
}

@Suite("Payments API client", .serialized)
struct PaymentsAPIClientTests {
    private func client() -> PaymentsAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PaymentsStubProtocol.self]
        PaymentsStubProtocol.captured = []
        return PaymentsAPIClient(configuration: PaymentsConfiguration(baseURL: URL(string: "https://payments.example.test")!, environment: "test"),
                                 credentialStore: StaticCredential(), session: URLSession(configuration: configuration))
    }

    private static let policy = ServerEventPolicy(id: "ev", name: "Gala", venue: "", lifecycle: .active, policyRevisionId: "r1", revision: 1, commercialMode: .payPerPrint,
                                                  unitPriceCentavos: 5_000, maxCopies: 5, defaultCopies: 1, cashEnabled: true, qrphEnabled: true, prepaidGuestCopyChoice: false,
                                                  supportedFormats: ["solo"], offlineValidUntil: nil)

    @Test func createOrderSendsDisplayedPolicyAndDecodesMillisecondDates() async throws {
        let api = client()
        PaymentsStubProtocol.handler = { _ in
            (201, Data(#"{"order":{"id":"o1","eventId":"ev","policyRevisionId":"r1","format":"solo","copies":2,"unitPriceCentavos":5000,"totalCentavos":10000,"currency":"PHP","state":"AWAITING_PAYMENT","paymentMethod":null,"checkoutSessionId":"PP-1","expiresAt":"2026-10-10T08:30:00.000Z"}}"#.utf8))
        }
        let order = try await api.createOrder(event: Self.policy, format: .solo, copies: 2, checkoutSessionID: "PP-1", supersedesOrderID: nil, idempotencyKey: "order-PP-1-0")
        #expect(order.totalCentavos == 10_000)
        #expect(order.expiresAt != nil)
        let request = try #require(PaymentsStubProtocol.captured.first)
        #expect(request.url?.absoluteString == "https://payments.example.test/v1/orders")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "order-PP-1-0")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["expectedPolicyRevisionId"] as? String == "r1")
        #expect(body?["expectedUnitPriceCentavos"] as? Int == 5_000)
        #expect(body?["checkoutSessionId"] as? String == "PP-1")
    }

    @Test func queryStringsAreNotPercentEncodedIntoThePath() throws {
        let configuration = PaymentsConfiguration(baseURL: URL(string: "https://payments.example.test/")!, environment: "test")
        #expect(configuration.url(for: "v1/admin/events?limit=100")?.absoluteString == "https://payments.example.test/v1/admin/events?limit=100")
        #expect(PaymentsConfiguration.validatedURL("http://insecure.example") == nil)
        #expect(PaymentsConfiguration.validatedURL("https://user:pw@host.example") == nil)
    }

    @Test func serverErrorCodesAreStructured() async throws {
        let api = client()
        PaymentsStubProtocol.handler = { _ in (409, Data(#"{"error":"payment_method_locked","message":"This order already started QR Ph.","lockedMethod":"QRPH"}"#.utf8)) }
        do {
            _ = try await api.declareCash(orderID: "o1")
            Issue.record("expected rejection")
        } catch let error as PaymentsAPIError {
            #expect(error.code == "payment_method_locked")
            #expect(!error.isOutcomeUnknown)
        }
        PaymentsStubProtocol.handler = { _ in (503, Data(#"{"error":"qr_status_unknown","message":"QR Ph status is unknown."}"#.utf8)) }
        do {
            _ = try await api.createQR(orderID: "o1")
            Issue.record("expected unknown")
        } catch let error as PaymentsAPIError {
            #expect(error.isOutcomeUnknown, "a provider timeout is unknown, never a failure")
        }
        PaymentsStubProtocol.handler = { _ in (401, Data(#"{"error":"unauthorized","message":"x"}"#.utf8)) }
        await #expect(throws: PaymentsAPIError.unauthorized) { _ = try await api.activeEvent() }
    }

    @Test func transportFailureOnWriteIsOutcomeUnknownButOnReadIsUnavailable() async {
        let api = client()
        PaymentsStubProtocol.handler = { _ in throw URLError(.timedOut) }
        await #expect(throws: PaymentsAPIError.outcomeUnknown) { _ = try await api.declareCash(orderID: "o1") }
        await #expect(throws: PaymentsAPIError.unavailable) { _ = try await api.status(orderID: "o1") }
    }

    @Test func policyChangedCarriesTheCurrentPolicy() async throws {
        let api = client()
        PaymentsStubProtocol.handler = { _ in
            (409, Data(#"{"error":"policy_changed","message":"The event price changed.","currentPolicy":{"id":"ev","name":"Gala","venue":"","lifecycle":"ACTIVE","policyRevisionId":"r2","revision":2,"commercialMode":"PAY_PER_PRINT","unitPriceCentavos":7500,"maxCopies":5,"defaultCopies":1,"cashEnabled":true,"qrphEnabled":true,"prepaidGuestCopyChoice":false,"supportedFormats":["solo"],"features":{},"offlineValidUntil":null}}"#.utf8))
        }
        do {
            _ = try await api.createOrder(event: Self.policy, format: .solo, copies: 1, checkoutSessionID: "PP-2", supersedesOrderID: nil, idempotencyKey: "k")
            Issue.record("expected policy_changed")
        } catch let error as PaymentsAPIError {
            struct Details: Decodable { let currentPolicy: ServerEventPolicy }
            #expect(error.decodeDetails(Details.self)?.currentPolicy.unitPriceCentavos == 7_500)
        }
    }

    @Test func statusDecodesNewCheckoutDecisionAndVerification() async throws {
        let api = client()
        PaymentsStubProtocol.handler = { _ in
            (200, Data(#"{"order":{"id":"o1","eventId":"ev","policyRevisionId":"r1","format":"solo","copies":1,"unitPriceCentavos":5000,"totalCentavos":5000,"currency":"PHP","state":"PAYMENT_PENDING","paymentMethod":"QRPH","expiresAt":null},"attempt":{"id":"a1","method":"QRPH","state":"QR_EXPIRED_CONFIRMED","qrImageDataURL":null,"testURL":null,"expiresAt":"2026-10-10T08:00:00.000Z","verification":"NOT_VERIFIED"},"entitlement":null,"newCheckout":{"allowed":true,"reason":"qr_conclusively_unpaid"},"serverTime":"2026-10-10T08:20:00.000Z"}"#.utf8))
        }
        let status = try await api.status(orderID: "o1")
        #expect(status.newCheckout?.allowed == true)
        #expect(status.attempt?.isConclusivelyUnpaid == true)
        #expect(status.order.paymentMethod == "QRPH")
    }
}
