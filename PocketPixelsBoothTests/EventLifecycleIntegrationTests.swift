import XCTest
import SwiftUI
@testable import PocketPixelsBooth

/// A synthetic Payments Worker with the real lifecycle rules: one active event per account,
/// version-checked transitions, ENDED is terminal, and injectable lost responses.
@MainActor final class LifecycleServerStub: SessionSetupAPI {
    struct Event { var name: String; var venue: String; var lifecycle: CommercialEventLifecycle; var version: Int; var latest: OperatorPolicyRevision?; var active: OperatorPolicyRevision? }
    var events: [String: Event] = [:]
    var calls: [String] = []
    /// The mutation commits, then the response is lost.
    var loseResponseAfter: String?
    /// The request never reaches the server.
    var unreachableBefore: String?
    /// Another operator changes the event just before this request.
    var concurrentEditBefore: String?
    /// Creation idempotency as in Worker migration 0006: operation ID → (event, payload).
    var creationsByOperation: [String: (id: String, name: String, venue: String)] = [:]
    /// Simulates a Worker without migration 0006 / the lookup route.
    var supportsCreationIdempotency = true
    /// The create commits, then the response is lost (or the server answers 5xx after the insert).
    var loseCreateResponse = false
    var createFailsBeforeCommit: PaymentsAPIError?
    private var counter = 0

    @MainActor func listEvents() async throws -> [OperatorEventSummary] {
        calls.append("list")
        return events.sorted { $0.key < $1.key }.map { .init(id: $0.key, name: $0.value.name, venue: $0.value.venue, lifecycle: $0.value.lifecycle.rawValue,
                                                             activePolicyRevisionId: $0.value.active?.id, version: $0.value.version, updatedAt: Date()) }
    }
    /// The next event read fails in transit (e.g. the network drops right after a create).
    var detailUnreachableOnce = false
    @MainActor func eventDetail(id: String) async throws -> OperatorEventDetail {
        calls.append("detail:\(id)")
        if detailUnreachableOnce { detailUnreachableOnce = false; throw PaymentsAPIError.unavailable }
        guard let event = events[id] else { throw PaymentsAPIError.rejected(code: "not_found", message: "missing", status: 404, details: Data()) }
        return .init(event: .init(id: id, name: event.name, venue: event.venue, lifecycle: event.lifecycle, version: event.version, updatedAt: Date(), activePolicyRevisionId: event.active?.id),
                     activePolicy: event.active, latestRevision: event.latest, hasUnpublishedRevision: event.latest?.id != event.active?.id, outstandingEntitlements: 0, serverTime: Date())
    }
    @MainActor func createEvent(name: String, venue: String, operationID: String) async throws -> OperatorCreatedEvent {
        calls.append("create:\(name)")
        if let failure = createFailsBeforeCommit { createFailsBeforeCommit = nil; throw failure }
        if supportsCreationIdempotency, let prior = creationsByOperation[operationID] {
            guard prior.name == name, prior.venue == venue else { throw PaymentsAPIError.rejected(code: "idempotency_mismatch", message: "mismatch", status: 422, details: Data()) }
            return .init(id: prior.id, lifecycle: events[prior.id]?.lifecycle.rawValue ?? "DRAFT", version: events[prior.id]?.version, operationId: operationID, replayed: true)
        }
        counter += 1
        let id = "srv-\(counter)"
        events[id] = Event(name: name, venue: venue, lifecycle: .draft, version: 1, latest: nil, active: nil)
        if supportsCreationIdempotency { creationsByOperation[operationID] = (id, name, venue) }
        if loseCreateResponse { loseCreateResponse = false; throw PaymentsAPIError.outcomeUnknown }
        return .init(id: id, lifecycle: "DRAFT", version: 1, operationId: supportsCreationIdempotency ? operationID : nil, replayed: supportsCreationIdempotency ? false : nil)
    }
    @MainActor func eventCreation(operationID: String) async throws -> OperatorEventCreationLookup {
        calls.append("lookup:\(operationID)")
        guard supportsCreationIdempotency else { throw PaymentsAPIError.rejected(code: "not_found", message: "no route", status: 404, details: Data()) }
        guard let prior = creationsByOperation[operationID], let event = events[prior.id] else {
            throw PaymentsAPIError.rejected(code: "creation_not_found", message: "none", status: 404, details: Data())
        }
        return .init(operationId: operationID, event: .init(id: prior.id, name: event.name, venue: event.venue, lifecycle: event.lifecycle.rawValue, version: event.version))
    }
    @MainActor func saveDraft(eventID: String, expectedVersion: Int, name: String, venue: String, policy: ServerPolicyDraft.RequestBody) async throws -> OperatorEventUpdate {
        calls.append("save:\(eventID)")
        guard var event = events[eventID], event.version == expectedVersion else { throw conflict }
        guard ![.ended, .archived].contains(event.lifecycle) else { throw PaymentsAPIError.rejected(code: "event_not_editable", message: "closed", status: 409, details: Data()) }
        let revision = (event.latest?.revision ?? 0) + 1
        event.latest = .init(id: "\(eventID)-r\(revision)", revision: revision, commercialMode: .payPerPrint, unitPriceCentavos: policy.unitPriceCentavos,
                             maxCopies: policy.maxCopies, defaultCopies: policy.defaultCopies, cashEnabled: policy.cashEnabled, qrphEnabled: policy.qrphEnabled,
                             prepaidGuestCopyChoice: false, supportedFormats: policy.supportedFormats, offlineValidUntil: policy.offlineValidUntil, createdAt: Date(), activatedAt: nil)
        event.name = name; event.venue = venue; event.version += 1
        events[eventID] = event
        return .init(eventId: eventID, version: event.version, draftRevision: event.latest!)
    }
    @MainActor private var conflict: PaymentsAPIError { .rejected(code: "version_conflict", message: "changed", status: 409, details: Data()) }
    @MainActor func transitionEvent(id: String, action: String, expectedVersion: Int, policyRevisionID: String?, acknowledgedUnitPriceCentavos: Int?) async throws -> OperatorEventTransition {
        calls.append("\(action):\(id)")
        if unreachableBefore == action { unreachableBefore = nil; throw PaymentsAPIError.unavailable }
        if concurrentEditBefore == action { concurrentEditBefore = nil; events[id]?.version += 1 }
        guard var event = events[id], event.version == expectedVersion else { throw conflict }
        let allowed: [String: ([CommercialEventLifecycle], CommercialEventLifecycle?)] = [
            "activate": ([.draft], .active), "publish": ([.draft, .active, .paused], nil), "pause": ([.active], .paused),
            "resume": ([.paused], .active), "end": ([.active, .paused], .ended), "archive": ([.ended, .draft], .archived)]
        guard let rule = allowed[action], rule.0.contains(event.lifecycle) else { throw PaymentsAPIError.rejected(code: "invalid_transition", message: "no", status: 409, details: Data()) }
        if rule.1 == .active, events.contains(where: { $0.key != id && $0.value.lifecycle == .active }) { throw PaymentsAPIError.rejected(code: "another_active", message: "busy", status: 409, details: Data()) }
        if action == "activate" || action == "publish" { event.active = event.latest }
        if let next = rule.1 { event.lifecycle = next }
        event.version += 1
        events[id] = event
        if loseResponseAfter == action { loseResponseAfter = nil; throw PaymentsAPIError.outcomeUnknown }
        return .init(id: id, lifecycle: event.lifecycle.rawValue, activePolicyRevisionId: event.active?.id, version: event.version)
    }
    @MainActor func activeEvent() async throws -> ActiveEventResponse {
        calls.append("active")
        let match = events.first { $0.value.lifecycle == .active }
        let event: ServerEventPolicy? = match.flatMap { id, value in
            value.active.map { p in .init(id: id, name: value.name, venue: value.venue, lifecycle: .active, policyRevisionId: p.id, revision: p.revision,
                                          commercialMode: p.commercialMode, unitPriceCentavos: p.unitPriceCentavos, maxCopies: p.maxCopies, defaultCopies: p.defaultCopies,
                                          cashEnabled: p.cashEnabled, qrphEnabled: p.qrphEnabled, prepaidGuestCopyChoice: false, supportedFormats: p.supportedFormats,
                                          offlineValidUntil: p.offlineValidUntil) }
        }
        return .init(event: event, inactiveEvent: nil, offlinePolicy: nil, offlinePolicyStatus: nil, device: .init(id: "fixture", accountId: "fixture"), serverTime: Date())
    }
    func mutations(_ action: String) -> Int { calls.filter { $0.hasPrefix(action + ":") }.count }
}

/// One iPad's durable state in an isolated directory. `relaunch()` rebuilds every store from disk.
@MainActor final class Booth {
    let directory: URL
    let server: LifecycleServerStub
    var workspace: OperatorWorkspace
    var acceptance: SessionAcceptanceStore
    var library: EventDesignLibraryStore
    var runs: EventRunStore
    var creations: CommercialEventCreationStore
    var creationWriteFails = false
    var source = CommercialPolicySource.localPrepaid
    var local = CommercialEventRun.legacy
    var profile = EventProfile.pocketPixelsDefault
    var permitted = true
    var busyReason: String?
    var recoveryReason: @MainActor () -> String? = { nil }
    private var operationBlockingReason: String? { busyReason ?? recoveryReason() }
    var runWriteFails = false
    var binding: String { workspace.serverBinding }

    init(server: LifecycleServerStub? = nil, directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-\(UUID())")) {
        self.server = server ?? LifecycleServerStub(); self.directory = directory
        workspace = OperatorWorkspace(directory: directory)
        acceptance = SessionAcceptanceStore(directory: directory)
        library = Self.makeLibrary(directory)
        runs = EventRunStore(directory: directory.appendingPathComponent("runs"))
        creations = CommercialEventCreationStore(directory: directory)
        runs = makeRuns()
        creations = makeCreations()
    }
    private func makeCreations() -> CommercialEventCreationStore {
        CommercialEventCreationStore(directory: directory, writer: { [unowned self] data, url in
            if self.creationWriteFails { throw CocoaError(.fileWriteOutOfSpace) }
            try DurableFileWriter.write(data, to: url)
        })
    }
    private static func makeLibrary(_ directory: URL) -> EventDesignLibraryStore {
        EventDesignLibraryStore(directory: directory, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" }, operationAuthorized: { true }, operationBlockingReason: { nil })
    }
    private func makeRuns() -> EventRunStore {
        EventRunStore(directory: directory.appendingPathComponent("runs"), writer: { [unowned self] data, url in
            if self.runWriteFails { throw CocoaError(.fileWriteOutOfSpace) }
            try DurableFileWriter.write(data, to: url)
        }, authorized: { [unowned self] in self.permitted }, blockingReason: { [unowned self] in self.operationBlockingReason })
    }
    func relaunch() {
        workspace = OperatorWorkspace(directory: directory)
        acceptance = SessionAcceptanceStore(directory: directory)
        library = Self.makeLibrary(directory)
        runs = makeRuns()
        creations = makeCreations()
    }
    func setup() -> SessionSetupCoordinator {
        SessionSetupCoordinator(workspace: workspace, acceptance: acceptance, library: library, eventRuns: runs, creations: creations, api: { [unowned self] in self.server },
            authorized: { [unowned self] in self.permitted }, blockingReason: { [unowned self] in self.operationBlockingReason },
            loadLocal: { [unowned self] in self.local }, saveLocal: { [unowned self] in self.local = $0 },
            source: { [unowned self] in self.source }, saveSource: { [unowned self] in self.source = $0 },
            currentProfile: { [unowned self] in self.profile }, applyProfile: { [unowned self] in self.profile = $0 }, artworkAvailable: { _ in false })
    }
    var appliedContext: EventRunContext {
        let paid = source == .serverManaged
        return EventRunContext.admission(library: library.library, commercialEventID: paid ? acceptance.state.eventID : nil,
                                         serverBinding: paid ? binding : nil, fallbackName: local.name)
    }
    func lifecycle() -> EventLifecycleCoordinator {
        EventLifecycleCoordinator(runs: runs, acceptance: acceptance, api: { [unowned self] in self.server },
            authorized: { [unowned self] in self.permitted }, blockingReason: { [unowned self] in self.operationBlockingReason }, recoveryReason: { [unowned self] in self.recoveryReason() },
            source: { [unowned self] in self.source }, loadLocal: { [unowned self] in self.local }, saveLocal: { [unowned self] in self.local = $0 },
            binding: { [unowned self] in self.binding }, appliedContext: { [unowned self] in self.appliedContext },
            hasUnsavedSetup: { [unowned self] in self.workspace.hasUnsavedDrafts }, makeSetup: { [unowned self] in self.setup() }, applyRegularConfiguration: { [unowned self] in
                try self.library.recordApplied(eventModeEnabled: false, eventID: nil)
                self.profile = .pocketPixelsDefault; self.source = .localPrepaid
            })
    }

    /// The same gates a guest's Make a Memory tap passes, in the same order, using production
    /// admission helpers: the durable barrier, the policy source, then the committed run.
    func admitGuest(session: String = UUID().uuidString.lowercased(), format: String = "solo") async throws -> String {
        guard !acceptance.state.blocked else { throw SetupFailure("New sessions are paused.") }
        if RegularBoothMode.isEnabled(acceptance: acceptance, runs: runs) { return "regular-booth" }
        let commercialID: String?
        if source == .serverManaged {
            guard let event = try await server.activeEvent().event, acceptance.permits(eventID: event.id, binding: binding) else { throw SetupFailure("Paid event not accepting guests.") }
            commercialID = event.id
        } else {
            guard SessionAdmission.localConfigurationIsReady(source: .localPrepaid, local: local) else { throw SetupFailure("Prepaid setup not ready.") }
            commercialID = nil
        }
        let context = EventRunContext.admission(library: library.library, commercialEventID: commercialID, serverBinding: commercialID == nil ? nil : binding, fallbackName: local.name)
        let run = try runs.runForAdmission(context: context)
        try runs.beginSession(id: session, runID: run.id, format: format)
        runs.updateSession(id: session) { $0.completedAt = Date(); $0.printOutcomes["\(session)/1"] = "delivered" }
        return run.id
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor final class EventLifecycleIntegrationTests: XCTestCase {
    func testAcknowledgedUnknownPrintAllowsRelaunchRegularGuestEventStartAndEnd() async throws {
        let booth = Booth()
        let defaultsName = "recovery-cycle-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { booth.cleanup(); defaults.removePersistentDomain(forName: defaultsName) }
        var journal = try PrintOutcomeOutbox(directory: booth.directory)
        var checkpoints = try CheckoutCheckpointStore(directory: booth.directory)
        var recoveryStore = try AppRecoveryStore(directoryURL: booth.directory.appendingPathComponent("recovery"))
        let snapshot = AppRecoverySnapshot(schemaVersion: 1, sessionIdentifier: "old-guest", createdAt: Date(), format: .solo,
            eventProfile: nil, galleryToken: nil, galleryURL: nil, photoJPEGData: [Data([1, 2, 3])],
            receiptPreviewPNGData: Data([4, 5]), thermalPreviewPNGData: nil, rasterFingerprint: "original-raster",
            stage: .printStatusUnknown, updatedAt: Date())
        try recoveryStore.saveCritical(snapshot)
        try journal.beginCopy(batchID: "old-batch", sessionID: "old-guest", entitlementID: nil,
            receiptFingerprint: "original-raster", copyIndex: 1, copyCount: 1, transport: "bluetooth")
        journal = try PrintOutcomeOutbox(directory: booth.directory)
        XCTAssertEqual(journal.recoverAfterLaunch(), 1)
        booth.recoveryReason = {
            let saved = recoveryStore.load()
            let acknowledged = defaults.string(forKey: OperatorRecoveryAcknowledgement.key)
            let pending = saved.map { OperatorRecoveryAcknowledgement.identity($0) != acknowledged } ?? false
            let receiptCheck = saved.map {
                OperatorPrintPolicy.requiresAcknowledgement(stage: $0.stage, snapshotIdentity: OperatorRecoveryAcknowledgement.identity($0), acknowledgedIdentity: acknowledged)
            } ?? false
            return SessionSetupSafety.recoveryReason(needsReceiptCheck: receiptCheck, hasPendingSession: pending, checkpoints: checkpoints, outbox: journal)
        }
        let blocked = await booth.lifecycle().returnToRegular()
        XCTAssertFalse(blocked, "A genuinely current unknown print needs an operator check")
        let saved = try XCTUnwrap(recoveryStore.load())
        _ = try OperatorRecoveryAcknowledgement.retainAndAcknowledge(saved, store: recoveryStore, defaults: defaults)
        booth.relaunch()
        journal = try PrintOutcomeOutbox(directory: booth.directory)
        checkpoints = try CheckoutCheckpointStore(directory: booth.directory)
        recoveryStore = try AppRecoveryStore(directoryURL: booth.directory.appendingPathComponent("recovery"))
        let oldEvidence = journal.entries
        XCTAssertNil(booth.recoveryReason())
        let regular = booth.lifecycle()
        let returned = await regular.returnToRegular()
        XCTAssertTrue(returned, regular.message)
        XCTAssertEqual(regular.status, .regular)
        var settings = RegularBoothSettings()
        settings.maxCopies = 3; settings.defaultCopies = 2
        try RegularBoothSettings.save(settings, defaults: defaults)
        XCTAssertEqual(try RegularBoothSettings.loadForSession(defaults: defaults).defaultCopies, 2)
        let regularGuest = try await booth.admitGuest(session: "next-regular-guest")
        XCTAssertEqual(regularGuest, "regular-booth")
        _ = await startPrepaid(booth, design: "Next Free Event")
        XCTAssertEqual(booth.lifecycle().status, .accepting)
        _ = try await booth.admitGuest(session: "next-event-guest")
        let ended = await booth.lifecycle().end(scope: .thisBooth)
        XCTAssertTrue(ended)
        XCTAssertEqual(booth.lifecycle().status, .regular)
        XCTAssertEqual(journal.entries, oldEvidence, "Normal operation must never erase or rewrite the unknown outcome")
        XCTAssertEqual(try recoveryStore.retainedSessions().first?.photoJPEGData, saved.photoJPEGData)
        XCTAssertThrowsError(try journal.beginCopy(batchID: "old-batch", sessionID: "old-guest", entitlementID: nil,
            receiptFingerprint: "original-raster", copyIndex: 1, copyCount: 1, transport: "bluetooth"))
        let nextUnknown = AppRecoverySnapshot(schemaVersion: 1, sessionIdentifier: "different-interrupted-guest", createdAt: Date(), format: .solo,
            eventProfile: nil, galleryToken: nil, galleryURL: nil, photoJPEGData: [], receiptPreviewPNGData: nil,
            thermalPreviewPNGData: nil, rasterFingerprint: nil, stage: .printStatusUnknown, updatedAt: Date())
        try recoveryStore.saveCritical(nextUnknown)
        XCTAssertNotNil(booth.recoveryReason(), "A new interruption cannot inherit the previous receipt check")
        XCTAssertTrue(booth.server.calls.isEmpty, "Free recovery and event operation need no payment requests")
    }

    private func startPrepaid(_ booth: Booth, design name: String = "Garden Wedding", file: StaticString = #filePath, line: UInt = #line) async -> SessionSetupCoordinator {
        let setup = booth.setup()
        await setup.createEvent(name: name, venue: "Garden")
        let started = await setup.startAccepting()
        XCTAssertTrue(started, setup.message, file: file, line: line)
        return setup
    }
    private func startPaid(_ booth: Booth, price: String = "50", file: StaticString = #filePath, line: UInt = #line) async -> SessionSetupCoordinator {
        let setup = booth.setup()
        await setup.choosePayment(.qrOnly)
        await setup.createEvent(name: "Gala Night", venue: "Ballroom")
        setup.policy.priceText = price
        let started = await setup.startAccepting()
        XCTAssertTrue(started, "\(setup.validation ?? "") \(setup.message)", file: file, line: line)
        return setup
    }
    private func sessions(_ booth: Booth, run: String) throws -> [EventRunSession] {
        try EventRunStore.loadSessions(directory: booth.runs.directory).filter { $0.runID == run }
    }

    // MARK: Scenario 1 — prepaid

    func testPrepaidStartCommitsRunBeforeFirstGuestAndReportsWithoutPaymentsServer() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPrepaid(booth)
        let run = try XCTUnwrap(booth.runs.current, "The run exists before any guest arrives")
        XCTAssertEqual(run.status, .active)
        XCTAssertFalse(booth.acceptance.state.blocked)
        let revision = booth.runs.revision
        let admitted = try await booth.admitGuest(session: "guest-1")
        XCTAssertEqual(admitted, run.id, "The first customer never changes report identity")
        XCTAssertEqual(booth.runs.runs.count, 1)
        XCTAssertGreaterThan(booth.runs.revision, revision, "Only the session journal changed")
        XCTAssertEqual(EventRunStatistics(sessions: try sessions(booth, run: run.id)).completed, 1)
        XCTAssertTrue(booth.server.calls.isEmpty, "Prepaid mode never needs the Payments Worker")
        XCTAssertEqual(booth.lifecycle().status, .accepting)
    }

    // MARK: Problem A — End → Start again

    func testEndedRunIsNeverReopenedAndRequiresExplicitNewOccurrence() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPrepaid(booth)
        let runA = try XCTUnwrap(booth.runs.current)
        _ = try await booth.admitGuest(session: "a-1")
        let lifecycle = booth.lifecycle()
        let ended = await lifecycle.end(scope: .thisBooth)
        XCTAssertTrue(ended, lifecycle.message)
        XCTAssertNil(booth.runs.current)
        XCTAssertEqual(booth.runs.runs.first?.status, .completed)
        XCTAssertNotNil(booth.runs.runs.first?.endedAt)
        XCTAssertFalse(booth.acceptance.state.blocked)
        XCTAssertEqual(lifecycle.status, .regular)
        let regular = try await booth.admitGuest(session: "regular-guest")
        XCTAssertEqual(regular, "regular-booth")
        XCTAssertEqual(booth.runs.runs.count, 1, "Regular sessions do not create event occurrences")
        let again = booth.setup()
        await again.setEventMode(true)
        await again.chooseDesign(try XCTUnwrap(runA.context.designID))
        XCTAssertEqual(again.occurrencePlan, .requiresNewOccurrence(previousRunID: runA.id))
        let refused = await again.startAccepting()
        XCTAssertFalse(refused, "An ended occurrence is never reopened")
        again.startsNewOccurrence = true
        let started = await again.startAccepting()
        XCTAssertTrue(started, again.message)
        let runB = try XCTUnwrap(booth.runs.current)
        XCTAssertNotEqual(runB.id, runA.id)
        XCTAssertEqual(runB.previousRunID, runA.id)
        let admittedNow = try await booth.admitGuest(session: "b-1")
        XCTAssertEqual(admittedNow, runB.id)
        XCTAssertEqual(try sessions(booth, run: runA.id).map(\.sessionID), ["a-1"])
        XCTAssertEqual(EventRunStatistics(sessions: try sessions(booth, run: runB.id)).completed, 1)
    }

    func testEndThenRelaunchReturnsToRegularAndKeepsHistory() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPrepaid(booth)
        let runA = try XCTUnwrap(booth.runs.current)
        _ = try await booth.admitGuest(session: "a-1")
        _ = await booth.lifecycle().end(scope: .thisBooth)
        booth.relaunch()
        XCTAssertNil(booth.runs.current)
        XCTAssertEqual(booth.runs.runs.first { $0.id == runA.id }?.status, .completed)
        XCTAssertFalse(booth.acceptance.state.blocked)
        XCTAssertEqual(booth.lifecycle().status, .regular)
        let guest = try await booth.admitGuest()
        XCTAssertEqual(guest, "regular-booth")
        XCTAssertEqual(try sessions(booth, run: runA.id).count, 1)
    }

    // MARK: Pause / resume

    func testPausedRunResumesWithSameIdentityOnlyThroughRevalidatedStart() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPrepaid(booth)
        let run = try XCTUnwrap(booth.runs.current)
        let lifecycle = booth.lifecycle()
        await lifecycle.pauseBooth()
        XCTAssertEqual(booth.runs.current?.status, .paused)
        XCTAssertTrue(booth.acceptance.state.blocked)
        XCTAssertEqual(lifecycle.status, .pausedOnBooth)
        do { _ = try await booth.admitGuest(); XCTFail("Paused") } catch {}
        let resumed = await lifecycle.resume()
        XCTAssertTrue(resumed, lifecycle.message)
        XCTAssertEqual(booth.runs.current?.id, run.id, "Resume keeps the run")
        XCTAssertEqual(booth.runs.current?.status, .active)
        let admittedNow = try await booth.admitGuest()
        XCTAssertEqual(admittedNow, run.id)
    }

    func testPauseBoothNeverPausesTheSharedPaidEventForOtherBooths() async throws {
        let server = LifecycleServerStub()
        let carlo = Booth(server: server); defer { carlo.cleanup() }
        _ = await startPaid(carlo)
        let eventID = try XCTUnwrap(carlo.runs.current?.context.commercialEventID)
        // A second iPad on the same account accepts guests for the same paid event.
        let other = Booth(server: server); defer { other.cleanup() }
        other.source = .serverManaged
        try other.acceptance.save(.init(blocked: false, eventID: eventID, serverBinding: other.binding, mode: .serverManaged))
        try other.library.recordApplied(eventModeEnabled: false, eventID: nil)
        _ = try other.runs.commitStart(context: other.appliedContext, expected: .createFirst, allowNewOccurrence: false)

        let lifecycle = carlo.lifecycle()
        await lifecycle.pauseBooth()
        XCTAssertEqual(server.mutations("pause"), 0, "Pause This Booth is local only")
        XCTAssertEqual(server.events[eventID]?.lifecycle, .active)
        XCTAssertTrue(carlo.acceptance.state.blocked)
        await lifecycle.refresh()
        XCTAssertEqual(lifecycle.status, .pausedOnBooth)
        XCTAssertTrue(lifecycle.message.contains("stays open for other booths"), lifecycle.message)
        let otherRun = try await other.admitGuest()
        XCTAssertEqual(otherRun, other.runs.current?.id, "The other booth keeps accepting guests")
    }

    func testPauseCommercialEventIsExplicitServerWideAndConfirmedByReadBack() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPaid(booth)
        let eventID = try XCTUnwrap(booth.runs.current?.context.commercialEventID)
        let lifecycle = booth.lifecycle()
        await lifecycle.refresh()
        XCTAssertEqual(lifecycle.status, .accepting)
        await lifecycle.pauseCommercialEvent()
        XCTAssertEqual(booth.server.events[eventID]?.lifecycle, .paused)
        XCTAssertNil(booth.runs.pendingTransition)
        XCTAssertTrue(booth.acceptance.state.blocked)
        XCTAssertEqual(lifecycle.status, .serverPaused)
        // Resume revalidates and resumes the paid event, keeping the same run.
        let run = booth.runs.current?.id
        let resumed = await lifecycle.resume()
        XCTAssertTrue(resumed, lifecycle.message)
        XCTAssertEqual(booth.server.events[eventID]?.lifecycle, .active)
        XCTAssertEqual(booth.runs.current?.id, run)
        XCTAssertEqual(lifecycle.status, .accepting)
    }

    // MARK: End with commercial scope

    func testEndForEveryBoothCompletesRunOnlyAfterServerConfirmsEnded() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPaid(booth)
        let eventID = try XCTUnwrap(booth.runs.current?.context.commercialEventID)
        let lifecycle = booth.lifecycle()
        let ended = await lifecycle.end(scope: .thisBoothAndCommercialEvent)
        XCTAssertTrue(ended, lifecycle.message)
        XCTAssertEqual(booth.server.events[eventID]?.lifecycle, .ended)
        XCTAssertNil(booth.runs.current)
        XCTAssertEqual(booth.runs.runs.last?.status, .completed)
        XCTAssertNil(booth.runs.pendingTransition)
        XCTAssertTrue(lifecycle.message.contains("every booth"))
    }

    func testEndThisBoothOnlyLeavesTheSharedPaidEventOpen() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPaid(booth)
        let eventID = try XCTUnwrap(booth.runs.current?.context.commercialEventID)
        let lifecycle = booth.lifecycle()
        let ended = await lifecycle.end(scope: .thisBooth)
        XCTAssertTrue(ended)
        XCTAssertEqual(booth.server.mutations("end"), 0)
        XCTAssertEqual(booth.server.events[eventID]?.lifecycle, .active)
        XCTAssertTrue(lifecycle.message.contains("other booths are unchanged") || lifecycle.message.contains("other booths are unchanged".capitalized) || lifecycle.message.contains("other booths are unchanged".replacingOccurrences(of: "other", with: "Other")))
    }

    func testLostEndResponseIsReconciledAfterRelaunchWithoutRepeatingTheMutation() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPaid(booth)
        let run = try XCTUnwrap(booth.runs.current)
        booth.server.loseResponseAfter = "end"
        let lifecycle = booth.lifecycle()
        let ended = await lifecycle.end(scope: .thisBoothAndCommercialEvent)
        XCTAssertFalse(ended, "Never report success before confirmation")
        XCTAssertFalse(lifecycle.message.contains("Event ended"))
        XCTAssertEqual(booth.runs.current?.status, .active, "Local run is not completed on an ambiguous result")
        XCTAssertTrue(booth.acceptance.state.blocked, "Admission stays closed")
        XCTAssertNotNil(booth.runs.pendingTransition)
        if case .recoveryRequired = lifecycle.status {} else { XCTFail("Status must require recovery, got \(lifecycle.status)") }

        booth.relaunch()   // crash between the server commit and the local commit
        XCTAssertNotNil(booth.runs.pendingTransition, "The intent is durable")
        do { _ = try await booth.admitGuest(); XCTFail("No admission during an unresolved transition") } catch {}
        let afterLaunch = booth.lifecycle()
        await afterLaunch.refresh()
        XCTAssertNil(booth.runs.pendingTransition)
        XCTAssertNil(booth.runs.current)
        XCTAssertEqual(booth.runs.runs.first { $0.id == run.id }?.status, .completed)
        XCTAssertEqual(booth.server.mutations("end"), 1, "The committed mutation is never repeated")
        XCTAssertEqual(afterLaunch.status, .regular)
    }

    func testUnreachableEndLeavesRunPausedAndReviewClearsIntentWithoutGuessing() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPaid(booth)
        let eventID = try XCTUnwrap(booth.runs.current?.context.commercialEventID)
        booth.server.unreachableBefore = "end"
        let lifecycle = booth.lifecycle()
        let ended = await lifecycle.end(scope: .thisBoothAndCommercialEvent)
        XCTAssertFalse(ended)
        await lifecycle.refresh()
        XCTAssertNil(booth.runs.pendingTransition)
        XCTAssertEqual(booth.server.events[eventID]?.lifecycle, .active)
        XCTAssertEqual(booth.runs.current?.status, .active)
        XCTAssertTrue(booth.acceptance.state.blocked)
        XCTAssertEqual(lifecycle.status, .pausedOnBooth, "Nothing reopened; the operator decides next")
    }

    func testVersionConflictDuringEndIsNotRetriedAndKeepsHistory() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPaid(booth)
        booth.server.concurrentEditBefore = "end"
        let lifecycle = booth.lifecycle()
        let ended = await lifecycle.end(scope: .thisBoothAndCommercialEvent)
        XCTAssertFalse(ended)
        XCTAssertEqual(booth.server.mutations("end"), 1)
        XCTAssertEqual(booth.runs.current?.status, .active)
        await lifecycle.refresh()
        XCTAssertNil(booth.runs.pendingTransition)
        XCTAssertTrue(lifecycle.message.contains("not applied"))
    }

    func testConcurrentAndDuplicateOperatorActionsAreSerialized() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPaid(booth)
        let lifecycle = booth.lifecycle()
        async let first = lifecycle.end(scope: .thisBoothAndCommercialEvent)
        async let second = lifecycle.end(scope: .thisBoothAndCommercialEvent)
        let results = await [first, second]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(booth.server.mutations("end"), 1)
        let duplicate = await lifecycle.end(scope: .thisBooth)
        XCTAssertFalse(duplicate, "An ended run cannot be ended twice")
        // Duplicate Start on an already running setup keeps the same run.
        let fresh = Booth(); defer { fresh.cleanup() }
        let setup = await startPrepaid(fresh)
        let id = fresh.runs.current?.id
        let again = await setup.startAccepting()
        XCTAssertTrue(again)
        XCTAssertEqual(fresh.runs.current?.id, id)
        XCTAssertEqual(fresh.runs.runs.count, 1)
    }

    func testMaintenanceEndElsewhereCompletesMatchingLocalRun() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPaid(booth)
        let eventID = try XCTUnwrap(booth.runs.current?.context.commercialEventID)
        let detail = try await booth.server.eventDetail(id: eventID)
        _ = try await booth.server.transitionEvent(id: eventID, action: "end", expectedVersion: detail.event.version, policyRevisionID: nil, acknowledgedUnitPriceCentavos: nil)
        let lifecycle = booth.lifecycle()
        await lifecycle.refresh()
        XCTAssertEqual(lifecycle.status, .needsReview("The paid event was ended for every booth. Finish ending this iPad's run."))
        XCTAssertNil(EventLifecycleCoordinator.syncAfterServerTransition(eventID: "other", lifecycle: .ended, binding: booth.binding, runs: booth.runs, acceptance: booth.acceptance))
        XCTAssertNotNil(EventLifecycleCoordinator.syncAfterServerTransition(eventID: eventID, lifecycle: .ended, binding: booth.binding, runs: booth.runs, acceptance: booth.acceptance))
        XCTAssertEqual(booth.runs.current?.status, .completed)
        XCTAssertTrue(booth.acceptance.state.blocked)
    }

    // MARK: Scenario 6 — reuse an ended paid design

    func testReusingEndedPaidDesignCreatesFreshCommercialEventAndKeepsOldFinancialHistory() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPaid(booth, price: "75")
        let runA = try XCTUnwrap(booth.runs.current)
        let oldEvent = try XCTUnwrap(runA.context.commercialEventID)
        _ = try await booth.admitGuest(session: "paid-a")
        booth.runs.updateSession(id: "paid-a") { $0.orderIDs = ["order-a"] }
        _ = await booth.lifecycle().end(scope: .thisBoothAndCommercialEvent)

        let reuse = booth.setup()
        await reuse.setEventMode(true)
        await reuse.choosePayment(.qrOnly)
        await reuse.chooseDesign(try XCTUnwrap(booth.runs.runs.last?.context.designID))
        await reuse.refresh()
        XCTAssertTrue(reuse.validation?.contains("Start New Paid Occurrence") == true, reuse.validation ?? "")
        XCTAssertTrue(reuse.canStartNewPaidOccurrence)
        await reuse.startNewPaidOccurrence()
        let newEvent = try XCTUnwrap(reuse.selectedID)
        XCTAssertNotEqual(newEvent, oldEvent)
        XCTAssertEqual(booth.server.events[oldEvent]?.lifecycle, .ended, "The ended event is never reactivated")
        let design = try XCTUnwrap(booth.library.design(id: runA.context.designID))
        XCTAssertEqual(design.serverEvents[booth.binding], newEvent)
        XCTAssertEqual(design.retiredServerEvents?[booth.binding], [oldEvent], "History of the link is append-only")
        XCTAssertEqual(reuse.policy.requestBody()?.unitPriceCentavos, 7500, "Reviewed price carried into an unpublished draft")
        XCTAssertNil(booth.server.events[newEvent]?.active, "Nothing is published before Start")
        XCTAssertFalse(booth.library.library.knownServerEventIDs(binding: booth.binding).isDisjoint(with: [oldEvent]))

        let started = await reuse.startAccepting()
        XCTAssertTrue(started, reuse.message)
        let runB = try XCTUnwrap(booth.runs.current)
        XCTAssertNotEqual(runB.id, runA.id)
        XCTAssertEqual(runB.context.commercialEventID, newEvent)
        XCTAssertEqual(booth.runs.runs.first { $0.id == runA.id }?.context.commercialEventID, oldEvent, "Old run keeps its commercial event")
        let admittedNow = try await booth.admitGuest(session: "paid-b")
        XCTAssertEqual(admittedNow, runB.id)

        // Financial attribution stays exact per run.
        func row(_ id: String, session: String) -> OperatorOrderRow {
            OperatorOrderRow(id: id, createdAt: Date(), boothFormat: "solo", copies: 1, totalCentavos: 7500, state: "COMPLETE", method: nil, paymentState: nil,
                             category: "QRPH_VERIFIED_LIVE", entitlementState: "CONSUMED", confirmedPrints: 1, uncertainPrints: 0, lastReconcileError: nil, sessionId: session)
        }
        let all = try EventRunStore.loadSessions(directory: booth.runs.directory)
        let runAOrders = EventRunFinancialTotals.matchingOrders([row("order-a", session: "paid-a"), row("order-b", session: "paid-b")], sessions: all.filter { $0.runID == runA.id })
        XCTAssertEqual(runAOrders.map(\.id), ["order-a"])
        XCTAssertThrowsError(try booth.library.deleteUnusedDesign(id: design.id, runs: booth.runs.runs, archives: [], historyAvailable: true))
    }

    func testStaleOrReusedCommercialLinkIsRefusedWithoutChangingTheDesign() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPaid(booth)
        let oldEvent = try XCTUnwrap(booth.runs.current?.context.commercialEventID)
        _ = await booth.lifecycle().end(scope: .thisBoothAndCommercialEvent)
        let reuse = booth.setup()
        await reuse.setEventMode(true)
        await reuse.choosePayment(.qrOnly)
        await reuse.chooseDesign(try XCTUnwrap(booth.runs.runs.last?.context.designID))
        await reuse.refresh()
        let designID = try XCTUnwrap(reuse.design?.id)
        // A concurrent relink makes the expected link stale; the library refuses.
        XCTAssertThrowsError(try booth.library.linkNewCommercialOccurrence(designID: designID, binding: booth.binding, expectedCurrent: "stale", newServerEventID: "srv-x"))
        XCTAssertThrowsError(try booth.library.linkNewCommercialOccurrence(designID: designID, binding: booth.binding, expectedCurrent: oldEvent, newServerEventID: oldEvent))
        XCTAssertEqual(booth.library.design(id: designID)?.serverEvents[booth.binding], oldEvent)
    }

    // MARK: Switching

    func testSwitchingDesignsStartsNewRunWithoutMovingSessions() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPrepaid(booth, design: "Wedding")
        let runA = try XCTUnwrap(booth.runs.current)
        _ = try await booth.admitGuest(session: "w-1")
        let setup = booth.setup()
        await setup.createEvent(name: "Birthday", venue: "")
        if case .switchSetup(let previous, .active) = setup.occurrencePlan { XCTAssertEqual(previous, runA.id) } else { XCTFail("\(setup.occurrencePlan)") }
        let started = await setup.startAccepting()
        XCTAssertTrue(started, setup.message)
        let runB = try XCTUnwrap(booth.runs.current)
        XCTAssertNotEqual(runB.id, runA.id)
        XCTAssertEqual(booth.runs.runs.first { $0.id == runA.id }?.status, .completed)
        XCTAssertEqual(try sessions(booth, run: runA.id).map(\.sessionID), ["w-1"])
        XCTAssertTrue(try sessions(booth, run: runB.id).isEmpty)
    }

    func testSwitchingPaidToPrepaidWithUnresolvedEntitlementIsBlockedAndKeepsState() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPaid(booth)
        let run = booth.runs.current?.id
        booth.busyReason = "Resolve interrupted checkouts in Payment Recovery before changing operation."
        let setup = booth.setup()
        await setup.choosePayment(.noPayment)
        let started = await setup.startAccepting()
        XCTAssertFalse(started)
        XCTAssertEqual(booth.source, .serverManaged)
        XCTAssertEqual(booth.runs.current?.id, run)
        XCTAssertEqual(booth.runs.current?.status, .active)
        let lifecycle = booth.lifecycle()
        let ended = await lifecycle.end(scope: .thisBooth)
        XCTAssertFalse(ended, "Ending is blocked while a purchase still needs recovery")
        await lifecycle.pauseBooth()
        XCTAssertTrue(booth.acceptance.state.blocked, "Pausing is always allowed")
    }

    // MARK: Failure safety

    func testRunWriteFailureAtStartKeepsAdmissionClosed() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        booth.runWriteFails = true
        let setup = booth.setup()
        await setup.createEvent(name: "Disk Full", venue: "")
        let started = await setup.startAccepting()
        XCTAssertFalse(started)
        XCTAssertTrue(booth.acceptance.state.blocked)
        XCTAssertNil(booth.runs.current)
    }

    func testUnreadableRunHistoryBlocksStartAndIsPreserved() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let file = booth.directory.appendingPathComponent("runs/runs.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: file)
        booth.relaunch()
        let setup = booth.setup()
        await setup.createEvent(name: "Recovery", venue: "")
        XCTAssertNotNil(setup.validation)
        let started = await setup.startAccepting()
        XCTAssertFalse(started)
        XCTAssertEqual(try Data(contentsOf: file), Data("corrupt".utf8))
        if case .recoveryRequired = booth.lifecycle().status {} else { XCTFail("\(booth.lifecycle().status)") }
    }

    func testArchivedDesignAndArchivedRunCannotStartOrResume() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let setup = await startPrepaid(booth)
        let lifecycle = booth.lifecycle()
        _ = await lifecycle.end(scope: .thisBooth)
        let run = try XCTUnwrap(booth.runs.runs.last)
        try booth.runs.transition(id: run.id, to: .archived)
        XCTAssertEqual(lifecycle.status, .regular)
        try booth.library.archiveDesign(id: try XCTUnwrap(setup.design?.id))
        XCTAssertNotNil(booth.library.design(id: setup.design?.id)?.archivedAt)
        let other = try booth.library.create(name: "Other", venue: "")
        try booth.library.archiveDesign(id: other.id)
        let next = booth.setup()
        await next.setEventMode(true)
        await next.chooseDesign(other.id)
        XCTAssertNotNil(next.validation)
    }

    func testLegacyInstallWithoutRunsStillAdmitsFirstGuestButMismatchFailsClosed() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        // A booth that was accepting guests before event runs existed.
        let first = try await booth.admitGuest(session: "legacy-upgrade")
        XCTAssertEqual(booth.runs.current?.id, first)
        try booth.library.recordApplied(eventModeEnabled: true, eventID: try booth.library.create(name: "Changed", venue: "").id)
        do { _ = try await booth.admitGuest(); XCTFail("A changed setup must be started explicitly") } catch {}
        XCTAssertEqual(booth.runs.runs.count, 1)
        if case .needsReview = booth.lifecycle().status {} else { XCTFail("\(booth.lifecycle().status)") }
    }

    // MARK: Status model

    func testStatusModelNeverDerivesAcceptingFromASingleSource() {
        let context = EventRunContext(designID: "d", commercialEventID: "e", serverBinding: "b", name: "Gala")
        let run = EventRunRecord(id: "r", context: context, createdAt: Date(), status: .active)
        func status(run: EventRunRecord? = run, blocked: Bool = false, commercial: CommercialCheckState = .confirmed(.init(eventID: "e", lifecycle: .active, isAccountActiveEvent: true, checkedAt: Date())),
                    source: CommercialPolicySource = .serverManaged, acceptanceEvent: String? = "e", recovery: String? = nil, pending: EventTransitionIntent? = nil,
                    applied: EventRunContext = context, errors: [String] = []) -> EventOperatorStatus {
            EventStatusModel.derive(.init(run: run, appliedContext: applied, barrierBlocked: blocked, acceptanceEventID: acceptanceEvent, acceptanceBinding: "b", binding: "b",
                source: source, localPrepaidReady: true, commercial: commercial, recoveryReason: recovery, storageErrors: errors, pendingTransition: pending, hasUnsavedSetup: false, operation: nil))
        }
        XCTAssertEqual(status(), .accepting)
        XCTAssertEqual(status(blocked: true), .pausedOnBooth, "An active run with a closed barrier is not accepting")
        XCTAssertEqual(status(commercial: .confirmed(.init(eventID: "e", lifecycle: .paused, isAccountActiveEvent: false, checkedAt: Date()))), .serverPaused)
        XCTAssertEqual(status(commercial: .unavailable("offline")), .unconfirmed("offline"))
        if case .needsReview = status(acceptanceEvent: "other") {} else { XCTFail() }
        if case .needsReview = status(commercial: .confirmed(.init(eventID: "e", lifecycle: .ended, isAccountActiveEvent: false, checkedAt: Date()))) {} else { XCTFail() }
        if case .needsReview = status(applied: EventRunContext(designID: "x", commercialEventID: "e", serverBinding: "b", name: "Gala")) {} else { XCTFail() }
        if case .needsReview = status(recovery: "Unresolved checkout") {} else { XCTFail() }
        if case .recoveryRequired = status(pending: .init(id: "i", kind: .endCommercialEvent, runID: "r", commercialEventID: "e", serverBinding: "b", createdAt: Date())) {} else { XCTFail() }
        if case .recoveryRequired = status(errors: ["unreadable"]) {} else { XCTFail() }
        var completed = run; completed.status = .completed
        XCTAssertEqual(status(run: completed), .completed)
        var archived = run; archived.status = .archived
        XCTAssertEqual(status(run: archived), .archived)
        // Event Integrity release: a paused booth whose admission was committed for a confirmed paid
        // event is paused, not "No Event Configured" (an upgraded install with no run yet).
        XCTAssertEqual(status(run: nil, blocked: true), .pausedOnBooth)
        XCTAssertEqual(status(run: nil, blocked: true, acceptanceEvent: nil), .noEvent, "Nothing committed and nothing open: unconfigured")
        XCTAssertEqual(EventStatusModel.derive(.init(run: nil, appliedContext: context, barrierBlocked: true, acceptanceEventID: nil, acceptanceBinding: nil, binding: "b",
            source: .localPrepaid, localPrepaidReady: true, commercial: .notNeeded, recoveryReason: nil, storageErrors: [], pendingTransition: nil, hasUnsavedSetup: true, operation: nil)), .draft)
        XCTAssertEqual(EventStatusModel.derive(.init(run: run, appliedContext: context, barrierBlocked: false, acceptanceEventID: "e", acceptanceBinding: "b", binding: "b",
            source: .serverManaged, localPrepaidReady: true, commercial: .notNeeded, recoveryReason: nil, storageErrors: [], pendingTransition: nil, hasUnsavedSetup: false, operation: .ending)), .ending)
    }

    // MARK: UI

    func testCurrentEventAndReportTabsRenderInPortraitAndLandscape() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        _ = await startPrepaid(booth)
        _ = try await booth.admitGuest(session: "render")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let lifecycle = booth.lifecycle()
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            for (name, view) in [
                ("current-event", AnyView(NavigationStack { ScrollView { CurrentEventCard(lifecycle: lifecycle, loadsRemote: false).padding(24) } })),
                ("reports-overview", AnyView(NavigationStack { EventRunReportingView(store: booth.runs, library: booth.library, archiveDirectory: booth.directory.appendingPathComponent("archive"), loadsRemote: false) })),
                ("reports-history", AnyView(NavigationStack { EventRunReportingView(store: booth.runs, library: booth.library, archiveDirectory: booth.directory.appendingPathComponent("archive"), loadsRemote: false, initialTab: .history) })),
                ("reports-manage", AnyView(NavigationStack { EventRunReportingView(store: booth.runs, library: booth.library, archiveDirectory: booth.directory.appendingPathComponent("archive"), loadsRemote: false, initialTab: .manage) })),
                ("end-event", AnyView(EndEventSheet(lifecycle: lifecycle, isPresented: .constant(true))))
            ] {
                let host = UIHostingController(rootView: view)
                let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size)
                window.overrideUserInterfaceStyle = .light
                window.rootViewController = host; window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(350))
                host.view.frame = window.bounds; host.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(size: size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                XCTAssertGreaterThan(image.pngData()?.count ?? 0, 20_000, "\(name) rendered blank")
                let label = "\(name)-\(size.width < size.height ? "portrait" : "landscape")"
                let attachment = XCTAttachment(image: image); attachment.name = label; attachment.lifetime = .keepAlways; add(attachment)
                try? image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/pocket-lifecycle-\(label).png"))
                window.isHidden = true
            }
        }
    }
}
