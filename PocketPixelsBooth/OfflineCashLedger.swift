import Foundation

/// Local Private/Prepaid event settings for booths that do not use the Payments Worker.
/// Paid (pay-per-print) policy is never read from here; it comes only from the server.
nonisolated enum CommercialEventRunStore {
    private static let directoryName = "PaymentState"
    private static let fileName = "active-event.json"

    static func load(fileManager: FileManager = .default) -> CommercialEventRun {
        guard let data = try? Data(contentsOf: fileURL(fileManager: fileManager)),
              let value = try? decoder.decode(CommercialEventRun.self, from: data) else {
            return .legacy
        }
        return value
    }

    static func save(_ run: CommercialEventRun, fileManager: FileManager = .default) throws {
        let url = fileURL(named: fileName, fileManager: fileManager)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DurableFileWriter.write(try encoder.encode(run), to: url, fileManager: fileManager)
    }

    static var didChangeNotification: Notification.Name {
        Notification.Name("pocketPixels.commercialEvent.didChange")
    }

    static func publish(_ run: CommercialEventRun) throws {
        guard run.activePolicy.commercialMode == .privatePrepaid else {
            throw CommercialEventRunStoreError.paidPolicyRequiresServer
        }
        try save(run)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static func fileURL(fileManager: FileManager) -> URL {
        fileURL(named: fileName, fileManager: fileManager)
    }

    private static func fileURL(named name: String, fileManager: FileManager) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(name)
    }

    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.sortedKeys]
        return value
    }()

    private static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }()
}

nonisolated enum CommercialEventRunStoreError: Error, LocalizedError {
    case paidPolicyRequiresServer

    var errorDescription: String? {
        "Paid events are managed on the payments server. Local settings can only be Private / Prepaid."
    }
}

nonisolated struct OfflineCashRecord: Codable, Equatable, Identifiable, Sendable {
    enum SyncState: String, Codable, Sendable {
        case pending
        case syncing
        case synced
        case conflict
    }

    let id: String
    let localSequence: Int
    let eventID: String
    let policyRevisionID: String
    /// Signed offline policy snapshot that authorized this declaration (nil only for legacy records).
    var snapshotID: String? = nil
    let sessionID: String
    let format: String
    let copies: Int
    let unitPriceCentavos: Int
    let totalCentavos: Int
    let declaredAt: Date
    var syncState: SyncState
    var serverOrderID: String?
    var failureMessage: String?
    /// Server review flag such as `DECLARED_AFTER_SERVER_REVOCATION`.
    var reviewFlag: String? = nil
}

/// Result of one record in `POST /v1/sync/offline-cash`.
nonisolated struct OfflineSyncResult: Codable, Equatable, Sendable {
    let localId: String?
    let orderId: String?
    let result: String
    let reason: String?
    let reviewFlag: String?
}

/// Durable, append-only journal of guest self-declared cash taken while offline.
///
/// Every mutation is applied to a copy, written with `DurableFileWriter` (temp file, fsync,
/// atomic rename) and only then adopted in memory, so a failed write (disk full, I/O error)
/// never leaves a phantom authorization. An unreadable or inconsistent journal is quarantined
/// and blocks new offline cash until an operator acknowledges it.
actor OfflineCashLedger {
    enum LedgerError: Error, LocalizedError, Equatable {
        case invalidPolicy
        case duplicateSession
        case invalidAmount
        case declarationLimitReached
        case clockRolledBack
        case integrityFault(String)
        case persistFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidPolicy: "Offline cash is not authorized by a valid signed event policy."
            case .duplicateSession: "This session already has a cash declaration."
            case .invalidAmount: "The price, format or copy quantity is not allowed by the offline policy."
            case .declarationLimitReached: "The offline cash limit for this policy was reached. Reconnect to continue."
            case .clockRolledBack: "Offline cash is paused because the iPad clock moved backwards."
            case .integrityFault(let detail): "Offline cash is blocked: \(detail)"
            case .persistFailed(let detail): "Nothing was authorized: the cash record could not be saved (\(detail))."
            }
        }
    }

    typealias Writer = @Sendable (Data, URL) throws -> Void

    /// The one journal for the app. Every screen must use this instance: two actors over the same
    /// file could overwrite each other's committed records.
    static let shared: OfflineCashLedger? = try? OfflineCashLedger()

    private struct FilePayload: Codable {
        var nextSequence: Int
        var records: [OfflineCashRecord]
        var trustedClockFloor: Date?
    }

    private let fileManager: FileManager
    private let url: URL
    private let writer: Writer
    private var payload: FilePayload
    private(set) var integrityFault: String?

    init(fileManager: FileManager = .default, directory: URL? = nil, writer: Writer? = nil) throws {
        self.fileManager = fileManager
        let root = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        url = root.appendingPathComponent("PaymentState", isDirectory: true).appendingPathComponent("offline-cash-ledger.json")
        self.writer = writer ?? { data, url in try DurableFileWriter.write(data, to: url) }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        payload = FilePayload(nextSequence: 1, records: [], trustedClockFloor: nil)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try PaymentsJSON.decoder().decode(FilePayload.self, from: data)
            if let problem = Self.consistencyProblem(decoded) { throw LedgerError.integrityFault(problem) }
            payload = decoded
        } catch {
            // Keep the unreadable journal for audit; never silently start over with sequence 1.
            let quarantine = url.deletingLastPathComponent()
                .appendingPathComponent("offline-cash-ledger.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.moveItem(at: url, to: quarantine)
            integrityFault = "the offline cash journal was unreadable and was set aside for review (\(quarantine.lastPathComponent))."
        }
    }

    private static func consistencyProblem(_ payload: FilePayload) -> String? {
        let ids = Set(payload.records.map(\.id))
        let sequences = Set(payload.records.map(\.localSequence))
        let sessions = Set(payload.records.map(\.sessionID))
        guard ids.count == payload.records.count else { return "duplicate record identifiers." }
        guard sequences.count == payload.records.count else { return "duplicate local sequence numbers." }
        guard sessions.count == payload.records.count else { return "duplicate session declarations." }
        guard payload.records.allSatisfy({ $0.localSequence >= 1 && $0.localSequence < payload.nextSequence }) else {
            return "local sequence numbers are inconsistent."
        }
        guard payload.records.allSatisfy({ $0.copies >= 1 && $0.unitPriceCentavos > 0 && $0.totalCentavos == $0.unitPriceCentavos * $0.copies }) else {
            return "a record has an invalid amount."
        }
        return nil
    }

    /// Records a guest's self-declared cash under a verified signed offline policy.
    func declare(
        policy: OfflinePolicyPayload,
        sessionID: String,
        format: BoothFormat,
        copies: Int,
        at date: Date = Date()
    ) throws -> (OfflineCashRecord, CheckoutEntitlement) {
        if let integrityFault { throw LedgerError.integrityFault(integrityFault) }
        if let floor = payload.trustedClockFloor, date < floor.addingTimeInterval(-OfflinePolicyVerifier.clockSkew) {
            throw LedgerError.clockRolledBack
        }
        guard date <= policy.expiresAt, date >= policy.notBefore.addingTimeInterval(-OfflinePolicyVerifier.clockSkew) else {
            throw LedgerError.invalidPolicy
        }
        guard !payload.records.contains(where: { $0.sessionID == sessionID }) else {
            throw LedgerError.duplicateSession
        }
        guard (1...policy.maxCopies).contains(copies), let authorizedFormat = format.paymentRawValue(in: policy.supportedFormats),
              policy.unitPriceCentavos > 0, policy.unitPriceCentavos <= Int.max / copies else {
            throw LedgerError.invalidAmount
        }
        let usedUnderSnapshot = payload.records.filter { $0.snapshotID == policy.snapshotId }.count
        guard usedUnderSnapshot < policy.maxDeclarations else { throw LedgerError.declarationLimitReached }

        let total = policy.unitPriceCentavos * copies
        let record = OfflineCashRecord(
            id: UUID().uuidString.lowercased(),
            localSequence: payload.nextSequence,
            eventID: policy.eventId,
            policyRevisionID: policy.policyRevisionId,
            snapshotID: policy.snapshotId,
            sessionID: sessionID,
            format: authorizedFormat,
            copies: copies,
            unitPriceCentavos: policy.unitPriceCentavos,
            totalCentavos: total,
            declaredAt: date,
            syncState: .pending
        )
        var candidate = payload
        candidate.nextSequence += 1
        candidate.records.append(record)
        candidate.trustedClockFloor = max(candidate.trustedClockFloor ?? .distantPast, date)
        try commit(candidate)

        let entitlement = CheckoutEntitlement(
            id: "offline-cash-\(record.id)",
            orderID: nil,
            eventID: policy.eventId,
            policyRevisionID: policy.policyRevisionId,
            sessionID: sessionID,
            selectedFormatRawValue: format.rawValue,
            purchasedCopies: copies,
            unitPriceCentavos: policy.unitPriceCentavos,
            totalCentavos: total,
            authorizationSource: .localUnsyncedCashDeclared,
            authorizedAt: date,
            receiptFingerprint: nil
        )
        return (record, entitlement)
    }

    func pendingRecords() -> [OfflineCashRecord] {
        payload.records.filter { $0.syncState == .pending || $0.syncState == .syncing }
    }

    func conflictRecords() -> [OfflineCashRecord] {
        payload.records.filter { $0.syncState == .conflict }
    }

    func allRecords() -> [OfflineCashRecord] {
        payload.records
    }

    /// Self-reported cash this iPad has not yet delivered to the server.
    func unsyncedTotalCentavos() -> Int {
        pendingRecords().reduce(0) { partial, record in
            let (sum, overflow) = partial.addingReportingOverflow(record.totalCentavos)
            return overflow ? Int.max : sum
        }
    }

    /// Applies server sync results. Conflicts stay in the journal, visible to the operator.
    func applySync(_ results: [OfflineSyncResult]) throws {
        var candidate = payload
        for result in results {
            guard let localID = result.localId, let index = candidate.records.firstIndex(where: { $0.id == localID }) else { continue }
            switch result.result {
            case "synced", "duplicate":
                candidate.records[index].syncState = .synced
                candidate.records[index].serverOrderID = result.orderId ?? candidate.records[index].serverOrderID
                candidate.records[index].failureMessage = nil
                candidate.records[index].reviewFlag = result.reviewFlag
            case "conflict":
                candidate.records[index].syncState = .conflict
                candidate.records[index].failureMessage = result.reason ?? "rejected by server"
            default:
                // "retry" or unknown results keep the record pending for the next attempt.
                candidate.records[index].syncState = .pending
            }
        }
        try commit(candidate)
    }

    /// Operator acknowledgement after a quarantined journal. Sequence numbers restart far above
    /// any earlier value so they cannot collide with records already accepted by the server.
    func acknowledgeIntegrityFaultAndStartNewJournal(now: Date = Date()) throws {
        guard integrityFault != nil else { return }
        let candidate = FilePayload(nextSequence: max(1, Int(now.timeIntervalSince1970)), records: [], trustedClockFloor: now)
        try commit(candidate)
        integrityFault = nil
    }

    /// Delivers pending records to the server in bounded batches.
    func syncPending(using client: PaymentsAPIClient) async throws -> (synced: Int, conflicts: Int) {
        let batch = Array(pendingRecords().prefix(50))
        guard !batch.isEmpty else { return (0, 0) }
        let results = try await client.syncOfflineCash(records: batch)
        try applySync(results)
        return (results.filter { $0.result == "synced" || $0.result == "duplicate" }.count, results.filter { $0.result == "conflict" }.count)
    }

    private func commit(_ candidate: FilePayload) throws {
        do {
            try writer(try PaymentsJSON.encoder().encode(candidate), url)
        } catch {
            throw LedgerError.persistFailed(error.localizedDescription)
        }
        payload = candidate
    }
}
