import Foundation
import Combine

/// An explicit, authenticated operator statement that a legacy session belongs to an occurrence.
/// It is append-only, never rewrites the receipt archive, payment orders or gallery identities,
/// and is always reported separately from exact (identity-proven) activity.
nonisolated struct LegacySessionAttribution: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let archiveID: String
    let sessionID: String
    let runID: String
    let attributedAt: Date
    let note: String
    /// One operator confirmation; every entry of a batch shares it. Absent on single entries
    /// written by earlier builds.
    var batchID: String? = nil
}

@MainActor final class LegacyAttributionStore: ObservableObject {
    static let shared = LegacyAttributionStore()
    @Published private(set) var attributions: [LegacySessionAttribution] = []
    @Published private(set) var storageError: String?
    private let file: URL
    private let writer: (Data, URL) throws -> Void
    private let authorized: @MainActor () -> Bool
    private var unreadable = false
    private struct Journal: Codable { var schemaVersion = 1; var attributions: [LegacySessionAttribution] }

    init(directory: URL? = nil, writer: @escaping (Data, URL) throws -> Void = { try DurableFileWriter.write($0, to: $1) },
         authorized: @escaping @MainActor () -> Bool = { OperatorAccessPermit.shared.isAuthorized }) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("EventRunsV1")
        file = root.appendingPathComponent("legacy-attributions.json")
        self.writer = writer; self.authorized = authorized
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
            guard journal.schemaVersion == 1, Set(journal.attributions.map(\.archiveID)).count == journal.attributions.count else { throw CocoaError(.fileReadCorruptFile) }
            attributions = journal.attributions
        } catch {
            unreadable = true
            storageError = "Earlier-event attributions could not be read. The file is preserved; exact reports are unaffected."
        }
    }

    /// Records one attribution. A legacy archive can be attributed once; it cannot be moved.
    func attribute(_ archive: RecentSessionArchiveSummary, to run: EventRunRecord, note: String, exact: Set<String>, now: Date = Date()) throws {
        _ = try attribute([archive], to: run, knownRuns: [run], note: note, exact: exact, now: now)
    }

    /// Validates every selected session first, then appends the whole batch in one durable write.
    /// Any invalid item fails the batch and nothing is written. Receipts, galleries and orders are
    /// never touched, and attributions stay separate from exact run identities.
    @discardableResult
    func attribute(_ archives: [RecentSessionArchiveSummary], to run: EventRunRecord, knownRuns: [EventRunRecord], note: String,
                   exact: Set<String>, now: Date = Date()) throws -> [LegacySessionAttribution] {
        let entries = try validatedBatch(archives, to: run, knownRuns: knownRuns, note: note, exact: exact, now: now)
        let next = attributions + entries
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
            try writer(JSONEncoder().encode(Journal(attributions: next)), file)
            attributions = next; storageError = nil
        } catch { storageError = "Attribution not saved: \(error.localizedDescription). Nothing was attributed."; throw error }
        return entries
    }

    /// The same checks as `attribute`, without writing. Use before creating an earlier-event
    /// record so a doomed batch doesn't leave an empty record behind.
    func validate(_ archives: [RecentSessionArchiveSummary], to run: EventRunRecord, knownRuns: [EventRunRecord], note: String,
                  exact: Set<String>, now: Date = Date()) throws {
        _ = try validatedBatch(archives, to: run, knownRuns: knownRuns, note: note, exact: exact, now: now)
    }

    private func validatedBatch(_ archives: [RecentSessionArchiveSummary], to run: EventRunRecord, knownRuns: [EventRunRecord], note: String,
                                exact: Set<String>, now: Date) throws -> [LegacySessionAttribution] {
        guard authorized() else { throw PaymentsAPIError.unauthorized }
        guard !unreadable else { throw SetupFailure(storageError ?? "Attributions are unavailable.") }
        let reason = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !reason.isEmpty else { throw SetupFailure("Enter the reason for this attribution. It is kept with the record.") }
        guard !archives.isEmpty else { throw SetupFailure("Select at least one session.") }
        guard knownRuns.contains(where: { $0.id == run.id }) else { throw SetupFailure("The chosen event run no longer exists. Nothing was attributed.") }
        guard Set(archives.map(\.archiveID)).count == archives.count, Set(archives.map(\.sessionIdentifier)).count == archives.count else {
            throw SetupFailure("The selection lists a session twice. Nothing was attributed.")
        }
        let attributed = Set(attributions.map(\.archiveID))
        for archive in archives {
            let when = archive.createdAt.formatted(date: .abbreviated, time: .shortened)
            guard archive.rasterFingerprint != "CORRUPT" else { throw SetupFailure("The session from \(when) can't be read. Nothing was attributed.") }
            guard archive.eventRunID == nil, !exact.contains(archive.sessionIdentifier) else {
                throw SetupFailure("The session from \(when) already has an exact event-run identity. Nothing was attributed.")
            }
            guard !attributed.contains(archive.archiveID) else {
                throw SetupFailure("The session from \(when) was already attributed. Attributions are permanent; nothing was attributed.")
            }
            guard archive.createdAt <= now.addingTimeInterval(300) else { throw SetupFailure("The session from \(when) has an impossible future time. Nothing was attributed.") }
            // An earlier-event record is the operator's own statement; a real run has real bounds.
            if !run.isHistorical {
                if run.context.commercialEventID != nil, archive.createdAt < run.createdAt {
                    throw SetupFailure("The session from \(when) is earlier than this run started. Choose an earlier-event record. Nothing was attributed.")
                }
                if let ended = run.endedAt, archive.createdAt > ended.addingTimeInterval(60) {
                    throw SetupFailure("The session from \(when) is later than this run ended. Nothing was attributed.")
                }
            }
        }
        let batch = UUID().uuidString.lowercased()
        return archives.map {
            LegacySessionAttribution(id: UUID().uuidString.lowercased(), archiveID: $0.archiveID, sessionID: $0.sessionIdentifier,
                                     runID: run.id, attributedAt: now, note: reason, batchID: batch)
        }
    }
}

/// Read-only diagnostic of what local evidence can prove about each archived session.
nonisolated struct HistoricalActivityReport: Equatable, Sendable {
    nonisolated struct DayGroup: Equatable, Identifiable, Sendable {
        var id: Date { day }
        let day: Date
        let archives: [RecentSessionArchiveSummary]
        var byFormat: [String: Int] { Dictionary(grouping: archives, by: \.format.rawValue).mapValues(\.count) }
        var names: [String] { Array(Set(archives.compactMap(\.eventName).filter { !$0.isEmpty })).sorted() }
    }

    /// Archives whose run is proven by the archive's own saved run ID or by the session journal.
    let exactByRun: [String: Int]
    /// Archives with an audited operator attribution, by run. Never merged into exact counts.
    let attributedByRun: [String: Int]
    /// Archives with no provable or attributed run, grouped by local calendar day.
    let unassigned: [DayGroup]
    /// Exact copy records in the print journal whose session has no run identity.
    let unassignedPrintCopies: Int
    let corruptArchives: Int

    static let unassignedReason = "Recorded before this iPad saved event-run identities. No saved run, order or checkout identity links these sessions to an occurrence, so they are not counted in any run. Names and dates are shown only to help a manual review."

    init(archives: [RecentSessionArchiveSummary], sessions: [EventRunSession], runs: [EventRunRecord],
         attributions: [LegacySessionAttribution], printEntries: [PrintOutboxEntry], calendar: Calendar = .current) {
        let knownRuns = Set(runs.map(\.id))
        let journal = Dictionary(sessions.map { ($0.sessionID, $0.runID) }, uniquingKeysWith: { first, _ in first })
        let attributed = Dictionary(attributions.map { ($0.archiveID, $0.runID) }, uniquingKeysWith: { first, _ in first })
        var exact: [String: Int] = [:], manual: [String: Int] = [:], loose: [RecentSessionArchiveSummary] = []
        var corrupt = 0
        for archive in archives {
            if archive.rasterFingerprint == "CORRUPT" { corrupt += 1; continue }
            if let run = archive.eventRunID ?? journal[archive.sessionIdentifier], knownRuns.contains(run) { exact[run, default: 0] += 1 }
            else if let run = attributed[archive.archiveID], knownRuns.contains(run) { manual[run, default: 0] += 1 }
            else { loose.append(archive) }
        }
        exactByRun = exact; attributedByRun = manual; corruptArchives = corrupt
        unassigned = Dictionary(grouping: loose) { calendar.startOfDay(for: $0.createdAt) }
            .map { DayGroup(day: $0.key, archives: $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { $0.day > $1.day }
        unassignedPrintCopies = Set(printEntries.filter { $0.kind == .copy && journal[$0.sessionID] == nil }.map { "\($0.batchID)/\($0.copyIndex)" }).count
    }

    var unassignedCount: Int { unassigned.reduce(0) { $0 + $1.archives.count } }
}

/// Commercial orders that cannot be matched to any occurrence recorded on this iPad.
nonisolated enum CommercialAttribution {
    static func unmatchedOrders(_ rows: [OperatorOrderRow], allSessions: [EventRunSession]) -> [OperatorOrderRow] {
        let matched = Set(EventRunFinancialTotals.matchingOrders(rows, sessions: allSessions).map(\.id))
        var seen = Set<String>()
        return rows.filter { !matched.contains($0.id) && seen.insert($0.id).inserted }
    }
}
