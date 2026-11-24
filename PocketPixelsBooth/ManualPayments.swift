import Foundation
import Combine
import CryptoKit

nonisolated enum ManualPaymentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, cash, digital, cashAndDigital
    var id: String { rawValue }
    var title: String { switch self { case .none: "No Payment"; case .cash: "Cash Only"; case .digital: "Digital Payment Only"; case .cashAndDigital: "Cash + Digital Payment" } }
    var acceptsCash: Bool { self == .cash || self == .cashAndDigital }
    var acceptsDigital: Bool { self == .digital || self == .cashAndDigital }
}

nonisolated enum PaymentReceiptPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case acknowledgmentOnly = "ACK_ONLY", optional = "OPTIONAL", required = "REQUIRED"
    var id: String { rawValue }
    var title: String { switch self { case .acknowledgmentOnly: "Acknowledgment Only"; case .optional: "Optional Receipt Submission"; case .required: "Required Receipt Submission" } }
}

nonisolated struct ManualPaymentPolicy: Codable, Equatable, Sendable {
    var mode: ManualPaymentMode = .none
    var unitPriceCentavos = 2500
    var receiptPolicy: PaymentReceiptPolicy = .optional
    var validationMessage: String? {
        mode != .none && !(1...10_000_000).contains(unitPriceCentavos) ? "Set a price between ₱0.01 and ₱100,000 per copy." : nil
    }
}

nonisolated struct ManualReceivingAccount: Codable, Equatable, Sendable, Identifiable {
    var id = UUID().uuidString.lowercased()
    var provider = ""
    var recipient = ""
    var identifier = ""
    var instructions = "Transfer the exact amount, then acknowledge your payment. Please do not pay twice."
    var qrJPEG: Data? = nil
    var enabled = false
    var permittedUseConfirmed = false
    var isReady: Bool {
        enabled && permittedUseConfirmed && !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && provider.count <= 100 && recipient.count <= 150 && identifier.count <= 150 && instructions.count <= 1000
            && (qrJPEG?.count ?? 0) <= 262_144
    }
}

nonisolated struct ManualPaymentReview: Codable, Equatable, Identifiable, Sendable {
    enum Outcome: String, Codable, CaseIterable, Sendable { case fundsConfirmed = "FUNDS_CONFIRMED", discrepancy = "MISMATCH", unresolved = "NEEDS_REVIEW" }
    let id: String
    let outcome: Outcome
    let confirmedCentavos: Int?
    let note: String
    let createdAt: Date
}

nonisolated struct ManualReceiptProof: Codable, Equatable, Sendable {
    let checkoutId: String
    let snapshotHash: String
    let receiptId: String
    let storedAt: Date
    var trashedAt: Date? = nil
}

nonisolated struct ManualCheckoutRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sessionID: String
    let eventID: String
    let eventName: String
    let runID: String?
    let format: String
    let copies: Int
    let policy: ManualPaymentPolicy
    let receiver: ManualReceivingAccount?
    let method: String
    let createdAt: Date
    let eventProfile: EventProfile?
    var acknowledgedAt: Date?
    var authorizedAt: Date?
    var closedAt: Date?
    var completedAt: Date?
    var printingBeganAt: Date? = nil
    var receipt: ManualReceiptProof?
    var serverID: String?
    var checkoutURL: URL?
    var backendBinding: String?
    var reviews: [ManualPaymentReview] = []
    var syncError: String?
    var totalCentavos: Int { policy.unitPriceCentavos * copies }
    var isDigital: Bool { method == "MANUAL_DIGITAL" }
    var canAuthorize: Bool { acknowledgedAt != nil && (method == "CASH" || policy.receiptPolicy != .required || receipt != nil) }
    var verification: String { reviews.last?.outcome.rawValue ?? "AWAITING_REVIEW" }
    /// Stable canonical snapshot shared by the kiosk and Worker. No customer media/receipt URL.
    var snapshotHash: String {
        let fields = [id, sessionID, eventID, runID ?? "", format, String(copies), String(policy.unitPriceCentavos), method,
                      policy.receiptPolicy.rawValue, receiver?.id ?? "", policy.mode.rawValue]
        return SHA256.hash(data: Data(fields.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var entitlement: CheckoutEntitlement? {
        guard let authorizedAt else { return nil }
        return CheckoutEntitlement(id: "manual-" + id, orderID: nil, eventID: eventID, policyRevisionID: "manual-" + snapshotHash,
            sessionID: sessionID, selectedFormatRawValue: format, purchasedCopies: copies, unitPriceCentavos: policy.unitPriceCentavos,
            totalCentavos: totalCentavos, authorizationSource: isDigital ? .manualDigitalAcknowledged : .manualCashAcknowledged,
            authorizedAt: authorizedAt, receiptFingerprint: nil)
    }
}

/// Local money assertions and print authority are committed before camera access. Cloud sync is
/// evidence only. Neither a mobile reply nor a review can send paper or increase purchased copies.
@MainActor final class ManualPaymentStore: ObservableObject {
    static let shared = ManualPaymentStore()
    struct Payload: Codable { var receiver: ManualReceivingAccount?; var records: [ManualCheckoutRecord] = []; var retentionDays: Int? }
    @Published private(set) var records: [ManualCheckoutRecord] = []
    @Published private(set) var receiver: ManualReceivingAccount?
    @Published private(set) var storageError: String?
    private var payload = Payload()
    private let file: URL
    private let writer: (Data, URL) throws -> Void
    var armedResumeID: String?
    init(directory: URL? = nil, writer: @escaping (Data, URL) throws -> Void = { try DurableFileWriter.write($0, to: $1) }) {
        self.writer = writer
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        file = root.appendingPathComponent("ManualPaymentsV1/records.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let data = try Data(contentsOf: file)
                payload = try (try? JSONDecoder().decode(Payload.self, from: data)) ?? PaymentsJSON.decoder().decode(Payload.self, from: data)
                guard Set(payload.records.map(\.id)).count == payload.records.count,
                      payload.records.allSatisfy({ (1...10).contains($0.copies) && $0.policy.validationMessage == nil && ($0.authorizedAt == nil || $0.canAuthorize) && ($0.receipt == nil || ($0.receipt?.snapshotHash == $0.snapshotHash && $0.receipt?.checkoutId == $0.serverID)) }) else { throw SetupFailure("Invalid manual payment journal.") }
                receiver = payload.receiver; records = payload.records
            } catch { storageError = "Manual payment records could not be read. The original is retained; new paid sessions need recovery." }
        }
    }
    func saveReceiver(_ account: ManualReceivingAccount) throws {
        guard OperatorAccessPermit.shared.isAuthorized else { throw SetupFailure("Unlock Operator before configuring the receiving account.") }
        guard !account.enabled || account.isReady else { throw SetupFailure("Complete the receiving account and confirm it is permitted for this use before enabling digital payments.") }
        var next = payload; var revision = account; var previous = payload.receiver; previous?.enabled = account.enabled; if previous != account { revision.id = UUID().uuidString.lowercased() }; next.receiver = revision; try commit(next)
    }
    func record(_ id: String) -> ManualCheckoutRecord? { records.first { $0.id == id } }
    func record(sessionID: String) -> ManualCheckoutRecord? { records.first { $0.sessionID == sessionID } }
    func begin(sessionID: String, eventID: String, eventName: String, runID: String?, format: String, copies: Int,
               policy: ManualPaymentPolicy, method: String, profile: EventProfile?, now: Date = Date()) throws -> ManualCheckoutRecord {
        guard (1...10).contains(copies), policy.validationMessage == nil,
              method == "CASH" ? policy.mode.acceptsCash : (method == "MANUAL_DIGITAL" && policy.mode.acceptsDigital && receiver?.isReady == true) else {
            throw SetupFailure("This payment method or receiving account is unavailable.")
        }
        if let existing = record(sessionID: sessionID) {
            guard existing.eventID == eventID, existing.copies == copies, existing.format == format, existing.policy == policy,
                  existing.method == method, existing.closedAt == nil else { throw SetupFailure("This guest already has a different payment claim. Open Help & Recovery; do not pay again.") }
            return existing
        }
        let record = ManualCheckoutRecord(id: UUID().uuidString.lowercased(), sessionID: sessionID, eventID: eventID, eventName: eventName,
            runID: runID, format: format, copies: copies, policy: policy, receiver: method == "CASH" ? nil : receiver,
            method: method, createdAt: now, eventProfile: profile)
        var next = payload; next.records.append(record); try commit(next); return record
    }
    func acknowledge(_ id: String, now: Date = Date()) throws {
        try update(id) { r in
            guard r.closedAt == nil, r.completedAt == nil else { throw SetupFailure("This checkout is closed. Ask the attendant to review the original claim; do not pay again.") }
            guard r.acknowledgedAt != nil || now.timeIntervalSince(r.createdAt) <= 1800 else { throw SetupFailure("This checkout expired. Ask the attendant to recover the original payment claim; do not pay again.") }
            r.acknowledgedAt = r.acknowledgedAt ?? now
        }
    }
    @discardableResult func authorize(_ id: String, now: Date = Date()) throws -> CheckoutEntitlement {
        try update(id) { r in
            guard r.authorizedAt != nil || (r.closedAt == nil && r.canAuthorize) else { throw SetupFailure("This policy requires acknowledgment and its matching privately stored receipt before photos can start.") }
            r.authorizedAt = r.authorizedAt ?? now
        }
        return record(id)!.entitlement!
    }
    func applyRemote(_ status: ManualCheckoutStatus, to id: String) throws {
        try update(id) { r in
            guard status.localCheckoutId == r.id, status.sessionId == r.sessionID, status.snapshotHash == r.snapshotHash,
                  status.copies == r.copies, status.totalCentavos == r.totalCentavos,
                  r.serverID == nil || r.serverID == status.id else { throw SetupFailure("The checkout reply belongs to a different payment snapshot.") }
            r.serverID = status.id; r.checkoutURL = status.checkoutURL ?? r.checkoutURL
            r.acknowledgedAt = r.acknowledgedAt ?? status.acknowledgedAt
            if let proof = status.receipt {
                guard proof.checkoutId == status.id, proof.snapshotHash == r.snapshotHash else { throw SetupFailure("Receipt confirmation does not match this guest.") }
                r.receipt = proof
            }
            r.syncError = nil
        }
    }
    func close(_ id: String, now: Date = Date()) throws { try update(id) { $0.closedAt = $0.closedAt ?? now } }
    func reopenForRecovery(_ id: String) throws {
        guard OperatorAccessPermit.shared.isAuthorized else { throw SetupFailure("Unlock Operator to resume an original payment claim.") }
        try update(id) { r in
            guard r.authorizedAt != nil, r.completedAt == nil, r.printingBeganAt == nil else { throw SetupFailure("This claim has no unused authorization.") }
            r.closedAt = nil
        }
    }
    func acceptOriginalClaimForRecovery(_ id: String, note: String, now: Date = Date()) throws {
        guard OperatorAccessPermit.shared.isAuthorized, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SetupFailure("Record the original guest's claim and reason while Operator is unlocked.") }
        try update(id) { r in
            guard r.completedAt == nil else { throw SetupFailure("This original authorization was already completed.") }
            r.acknowledgedAt = r.acknowledgedAt ?? now
            r.reviews.append(.init(id: UUID().uuidString.lowercased(), outcome: .unresolved, confirmedCentavos: nil, note: "Original guest claim accepted for recovery: " + String(note.prefix(800)), createdAt: now))
            if r.canAuthorize { r.authorizedAt = r.authorizedAt ?? now }
        }
    }
    func recordPrintIntent(sessionID: String, now: Date = Date()) throws {
        guard let record = record(sessionID: sessionID), record.entitlement != nil else { throw SetupFailure("Original manual authorization is unavailable before printing.") }
        try update(record.id) { $0.printingBeganAt = $0.printingBeganAt ?? now }
    }
    func complete(sessionID: String, now: Date = Date()) throws {
        guard let r = record(sessionID: sessionID) else { return }; try update(r.id) { $0.completedAt = $0.completedAt ?? now }
    }
    func review(_ id: String, outcome: ManualPaymentReview.Outcome, confirmedCentavos: Int?, note: String, now: Date = Date()) throws {
        guard OperatorAccessPermit.shared.isAuthorized else { throw SetupFailure("Unlock Operator before recording a review.") }
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, note.count <= 1000,
              outcome != .fundsConfirmed || (confirmedCentavos ?? -1) >= 0 else { throw SetupFailure("Record what was independently checked and the actual amount received.") }
        try update(id) { $0.reviews.append(.init(id: UUID().uuidString.lowercased(), outcome: outcome, confirmedCentavos: confirmedCentavos, note: note, createdAt: now)) }
    }
    func setBinding(_ id: String, _ binding: String) throws {
        try update(id) { r in
            guard r.backendBinding == nil || r.backendBinding == binding else { throw SetupFailure("This checkout belongs to its original backend connection.") }
            r.backendBinding = binding
        }
    }
    func setSyncError(_ id: String) { try? update(id) { $0.syncError = "Cloud synchronization pending. Local acknowledgment is retained." } }
    func setRetentionDays(_ days: Int?) throws {
        guard OperatorAccessPermit.shared.isAuthorized, days == nil || (1...3650).contains(days!) else { throw SetupFailure("Choose a valid reviewed retention period.") }
        var next = payload; next.retentionDays = days; try commit(next)
    }
    var retentionDays: Int? { payload.retentionDays }
    var totals: (acknowledged: Int, verified: Int) {
        (records.filter { $0.acknowledgedAt != nil }.reduce(0) { $0 + $1.totalCentavos }, records.reduce(0) { $0 + ($1.reviews.last?.outcome == .fundsConfirmed ? ($1.reviews.last?.confirmedCentavos ?? 0) : 0) })
    }
    private func update(_ id: String, _ body: (inout ManualCheckoutRecord) throws -> Void) throws {
        var next = payload; guard let index = next.records.firstIndex(where: { $0.id == id }) else { throw SetupFailure("Original manual checkout not found.") }
        try body(&next.records[index]); try commit(next)
    }
    private func commit(_ next: Payload) throws {
        if let storageError { throw SetupFailure(storageError) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try writer(JSONEncoder().encode(next), file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        payload = next; receiver = next.receiver; records = next.records
    }
}

nonisolated struct ManualCheckoutStatus: Codable, Sendable {
    let id: String
    let localCheckoutId: String
    let sessionId: String
    let snapshotHash: String
    let copies: Int
    let totalCentavos: Int
    let acknowledgedAt: Date?
    let receipt: ManualReceiptProof?
    let checkoutURL: URL?
}

@MainActor enum ManualPaymentSync {
    private static var active: Set<String> = []
    @discardableResult static func sync(_ id: String, store suppliedStore: ManualPaymentStore? = nil) async throws -> ManualCheckoutRecord {
        let store = suppliedStore ?? .shared
        guard let config = PaymentsConfiguration.current(), var record = store.record(id) else { throw SetupFailure("Mobile checkout is unavailable. Your local payment claim is retained.") }
        let binding = config.environment + ":" + config.baseURL.absoluteString
        try store.setBinding(id, binding)
        guard active.insert(id).inserted else { return store.record(id)! }
        defer { active.remove(id) }
        let client = PaymentsAPIClient(configuration: config)
        do {
            if record.serverID == nil { try store.applyRemote(await client.createManualCheckout(record), to: id) }
            record = store.record(id)!
            let evidence = Array((PrintOutcomeOutbox.shared?.entries.filter { $0.sessionID == record.sessionID && $0.isCustomerCopy } ?? []).suffix(100))
            try store.applyRemote(await client.syncManualFacts(record, printEvidence: evidence), to: id)
            try store.applyRemote(await client.manualCheckoutStatus(store.record(id)!.serverID!), to: id)
            let reviews = store.record(id)!.reviews
            if !reviews.isEmpty {
                // Administration may wait for Operator unlock; it never withholds an already
                // received, exact-checkout guest acknowledgment/private storage proof.
                if OperatorAccessPermit.shared.isAuthorized {
                    do { for review in reviews { try await client.syncManualReview(review, checkoutID: store.record(id)!.serverID!) } }
                    catch { store.setSyncError(id) }
                } else { store.setSyncError(id) }
            }
            return store.record(id)!
        } catch { store.setSyncError(id); throw error }
    }
    static func syncPending(store suppliedStore: ManualPaymentStore? = nil) async {
        let store = suppliedStore ?? .shared
        for record in store.records where record.completedAt == nil || record.syncError != nil { _ = try? await sync(record.id, store: store) }
    }
}
