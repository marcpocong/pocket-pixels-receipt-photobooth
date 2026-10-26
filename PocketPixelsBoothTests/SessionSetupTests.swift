import XCTest
import SwiftUI
@testable import PocketPixelsBooth

@MainActor private final class SetupAPIStub: SessionSetupAPI {
    var lifecycle: CommercialEventLifecycle = .draft
    var version = 2
    var latest = OperatorPolicyRevision(id: "r1", revision: 1, commercialMode: .payPerPrint, unitPriceCentavos: 2500,
        maxCopies: 3, defaultCopies: 1, cashEnabled: false, qrphEnabled: true, prepaidGuestCopyChoice: false,
        supportedFormats: ["solo", "duo", "grid", "strip", "gridSix", "photoPass"], offlineValidUntil: nil, createdAt: Date(), activatedAt: nil)
    var active: OperatorPolicyRevision?
    var name = "Regular Sessions"
    var venue = ""
    var calls: [String] = []
    var listGate: CheckedContinuation<Void, Never>?
    var delaysList = false
    var createDelay: UInt64 = 0
    var detailDelay: UInt64 = 0
    var failAfterCommit: String?
    var onTransition: (() -> Void)?
    var barrier: (() -> Bool)?
    var acknowledgements: [(String?, Int?)] = []
    @MainActor func listEvents() async throws -> [OperatorEventSummary] {
        calls.append("list")
        if delaysList { await withCheckedContinuation { listGate = $0 } }
        return [.init(id: "event", name: name, venue: venue, lifecycle: lifecycle.rawValue,
            activePolicyRevisionId: active?.id, version: version, updatedAt: Date())]
    }
    @MainActor func eventDetail(id: String) async throws -> OperatorEventDetail {
        calls.append("detail")
        if detailDelay > 0 { try await Task.sleep(nanoseconds: detailDelay) }
        return .init(event: .init(id: "event", name: name, venue: venue, lifecycle: lifecycle, version: version,
            updatedAt: Date(), activePolicyRevisionId: active?.id), activePolicy: active, latestRevision: latest,
            hasUnpublishedRevision: latest.id != active?.id, outstandingEntitlements: 0, serverTime: Date())
    }
    @MainActor func eventCreation(operationID: String) async throws -> OperatorEventCreationLookup {
        throw PaymentsAPIError.rejected(code: "not_found", message: "missing", status: 404, details: Data())
    }
    @MainActor func createEvent(name: String, venue: String, operationID: String) async throws -> OperatorCreatedEvent {
        calls.append("create"); self.name = name; self.venue = venue
        if createDelay > 0 { try await Task.sleep(nanoseconds: createDelay) }
        if failAfterCommit == "create" { throw PaymentsAPIError.outcomeUnknown }
        return .init(id: "event", lifecycle: "DRAFT", version: 1)
    }
    @MainActor func saveDraft(eventID: String, expectedVersion: Int, name: String, venue: String, policy: ServerPolicyDraft.RequestBody) async throws -> OperatorEventUpdate {
        calls.append("save")
        guard expectedVersion == version else { throw SetupFailure("version conflict") }
        self.name = name; self.venue = venue; version += 1
        latest = .init(id: "r\(latest.revision + 1)", revision: latest.revision + 1, commercialMode: .payPerPrint,
            unitPriceCentavos: policy.unitPriceCentavos, maxCopies: policy.maxCopies, defaultCopies: policy.defaultCopies,
            cashEnabled: policy.cashEnabled, qrphEnabled: policy.qrphEnabled, prepaidGuestCopyChoice: false,
            supportedFormats: policy.supportedFormats, offlineValidUntil: policy.offlineValidUntil, createdAt: Date(), activatedAt: nil)
        if failAfterCommit == "save" { throw PaymentsAPIError.outcomeUnknown }
        return .init(eventId: "event", version: version, draftRevision: latest)
    }
    @MainActor func transitionEvent(id: String, action: String, expectedVersion: Int, policyRevisionID: String?, acknowledgedUnitPriceCentavos: Int?) async throws -> OperatorEventTransition {
        calls.append(action)
        XCTAssertTrue(barrier?() ?? true, "The durable barrier must close before changing the server")
        guard expectedVersion == version else { throw SetupFailure("version conflict") }
        if action == "activate" || action == "publish" {
            acknowledgements.append((policyRevisionID, acknowledgedUnitPriceCentavos))
            XCTAssertEqual(policyRevisionID, latest.id); XCTAssertEqual(acknowledgedUnitPriceCentavos, latest.unitPriceCentavos)
            active = latest
        }
        if action == "activate" || action == "resume" { lifecycle = .active }
        if action == "pause" { lifecycle = .paused }
        version += 1; onTransition?()
        if failAfterCommit == action { throw PaymentsAPIError.outcomeUnknown }
        return .init(id: "event", lifecycle: lifecycle.rawValue, activePolicyRevisionId: active?.id, version: version)
    }
    @MainActor func activeEvent() async throws -> ActiveEventResponse {
        calls.append("active")
        let p = active
        let event: ServerEventPolicy? = lifecycle == .active && p != nil ? .init(id: "event", name: name, venue: venue,
            lifecycle: .active, policyRevisionId: p!.id, revision: p!.revision, commercialMode: p!.commercialMode,
            unitPriceCentavos: p!.unitPriceCentavos, maxCopies: p!.maxCopies, defaultCopies: p!.defaultCopies,
            cashEnabled: p!.cashEnabled, qrphEnabled: p!.qrphEnabled, prepaidGuestCopyChoice: false,
            supportedFormats: p!.supportedFormats, offlineValidUntil: p!.offlineValidUntil) : nil
        return .init(event: event, inactiveEvent: nil, offlinePolicy: nil, offlinePolicyStatus: nil,
            device: .init(id: "fixture", accountId: "fixture"), serverTime: Date())
    }
}

@MainActor private final class SetupFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("setup-test-\(UUID())")
    let workspace: OperatorWorkspace
    let acceptance: SessionAcceptanceStore
    let api = SetupAPIStub()
    var source = CommercialPolicySource.localPrepaid
    var local = CommercialEventRun.legacy
    var permitted = true
    var blockedReason: String?
    var applied: [EventProfile] = []
    var profile = EventProfile.pocketPixelsDefault
    var usableArtwork: Set<String> = []
    let library: EventDesignLibraryStore
    lazy var runs = EventRunStore(directory: directory.appendingPathComponent("runs"), authorized: { [unowned self] in self.permitted }, blockingReason: { [unowned self] in self.blockedReason })
    lazy var model = makeModel()
    init() {
        workspace = OperatorWorkspace(directory: directory)
        acceptance = SessionAcceptanceStore(directory: directory)
        library = EventDesignLibraryStore(directory: directory, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" })
        api.barrier = { [weak self] in self?.acceptance.state.blocked == true }
    }
    func makeModel(live: Bool = false, timeout: TimeInterval = 15) -> SessionSetupCoordinator {
        .init(editingLiveEvent: live, requestTimeout: timeout, workspace: workspace, acceptance: acceptance, library: library, eventRuns: runs, creations: CommercialEventCreationStore(directory: directory), api: { self.api }, authorized: { self.permitted },
              blockingReason: { self.blockedReason }, loadLocal: { self.local }, saveLocal: { self.local = $0 },
              source: { self.source }, saveSource: { self.source = $0 }, currentProfile: { self.profile },
              applyProfile: { self.profile = $0; self.applied.append($0) }, artworkAvailable: { $0.map(self.usableArtwork.contains) ?? false })
    }
    func paid() async { model.mode = .serverManaged; await model.select("event") }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor final class SessionSetupTests: XCTestCase {
    private func assertStart(_ model: SessionSetupCoordinator, expected: Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let result = await model.startAccepting()
        XCTAssertEqual(result, expected, model.message, file: file, line: line)
    }
    func testDuplicatePaidCreateSharesOneOperationAndOnlyOneVerificationRead() async throws {
        let f = SetupFixture(); defer { f.cleanup() }
        f.model.mode = .serverManaged; f.api.createDelay = 50_000_000
        let first = Task { await f.model.createEvent(name: "One event", venue: "Test") }
        while !f.api.calls.contains("create") { await Task.yield() }
        await f.model.createEvent(name: "Duplicate tap", venue: "Test")
        await first.value
        XCTAssertEqual(f.library.library.events.count, 1)
        XCTAssertEqual(f.api.calls.filter { $0 == "create" }.count, 1)
        XCTAssertEqual(f.api.calls.filter { $0 == "detail" }.count, 1)
        XCTAssertFalse(f.model.busy)
        XCTAssertEqual(f.model.phase, .completed)
    }

    func testThermalPreviewWorkerPreservesExactPrinterRaster() async throws {
        let receipt = try await EventReceiptComposerPreview.makePreviewReceipt(profile: .pocketPixelsDefault, format: .solo)
        let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        let expected = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt).previewPNGData
        let actual = try await EventReceiptComposerPreview.makePrinterPreview(receiptPNG: receipt.imagePNGData)
        XCTAssertEqual(actual, expected)
    }

    func testReadTimeoutReleasesBusyAndAllowsExplicitRefresh() async throws {
        let f = SetupFixture(); defer { f.cleanup() }
        let model = f.makeModel(timeout: 0.02)
        model.mode = .serverManaged; f.api.detailDelay = 200_000_000
        await model.select("event")
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.message.contains("timed out"))
        f.api.detailDelay = 0
        await model.refresh()
        XCTAssertNotNil(model.detail); XCTAssertFalse(model.busy)
    }

    func testCreateTimeoutRetainsOriginalOperationAcrossRelaunchWithoutRetry() async throws {
        let f = SetupFixture(); defer { f.cleanup() }
        let model = f.makeModel(timeout: 0.02)
        model.mode = .serverManaged; f.api.createDelay = 200_000_000
        await model.createEvent(name: "Uncertain create", venue: "Test")
        let operation = try XCTUnwrap(model.pendingCreation)
        XCTAssertEqual(operation.state, .requested)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.message.contains("Check Original Request"))
        let reopened = f.makeModel(timeout: 0.02)
        XCTAssertEqual(reopened.pendingCreation?.id, operation.id)
        await reopened.createEvent(name: "Never duplicate", venue: "")
        XCTAssertEqual(f.api.calls.filter { $0 == "create" }.count, 1)
        XCTAssertEqual(f.library.library.events.count, 1)
    }

    func testReopeningSetupCannotOverlapAnInFlightActivation() async throws {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.paid()
        let reopened = f.makeModel(); await reopened.refresh()
        f.api.detailDelay = 100_000_000
        let first = Task { await f.model.startAccepting() }
        while f.acceptance.setupOperationID == nil { await Task.yield() }
        let second = await reopened.startAccepting()
        XCTAssertFalse(second)
        XCTAssertTrue(reopened.message.contains("still finishing"))
        let started = await first.value
        XCTAssertTrue(started, f.model.message)
        XCTAssertEqual(f.api.calls.filter { $0 == "activate" }.count, 1)
        XCTAssertNil(f.acceptance.setupOperationID)
        XCTAssertFalse(f.model.busy)
    }

    func testConcurrentRefreshIsCoalesced() async {
        let f = SetupFixture(); defer { f.cleanup() }
        f.model.mode = .serverManaged; f.api.delaysList = true
        let first = Task { await f.model.refresh() }
        while f.api.listGate == nil { await Task.yield() }
        let second = Task { await f.model.refresh() }
        await Task.yield()
        f.api.delaysList = false; f.api.listGate?.resume(); f.api.listGate = nil
        await first.value; await second.value
        XCTAssertEqual(f.api.calls.filter { $0 == "list" }.count, 1)
        XCTAssertFalse(f.model.busy)
    }

    func testDraftFlushRunsOffMainAndPreservesLatestValueAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = OperatorWorkspace(directory: directory, backgroundWrites: true, write: { data, url in
            XCTAssertFalse(Thread.isMainThread)
            Thread.sleep(forTimeInterval: 0.03)
            try DurableFileWriter.write(data, to: url)
        })
        let start = Date()
        workspace.saveNewEvent(name: "First", venue: "")
        workspace.saveNewEvent(name: "Latest", venue: "Test")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.025)
        await workspace.flush()
        XCTAssertNil(workspace.persistenceError)
        XCTAssertEqual(OperatorWorkspace(directory: directory).snapshot.newEventName, "Latest")
    }

    func testLivePrepaidChangesPreserveRunAndSessionJournalAndSurviveRestart() async throws {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.model.createEvent(name: "Live event", venue: "Original venue")
        await assertStart(f.model, expected: true)
        let runID = try XCTUnwrap(f.runs.currentRunID)
        try f.runs.beginSession(id: "already-captured", runID: runID, format: "solo")
        let journal = try f.runs.session(id: "already-captured")
        let frozenProfile = f.profile
        let live = f.makeModel(live: true)
        live.design?.name = "Renamed live event"
        live.design?.venue = "Next venue"
        live.design?.profile.receiptDesign.editorialCaption = "NEXT GUEST"
        live.design?.guestScreensEnabled = true
        live.design?.profile.customerWelcomeMessage = "Welcome to the next session"
        live.prepaid.activePolicy.maxCopies = 6
        live.prepaid.activePolicy.defaultCopies = 2
        live.prepaid.activePolicy.prepaidGuestCopyChoice = true
        live.prepaid.activePolicy.supportedFormatRawValues = ["solo"]
        XCTAssertEqual(f.profile, frozenProfile, "Staged changes must not leak to guests")
        let result = await live.applyLiveChanges()
        XCTAssertTrue(result, live.message)
        XCTAssertEqual(f.runs.currentRunID, runID); XCTAssertEqual(f.runs.runs.count, 1)
        XCTAssertEqual(try f.runs.session(id: "already-captured"), journal)
        XCTAssertEqual(f.profile.receiptDesign.editorialCaption, "NEXT GUEST")
        XCTAssertEqual(f.local.activePolicy.maxCopies, 6)
        XCTAssertEqual(f.local.venue, "Next venue")
        XCTAssertTrue(f.api.calls.isEmpty)
        let reopened = f.makeModel(live: true)
        XCTAssertEqual(reopened.design?.profile.receiptDesign.editorialCaption, "NEXT GUEST")
        XCTAssertEqual(reopened.prepaid.activePolicy.defaultCopies, 2)
        XCTAssertEqual(EventRunStore(directory: f.directory.appendingPathComponent("runs")).currentRunID, runID)
        XCTAssertEqual(EventDesignLibraryStore(directory: f.directory).design(id: live.designID)?.name, "Renamed live event")
    }

    func testLiveEditsAreStagedDuringGuestAndApplyOnlyWhenGuestFinishes() async throws {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.model.createEvent(name: "Running", venue: "")
        await assertStart(f.model, expected: true)
        let live = f.makeModel(live: true), original = f.profile
        f.blockedReason = "A guest is capturing photos"
        live.design?.profile.receiptDesign.editorialCaption = "NEXT"
        var result = await live.applyLiveChanges()
        XCTAssertFalse(result); XCTAssertEqual(f.profile, original)
        XCTAssertFalse(f.acceptance.state.blocked, "Staging never pauses the active booth")
        f.blockedReason = nil
        result = await live.applyLiveChanges()
        XCTAssertTrue(result, live.message)
    }

    func testLivePaidPolicyUsesVersionedPublishAndSameEventAndRun() async throws {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.paid(); await assertStart(f.model, expected: true)
        let runID = f.runs.currentRunID, eventID = f.acceptance.state.eventID
        let originalPrice = f.api.active?.unitPriceCentavos
        let live = f.makeModel(live: true); await live.refresh()
        live.policy.priceText = "45"; live.policy.cashEnabled = true
        live.policy.maxCopies = 5
        let result = await live.applyLiveChanges()
        XCTAssertTrue(result, live.message)
        XCTAssertEqual(f.runs.currentRunID, runID); XCTAssertEqual(f.runs.runs.count, 1)
        XCTAssertEqual(f.acceptance.state.eventID, eventID)
        XCTAssertEqual(originalPrice, 2500); XCTAssertEqual(f.api.active?.unitPriceCentavos, 4500)
        XCTAssertEqual(f.api.acknowledgements.last?.1, 4500)
        XCTAssertEqual(f.api.calls.filter { $0 == "publish" }.count, 1)
        XCTAssertFalse(f.api.calls.contains("create")); XCTAssertFalse(f.api.calls.contains("end"))
    }

    func testLivePaidCosmeticChangesDoNotPublishUnrelatedServerDraft() async throws {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.model.createEvent(name: "Branded", venue: "Test")
        await f.paid(); await assertStart(f.model, expected: true)
        let live = f.makeModel(live: true); await live.refresh()
        f.api.calls = []
        live.design?.profile.receiptDesign.editorialCaption = "NEW CAPTION"
        let result = await live.applyLiveChanges()
        XCTAssertTrue(result, live.message)
        XCTAssertTrue(f.api.calls.isEmpty, "Cosmetic edits do not save, publish, activate or refetch paid policy")
    }

    func testLiveStaleVersionPreservesEditsAndRunUntilReview() async throws {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.paid(); await assertStart(f.model, expected: true)
        let live = f.makeModel(live: true); await live.refresh()
        let runID = f.runs.currentRunID
        live.policy.priceText = "40"; f.api.version += 1
        let result = await live.applyLiveChanges()
        XCTAssertFalse(result); XCTAssertTrue(live.conflict); XCTAssertTrue(live.needsRefresh)
        XCTAssertEqual(live.policy.priceText, "40"); XCTAssertEqual(f.runs.currentRunID, runID)
        XCTAssertFalse(f.api.calls.contains("publish"))
    }

    func testLiveUnknownPublishNeverReportsSuccessOrRepeatsMutation() async throws {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.paid(); await assertStart(f.model, expected: true)
        let live = f.makeModel(live: true); await live.refresh()
        live.policy.priceText = "40"; f.api.failAfterCommit = "publish"
        var result = await live.applyLiveChanges()
        XCTAssertFalse(result); XCTAssertTrue(live.needsRefresh); XCTAssertTrue(f.acceptance.state.blocked)
        result = await live.applyLiveChanges()
        XCTAssertFalse(result)
        XCTAssertEqual(f.api.calls.filter { $0 == "publish" }.count, 1)
    }

    func testCancelLiveChangesRestoresEarlierUnrelatedDraft() async throws {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.model.createEvent(name: "Running", venue: "")
        await assertStart(f.model, expected: true)
        let id = try XCTUnwrap(f.model.designID)
        var older = try XCTUnwrap(f.library.design(id: id))
        older.name = "Earlier saved draft"; f.workspace.saveDesignDraft(older, id: id)
        let live = f.makeModel(live: true)
        live.reloadDesignFromStorage()
        XCTAssertEqual(live.design?.name, "Running", "Open the applied values, not an unrelated draft")
        live.design?.name = "Discard me"
        live.cancelLiveChanges()
        XCTAssertEqual(live.design?.name, "Running")
        XCTAssertEqual(f.workspace.designDraft(id: id)?.name, "Earlier saved draft")
        XCTAssertEqual(f.profile.eventName, "Running")
    }

    func testRefreshAndCreateDoNotLosePaidLinking() async throws {
        let f = SetupFixture(); defer { f.cleanup() }
        f.model.mode = .serverManaged
        f.api.delaysList = true
        let refresh = Task { await f.model.refresh() }
        while f.api.listGate == nil { await Task.yield() }
        let create = Task { await f.model.createEvent(name: "Concurrent event", venue: "Test") }
        await Task.yield()
        f.api.delaysList = false
        f.api.listGate?.resume(); f.api.listGate = nil
        await refresh.value; await create.value
        XCTAssertEqual(f.library.library.events.count, 1)
        XCTAssertEqual(f.model.targetServerEventID, "event", "A background refresh must not silently discard the paid-link action")
        XCTAssertFalse(f.model.busy)
    }

    func testUnchangedDraftDoesNotRepeatDurableWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var writes = 0
        let workspace = OperatorWorkspace(directory: directory, write: { data, url in
            writes += 1; try DurableFileWriter.write(data, to: url)
        })
        workspace.saveNewEvent(name: "Event", venue: "Test")
        workspace.saveNewEvent(name: "Event", venue: "Test")
        workspace.saveNewEvent(name: "Event", venue: "Test")
        XCTAssertEqual(writes, 1, "Unchanged published state must not flush the same JSON repeatedly")
    }

    func testSavingAnEventDuringRecoveryPreservesAdmissionAndActiveProfile() async throws {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.model.createEvent(name: "Later event", venue: "Garden")
        let before = f.acceptance.state
        let active = f.profile
        f.blockedReason = "Check the previous receipt"
        f.model.prepaid.activePolicy.defaultCopies = 2
        f.model.design?.profile.receiptDesign.editorialCaption = "SAVED FOR LATER"
        XCTAssertNil(f.model.saveValidation)
        XCTAssertEqual(f.model.validation, f.blockedReason)
        await f.model.saveOnly()
        let id = try XCTUnwrap(f.model.designID)
        XCTAssertEqual(f.library.design(id: id)?.prepaidPolicy?.defaultCopies, 2)
        XCTAssertEqual(f.library.design(id: id)?.profile.receiptDesign.editorialCaption, "SAVED FOR LATER")
        XCTAssertEqual(f.acceptance.state, before)
        XCTAssertEqual(f.profile, active)
        XCTAssertTrue(f.runs.runs.isEmpty)
        await assertStart(f.model, expected: false)
        XCTAssertTrue(f.api.calls.isEmpty)
        let restored = f.makeModel()
        XCTAssertEqual(restored.design?.id, id)
        XCTAssertEqual(restored.prepaid.activePolicy.defaultCopies, 2)
    }

    func testUnfinishedLogoCanBeSavedButCannotBeActivated() async throws {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.model.createEvent(name: "Design in progress", venue: "")
        f.model.design?.personalizeReceipt = true
        XCTAssertNil(f.model.saveValidation)
        XCTAssertNotNil(f.model.validation)
        await f.model.saveOnly()
        XCTAssertTrue(f.library.design(id: f.model.designID)?.personalizeReceipt == true)
        await assertStart(f.model, expected: false)
        XCTAssertFalse(f.model.requiresPaymentReview)
        await f.paid()
        XCTAssertTrue(f.model.requiresPaymentReview)
    }

    func testGalleryOverrideIsStagedSavedAndAppliedIndependentlyOfLogo() async throws {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.model.createEvent(name: "Gallery Style", venue: "Cebu")
        f.model.design?.profile.galleryReceiptStyleOverride = .asPrinted
        XCTAssertTrue(f.model.designDirty)
        XCTAssertNil(f.profile.galleryReceiptStyleOverride)
        f.model.saveDesign()
        XCTAssertFalse(f.model.designDirty)
        XCTAssertNil(f.profile.galleryReceiptStyleOverride, "Save Design does not mutate the active profile")
        await assertStart(f.model, expected: true)
        XCTAssertEqual(f.profile.galleryReceiptStyleOverride, .asPrinted)
        XCTAssertNil(f.profile.activeReceiptSnapshot, "Logo-off events still apply the gallery preference")
        f.model.design?.profile.galleryReceiptStyleOverride = .shareFriendly
        XCTAssertEqual(f.profile.galleryReceiptStyleOverride, .asPrinted)
        f.model.saveDesign()
        XCTAssertEqual(f.profile.galleryReceiptStyleOverride, .asPrinted, "Saved edits cannot leak into active sessions")
    }

    func testModeSelectionIsStagedInBothDirectionsAndDraftsSurviveRelaunch() async {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.paid(); f.model.policy.priceText = "35"; f.model.prepaid.activePolicy.maxCopies = 7
        f.model.mode = .localPrepaid; await f.model.setEventMode(true)
        XCTAssertEqual(f.source, .localPrepaid); XCTAssertEqual(f.api.lifecycle, .draft)
        let restored = f.makeModel()
        XCTAssertEqual(restored.mode, .localPrepaid); XCTAssertEqual(restored.prepaid.activePolicy.maxCopies, 7)
        restored.mode = .serverManaged; await restored.select("event")
        XCTAssertEqual(restored.policy.priceText, "35"); XCTAssertTrue(restored.eventModeEnabled)
        XCTAssertFalse(f.acceptance.state.blocked); XCTAssertFalse(f.api.calls.contains("save"))
        f.source = .serverManaged; restored.mode = .localPrepaid
        XCTAssertEqual(f.source, .serverManaged, "Reverse visible selection also stays staged")
    }
    func testFreeActivationNeedsNoPaymentsAndPreservesIncludedCopiesAndFormats() async {
        let f = SetupFixture(); defer { f.cleanup() }
        f.local.lifecycle = .paused
        f.model.prepaid.name = "Wedding"; f.model.prepaid.activePolicy.defaultCopies = 2
        f.model.prepaid.activePolicy.maxCopies = 5; f.model.prepaid.activePolicy.supportedFormatRawValues = ["solo"]
        await f.model.createEvent(name: "Wedding", venue: "Garden")
        await assertStart(f.model, expected: true)
        XCTAssertTrue(f.api.calls.isEmpty); XCTAssertEqual(f.local.lifecycle, .active)
        XCTAssertEqual(f.local.activePolicy.commercialMode, .privatePrepaid); XCTAssertEqual(f.local.activePolicy.unitPriceCentavos, 0)
        XCTAssertEqual(f.local.activePolicy.defaultCopies, 2); XCTAssertEqual(f.local.activePolicy.supportedFormatRawValues, ["solo"])
        XCTAssertEqual(f.applied.last?.eventName, "Wedding"); XCTAssertEqual(f.local.name, "Wedding")
        XCTAssertEqual(f.applied.last?.isEnabled, false, "An event without a logo prints the standard receipt")
        XCTAssertFalse(f.acceptance.state.blocked)
    }
    func testPaidActivationAcknowledgesExactSavedPriceAndCommitsModeOnlyAfterConfirmation() async {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.paid(); f.model.policy.priceText = "35"; f.model.policy.maxCopies = 5
        await assertStart(f.model, expected: true)
        XCTAssertEqual(f.source, .serverManaged); XCTAssertEqual(f.api.latest.unitPriceCentavos, 3500)
        XCTAssertEqual(f.api.latest.maxCopies, 5); XCTAssertEqual(f.api.acknowledgements.count, 1)
        XCTAssertEqual(f.api.acknowledgements.first?.0, "r2"); XCTAssertEqual(f.api.acknowledgements.first?.1, 3500)
        XCTAssertFalse(f.acceptance.state.blocked); XCTAssertEqual(f.acceptance.state.eventID, "event")
        XCTAssertEqual(SessionAcceptanceStore(directory: f.directory).state.mode, .serverManaged)
        XCTAssertEqual(f.applied.count, 1); XCTAssertFalse(f.applied[0].isEventModeActive)
        XCTAssertEqual(f.api.calls.filter { $0 == "save" }.count, 1)
    }
    func testSaveWithoutStartingNeverChangesSourceOrPublishes() async {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.paid(); f.model.policy.priceText = "35"; await f.model.saveOnly()
        XCTAssertEqual(f.api.latest.unitPriceCentavos, 3500); XCTAssertEqual(f.api.lifecycle, .draft)
        XCTAssertNil(f.api.active); XCTAssertEqual(f.source, .localPrepaid)
        XCTAssertFalse(f.api.calls.contains("activate")); XCTAssertFalse(f.api.calls.contains("publish"))
    }
    func testUnknownSaveClosesGateAcrossRelaunchAndNeverAutomaticallyRetriesMutation() async {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.paid(); f.model.policy.priceText = "35"; f.api.failAfterCommit = "save"
        await assertStart(f.model, expected: false)
        XCTAssertTrue(SessionAcceptanceStore(directory: f.directory).state.blocked)
        XCTAssertEqual(f.source, .localPrepaid); XCTAssertEqual(f.api.calls.filter { $0 == "save" }.count, 1)
        XCTAssertTrue(f.model.needsRefresh); XCTAssertEqual(f.model.policy.priceText, "35")
        await assertStart(f.model, expected: false); XCTAssertFalse(f.api.calls.contains("activate"))
        await f.model.refresh(); XCTAssertTrue(f.model.conflict)
        f.model.keepReviewedEdits(); f.api.failAfterCommit = nil
        await assertStart(f.model, expected: true)
        XCTAssertEqual(f.api.calls.filter { $0 == "save" }.count, 1, "The committed save is reused after explicit status check and review")
    }
    func testUnknownActivationReportsActiveServerButBoothRemainsPausedUntilExplicitRetry() async {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.paid(); f.api.failAfterCommit = "activate"
        await assertStart(f.model, expected: false); XCTAssertEqual(f.api.lifecycle, .active)
        XCTAssertEqual(f.source, .localPrepaid); XCTAssertTrue(f.acceptance.state.blocked)
        XCTAssertTrue(f.model.message.contains("Currently Active")); XCTAssertEqual(f.api.calls.filter { $0 == "activate" }.count, 1)
        await f.model.refresh(); f.model.keepReviewedEdits(); f.api.failAfterCommit = nil
        await assertStart(f.model, expected: true); XCTAssertEqual(f.api.calls.filter { $0 == "activate" }.count, 1)
    }
    func testPaidToFreePausesServerBeforeCommittingFreeMode() async {
        let f = SetupFixture(); defer { f.cleanup() }
        f.source = .serverManaged; f.api.lifecycle = .active; f.api.active = f.api.latest
        f.model.mode = .localPrepaid
        await assertStart(f.model, expected: true)
        XCTAssertEqual(f.api.lifecycle, .paused); XCTAssertEqual(f.source, .localPrepaid)
        XCTAssertEqual(f.local.lifecycle, .active); XCTAssertFalse(f.acceptance.state.blocked)
    }
    func testInterruptedPaidToFreeTransitionNeverOpensFreeSessions() async {
        let f = SetupFixture(); defer { f.cleanup() }
        f.source = .serverManaged; f.api.lifecycle = .active; f.api.active = f.api.latest; f.api.failAfterCommit = "pause"
        f.model.mode = .localPrepaid
        await assertStart(f.model, expected: false); XCTAssertEqual(f.source, .serverManaged)
        XCTAssertTrue(f.acceptance.state.blocked); XCTAssertEqual(f.api.lifecycle, .paused)
    }
    func testStaleServerVersionPreservesLocalEditsAndRequiresReview() async {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.paid(); f.model.policy.priceText = "40"; f.api.version += 1
        await assertStart(f.model, expected: false); XCTAssertTrue(f.model.conflict)
        XCTAssertEqual(f.model.policy.priceText, "40"); XCTAssertFalse(f.api.calls.contains("save"))
        await f.model.refresh(); f.model.keepReviewedEdits()
        await assertStart(f.model, expected: true); XCTAssertEqual(f.api.latest.unitPriceCentavos, 4000)
    }
    func testLockDuringActivationPreventsSourceCommit() async {
        let f = SetupFixture(); defer { f.cleanup() }
        await f.paid(); f.api.onTransition = { f.permitted = false }
        await assertStart(f.model, expected: false); XCTAssertEqual(f.source, .localPrepaid)
        XCTAssertTrue(f.acceptance.state.blocked); XCTAssertTrue(f.applied.isEmpty)
    }
    func testFulfillmentBlocksSwitchingButDoesNotBlockPausingNewSessions() async {
        let f = SetupFixture(); defer { f.cleanup() }
        f.blockedReason = "A guest is printing"
        await assertStart(f.model, expected: false)
        await f.model.pause()
        XCTAssertEqual(f.local.lifecycle, .paused); XCTAssertTrue(f.acceptance.state.blocked)
    }
    func testAcceptanceBindingAndCorruptStateFailClosedWithoutOverwritingOriginal() throws {
        let f = SetupFixture(); defer { f.cleanup() }
        try f.acceptance.save(.init(blocked: false, eventID: "event", serverBinding: "live:example"))
        XCTAssertTrue(f.acceptance.permits(eventID: "event", binding: "live:example"))
        XCTAssertFalse(f.acceptance.permits(eventID: "other", binding: "live:example"))
        XCTAssertFalse(f.acceptance.permits(eventID: "event", binding: "test:example"))
        let file = f.directory.appendingPathComponent("SessionAcceptanceV1/state.json")
        let corrupt = Data("incomplete".utf8); try corrupt.write(to: file)
        let restored = SessionAcceptanceStore(directory: f.directory)
        XCTAssertTrue(restored.state.blocked); XCTAssertThrowsError(try restored.save(.init()))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
    func testPaidAdmissionDoesNotDependOnPausedOrInvalidPrepaidSettings() {
        var local = CommercialEventRun.legacy; local.lifecycle = .paused; local.activePolicy.maxCopies = 0
        XCTAssertTrue(SessionAdmission.localConfigurationIsReady(source: .serverManaged, local: local))
        XCTAssertFalse(SessionAdmission.localConfigurationIsReady(source: .localPrepaid, local: local))
    }
    func testLegacyWorkspaceStillDecodesWithoutSessionSetupFields() throws {
        let data = Data(#"{"schemaVersion":1,"resumeSetup":true,"path":[{"charging":{}}],"serverDrafts":{},"newEventName":"","newEventVenue":""}"#.utf8)
        let restored = try JSONDecoder().decode(OperatorWorkspace.Snapshot.self, from: data)
        XCTAssertNil(restored.sessionSetup); XCTAssertEqual(restored.path, [.charging])
    }
    func testUnifiedAndMaintenanceRoutesRoundTripWithoutLosingSavedNavigation() throws {
        let routes: [OperatorWorkspaceRoute] = [.sessionSetup, .branding, .sales, .eventReport("event"), .eventMaintenance("event")]
        XCTAssertEqual(try JSONDecoder().decode([OperatorWorkspaceRoute].self, from: JSONEncoder().encode(routes)), routes)
        XCTAssertEqual(OperatorWorkspaceRoute.charging.title, "Event Setup", "A legacy saved route opens the unified setup")
        XCTAssertEqual(OperatorWorkspaceRoute.manageEvent.title, "Event Library & History")
        XCTAssertEqual(OperatorWorkspaceRoute.sales.title, "Reports & Statistics")
    }
    func testTurningTheLogoOffKeepsTheSavedDesignButPrintsTheStandardReceipt() throws {
        var design = SavedEventDesign.new(name: "Wedding", venue: "Garden")
        design.profile.receiptHeader.assetIdentifier = "8a6f3a8e-4a52-4cc4-9a1b-8bb1f0d3a111"
        design.personalizeReceipt = true
        let personalized = design.appliedProfile()
        XCTAssertTrue(personalized.isEnabled); XCTAssertEqual(personalized.receiptHeader.mode, .customEventHeader)
        XCTAssertEqual(personalized.receiptHeader.brandingMode, .coBranded)
        design.personalizeReceipt = false
        let standard = design.appliedProfile()
        XCTAssertFalse(standard.isEnabled); XCTAssertNil(standard.activeReceiptSnapshot)
        XCTAssertEqual(standard.receiptHeader.assetIdentifier, personalized.receiptHeader.assetIdentifier, "The saved logo is kept")
        XCTAssertEqual(standard.receiptDesign, personalized.receiptDesign)
    }
    func testLegacyPhotoPassFormatRemainsEnabledAndIsNotSilentlyDroppedFromSavedSetup() throws {
        let f = SetupFixture(); defer { f.cleanup() }
        var draft = ServerPolicyDraft(revision: f.api.latest)
        XCTAssertTrue(draft.supports(.passport))
        XCTAssertEqual(BoothFormat.passport.paymentRawValue(in: f.api.latest.supportedFormats), "photoPass")
        XCTAssertTrue(try XCTUnwrap(draft.requestBody()).supportedFormats.contains("photoPass"))
        var policy = PaymentPolicySnapshot.legacyPrepaid
        policy.supportedFormatRawValues = ["photoPass"]
        XCTAssertTrue(policy.supports(.passport)); XCTAssertFalse(policy.supports(.solo))
        draft.setFormat(.passport, enabled: false)
        XCTAssertFalse(draft.supports(.passport))
        draft.setFormat(.passport, enabled: true)
        XCTAssertTrue(draft.supports(.passport)); XCTAssertTrue(draft.supportedFormats.contains("passport"))
    }

    func testRenderActualOperatorScreensForVisualReview() async throws {
        let f = SetupFixture(); defer { f.cleanup() }
        try await snapshot("operator-home", view: NavigationStack { OperatorDashboardView() })
        try await snapshot("prepaid-setup", view: NavigationStack { SessionSetupView(coordinator: f.model) })
        await f.paid()
        try await snapshot("paid-setup", view: NavigationStack { SessionSetupView(coordinator: f.model) })
        try await snapshot("paid-review", view: SessionSetupReviewView(setup: f.model, onBack: {}, onFinished: { _ in }))
    }
    func testAppliedDesignIdentityFailureKeepsAdmissionClosed() async {
        let f = SetupFixture(); defer { f.cleanup() }
        var fail = false
        let library = EventDesignLibraryStore(directory: f.directory.appendingPathComponent("identity-fault"), write: { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try DurableFileWriter.write(data, to: url)
        }, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" })
        let model = SessionSetupCoordinator(workspace: f.workspace, acceptance: f.acceptance, library: library, eventRuns: f.runs, creations: CommercialEventCreationStore(directory: f.directory),
            api: { f.api }, authorized: { true }, blockingReason: { nil }, loadLocal: { f.local }, saveLocal: { f.local = $0 },
            source: { f.source }, saveSource: { f.source = $0 }, currentProfile: { f.profile }, applyProfile: { f.profile = $0 })
        await model.createEvent(name: "Identity write under test", venue: "")
        model.design?.prepaidPolicy = model.prepaid.activePolicy
        model.saveDesign()
        fail = true
        let started = await model.startAccepting()
        XCTAssertFalse(started)
        XCTAssertTrue(f.acceptance.state.blocked)
        XCTAssertTrue(model.message.contains("not confirmed"))
    }

    private func snapshot<V: View>(_ name: String, view: V) async throws {
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(image.pngData()?.count ?? 0, 30_000, "A blank render cannot provide visual validation")
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
