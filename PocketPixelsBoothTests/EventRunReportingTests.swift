import XCTest
import SwiftUI
@testable import PocketPixelsBooth

@MainActor final class EventRunReportingTests: XCTestCase {
    private var directory: URL!
    private let context = EventRunContext(designID: "design-a", commercialEventID: "commercial-a", serverBinding: "test:https://synthetic.example.test", name: "Same Event Name")
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    private func makeStore() -> EventRunStore { EventRunStore(directory: directory, authorized: { true }, blockingReason: { nil }) }

    func testRunAndCompletionsSurviveRelaunchAndNewRunKeepsHistory() throws {
        let first = makeStore()
        let run = try first.startNewRun(context: context)
        try first.beginSession(id: "original", runID: run.id, format: "solo")
        first.updateSession(id: "original") { $0.completedAt = Date(); $0.printOutcomes["batch/1"] = "delivered" }
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.current?.id, run.id)
        XCTAssertEqual(EventRunStatistics(sessions: try EventRunStore.loadSessions(directory: directory)).completed, 1)
        let second = try relaunched.startNewRun(context: context)
        XCTAssertNotEqual(second.id, run.id)
        XCTAssertEqual(relaunched.runs.first?.status, .completed)
        XCTAssertEqual(try relaunched.session(id: "original")?.runID, run.id)
        XCTAssertEqual(try EventRunStore.loadSessions(directory: directory).filter { $0.runID == second.id }.count, 0)
    }

    func testRepeatedCallbacksDoNotInflateCopiesCompletionOrGalleryCounts() throws {
        let store = makeStore(); let run = try store.startNewRun(context: context)
        try store.beginSession(id: "session", runID: run.id, format: "duo")
        for _ in 0..<20 {
            store.updateSession(id: "session") {
                if $0.completedAt == nil { $0.completedAt = Date() }
                $0.printOutcomes["batch/1"] = "delivered"
                $0.printOutcomes["batch/2"] = "uncertain"
                $0.galleryPreparedAt = Date(); $0.galleryVerifiedAt = Date()
            }
        }
        let stats = EventRunStatistics(sessions: try EventRunStore.loadSessions(directory: directory))
        XCTAssertEqual(stats.completed, 1); XCTAssertEqual(stats.completedByFormat["duo"], 1)
        XCTAssertEqual(stats.delivered, 1); XCTAssertEqual(stats.uncertain, 1)
        XCTAssertEqual(stats.galleriesVerified, 1); XCTAssertEqual(stats.galleriesAwaitingVerification, 0)
    }

    func testNamesNeverIdentifyRunsAndTestLiveRemainSeparate() throws {
        let store = makeStore()
        let first = try store.runForAdmission(context: context)
        let sameName = EventRunContext(designID: "design-b", commercialEventID: context.commercialEventID, serverBinding: context.serverBinding, name: context.name)
        XCTAssertThrowsError(try store.runForAdmission(context: sameName), "A guest tap never switches or creates an occurrence")
        XCTAssertEqual(store.current?.id, first.id)
        XCTAssertEqual(store.occurrencePlan(for: sameName), .switchSetup(previousRunID: first.id, previousStatus: .active))
        let second = try store.commitStart(context: sameName, expected: store.occurrencePlan(for: sameName), allowNewOccurrence: false)
        XCTAssertNotEqual(first.id, second.id)
        let live = EventRunContext(designID: sameName.designID, commercialEventID: sameName.commercialEventID, serverBinding: "live:https://synthetic.example.test", name: sameName.name)
        let third = try store.commitStart(context: live, expected: store.occurrencePlan(for: live), allowNewOccurrence: false)
        XCTAssertNotEqual(third.id, second.id)
        XCTAssertThrowsError(try store.runForAdmission(context: sameName), "A TEST setup can never admit into the LIVE run")
        XCTAssertEqual(try store.runForAdmission(context: live).id, third.id)
    }

    func testHistoricalSessionCannotBeReassignedToNewRun() throws {
        let store = makeStore(); let old = try store.startNewRun(context: context)
        try store.beginSession(id: "original", runID: old.id, format: "solo")
        let new = try store.startNewRun(context: context)
        XCTAssertThrowsError(try store.beginSession(id: "original", runID: new.id, format: "solo"))
        store.updateSession(id: "unknown-old-session") { $0.completedAt = Date() }
        XCTAssertNil(try store.session(id: "unknown-old-session"))
        XCTAssertEqual(try store.session(id: "original")?.runID, old.id)
    }

    func testPauseResumeEndAndArchivePreserveIdentityAndHistory() throws {
        let store = makeStore(); let run = try store.startNewRun(context: context)
        try store.transition(id: run.id, to: .paused)
        XCTAssertThrowsError(try store.runForAdmission(context: context))
        try store.transition(id: run.id, to: .active)
        XCTAssertEqual(try store.runForAdmission(context: context).id, run.id)
        try store.transition(id: run.id, to: .completed)
        try store.transition(id: run.id, to: .archived)
        XCTAssertThrowsError(try store.transition(id: run.id, to: .active))
        XCTAssertEqual(makeStore().runs.first?.status, .archived)
    }

    func testFinancialAndPrintSafetyAndAuthenticationBlockRunReset() throws {
        var reason: String? = "Unresolved checkout"
        var authorized = true
        let store = EventRunStore(directory: directory, authorized: { authorized }, blockingReason: { reason })
        XCTAssertThrowsError(try store.startNewRun(context: context))
        XCTAssertNil(store.current)
        reason = nil; authorized = false
        XCTAssertThrowsError(try store.startNewRun(context: context))
        authorized = true
        let run = try store.startNewRun(context: context)
        reason = "Print output unknown"
        XCTAssertThrowsError(try store.transition(id: run.id, to: .completed))
        XCTAssertEqual(store.current?.status, .active)
    }

    func testDiskFailureKeepsCommittedRunAndSessionRecords() throws {
        let good = makeStore(); let run = try good.startNewRun(context: context)
        try good.beginSession(id: "saved", runID: run.id, format: "solo")
        let failing = EventRunStore(directory: directory, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }, authorized: { true }, blockingReason: { nil })
        XCTAssertThrowsError(try failing.startNewRun(context: context))
        XCTAssertEqual(failing.current?.id, run.id)
        failing.updateSession(id: "saved") { $0.completedAt = Date() }
        XCTAssertNotNil(failing.storageError)
        XCTAssertNil(try good.session(id: "saved")?.completedAt)
        XCTAssertEqual(makeStore().current?.id, run.id)
    }

    func testUnreadableRunHistoryIsPreservedAndCannotBeOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("runs.json"); let bytes = Data("corrupt".utf8)
        try bytes.write(to: file)
        let store = makeStore()
        XCTAssertNotNil(store.storageError)
        XCTAssertThrowsError(try store.startNewRun(context: context))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testPartialPrintsAndGalleryUnknownAreNotCompletedOrVerified() throws {
        let store = makeStore(); let run = try store.startNewRun(context: context)
        try store.beginSession(id: "interrupted", runID: run.id, format: "strip")
        store.updateSession(id: "interrupted") { $0.printOutcomes = ["batch/1": "delivered", "batch/2": "inFlight"]; $0.galleryPreparedAt = Date() }
        let stats = EventRunStatistics(sessions: try EventRunStore.loadSessions(directory: directory))
        XCTAssertEqual(stats.completed, 0); XCTAssertEqual(stats.delivered, 1); XCTAssertEqual(stats.uncertain, 1)
        XCTAssertEqual(stats.galleriesVerified, 0); XCTAssertEqual(stats.galleriesAwaitingVerification, 1)
    }

    private func order(_ id: String, category: String, amount: Int = 5000, state: String = "COMPLETE", held: Bool = false, session: String? = nil, entitlement: String = "CONSUMED") -> OperatorOrderRow {
        OperatorOrderRow(id: id, createdAt: Date(), boothFormat: "solo", copies: 1, totalCentavos: amount, state: state, method: nil,
                         paymentState: nil, category: category, entitlementState: held ? "REVIEW_REQUIRED" : entitlement,
                         confirmedPrints: 0, uncertainPrints: 0, lastReconcileError: nil, sessionId: session)
    }

    func testRunPaymentsUseExactMembershipAndExcludeUnresolvedAndHeldFromRevenue() throws {
        var session = EventRunSession(sessionID: "original", runID: "run", createdAt: Date(), format: "solo")
        session.orderIDs = ["live", "test", "unknown", "held", "staff", "guest"]
        let rows = [order("live", category: "QRPH_VERIFIED_LIVE"), order("test", category: "QRPH_VERIFIED_TEST"),
                    order("unknown", category: "QRPH_UNRESOLVED"), order("held", category: "QRPH_VERIFIED_LIVE", held: true),
                    order("staff", category: "CASH_OPERATOR_CONFIRMED"), order("guest", category: "CASH_SELF_REPORTED"),
                    order("another-run", category: "QRPH_VERIFIED_LIVE"), order("offline-synced", category: "CASH_SELF_REPORTED_OFFLINE_SYNCED", session: "original")]
        let matching = EventRunFinancialTotals.matchingOrders(rows + [rows[0]], sessions: [session])
        XCTAssertEqual(matching.count, 7)
        let totals = try EventRunFinancialTotals(orders: matching)
        XCTAssertEqual(totals.verifiedLive, 5000); XCTAssertEqual(totals.verifiedTest, 5000)
        XCTAssertEqual(totals.operatorCash, 5000); XCTAssertEqual(totals.declaredCash, 10000)
        XCTAssertEqual(totals.unresolved, 1); XCTAssertEqual(totals.review, 1)
    }

    func testInvalidFinancialAmountsFailInsteadOfDisplayingZero() {
        XCTAssertThrowsError(try EventRunFinancialTotals(orders: [order("negative", category: "QRPH_VERIFIED_LIVE", amount: -1)]))
        XCTAssertThrowsError(try EventRunFinancialTotals(orders: [order("a", category: "QRPH_VERIFIED_LIVE", amount: Int.max), order("b", category: "QRPH_VERIFIED_LIVE")]))
    }

    func testLegacySessionDecodingKeepsMissingGalleryEvidenceUnknown() throws {
        let date = Date().timeIntervalSinceReferenceDate
        let bytes = Data("{\"sessionID\":\"old\",\"runID\":\"run\",\"createdAt\":\(date),\"format\":\"solo\",\"orderIDs\":[],\"printOutcomes\":{}}".utf8)
        let record = try JSONDecoder().decode(EventRunSession.self, from: bytes)
        XCTAssertNil(record.completedAt); XCTAssertNil(record.galleryVerifiedAt); XCTAssertNil(record.galleryPreparedAt)
    }
    func testActualCompletionCallbackRecordsOnceAndKeepsRunAfterGuestReset() throws {
        let store = makeStore(); let run = try store.startNewRun(context: context)
        var environment = BoothSessionEnvironment.customer
        environment.archiveDirectory = directory.appendingPathComponent("archive")
        environment.recoveryDirectory = directory.appendingPathComponent("recovery")
        environment.deliversGallery = false
        let model = BoothSessionViewModel(environment: environment, eventRunStore: store)
        model.configureAuthorizedCameraReadyForTesting()
        let session = try XCTUnwrap(model.sessionIdentifier)
        try store.beginSession(id: session, runID: run.id, format: "solo")
        model.completeSessionForReportingTest()
        let completedAt = try XCTUnwrap(store.session(id: session)?.completedAt)
        model.completeSessionForReportingTest()
        XCTAssertEqual(try store.session(id: session)?.completedAt, completedAt)
        model.resetAfterDone()
        XCTAssertEqual(try store.session(id: session)?.runID, run.id)
        XCTAssertEqual(EventRunStatistics(sessions: try EventRunStore.loadSessions(directory: directory)).completed, 1)
        XCTAssertNil(model.sessionIdentifier)
    }

    func testAutomaticContextSwitchCannotBypassUnresolvedFinancialRecovery() throws {
        var reason: String?
        let store = EventRunStore(directory: directory, authorized: { true }, blockingReason: { reason })
        let original = try store.runForAdmission(context: context)
        reason = "Unresolved payment"
        let other = EventRunContext(designID: "different", commercialEventID: nil, serverBinding: nil, name: context.name)
        XCTAssertThrowsError(try store.runForAdmission(context: other))
        XCTAssertEqual(store.current?.id, original.id)
        XCTAssertEqual(try store.runForAdmission(context: context).id, original.id, "An existing run is preserved; there is no hidden reset")
    }

    func testPauseAndEndCloseExistingAdmissionBarrierForRollbackSafety() throws {
        let store = makeStore(); let run = try store.startNewRun(context: context)
        let admission = SessionAcceptanceStore(directory: directory.appendingPathComponent("admission"))
        XCTAssertFalse(admission.state.blocked)
        try store.pauseOrEndCurrentRun(admission: admission, status: .paused)
        XCTAssertTrue(SessionAcceptanceStore(directory: directory.appendingPathComponent("admission")).state.blocked)
        XCTAssertEqual(store.current?.status, .paused)
        try store.pauseOrEndCurrentRun(admission: admission, status: .completed)
        XCTAssertEqual(store.current?.status, .completed)
        XCTAssertEqual(store.current?.id, run.id)
    }

    func testRunWriteFailureAfterPausingLeavesAdmissionFailClosed() throws {
        let good = makeStore(); _ = try good.startNewRun(context: context)
        let failing = EventRunStore(directory: directory, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }, authorized: { true }, blockingReason: { nil })
        let admission = SessionAcceptanceStore(directory: directory.appendingPathComponent("admission"))
        XCTAssertThrowsError(try failing.pauseOrEndCurrentRun(admission: admission, status: .paused))
        XCTAssertTrue(admission.state.blocked)
        XCTAssertEqual(good.current?.status, .active)
    }

    func testOfflineCashSnapshotScopesEnvironmentAndRunWithoutServerAccess() throws {
        func cash(_ id: String, environment: String?, event: String = "event", session: String = "member", state: OfflineCashRecord.SyncState = .pending) -> OfflineCashRecord {
            OfflineCashRecord(id: id, localSequence: 1, eventID: event, policyRevisionID: "policy", sessionID: session,
                format: "solo", copies: 1, unitPriceCentavos: 5000, totalCentavos: 5000, declaredAt: Date(), syncState: state, environment: environment)
        }
        let local = try OfflineCashReportingSnapshot(records: [cash("live", environment: "live"), cash("test", environment: "test"),
            cash("legacy", environment: nil), cash("other-run", environment: "live", session: "other"),
            cash("other-event", environment: "live", event: "other"), cash("synced", environment: "live", state: .synced)],
            eventID: "event", environment: "live", sessionIDs: ["member"])
        XCTAssertEqual(local.pending.map(\.id), ["live"])
        XCTAssertEqual(local.unassigned.map(\.id), ["legacy"])
        XCTAssertEqual(local.centavos, 5000)
    }

    func testPaidButUnclaimedOrderMatchesOriginalCheckoutWithoutInventingAClaim() throws {
        let session = EventRunSession(sessionID: "original-checkout", runID: "run", createdAt: Date(), format: "solo")
        var paid = order("unclaimed-order", category: "QRPH_VERIFIED_LIVE", state: "AUTHORIZED", entitlement: "AUTHORIZED")
        paid.checkoutSessionId = session.sessionID
        XCTAssertNil(paid.sessionId)
        let matched = EventRunFinancialTotals.matchingOrders([paid], sessions: [session])
        XCTAssertEqual(matched.map(\.id), [paid.id])
        XCTAssertEqual(try EventRunFinancialTotals(orders: matched).verifiedLive, 5000)
        XCTAssertNil(paid.sessionId, "A report read cannot claim or rebind an entitlement")
    }

}
