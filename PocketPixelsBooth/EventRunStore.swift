import Foundation
import Combine
import CryptoKit

nonisolated enum EventRunStatus: String, Codable, CaseIterable, Sendable {
    case draft, active, paused, completed, archived
}

/// An occurrence is distinct from both reusable artwork and the server's commercial event.
nonisolated struct EventRunContext: Codable, Equatable, Sendable {
    let designID: String?
    let commercialEventID: String?
    let serverBinding: String?
    let name: String
    func matches(_ other: Self) -> Bool {
        designID == other.designID && commercialEventID == other.commercialEventID && serverBinding == other.serverBinding
    }
}

nonisolated struct EventRunRecord: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let context: EventRunContext
    let createdAt: Date
    var status: EventRunStatus
}

/// Small, private operational journal. It contains no images, QR links, tokens or credentials.
nonisolated struct EventRunSession: Codable, Identifiable, Equatable, Sendable {
    var id: String { sessionID }
    let sessionID: String
    let runID: String
    let createdAt: Date
    var format: String
    var orderIDs: [String] = []
    var completedAt: Date?
    /// One final observed result per batch/copy. A repeated callback never inflates totals.
    var printOutcomes: [String: String] = [:]
    var galleryPreparedAt: Date?
    var galleryVerifiedAt: Date?
}

@MainActor final class EventRunStore: ObservableObject {
    static let shared = EventRunStore()
    @Published private(set) var runs: [EventRunRecord] = []
    @Published private(set) var currentRunID: String?
    @Published private(set) var storageError: String?
    @Published private(set) var revision = 0
    let directory: URL
    private let writer: (Data, URL) throws -> Void
    private var unreadable = false
    private let authorized: @MainActor () -> Bool
    private let blockingReason: @MainActor () -> String?
    private struct Manifest: Codable { var schemaVersion = 1; var runs: [EventRunRecord]; var currentRunID: String? }

    init(directory: URL? = nil, writer: @escaping (Data, URL) throws -> Void = { try DurableFileWriter.write($0, to: $1) },
         authorized: @escaping @MainActor () -> Bool = { OperatorAccessPermit.shared.isAuthorized },
         blockingReason: @escaping @MainActor () -> String? = { SessionSetupSafety.blockingReason }) {
        self.authorized = authorized
        self.blockingReason = blockingReason
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("EventRunsV1")
        self.writer = writer
        let file = self.directory.appendingPathComponent("runs.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file))
                guard manifest.schemaVersion == 1, Set(manifest.runs.map(\.id)).count == manifest.runs.count,
                      manifest.currentRunID == nil || manifest.runs.contains(where: { $0.id == manifest.currentRunID }) else { throw CocoaError(.fileReadCorruptFile) }
                runs = manifest.runs; currentRunID = manifest.currentRunID
            } catch {
                unreadable = true
                storageError = "Event-run history could not be read. The original file is preserved; recover it before changing runs."
            }
        }
    }

    var current: EventRunRecord? { runs.first { $0.id == currentRunID } }

    static func currentContext() -> EventRunContext {
        let library = EventDesignLibraryStore.shared.library
        let commercial = CommercialEventRunStore.load()
        let managed = CommercialPolicySource.load() == .serverManaged
        return EventRunContext(designID: library.appliedEventID,
                               commercialEventID: managed ? (SessionAcceptanceStore.shared.state.eventID ?? commercial.id) : nil,
                               serverBinding: managed ? OperatorWorkspace.shared.serverBinding : nil,
                               name: library.design(id: library.appliedEventID)?.displayName ?? commercial.name)
    }

    /// First use of a setup creates a stable run. Returning to a completed occurrence needs an
    /// explicit operator action; old archives are never assigned by their event name.
    func runForAdmission(context: EventRunContext) throws -> EventRunRecord {
        if let current, current.context.matches(context) {
            guard current.status == .active else { throw SetupFailure("This event run is \(current.status.rawValue). Ask the attendant to resume or start a new run.") }
            return current
        }
        if current != nil, let reason = blockingReason() { throw SetupFailure(reason) }
        return try createRun(context: context, now: Date())
    }

    @discardableResult func startNewRun(context: EventRunContext, now: Date = Date()) throws -> EventRunRecord {
        try checkOperatorTransition()
        return try createRun(context: context, now: now)
    }

    private func checkOperatorTransition() throws {
        guard authorized() else { throw PaymentsAPIError.unauthorized }
        if let reason = blockingReason() { throw SetupFailure(reason) }
    }

    private func createRun(context: EventRunContext, now: Date) throws -> EventRunRecord {
        let run = EventRunRecord(id: UUID().uuidString.lowercased(), context: context, createdAt: now, status: .active)
        var next = runs
        if let index = next.firstIndex(where: { $0.id == currentRunID }), [.active, .paused].contains(next[index].status) { next[index].status = .completed }
        next.append(run)
        try commitManifest(next, currentID: run.id)
        return run
    }

    /// The existing durable admission barrier also protects a rollback to a pre-run app.
    /// If the run write fails, admission stays paused instead of silently accepting guests.
    func pauseOrEndCurrentRun(admission: SessionAcceptanceStore, status: EventRunStatus) throws {
        try checkOperatorTransition()
        guard status == .paused || status == .completed, let current,
              current.status == .active || (current.status == .paused && status == .completed) else {
            throw SetupFailure("Only an active or paused current run can be paused or ended.")
        }
        var barrier = admission.state; barrier.blocked = true
        try admission.save(barrier)
        try transition(id: current.id, to: status)
    }

    func transition(id: String, to status: EventRunStatus) throws {
        try checkOperatorTransition()
        guard let index = runs.firstIndex(where: { $0.id == id }) else { throw SetupFailure("Event run not found.") }
        let old = runs[index].status
        let permitted: Bool = switch (old, status) {
        case (.draft, .active), (.active, .paused), (.paused, .active), (.active, .completed), (.paused, .completed), (.draft, .archived), (.completed, .archived): true
        default: false
        }
        guard permitted else { throw SetupFailure("That run transition is not allowed. History is retained.") }
        var next = runs; next[index].status = status
        try commitManifest(next, currentID: currentRunID)
    }

    private func commitManifest(_ next: [EventRunRecord], currentID: String?) throws {
        do {
            guard !unreadable else { throw SetupFailure(storageError ?? "Event history is unreadable.") }
            try prepareDirectory(directory)
            try writer(try JSONEncoder().encode(Manifest(runs: next, currentRunID: currentID)), directory.appendingPathComponent("runs.json"))
            runs = next; currentRunID = currentID; storageError = nil; revision += 1
        } catch { storageError = error.localizedDescription; throw error }
    }

    private func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
    }

    private func sessionURL(_ id: String) -> URL {
        let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("sessions").appendingPathComponent(key + ".json")
    }

    func session(id: String) throws -> EventRunSession? {
        let file = sessionURL(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let record = try JSONDecoder().decode(EventRunSession.self, from: Data(contentsOf: file))
        guard record.sessionID == id, runs.contains(where: { $0.id == record.runID }) else { throw SetupFailure("Session reporting identity is inconsistent; data was retained.") }
        return record
    }

    func beginSession(id: String, runID: String, format: String, now: Date = Date()) throws {
        if var existing = try session(id: id) {
            guard existing.runID == runID else { throw SetupFailure("This session already belongs to another event run.") }
            guard existing.completedAt == nil else { return }
            existing.format = format
            try saveSession(existing)
        } else {
            guard runs.contains(where: { $0.id == runID }) else { throw SetupFailure("Unknown event run.") }
            try saveSession(EventRunSession(sessionID: id, runID: runID, createdAt: now, format: format))
        }
    }

    func updateSession(id: String, _ change: (inout EventRunSession) -> Void) {
        do {
            // Older recoveries stay unassigned. Never adopt a historical session into today's run.
            guard var record = try session(id: id) else { return }
            change(&record)
            try saveSession(record)
        } catch { storageError = "Operational reporting could not be saved: \(error.localizedDescription). Payment and print journals are retained separately." }
    }

    private func saveSession(_ session: EventRunSession) throws {
        do {
            guard !unreadable else { throw SetupFailure("Event history is unreadable.") }
            try prepareDirectory(directory.appendingPathComponent("sessions"))
            try writer(try JSONEncoder().encode(session), sessionURL(session.sessionID))
            revision += 1; storageError = nil
        } catch { storageError = error.localizedDescription; throw error }
    }

    /// Reconcile only sessions already assigned to a run, using the authoritative local print
    /// outbox after launch. This repairs a crash between print accounting and statistics writes.
    func reconcilePrintEvidence(_ entries: [PrintOutboxEntry]) async {
        for (sessionID, copies) in Dictionary(grouping: entries.filter { $0.kind == .copy }, by: \.sessionID) {
            do {
                guard var record = try session(id: sessionID) else { continue }
                let original = record
                let latest = Dictionary(grouping: copies, by: { $0.batchID + "/" + String($0.copyIndex) })
                    .compactMapValues { $0.max(by: { $0.updatedAt < $1.updatedAt }) }
                for (key, entry) in latest { record.printOutcomes[key] = entry.localState.rawValue }
                if record.completedAt == nil {
                    for batch in Dictionary(grouping: Array(latest.values), by: \.batchID).values {
                        guard let count = batch.first?.copyCount,
                              PaymentRecoveryCoordinator.allPaidCopiesDelivered(batch, paidCopies: count) else { continue }
                        record.completedAt = batch.map(\.updatedAt).max()
                    }
                }
                if record != original { try saveSession(record) }
            } catch { storageError = "Print history was retained, but operational statistics need recovery: \(error.localizedDescription)" }
            await Task.yield()
        }
    }

    nonisolated static func loadSessions(directory: URL) throws -> [EventRunSession] {
        let path = directory.appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let records = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(EventRunSession.self, from: Data(contentsOf: $0)) }
        guard Set(records.map(\.sessionID)).count == records.count else { throw SetupFailure("Duplicate reporting identities need operator review; records were retained.") }
        return records
    }
}

nonisolated struct EventRunStatistics: Equatable, Sendable {
    let completed: Int
    let completedByFormat: [String: Int]
    let delivered: Int
    let uncertain: Int
    let notStarted: Int
    let galleriesVerified: Int
    let galleriesAwaitingVerification: Int
    init(sessions: [EventRunSession]) {
        let unique = Dictionary(sessions.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first }).values
        let completedSessions = unique.filter { $0.completedAt != nil }
        completed = completedSessions.count
        completedByFormat = Dictionary(grouping: completedSessions, by: \.format).mapValues(\.count)
        let outcomes = unique.flatMap { $0.printOutcomes.values }
        delivered = outcomes.filter { $0 == "delivered" }.count
        uncertain = outcomes.filter { $0 == "uncertain" || $0 == "inFlight" }.count
        notStarted = outcomes.filter { $0 == "notStarted" }.count
        galleriesVerified = unique.filter { $0.galleryVerifiedAt != nil }.count
        galleriesAwaitingVerification = unique.filter { $0.galleryPreparedAt != nil && $0.galleryVerifiedAt == nil }.count
    }
}
