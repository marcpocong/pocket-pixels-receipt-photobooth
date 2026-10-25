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

    /// The identity a guest's tap is admitted under: the applied design and the policy authority.
    static func admission(library: EventDesignLibrary, commercialEventID: String?, serverBinding: String?, fallbackName: String) -> EventRunContext {
        EventRunContext(designID: library.appliedEventID, commercialEventID: commercialEventID, serverBinding: serverBinding,
                        name: library.design(id: library.appliedEventID)?.displayName ?? fallbackName)
    }
}

nonisolated struct EventRunRecord: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let context: EventRunContext
    let createdAt: Date
    var status: EventRunStatus
    /// Additive, optional fields: older builds ignore them and older manifests decode without them.
    var endedAt: Date? = nil
    var archivedAt: Date? = nil
    /// A completed record the operator created to hold pre-run (legacy) activity. Never current.
    var historical: Bool? = nil
    /// The occurrence this one followed when it was explicitly started from the same design.
    var previousRunID: String? = nil
    /// The first run of an install upgraded from a build without event runs. Its occurrence began
    /// before `createdAt`; statistics count only from `createdAt`.
    var recordedAfterUpgrade: Bool? = nil

    var isHistorical: Bool { historical == true }
}

/// What Start would do with the occurrence for a given setup. Computed before any server change
/// and re-checked at commit, so a concurrent change can't silently reopen or replace a run.
nonisolated enum EventOccurrencePlan: Equatable, Sendable {
    /// No occurrence exists on this iPad yet.
    case createFirst
    /// The same setup is already running; Start only (re)confirms admission.
    case continueActive(runID: String)
    /// The same setup was paused on this iPad; it resumes with the same run ID.
    case resumePaused(runID: String)
    /// The same setup's occurrence has ended. Only an explicit new occurrence may follow it.
    case requiresNewOccurrence(previousRunID: String)
    /// A different design or commercial event: a new run starts and the previous one completes.
    case switchSetup(previousRunID: String, previousStatus: EventRunStatus)

    var createsRun: Bool {
        switch self { case .createFirst, .requiresNewOccurrence, .switchSetup: true; case .continueActive, .resumePaused: false }
    }
}

/// A durable record of a multi-step lifecycle change that spans the server and this iPad.
/// Local JSON and the server database cannot commit atomically, so an interrupted change is
/// resolved by reading authoritative state back, never by blindly repeating the mutation.
nonisolated struct EventTransitionIntent: Codable, Equatable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable { case endCommercialEvent, pauseCommercialEvent, returnToRegular }
    let id: String
    let kind: Kind
    let runID: String?
    let commercialEventID: String
    let serverBinding: String
    let createdAt: Date
    var returnsToRegular: Bool? = nil
    var serverConfirmed: Bool? = nil
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
    @Published private(set) var pendingTransition: EventTransitionIntent?
    private struct Manifest: Codable {
        var schemaVersion = 1; var runs: [EventRunRecord]; var currentRunID: String?
        var pendingTransition: EventTransitionIntent? = nil
    }

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
                runs = manifest.runs; currentRunID = manifest.currentRunID; pendingTransition = manifest.pendingTransition
            } catch {
                unreadable = true
                storageError = "Event-run history could not be read. The original file is preserved; recover it before changing runs."
            }
        }
    }

    var current: EventRunRecord? { runs.first { $0.id == currentRunID } }
    var historyUnreadable: Bool { unreadable }
    /// Completed records are history, even when an older build retained their pointer.
    var operational: EventRunRecord? { current.flatMap { [.active, .paused].contains($0.status) ? $0 : nil } }

    /// One atomic manifest commit completes and detaches the occurrence. The transition remains
    /// journaled until regular configuration and the admission barrier have also committed.
    func completeAndDetachForRegular(intentID: String) throws {
        guard let intent = pendingTransition, intent.id == intentID, intent.returnsToRegular == true,
              intent.serverConfirmed == true else { throw SetupFailure("Return to Regular Booth has not been verified.") }
        guard currentRunID == nil || currentRunID == intent.runID else { throw SetupFailure("The current event changed. Review Booth Status.") }
        var next = runs
        if let index = next.firstIndex(where: { $0.id == intent.runID }) {
            guard [.active, .paused, .completed, .archived].contains(next[index].status) else { throw SetupFailure("The event cannot be completed.") }
            if [.active, .paused].contains(next[index].status) { next[index].status = .completed; next[index].endedAt = Date() }
        }
        try commitManifest(next, currentID: nil)
    }

    static func currentContext() -> EventRunContext {
        let library = EventDesignLibraryStore.shared.library
        let commercial = CommercialEventRunStore.load()
        let managed = CommercialPolicySource.load() == .serverManaged
        return EventRunContext(designID: library.appliedEventID,
                               commercialEventID: managed ? (SessionAcceptanceStore.shared.state.eventID ?? commercial.id) : nil,
                               serverBinding: managed ? OperatorWorkspace.shared.serverBinding : nil,
                               name: library.design(id: library.appliedEventID)?.displayName ?? commercial.name)
    }

    /// Guest admission only uses the occurrence Start committed. It never creates, reopens or
    /// switches a run on a guest's tap, so the first customer cannot change report identity.
    /// The one exception is an install upgraded from a build without event runs (no run exists
    /// yet): its first admission creates the first run so a live booth keeps working.
    func runForAdmission(context: EventRunContext) throws -> EventRunRecord {
        if let current {
            guard current.context.matches(context) else {
                throw SetupFailure("This booth's event changed after it was started. Ask the attendant to review Current Event.")
            }
            guard current.status == .active else { throw SetupFailure("This event run is \(current.status.rawValue). Ask the attendant to resume or start a new run.") }
            return current
        }
        if pendingTransition != nil { throw SetupFailure("An event change needs review. Ask the attendant to open Current Event.") }
        return try createRun(context: context, now: Date(), upgrade: true)
    }

    /// Durable, idempotent upgrade step for an install that is already running an occurrence
    /// with no run recorded. One atomic manifest write; a repeat returns the same run, and a
    /// different identity is refused rather than replacing it. No session is reassigned.
    @discardableResult func recordUpgradedRun(context: EventRunContext, paused: Bool, now: Date = Date()) throws -> EventRunRecord {
        guard authorized() else { throw PaymentsAPIError.unauthorized }
        if pendingTransition != nil { throw SetupFailure("Finish reviewing the interrupted event change in Current Event first.") }
        if let current {
            guard current.context.matches(context), [.active, .paused].contains(current.status) else {
                throw SetupFailure("This iPad already has a different event run. Nothing was changed.")
            }
            return current
        }
        return try createRun(context: context, now: now, status: paused ? .paused : .active, upgrade: true)
    }

    func occurrencePlan(for context: EventRunContext) -> EventOccurrencePlan {
        guard let current else {
            if let previous = runs.last(where: { !$0.isHistorical && $0.context.matches(context) && [.completed, .archived].contains($0.status) }) {
                return .requiresNewOccurrence(previousRunID: previous.id)
            }
            return .createFirst
        }
        guard current.context.matches(context) else { return .switchSetup(previousRunID: current.id, previousStatus: current.status) }
        switch current.status {
        case .active: return .continueActive(runID: current.id)
        case .paused: return .resumePaused(runID: current.id)
        case .draft: return .resumePaused(runID: current.id)
        case .completed, .archived: return .requiresNewOccurrence(previousRunID: current.id)
        }
    }

    /// Commits the occurrence for a reviewed Start. Call only after every server step is
    /// confirmed and before admission opens. `expected` must still describe the current state.
    @discardableResult func commitStart(context: EventRunContext, expected: EventOccurrencePlan, allowNewOccurrence: Bool, now: Date = Date()) throws -> EventRunRecord {
        try checkOperatorTransition()
        if pendingTransition != nil { throw SetupFailure("Finish reviewing the interrupted event change in Current Event first.") }
        let plan = occurrencePlan(for: context)
        guard plan == expected else { throw SetupFailure("The event run changed while starting. Review Current Event and try again.") }
        switch plan {
        case .continueActive(let id): return try record(id)
        case .resumePaused(let id): try transition(id: id, to: .active); return try record(id)
        case .requiresNewOccurrence(let previous):
            guard allowNewOccurrence else { throw SetupFailure("This event run has ended. Choose Start New Occurrence to begin fresh statistics; the ended run keeps its history.") }
            return try createRun(context: context, now: now, previousRunID: previous)
        case .createFirst, .switchSetup: return try createRun(context: context, now: now)
        }
    }

    private func record(_ id: String) throws -> EventRunRecord {
        guard let run = runs.first(where: { $0.id == id }) else { throw SetupFailure("Event run not found.") }
        return run
    }

    /// Low-level run creation for fixtures and migrations. Production occurrences are created only
    /// through the reviewed Start (`commitStart`), the upgrade step, or a historical record.
    @discardableResult func startNewRun(context: EventRunContext, now: Date = Date()) throws -> EventRunRecord {
        try checkOperatorTransition()
        return try createRun(context: context, now: now)
    }

    private func checkOperatorTransition() throws {
        guard authorized() else { throw PaymentsAPIError.unauthorized }
        if let reason = blockingReason() { throw SetupFailure(reason) }
    }

    private func createRun(context: EventRunContext, now: Date, previousRunID: String? = nil, status: EventRunStatus = .active, upgrade: Bool = false) throws -> EventRunRecord {
        let run = EventRunRecord(id: UUID().uuidString.lowercased(), context: context, createdAt: now, status: status, previousRunID: previousRunID,
                                 recordedAfterUpgrade: upgrade && runs.isEmpty ? true : nil)
        var next = runs
        if let index = next.firstIndex(where: { $0.id == currentRunID }), [.active, .paused].contains(next[index].status) {
            next[index].status = .completed; next[index].endedAt = now
        }
        next.append(run)
        try commitManifest(next, currentID: run.id)
        return run
    }

    /// A completed, never-current occurrence that holds operator-attributed legacy activity
    /// from before event runs were recorded. It has no commercial link, so it can never claim sales.
    @discardableResult func createHistoricalRun(name: String, designID: String?, startedAt: Date, endedAt: Date) throws -> EventRunRecord {
        try checkOperatorTransition()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, startedAt <= endedAt else { throw SetupFailure("Enter a name and a valid date range for the earlier event.") }
        let run = EventRunRecord(id: UUID().uuidString.lowercased(), context: EventRunContext(designID: designID, commercialEventID: nil, serverBinding: nil, name: trimmed),
                                 createdAt: startedAt, status: .completed, endedAt: endedAt, historical: true)
        try commitManifest(runs + [run], currentID: currentRunID)
        return run
    }

    /// Records intent before a server lifecycle mutation. Only one may be outstanding.
    func beginTransition(_ intent: EventTransitionIntent) throws {
        if let pendingTransition, pendingTransition.id != intent.id { throw SetupFailure("Another event change still needs review in Current Event.") }
        try commitManifest(runs, currentID: currentRunID, pending: .some(intent))
    }

    func clearTransition(id: String) throws {
        guard pendingTransition?.id == id else { return }
        try commitManifest(runs, currentID: currentRunID, pending: .some(nil))
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

    /// Pausing only closes admission, so it is allowed while a guest or print is still finishing.
    func pauseCurrentRunForAdmission() throws {
        guard authorized() else { throw PaymentsAPIError.unauthorized }
        guard let current, current.status == .active else { return }
        try applyTransition(id: current.id, to: .paused)
    }

    func transition(id: String, to status: EventRunStatus) throws {
        try checkOperatorTransition()
        try applyTransition(id: id, to: status)
    }

    private func applyTransition(id: String, to status: EventRunStatus) throws {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { throw SetupFailure("Event run not found.") }
        let old = runs[index].status
        let permitted: Bool = switch (old, status) {
        case (.draft, .active), (.active, .paused), (.paused, .active), (.active, .completed), (.paused, .completed), (.draft, .archived), (.completed, .archived): true
        default: false
        }
        guard permitted else { throw SetupFailure("That run transition is not allowed. History is retained.") }
        var next = runs; next[index].status = status
        if status == .completed { next[index].endedAt = next[index].endedAt ?? Date() }
        if status == .archived { next[index].archivedAt = Date() }
        try commitManifest(next, currentID: currentRunID)
    }

    func restoreArchivedRun(id: String) throws {
        try checkOperatorTransition()
        guard let index = runs.firstIndex(where: { $0.id == id }), runs[index].status == .archived else {
            throw SetupFailure("Choose an archived run to restore.")
        }
        var next = runs
        next[index].status = .completed
        next[index].archivedAt = nil
        try commitManifest(next, currentID: currentRunID)
    }

    func unusedRunDeletionReason(id: String, archives: [RecentSessionArchiveSummary], inspectionComplete: Bool) -> String? {
        guard inspectionComplete, !historyUnreadable, pendingTransition == nil, storageError == nil else { return "Dependency inspection is incomplete." }
        guard let run = runs.first(where: { $0.id == id }) else { return "Run not found." }
        guard id != currentRunID, [.draft, .completed, .archived].contains(run.status), run.context.commercialEventID == nil else { return "Current and commercially linked runs are protected. Archive completed runs instead." }
        guard !runs.contains(where: { $0.previousRunID == id }) else { return "Another occurrence references this run." }
        let legacy = LegacyAttributionStore(directory: directory)
        guard legacy.storageError == nil else { return "Earlier-session attribution could not be inspected. Keep this run archived until history can be read." }
        guard !legacy.attributions.contains(where: { $0.runID == id }) else { return "Earlier sessions were explicitly attributed to this run. Archive it to keep that history." }
        guard !archives.contains(where: { $0.rasterFingerprint == "CORRUPT" }) else { return "Some session identities are unreadable. Keep this run archived until dependencies can be inspected." }
        do {
            guard try !Self.loadSessions(directory: directory).contains(where: { $0.runID == id }),
                  !archives.contains(where: { $0.eventRunID == id }) else { return "This run has session or receipt history. Archive it instead." }
        } catch { return "Session dependencies could not be read." }
        return nil
    }

    func deleteUnusedRun(id: String, archives: [RecentSessionArchiveSummary], inspectionComplete: Bool, deletedSessions: [RecentSessionArchiveStore.DeletedSessionEvidence]? = nil) throws {
        try checkOperatorTransition()
        // Idempotent after a successful removal; no other record is ever removed by a replay.
        guard runs.contains(where: { $0.id == id }) else { return }
        if let reason = unusedRunDeletionReason(id: id, archives: archives, inspectionComplete: inspectionComplete) { throw SetupFailure(reason) }
        let deleted = try deletedSessions ?? RecentSessionArchiveStore().deletedSessionEvidence()
        if deleted.contains(where: { $0.eventRunID == id }) {
            throw SetupFailure("Removed local media still has historical session evidence. Archive this run instead.")
        }
        try commitManifest(runs.filter { $0.id != id }, currentID: currentRunID)
    }

    private func commitManifest(_ next: [EventRunRecord], currentID: String?, pending: EventTransitionIntent?? = nil) throws {
        do {
            guard !unreadable else { throw SetupFailure(storageError ?? "Event history is unreadable.") }
            let nextPending = pending ?? pendingTransition
            try prepareDirectory(directory)
            try writer(try JSONEncoder().encode(Manifest(runs: next, currentRunID: currentID, pendingTransition: nextPending)), directory.appendingPathComponent("runs.json"))
            runs = next; currentRunID = currentID; pendingTransition = nextPending; storageError = nil; revision += 1
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
