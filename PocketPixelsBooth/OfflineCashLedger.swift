import Foundation

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
        try save(run)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func loadDraft(fileManager: FileManager = .default) -> CommercialEventRun {
        guard let data = try? Data(contentsOf: fileURL(named: "draft-event.json", fileManager: fileManager)),
              let value = try? decoder.decode(CommercialEventRun.self, from: data) else {
            return load(fileManager: fileManager)
        }
        return value
    }

    static func saveDraft(_ run: CommercialEventRun, fileManager: FileManager = .default) throws {
        let url = fileURL(named: "draft-event.json", fileManager: fileManager)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DurableFileWriter.write(try encoder.encode(run), to: url, fileManager: fileManager)
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
    let sessionID: String
    let format: String
    let copies: Int
    let unitPriceCentavos: Int
    let totalCentavos: Int
    let declaredAt: Date
    var syncState: SyncState
    var serverOrderID: String?
    var failureMessage: String?
}

actor OfflineCashLedger {
    enum LedgerError: Error, LocalizedError {
        case invalidPolicy
        case duplicateSession
        case invalidAmount

        var errorDescription: String? {
            switch self {
            case .invalidPolicy: "Offline cash is not authorized by the cached event policy."
            case .duplicateSession: "This session already has a cash declaration."
            case .invalidAmount: "The cached price or copy quantity is invalid."
            }
        }
    }

    private struct FilePayload: Codable {
        var nextSequence: Int
        var records: [OfflineCashRecord]
    }

    private let fileManager: FileManager
    private let url: URL
    private var payload: FilePayload

    init(fileManager: FileManager = .default, directory: URL? = nil) throws {
        self.fileManager = fileManager
        let root = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        url = root.appendingPathComponent("PaymentState", isDirectory: true).appendingPathComponent("offline-cash-ledger.json")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url),
           let decoded = try? Self.decoder.decode(FilePayload.self, from: data) {
            payload = decoded
        } else {
            payload = FilePayload(nextSequence: 1, records: [])
        }
    }

    func declare(
        event: CommercialEventRun,
        sessionID: String,
        format: BoothFormat,
        copies: Int,
        at date: Date = Date()
    ) throws -> (OfflineCashRecord, CheckoutEntitlement) {
        let policy = event.activePolicy
        guard event.lifecycle == .active, policy.permitsOfflineCash(at: date) else {
            throw LedgerError.invalidPolicy
        }
        guard !payload.records.contains(where: { $0.sessionID == sessionID }) else {
            throw LedgerError.duplicateSession
        }
        guard let total = policy.totalCentavos(for: copies), policy.supports(format) else {
            throw LedgerError.invalidAmount
        }

        let record = OfflineCashRecord(
            id: UUID().uuidString.lowercased(),
            localSequence: payload.nextSequence,
            eventID: event.id,
            policyRevisionID: policy.revisionID,
            sessionID: sessionID,
            format: format.rawValue,
            copies: copies,
            unitPriceCentavos: policy.unitPriceCentavos,
            totalCentavos: total,
            declaredAt: date,
            syncState: .pending
        )
        payload.nextSequence += 1
        payload.records.append(record)
        try persist()

        let entitlement = CheckoutEntitlement(
            id: "offline-cash-\(record.id)",
            orderID: nil,
            eventID: event.id,
            policyRevisionID: policy.revisionID,
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
        payload.records.filter { $0.syncState == .pending || $0.syncState == .conflict }
    }

    func unsyncedTotalCentavos() -> Int {
        pendingRecords().reduce(0) { partial, record in
            let (sum, overflow) = partial.addingReportingOverflow(record.totalCentavos)
            return overflow ? Int.max : sum
        }
    }

    func applySync(localID: String, serverOrderID: String?, conflict: String?) throws {
        guard let index = payload.records.firstIndex(where: { $0.id == localID }) else { return }
        payload.records[index].serverOrderID = serverOrderID
        payload.records[index].failureMessage = conflict
        payload.records[index].syncState = conflict == nil ? .synced : .conflict
        try persist()
    }

    private func persist() throws {
        try DurableFileWriter.write(try Self.encoder.encode(payload), to: url, fileManager: fileManager)
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
