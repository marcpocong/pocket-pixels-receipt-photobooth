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

    func testUnresolvedCheckoutNeedsReviewWithOrWithoutARun() {
        let context = EventRunContext(designID: nil, commercialEventID: "e", serverBinding: "b", name: "Gala")
        let check = CommercialCheckState.confirmed(.init(eventID: "e", lifecycle: .active, isAccountActiveEvent: true, checkedAt: Date()))
        func status(run: EventRunRecord?, source: CommercialPolicySource = .serverManaged) -> EventOperatorStatus {
            EventStatusModel.derive(.init(run: run, appliedContext: source == .serverManaged ? context : EventRunContext(designID: nil, commercialEventID: nil, serverBinding: nil, name: ""),
                barrierBlocked: false, acceptanceEventID: source == .serverManaged ? "e" : nil, acceptanceBinding: "b", binding: "b", source: source, localPrepaidReady: true,
                commercial: source == .serverManaged ? check : .notNeeded, recoveryReason: "Resolve interrupted checkouts in Payment Recovery before changing operation.",
                storageErrors: [], pendingTransition: nil, hasUnsavedSetup: false, operation: nil))
        }
        let run = EventRunRecord(id: "r", context: context, createdAt: Date(), status: .active)
        XCTAssertEqual(status(run: run), status(run: nil), "Recording a run never changes what an unresolved checkout means")
        guard case .needsReview = status(run: nil) else { return XCTFail("paid, no run") }
        guard case .needsReview = status(run: nil, source: .localPrepaid) else { return XCTFail("prepaid, no run") }
    }

    func testOpenAdmissionWithNoCommittedPaidEventNeedsReview() {
        let context = EventRunContext(designID: nil, commercialEventID: nil, serverBinding: nil, name: "")
        let status = EventStatusModel.derive(.init(run: nil, appliedContext: context, barrierBlocked: false, acceptanceEventID: nil, acceptanceBinding: nil, binding: "b",
            source: .serverManaged, localPrepaidReady: false, commercial: .notNeeded, recoveryReason: nil, storageErrors: [], pendingTransition: nil, hasUnsavedSetup: false, operation: nil))
        guard case .needsReview = status else { return XCTFail("Ambiguous identity is shown as Needs Operator Review, got \(status)") }
    }
}

/// P1: a paid-event creation can't silently produce duplicate commercial events, and an
/// interrupted creation is recovered by exact identity.
@MainActor final class CommercialEventCreationRecoveryTests: XCTestCase {
    private func paidSetup(_ booth: Booth) async -> SessionSetupCoordinator {
        let setup = booth.setup()
        await setup.choosePayment(.qrOnly)
        return setup
    }
    private func designCount(_ booth: Booth) -> Int { booth.library.library.events.count }

    func testLostCreateResponseNeverCreatesASecondEventAndRecoversByExactIdentity() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let setup = await paidSetup(booth)
        booth.server.loseCreateResponse = true
        await setup.createEvent(name: "Gala Night", venue: "Ballroom")
        XCTAssertEqual(booth.server.events.count, 1, "The server committed the create")
        let pending = try XCTUnwrap(setup.pendingCreation, setup.message)
        XCTAssertEqual(pending.state, .requested)
        XCTAssertNil(setup.design?.serverEventID(binding: booth.binding), "Nothing is linked from a lost response")
        XCTAssertTrue(setup.validation?.contains("Confirm") == true, setup.validation ?? "")

        // Duplicate operator actions can't create another event while it is unresolved.
        await setup.connectPaidCheckout()
        await setup.connectPaidCheckout()
        XCTAssertEqual(booth.server.mutations("create"), 1)
        XCTAssertEqual(booth.server.events.count, 1)

        await setup.checkOriginalCreation()
        XCTAssertEqual(setup.pendingCreation?.state, .created, setup.message)
        XCTAssertEqual(setup.pendingCreation?.eventID, "srv-1")
        await setup.completeCreationLinking()
        XCTAssertNil(setup.pendingCreation, setup.message)
        XCTAssertEqual(booth.library.design(id: setup.design?.id)?.serverEventID(binding: booth.binding), "srv-1")
        XCTAssertEqual(booth.server.events.count, 1, "Exactly one commercial event")
        XCTAssertEqual(booth.creations.intents.map(\.state), [.linked])
    }

    func testSameOperationIDReplaysAndDifferentPayloadFails() async throws {
        let server = LifecycleServerStub()
        let first = try await server.createEvent(name: "Gala", venue: "Hall", operationID: "op-1")
        let again = try await server.createEvent(name: "Gala", venue: "Hall", operationID: "op-1")
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(again.replayed, true)
        do { _ = try await server.createEvent(name: "Other", venue: "Hall", operationID: "op-1"); XCTFail("payload mismatch must fail") }
        catch let error as PaymentsAPIError { XCTAssertEqual(error.code, "idempotency_mismatch"); XCTAssertTrue(error.provesNoMutation) }
        XCTAssertEqual(server.events.count, 1)
    }

    func testCrashAfterServerCreationBeforeLocalLinkingResumesAfterRelaunch() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let setup = await paidSetup(booth)
        booth.server.detailUnreachableOnce = true   // the create answered; the verification read failed
        await setup.createEvent(name: "Gala Night", venue: "Ballroom")
        XCTAssertEqual(setup.pendingCreation?.state, .created, setup.message)
        let designID = try XCTUnwrap(setup.design?.id)
        booth.relaunch()
        let resumed = booth.setup()
        let pending = try XCTUnwrap(resumed.pendingCreation, "The durable intent survives relaunch")
        XCTAssertEqual(pending.eventID, "srv-1")
        await resumed.completeCreationLinking()
        XCTAssertNil(resumed.pendingCreation, resumed.message)
        XCTAssertEqual(booth.library.design(id: designID)?.serverEventID(binding: booth.binding), "srv-1")
        await resumed.completeCreationLinking()   // repeat is a no-op
        XCTAssertEqual(booth.server.mutations("create"), 1)
    }

    func testIntentWriteFailureSendsNothing() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let setup = await paidSetup(booth)
        booth.creationWriteFails = true
        await setup.createEvent(name: "Gala Night", venue: "Ballroom")
        XCTAssertEqual(booth.server.mutations("create"), 0, "No request without a durable operation ID")
        XCTAssertTrue(booth.server.events.isEmpty)
        XCTAssertNil(setup.pendingCreation)
        XCTAssertEqual(designCount(booth), 1, "The saved design is kept")
    }

    func testUnpairedIPadSendsNothingAndRecordsNoCreation() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let setup = SessionSetupCoordinator(workspace: booth.workspace, acceptance: booth.acceptance, library: booth.library, eventRuns: booth.runs, creations: booth.creations,
            api: { throw SetupFailure("Pair this iPad first.") }, authorized: { true }, blockingReason: { nil }, loadLocal: { booth.local }, saveLocal: { booth.local = $0 },
            source: { booth.source }, saveSource: { booth.source = $0 }, currentProfile: { booth.profile }, applyProfile: { booth.profile = $0 }, artworkAvailable: { _ in false })
        await setup.choosePayment(.qrOnly)
        await setup.createEvent(name: "Gala Night", venue: "Ballroom")
        XCTAssertTrue(booth.creations.intents.isEmpty, "Nothing was sent, so nothing needs confirmation")
        XCTAssertNil(setup.pendingCreation)
    }

    func testDefinitiveRejectionClosesTheRequestAndAllowsARetry() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let setup = await paidSetup(booth)
        booth.server.createFailsBeforeCommit = .rejected(code: "required_text_missing", message: "Missing", status: 422, details: Data())
        await setup.createEvent(name: "Gala Night", venue: "Ballroom")
        XCTAssertNil(setup.pendingCreation, "A 4xx refusal proves nothing was created")
        XCTAssertEqual(booth.creations.intents.first?.state, .notCreated)
        await setup.refresh()
        await setup.connectPaidCheckout()
        XCTAssertNil(setup.pendingCreation, setup.message)
        XCTAssertEqual(booth.server.events.count, 1)
    }

    func testRequestThatNeverArrivedIsConfirmedNotCreatedThenRetried() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let setup = await paidSetup(booth)
        booth.server.createFailsBeforeCommit = .outcomeUnknown   // timeout: did it arrive? unknown
        await setup.createEvent(name: "Gala Night", venue: "Ballroom")
        XCTAssertEqual(setup.pendingCreation?.state, .requested, "A timeout stays unresolved")
        await setup.checkOriginalCreation()
        XCTAssertNil(setup.pendingCreation, setup.message)
        XCTAssertEqual(booth.creations.intents.first?.state, .notCreated)
        await setup.connectPaidCheckout()
        XCTAssertEqual(booth.server.events.count, 1)
        XCTAssertEqual(booth.library.design(id: setup.design?.id)?.serverEventID(binding: booth.binding), "srv-1")
    }

    func testOlderWorkerWithoutLookupFallsBackToExplicitAuditedDraftSelection() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        booth.server.supportsCreationIdempotency = false
        let setup = await paidSetup(booth)
        booth.server.loseCreateResponse = true
        await setup.createEvent(name: "Gala Night", venue: "Ballroom")
        await setup.checkOriginalCreation()
        XCTAssertEqual(setup.pendingCreation?.state, .requested, "No guess is made")
        XCTAssertTrue(setup.message.contains("can't look up"), setup.message)
        await setup.refresh()
        XCTAssertEqual(setup.draftCandidatesForCreation.map(\.id), ["srv-1"])
        await setup.useDraftForPendingCreation("srv-1", reason: "   ")
        XCTAssertNotNil(setup.pendingCreation, "A reason is required")
        await setup.useDraftForPendingCreation("srv-1", reason: "Only draft created at 10:02; confirmed on dashboard")
        XCTAssertNil(setup.pendingCreation, setup.message)
        let record = try XCTUnwrap(booth.creations.intents.first)
        XCTAssertEqual(record.state, .linked)
        XCTAssertTrue(record.resolution?.hasPrefix("operator-selected:") == true, "Recorded as the operator's decision, not an exact match")
        XCTAssertEqual(booth.server.events.count, 1)
    }

    func testAbandoningRequiresAReasonAndKeepsTheDraft() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let setup = await paidSetup(booth)
        booth.server.loseCreateResponse = true
        await setup.createEvent(name: "Gala Night", venue: "Ballroom")
        setup.abandonPendingCreation(reason: "")
        XCTAssertNotNil(setup.pendingCreation)
        setup.abandonPendingCreation(reason: "Owner will use a different event")
        XCTAssertNil(setup.pendingCreation)
        XCTAssertEqual(booth.creations.intents.first?.state, .superseded)
        XCTAssertNotNil(booth.server.events["srv-1"], "Nothing on the server is deleted")
    }

    func testCreationOnAnotherConnectionIsNeverAttachedHere() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        try booth.creations.begin(.init(id: "op-live", serverBinding: "live:https://payments.example", purpose: .regularSessions,
                                        name: "Regular Sessions", venue: "", createdAt: Date(), state: .requested))
        let setup = await paidSetup(booth)
        XCTAssertNil(setup.pendingCreation, "Belongs to LIVE; this booth is on another connection")
        XCTAssertEqual(setup.creationsElsewhere.map(\.id), ["op-live"])
        await setup.checkOriginalCreation()
        await setup.completeCreationLinking()
        XCTAssertFalse(booth.server.calls.contains { $0.hasPrefix("lookup:") }, "Never looked up on the wrong server")
        await setup.createEvent(name: "Gala Night", venue: "Ballroom")
        XCTAssertEqual(booth.server.events.count, 1, "This connection isn't blocked by another environment's request")
        XCTAssertEqual(booth.creations.intent(id: "op-live")?.state, .requested, "The LIVE request stays for LIVE")
    }

    func testConcurrentDuplicateTapsCreateOneEvent() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let setup = await paidSetup(booth)
        let saved = try booth.library.create(name: "Gala Night", venue: "Ballroom")
        await setup.chooseDesign(saved.id)
        async let first: Void = setup.connectPaidCheckout()
        async let second: Void = setup.connectPaidCheckout()
        _ = await (first, second)
        XCTAssertEqual(booth.server.mutations("create"), 1)
    }

    func testCorruptedCreationJournalBlocksNewCreationsAndIsPreserved() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let file = booth.directory.appendingPathComponent("EventCreationV1/intents.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: file)
        booth.relaunch()
        let setup = await paidSetup(booth)
        await setup.createEvent(name: "Gala Night", venue: "Ballroom")
        XCTAssertEqual(booth.server.mutations("create"), 0)
        XCTAssertEqual(try Data(contentsOf: file), Data("garbage".utf8))
    }

    func testLostResponseWhileStartingNewPaidOccurrenceRecoversWithoutReassigningHistory() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let setup = await paidSetup(booth)
        await setup.createEvent(name: "Gala Night", venue: "Ballroom")
        setup.policy.priceText = "75"
        let started = await setup.startAccepting()
        XCTAssertTrue(started, setup.message)
        let runA = try XCTUnwrap(booth.runs.current)
        let oldEvent = try XCTUnwrap(runA.context.commercialEventID)
        _ = await booth.lifecycle().end(scope: .thisBoothAndCommercialEvent)

        let reuse = booth.setup()
        await reuse.setEventMode(true)
        await reuse.chooseDesign(try XCTUnwrap(runA.context.designID))
        await reuse.choosePayment(.qrOnly)
        await reuse.refresh()
        XCTAssertTrue(reuse.canStartNewPaidOccurrence)
        booth.server.loseCreateResponse = true
        await reuse.startNewPaidOccurrence()
        XCTAssertNotNil(reuse.pendingCreation, reuse.message)
        XCTAssertEqual(booth.library.design(id: runA.context.designID)?.serverEventID(binding: booth.binding), oldEvent, "Not relinked from a lost response")
        await reuse.startNewPaidOccurrence()
        XCTAssertEqual(booth.server.mutations("create"), 2, "One original create, one occurrence create — no duplicate")
        await reuse.checkOriginalCreation()
        await reuse.completeCreationLinking()
        XCTAssertNil(reuse.pendingCreation, reuse.message)
        let design = try XCTUnwrap(booth.library.design(id: runA.context.designID))
        XCTAssertEqual(design.serverEvents[booth.binding], "srv-2")
        XCTAssertEqual(design.retiredServerEvents?[booth.binding], [oldEvent])
        XCTAssertEqual(booth.runs.runs.first { $0.id == runA.id }?.context.commercialEventID, oldEvent, "Old run keeps its commercial identity")
        XCTAssertEqual(booth.server.events[oldEvent]?.lifecycle, .ended)
    }
}

/// P1: a new occurrence goes through the reviewed lifecycle; statistics are never reset in place.
@MainActor final class OccurrenceBoundaryTests: XCTestCase {
    private func startPaid(_ booth: Booth) async throws -> SessionSetupCoordinator {
        let setup = booth.setup()
        await setup.choosePayment(.qrOnly)
        await setup.createEvent(name: "Gala Night", venue: "Ballroom")
        setup.policy.priceText = "50"
        let started = await setup.startAccepting()
        XCTAssertTrue(started, setup.message)
        return setup
    }
    private func order(_ id: String, session: String, centavos: Int) -> OperatorOrderRow {
        OperatorOrderRow(id: id, createdAt: Date(), boothFormat: "solo", copies: 1, totalCentavos: centavos, state: "COMPLETED", method: "QRPH", paymentState: "PAID_VERIFIED",
                         category: "QRPH_VERIFIED_LIVE", entitlementState: "CONSUMED", confirmedPrints: 1, uncertainPrints: 0, lastReconcileError: nil, checkoutSessionId: session)
    }

    func testRunningEventCannotBeResetFromSetupWithoutEndingIt() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let setup = try await startPaid(booth)
        let run = try XCTUnwrap(booth.runs.current)
        XCTAssertEqual(setup.occurrencePlan, .continueActive(runID: run.id))
        setup.startsNewOccurrence = true   // ignored for a running occurrence
        let again = await setup.startAccepting()
        XCTAssertTrue(again, setup.message)
        XCTAssertEqual(booth.runs.runs.map(\.id), [run.id], "Restarting the same setup never creates fresh statistics")
    }

    func testNewOccurrenceSharingACommercialEventKeepsRevenueSeparatePerRun() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = try await startPaid(booth)
        let runA = try XCTUnwrap(booth.runs.current)
        let eventID = try XCTUnwrap(runA.context.commercialEventID)
        _ = try await booth.admitGuest(session: "morning-1")
        booth.runs.updateSession(id: "morning-1") { $0.orderIDs = ["order-1"] }
        // End on this iPad only: the paid event stays open (e.g. for other booths or an evening shift).
        let ended = await booth.lifecycle().end(scope: .thisBooth)
        XCTAssertTrue(ended)
        XCTAssertEqual(booth.server.events[eventID]?.lifecycle, .active, "This-iPad end never changes the paid event")

        let next = booth.setup()
        await next.setEventMode(true)
        await next.chooseDesign(try XCTUnwrap(runA.context.designID))
        await next.choosePayment(.qrOnly)
        await next.refresh()
        XCTAssertEqual(next.occurrencePlan, .requiresNewOccurrence(previousRunID: runA.id))
        next.startsNewOccurrence = true
        let started = await next.startAccepting()
        XCTAssertTrue(started, next.message)
        let runB = try XCTUnwrap(booth.runs.current)
        XCTAssertEqual(runB.previousRunID, runA.id)
        XCTAssertEqual(runB.context.commercialEventID, eventID, "The same commercial event, deliberately shared")
        _ = try await booth.admitGuest(session: "evening-1")
        booth.runs.updateSession(id: "evening-1") { $0.orderIDs = ["order-2"] }

        let all = try EventRunStore.loadSessions(directory: booth.runs.directory)
        let rows = [order("order-1", session: "morning-1", centavos: 5000), order("order-2", session: "evening-1", centavos: 7500), order("order-x", session: "other-ipad", centavos: 9900)]
        let totalsA = try EventRunFinancialTotals(orders: EventRunFinancialTotals.matchingOrders(rows, sessions: all.filter { $0.runID == runA.id }))
        let totalsB = try EventRunFinancialTotals(orders: EventRunFinancialTotals.matchingOrders(rows, sessions: all.filter { $0.runID == runB.id }))
        XCTAssertEqual(totalsA.verifiedLive, 5000)
        XCTAssertEqual(totalsB.verifiedLive, 7500)
        XCTAssertEqual(CommercialAttribution.unmatchedOrders(rows, allSessions: all).map(\.id), ["order-x"], "Shown, never allocated")
        XCTAssertEqual(all.first { $0.sessionID == "morning-1" }?.runID, runA.id, "Sessions never move between runs")
    }

    func testSwitchingPaidEventsCompletesThePreviousRunAndKeepsItsIdentity() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = try await startPaid(booth)
        let runA = try XCTUnwrap(booth.runs.current)
        _ = await booth.lifecycle().end(scope: .thisBoothAndCommercialEvent)
        let second = booth.setup()
        await second.createEvent(name: "Second Event", venue: "Garden")
        second.policy.priceText = "60"
        let started = await second.startAccepting()
        XCTAssertTrue(started, second.message)
        let runB = try XCTUnwrap(booth.runs.current)
        XCTAssertNotEqual(runB.context.commercialEventID, runA.context.commercialEventID)
        XCTAssertNil(runB.previousRunID, "A different design is a different event, not a follow-on occurrence")
        XCTAssertEqual(booth.runs.runs.first { $0.id == runA.id }?.status, .completed)
        XCTAssertEqual(booth.runs.runs.first { $0.id == runA.id }?.context, runA.context)
    }

    func testCrashBetweenAdmissionClosureAndRunTransitionStaysClosedAndRecovers() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = try await startPaid(booth)
        let run = try XCTUnwrap(booth.runs.current)
        booth.runWriteFails = true
        let ended = await booth.lifecycle().end(scope: .thisBooth)
        XCTAssertFalse(ended)
        XCTAssertTrue(booth.acceptance.state.blocked, "Admission closed first and stays closed")
        booth.runWriteFails = false
        booth.relaunch()
        XCTAssertEqual(booth.runs.current?.status, .active, "The run write never happened")
        let lifecycle = booth.lifecycle()
        await lifecycle.refresh()
        XCTAssertEqual(lifecycle.status, .pausedOnBooth, "Guests can't start; the status says so")
        do { _ = try await booth.admitGuest(); XCTFail("admission must stay closed") } catch {}
        let retried = await lifecycle.end(scope: .thisBooth)
        XCTAssertTrue(retried, lifecycle.message)
        XCTAssertNil(booth.runs.current)
        XCTAssertEqual(booth.runs.runs.first { $0.id == run.id }?.status, .completed)
        XCTAssertEqual(lifecycle.status, .regular)
    }

    func testPausedOccurrenceResumesWithTheSameRun() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = try await startPaid(booth)
        let run = try XCTUnwrap(booth.runs.current)
        let lifecycle = booth.lifecycle()
        await lifecycle.pauseBooth()
        XCTAssertEqual(booth.runs.current?.status, .paused)
        let resumed = await lifecycle.resume()
        XCTAssertTrue(resumed, lifecycle.message)
        XCTAssertEqual(booth.runs.current?.id, run.id)
        XCTAssertEqual(booth.runs.runs.count, 1)
    }
}

/// P1: precise, atomic, audited historical attribution.
@MainActor final class HistoricalAttributionBatchTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("attribution-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private let day = Date(timeIntervalSince1970: 1_750_000_000)

    private func archive(_ id: String, minutes: Double, name: String? = nil, run: String? = nil) -> RecentSessionArchiveSummary {
        RecentSessionArchiveSummary(archiveID: id, sessionIdentifier: "session-\(id)", createdAt: day.addingTimeInterval(minutes * 60), format: .solo, eventName: name,
            eventLocation: nil, photoCount: 1, receiptWidth: 576, receiptHeight: 900, estimatedLengthMillimeters: 100, rasterFingerprint: String(repeating: "a", count: 64),
            thumbnailFilenames: [], lastReprintedAt: nil, reprintCount: 0, payloadSizeBytes: 1, eventRunID: run)
    }
    private func runs() -> EventRunStore { EventRunStore(directory: root.appendingPathComponent("runs"), authorized: { true }, blockingReason: { nil }) }
    private func journal(fails: @escaping () -> Bool = { false }) -> LegacyAttributionStore {
        LegacyAttributionStore(directory: root.appendingPathComponent("runs"), writer: { data, url in
            if fails() { throw CocoaError(.fileWriteOutOfSpace) }
            try DurableFileWriter.write(data, to: url)
        }, authorized: { true })
    }

    func testTwoEventsOnTheSameDayAreAttributedSeparatelyBySelection() throws {
        let store = runs(), attributions = journal()
        let morning = [archive("m1", minutes: 600, name: "Wedding"), archive("m2", minutes: 640, name: "Wedding")]
        let evening = [archive("e1", minutes: 1100, name: "Debut"), archive("e2", minutes: 1150, name: "Debut")]
        let all = morning + evening
        let before = HistoricalActivityReport(archives: all, sessions: [], runs: store.runs, attributions: [], printEntries: [])
        XCTAssertEqual(before.unassigned.count, 1, "One calendar day")
        XCTAssertEqual(before.unassigned.first?.archives.count, 4)

        let wedding = try store.createHistoricalRun(name: "Wedding", designID: nil, startedAt: morning[0].createdAt, endedAt: morning[1].createdAt)
        try attributions.attribute(morning, to: wedding, knownRuns: store.runs, note: "Guest list", exact: [])
        var report = HistoricalActivityReport(archives: all, sessions: [], runs: store.runs, attributions: attributions.attributions, printEntries: [])
        XCTAssertEqual(report.attributedByRun[wedding.id], 2)
        XCTAssertEqual(report.unassigned.flatMap(\.archives).map(\.archiveID).sorted(), ["e1", "e2"], "Unselected sessions on the same day stay unassigned")

        let debut = try store.createHistoricalRun(name: "Debut", designID: nil, startedAt: evening[0].createdAt, endedAt: evening[1].createdAt)
        try attributions.attribute([evening[0]], to: debut, knownRuns: store.runs, note: "Photographer's notes", exact: [])
        report = HistoricalActivityReport(archives: all, sessions: [], runs: store.runs, attributions: attributions.attributions, printEntries: [])
        XCTAssertEqual(report.attributedByRun[debut.id], 1, "Partial selection")
        XCTAssertEqual(report.unassignedCount, 1)
        XCTAssertTrue(report.exactByRun.isEmpty, "Operator attribution never becomes an exact identity")
    }

    func testFailedBatchWriteAttributesNothing() throws {
        let store = runs()
        var failing = true
        let attributions = journal { failing }
        let run = try store.createHistoricalRun(name: "Gala", designID: nil, startedAt: day, endedAt: day.addingTimeInterval(7200))
        XCTAssertThrowsError(try attributions.attribute([archive("a", minutes: 1), archive("b", minutes: 2)], to: run, knownRuns: store.runs, note: "Owner", exact: []))
        XCTAssertTrue(attributions.attributions.isEmpty)
        XCTAssertTrue(journal().attributions.isEmpty, "Nothing on disk after relaunch")
        failing = false
        try attributions.attribute([archive("a", minutes: 1), archive("b", minutes: 2)], to: run, knownRuns: store.runs, note: "Owner", exact: [])
        XCTAssertEqual(journal().attributions.count, 2)
    }

    func testOneInvalidItemRejectsTheWholeBatch() throws {
        let store = runs(), attributions = journal()
        let run = try store.createHistoricalRun(name: "Gala", designID: nil, startedAt: day, endedAt: day.addingTimeInterval(7200))
        try attributions.attribute([archive("done", minutes: 5)], to: run, knownRuns: store.runs, note: "First pass", exact: [])
        let snapshot = attributions.attributions
        let cases: [(String, [RecentSessionArchiveSummary], Set<String>)] = [
            ("already attributed", [archive("new-1", minutes: 6), archive("done", minutes: 5)], []),
            ("exact archive identity", [archive("new-1", minutes: 6), archive("exact", minutes: 7, run: "some-run")], []),
            ("exact journal identity", [archive("new-1", minutes: 6), archive("journal", minutes: 7)], ["session-journal"]),
            ("duplicate archive in batch", [archive("new-1", minutes: 6), archive("new-1", minutes: 6)], []),
            ("impossible future time", [archive("new-1", minutes: 6), archive("future", minutes: 60 * 24 * 365 * 50)], []),
        ]
        for (label, batch, exact) in cases {
            XCTAssertThrowsError(try attributions.attribute(batch, to: run, knownRuns: store.runs, note: "Retry", exact: exact), label)
            XCTAssertEqual(attributions.attributions, snapshot, "\(label): nothing partially applied")
        }
        XCTAssertThrowsError(try attributions.attribute([archive("new-1", minutes: 6)], to: run, knownRuns: store.runs, note: "   ", exact: []), "Reason required")
        let missing = EventRunRecord(id: "gone", context: run.context, createdAt: day, status: .completed, historical: true)
        XCTAssertThrowsError(try attributions.attribute([archive("new-1", minutes: 6)], to: missing, knownRuns: store.runs, note: "x", exact: []), "Unknown run identity")
        XCTAssertEqual(journal().attributions, snapshot, "Append-only journal unchanged on disk")
    }

    func testRealRunBoundsAreEnforcedButEarlierEventRecordsAreOperatorDefined() throws {
        let store = runs(), attributions = journal()
        let paid = EventRunRecord(id: "paid", context: EventRunContext(designID: nil, commercialEventID: "evt", serverBinding: "b", name: "Paid"),
                                  createdAt: day.addingTimeInterval(3600), status: .completed, endedAt: day.addingTimeInterval(7200))
        XCTAssertThrowsError(try attributions.validate([archive("before", minutes: 10)], to: paid, knownRuns: [paid], note: "x", exact: []), "Before a paid run started")
        XCTAssertThrowsError(try attributions.validate([archive("after", minutes: 200)], to: paid, knownRuns: [paid], note: "x", exact: []), "After the run ended")
        XCTAssertNoThrow(try attributions.validate([archive("inside", minutes: 90)], to: paid, knownRuns: [paid], note: "x", exact: []))
        let record = try store.createHistoricalRun(name: "Earlier", designID: nil, startedAt: day.addingTimeInterval(600), endedAt: day.addingTimeInterval(900))
        XCTAssertNoThrow(try attributions.validate([archive("outside-range", minutes: 1)], to: record, knownRuns: store.runs, note: "x", exact: []))
    }

    func testRepeatedSubmissionAndRelaunchKeepOneAuditedBatch() throws {
        let store = runs(), attributions = journal()
        let run = try store.createHistoricalRun(name: "Gala", designID: nil, startedAt: day, endedAt: day.addingTimeInterval(7200))
        let batch = [archive("a", minutes: 1), archive("b", minutes: 2), archive("c", minutes: 3)]
        let saved = try attributions.attribute(batch, to: run, knownRuns: store.runs, note: "Owner confirmed", exact: [])
        XCTAssertThrowsError(try attributions.attribute(batch, to: run, knownRuns: store.runs, note: "Owner confirmed", exact: []), "A double tap can't duplicate")
        let reloaded = journal()
        XCTAssertEqual(reloaded.attributions, saved)
        XCTAssertEqual(Set(reloaded.attributions.compactMap(\.batchID)).count, 1, "One confirmation for the whole batch")
        XCTAssertTrue(reloaded.attributions.allSatisfy { $0.note == "Owner confirmed" && $0.runID == run.id })
        let later = try attributions.attribute([archive("d", minutes: 4)], to: run, knownRuns: store.runs, note: "Second pass", exact: [])
        XCTAssertEqual(Array(journal().attributions.prefix(3)), saved, "Earlier entries are never rewritten")
        XCTAssertEqual(journal().attributions.last, later.first)
    }

    func testEarlierBuildJournalEntriesWithoutBatchIDStillDecode() throws {
        let directory = root.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = #"{"schemaVersion":1,"attributions":[{"id":"x","archiveID":"a","sessionID":"s","runID":"r","attributedAt":0,"note":"old"}]}"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("legacy-attributions.json"))
        let store = journal()
        XCTAssertNil(store.storageError)
        XCTAssertEqual(store.attributions.first?.note, "old")
        XCTAssertNil(store.attributions.first?.batchID)
    }
}
