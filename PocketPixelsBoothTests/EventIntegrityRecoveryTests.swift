import XCTest
@testable import PocketPixelsBooth

/// Event Integrity & Recovery release, P0: installs upgraded from builds without event runs.
/// Reproduces the Carlo state recorded at the Stage 3 install — a LIVE paid event active on the
/// server, guest admission open for it, and no event run because no guest arrived since the upgrade.
@MainActor final class UpgradedEventBootstrapTests: XCTestCase {
    private func upgradedPaidBooth(lifecycle: CommercialEventLifecycle = .active, blocked: Bool = false) throws -> Booth {
        let booth = Booth()
        let revision = OperatorPolicyRevision(id: "live-r1", revision: 1, commercialMode: .payPerPrint, unitPriceCentavos: 5000, maxCopies: 5, defaultCopies: 1,
                                              cashEnabled: false, qrphEnabled: true, prepaidGuestCopyChoice: false, supportedFormats: ["solo"], offlineValidUntil: nil,
                                              createdAt: Date(), activatedAt: Date())
        booth.server.events["live-event"] = .init(name: "Gala Night", venue: "Ballroom", lifecycle: lifecycle, version: 3, latest: revision, active: revision)
        booth.source = .serverManaged
        try booth.acceptance.save(.init(blocked: blocked, eventID: "live-event", serverBinding: booth.binding, mode: .serverManaged))
        XCTAssertNil(booth.runs.current, "precondition: no event run yet")
        return booth
    }
    private func upgradedPrepaidBooth(paused: Bool = false) throws -> Booth {
        let booth = Booth()
        booth.local.activePolicy.commercialMode = .privatePrepaid
        booth.local.activePolicy.unitPriceCentavos = 0
        booth.local.lifecycle = paused ? .paused : .active
        try booth.acceptance.save(.init(blocked: paused, eventID: nil, serverBinding: nil, mode: .localPrepaid))
        return booth
    }
    private func manifestBytes(_ booth: Booth) -> Data? { try? Data(contentsOf: booth.runs.directory.appendingPathComponent("runs.json")) }

    func testUpgradedActivePaidEventWithoutRunIsNotShownAsUnconfigured() async throws {
        let booth = try upgradedPaidBooth(); defer { booth.cleanup() }
        let lifecycle = booth.lifecycle()
        XCTAssertEqual(lifecycle.linkedCommercialEventID, "live-event", "The committed admission identity is checkable without a run")
        XCTAssertEqual(lifecycle.status, .unconfirmed("checking now"), "Before the server answers it is not claimed as success")
        await lifecycle.refresh()
        XCTAssertEqual(lifecycle.status, .accepting)
        XCTAssertTrue(lifecycle.canRecordUpgradedRun)
        XCTAssertEqual(booth.server.mutations("create") + booth.server.mutations("activate") + booth.server.mutations("pause"), 0, "Status is read-only")
    }

    func testUpgradedPrepaidEventWithoutRunAcceptsAndPausedPrepaidIsPaused() async throws {
        let open = try upgradedPrepaidBooth(); defer { open.cleanup() }
        XCTAssertEqual(open.lifecycle().status, .accepting)
        let paused = try upgradedPrepaidBooth(paused: true); defer { paused.cleanup() }
        XCTAssertEqual(paused.lifecycle().status, .pausedOnBooth, "A paused prepaid booth is not 'No Event Configured'")
        XCTAssertTrue(paused.server.calls.isEmpty, "Prepaid never needs the payments server")
    }

    func testServerActiveButLocalAdmissionPausedIsPausedOnThisIPad() async throws {
        let booth = try upgradedPaidBooth(blocked: true); defer { booth.cleanup() }
        let lifecycle = booth.lifecycle()
        await lifecycle.refresh()
        XCTAssertEqual(lifecycle.status, .pausedOnBooth)
        let recorded = await lifecycle.recordUpgradedRun()
        XCTAssertTrue(recorded, lifecycle.message)
        XCTAssertEqual(booth.runs.current?.status, .paused, "A paused booth gets a paused run so Resume keeps its identity")
        XCTAssertTrue(booth.acceptance.state.blocked, "Recording a run never reopens admission")
        XCTAssertEqual(booth.runs.occurrencePlan(for: booth.appliedContext), .resumePaused(runID: booth.runs.current!.id))
    }

    func testServerPausedEndedDraftAndMissingEventsAreNeverAcceptingOrUnconfigured() async throws {
        for (lifecycleState, expectPaused) in [(CommercialEventLifecycle.paused, true), (.ended, false), (.archived, false), (.draft, false)] {
            let booth = try upgradedPaidBooth(lifecycle: lifecycleState); defer { booth.cleanup() }
            let lifecycle = booth.lifecycle()
            await lifecycle.refresh()
            if expectPaused { XCTAssertEqual(lifecycle.status, .serverPaused) }
            else if case .needsReview = lifecycle.status {} else { XCTFail("\(lifecycleState): \(lifecycle.status)") }
            if lifecycleState != .paused {
                let recorded = await lifecycle.recordUpgradedRun()
                XCTAssertFalse(recorded, "\(lifecycleState): no run for an event that isn't running")
                XCTAssertNil(booth.runs.current)
            }
        }
        // Server ended while the iPad was offline; the admission barrier is stale but the status is not success.
        let stale = try upgradedPaidBooth(lifecycle: .ended); defer { stale.cleanup() }
        let lifecycle = stale.lifecycle()
        await lifecycle.refresh()
        XCTAssertNotEqual(lifecycle.status, .accepting)
        XCTAssertFalse(lifecycle.status.title.contains("No Event"))
    }

    func testConnectionUnavailableIsUnconfirmedAndRecordsNothing() async throws {
        let booth = try upgradedPaidBooth(); defer { booth.cleanup() }
        let lifecycle = EventLifecycleCoordinator(runs: booth.runs, acceptance: booth.acceptance, api: { throw PaymentsAPIError.unavailable },
            authorized: { true }, blockingReason: { nil }, recoveryReason: { nil }, source: { .serverManaged }, loadLocal: { booth.local }, saveLocal: { _ in },
            binding: { booth.binding }, appliedContext: { booth.appliedContext }, hasUnsavedSetup: { false }, makeSetup: { booth.setup() })
        await lifecycle.refresh()
        guard case .unconfirmed = lifecycle.status else { return XCTFail("\(lifecycle.status)") }
        let recorded = await lifecycle.recordUpgradedRun()
        XCTAssertFalse(recorded)
        XCTAssertNil(booth.runs.current)
    }

    func testWrongEnvironmentOrAccountNeedsReview() async throws {
        // Admission was committed on another payments connection (TEST vs LIVE).
        let other = try upgradedPaidBooth(); defer { other.cleanup() }
        try other.acceptance.save(.init(blocked: false, eventID: "live-event", serverBinding: "test:https://other.example", mode: .serverManaged))
        let lifecycle = other.lifecycle()
        XCTAssertNil(lifecycle.linkedCommercialEventID, "Never checks or attaches an event from another environment")
        guard case .needsReview = lifecycle.status else { return XCTFail("\(lifecycle.status)") }
        XCTAssertFalse(lifecycle.canRecordUpgradedRun)

        // Same connection, but the event isn't in this account (404 from the server).
        let account = try upgradedPaidBooth(); defer { account.cleanup() }
        account.server.events.removeAll()
        let check = account.lifecycle()
        await check.refresh()
        XCTAssertEqual(check.status, .needsReview(EventStatusModel.notFoundReason))
        let recorded = await check.recordUpgradedRun()
        XCTAssertFalse(recorded)
    }

    func testInterruptedBootstrapRetriesAfterRelaunchAndNeverDuplicates() async throws {
        let booth = try upgradedPaidBooth(); defer { booth.cleanup() }
        booth.runWriteFails = true
        let failed = await booth.lifecycle().recordUpgradedRun()
        XCTAssertFalse(failed)
        XCTAssertNil(booth.runs.current, "A failed atomic write leaves no partial run")
        booth.runWriteFails = false
        booth.relaunch()
        let lifecycle = booth.lifecycle()
        await lifecycle.refresh()
        XCTAssertEqual(lifecycle.status, .accepting, "Still accurately accepting after the interruption")
        let recorded = await lifecycle.recordUpgradedRun()
        XCTAssertTrue(recorded, lifecycle.message)
        let run = try XCTUnwrap(booth.runs.current)
        XCTAssertEqual(run.recordedAfterUpgrade, true)
        XCTAssertEqual(run.context.commercialEventID, "live-event")
        XCTAssertEqual(run.context.serverBinding, booth.binding)
        // Repeat, and repeat after relaunch: same single run.
        let again = await lifecycle.recordUpgradedRun()
        XCTAssertFalse(again)
        booth.relaunch()
        let relaunched = await booth.lifecycle().recordUpgradedRun()
        XCTAssertFalse(relaunched)
        XCTAssertEqual(booth.runs.runs.map(\.id), [run.id])
        XCTAssertEqual(try booth.runs.recordUpgradedRun(context: booth.appliedContext, paused: false).id, run.id, "The store-level step is idempotent too")
        XCTAssertThrowsError(try booth.runs.recordUpgradedRun(context: EventRunContext(designID: nil, commercialEventID: "other", serverBinding: booth.binding, name: "x"), paused: false),
                             "A different identity never replaces the recorded run")
    }

    func testFirstGuestAfterBootstrapUsesTheRecordedRunAndStatusStaysAccepting() async throws {
        let booth = try upgradedPaidBooth(); defer { booth.cleanup() }
        let lifecycle = booth.lifecycle()
        let recorded = await lifecycle.recordUpgradedRun()
        XCTAssertTrue(recorded, lifecycle.message)
        let run = try XCTUnwrap(booth.runs.current)
        let admitted = try await booth.admitGuest(session: "first-guest")
        XCTAssertEqual(admitted, run.id)
        XCTAssertEqual(booth.runs.runs.count, 1)
        await lifecycle.refresh()
        XCTAssertEqual(lifecycle.status, .accepting)
        XCTAssertFalse(lifecycle.canRecordUpgradedRun)
    }

    func testFirstGuestWithoutBootstrapKeepsTheEstablishedUpgradePath() async throws {
        let booth = try upgradedPaidBooth(); defer { booth.cleanup() }
        let admitted = try await booth.admitGuest(session: "guest")
        let run = try XCTUnwrap(booth.runs.current)
        XCTAssertEqual(admitted, run.id)
        XCTAssertEqual(run.recordedAfterUpgrade, true)
        let recorded = await booth.lifecycle().recordUpgradedRun()
        XCTAssertFalse(recorded, "An existing run is never duplicated")
        XCTAssertEqual(booth.runs.runs.count, 1)
    }

    func testBootstrapChangesOnlyTheRunManifestAndKeepsHistory() async throws {
        let booth = try upgradedPaidBooth(); defer { booth.cleanup() }
        // An earlier, operator-created historical record and an admission/barrier/library state.
        let earlier = try booth.runs.createHistoricalRun(name: "June Wedding", designID: nil, startedAt: Date(timeIntervalSinceNow: -86_400 * 30), endedAt: Date(timeIntervalSinceNow: -86_400 * 29))
        let acceptanceBefore = booth.acceptance.state, libraryBefore = booth.library.library, localBefore = booth.local, sourceBefore = booth.source
        let lifecycle = booth.lifecycle()
        let recorded = await lifecycle.recordUpgradedRun()
        XCTAssertTrue(recorded, lifecycle.message)
        XCTAssertEqual(booth.acceptance.state, acceptanceBefore)
        XCTAssertEqual(booth.library.library, libraryBefore)
        XCTAssertEqual(booth.local, localBefore)
        XCTAssertEqual(booth.source, sourceBefore)
        XCTAssertEqual(booth.runs.runs.first { $0.id == earlier.id }, earlier, "Historical records are unchanged")
        XCTAssertEqual(booth.runs.runs.count, 2)
        XCTAssertNil(booth.runs.current?.recordedAfterUpgrade, "Not the install's first run, so it isn't flagged as one")
        XCTAssertTrue(try EventRunStore.loadSessions(directory: booth.runs.directory).isEmpty, "No session is assigned to the new run")
    }

    func testCorruptedRunHistoryBlocksBootstrapAndKeepsTheFile() async throws {
        let booth = try upgradedPaidBooth(); defer { booth.cleanup() }
        try FileManager.default.createDirectory(at: booth.runs.directory, withIntermediateDirectories: true)
        let file = booth.runs.directory.appendingPathComponent("runs.json")
        try Data("{not json".utf8).write(to: file)
        booth.relaunch()
        let lifecycle = booth.lifecycle()
        guard case .recoveryRequired = lifecycle.status else { return XCTFail("\(lifecycle.status)") }
        XCTAssertFalse(lifecycle.canRecordUpgradedRun)
        let recorded = await lifecycle.recordUpgradedRun()
        XCTAssertFalse(recorded)
        XCTAssertEqual(manifestBytes(booth), Data("{not json".utf8), "The unreadable original is preserved")
    }

    func testUnauthorizedOperatorCannotRecordARun() async throws {
        let booth = try upgradedPaidBooth(); defer { booth.cleanup() }
        booth.permitted = false
        let recorded = await booth.lifecycle().recordUpgradedRun()
        XCTAssertFalse(recorded)
        XCTAssertNil(booth.runs.current)
    }

    func testOpenAdmissionWithNoCommittedPaidEventNeedsReview() {
        let context = EventRunContext(designID: nil, commercialEventID: nil, serverBinding: nil, name: "")
        let status = EventStatusModel.derive(.init(run: nil, appliedContext: context, barrierBlocked: false, acceptanceEventID: nil, acceptanceBinding: nil, binding: "b",
            source: .serverManaged, localPrepaidReady: false, commercial: .notNeeded, recoveryReason: nil, storageErrors: [], pendingTransition: nil, hasUnsavedSetup: false, operation: nil))
        guard case .needsReview = status else { return XCTFail("Ambiguous identity is shown as Needs Operator Review, got \(status)") }
    }
}
