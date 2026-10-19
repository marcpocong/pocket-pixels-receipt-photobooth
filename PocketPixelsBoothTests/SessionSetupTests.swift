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
    var failAfterCommit: String?
    var onTransition: (() -> Void)?
    var barrier: (() -> Bool)?
    var acknowledgements: [(String?, Int?)] = []
    @MainActor func listEvents() async throws -> [OperatorEventSummary] {
        calls.append("list")
        return [.init(id: "event", name: name, venue: venue, lifecycle: lifecycle.rawValue,
            activePolicyRevisionId: active?.id, version: version, updatedAt: Date())]
    }
    @MainActor func eventDetail(id: String) async throws -> OperatorEventDetail {
        calls.append("detail")
        return .init(event: .init(id: "event", name: name, venue: venue, lifecycle: lifecycle, version: version,
            updatedAt: Date(), activePolicyRevisionId: active?.id), activePolicy: active, latestRevision: latest,
            hasUnpublishedRevision: latest.id != active?.id, outstandingEntitlements: 0, serverTime: Date())
    }
    @MainActor func eventCreation(operationID: String) async throws -> OperatorEventCreationLookup {
        throw PaymentsAPIError.rejected(code: "not_found", message: "missing", status: 404, details: Data())
    }
    @MainActor func createEvent(name: String, venue: String, operationID: String) async throws -> OperatorCreatedEvent {
        calls.append("create"); self.name = name; self.venue = venue
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
    func makeModel() -> SessionSetupCoordinator {
        .init(workspace: workspace, acceptance: acceptance, library: library, eventRuns: runs, creations: CommercialEventCreationStore(directory: directory), api: { self.api }, authorized: { self.permitted },
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
