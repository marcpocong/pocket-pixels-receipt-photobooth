import XCTest
import SwiftUI
import UIKit
@testable import PocketPixelsBooth

// MARK: - Multi-event payments stub

@MainActor private final class MatrixAPIStub: SessionSetupAPI {
    struct Event { var name: String; var venue: String; var lifecycle: CommercialEventLifecycle; var version: Int; var latest: OperatorPolicyRevision?; var active: OperatorPolicyRevision? }
    var events: [String: Event] = [:]
    var calls: [String] = []
    private var counter = 0

    @MainActor func listEvents() async throws -> [OperatorEventSummary] {
        calls.append("list")
        return events.map { .init(id: $0.key, name: $0.value.name, venue: $0.value.venue, lifecycle: $0.value.lifecycle.rawValue,
                                  activePolicyRevisionId: $0.value.active?.id, version: $0.value.version, updatedAt: Date()) }
    }
    @MainActor func eventDetail(id: String) async throws -> OperatorEventDetail {
        calls.append("detail:\(id)")
        guard let event = events[id] else { throw SetupFailure("missing \(id)") }
        return .init(event: .init(id: id, name: event.name, venue: event.venue, lifecycle: event.lifecycle, version: event.version,
                                  updatedAt: Date(), activePolicyRevisionId: event.active?.id),
                     activePolicy: event.active, latestRevision: event.latest, hasUnpublishedRevision: event.latest?.id != event.active?.id,
                     outstandingEntitlements: 0, serverTime: Date())
    }
    @MainActor func eventCreation(operationID: String) async throws -> OperatorEventCreationLookup {
        throw PaymentsAPIError.rejected(code: "not_found", message: "missing", status: 404, details: Data())
    }
    @MainActor func createEvent(name: String, venue: String, operationID: String) async throws -> OperatorCreatedEvent {
        counter += 1
        let id = "srv-\(counter)"
        calls.append("create:\(name)")
        events[id] = Event(name: name, venue: venue, lifecycle: .draft, version: 1, latest: nil, active: nil)
        return .init(id: id, lifecycle: "DRAFT", version: 1)
    }
    @MainActor func saveDraft(eventID: String, expectedVersion: Int, name: String, venue: String, policy: ServerPolicyDraft.RequestBody) async throws -> OperatorEventUpdate {
        calls.append("save:\(eventID)")
        guard var event = events[eventID], event.version == expectedVersion else { throw SetupFailure("version conflict") }
        let revision = (event.latest?.revision ?? 0) + 1
        event.latest = .init(id: "\(eventID)-r\(revision)", revision: revision, commercialMode: .payPerPrint, unitPriceCentavos: policy.unitPriceCentavos,
                             maxCopies: policy.maxCopies, defaultCopies: policy.defaultCopies, cashEnabled: policy.cashEnabled, qrphEnabled: policy.qrphEnabled,
                             prepaidGuestCopyChoice: false, supportedFormats: policy.supportedFormats, offlineValidUntil: policy.offlineValidUntil,
                             createdAt: Date(), activatedAt: nil)
        event.name = name; event.venue = venue; event.version += 1
        events[eventID] = event
        return .init(eventId: eventID, version: event.version, draftRevision: event.latest!)
    }
    @MainActor func transitionEvent(id: String, action: String, expectedVersion: Int, policyRevisionID: String?, acknowledgedUnitPriceCentavos: Int?) async throws -> OperatorEventTransition {
        calls.append("\(action):\(id)")
        guard var event = events[id], event.version == expectedVersion else { throw SetupFailure("version conflict") }
        if action == "activate" || action == "publish" { event.active = event.latest }
        if action == "activate" || action == "resume" { event.lifecycle = .active }
        if action == "pause" { event.lifecycle = .paused }
        event.version += 1
        events[id] = event
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
}

@MainActor private final class MatrixFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("matrix-\(UUID())")
    let workspace: OperatorWorkspace
    let acceptance: SessionAcceptanceStore
    var library: EventDesignLibraryStore
    let api = MatrixAPIStub()
    var source = CommercialPolicySource.localPrepaid
    var local = CommercialEventRun.legacy
    var profile = EventProfile.pocketPixelsDefault
    var applied: [EventProfile] = []
    var usable: Set<String> = []
    lazy var runs = EventRunStore(directory: directory.appendingPathComponent("runs"), authorized: { true }, blockingReason: { nil })
    lazy var model = makeModel()

    init() {
        workspace = OperatorWorkspace(directory: directory)
        acceptance = SessionAcceptanceStore(directory: directory)
        library = EventDesignLibraryStore(directory: directory, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" })
    }
    func makeModel() -> SessionSetupCoordinator {
        .init(workspace: workspace, acceptance: acceptance, library: library, eventRuns: runs, creations: CommercialEventCreationStore(directory: directory), api: { self.api }, authorized: { true }, blockingReason: { nil },
              loadLocal: { self.local }, saveLocal: { self.local = $0 }, source: { self.source }, saveSource: { self.source = $0 },
              currentProfile: { self.profile }, applyProfile: { self.profile = $0; self.applied.append($0) },
              artworkAvailable: { $0.map(self.usable.contains) ?? false })
    }
    func relaunch() -> SessionSetupCoordinator {
        library = EventDesignLibraryStore(directory: directory, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" })
        return makeModel()
    }
    func addLogo(to model: SessionSetupCoordinator, id: String = UUID().uuidString.lowercased()) -> String {
        usable.insert(id)
        model.design?.personalizeReceipt = true
        model.design?.profile.receiptHeader.assetIdentifier = id
        return id
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

// MARK: - Event Mode × logo × payment matrix

@MainActor final class EventSetupAndPaymentMatrixTests: XCTestCase {
    private func start(_ model: SessionSetupCoordinator, file: StaticString = #filePath, line: UInt = #line) async {
        let started = await model.startAccepting()
        XCTAssertTrue(started, "\(model.validation ?? "") \(model.message)", file: file, line: line)
    }

    func testViewingAppliedAndPausedSetupDoesNotLeaveFalseDrafts() async {
        let f = MatrixFixture(); defer { f.cleanup() }
        await f.model.choosePayment(.cashOnly)
        await f.model.connectPaidCheckout()
        f.model.policy.priceText = "1.00"
        await start(f.model)
        let revisited = f.relaunch()
        await revisited.refresh()
        XCTAssertNil(f.workspace.snapshot.sessionSetup)
        XCTAssertFalse(f.workspace.hasPendingSetup)
        await revisited.pause()
        XCTAssertTrue(f.acceptance.state.blocked)
        XCTAssertTrue(f.workspace.snapshot.serverDrafts.isEmpty)
        let paused = f.relaunch()
        await paused.refresh()
        XCTAssertNil(f.workspace.snapshot.sessionSetup)
        XCTAssertFalse(f.workspace.hasPendingSetup)
        paused.policy.priceText = "2.00"
        XCTAssertTrue(f.workspace.hasPendingSetup, "A real price change still survives exit")
    }

    func testTargetedPaymentReviewIsReadOnlyAndCapturesOriginalBaselineOnEdit() async {
        let f = MatrixFixture(); defer { f.cleanup() }
        await f.model.choosePayment(.cashOnly)
        await f.model.connectPaidCheckout()
        f.model.policy.priceText = "1.00"
        await start(f.model)
        let id = f.model.selectedID!
        let target = SavedDraftID.payment(binding: f.workspace.serverBinding, eventID: id)
        let selection = OperatorSessionSetupDraft(mode: .localPrepaid, eventID: nil, serverBinding: f.workspace.serverBinding, eventModeEnabled: false)
        f.workspace.saveSessionSetup(selection)
        f.api.calls = []
        let review = SessionSetupCoordinator(draftTarget: target, workspace: f.workspace, acceptance: f.acceptance, library: f.library,
            api: { f.api }, authorized: { true }, blockingReason: { nil }, loadLocal: { f.local }, source: { f.source }, currentProfile: { f.profile })
        await review.refresh()
        XCTAssertFalse(f.api.calls.contains { $0.hasPrefix("save:") || $0.hasPrefix("create:") || $0.hasPrefix("activate:") || $0.hasPrefix("publish:") })
        XCTAssertEqual(f.workspace.snapshot.sessionSetup, selection)
        review.policy.priceText = "2.00"
        let draft = f.workspace.serverDraft(eventID: id)
        XCTAssertEqual(draft?.baseline?.policy.unitPriceCentavos, 100)
        XCTAssertEqual(draft?.policy.unitPriceCentavos, 200)
        f.api.events[id]?.version += 1
        let detail = try! await f.api.eventDetail(id: id)
        let entries = SavedDraftCatalog.entries(workspace: f.workspace, library: f.library.library, remote: [target: detail])
        XCTAssertTrue(entries.first { $0.id == target }?.notice?.contains("changed") == true)
    }

    func testDifferentConnectionDraftReviewNeverContactsCurrentServer() async {
        let f = MatrixFixture(); defer { f.cleanup() }
        let review = SessionSetupCoordinator(draftTarget: .payment(binding: "another-server", eventID: "pilot"), workspace: f.workspace,
            acceptance: f.acceptance, library: f.library, api: { f.api }, authorized: { true }, blockingReason: { nil })
        await review.refresh()
        XCTAssertTrue(f.api.calls.isEmpty)
        XCTAssertTrue(review.needsRefresh)
    }

    func testEventOffWithEveryPaymentChoiceUsesTheStudioReceipt() async {
        for choice in GuestPaymentChoice.allCases {
            let f = MatrixFixture(); defer { f.cleanup() }
            await f.model.choosePayment(choice)
            if choice.isPaid {
                await f.model.connectPaidCheckout()
                f.model.policy.priceText = "25"
            }
            await start(f.model)
            XCTAssertFalse(f.applied.last!.isEventModeActive, "\(choice)")
            XCTAssertEqual(f.source, choice.isPaid ? .serverManaged : .localPrepaid)
            if choice.isPaid {
                let event = f.api.events.values.first!
                XCTAssertEqual(event.name, SessionSetupCoordinator.regularEventName)
                XCTAssertEqual(event.active?.qrphEnabled, choice.acceptsQRPh)
                XCTAssertEqual(event.active?.cashEnabled, choice.acceptsCash)
                XCTAssertEqual(event.active?.unitPriceCentavos, 2500)
            } else {
                XCTAssertTrue(f.api.calls.isEmpty, "Free mode never contacts the payments server")
                XCTAssertEqual(f.local.activePolicy.unitPriceCentavos, 0)
                XCTAssertFalse(f.local.activePolicy.cashEnabled || f.local.activePolicy.qrPhEnabled)
            }
        }
    }

    func testRevisitingSetupNeverCreatesDuplicatePaidEvents() async {
        let f = MatrixFixture(); defer { f.cleanup() }
        await f.model.choosePayment(.qrOnly)
        await f.model.connectPaidCheckout()
        let again = f.relaunch()
        await again.refresh()
        await again.connectPaidCheckout()
        XCTAssertEqual(f.api.calls.filter { $0.hasPrefix("create:") }.count, 1)
        XCTAssertEqual(again.targetServerEventID, "srv-1")
    }

    func testExistingRegularSessionsNamesAreReusedWithoutChangingServerPolicy() async throws {
        for name in ["Regular Sessions", "Made to Keep Studios — Regular Sessions"] {
            let f = MatrixFixture(); defer { f.cleanup() }
            let original = try await f.api.createEvent(name: name, venue: "Existing venue", operationID: UUID().uuidString)
            var policy = ServerPolicyDraft()
            policy.priceText = "25"; policy.maxCopies = 3; policy.defaultCopies = 1
            _ = try await f.api.saveDraft(eventID: original.id, expectedVersion: 1, name: name, venue: "Existing venue", policy: XCTUnwrap(policy.requestBody()))
            f.api.calls.removeAll()
            await f.model.choosePayment(.qrOnly)
            await f.model.connectPaidCheckout()
            XCTAssertEqual(f.model.targetServerEventID, original.id)
            XCTAssertEqual(f.model.policy.requestBody()?.unitPriceCentavos, 2500)
            XCTAssertEqual(f.model.policy.maxCopies, 3)
            XCTAssertEqual(f.api.events.count, 1)
            XCTAssertFalse(f.api.calls.contains { $0.hasPrefix("create:") || $0.hasPrefix("save:") || $0.hasPrefix("activate:") })
            XCTAssertEqual(f.api.events[original.id]?.lifecycle, .draft)
        }
    }

    func testAmbiguousRegularSessionsDoNotCreateOrChooseAnotherEvent() async throws {
        let f = MatrixFixture(); defer { f.cleanup() }
        _ = try await f.api.createEvent(name: "Regular Sessions", venue: "", operationID: UUID().uuidString)
        _ = try await f.api.createEvent(name: "Made to Keep Studios — Regular Sessions", venue: "", operationID: UUID().uuidString)
        f.api.calls.removeAll()
        await f.model.choosePayment(.qrOnly)
        await f.model.connectPaidCheckout()
        XCTAssertNil(f.model.targetServerEventID)
        XCTAssertEqual(f.api.events.count, 2)
        XCTAssertTrue(f.model.needsRefresh)
        XCTAssertFalse(f.api.calls.contains { $0.hasPrefix("create:") })
    }

    func testEventOnLogoOffFreeAppliesEventScreensButStandardReceipt() async {
        let f = MatrixFixture(); defer { f.cleanup() }
        await f.model.createEvent(name: "Garden Wedding", venue: "Cebu")
        f.model.design?.guestScreensEnabled = true
        await start(f.model)
        let applied = f.applied.last!
        XCTAssertNil(applied.activeReceiptSnapshot, "No logo: the ordinary Made to Keep receipt")
        XCTAssertNotNil(applied.activeCustomerSnapshot)
        XCTAssertEqual(applied.customerDisplayTitle, "Garden Wedding")
        XCTAssertEqual(f.local.name, "Garden Wedding")
    }

    func testFreeEventWithCoBrandedReceipt() async {
        let f = MatrixFixture(); defer { f.cleanup() }
        await f.model.createEvent(name: "CIM Ball", venue: "")
        let logo = f.addLogo(to: f.model)
        XCTAssertNil(f.model.validation)
        await start(f.model)
        let applied = f.applied.last!
        XCTAssertTrue(applied.isEnabled)
        XCTAssertEqual(applied.receiptHeader.mode, .customEventHeader)
        XCTAssertEqual(applied.receiptHeader.brandingMode, .coBranded)
        XCTAssertEqual(applied.receiptHeader.assetIdentifier, logo)
        XCTAssertFalse(f.model.designDirty, "Starting saves the reviewed design")
        XCTAssertEqual(f.library.design(id: f.model.designID!)?.logoIdentifier, logo)
    }

    func testPaidEventWithStandardReceiptConnectsOnceAndCarriesTheEventName() async {
        let f = MatrixFixture(); defer { f.cleanup() }
        await f.model.choosePayment(.cashOnly)
        await f.model.createEvent(name: "Night Market", venue: "IT Park")
        f.model.policy.priceText = "30"
        await start(f.model)
        let event = f.api.events["srv-1"]!
        XCTAssertEqual(event.name, "Night Market")
        XCTAssertEqual(event.active?.cashEnabled, true); XCTAssertEqual(event.active?.qrphEnabled, false)
        XCTAssertNil(f.applied.last!.activeReceiptSnapshot)
        XCTAssertEqual(f.library.design(id: f.model.designID!)?.serverEventID(binding: f.workspace.serverBinding), "srv-1")
    }

    func testPersonalizedReceiptRequiresAUsableLogo() async {
        let f = MatrixFixture(); defer { f.cleanup() }
        await f.model.createEvent(name: "Gala", venue: "")
        f.model.design?.personalizeReceipt = true
        XCTAssertEqual(f.model.validation, "Add an event logo, or turn off Personalize Receipt.")
        f.model.design?.profile.receiptHeader.assetIdentifier = UUID().uuidString.lowercased()
        XCTAssertEqual(f.model.validation, "The saved logo can’t be read. Choose another file, or turn off Personalize Receipt.")
        let started = await f.model.startAccepting()
        XCTAssertFalse(started); XCTAssertTrue(f.applied.isEmpty)
        f.model.design?.personalizeReceipt = false
        XCTAssertNil(f.model.validation)
    }

    func testTurningLogoOrEventModeOffKeepsTheSavedArtwork() async {
        let f = MatrixFixture(); defer { f.cleanup() }
        await f.model.createEvent(name: "Gala", venue: "")
        let logo = f.addLogo(to: f.model)
        f.model.saveDesign()
        f.model.design?.personalizeReceipt = false
        await start(f.model)
        XCTAssertNil(f.applied.last!.activeReceiptSnapshot)
        XCTAssertEqual(f.library.design(id: f.model.designID!)?.logoIdentifier, logo, "Turning the logo off never deletes it")
        await f.model.setEventMode(false)
        await start(f.model)
        XCTAssertFalse(f.applied.last!.isEventModeActive)
        XCTAssertEqual(f.library.design(id: f.model.designID!)?.logoIdentifier, logo)
        await f.model.setEventMode(true)
        f.model.design?.personalizeReceipt = true
        await start(f.model)
        XCTAssertEqual(f.applied.last!.receiptHeader.assetIdentifier, logo, "The saved logo returns with personalization")
    }

    func testSwitchingEventsNeverCarriesAnotherEventsLogo() async {
        let f = MatrixFixture(); defer { f.cleanup() }
        await f.model.createEvent(name: "Event A", venue: "")
        let logoA = f.addLogo(to: f.model)
        let idA = f.model.designID!
        await f.model.createEvent(name: "Event B", venue: "")
        XCTAssertNil(f.model.design?.logoIdentifier)
        XCTAssertFalse(f.model.design!.personalizeReceipt)
        await start(f.model)
        XCTAssertNil(f.applied.last!.receiptHeader.assetIdentifier)
        await f.model.chooseDesign(idA)
        XCTAssertEqual(f.model.design?.logoIdentifier, logoA, "Event A's unsaved draft is kept for Event A only")
        await start(f.model)
        XCTAssertEqual(f.applied.last!.receiptHeader.assetIdentifier, logoA)
        XCTAssertEqual(f.applied.last!.eventName, "Event A")
    }

    func testSavedEventAndDraftsAreRestoredAfterRelaunch() async {
        let f = MatrixFixture(); defer { f.cleanup() }
        await f.model.createEvent(name: "Reunion", venue: "")
        let logo = f.addLogo(to: f.model)
        await f.model.choosePayment(.qrAndCash)
        let restored = f.relaunch()
        XCTAssertTrue(restored.eventModeEnabled)
        XCTAssertEqual(restored.design?.name, "Reunion")
        XCTAssertEqual(restored.design?.logoIdentifier, logo, "Unsaved logo draft survives a force quit")
        XCTAssertTrue(restored.designDirty)
        XCTAssertEqual(restored.mode, .serverManaged)
        XCTAssertEqual(restored.paymentChoice, .qrAndCash, "The chosen payment method is never silently reset")
    }

    func testPaymentChoiceAppliesToTheLoadedPolicyAndClearsOfflineCashWithCash() async {
        let f = MatrixFixture(); defer { f.cleanup() }
        await f.model.choosePayment(.qrAndCash)
        await f.model.connectPaidCheckout()
        XCTAssertTrue(f.model.policy.qrPhEnabled); XCTAssertTrue(f.model.policy.cashEnabled)
        f.model.policy.offlineCashEnabled = true
        await f.model.choosePayment(.qrOnly)
        XCTAssertTrue(f.model.policy.qrPhEnabled); XCTAssertFalse(f.model.policy.cashEnabled)
        XCTAssertFalse(f.model.policy.offlineCashEnabled, "Offline cash is never left on without cash")
        await f.model.choosePayment(.cashOnly)
        XCTAssertFalse(f.model.policy.qrPhEnabled); XCTAssertTrue(f.model.policy.cashEnabled)
        XCTAssertFalse(f.model.policy.offlineCashEnabled, "Offline cash is never enabled silently")
        await f.model.choosePayment(.noPayment)
        XCTAssertEqual(f.model.mode, .localPrepaid)
        await f.model.choosePayment(.cashOnly)
        XCTAssertEqual(f.model.paymentChoice, .cashOnly, "Switching to free and back keeps the paid draft")
    }

    func testQRMinimumAndEmptyMethodsAreRejected() async {
        let f = MatrixFixture(); defer { f.cleanup() }
        await f.model.choosePayment(.qrOnly)
        await f.model.connectPaidCheckout()
        f.model.policy.priceText = "0.50"
        XCTAssertEqual(f.model.validation, "QR Ph needs a price of at least ₱1.00 per copy.")
        await f.model.choosePayment(.cashOnly)
        XCTAssertNil(f.model.validation, "Cash-only may charge under ₱1")
        f.model.policy.cashEnabled = false; f.model.policy.qrPhEnabled = false
        XCTAssertEqual(f.model.validation, "Enable QR Ph, Cash, or both.")
    }

    func testPaidToFreeEventPausesTheRemoteEventFirst() async {
        let f = MatrixFixture(); defer { f.cleanup() }
        await f.model.choosePayment(.qrOnly)
        await f.model.createEvent(name: "Expo", venue: "")
        f.model.policy.priceText = "25"
        await start(f.model)
        XCTAssertEqual(f.api.events["srv-1"]?.lifecycle, .active)
        await f.model.choosePayment(.noPayment)
        await start(f.model)
        XCTAssertEqual(f.api.events["srv-1"]?.lifecycle, .paused)
        XCTAssertEqual(f.source, .localPrepaid)
        XCTAssertEqual(f.local.name, "Expo")
    }

    func testExistingInstallsKeepTheirCommittedPaidEventWithoutRelinking() async throws {
        let f = MatrixFixture(); defer { f.cleanup() }
        _ = try await f.api.createEvent(name: "Legacy Paid", venue: "", operationID: UUID().uuidString)
        try f.acceptance.save(.init(blocked: false, eventID: "srv-1", serverBinding: f.workspace.serverBinding, mode: .serverManaged))
        f.source = .serverManaged
        await f.model.refresh()
        XCTAssertEqual(f.model.targetServerEventID, "srv-1")
        XCTAssertEqual(f.model.selectedID, "srv-1")
        XCTAssertEqual(f.api.calls.filter { $0.hasPrefix("create:") }.count, 1)
    }

    func testSaveDesignNeverReportsSuccessWhenTheWriteFails() async {
        let f = MatrixFixture(); defer { f.cleanup() }
        await f.model.createEvent(name: "Fair", venue: "")
        f.library = EventDesignLibraryStore(directory: f.directory, write: { _, _ in throw CocoaError(.fileWriteNoPermission) },
                                            legacyProfile: { .pocketPixelsDefault }, legacyName: { "" })
        let model = f.makeModel()
        model.design?.venue = "Hall"
        model.saveDesign()
        XCTAssertFalse(model.message.hasPrefix("Design saved"), model.message)
        XCTAssertTrue(model.message.contains("could not be saved"), model.message)
        XCTAssertTrue(model.designDirty)
        XCTAssertNotEqual(f.library.design(id: model.designID!)?.venue, "Hall")
    }
}

// MARK: - Library

@MainActor final class EventDesignLibraryTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID())") }

    func testServerLinksAreSeparatedByPaymentsEnvironment() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = EventDesignLibraryStore(directory: root, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" })
        let event = try store.create(name: "Gala", venue: "")
        try store.link(designID: event.id, binding: "test:https://a", serverEventID: "t-1")
        try store.link(designID: event.id, binding: "live:https://b", serverEventID: "l-1")
        let reloaded = EventDesignLibraryStore(directory: root, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" })
        XCTAssertEqual(reloaded.library.design(linkedTo: "t-1", binding: "test:https://a")?.id, event.id)
        XCTAssertNil(reloaded.library.design(linkedTo: "t-1", binding: "live:https://b"))
        XCTAssertEqual(reloaded.design(id: event.id)?.serverEventID(binding: "live:https://b"), "l-1")
    }

    func testLegacyProfileMigratesToOneSavedEventWithoutChangingIt() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var legacy = EventProfile.pocketPixelsDefault
        legacy.isEnabled = true; legacy.customerScreenEnabled = true; legacy.eventName = "Old Gala"
        legacy.receiptHeader.mode = .customEventHeader; legacy.receiptHeader.assetIdentifier = "8a6f3a8e-4a52-4cc4-9a1b-8bb1f0d3a111"
        legacy.receiptHeader.brandingMode = .eventFirst
        let store = EventDesignLibraryStore(directory: root, legacyProfile: { legacy }, legacyName: { "" })
        let migrated = try XCTUnwrap(store.library.events.first)
        XCTAssertEqual(migrated.name, "Old Gala")
        XCTAssertTrue(migrated.personalizeReceipt); XCTAssertTrue(migrated.guestScreensEnabled)
        XCTAssertEqual(migrated.layout, .eventFirst, "An existing layout choice is kept")
        XCTAssertTrue(store.library.appliedEventModeEnabled)
        XCTAssertEqual(migrated.appliedProfile().receiptHeader, legacy.normalized().receiptHeader)
        let again = EventDesignLibraryStore(directory: root, legacyProfile: { legacy }, legacyName: { "" })
        XCTAssertEqual(again.library.events.map(\.id), [migrated.id], "Migration runs once with a stable identity")
        XCTAssertTrue(EventDesignLibrary.migrating(legacy: .pocketPixelsDefault, legacyName: "").events.isEmpty)
    }

    func testUnreadableLibraryIsPreservedAndRefusesWrites() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("EventDesignLibraryV1/library.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("{broken".utf8); try corrupt.write(to: file)
        let store = EventDesignLibraryStore(directory: root, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" })
        XCTAssertNotNil(store.storageError)
        XCTAssertThrowsError(try store.create(name: "New", venue: ""))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testSessionSetupDraftFromEarlierBuildStillDecodes() throws {
        let data = Data(#"{"mode":"SERVER_MANAGED","eventID":"e1","serverBinding":"test:x","branding":"custom"}"#.utf8)
        let draft = try JSONDecoder().decode(OperatorSessionSetupDraft.self, from: data)
        XCTAssertEqual(draft.mode, .serverManaged); XCTAssertNil(draft.eventModeEnabled); XCTAssertNil(draft.requestedMethods)
    }
}

// MARK: - Payment choices and cash

@MainActor final class GuestPaymentAndCashTests: XCTestCase {
    func testChoicesMapOntoTheExistingPolicyModel() {
        XCTAssertEqual(GuestPaymentChoice(qrPhEnabled: true, cashEnabled: false), .qrOnly)
        XCTAssertEqual(GuestPaymentChoice(qrPhEnabled: false, cashEnabled: true), .cashOnly)
        XCTAssertEqual(GuestPaymentChoice(qrPhEnabled: true, cashEnabled: true), .qrAndCash)
        XCTAssertFalse(GuestPaymentChoice.noPayment.isPaid)
        XCTAssertTrue(GuestPaymentChoice.cashOnly.acceptsCash && !GuestPaymentChoice.cashOnly.acceptsQRPh)
        XCTAssertTrue(GuestPaymentChoice.qrOnly.methodSummary.contains("provider verified"))
        XCTAssertTrue(GuestPaymentChoice.cashOnly.methodSummary.contains("customer declared"))
    }

    func testCashOnlyGoesStraightToTheAttendantScreenWithoutCreatingAnyOrder() {
        let model = BoothSessionViewModel()
        model.configurePaidCheckoutForTesting(qrPhEnabled: false, cashEnabled: true)
        XCTAssertEqual(model.soleOfferedPaymentMethod, .cash)
        model.confirmCopySelection()
        XCTAssertEqual(model.state, .cashAttestation)
        XCTAssertNil(model.paymentOrder)
        XCTAssertFalse(model.canLeaveCashPayment, "Cash-only has nothing to go back to")
    }

    func testQROnlyNeverOffersCashAndBothMethodsStillAskTheGuest() {
        let qr = BoothSessionViewModel()
        qr.configurePaidCheckoutForTesting(qrPhEnabled: true, cashEnabled: false)
        XCTAssertEqual(qr.soleOfferedPaymentMethod, .qrPh)
        XCTAssertFalse(qr.canChooseCash)
        qr.chooseCash()
        XCTAssertNotEqual(qr.state, .cashAttestation)
        let both = BoothSessionViewModel()
        both.configurePaidCheckoutForTesting(qrPhEnabled: true, cashEnabled: true)
        XCTAssertNil(both.soleOfferedPaymentMethod)
        both.confirmCopySelection()
        XCTAssertEqual(both.state, .choosingPayment)
        both.chooseCash()
        XCTAssertTrue(both.canLeaveCashPayment)
        both.leaveCashPayment()
        XCTAssertEqual(both.state, .choosingPayment)
    }

    func testAttendantConfirmationRequiresAuthentication() async {
        var environment = BoothSessionEnvironment.customer
        var requests = 0
        environment.authorizeAttendantCashConfirmation = { _ in requests += 1; return false }
        let model = BoothSessionViewModel(environment: environment)
        model.configurePaidCheckoutForTesting(qrPhEnabled: false, cashEnabled: true)
        model.confirmCopySelection()
        let permitBefore = OperatorAccessPermit.shared.isAuthorized
        model.confirmCashReceivedByAttendant()
        await model.activeTaskForTesting?.value
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(model.state, .cashAttestation)
        XCTAssertNil(model.paymentOrder)
        XCTAssertNotNil(model.paymentNotice)
        XCTAssertEqual(OperatorAccessPermit.shared.isAuthorized, permitBefore)
    }

    func testAttendantConfirmationFailingOnTheServerNeverFallsBackToSelfDeclaration() async {
        var environment = BoothSessionEnvironment.customer
        environment.authorizeAttendantCashConfirmation = { _ in true }
        let model = BoothSessionViewModel(environment: environment)
        model.configurePaidCheckoutForTesting(qrPhEnabled: false, cashEnabled: true)
        model.confirmCopySelection()
        OperatorAccessPermit.shared.revoke()
        model.confirmCashReceivedByAttendant()
        await model.activeTaskForTesting?.value
        // Without a reachable, updated payments service nothing is authorized.
        XCTAssertNotEqual(model.state, .cameraReady)
        XCTAssertFalse(OperatorAccessPermit.shared.isAuthorized, "The temporary attendant permit is withdrawn")
    }

    func testOnlineGuestDeclarationDoesNotAskForOperatorAuthentication() async {
        var environment = BoothSessionEnvironment.customer
        var authenticationRequests = 0
        environment.authorizeAttendantCashConfirmation = { _ in authenticationRequests += 1; return false }
        let model = BoothSessionViewModel(environment: environment)
        model.configurePaidCheckoutForTesting(qrPhEnabled: false, cashEnabled: true)
        model.confirmCopySelection()
        let permitBefore = OperatorAccessPermit.shared.isAuthorized
        model.declareCashPaidByGuest()
        model.declareCashPaidByGuest() // A second tap during the transition cannot start another task.
        await model.activeTaskForTesting?.value
        XCTAssertEqual(authenticationRequests, 0)
        XCTAssertEqual(OperatorAccessPermit.shared.isAuthorized, permitBefore)
        XCTAssertNotEqual(model.state, .cameraReady, "A customer tap still needs a valid server entitlement")
    }

    func testGuestDeclarationCannotBypassOfflineAttendantAuthentication() async {
        var environment = BoothSessionEnvironment.customer
        var authenticationRequests = 0
        environment.authorizeAttendantCashConfirmation = { _ in authenticationRequests += 1; return false }
        let model = BoothSessionViewModel(environment: environment)
        model.configurePaidCheckoutForTesting(qrPhEnabled: false, cashEnabled: true, authority: .signedOffline(snapshotID: "fixture", expiresAt: Date().addingTimeInterval(3600)))
        model.confirmCopySelection()
        model.declareCashPaidByGuest()
        await model.activeTaskForTesting?.value
        XCTAssertEqual(authenticationRequests, 1)
        XCTAssertEqual(model.state, .cashAttestation)
        XCTAssertNil(model.paymentOrder)
    }

    func testGuestDeclarationUsesBoothCredentialAndKeepsSelfReportedProvenance() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CashConfirmationProtocol.self]
        CashConfirmationProtocol.requests = []
        let api = PaymentsAPIClient(configuration: PaymentsConfiguration(baseURL: URL(string: "https://payments.example.test")!, environment: "live"),
                                    credentialStore: PaymentPairingCredential(token: String(repeating: "b", count: 40)),
                                    operatorCredentialStore: PaymentPairingCredential(token: String(repeating: "o", count: 40)),
                                    session: URLSession(configuration: configuration))
        let response = try await api.declareCash(orderID: "o1")
        let request = try XCTUnwrap(CashConfirmationProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/orders/o1/cash-declaration")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(String(repeating: "b", count: 40))")
        XCTAssertEqual(response.attempt?.state, "SELF_REPORTED")
        XCTAssertEqual(response.attempt?.verification, "UNVERIFIED_SELF_REPORTED")
        XCTAssertFalse(response.attempt?.isOperatorConfirmedCash == true)
        XCTAssertNotNil(response.entitlement)
    }

    func testConfirmationUnavailableErrorsAreRecognised() {
        XCTAssertTrue(BoothSessionViewModel.isCashConfirmationUnavailable(.unauthorized))
        XCTAssertTrue(BoothSessionViewModel.isCashConfirmationUnavailable(.configuration("pair")))
        XCTAssertTrue(BoothSessionViewModel.isCashConfirmationUnavailable(.rejected(code: "not_found", message: "", status: 404, details: Data())))
        XCTAssertFalse(BoothSessionViewModel.isCashConfirmationUnavailable(.rejected(code: "payment_method_locked", message: "", status: 409, details: Data())))
        XCTAssertFalse(BoothSessionViewModel.isCashConfirmationUnavailable(.outcomeUnknown))
    }

    func testOperatorConfirmedProvenanceIsDecodedSeparatelyFromHistoricalCash() throws {
        let confirmed = try JSONDecoder().decode(PaymentAttempt.self, from: Data(#"{"id":"a","method":"CASH_DECLARED","state":"OPERATOR_CONFIRMED","verification":"OPERATOR_CONFIRMED"}"#.utf8))
        let historical = try JSONDecoder().decode(PaymentAttempt.self, from: Data(#"{"id":"b","method":"CASH_DECLARED","state":"SELF_REPORTED","verification":"UNVERIFIED_SELF_REPORTED"}"#.utf8))
        XCTAssertTrue(confirmed.isOperatorConfirmedCash)
        XCTAssertFalse(historical.isOperatorConfirmedCash)
    }

    func testConfirmCashUsesTheOperatorCredentialAndSendsTheShownAmount() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CashConfirmationProtocol.self]
        CashConfirmationProtocol.requests = []
        let api = PaymentsAPIClient(configuration: PaymentsConfiguration(baseURL: URL(string: "https://payments.example.test")!, environment: "live"),
                                    credentialStore: PaymentPairingCredential(token: String(repeating: "b", count: 40)),
                                    operatorCredentialStore: PaymentPairingCredential(token: String(repeating: "o", count: 40)),
                                    session: URLSession(configuration: configuration))
        let response = try await api.confirmCash(orderID: "o1", expectedTotalCentavos: 5000)
        let request = try XCTUnwrap(CashConfirmationProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/admin/orders/o1/cash-confirmation")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(String(repeating: "o", count: 40))")
        XCTAssertTrue(response.attempt?.isOperatorConfirmedCash == true)
        XCTAssertEqual(CashConfirmationProtocol.bodies.first?["expectedTotalCentavos"] as? Int, 5000)
    }
}

final class CashConfirmationProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
            stream.close()
        }
        Self.bodies.append((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
        var json = #"{"order":{"id":"o1","eventId":"e","policyRevisionId":"r","format":"solo","copies":2,"unitPriceCentavos":2500,"totalCentavos":5000,"currency":"PHP","state":"AUTHORIZED","expiresAt":null,"paymentMethod":"CASH_DECLARED"},"attempt":{"id":"a","method":"CASH_DECLARED","state":"OPERATOR_CONFIRMED","verification":"OPERATOR_CONFIRMED"},"entitlement":{"id":"en","orderId":"o1","eventId":"e","policyRevisionId":"r","selectedFormat":"solo","purchasedCopies":2,"unitPriceCentavos":2500,"totalCentavos":5000,"authorizationSource":"UNVERIFIED_CASH_DECLARED","authorizedAt":"2026-10-14T01:00:00.000Z","state":"AUTHORIZED"},"serverTime":"2026-10-14T01:00:00.000Z"}"#
        if request.url?.path.hasSuffix("/cash-declaration") == true {
            json = json.replacingOccurrences(of: "\"state\":\"OPERATOR_CONFIRMED\"", with: "\"state\":\"SELF_REPORTED\"")
                .replacingOccurrences(of: "\"verification\":\"OPERATOR_CONFIRMED\"", with: "\"verification\":\"UNVERIFIED_SELF_REPORTED\"")
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// MARK: - Artwork import

final class EventLogoImportTests: XCTestCase {
    private func store() throws -> (EventHeaderAssetStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("logo-\(UUID())")
        return (try EventHeaderAssetStore(directoryURL: root), root)
    }

    private func png(size: CGSize, opaque: Bool, padded: Bool = false) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            if opaque { UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size)) }
            UIColor.black.setFill()
            let inset = padded ? size.width * 0.3 : size.width * 0.05
            context.fill(CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: padded ? size.height * 0.3 : size.height * 0.05))
        }.pngData()!
    }

    private func pdf(pages: Int, password: String? = nil) -> Data {
        let data = NSMutableData()
        var info: [String: Any] = [:]
        if let password { info[kCGPDFContextUserPassword as String] = password; info[kCGPDFContextOwnerPassword as String] = password }
        UIGraphicsBeginPDFContextToData(data, CGRect(x: 0, y: 0, width: 300, height: 100), info)
        for _ in 0..<pages {
            UIGraphicsBeginPDFPage()
            UIColor.black.setFill(); UIRectFill(CGRect(x: 20, y: 20, width: 260, height: 60))
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    func testValidPNGTransparentPNGJPEGAndVectorPDFImport() async throws {
        let (store, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = UIImage(data: png(size: CGSize(width: 400, height: 200), opaque: true))!.jpegData(compressionQuality: 0.9)!
        for (data, kind) in [(png(size: CGSize(width: 400, height: 200), opaque: true), EventArtworkKind.bitmap),
                             (png(size: CGSize(width: 400, height: 200), opaque: false), .bitmap),
                             (jpeg, .bitmap), (pdf(pages: 1), .vector)] {
            let imported = try await EventArtworkImporter.importData(data, store: { store })
            XCTAssertEqual(imported.artwork.kind, kind)
            XCTAssertNotNil(store.loadArtwork(identifier: imported.identifier), "Readable after a relaunch-equivalent reload")
        }
    }

    func testCorruptOversizedMultipageAndEncryptedFilesAreRejectedWithClearMessages() async throws {
        let (store, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(Data, String)] = [
            (Data("not an image".utf8), "not a readable PNG, JPEG or PDF"),
            (Data(count: EventArtwork.maximumFileSize + 1), "too large"),
            (pdf(pages: 3), "3 pages"),
            (pdf(pages: 1, password: "secret"), "password protected")
        ]
        for (data, expected) in cases {
            do {
                _ = try await EventArtworkImporter.importData(data, store: { store })
                XCTFail("Expected rejection: \(expected)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
            }
        }
    }

    func testReplacementCreatesANewIdentifierAndKeepsTheOldArtworkForFrozenSessions() async throws {
        let (store, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await EventArtworkImporter.importData(png(size: CGSize(width: 300, height: 100), opaque: false), store: { store })
        let second = try await EventArtworkImporter.importData(png(size: CGSize(width: 200, height: 200), opaque: false), store: { store })
        XCTAssertNotEqual(first.identifier, second.identifier)
        XCTAssertNotNil(store.loadArtwork(identifier: first.identifier), "A frozen session's original artwork still resolves for reprints")
        XCTAssertNil(store.loadArtwork(identifier: UUID().uuidString.lowercased()), "A missing asset loads as nil (standard header fallback)")
    }

    func testContentBoundsIgnoreEmptyPaddingSoPaddedLogosPrintAtTheSameSize() throws {
        let tight = EventArtwork(image: UIImage(data: png(size: CGSize(width: 400, height: 200), opaque: false))!)
        let padded = EventArtwork(image: UIImage(data: png(size: CGSize(width: 1000, height: 500), opaque: true, padded: true))!)
        let config = ReceiptHeaderConfiguration.coBrandedRecommended
        let tightSize = CoBrandedHeaderGeometry.logoFrameSize(sourceSize: tight.contentBounds.size, configuration: config)
        let paddedSize = CoBrandedHeaderGeometry.logoFrameSize(sourceSize: padded.contentBounds.size, configuration: config)
        XCTAssertEqual(paddedSize.width / paddedSize.height, tightSize.width / tightSize.height, accuracy: 0.15)
        XCTAssertLessThan(padded.contentBounds.width, padded.size.width * 0.5, "White padding is excluded")
        XCTAssertTrue(CGRect(origin: .zero, size: padded.size).contains(padded.contentBounds))
    }
}

// MARK: - Rendered operator and guest screens for visual review

@MainActor final class SessionSetupScreenRenderTests: XCTestCase {
    func testRenderCenteredGuestCash() async throws {
        let guest = BoothSessionViewModel()
        guest.configurePaidCheckoutForTesting(qrPhEnabled: false, cashEnabled: true)
        guest.confirmCopySelection()
        try await render("Guest_cash_centered_portrait", CashAttestationView(viewModel: guest))
        try await render("Guest_cash_centered_landscape", CashAttestationView(viewModel: guest), width: 1194, height: 834)
    }

    func testRenderSetupScenarios() async throws {
        // A: regular paid session, QR only.
        let a = MatrixFixture(); defer { a.cleanup() }
        await a.model.choosePayment(.qrOnly)
        await a.model.connectPaidCheckout()
        a.model.policy.priceText = "25"
        try await render("A_regular_qr", NavigationStack { SessionSetupView(coordinator: a.model) })

        // B: free event with a co-branded receipt and a real logo file.
        let b = MatrixFixture(); defer { b.cleanup() }
        await b.model.createEvent(name: "CIM Graduation Ball", venue: "Cebu")
        let logo = try EventHeaderAssetStore().importArtworkData(Self.sampleLogoPNG())
        b.usable.insert(logo)
        b.model.design?.personalizeReceipt = true
        b.model.design?.profile.receiptHeader.assetIdentifier = logo
        b.model.saveDesign()
        try await render("B_free_event_cobranded", NavigationStack { SessionSetupView(coordinator: b.model) }, height: 2600)
        try await render("B_free_event_cobranded_landscape", NavigationStack { SessionSetupView(coordinator: b.model) }, width: 1194, height: 1800)
        try await render("B_review", SessionSetupReviewView(setup: b.model, onBack: {}, onFinished: { _ in }), height: 2400)

        // C: cash-only event.
        let c = MatrixFixture(); defer { c.cleanup() }
        await c.model.choosePayment(.cashOnly)
        await c.model.createEvent(name: "Night Market", venue: "IT Park")
        c.model.policy.priceText = "30"
        try await render("C_cash_only_event", NavigationStack { SessionSetupView(coordinator: c.model) }, height: 2000)

        // Guest cash screen.
        let guest = BoothSessionViewModel()
        guest.configurePaidCheckoutForTesting(qrPhEnabled: true, cashEnabled: true)
        guest.confirmCopySelection()
        guest.chooseCash()
        try await render("Guest_cash_attendant", CashAttestationView(viewModel: guest))
    }

    static func sampleLogoPNG() -> Data {
        let size = CGSize(width: 1080, height: 360)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let navy = UIColor(red: 0.07, green: 0.12, blue: 0.24, alpha: 1)
            navy.setStroke()
            context.cgContext.setLineWidth(12)
            context.cgContext.strokeEllipse(in: CGRect(x: 20, y: 20, width: 320, height: 320))
            context.cgContext.setLineWidth(5)
            context.cgContext.strokeEllipse(in: CGRect(x: 80, y: 80, width: 200, height: 200))
            NSString(string: "SIM").draw(at: CGPoint(x: 380, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 190, weight: .black), .foregroundColor: navy])
            NSString(string: "SAMPLE INSTITUTE OF MEDICINE").draw(at: CGPoint(x: 385, y: 262), withAttributes: [.font: UIFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: navy])
        }.pngData()!
    }

    private func render<V: View>(_ name: String, _ view: V, width: CGFloat = 834, height: CGFloat = 1194) async throws {
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(1200))
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(data: try XCTUnwrap(image.pngData()), uniformTypeIdentifier: "public.png")
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor final class EventDesignDirtyStateTests: XCTestCase {
    func testConnectingPaidCheckoutDoesNotMarkTheDesignAsEdited() async {
        let f = MatrixFixture(); defer { f.cleanup() }
        await f.model.choosePayment(.cashOnly)
        await f.model.createEvent(name: "Night Market", venue: "")
        XCTAssertNotNil(f.model.targetServerEventID)
        XCTAssertFalse(f.model.designDirty)
        f.model.design?.venue = "IT Park"
        XCTAssertTrue(f.model.designDirty)
        f.model.saveDesign()
        XCTAssertNotNil(f.library.design(id: f.model.designID!)?.serverEventID(binding: f.workspace.serverBinding), "Saving a draft keeps the paid link")
    }
}
