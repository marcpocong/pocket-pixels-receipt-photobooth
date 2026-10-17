import XCTest
@testable import PocketPixelsBooth

@MainActor final class EventHistoryReportingTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func archive(_ id: String, session: String, at date: Date, run: String? = nil, name: String? = "Garden Wedding", corrupt: Bool = false) -> RecentSessionArchiveSummary {
        RecentSessionArchiveSummary(archiveID: id, sessionIdentifier: session, createdAt: date, format: .solo, eventName: name, eventLocation: nil, photoCount: 1,
            receiptWidth: 576, receiptHeight: 900, estimatedLengthMillimeters: 100, rasterFingerprint: corrupt ? "CORRUPT" : String(repeating: "a", count: 64),
            thumbnailFilenames: [], lastReprintedAt: nil, reprintCount: 0, payloadSizeBytes: 1, eventRunID: run)
    }
    private func store(_ authorized: @escaping @MainActor () -> Bool = { true }) -> EventRunStore {
        EventRunStore(directory: root.appendingPathComponent("runs"), authorized: authorized, blockingReason: { nil })
    }
    private let context = EventRunContext(designID: "d", commercialEventID: nil, serverBinding: nil, name: "Today")

    func testHistoricalReportProvesOnlyIdentityLinkedSessionsAndExplainsTheRest() throws {
        let runs = store()
        let run = try runs.startNewRun(context: context)
        try runs.beginSession(id: "journal-only", runID: run.id, format: "solo")
        let day1 = Date(timeIntervalSince1970: 1_760_000_000), day2 = day1.addingTimeInterval(3 * 86_400)
        let archives = [
            archive("a1", session: "exact-archive", at: day2, run: run.id),
            archive("a2", session: "journal-only", at: day2),
            archive("a3", session: "legacy-1", at: day1), archive("a4", session: "legacy-2", at: day1.addingTimeInterval(60), name: "Debut"),
            archive("a5", session: "legacy-3", at: day2.addingTimeInterval(-86_400)),
            archive("a6", session: "unknown-run", at: day2, run: "deleted-run"),
            archive("a7", session: "broken", at: day1, corrupt: true)
        ]
        let sessions = try EventRunStore.loadSessions(directory: runs.directory)
        let report = HistoricalActivityReport(archives: archives, sessions: sessions, runs: runs.runs, attributions: [], printEntries: [], calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(report.exactByRun[run.id], 2, "Archive run ID and the session journal are both immutable identities")
        XCTAssertEqual(report.unassignedCount, 4, "Unknown run IDs and pre-run archives are never guessed into a run")
        XCTAssertEqual(report.corruptArchives, 1)
        XCTAssertEqual(report.unassigned.map(\.archives.count).reduce(0, +), 4)
        XCTAssertTrue(report.unassigned.contains { $0.names == ["Debut", "Garden Wedding"] }, "Names are shown only for review")
        XCTAssertTrue(HistoricalActivityReport.unassignedReason.contains("not counted in any run"))
        XCTAssertEqual(EventRunStatistics(sessions: sessions.filter { $0.runID == run.id }).completed, 0, "The diagnostic is read-only")
    }

    func testUnassignedPrintEvidenceIsCountedOnceAndNeverAdopted() throws {
        let runs = store()
        let run = try runs.startNewRun(context: context)
        try runs.beginSession(id: "assigned", runID: run.id, format: "solo")
        let outbox = try PrintOutcomeOutbox(directory: root.appendingPathComponent("outbox"))
        for session in ["assigned", "legacy"] {
            try outbox.beginCopy(batchID: session, sessionID: session, entitlementID: nil, receiptFingerprint: String(repeating: "b", count: 64), copyIndex: 1, copyCount: 1, transport: "bluetooth")
            _ = outbox.finishCopy(batchID: session, copyIndex: 1, state: .delivered)
        }
        let report = HistoricalActivityReport(archives: [], sessions: try EventRunStore.loadSessions(directory: runs.directory), runs: runs.runs, attributions: [], printEntries: outbox.entries + outbox.entries)
        XCTAssertEqual(report.unassignedPrintCopies, 1)
        XCTAssertNil(try runs.session(id: "legacy"))
    }

    func testManualAttributionIsAuthenticatedAppendOnlyAuditedAndSeparateFromExactCounts() throws {
        var authorized = true
        let runs = store { authorized }
        let attributions = LegacyAttributionStore(directory: root.appendingPathComponent("runs"), authorized: { authorized })
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let earlier = try runs.createHistoricalRun(name: "June Wedding", designID: nil, startedAt: start, endedAt: start.addingTimeInterval(3600))
        XCTAssertTrue(earlier.isHistorical); XCTAssertEqual(earlier.status, .completed)
        XCTAssertNil(runs.current, "An earlier-event record never becomes the current run")
        XCTAssertNil(earlier.context.commercialEventID, "It can never claim sales")
        let legacy = archive("legacy-a", session: "legacy-session", at: start.addingTimeInterval(60))
        authorized = false
        XCTAssertThrowsError(try attributions.attribute(legacy, to: earlier, note: "Owner confirmed", exact: []))
        authorized = true
        try attributions.attribute(legacy, to: earlier, note: "Owner confirmed from the guest list", exact: [])
        XCTAssertThrowsError(try attributions.attribute(legacy, to: earlier, note: "again", exact: []), "Attributions cannot be moved or repeated")
        XCTAssertThrowsError(try attributions.attribute(archive("exact", session: "s", at: start, run: earlier.id), to: earlier, note: "x", exact: []))
        XCTAssertThrowsError(try attributions.attribute(archive("journal", session: "in-journal", at: start), to: earlier, note: "x", exact: ["in-journal"]))

        let reloaded = LegacyAttributionStore(directory: root.appendingPathComponent("runs"), authorized: { true })
        XCTAssertEqual(reloaded.attributions.map(\.archiveID), ["legacy-a"])
        XCTAssertEqual(reloaded.attributions.first?.note, "Owner confirmed from the guest list")
        let report = HistoricalActivityReport(archives: [legacy], sessions: [], runs: store().runs, attributions: reloaded.attributions, printEntries: [])
        XCTAssertEqual(report.attributedByRun[earlier.id], 1)
        XCTAssertNil(report.exactByRun[earlier.id], "Operator attribution is never reported as exact")
        XCTAssertEqual(report.unassignedCount, 0)
    }

    func testCorruptAttributionJournalIsPreservedAndBlocksNewAttributions() throws {
        let directory = root.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("legacy-attributions.json")
        try Data("broken".utf8).write(to: file)
        let attributions = LegacyAttributionStore(directory: directory, authorized: { true })
        XCTAssertNotNil(attributions.storageError)
        let run = EventRunRecord(id: "r", context: context, createdAt: Date(), status: .completed, historical: true)
        XCTAssertThrowsError(try attributions.attribute(archive("x", session: "x", at: Date()), to: run, note: "n", exact: []))
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
    }

    func testCommercialOrdersNotLinkedToAnyRunStayUnassignedAndAreNotGuessed() {
        func row(_ id: String, session: String? = nil, checkout: String? = nil) -> OperatorOrderRow {
            var value = OperatorOrderRow(id: id, createdAt: Date(), boothFormat: "solo", copies: 1, totalCentavos: 5000, state: "COMPLETE", method: nil, paymentState: nil,
                category: "QRPH_VERIFIED_LIVE", entitlementState: "CONSUMED", confirmedPrints: 1, uncertainPrints: 0, lastReconcileError: nil, sessionId: session)
            value.checkoutSessionId = checkout
            return value
        }
        var runA = EventRunSession(sessionID: "a", runID: "run-a", createdAt: Date(), format: "solo"); runA.orderIDs = ["by-id"]
        let runB = EventRunSession(sessionID: "b", runID: "run-b", createdAt: Date(), format: "solo")
        let rows = [row("by-id"), row("by-session", session: "b"), row("by-checkout", checkout: "a"), row("other-ipad", session: "elsewhere"), row("legacy"), row("legacy")]
        let unmatched = CommercialAttribution.unmatchedOrders(rows, allSessions: [runA, runB])
        XCTAssertEqual(unmatched.map(\.id), ["other-ipad", "legacy"])
        XCTAssertEqual(EventRunFinancialTotals.matchingOrders(rows, sessions: [runA]).map(\.id), ["by-id", "by-checkout"])
        XCTAssertEqual(EventRunFinancialTotals.matchingOrders(rows, sessions: [runB]).map(\.id), ["by-session"])
    }

    func testMultipleRunsKeepSeparateRestartSafeStatisticsAndCompleteCSV() throws {
        let first = store()
        let a = try first.startNewRun(context: context)
        for id in ["a1", "a2"] { try first.beginSession(id: id, runID: a.id, format: "solo"); first.updateSession(id: id) { $0.completedAt = Date(); $0.printOutcomes[id + "/1"] = "delivered" } }
        let b = try first.startNewRun(context: context)
        try first.beginSession(id: "b1", runID: b.id, format: "strip")
        first.updateSession(id: "b1") { $0.completedAt = Date(); $0.printOutcomes["b1/1"] = "delivered"; $0.printOutcomes["b1/2"] = "notStarted" }
        let relaunched = store()
        XCTAssertEqual(relaunched.runs.first { $0.id == a.id }?.status, .completed)
        XCTAssertNotNil(relaunched.runs.first { $0.id == a.id }?.endedAt)
        let sessions = try EventRunStore.loadSessions(directory: relaunched.directory)
        XCTAssertEqual(EventRunStatistics(sessions: sessions.filter { $0.runID == a.id }).completed, 2)
        let bStats = EventRunStatistics(sessions: sessions.filter { $0.runID == b.id })
        XCTAssertEqual(bStats.completed, 1); XCTAssertEqual(bStats.completedByFormat["strip"], 1); XCTAssertEqual(bStats.notStarted, 1)

        let csv = EventRunCSV.make(run: a, sessions: sessions)
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.first, EventRunCSV.header)
        XCTAssertEqual(lines.count, 3, "Exactly this run's sessions, no others")
        // A random run UUID can itself contain "b1". Check the exported session column,
        // so the assertion proves run isolation independently of generated identifiers.
        let exportedSessions = Set(lines.dropFirst().map { $0.components(separatedBy: ",")[2] })
        XCTAssertEqual(exportedSessions, Set(["\"a1\"", "\"a2\""]))
        XCTAssertFalse(csv.lowercased().contains("http"), "No gallery links or tokens")
        let hostile = EventRunRecord(id: "r", context: EventRunContext(designID: nil, commercialEventID: nil, serverBinding: nil, name: "=HYPERLINK(\"x\")"), createdAt: Date(), status: .active)
        XCTAssertTrue(EventRunCSV.make(run: hostile, sessions: [EventRunSession(sessionID: "s", runID: "r", createdAt: Date(), format: "solo")]).contains("\"'=HYPERLINK(\"\"x\"\")\""))
    }

    func testLegacyManifestWithoutNewFieldsDecodesAndOlderReadersIgnoreThem() throws {
        let directory = root.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let created = Date().timeIntervalSinceReferenceDate
        let legacy = "{\"schemaVersion\":1,\"currentRunID\":\"old\",\"runs\":[{\"id\":\"old\",\"createdAt\":\(created),\"status\":\"active\",\"context\":{\"name\":\"Stage 2\",\"designID\":\"d\"}}]}"
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("runs.json"))
        let store = store()
        XCTAssertNil(store.storageError)
        XCTAssertEqual(store.current?.id, "old"); XCTAssertNil(store.current?.endedAt); XCTAssertNil(store.pendingTransition)
        try store.transition(id: "old", to: .completed)
        // A Stage 2 reader decodes only the original keys.
        struct OldRecord: Decodable { let id: String; let status: String; let createdAt: Date }
        struct OldManifest: Decodable { let schemaVersion: Int; let runs: [OldRecord]; let currentRunID: String? }
        let old = try JSONDecoder().decode(OldManifest.self, from: Data(contentsOf: directory.appendingPathComponent("runs.json")))
        XCTAssertEqual(old.schemaVersion, 1); XCTAssertEqual(old.runs.first?.status, "completed")
    }

    func testLegacyDesignLibraryDecodesWithoutRetiredLinksAndDraftCannotReplaceALink() throws {
        let library = EventDesignLibraryStore(directory: root, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" }, operationAuthorized: { true }, operationBlockingReason: { nil })
        let design = try library.create(name: "Gala", venue: "")
        try library.link(designID: design.id, binding: "b", serverEventID: "current")
        var stale = design; stale.serverEvents["b"] = "stale-draft-link"
        try library.save(stale)
        XCTAssertEqual(library.design(id: design.id)?.serverEvents["b"], "current", "The library owns commercial links")
        try library.linkNewCommercialOccurrence(designID: design.id, binding: "b", expectedCurrent: "current", newServerEventID: "next")
        var edited = try XCTUnwrap(library.design(id: design.id)); edited.retiredServerEvents = nil; edited.name = "Gala II"
        try library.save(edited)
        XCTAssertEqual(library.design(id: design.id)?.retiredServerEvents?["b"], ["current"], "A draft can't erase link history")
        XCTAssertEqual(library.design(id: design.id)?.allServerEventIDs(binding: "b"), ["current", "next"])
        XCTAssertTrue(SavedDraftDiff.design(edited, library.design(id: design.id)).allSatisfy { !$0.label.lowercased().contains("retired") })
        XCTAssertThrowsError(try library.linkNewCommercialOccurrence(designID: nil, binding: "b", expectedCurrent: "none", newServerEventID: "current"))
    }
}
